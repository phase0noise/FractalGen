// Preview navigation, one bookmark, and a latched HD request.
module ViewControl #(
    parameter DEBOUNCE_CYCLES = 500000,
    parameter REPEAT_CYCLES = 8000000
) (
    input clk,
    input reset,
    input [8:0] switches,
    input [3:0] keys,
    input [7:0] keycode,
    input key_ready,
    input key_extended,
    input key_released,
    output reg signed [31:0] center_x = -32'sd12582912,
    output reg signed [31:0] center_y = 32'sd0,
    output reg [31:0] zoom_level = 32'd46976205,
    output reg [7:0] settings = 8'd0,
    output reg [3:0] color_scheme = 4'd0,
    output reg [3:0] color_offset = 4'd0,
    output reg [1:0] burn_speed = 2'd2,
    output reg overrender = 1'b0,
    output reg bookmark_valid = 1'b0,
    output reg lens_enable = 1'b0
);

localparam [31:0] MIN_ZOOM = 32'd8192;
localparam [31:0] MAX_ZOOM = 32'd67108864;
localparam signed [31:0] CENTER_LIMIT = 32'sd1073741824;
reg [8:0] switch_meta, switch_sync, previous_switches;
reg [3:0] key_meta, key_sync, key_stable, previous_keys;
reg [19:0] debounce_count [0:3];
reg [23:0] repeat_count;
reg o_held, b_held, r_held, l_held, c_held, v_held, bookmark_lens;
reg signed [31:0] bookmark_x, bookmark_y;
reg [31:0] bookmark_zoom;
reg [3:0] bookmark_color;
reg [3:0] bookmark_offset;
reg [1:0] bookmark_speed;
wire [3:0] key_press = previous_keys & ~key_stable;
wire repeat_tick = (repeat_count == REPEAT_CYCLES-1);
wire [31:0] zoom_step = (zoom_level >> 4);
wire signed [31:0] pan_step = $signed(zoom_level >> 3);

function [31:0] zoom_in;
    input [31:0] value;
    input [31:0] step;
    begin
        zoom_in = (value <= MIN_ZOOM + step) ? MIN_ZOOM : value - step;
    end
endfunction
function [31:0] zoom_out;
    input [31:0] value;
    input [31:0] step;
    begin
        zoom_out = (value >= MAX_ZOOM - step) ? MAX_ZOOM : value + step;
    end
endfunction
function signed [31:0] pan;
    input signed [31:0] value;
    input signed [31:0] delta;
    reg signed [32:0] moved;
    begin
        moved = {value[31], value} + {delta[31], delta};
        if (moved > CENTER_LIMIT) pan = CENTER_LIMIT;
        else if (moved < -CENTER_LIMIT) pan = -CENTER_LIMIT;
        else pan = moved[31:0];
    end
endfunction

