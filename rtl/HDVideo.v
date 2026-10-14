// VESA DMT 1280x1024 @ 60 Hz: 108 MHz, 1688x1066 total, positive sync.
// Eight RGB444 pixels occupy three words. Cache the next group while shifting
// out the current group, so the RAM read port needs only three clocks in eight.
module HDVideo #(parameter PROGRESSIVE = 0) (
    input clk, input reset, input enable,
    input [17:0] progress_gray,
    output reg line_request, output reg [9:0] line_y, output reg line_bank,
    input line_ack,
    output reg [9:0] buffer_address, input [31:0] buffer_q,
    output reg selected, output reg underflow,
    output frame_tick,
    output reg pixel_active,
    output reg [10:0] pixel_x,
    output reg [9:0] pixel_y,
    output reg [3:0] red, green, blue, output reg hsync, vsync
);
reg enable_meta, enable_sync;
(* async_reg = "true" *) reg [17:0] progress_meta, progress_sync;
reg [17:0] progress_binary;
reg [17:0] requested_progress, bank0_progress, bank1_progress;
reg [17:0] row_group_base;
reg [7:0] published_groups;
integer progress_bit;
reg ack_meta, ack_sync, ack_seen;
reg [10:0] tag0, tag1;
reg [10:0] h;
reg [10:0] v;
reg [31:0] cache0, cache1, cache2;
reg [95:0] pixels;
reg [8:0] next_group_word;
wire active_y = v >= 11'd41 && v < 11'd1065;
wire active = active_y && h >= 11'd360 && h < 11'd1640;
wire [9:0] y = v - 11'd41;
wire [2:0] position = h[2:0]; // Active start 360 is a multiple of eight.
wire line_valid = y[0] ? tag1 == {1'b0,y} : tag0 == {1'b0,y};
wire [10:0] x = h - 11'd360;
wire [17:0] row_groups = ({8'd0,y} << 7) + ({8'd0,y} << 5);
wire [17:0] bank_progress = y[0] ? bank1_progress : bank0_progress;
wire [7:0] group_column = h[10:3] - 8'd45;
wire pixel_published = !PROGRESSIVE || group_column < published_groups;
wire outstanding = line_request != ack_sync;
wire frame_end = h==11'd1687 && v==11'd1065;
assign frame_tick = selected && frame_end;

always @(*) begin
    buffer_address = {y[0], 9'd0};
    if (h == 11'd354) buffer_address = {y[0], 9'd0};
    else if (h == 11'd355) buffer_address = {y[0], 9'd1};
    else if (h == 11'd356) buffer_address = {y[0], 9'd2};
    else if (active && next_group_word < 9'd480) begin
        case (position)
            3'd0: buffer_address = {y[0], next_group_word};
            3'd1: buffer_address = {y[0], next_group_word + 9'd1};
            3'd2: buffer_address = {y[0], next_group_word + 9'd2};
            default: ;
        endcase
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        enable_meta <= 1'b0; enable_sync <= 1'b0;
        progress_meta<=0; progress_sync<=0; progress_binary<=0;
        requested_progress<=0; bank0_progress<=0; bank1_progress<=0;
        row_group_base<=0; published_groups<=0;
        ack_meta <= 1'b0; ack_sync <= 1'b0; ack_seen <= 1'b0;
        line_request <= 1'b0; line_y <= 10'd0; line_bank <= 1'b0;
        tag0 <= 11'd2047; tag1 <= 11'd2047;
        h <= 11'd0; v <= 11'd0;
        selected<=0;
        cache0 <= 32'd0; cache1 <= 32'd0; cache2 <= 32'd0; pixels <= 96'd0;
        next_group_word <= 9'd3;
        red <= 4'd0; green <= 4'd0; blue <= 4'd0;
        hsync <= 1'b1; vsync <= 1'b1; underflow <= 1'b0;
        pixel_active<=0; pixel_x<=0; pixel_y<=0;
    end else begin
        enable_meta <= enable; enable_sync <= enable_meta;
        // Timing runs continuously. Mode changes are committed only at the
        // end of a complete frame, so a short ready dropout cannot restart
        // the raster or splice preview and HD sync pulses together.
        hsync<=h<11'd112; vsync<=v<11'd3;
        if(frame_end) selected<=enable_sync;
        if(h==11'd1687) begin
            h<=0; v<=v==11'd1065 ? 11'd0 : v+1'b1;
        end else h<=h+1'b1;
        progress_meta<=progress_gray; progress_sync<=progress_meta;
        row_group_base<=row_groups;
        // Clamp a fetched row's publication frontier before the pixel path.
        // The frontier is captured at request time, so pixels completed after
        // the fetch cannot expose stale words in this line-buffer bank.
        if(bank_progress<=row_group_base) published_groups<=0;
        else if(bank_progress>=row_group_base+18'd160) published_groups<=8'd160;
        else published_groups<=bank_progress-row_group_base;
        for(progress_bit=0;progress_bit<18;progress_bit=progress_bit+1)
            progress_binary[progress_bit]<=^(progress_sync>>progress_bit);
        ack_meta <= line_ack; ack_sync <= ack_meta;
        if (!selected) begin
            next_group_word <= 9'd3;
            tag0 <= 11'd2047; tag1 <= 11'd2047;
            ack_seen <= ack_sync;
            red <= 4'd0; green <= 4'd0; blue <= 4'd0;
            underflow <= 1'b0;
            pixel_active<=0;
            bank0_progress<=0; bank1_progress<=0;
        end else begin
            if (ack_sync != ack_seen) begin
                ack_seen <= ack_sync;
                if (line_bank) begin tag1<=line_y; bank1_progress<=requested_progress; end
                else begin tag0<=line_y; bank0_progress<=requested_progress; end
            end
            if (h == 11'd0 && !outstanding) begin
                if (v == 11'd0) begin
                    line_y <= 10'd0; line_bank <= 1'b0; line_request <= ~line_request;
                    requested_progress<=progress_binary;
                end else if (active_y && y < 10'd1023) begin
                    line_y <= y + 1'b1; line_bank <= ~y[0]; line_request <= ~line_request;
                    requested_progress<=progress_binary;
                end
            end
            if (active_y) begin
                if (h == 11'd359) next_group_word <= 9'd3;
                if (h == 11'd355) cache0 <= buffer_q;
                if (h == 11'd356) cache1 <= buffer_q;
                if (h == 11'd357) cache2 <= buffer_q;
                if (h == 11'd358) pixels <= {cache2, cache1, cache0};
                if (active) begin
                    case (position)
                        3'd1: cache0 <= buffer_q;
                        3'd2: cache1 <= buffer_q;
                        3'd3: cache2 <= buffer_q;
                        default: ;
                    endcase
                    if (position == 3'd7) begin
                        pixels <= {cache2, cache1, cache0};
                        next_group_word <= next_group_word + 9'd3;
                    end
                    else pixels <= pixels >> 12;
                end
            end
            pixel_active<=active && line_valid && pixel_published;
            pixel_x<=x; pixel_y<=y;
            red <= (active && line_valid && pixel_published) ? pixels[11:8] : 4'd0;
            green <= (active && line_valid && pixel_published) ? pixels[7:4] : 4'd0;
            blue <= (active && line_valid && pixel_published) ? pixels[3:0] : 4'd0;
            if (h == 11'd360 && active_y && !line_valid) underflow <= 1'b1;
        end
    end
end
endmodule
