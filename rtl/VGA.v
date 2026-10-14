// 640x480 preview with a 25 MHz pixel enable in the 75 MHz render domain.
// Sharing this domain permits safe borrowing of the RAM read port for tiles.
module VGA (
    input clk, input reset,
    input [15:0] framebuffer_q,
    output reg [17:0] framebuffer_address,
    input [1:0] palette_select,
    input palette_cycle, input fast_cycle, input palette_freeze,
    input visible,
    output reg [7:0] current_palette_phase,
    output reg [8:0] scan_y, output reg scan_active,
    output reg [10:0] pixel_x,
    output frame_tick, output reg pixel_tick,
    output read_borrow_ok,
    output reg [3:0] red, green, blue,
    output reg hsync, vsync
);
reg [1:0] pixel_divider;
reg [9:0] h, v;
reg lane;
reg [7:0] palette_index;
reg [2:0] phase_divider;
reg freeze_meta, freeze_sync;
reg cycle_meta, cycle_sync;
reg fast_meta, fast_sync;
reg [1:0] palette_meta, palette_sync;
wire pixel_enable = (pixel_divider == 2'd2);
assign frame_tick = pixel_enable && h==10'd799 && v==10'd524;
wire [9:0] next_h = (h == 10'd799) ? 10'd0 : h + 1'b1;
wire [9:0] next_v = (h == 10'd799) ? ((v == 10'd524) ? 10'd0 : v + 1'b1) : v;
wire active = next_h >= 10'd144 && next_h < 10'd784 && next_v >= 10'd35 && next_v < 10'd515;
wire [9:0] x = next_h - 10'd144;
wire [8:0] y = next_v - 10'd35;
// Prepare the following pixel's address on the current pixel-enable edge.
// The next cycle clocks this address into RAM, the second captures its byte,
// and the third outputs its mapped color. Registering before the RAM removes
// counter arithmetic from the 304-block address/enable fanout.
wire [9:0] fetch_h = (h >= 10'd798) ? {9'd0,h[0]} : h + 10'd2;
wire [9:0] fetch_v = (h >= 10'd798) ? ((v == 10'd524) ? 10'd0 : v + 1'b1) : v;
wire fetch_active = fetch_h >= 10'd144 && fetch_h < 10'd784 && fetch_v >= 10'd35 && fetch_v < 10'd515;
// One RAM read may be borrowed here; the following palette capture is blank.
assign read_borrow_ok = !active && !fetch_active && pixel_divider==0;
wire [9:0] fetch_x = fetch_h - 10'd144;
wire [8:0] fetch_y = fetch_v - 10'd35;
wire [17:0] fetch_row = ({9'd0, fetch_y} << 8) + ({9'd0, fetch_y} << 6);
wire [7:0] index = lane ? framebuffer_q[15:8] : framebuffer_q[7:0];
wire [23:0] bgr;
ColorMapper mapper (.index(palette_index), .palette(palette_sync), .phase(current_palette_phase), .bgr(bgr));

always @(posedge clk or posedge reset) begin
    if (reset) begin
        pixel_divider <= 2'd0;
        h <= 10'd0; v <= 10'd0;
        lane <= 1'b0;
        palette_index <= 8'hfe;
        framebuffer_address <= 18'd0;
        scan_y <= 9'd0; scan_active <= 1'b0;
        pixel_x <= 11'd0;
        pixel_tick <= 1'b0;
        current_palette_phase <= 8'd0;
        phase_divider <= 3'd0;
        freeze_meta <= 1'b0; freeze_sync <= 1'b0;
        cycle_meta <= 1'b0; cycle_sync <= 1'b0;
        fast_meta <= 1'b0; fast_sync <= 1'b0;
        palette_meta <= 2'd0; palette_sync <= 2'd0;
        red <= 4'd0; green <= 4'd0; blue <= 4'd0;
        hsync <= 1'b0; vsync <= 1'b0;
    end else begin
        pixel_tick <= pixel_enable;
        freeze_meta <= palette_freeze; freeze_sync <= freeze_meta;
        cycle_meta <= palette_cycle; cycle_sync <= cycle_meta;
        fast_meta <= fast_cycle; fast_sync <= fast_meta;
        palette_meta <= palette_select; palette_sync <= palette_meta;
        lane <= x[0];
        // Register the settled byte one cycle before its pixel-enable edge.
        // This separates the staging RAM's output mux from palette arithmetic.
        if (pixel_divider == 2'd1) palette_index <= index;
        pixel_divider <= pixel_enable ? 2'd0 : pixel_divider + 1'b1;
        if (!freeze_sync && !cycle_sync) begin
            current_palette_phase <= 8'd0;
            phase_divider <= 3'd0;
        end
        if (pixel_enable) begin
            framebuffer_address <= fetch_active ? fetch_row + {9'd0,fetch_x[9:1]} : 18'd0;
            h <= next_h; v <= next_v;
            scan_y <= next_v - 10'd35; scan_active <= active;
            pixel_x <= {1'b0,x};
            hsync <= (next_h >= 10'd96);
            vsync <= (next_v >= 10'd2);
            red <= (visible && active) ? bgr[7:4] : 4'd0;
            green <= (visible && active) ? bgr[15:12] : 4'd0;
            blue <= (visible && active) ? bgr[23:20] : 4'd0;
            if (h == 10'd799 && v == 10'd524 && cycle_sync && !freeze_sync) begin
                phase_divider <= phase_divider + 1'b1;
                if (fast_sync) current_palette_phase <= current_palette_phase + 8'd4;
                else if (phase_divider == 3'd7) current_palette_phase <= current_palette_phase + 1'b1;
            end
        end
    end
end
endmodule
