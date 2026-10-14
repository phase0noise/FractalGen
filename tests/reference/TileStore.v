// Shared native SDRAM client. Upload eight 640x240 RGB444 tiles, packing
// eight pixels into three 32-bit words. During display, fetch one scanline
// into the unused line-buffer bank using at most 128-word read bursts.
module TileStore #(
    parameter TILE_WIDTH = 640, parameter TILE_HEIGHT = 240,
    parameter STARTUP_CYCLES = 40000
) (
    input clk, input reset,
    input tile_done, input [2:0] tile_index, output reg tile_ack,
    output tile_reading, output reg [17:0] tile_address, input [15:0] tile_q,
    input display_ready,
    input line_request, input [9:0] line_y, input line_bank,
    output reg line_ack,
    output reg line_write, output reg [9:0] line_write_address, output reg [31:0] line_write_data,
    output reg word_rd, output reg word_wr, output reg [23:0] word_addr,
    output reg [31:0] word_data, output [3:0] word_wstrb, output reg [7:0] word_burst_len,
    input word_busy, input word_valid, input [31:0] word_q
);
localparam ROW_WORDS = TILE_WIDTH * 2 * 12 / 32;
localparam TILE_WORDS = TILE_WIDTH * 12 / 32;
localparam S_INIT=0, S_IDLE=1, S_ADDR=2, S_WAIT=3, S_CAPTURE=4,
    S_WRITE=5, S_WRITE_BUSY=6, S_WRITE_DONE=7, S_TILE_END=8,
    S_READ=9, S_READ_BUSY=10, S_READ_DATA=11, S_READ_NEXT=12;
reg [3:0] state;
reg [15:0] startup;
reg [95:0] packed_pixels;
reg [2:0] pixel_in_group;
reg [1:0] word_in_group;
reg [17:0] pixel_address;
reg [8:0] tile_row;
reg [6:0] group_x;
reg [23:0] row_address;
reg request_meta, request_sync;
reg held_request, held_bank;
reg [23:0] line_base;
reg [9:0] words_received;
wire [9:0] words_remaining = ROW_WORDS - words_received;
assign word_wstrb = 4'b1111;
assign tile_reading = state >= S_ADDR && state <= S_WRITE_DONE;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state <= S_INIT; startup <= 16'd0;
        tile_ack <= 1'b0; tile_address <= 18'd0;
        pixel_address <= 18'd0; tile_row <= 9'd0; group_x <= 7'd0;
        packed_pixels <= 96'd0; pixel_in_group <= 3'd0; word_in_group <= 2'd0;
        row_address <= 24'd0;
        request_meta <= 1'b0; request_sync <= 1'b0;
        held_request <= 1'b0; held_bank <= 1'b0; line_ack <= 1'b0;
        line_base <= 24'd0; words_received <= 10'd0;
        line_write <= 1'b0; line_write_address <= 10'd0; line_write_data <= 32'd0;
        word_rd <= 1'b0; word_wr <= 1'b0;
        word_addr <= 24'd0; word_data <= 32'd0; word_burst_len <= 8'd0;
    end else begin
        request_meta <= line_request; request_sync <= request_meta;
        tile_ack <= 1'b0; word_rd <= 1'b0; word_wr <= 1'b0; line_write <= 1'b0;
        if (!display_ready && state < S_READ) line_ack <= request_sync;
        if (state >= S_READ && word_valid) begin
            line_write <= 1'b1;
            line_write_address <= {held_bank, words_received[8:0]};
            line_write_data <= word_q;
            words_received <= words_received + 1'b1;
        end
        case (state)
            S_INIT: if (startup == STARTUP_CYCLES-1) state <= S_IDLE;
                    else startup <= startup + 1'b1;
            S_IDLE: if (!word_busy) begin
                if (tile_done) begin
                    pixel_address <= 18'd0; tile_row <= 9'd0; group_x <= 7'd0;
                    row_address <= (tile_index[2:1] * TILE_HEIGHT) * ROW_WORDS +
                                   (tile_index[0] ? TILE_WORDS : 0);
                    pixel_in_group <= 3'd0; state <= S_ADDR;
                end else if (display_ready && request_sync != line_ack) begin
                    // The source holds this bus from request until acknowledgement.
                    held_request <= request_sync; held_bank <= line_bank;
                    line_base <= line_y * ROW_WORDS;
                    words_received <= 10'd0; state <= S_READ;
                end
            end
            S_ADDR: begin tile_address <= pixel_address; state <= S_WAIT; end
            S_WAIT: state <= S_CAPTURE;
            S_CAPTURE: begin
                packed_pixels[pixel_in_group*12 +: 12] <= tile_q[11:0];
                pixel_address <= pixel_address + 1'b1;
                if (pixel_in_group == 3'd7) begin word_in_group <= 2'd0; state <= S_WRITE; end
                else begin pixel_in_group <= pixel_in_group + 1'b1; state <= S_ADDR; end
            end
            S_WRITE: if (!word_busy) begin
                word_addr <= row_address + group_x * 3 + word_in_group;
                case (word_in_group)
                    2'd0: word_data <= packed_pixels[31:0];
                    2'd1: word_data <= packed_pixels[63:32];
                    default: word_data <= packed_pixels[95:64];
                endcase
                word_wr <= 1'b1; state <= S_WRITE_BUSY;
            end
            S_WRITE_BUSY: if (word_busy) state <= S_WRITE_DONE;
            S_WRITE_DONE: if (!word_busy) begin
                if (!tile_done) state <= S_IDLE; // Cancel after the pending write.
                else if (word_in_group != 2'd2) begin
                    word_in_group <= word_in_group + 1'b1; state <= S_WRITE;
                end else if (group_x == TILE_WIDTH/8-1) begin
                    if (tile_row == TILE_HEIGHT-1) begin tile_ack <= 1'b1; state <= S_TILE_END; end
                    else begin
                        tile_row <= tile_row + 1'b1; row_address <= row_address + ROW_WORDS;
                        group_x <= 7'd0; pixel_in_group <= 3'd0; state <= S_ADDR;
                    end
                end else begin
                    group_x <= group_x + 1'b1; pixel_in_group <= 3'd0; state <= S_ADDR;
                end
            end
            S_TILE_END: if (!tile_done) state <= S_IDLE;
            S_READ: if (!word_busy) begin
                word_addr <= line_base + words_received;
                word_burst_len <= (words_remaining > 10'd128) ? 8'd127 : words_remaining - 1'b1;
                word_rd <= 1'b1; state <= S_READ_BUSY;
            end
            S_READ_BUSY: if (word_busy) state <= S_READ_DATA;
            S_READ_DATA: if (!word_busy) state <= S_READ_NEXT;
            S_READ_NEXT: begin
                if (words_received == ROW_WORDS || !display_ready) begin
                    line_ack <= held_request; state <= S_IDLE;
                end else state <= S_READ;
            end
            default: state <= S_INIT;
        endcase
    end
end
endmodule