integer k;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        switch_meta <= 9'd0;
        switch_sync <= 9'd0;
        previous_switches <= 9'd0;
        key_meta <= 4'b1111;
        key_sync <= 4'b1111;
        key_stable <= 4'b1111;
        previous_keys <= 4'b1111;
        repeat_count <= 24'd0;
        for (k = 0; k < 4; k = k + 1) debounce_count[k] <= 20'd0;
    end else begin
        switch_meta <= switches;
        switch_sync <= switch_meta;
        previous_switches <= switch_sync;
        key_meta <= keys;
        key_sync <= key_meta;
        previous_keys <= key_stable;
        for (k = 0; k < 4; k = k + 1) begin
            if (key_sync[k] == key_stable[k]) debounce_count[k] <= 20'd0;
            else if (debounce_count[k] == DEBOUNCE_CYCLES-1) begin
                key_stable[k] <= key_sync[k];
                debounce_count[k] <= 20'd0;
            end else debounce_count[k] <= debounce_count[k] + 1'b1;
        end
        if (&key_stable || repeat_tick) repeat_count <= 24'd0;
        else repeat_count <= repeat_count + 1'b1;
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        center_x <= -32'sd12582912;
        center_y <= 32'sd0;
        zoom_level <= 32'd46976205;
        settings <= 8'd0;
        color_scheme <= 4'd0; color_offset <= 4'd0; burn_speed <= 2'd2;
        overrender <= 1'b0;
        bookmark_valid <= 1'b0;
        bookmark_x <= 32'sd0;
        bookmark_y <= 32'sd0;
        bookmark_zoom <= 32'd46976205;
        bookmark_color <= 4'd0; bookmark_offset <= 4'd0; bookmark_speed <= 2'd2;
        o_held <= 1'b0;
        b_held <= 1'b0;
        r_held <= 1'b0;
        c_held <= 1'b0; v_held <= 1'b0;
        l_held <= 1'b0; lens_enable <= 1'b0; bookmark_lens <= 1'b0;
    end else begin
        // Effects follow their switches. An SW0 edge sets the HD request.
        settings <= switch_sync[8:1];
        if (switch_sync[0] != previous_switches[0])
            overrender <= switch_sync[0];
        if (key_press[3]) overrender <= ~overrender;

        if (!overrender) begin
            if (key_press[0] || (!key_stable[0] && repeat_tick))
                zoom_level <= zoom_in(zoom_level, zoom_step);
            else if (key_press[1] || (!key_stable[1] && repeat_tick))
                zoom_level <= zoom_out(zoom_level, zoom_step);
            if (key_press[2]) center_y <= pan(center_y, pan_step);
        end

        if (key_ready && !key_extended) begin
            // PS/2 typematic repeats must not toggle O or overwrite a bookmark.
            case (keycode)
                8'h21: begin // C: next palette, one step per physical press
                    c_held <= !key_released;
                    if (!key_released && !c_held) color_scheme <= color_scheme+1'b1;
                end
                8'h2a: begin // V: previous palette
                    v_held <= !key_released;
                    if (!key_released && !v_held) color_scheme <= color_scheme-1'b1;
                end
                8'h16: if (!key_released) color_scheme <= 4'd0; // 1: Ocean
                8'h1e: if (!key_released) color_scheme <= 4'd1; // 2: Blue
                8'h26: if (!key_released) color_scheme <= 4'd2; // 3: Vivid Spectrum
                8'h25: if (!key_released) color_scheme <= 4'd3; // 4: Aurora
                8'h2e: if (!key_released) color_scheme <= 4'd4; // 5: Inferno
                8'h36: if (!key_released) color_scheme <= 4'd5; // 6: Candy
                8'h3d: if (!key_released) color_scheme <= 4'd6; // 7: Emerald
                8'h3e: if (!key_released) color_scheme <= 4'd7; // 8: Solar Gold
                8'h05: if (!key_released) color_scheme <= 4'd8;  // F1: Neon Tide
                8'h06: if (!key_released) color_scheme <= 4'd9;  // F2: Ember Ice
                8'h04: if (!key_released) color_scheme <= 4'd10; // F3: Acid
                8'h0c: if (!key_released) color_scheme <= 4'd11; // F4: Violet Fire
                8'h03: if (!key_released) color_scheme <= 4'd12; // F5: Peacock
                8'h0b: if (!key_released) color_scheme <= 4'd13; // F6: Ruby Mint
                8'h83: if (!key_released) color_scheme <= 4'd14; // F7: Copper Blue
                8'h0a: if (!key_released) color_scheme <= 4'd15; // F8: Prism Bands
                8'h54: if (!key_released) color_offset <= color_offset-1'b1; // [
                8'h5b: if (!key_released) color_offset <= color_offset+1'b1; // ]
                8'h4e, 8'h7b: if (!key_released && burn_speed!=0)
                    burn_speed <= burn_speed-1'b1; // -: Still/Slow/Fast/Wild
                8'h55, 8'h79: if (!key_released && burn_speed!=3)
                    burn_speed <= burn_speed+1'b1; // = / + (also keypad +)
                8'h44: begin // O: render/cancel
                    o_held <= !key_released;
                    if (!key_released && !o_held) overrender <= ~overrender;
                end
                8'h32: begin // B: save view, palette, speed and lens
                    b_held <= !key_released;
                    if (!key_released && !b_held) begin
                        bookmark_x <= center_x;
                        bookmark_y <= center_y;
                        bookmark_zoom <= zoom_level;
                        bookmark_color <= color_scheme;
                        bookmark_offset <= color_offset;
                        bookmark_speed <= burn_speed;
                        bookmark_lens <= lens_enable;
                        bookmark_valid <= 1'b1;
                    end
                end
                8'h2d: begin // R: restore bookmark and return to preview
                    r_held <= !key_released;
                    if (!key_released && !r_held && bookmark_valid) begin
                        center_x <= bookmark_x;
                        center_y <= bookmark_y;
                        zoom_level <= bookmark_zoom;
                        color_scheme <= bookmark_color;
                        color_offset <= bookmark_offset;
                        burn_speed <= bookmark_speed;
                        lens_enable <= bookmark_lens;
                        overrender <= 1'b0;
                    end
                end
                8'h4b: begin // L: toggle preview lens
                    l_held <= !key_released;
                    if (!key_released && !l_held && !overrender) lens_enable <= ~lens_enable;
                end
                8'h76, 8'h15: if (!key_released) begin // Escape / legacy Q
                    if (overrender) overrender <= 1'b0;
                    else begin
                        center_x <= -32'sd12582912;
                        center_y <= 32'sd0;
                        zoom_level <= 32'd46976205;
                    end
                end
                default: if (!key_released && !overrender) begin
                    case (keycode)
                        8'h1d: center_y <= pan(center_y, pan_step); // W
                        8'h1b: center_y <= pan(center_y, -pan_step); // S
                        8'h1c: center_x <= pan(center_x, -pan_step); // A
                        8'h23: center_x <= pan(center_x, pan_step); // D
                        8'h5a: zoom_level <= zoom_in(zoom_level, zoom_step);
                        8'h29: zoom_level <= zoom_out(zoom_level, zoom_step);
                        default: ;
                    endcase
                end
            endcase
        end
    end
end
endmodule
