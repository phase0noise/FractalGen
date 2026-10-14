`include "mandel_constants.vh"

module Coor_gen
#(parameter C_ADDR_WIDTH = `E_ADDR_WIDTH,
  parameter SCREEN_WIDTH = 640, parameter SCREEN_HEIGHT = 480,
  parameter QUALITY_TILE_HEIGHT = 240,
  parameter QUALITY_TILE_WIDTH = SCREEN_WIDTH,
  parameter QUALITY_COLUMNS = 2,
  parameter QUALITY_PROJECTION_HEIGHT = 960,
  parameter QUALITY_INITIAL_LEVEL = 0,
  parameter TRIM_QUALITY_EDGES = 0,
  parameter PROGRESSIVE = 0,
  parameter EXTERNAL_PAUSE = 0, parameter QUEUED = 0)
(
    input cclk,
    input [3:0] ckey,
    input creset,
    input pause,
    input queue_ready,
    input [`NUM_PROC-1:0] cdones,
    input [`NUM_PROC-1:0] cidle,
    output clatch_en,
    output reg [C_ADDR_WIDTH-1:0] cengine_addr,
    output [82:0] cword2engines,
    output frame,
    input [31:0] zoom_level,
    input signed [31:0] center_x,
    input signed [31:0] center_y,
    input lens_enable,
    input detail_enable,
    input deep_enable,
    input turbo_enable,
    input overrender_enable,
    input refine_enable,
    input [1:0] palette_select,
    input [7:0] palette_phase,
    input tile_ack,
    output reg detail_active,
    output reg deep_active,
    output reg turbo_active,
    output reg overrender_active,
    output reg overrender_done,
    output tile_done,
    output reg [2:0] tile_index,
    output reg normal_ready,
    output [31:0] sample_step,
    output reg [1:0] render_palette,
    output reg [7:0] render_phase,
    output [7:0] group_x,
    output [9:0] group_y,
    output reg [1:0] iteration_level,
    output reg [31:0] zoom_active,
    output reg signed [31:0] center_x_active,center_y_active,
    output reg lens_active
);

reg [10:0] x_value;
reg [9:0] y_value;
wire none_done = ~(|cdones);
wire all_idle = &cidle;
reg frame_hold;
reg [1:0] view_ready;
assign tile_done = frame_hold && all_idle && overrender_active &&
                   overrender_synced && !overrender_done;
wire [9:0] last_y = overrender_active ?
    (PROGRESSIVE ? QUALITY_TILE_HEIGHT*(8/QUALITY_COLUMNS)-1 : QUALITY_TILE_HEIGHT-1) : SCREEN_HEIGHT-1;
wire [10:0] last_x = overrender_active ?
    (PROGRESSIVE ? QUALITY_TILE_WIDTH*QUALITY_COLUMNS-1 : QUALITY_TILE_WIDTH-1) : SCREEN_WIDTH-1;
localparam COLUMN_BITS = $clog2(QUALITY_COLUMNS);
localparam QUALITY_HEIGHT = QUALITY_TILE_HEIGHT * (8 / QUALITY_COLUMNS);
wire [2:0] tile_column = tile_index & (QUALITY_COLUMNS-1);
wire [2:0] tile_row = tile_index >> COLUMN_BITS;

// View controls are adopted only at a frame boundary. This prevents a frame
// from being assembled from several different zoom or center values.
reg lens_meta, lens_synced;
reg [31:0] zoom_meta, zoom_synced;
reg signed [31:0] center_x_meta, center_x_synced;
reg signed [31:0] center_y_meta, center_y_synced;
reg detail_meta, detail_synced;
reg deep_meta, deep_synced;
reg turbo_meta, turbo_synced;
reg overrender_meta, overrender_synced;
reg refine_meta, refine_synced;
reg [1:0] palette_meta, palette_synced;

