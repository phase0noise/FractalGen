// PS/2 set-2 receiver. Prefixes belong to the following key event, so releasing
// O cannot accidentally toggle quality mode again. Invalid/incomplete frames
// and orphaned prefixes expire. Short clock glitches are discarded, and every
// event is exactly one system-clock pulse.
module keyboard #(
    parameter TIMEOUT_CYCLES = 1000000,
    parameter FILTER_CYCLES = 4
) (
    input clk,
    input reset,
    inout ps2_clk,
    inout ps2_data,
    output reg [7:0] keycode,
    output reg key_ready,
    output reg key_extended,
    output reg key_released
);
reg [2:0] ps2_clk_sync, ps2_data_sync;
localparam FILTER_WIDTH = FILTER_CYCLES > 1 ? $clog2(FILTER_CYCLES) : 1;
localparam TIMEOUT_WIDTH = TIMEOUT_CYCLES > 1 ? $clog2(TIMEOUT_CYCLES) : 1;
reg [FILTER_WIDTH-1:0] filter_count;
reg ps2_clk_filtered, ps2_clk_previous;
reg [10:0] shift_reg;
reg [3:0] bit_count;
reg [TIMEOUT_WIDTH-1:0] timeout_count;
reg extended_pending, release_pending;
wire ps2_clk_falling = ps2_clk_previous && !ps2_clk_filtered;
wire receiving = bit_count != 0 || extended_pending || release_pending;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        ps2_clk_sync <= 3'b111;
        ps2_data_sync <= 3'b111;
        filter_count <= 0;
        ps2_clk_filtered <= 1'b1;
        ps2_clk_previous <= 1'b1;
        shift_reg <= 11'd0;
        bit_count <= 4'd0;
        timeout_count <= 0;
        extended_pending <= 1'b0;
        release_pending <= 1'b0;
        keycode <= 8'd0;
        key_ready <= 1'b0;
        key_extended <= 1'b0;
        key_released <= 1'b0;
    end else begin
        ps2_clk_sync <= {ps2_clk_sync[1:0], ps2_clk};
        ps2_data_sync <= {ps2_data_sync[1:0], ps2_data};
        ps2_clk_previous <= ps2_clk_filtered;
        // Require consecutive synchronized samples at the new clock level.
        // Filter both edges so a high spike within a bit cannot split it.
        if (ps2_clk_sync[2] == ps2_clk_filtered) filter_count <= 0;
        else if (filter_count == FILTER_CYCLES-1) begin
            ps2_clk_filtered <= ps2_clk_sync[2];
            filter_count <= 0;
        end else filter_count <= filter_count + 1'b1;
        key_ready <= 1'b0;
        // A byte arriving on the timeout boundary still belongs to the event.
        // The timer also runs between a prefix and its following byte.
        if (ps2_clk_falling) begin
            timeout_count <= 0;
            if (bit_count == 4'd0) begin
                if (!ps2_data_sync[2]) begin
                    shift_reg[0] <= 1'b0;
                    bit_count <= 4'd1;
                end
            end else if (bit_count == 4'd10) begin
                bit_count <= 4'd0;
                // Odd parity covers the eight data bits and parity bit.
                if (ps2_data_sync[2] && (^shift_reg[9:1])) begin
                    if (shift_reg[8:1] == 8'he0) extended_pending <= 1'b1;
                    else if (shift_reg[8:1] == 8'hf0) release_pending <= 1'b1;
                    else begin
                        keycode <= shift_reg[8:1];
                        key_ready <= 1'b1;
                        key_extended <= extended_pending;
                        key_released <= release_pending;
                        extended_pending <= 1'b0;
                        release_pending <= 1'b0;
                    end
                end else begin
                    extended_pending <= 1'b0;
                    release_pending <= 1'b0;
                end
            end else begin
                shift_reg[bit_count] <= ps2_data_sync[2];
                bit_count <= bit_count + 1'b1;
            end
        end else if (receiving) begin
            if (timeout_count == TIMEOUT_CYCLES-1) begin
                bit_count <= 4'd0;
                timeout_count <= 0;
                extended_pending <= 1'b0;
                release_pending <= 1'b0;
            end else timeout_count <= timeout_count + 1'b1;
        end else timeout_count <= 0;
    end
end
endmodule
