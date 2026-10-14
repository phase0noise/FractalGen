// Resource-efficient Mandelbrot engine.
//
// This implementation deliberately preserves Engine.v's fixed-point arithmetic
// and iteration-count convention.  The architectural change is that the escape
// test is performed at the start of the following iteration.  That lets the
// same Re^2 and Im^2 products serve both the escape test and the next update,
// reducing the datapath from five multipliers to three.

`include "mandel_constants.vh"

module Engine_fast #(parameter BRENT_CYCLE=1, parameter CYCLE_BITS=8) (
    input  [`E_ADDR_WIDTH-1:0] my_addr,
    input  [`E_ADDR_WIDTH-1:0] engine_addr,
    input  [82:0] in_word,
    input         latch_en,
    input         eRST,
    input         Engine_CLK,
    input         req_ack,
    input         detail_enable,
    input         deep_enable,
    input         overrender_enable,
    input [1:0]   iteration_level,
    output [26:0] out_word,
    output reg    available,
    output        idle,
    output reg    service_req,
    output        quick_escape
);

localparam S_IDLE         = 3'd0;
localparam S_MULTIPLY     = 3'd1;
localparam S_UPDATE       = 3'd2;
localparam S_WAIT_ACK     = 3'd3;

reg [2:0] state;
reg [82:0] latched_word;
reg signed [31:0] z_re, z_im;
reg signed [63:0] re_product, im_product, cross_product;
reg [15:0] iteration;
reg have_iteration;
reg detail_latched, deep_latched, overrender_latched;
reg [1:0] level_latched;
reg signed [31:0] period_re, period_im;
localparam CYCLE_WIDTH=BRENT_CYCLE ? CYCLE_BITS : 4;
reg [CYCLE_WIDTH-1:0] period_counter;
reg [CYCLE_WIDTH-1:0] period_span;
reg period_valid;
reg [7:0] color_index;

wire signed [31:0] c_re = latched_word[63:32];
wire signed [31:0] c_im = latched_word[31:0];
wire [9:0] pixel_x = latched_word[82:73];
wire [8:0] pixel_y = latched_word[72:64];
wire address_match = (engine_addr == my_addr);

wire signed [63:0] re_squared = re_product >>> 24;
wire signed [63:0] im_squared = im_product >>> 24;
wire signed [63:0] re_im      = cross_product >>> 24;
wire [63:0] magnitude_squared = $unsigned(re_squared) + $unsigned(im_squared);
wire escaped = (magnitude_squared > 64'h0000_0000_0400_0000);
wire signed [63:0] next_re_wide = re_squared - im_squared + c_re;
wire signed [63:0] next_im_wide = (re_im <<< 1) + c_im;
function [15:0] quality_limit;
    input [1:0] level;
    input deep;
    begin
        case (level)
            2'd0: quality_limit = `OVERRENDER_ITERATIONS;
            2'd1: quality_limit = 16'd16383;
            2'd2: quality_limit = `OVERRENDER_DEEP_ITERATIONS;
            2'd3: quality_limit = 16'd65535;
            default: quality_limit = deep ? `OVERRENDER_DEEP_ITERATIONS : `OVERRENDER_ITERATIONS;
        endcase
    end
endfunction
wire [15:0] iteration_limit = overrender_latched ?
    quality_limit(level_latched, deep_latched) :
    (deep_latched ? 16'd1023 : `MAX_ITERATIONS);
wire orbit_repeated = period_valid && (z_re == period_re) && (z_im == period_im);

wire [63:0] escape_excess = magnitude_squared - 64'h0000_0000_0400_0000;
wire [63:0] fraction_scaled = escape_excess >> 23;
wire [3:0] escape_fraction = (|fraction_scaled[63:4]) ?
                             4'd15 : fraction_scaled[3:0];

// FE and FF are reserved for interior/background in the color mapper. Fold
// escaped iterations that land there back to 0/1 so deep mode never creates
// false black contour bands when its 16-bit counter crosses an 8-bit boundary.
wire [7:0] escape_base_index = (iteration[7:0] >= 8'hfe) ?
                               (iteration[7:0] - 8'hfe) : iteration[7:0];
// Round escape detail consistently. Spatial thresholds turn a uniform orbit
// into a checkerboard before palette remapping can amplify the difference.
wire detail_increment = detail_latched && escape_fraction[3] &&
                        (escape_base_index < 8'hfd);

// The result is kept driven and stable while service_req is asserted.  This is
// friendlier to FPGA routing than the internal tri-state bus used by Engine.v.
assign out_word = {pixel_x, pixel_y, color_index};
assign idle = available && !service_req && (state == S_IDLE);
assign quick_escape = service_req && color_index != 8'hfe && iteration < 16'd32;

always @(posedge Engine_CLK or posedge eRST) begin
    if (eRST) begin
        state          <= S_IDLE;
        available      <= 1'b1;
        service_req    <= 1'b0;
        iteration      <= 16'd0;
        have_iteration <= 1'b0;
        z_re            <= 32'sd0;
        z_im            <= 32'sd0;
        detail_latched  <= 1'b0;
        deep_latched    <= 1'b0;
        overrender_latched <= 1'b0;
        level_latched <= 2'd0;
        period_counter  <= 0;
        period_span     <= 0;
        period_valid    <= 1'b0;
        color_index     <= 8'hfe;
    end else begin
        case (state)
            S_IDLE: begin
                available   <= 1'b1;
                service_req <= 1'b0;
                if (address_match && latch_en) begin
                    latched_word    <= in_word;
                    z_re            <= 32'sd0;
                    z_im            <= 32'sd0;
                    iteration       <= 16'd0;
                    have_iteration  <= 1'b0;
                    detail_latched  <= detail_enable;
                    deep_latched    <= deep_enable;
                    overrender_latched <= overrender_enable;
                    level_latched <= iteration_level;
                    period_counter  <= 0;
                    period_span     <= 0;
                    period_re       <= 0;
                    period_im       <= 0;
                    period_valid    <= BRENT_CYCLE;
                    color_index     <= 8'hfe;
                    available       <= 1'b0;
                    state           <= S_MULTIPLY;
                end
            end

            S_MULTIPLY: begin
                re_product    <= z_re * z_re;
                im_product    <= z_im * z_im;
                cross_product <= z_re * z_im;
                state         <= S_UPDATE;
            end

            S_UPDATE: begin
                if (have_iteration && escaped) begin
                    color_index <= escape_base_index + detail_increment;
                    service_req <= 1'b1;
                    state       <= S_WAIT_ACK;
                end else if (have_iteration && orbit_repeated) begin
                    // Exact equality means the finite-precision orbit is in a
                    // cycle and can never escape. This is a lossless shortcut.
                    color_index <= 8'hfe;
                    service_req <= 1'b1;
                    state       <= S_WAIT_ACK;
                end else if (have_iteration && ((iteration + 1'b1) == iteration_limit)) begin
                    color_index <= 8'hfe;
                    service_req <= 1'b1;
                    state       <= S_WAIT_ACK;
                end else begin
                    // These operations and truncations match Engine.v.
                    z_re <= next_re_wide[31:0];
                    z_im <= next_im_wide[31:0];
                    if (have_iteration)
                        iteration <= iteration + 1'b1;
                    else
                        have_iteration <= 1'b1;
                    // Compare exact finite-precision states. Growing the
                    // checkpoint window catches periods up to 2^CYCLE_BITS,
                    // exceeding the old 16-step window. A saturating span
                    // mask keeps the counter small and limits revisit delay.
                    if (BRENT_CYCLE) begin
                        if (have_iteration) begin
                            if (period_counter == 0) begin
                                period_re <= z_re; period_im <= z_im;
                                period_span <= (period_span << 1)|1'b1;
                                period_counter <= (period_span << 1)|1'b1;
                            end else period_counter <= period_counter-1'b1;
                        end
                    end else if (period_counter == 4'd15) begin
                        period_re      <= z_re;
                        period_im      <= z_im;
                        period_valid   <= have_iteration;
                        period_counter <= 4'd0;
                    end else begin
                        period_counter <= period_counter + 1'b1;
                    end
                    state <= S_MULTIPLY;
                end
            end

            S_WAIT_ACK: begin
                service_req <= 1'b1;
                if (req_ack) begin
                    service_req <= 1'b0;
                    available <= 1'b1;
                    state     <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
