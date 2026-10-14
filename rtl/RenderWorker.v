`include "mandel_constants.vh"

// Reuse the existing multipliers for adaptive two/four-sample antialiasing.
// Normal mode keeps the original two-context worker and its throughput.
module RenderWorker #(
    parameter USE_INTERLEAVED = `USE_INTERLEAVED_ENGINE,
    parameter ADAPTIVE = 0,
    parameter BRENT_CYCLE = 1,
    parameter CYCLE_BITS = 8
) (
    input [`E_ADDR_WIDTH-1:0] my_addr,
    input [`E_ADDR_WIDTH-1:0] engine_addr,
    input [82:0] in_word,
    input latch_en,
    input eRST,
    input Engine_CLK,
    input req_ack,
    input detail_enable,
    input deep_enable,
    input turbo_enable,
    input overrender_enable,
    input [1:0] iteration_level,
    input [31:0] sample_step,
    input [1:0] palette,
    input [7:0] palette_phase,
    output [34:0] out_word,
    output available,
    output idle,
    output service_req
);
localparam S_IDLE = 2'd0, S_SAMPLES = 2'd1, S_BLEND = 2'd2, S_RESULT = 2'd3;
reg [1:0] state;
reg [82:0] pixel;
reg signed [31:0] quarter_step;
reg [2:0] sent, received;
reg [9:0] red_sum, green_sum, blue_sum;
reg [23:0] sample_color;
reg sample_pending;
reg full_sampling, first_quick, sample_quick;
reg [7:0] first_index, sample_index;
reg [34:0] quality_result;
wire [26:0] core_word;
wire core_available, core_idle, core_req;
wire core_quick;
wire [2:0] sample_limit = (ADAPTIVE && !full_sampling) ? 3'd2 : 3'd4;
wire [1:0] sample_number = !ADAPTIVE ? sent[1:0] :
    sent==0 ? 2'd0 : sent==1 ? 2'd3 : sent==2 ? 2'd1 : 2'd2;