wire signed [42:0] active_zoom = {11'd0, zoom_active};

// Accumulating pixel*zoom preserves the normal projection exactly. Quality
// coordinates combine tile and pixel products before rounding. Factors 320 and
// 240 are shift/add networks, so normal coordinate generation uses no DSPs.
reg signed [42:0] x_product, y_product;
wire signed [42:0] active_x_offset =
    ((active_zoom <<< 8) + (active_zoom <<< 6)) >>> 9;
wire signed [42:0] active_y_offset =
    overrender_active ? ((active_zoom * (QUALITY_PROJECTION_HEIGHT/2)) >>> 10) :
    (((active_zoom <<< 8) - (active_zoom <<< 4)) >>> 9);
wire signed [42:0] tile_x_product = active_zoom * (PROGRESSIVE ? QUALITY_TILE_WIDTH : 640);
wire signed [42:0] raw_global_x_product = PROGRESSIVE ? x_product :
    x_product + tile_column * tile_x_product;
// Trim one source pixel from each adjoining edge, extending the nearest
// interior pixel into its place. Tags/storage retain the full rectangle:
// shortening a tile's stored dimensions would leave an unwritten gap.
wire signed [42:0] trimmed_x_product = raw_global_x_product +
    ((TRIM_QUALITY_EDGES && overrender_active && x_value==0 && tile_column!=0) ? active_zoom :
     (TRIM_QUALITY_EDGES && overrender_active && x_value==last_x && tile_column!=QUALITY_COLUMNS-1) ? -active_zoom : 43'sd0);
wire signed [42:0] base_x_wide =
    {{11{center_x_active[31]}}, center_x_active} +
    (overrender_active ? (global_x_product >>> 10) : (x_product >>> 9)) - active_x_offset;
wire signed [42:0] tile_row_product = active_zoom * (PROGRESSIVE ? QUALITY_TILE_HEIGHT : 240);
wire signed [42:0] raw_global_y_product = PROGRESSIVE ? y_product : y_product + tile_row * tile_row_product;
wire signed [42:0] trimmed_y_product = raw_global_y_product +
    ((TRIM_QUALITY_EDGES && overrender_active && y_value==0 && tile_row!=0) ? active_zoom :
     (TRIM_QUALITY_EDGES && overrender_active && y_value==last_y && tile_row!=(8/QUALITY_COLUMNS)-1) ? -active_zoom : 43'sd0);
reg signed [42:0] prepared_global_x, prepared_global_y;
wire signed [42:0] global_x_product = (TRIM_QUALITY_EDGES && !PROGRESSIVE) ? prepared_global_x : raw_global_x_product;
wire signed [42:0] global_y_product = (TRIM_QUALITY_EDGES && !PROGRESSIVE) ? prepared_global_y : raw_global_y_product;
assign group_x = x_value[10:3];
assign group_y = y_value;
// Round the complete global pixel coordinate once. Rounding the tile origin
// and its local coordinate separately introduces a discontinuity at seams.
wire signed [42:0] base_y_wide =
    {{11{center_y_active[31]}}, center_y_active} -
    (overrender_active ? (global_y_product >>> 10) : (y_product >>> 9)) + active_y_offset;
wire signed [31:0] base_x = base_x_wide[31:0];
wire signed [31:0] base_y = base_y_wide[31:0];

// Center-magnifying, hyperbolic-style radial lens. The radial factor rises
// smoothly from 0.5 at the center to 1.0 at the outer edge. Chebyshev radius
// with an inexpensive 4/3 Y correction keeps it visually close to circular.
wire [9:0] lens_pixel_x = overrender_active ?
    (PROGRESSIVE ? x_value[10:1] : ((x_value >> 1) + tile_column * 320)) : x_value[9:0];
wire [8:0] lens_pixel_y = overrender_active ?
    (PROGRESSIVE ? y_value[9:1] : ((y_value >> 1) + tile_row * 120)) : y_value[8:0];
wire signed [10:0] pixel_dx = $signed({1'b0, lens_pixel_x}) - 11'sd320;
wire signed [9:0]  pixel_dy = $signed({1'b0, lens_pixel_y}) - (overrender_active ? QUALITY_PROJECTION_HEIGHT/4 : 10'sd240);
wire [10:0] abs_dx = pixel_dx[10] ? -pixel_dx : pixel_dx;
wire [9:0]  abs_dy = pixel_dy[9] ? -pixel_dy : pixel_dy;
reg [10:0] prepared_abs_dx, prepared_radius;
reg [9:0] prepared_abs_dy;
wire [10:0] abs_y_wide = {1'b0, prepared_abs_dy};
wire [10:0] scaled_abs_dy = (abs_y_wide + (abs_y_wide >> 2)) +
    ((overrender_active && QUALITY_PROJECTION_HEIGHT==1024) ? 11'd0 : ((abs_y_wide >> 4) + (abs_y_wide >> 6)));
wire [10:0] lens_radius = (prepared_abs_dx > scaled_abs_dy) ? prepared_abs_dx : scaled_abs_dy;
wire [17:0] radius_extended = {7'd0, prepared_radius};
wire [17:0] lens_curve = ((radius_extended << 7) + (radius_extended << 6)) +
                       ((radius_extended << 3) + (radius_extended << 2)) +
                       radius_extended; // radius * 205
wire [8:0] lens_curve_scaled = lens_curve[17:9];
wire [8:0] lens_factor_unclamped = 9'd128 + lens_curve_scaled;
wire [8:0] lens_factor = (lens_factor_unclamped > 9'd256) ?
                         9'd256 : lens_factor_unclamped;

// Two small partial products leave all DSPs to the orbit engines and avoid
// putting the complete nine-bit multiplier's adder tree in one clock cycle.
function signed [42:0] lens_partial;
    input signed [32:0] value;
    input [4:0] factor;
    reg signed [42:0] extended_value;
    reg signed [42:0] partial [0:4];
    integer bit_index;
    begin
        extended_value = {{10{value[32]}}, value};
        for (bit_index = 0; bit_index < 5; bit_index = bit_index + 1)
            partial[bit_index] = factor[bit_index] ? (extended_value <<< bit_index) : 43'sd0;
        lens_partial = ((partial[0]+partial[1])+(partial[2]+partial[3])) + partial[4];
    end
endfunction

wire signed [42:0] lens_center_x = {{11{center_x_active[31]}}, center_x_active};
wire signed [42:0] lens_center_y = {{11{center_y_active[31]}}, center_y_active};
wire signed [32:0] base_sample_step = $signed({1'b0, overrender_active ? (zoom_active >> 11) : (zoom_active >> 10)});
reg [2:0] prepare_stage;
reg signed [31:0] prepared_base_x, prepared_base_y, output_x, output_y;
reg signed [32:0] prepared_relative_x, prepared_relative_y, prepared_step;
reg [8:0] prepared_factor;
reg signed [42:0] prepared_product_x, prepared_product_y, prepared_product_step;
reg signed [42:0] prepared_high_x, prepared_high_y, prepared_high_step;
reg [31:0] ready_sample_step;
wire signed [42:0] product_x = prepared_product_x + (prepared_high_x <<< 4);
wire signed [42:0] product_y = prepared_product_y + (prepared_high_y <<< 4);
wire signed [42:0] product_step = prepared_product_step + (prepared_high_step <<< 4);
wire signed [42:0] lens_x_wide = lens_center_x + (product_x >>> 8);
wire signed [42:0] lens_y_wide = lens_center_y + (product_y >>> 8);
assign sample_step = ready_sample_step;
// Quality workers need only the assembly-slot bits of these tags. The held
// global group metadata supplies the full SDRAM address after they drain.
assign cword2engines = {x_value[9:0], y_value[8:0], output_x, output_y};

// Bound the coordinate/lens path independently of the workers' orbit path.
// Coordinates and sample spacing are held together until an engine accepts
// them; counters advance only on that same acceptance edge.
always @(posedge cclk or posedge creset) begin
    if (creset) begin
        prepare_stage <= 3'd0;
        prepared_base_x <= 32'sd0; prepared_base_y <= 32'sd0;
        prepared_relative_x <= 33'sd0; prepared_relative_y <= 33'sd0;
        prepared_step <= 33'sd0; prepared_factor <= 9'd0;
        prepared_product_x <= 43'sd0; prepared_product_y <= 43'sd0;
        prepared_product_step <= 43'sd0;
        prepared_high_x <= 43'sd0; prepared_high_y <= 43'sd0;
        prepared_high_step <= 43'sd0;
        prepared_abs_dx <= 11'd0; prepared_abs_dy <= 10'd0; prepared_radius <= 11'd0;
        output_x <= 32'sd0; output_y <= 32'sd0; ready_sample_step <= 32'd0;
        prepared_global_x<=0; prepared_global_y<=0;
    end else if (frame_hold) prepare_stage <= 3'd0;
    else case (prepare_stage)
        3'd0: begin
            prepared_abs_dx <= abs_dx; prepared_abs_dy <= abs_dy;
            prepared_step <= base_sample_step;
            prepared_global_x<=trimmed_x_product; prepared_global_y<=trimmed_y_product;
            if(TRIM_QUALITY_EDGES && !PROGRESSIVE && overrender_active) prepare_stage<=3'd6;
            else if (lens_active) begin
                prepared_base_x <= base_x; prepared_base_y <= base_y;
                prepare_stage <= 3'd1;
            end
            else begin
                output_x <= base_x; output_y <= base_y;
                ready_sample_step <= base_sample_step[31:0];
                prepare_stage <= 3'd5;
            end
        end
        3'd6: begin
            prepared_base_x <= base_x; prepared_base_y <= base_y;
            if(lens_active) prepare_stage<=3'd1;
            else begin
                output_x<=base_x; output_y<=base_y;
                ready_sample_step<=base_sample_step[31:0]; prepare_stage<=3'd5;
            end
        end
        3'd1: begin
            prepared_relative_x <= {prepared_base_x[31], prepared_base_x} - {center_x_active[31], center_x_active};
            prepared_relative_y <= {prepared_base_y[31], prepared_base_y} - {center_y_active[31], center_y_active};
            prepared_radius <= lens_radius;
            prepare_stage <= 3'd2;
        end
        3'd2: begin
            prepared_factor <= lens_factor;
            prepare_stage <= 3'd3;
        end
        3'd3: begin
            prepared_product_x <= lens_partial(prepared_relative_x, {1'b0, prepared_factor[3:0]});
            prepared_product_y <= lens_partial(prepared_relative_y, {1'b0, prepared_factor[3:0]});
            prepared_product_step <= lens_partial(prepared_step, {1'b0, prepared_factor[3:0]});
            prepared_high_x <= lens_partial(prepared_relative_x, prepared_factor[8:4]);
            prepared_high_y <= lens_partial(prepared_relative_y, prepared_factor[8:4]);
            prepared_high_step <= lens_partial(prepared_step, prepared_factor[8:4]);
            prepare_stage <= 3'd4;
        end
        3'd4: begin
            output_x <= lens_x_wide[31:0]; output_y <= lens_y_wide[31:0];
            ready_sample_step <= product_step >>> 8;
            prepare_stage <= 3'd5;
        end
        3'd5: if (clatch_en) prepare_stage <= 3'd0;
    endcase
end

always @(posedge cclk or posedge creset) begin
    if (creset) begin
        lens_meta       <= 1'b0;
        lens_synced     <= 1'b0;
        lens_active     <= 1'b0;
        zoom_active     <= 32'd46976205;
        center_x_active <= -32'sd12582912;
        center_y_active <= 32'sd0;
        zoom_meta       <= 32'd0;
        zoom_synced     <= 32'd0;
        center_x_meta   <= 32'sd0;
        center_x_synced <= 32'sd0;
        center_y_meta   <= 32'sd0;
        center_y_synced <= 32'sd0;
        detail_meta     <= 1'b0;
        detail_synced   <= 1'b0;
        deep_meta       <= 1'b0;
        deep_synced     <= 1'b0;
        turbo_meta      <= 1'b0;
        turbo_synced    <= 1'b0;
        detail_active   <= 1'b0;
        deep_active     <= 1'b0;
        turbo_active    <= 1'b0;
        overrender_meta <= 1'b0;
        overrender_synced <= 1'b0;
        refine_meta <= 1'b0; refine_synced <= 1'b0;
        iteration_level <= 2'd0;
        overrender_active <= 1'b0;
        overrender_done <= 1'b0;
        tile_index <= 3'd0;
        normal_ready <= 1'b0;
        palette_meta <= 2'd0;
        palette_synced <= 2'd0;
        render_palette <= 2'd0;
        render_phase <= 8'd0;
        frame_hold      <= 1'b1;
        view_ready      <= 2'b00;
        x_value         <= 10'd0;
        y_value         <= 9'd0;
        x_product       <= 43'sd0;
        y_product       <= 43'sd0;
    end else begin
        view_ready <= {view_ready[0], 1'b1};
        lens_meta   <= lens_enable;
        lens_synced <= lens_meta;
        zoom_meta       <= zoom_level;
        zoom_synced     <= zoom_meta;
        center_x_meta   <= center_x;
        center_x_synced <= center_x_meta;
        center_y_meta   <= center_y;
        center_y_synced <= center_y_meta;
        detail_meta     <= detail_enable;
        detail_synced   <= detail_meta;
        deep_meta       <= deep_enable;
        deep_synced     <= deep_meta;
        turbo_meta      <= turbo_enable;
        turbo_synced    <= turbo_meta;
        overrender_meta <= overrender_enable;
        overrender_synced <= overrender_meta;
        refine_meta <= refine_enable; refine_synced <= refine_meta;
        palette_meta <= palette_select;
        palette_synced <= palette_meta;

        if (EXTERNAL_PAUSE && pause && !frame_hold) begin
            // Keep a partially dispatched group and its geometry intact.
            // Completed groups must still consume tile_ack below, releasing
            // LiveStore so scanout and screenshot DMA can keep running.
        end else if (frame_hold) begin
            // Do not mix generations in the framebuffer.  The next view is
            // adopted only after every context and result slot has drained.
            if (all_idle && (&view_ready) && overrender_active && overrender_synced && tile_ack && (!QUEUED || !overrender_done)) begin
                if (PROGRESSIVE) begin
                    // One continuous raster: no section counter, origin reset,
                    // overlap, or duplicated boundary pixels in the HD path.
                    if (x_value == last_x && y_value == last_y)
                        overrender_done <= 1'b1;
                    else begin
                        frame_hold <= 1'b0;
                        if (x_value == last_x) begin
                            x_value <= 11'd0;
                            x_product <= 43'sd0;
                            y_product <= y_product + active_zoom;
                            y_value <= y_value + 1'b1;
                        end else begin
                            x_value <= x_value + 1'b1;
                            x_product <= x_product + active_zoom;
                        end
                    end
                end else if (tile_index == 3'd7) overrender_done <= 1'b1;
                else begin
                    tile_index <= tile_index + 1'b1;
                    frame_hold <= 1'b0;
                end
            end else if (all_idle && (&view_ready) && overrender_active && overrender_synced) begin
                // Keep the captured geometry and colors across deeper passes.
                // Escaped samples produce the same result; unresolved samples
                // get a larger budget. The last complete image stays visible.
                if (PROGRESSIVE && overrender_done && refine_synced && iteration_level != 2'd3) begin
                    iteration_level <= iteration_level + 1'b1;
                    overrender_done <= 1'b0; frame_hold <= 1'b0;
                    x_value <= 10'd0; y_value <= 9'd0; tile_index <= 3'd0;
                    x_product <= 43'sd0; y_product <= 43'sd0;
                end
            end else if (all_idle && (&view_ready)) begin
                frame_hold      <= 1'b0;
                zoom_active     <= zoom_synced;
                center_x_active <= center_x_synced;
                center_y_active <= center_y_synced;
                lens_active     <= lens_synced;
                detail_active   <= detail_synced;
                deep_active     <= deep_synced;
                turbo_active    <= turbo_synced;
                overrender_active <= overrender_synced;
                overrender_done <= 1'b0;
                tile_index <= 3'd0;
                x_value <= 10'd0; y_value <= 9'd0;
                x_product <= 43'sd0; y_product <= 43'sd0;
                iteration_level <= overrender_synced ? QUALITY_INITIAL_LEVEL : (deep_synced ? 2'd2 : 2'd0);
                if (overrender_synced) normal_ready <= 1'b0;
                else if (!overrender_active) normal_ready <= 1'b1;
                render_palette <= palette_synced;
                render_phase <= palette_phase; // VGA now shares the render clock.
            end
        end else if (overrender_active && !overrender_synced) begin
            // Cancel after draining only the outstanding pixels, rather than
            // waiting for the remainder of an expensive quality frame.
            frame_hold <= 1'b1;
            x_value <= 10'd0;
            y_value <= 9'd0;
            x_product <= 43'sd0;
            y_product <= 43'sd0;
        end else if (clatch_en) begin
            if (PROGRESSIVE && overrender_active) begin
                if (QUEUED && x_value==last_x && y_value==last_y) frame_hold<=1'b1;
                else if (QUEUED && x_value==last_x) begin
                    x_value<=0;x_product<=0;y_product<=y_product+active_zoom;y_value<=y_value+1'b1;
                end else if (!QUEUED && x_value[2:0] == 3'd7) frame_hold <= 1'b1;
                else begin
                    x_value <= x_value + 1'b1;
                    x_product <= x_product + active_zoom;
                end
            end else if ((x_value == last_x) && (y_value == last_y)) begin
                frame_hold      <= 1'b1;
                x_product       <= 43'sd0;
                y_product       <= 43'sd0;
                x_value         <= 10'd0;
                y_value         <= 9'd0;
            end else if (y_value == last_y) begin
                x_product <= x_product + active_zoom;
                y_product <= 43'sd0;
                x_value <= x_value + 1'b1;
                y_value <= 9'd0;
            end else begin
                y_product <= y_product + active_zoom;
                y_value <= y_value + 1'b1;
            end
        end
    end
end

integer j;
always @(posedge cclk or posedge creset) begin
    if (creset) cengine_addr <= {C_ADDR_WIDTH{1'b0}};
    else begin
        cengine_addr <= {C_ADDR_WIDTH{1'b0}};
        for (j = `NUM_PROC-1; j >= 0; j = j - 1)
            if (cdones[j]) cengine_addr <= j[C_ADDR_WIDTH-1:0];
    end
end

// Hold coordinates until the registered selection actually has a free slot.
assign clatch_en = cdones[cengine_addr] && ~frame_hold && (prepare_stage == 3'd5) &&
                  (!QUEUED || !overrender_active || queue_ready) &&
                  !(EXTERNAL_PAUSE && pause);

assign frame = (x_value < 10'd100);

endmodule
