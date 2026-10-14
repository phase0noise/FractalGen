// Two-context, C-slow Mandelbrot worker.
//
// The three multipliers are shared by two independent pixel contexts.  A
// multiply for one context is launched while the preceding context is being
// updated, allowing an orbit step to enter the datapath every clock whenever
// both contexts are active.  Completed contexts double as a two-entry result
// queue and are not reused until their result is acknowledged.

`include "mandel_constants.vh"

module Engine_interleaved #(parameter BRENT_CYCLE=1, parameter CYCLE_BITS=8) (
    input  [`E_ADDR_WIDTH-1:0] my_addr,
    input  [`E_ADDR_WIDTH-1:0] engine_addr,
    input  [82:0] in_word,
    input         latch_en,
    input         eRST,
    input         Engine_CLK,
    input         req_ack,
    input         detail_enable,
    input         deep_enable,
    input         turbo_enable,
    input         overrender_enable,
    input [1:0]   iteration_level,
    output [26:0] out_word,
    output        available,
    output        idle,
    output        service_req,
    output        quick_escape
);

localparam [1:0] C_FREE = 2'd0;
localparam [1:0] C_ACTIVE = 2'd1;
localparam [1:0] C_DONE = 2'd2;
localparam [1:0] C_COLOR = 2'd3;

reg [1:0] context_state [0:1];
reg signed [31:0] context_re [0:1];
reg signed [31:0] context_im [0:1];
reg signed [31:0] context_c_re [0:1];
reg signed [31:0] context_c_im [0:1];
reg signed [31:0] context_period_re [0:1];
reg signed [31:0] context_period_im [0:1];
reg [15:0] context_iteration [0:1];
localparam CYCLE_WIDTH=BRENT_CYCLE ? CYCLE_BITS : 4;
reg [CYCLE_WIDTH-1:0] context_period_counter [0:1];
reg [CYCLE_WIDTH-1:0] context_period_span [0:1];
reg context_have_iteration [0:1];
reg context_period_valid [0:1];
reg context_detail [0:1];
reg context_deep [0:1];
reg context_overrender [0:1];
reg [1:0] context_level [0:1];
reg context_turbo [0:1];
reg context_cardioid_pending [0:1];
reg signed [31:0] context_cardioid_q [0:1];
reg signed [31:0] context_y_squared [0:1];
reg [9:0] context_x [0:1];
reg [8:0] context_y [0:1];
reg [26:0] context_result [0:1];
reg [3:0] context_escape_fraction [0:1];
reg [7:0] context_color_iteration [0:1];
reg context_interior [0:1];
reg context_quick_escape [0:1];

reg signed [63:0] pipe_re_product;
reg signed [63:0] pipe_im_product;
reg signed [63:0] pipe_cross_product;
reg pipe_valid;
reg pipe_context;
reg [1:0] pipe_mode;
reg launch_turn;

reg launch_valid;
reg launch_context;
wire context0_active = (context_state[0] == C_ACTIVE);
wire context1_active = (context_state[1] == C_ACTIVE);
wire context0_launchable = context0_active && !(pipe_valid && !pipe_context);
wire context1_launchable = context1_active && !(pipe_valid && pipe_context);

always @(*) begin
    launch_valid = 1'b0;
    launch_context = launch_turn;
    if (!launch_turn) begin
        if (context0_launchable) begin
            launch_valid = 1'b1;
            launch_context = 1'b0;
        end else if (context1_launchable) begin
            launch_valid = 1'b1;
            launch_context = 1'b1;
        end
    end else begin
        if (context1_launchable) begin
            launch_valid = 1'b1;
            launch_context = 1'b1;
        end else if (context0_launchable) begin
            launch_valid = 1'b1;
            launch_context = 1'b0;
        end
    end
end

wire signed [31:0] launch_re = launch_context ? context_re[1] : context_re[0];
wire signed [31:0] launch_im = launch_context ? context_im[1] : context_im[0];
wire signed [31:0] launch_c_re = launch_context ? context_c_re[1] : context_c_re[0];
wire signed [31:0] launch_c_im = launch_context ? context_c_im[1] : context_c_im[0];
wire launch_have_iteration = launch_context ?
    context_have_iteration[1] : context_have_iteration[0];
wire launch_turbo = launch_context ? context_turbo[1] : context_turbo[0];
wire launch_cardioid_pending = launch_context ?
    context_cardioid_pending[1] : context_cardioid_pending[0];
wire signed [31:0] launch_cardioid_q = launch_context ?
    context_cardioid_q[1] : context_cardioid_q[0];

localparam [1:0] PIPE_ORBIT = 2'd0;
localparam [1:0] PIPE_INTERIOR_FIRST = 2'd1;
localparam [1:0] PIPE_CARDIOID_FINISH = 2'd2;
wire [1:0] launch_mode = (launch_turbo && !launch_have_iteration) ?
    PIPE_INTERIOR_FIRST :
    ((launch_turbo && launch_cardioid_pending) ? PIPE_CARDIOID_FINISH : PIPE_ORBIT);

wire signed [31:0] launch_plus_one = launch_c_re + 32'sh0100_0000;
wire signed [31:0] launch_minus_quarter = launch_c_re - 32'sh0040_0000;
wire signed [31:0] launch_cardioid_factor =
    launch_cardioid_q + launch_minus_quarter;
wire signed [31:0] multiply0_left =
    (launch_mode == PIPE_INTERIOR_FIRST) ? launch_plus_one :
    ((launch_mode == PIPE_CARDIOID_FINISH) ? launch_cardioid_q : launch_re);
wire signed [31:0] multiply0_right =
    (launch_mode == PIPE_INTERIOR_FIRST) ? launch_plus_one :
    ((launch_mode == PIPE_CARDIOID_FINISH) ? launch_cardioid_factor : launch_re);
wire signed [31:0] multiply1_left =
    (launch_mode == PIPE_INTERIOR_FIRST) ? launch_c_im :
    ((launch_mode == PIPE_CARDIOID_FINISH) ? 32'sd0 : launch_im);
wire signed [31:0] multiply1_right = multiply1_left;
wire signed [31:0] multiply2_left =
    (launch_mode == PIPE_INTERIOR_FIRST) ? launch_minus_quarter :
    ((launch_mode == PIPE_CARDIOID_FINISH) ? 32'sd0 : launch_re);
wire signed [31:0] multiply2_right =
    (launch_mode == PIPE_INTERIOR_FIRST) ? launch_minus_quarter :
    ((launch_mode == PIPE_CARDIOID_FINISH) ? 32'sd0 : launch_im);

wire signed [31:0] update_re = pipe_context ? context_re[1] : context_re[0];
wire signed [31:0] update_im = pipe_context ? context_im[1] : context_im[0];
wire signed [31:0] update_c_re = pipe_context ? context_c_re[1] : context_c_re[0];
wire signed [31:0] update_c_im = pipe_context ? context_c_im[1] : context_c_im[0];
wire signed [31:0] update_period_re = pipe_context ? context_period_re[1] : context_period_re[0];
wire signed [31:0] update_period_im = pipe_context ? context_period_im[1] : context_period_im[0];
wire [15:0] update_iteration = pipe_context ? context_iteration[1] : context_iteration[0];
wire update_have_iteration = pipe_context ? context_have_iteration[1] : context_have_iteration[0];
wire update_period_valid = pipe_context ? context_period_valid[1] : context_period_valid[0];
wire update_detail = pipe_context ? context_detail[1] : context_detail[0];
wire update_deep = pipe_context ? context_deep[1] : context_deep[0];
wire update_overrender = pipe_context ? context_overrender[1] : context_overrender[0];
wire [9:0] update_x = pipe_context ? context_x[1] : context_x[0];
wire [8:0] update_y = pipe_context ? context_y[1] : context_y[0];

wire signed [63:0] update_re_squared = pipe_re_product >>> 24;
wire signed [63:0] update_im_squared = pipe_im_product >>> 24;
wire signed [63:0] update_re_im = pipe_cross_product >>> 24;
wire [63:0] update_magnitude_squared =
    $unsigned(update_re_squared) + $unsigned(update_im_squared);
wire update_escaped =
    (update_magnitude_squared > 64'h0000_0000_0400_0000);
wire signed [63:0] update_next_re =
    update_re_squared - update_im_squared + update_c_re;
wire signed [63:0] update_next_im =
    (update_re_im <<< 1) + update_c_im;
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
wire [15:0] update_iteration_limit =
    update_overrender ? quality_limit(context_level[pipe_context], update_deep) :
    (update_deep ? 16'd1023 : `MAX_ITERATIONS);