wire quality_latch = (state == S_SAMPLES) && (sent < sample_limit) && core_available;
wire core_latch = overrender_enable ? quality_latch : latch_en;
wire core_ack = overrender_enable ? (state == S_SAMPLES && core_req && !sample_pending) : req_ack;
wire signed [31:0] base_re = pixel[63:32];
wire signed [31:0] base_im = pixel[31:0];
wire signed [31:0] sample_re = sample_number[0] ? base_re + quarter_step : base_re - quarter_step;
wire signed [31:0] sample_im = sample_number[1] ? base_im - quarter_step : base_im + quarter_step;
wire [82:0] sample_word = {pixel[82:64],sample_re,sample_im};
wire [82:0] core_input = overrender_enable ? sample_word : in_word;
wire [`E_ADDR_WIDTH-1:0] core_address = overrender_enable ? my_addr : engine_addr;

generate
    if (USE_INTERLEAVED) begin : interleaved
        Engine_interleaved #(.BRENT_CYCLE(BRENT_CYCLE),.CYCLE_BITS(CYCLE_BITS)) core (
            .my_addr(my_addr), .engine_addr(core_address), .in_word(core_input),
            .latch_en(core_latch), .eRST(eRST), .Engine_CLK(Engine_CLK),
            .req_ack(core_ack), .detail_enable(detail_enable || overrender_enable),
            .deep_enable(deep_enable), .overrender_enable(overrender_enable),
            .iteration_level(iteration_level),
            .turbo_enable(turbo_enable && !overrender_enable),
            .out_word(core_word), .available(core_available), .idle(core_idle),
            .service_req(core_req), .quick_escape(core_quick)
        );
    end else begin : baseline
        Engine_fast #(.BRENT_CYCLE(BRENT_CYCLE),.CYCLE_BITS(CYCLE_BITS)) core (
            .my_addr(my_addr), .engine_addr(core_address), .in_word(core_input),
            .latch_en(core_latch), .eRST(eRST), .Engine_CLK(Engine_CLK),
            .req_ack(core_ack), .detail_enable(detail_enable || overrender_enable),
            .deep_enable(deep_enable), .overrender_enable(overrender_enable),
            .iteration_level(iteration_level),
            .out_word(core_word), .available(core_available), .idle(core_idle),
            .service_req(core_req), .quick_escape(core_quick)
        );
    end
endgenerate

wire [23:0] sample_bgr;
ColorMapper sample_palette (
    .index(core_word[7:0]), .palette(palette), .phase(palette_phase), .bgr(sample_bgr)
);
wire [9:0] next_red = red_sum + {2'd0, sample_color[7:0]};
wire [9:0] next_green = green_sum + {2'd0, sample_color[15:8]};
wire [9:0] next_blue = blue_sum + {2'd0, sample_color[23:16]};
wire [11:0] blended_rgb;
SupersampleColor blend (
    .red_sum(red_sum), .green_sum(green_sum), .blue_sum(blue_sum),
    .pixel_x(pixel[82:73]), .pixel_y(pixel[72:64]), .rgb(blended_rgb)
);

assign out_word = overrender_enable ? quality_result : {core_word[26:8], 8'd0, core_word[7:0]};
assign service_req = overrender_enable ? (state == S_RESULT) : core_req;
assign available = overrender_enable ? ((state == S_IDLE) && core_idle) : core_available;
assign idle = (state == S_IDLE) && core_idle;

always @(posedge Engine_CLK or posedge eRST) begin
    if (eRST) begin
        state <= S_IDLE;
        pixel <= 83'd0;
        quarter_step <= 32'sd0;
        sent <= 3'd0;
        received <= 3'd0;
        red_sum <= 10'd0;
        green_sum <= 10'd0;
        blue_sum <= 10'd0;
        sample_color <= 24'd0;
        sample_pending <= 1'b0;
        full_sampling <= 1'b0;
        first_quick <= 1'b0; sample_quick <= 1'b0;
        first_index <= 8'd0; sample_index <= 8'd0;
        quality_result <= 35'd0;
    end else begin
        case (state)
            S_IDLE: if (overrender_enable && latch_en && (engine_addr == my_addr) && core_idle) begin
                pixel <= in_word;
                quarter_step <= $signed(sample_step >> 1);
                sent <= 3'd0;
                received <= 3'd0;
                red_sum <= 10'd0;
                green_sum <= 10'd0;
                blue_sum <= 10'd0;
                full_sampling <= !ADAPTIVE;
                first_quick <= 1'b0;
                state <= S_SAMPLES;
            end
            S_SAMPLES: begin
                if (quality_latch) sent <= sent + 1'b1;
                // Palette conversion, accumulation, and final quantization
                // each have a register boundary. Keep the core's result
                // held until its color has entered the accumulation stage.
                if (sample_pending) begin
                    red_sum <= next_red;
                    green_sum <= next_green;
                    blue_sum <= next_blue;
                    received <= received + 1'b1;
                    sample_pending <= 1'b0;
                    if (ADAPTIVE && received == 0) begin
                        first_quick <= sample_quick;
                        first_index <= sample_index;
                    end
                    if (ADAPTIVE && !full_sampling && received == 1) begin
                        // The opposite corners must both escape quickly and
                        // agree in color. Boundary/slow orbits get all four.
                        // A zero fixed-point sample step is exactly identical.
                        if (quarter_step == 0 ||
                            (first_quick && sample_quick && first_index == sample_index)) begin
                            red_sum <= next_red << 1;
                            green_sum <= next_green << 1;
                            blue_sum <= next_blue << 1;
                            received <= 3'd4;
                            state <= S_BLEND;
                        end else full_sampling <= 1'b1;
                    end else if (received == 3'd3) begin
                        state <= S_BLEND;
                    end
                end else if (core_req) begin
                    sample_color <= sample_bgr;
                    sample_index <= core_word[7:0];
                    sample_quick <= core_quick;
                    sample_pending <= 1'b1;
                end
            end
            S_BLEND: begin
                quality_result <= {pixel[82:64], 4'd0, blended_rgb};
                state <= S_RESULT;
            end
            S_RESULT: if (req_ack) state <= S_IDLE;
            default: state <= S_IDLE;
        endcase
    end
end
endmodule