wire update_orbit_repeated = update_period_valid &&
    (update_re == update_period_re) && (update_im == update_period_im);

wire [63:0] update_escape_excess =
    update_magnitude_squared - 64'h0000_0000_0400_0000;
wire [63:0] update_fraction_scaled = update_escape_excess >> 23;
wire [3:0] update_escape_fraction =
    (|update_fraction_scaled[63:4]) ? 4'd15 : update_fraction_scaled[3:0];
function [7:0] escape_color;
    input [7:0] iteration;
    input [3:0] fraction;
    input detail;
    reg [7:0] base;
    begin
        base = iteration >= 8'hfe ? iteration - 8'hfe : iteration;
        escape_color = base + ((detail && fraction >= 8 && base < 8'hfd) ? 8'd1 : 8'd0);
    end
endfunction
wire signed [63:0] turbo_product0 = pipe_re_product >>> 24;
wire signed [63:0] turbo_product1 = pipe_im_product >>> 24;
wire signed [63:0] turbo_product2 = pipe_cross_product >>> 24;
wire [63:0] turbo_bulb_radius =
    $unsigned(turbo_product0) + $unsigned(turbo_product1);
wire turbo_in_period2_bulb =
    (turbo_bulb_radius <= 64'h0000_0000_0010_0000);
wire signed [63:0] turbo_q_wide = turbo_product2 + turbo_product1;
wire turbo_in_main_cardioid =
    (turbo_product0 <= ($signed(context_y_squared[pipe_context]) >>> 2));

wire result_select = (context_state[0] != C_DONE) &&
                     (context_state[1] == C_DONE);
assign out_word = result_select ? context_result[1] : context_result[0];
assign quick_escape = service_req && context_quick_escape[result_select];
assign service_req = (context_state[0] == C_DONE) ||
                     (context_state[1] == C_DONE);
assign available = (context_state[0] == C_FREE) ||
                   (context_state[1] == C_FREE);
assign idle = (context_state[0] == C_FREE) &&
              (context_state[1] == C_FREE) && !pipe_valid;

wire address_match = (engine_addr == my_addr);
wire accept_input = address_match && latch_en && available;
wire accept_context = (context_state[0] != C_FREE);

integer reset_index;
integer color_context;
always @(posedge Engine_CLK or posedge eRST) begin
    if (eRST) begin
        pipe_valid <= 1'b0;
        pipe_context <= 1'b0;
        pipe_mode <= PIPE_ORBIT;
        pipe_re_product <= 64'sd0;
        pipe_im_product <= 64'sd0;
        pipe_cross_product <= 64'sd0;
        launch_turn <= 1'b0;
        for (reset_index = 0; reset_index < 2; reset_index = reset_index + 1) begin
            context_state[reset_index] <= C_FREE;
            context_re[reset_index] <= 32'sd0;
            context_im[reset_index] <= 32'sd0;
            context_c_re[reset_index] <= 32'sd0;
            context_c_im[reset_index] <= 32'sd0;
            context_period_re[reset_index] <= 32'sd0;
            context_period_im[reset_index] <= 32'sd0;
            context_iteration[reset_index] <= 16'd0;
            context_period_counter[reset_index] <= 0;
            context_period_span[reset_index] <= 0;
            context_have_iteration[reset_index] <= 1'b0;
            context_period_valid[reset_index] <= 1'b0;
            context_detail[reset_index] <= 1'b0;
            context_deep[reset_index] <= 1'b0;
            context_overrender[reset_index] <= 1'b0;
            context_level[reset_index] <= 2'd0;
            context_turbo[reset_index] <= 1'b0;
            context_cardioid_pending[reset_index] <= 1'b0;
            context_cardioid_q[reset_index] <= 32'sd0;
            context_y_squared[reset_index] <= 32'sd0;
            context_x[reset_index] <= 10'd0;
            context_y[reset_index] <= 9'd0;
            context_result[reset_index] <= 27'd0;
            context_escape_fraction[reset_index] <= 4'd0;
            context_color_iteration[reset_index] <= 8'd0;
            context_interior[reset_index] <= 1'b0;
            context_quick_escape[reset_index] <= 1'b0;
        end
    end else begin
        // Separate all termination decisions from result-register writes.
        for (color_context=0; color_context<2; color_context=color_context+1)
            if (context_state[color_context] == C_COLOR) begin
                context_result[color_context] <= {context_x[color_context], context_y[color_context],
                    context_interior[color_context] ? 8'hfe :
                    escape_color(context_color_iteration[color_context], context_escape_fraction[color_context],
                                 context_detail[color_context])};
                context_state[color_context] <= C_DONE;
            end
        // Retire exactly the result currently presented to the arbiter.
        if (req_ack && service_req)
            context_state[result_select] <= C_FREE;

        // A free context can be refilled independently of the other context.
        if (accept_input) begin
            context_state[accept_context] <= C_ACTIVE;
            context_re[accept_context] <= 32'sd0;
            context_im[accept_context] <= 32'sd0;
            context_c_re[accept_context] <= in_word[63:32];
            context_c_im[accept_context] <= in_word[31:0];
            context_period_re[accept_context] <= 32'sd0;
            context_period_im[accept_context] <= 32'sd0;
            context_iteration[accept_context] <= 16'd0;
            context_period_counter[accept_context] <= 0;
            context_period_span[accept_context] <= 0;
            context_have_iteration[accept_context] <= 1'b0;
            context_period_valid[accept_context] <= BRENT_CYCLE;
            context_detail[accept_context] <= detail_enable;
            context_deep[accept_context] <= deep_enable;
            context_overrender[accept_context] <= overrender_enable;
            context_level[accept_context] <= iteration_level;
            context_turbo[accept_context] <= turbo_enable;
            context_cardioid_pending[accept_context] <= 1'b0;
            context_cardioid_q[accept_context] <= 32'sd0;
            context_y_squared[accept_context] <= 32'sd0;
            context_color_iteration[accept_context] <= 8'd0;
            context_interior[accept_context] <= 1'b0;
            context_quick_escape[accept_context] <= 1'b0;
            context_x[accept_context] <= in_word[82:73];
            context_y[accept_context] <= in_word[72:64];
        end

        // Consume the products launched on the preceding edge.
        if (pipe_valid) begin
            // Update orbit data independently of the escape/interior decision.
            // A terminating context no longer uses its z registers. Keeping
            // these writes speculative removes the wide magnitude comparator
            // from the enable path without changing results or throughput.
            if (pipe_mode != PIPE_CARDIOID_FINISH) begin
                context_re[pipe_context] <= (pipe_mode == PIPE_INTERIOR_FIRST) ?
                    update_c_re : update_next_re[31:0];
                context_im[pipe_context] <= (pipe_mode == PIPE_INTERIOR_FIRST) ?
                    update_c_im : update_next_im[31:0];
            end
            if (pipe_mode == PIPE_ORBIT) begin
                // These values are irrelevant once the orbit terminates.
                // Capture the old count separately for the escaped color.
                context_color_iteration[pipe_context] <= update_iteration[7:0];
                if (update_have_iteration)
                    context_iteration[pipe_context] <= update_iteration + 1'b1;
                else context_have_iteration[pipe_context] <= 1'b1;
                // Brent's exponentially growing checkpoint windows detect
                // exact cycles up to 2^CYCLE_BITS without another orbit datapath.
                // The mask grows 0,1,3,7,... and saturates at the configured
                // window. A zero countdown moves the
                // checkpoint. Escape is still checked before cycle equality.
                if (BRENT_CYCLE) begin
                    if (update_have_iteration) begin
                        if (context_period_counter[pipe_context] == 0) begin
                            context_period_re[pipe_context] <= update_re;
                            context_period_im[pipe_context] <= update_im;
                            context_period_span[pipe_context] <=
                                (context_period_span[pipe_context] << 1)|1'b1;
                            context_period_counter[pipe_context] <=
                                (context_period_span[pipe_context] << 1)|1'b1;
                        end else context_period_counter[pipe_context] <=
                            context_period_counter[pipe_context]-1'b1;
                    end
                end else if (context_period_counter[pipe_context] == 4'd15) begin
                    context_period_re[pipe_context] <= update_re;
                    context_period_im[pipe_context] <= update_im;
                    context_period_valid[pipe_context] <= update_have_iteration;
                    context_period_counter[pipe_context] <= 4'd0;
                end else context_period_counter[pipe_context] <=
                    context_period_counter[pipe_context] + 1'b1;
            end
            if (pipe_mode == PIPE_INTERIOR_FIRST) begin
                // The legacy first z=0 multiply carries no useful orbit data.
                // Turbo mode spends it on the period-2 bulb and the first half
                // of the main-cardioid test instead, without adding DSPs.
                context_cardioid_q[pipe_context] <= turbo_q_wide[31:0];
                context_y_squared[pipe_context] <= turbo_product1[31:0];
                context_have_iteration[pipe_context] <= 1'b1;
                context_period_counter[pipe_context] <= BRENT_CYCLE ? 0 : 1;
                context_cardioid_pending[pipe_context] <= 1'b1;
                if (turbo_in_period2_bulb) begin
                    context_interior[pipe_context] <= 1'b1;
                    context_state[pipe_context] <= C_COLOR;
                end
            end else if (pipe_mode == PIPE_CARDIOID_FINISH) begin
                context_cardioid_pending[pipe_context] <= 1'b0;
                if (turbo_in_main_cardioid) begin
                    context_interior[pipe_context] <= 1'b1;
                    context_state[pipe_context] <= C_COLOR;
                end
            end else if (update_have_iteration && update_escaped) begin
                context_escape_fraction[pipe_context] <= update_escape_fraction;
                context_quick_escape[pipe_context] <= update_iteration < 16'd32;
                context_interior[pipe_context] <= 1'b0;
                context_state[pipe_context] <= C_COLOR;
            end else if (update_have_iteration && update_orbit_repeated) begin
                context_interior[pipe_context] <= 1'b1;
                context_state[pipe_context] <= C_COLOR;
            end else if (update_have_iteration &&
                         ((update_iteration + 1'b1) == update_iteration_limit)) begin
                context_interior[pipe_context] <= 1'b1;
                context_state[pipe_context] <= C_COLOR;
            end
        end

        // Launch only a context that is not being updated on this edge.  This
        // makes the feedback dependency explicit and prevents stale z values.
        pipe_valid <= launch_valid;
        if (launch_valid) begin
            pipe_context <= launch_context;
            pipe_mode <= launch_mode;
            pipe_re_product <= multiply0_left * multiply0_right;
            pipe_im_product <= multiply1_left * multiply1_right;
            pipe_cross_product <= multiply2_left * multiply2_right;
            launch_turn <= ~launch_context;
        end
    end
end

endmodule
