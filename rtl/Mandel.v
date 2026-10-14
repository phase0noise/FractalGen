`include "mandel_constants.vh"
module Mandel #(parameter SCREENSHOT_UHD_WIDTH=3840,SCREENSHOT_UHD_HEIGHT=2160) (
    input [9:0] SW, input [3:0] KEY, output [9:0] LEDR, input CLOCK_50,
    output [3:0] VGA_B, VGA_G, VGA_R, output VGA_HS, VGA_VS,
    inout PS2_CLK, PS2_DAT,
    output SD_CLK,SD_CMD,inout [3:0] SD_DATA,
    output [12:0] DRAM_ADDR, output [1:0] DRAM_BA,
    output DRAM_CAS_N, DRAM_CKE, DRAM_CLK, DRAM_CS_N,
    inout [15:0] DRAM_DQ,
    output DRAM_LDQM, DRAM_RAS_N, DRAM_UDQM, DRAM_WE_N
);
wire top_reset = SW[9];
wire engine_clock, pixel_hd_clock, system_locked, video_locked;
RenderClocks clocks (
    .refclk(CLOCK_50), .reset(top_reset), .engine_clk(engine_clock),
    .sdram_clk(DRAM_CLK), .pixel_hd_clk(pixel_hd_clock),
    .engine_locked(system_locked), .pixel_locked(video_locked)
);
reg [2:0] engine_reset_release = 3'b111, video_reset_release = 3'b111;
wire engine_reset_async = top_reset || !system_locked;
wire video_reset_async = top_reset || !video_locked;
always @(posedge engine_clock or posedge engine_reset_async)
    if (engine_reset_async) engine_reset_release <= 3'b111;
    else engine_reset_release <= {engine_reset_release[1:0], 1'b0};
always @(posedge pixel_hd_clock or posedge video_reset_async)
    if (video_reset_async) video_reset_release <= 3'b111;
    else video_reset_release <= {video_reset_release[1:0], 1'b0};
wire engine_reset = engine_reset_release[2];
wire video_reset = video_reset_release[2];

wire [7:0] ps2_keycode;
wire ps2_key_ready, ps2_key_extended, ps2_key_released;
keyboard kb_inst (
    .clk(CLOCK_50), .reset(top_reset), .ps2_clk(PS2_CLK), .ps2_data(PS2_DAT),
    .keycode(ps2_keycode), .key_ready(ps2_key_ready),
    .key_extended(ps2_key_extended), .key_released(ps2_key_released)
);
wire signed [31:0] center_x, center_y;
wire [31:0] zoom_level;
wire [7:0] settings;
wire [3:0] color_scheme;
wire [3:0] color_offset;
wire [1:0] burn_speed;
wire overrender_request, bookmark_valid;
wire lens_enable;
ViewControl controls (
    .clk(CLOCK_50), .reset(top_reset), .switches(SW[8:0]), .keys(KEY),
    .keycode(ps2_keycode), .key_ready(ps2_key_ready),
    .key_extended(ps2_key_extended), .key_released(ps2_key_released),
    .center_x(center_x), .center_y(center_y), .zoom_level(zoom_level),
    .settings(settings), .color_scheme(color_scheme), .color_offset(color_offset), .burn_speed(burn_speed),
    .overrender(overrender_request), .bookmark_valid(bookmark_valid), .lens_enable(lens_enable)
);
reg request_meta, request_sync;
always @(posedge engine_clock or posedge engine_reset)
    if (engine_reset) begin request_meta <= 1'b0; request_sync <= 1'b0; end
    else begin request_meta <= overrender_request; request_sync <= request_meta; end

wire [`NUM_PROC-1:0] dones, engine_idle, req_ack_bus, top_eng_req;
wire latch, write_enable, top_frame;
wire [`E_ADDR_WIDTH-1:0] engine_address;
wire [82:0] coordinate_word;
wire [34:0] result_word;
reg commit_valid, commit_quality;
reg [34:0] commit_word;
reg buffer_write;
reg [15:0] buffer_data;
reg [17:0] buffer_write_address;
reg [1:0] buffer_byte_enable;
reg buffer_quality;
wire writes_drained = !commit_valid && !buffer_write;
wire [`NUM_PROC*35-1:0] engine_words;
wire detail_active, deep_active, turbo_active, quality_active, quality_done, normal_ready;
wire tile_done, tile_ack;
wire [2:0] tile_index;
wire [31:0] sample_step;
wire [1:0] render_palette;
wire [7:0] render_phase, palette_phase;
wire [8:0] preview_scan_y;
wire preview_scan_active;
wire [7:0] group_x;
wire [9:0] group_y;
wire [1:0] iteration_level;
wire signed [31:0] render_center_x,render_center_y;
wire [31:0] render_zoom;
wire render_lens;
wire screenshot_busy,render_lock,uhd_start,uhd_busy,uhd_done,uhd_cancelled,job_cancel;
wire [7:0] screenshot_error;
wire screenshot_finished;
wire [3:0] saved_scheme;
wire [3:0] saved_offset;
wire [7:0] saved_effects;
wire [56:0] saved_phases,preview_phase_state,hd_phase_state;
wire signed [31:0] screenshot_x,screenshot_y;
wire [31:0] screenshot_zoom;
wire screenshot_lens,fs_start,fs_done,fs_ready,begin_payload;
wire [7:0] fs_error;
wire [31:0] screenshot_size;
wire [1:0] screenshot_mode;
wire ultra_owner=uhd_busy || uhd_start;
wire ultra_latch;
wire [`E_ADDR_WIDTH-1:0] ultra_engine_address;
wire [82:0] ultra_coordinate_word;
wire [31:0] ultra_sample_step;
wire [1:0] hd_dispatch_slot,ultra_dispatch_slot;
wire hd_queue_ready,hd_queue_empty,hd_group_valid;
wire [95:0] hd_group_pixels;
wire [23:0] hd_group_base;
wire [`E_ADDR_WIDTH-1:0] result_engine;
reg [1:0] worker_slot[0:`NUM_PROC-1];
reg [1:0] commit_slot,buffer_slot;
wire workers_latch=ultra_owner ? ultra_latch : latch;
wire [`E_ADDR_WIDTH-1:0] workers_address=ultra_owner ? ultra_engine_address : engine_address;
wire [82:0] workers_coordinate=ultra_owner ? ultra_coordinate_word : coordinate_word;
reg commit_ultra,buffer_ultra;
Coor_gen #(.PROGRESSIVE(1), .QUALITY_TILE_WIDTH(320), .QUALITY_TILE_HEIGHT(512),
    .QUALITY_COLUMNS(4), .QUALITY_PROJECTION_HEIGHT(1024),
    .QUALITY_INITIAL_LEVEL(2), .TRIM_QUALITY_EDGES(0),.EXTERNAL_PAUSE(1),.QUEUED(1)) u1 (
    .cclk(engine_clock), .ckey(KEY), .creset(engine_reset),
    .pause(render_lock),
    .queue_ready(hd_queue_ready),
    .cdones(dones), .cidle(engine_idle & {`NUM_PROC{writes_drained}}), .clatch_en(latch),
    .cengine_addr(engine_address), .cword2engines(coordinate_word), .frame(top_frame),
    .zoom_level(zoom_level), .center_x(center_x), .center_y(center_y),
    .lens_enable(lens_enable), .detail_enable(1'b1), .deep_enable(1'b0),
    .turbo_enable(1'b1), .overrender_enable(overrender_request),
    .refine_enable(1'b0),
    .palette_select(2'd0), .palette_phase(8'd0),
    .detail_active(detail_active), .deep_active(deep_active), .turbo_active(turbo_active),
    .overrender_active(quality_active), .overrender_done(quality_done),
    .tile_done(tile_done), .tile_ack(hd_queue_empty), .tile_index(tile_index), .normal_ready(normal_ready),
    .sample_step(sample_step), .render_palette(render_palette), .render_phase(render_phase),
    .group_x(group_x), .group_y(group_y), .iteration_level(iteration_level),
    .center_x_active(render_center_x),.center_y_active(render_center_y),
    .zoom_active(render_zoom),.lens_active(render_lens)
);
genvar i;
generate for (i = 0; i < `NUM_PROC; i = i + 1) begin : eng
    localparam [31:0] ENGINE_ID = i;
    RenderWorker #(.ADAPTIVE(1)) worker (
        .my_addr(ENGINE_ID[`E_ADDR_WIDTH-1:0]), .engine_addr(workers_address),
        .in_word(workers_coordinate), .latch_en(workers_latch), .eRST(engine_reset), .Engine_CLK(engine_clock),
        .req_ack(req_ack_bus[i]), .detail_enable(ultra_owner ? 1'b1 : detail_active), .deep_enable(deep_active),
        .turbo_enable(ultra_owner ? 1'b0 : turbo_active), .overrender_enable(quality_active || ultra_owner),
        .sample_step(ultra_owner ? ultra_sample_step : sample_step),
        .iteration_level(ultra_owner ? 2'd2 : iteration_level),
        .palette(ultra_owner ? 2'd0 : render_palette), .palette_phase(ultra_owner ? 8'd0 : render_phase),
        .out_word(engine_words[i*35 +: 35]), .available(dones[i]),
        .idle(engine_idle[i]), .service_req(top_eng_req[i])
    );
    always @(posedge engine_clock or posedge engine_reset)
        if(engine_reset) worker_slot[i]<=0;
        else if(workers_latch && workers_address==ENGINE_ID && (quality_active || ultra_owner))
            worker_slot[i]<=ultra_owner ? ultra_dispatch_slot : hd_dispatch_slot;
end endgenerate
ResultArbiter results (
    .engine_req(top_eng_req), .engine_words(engine_words), .scanline(preview_scan_y),
    .scan_active(preview_scan_active && !quality_active && !ultra_owner), .req_ack(req_ack_bus),
    .selected_word(result_word), .selected_engine(result_engine), .write_enable(write_enable)
);
wire [18:0] result_x = {9'd0, commit_word[34:25]};
wire [18:0] result_y = {10'd0, commit_word[24:16]};
wire [18:0] byte_address = result_x + (result_y << 9) + (result_y << 7);
// Acknowledge into a registered commit slot, then calculate the RAM address
// in the next stage. This separates scanline arbitration from the 304-block
// write fanout. Frame/tile boundaries also wait for these writes to drain.
always @(posedge engine_clock or posedge engine_reset) begin
    if (engine_reset) begin
        commit_valid <= 1'b0; commit_quality <= 1'b0; commit_word <= 35'd0;
        commit_ultra<=0;buffer_ultra<=0;
        commit_slot<=0;buffer_slot<=0;
        buffer_write <= 1'b0; buffer_data <= 16'd0;
        buffer_write_address <= 18'd0; buffer_byte_enable <= 2'b00;
        buffer_quality <= 1'b0;
    end else begin
        commit_valid <= write_enable;
        if (write_enable) begin commit_word <= result_word; commit_quality <= quality_active || ultra_owner;commit_ultra<=ultra_owner;commit_slot<=worker_slot[result_engine];end
        buffer_write <= commit_valid;
        buffer_quality <= commit_quality;
        buffer_ultra<=commit_ultra;
        buffer_slot<=commit_slot;
        if (commit_valid) begin
            buffer_data <= commit_quality ? commit_word[15:0] : {2{commit_word[7:0]}};
            buffer_write_address <= commit_quality ? byte_address[17:0] : byte_address[18:1];
            buffer_byte_enable <= commit_quality ? 2'b11 : (byte_address[0] ? 2'b10 : 2'b01);
        end
    end
end
wire [17:0] preview_address;
wire [15:0] framebuffer_q;
wire screenshot_preview_request,screenshot_preview_accepted,preview_borrow_ok;
wire [17:0] screenshot_preview_address;
assign screenshot_preview_accepted=screenshot_preview_request && preview_borrow_ok;
FrameBuffer staging (
    .clk(engine_clock), .data(buffer_data), .wraddress(buffer_write_address),
    .byteena(buffer_byte_enable), .wren(buffer_write && !buffer_quality),
    .rdaddress(screenshot_preview_accepted ? screenshot_preview_address : preview_address), .q(framebuffer_q)
);
wire [3:0] preview_r, preview_g, preview_b, hd_r, hd_g, hd_b, raw_hd_r, raw_hd_g, raw_hd_b;
wire preview_hs, preview_vs, hd_hs, hd_vs, raw_hd_hs, raw_hd_vs;
wire [3:0] raw_preview_r,raw_preview_g,raw_preview_b;
wire raw_preview_hs,raw_preview_vs,preview_frame_tick,preview_pixel_tick;
wire [10:0] preview_x;
wire preview_visible = normal_ready && !request_sync;
wire hd_selected, raw_hd_selected, hd_underflow, hd_frame_tick;
VGA preview (
    .clk(engine_clock), .reset(engine_reset), .framebuffer_q(framebuffer_q),
    .framebuffer_address(preview_address), .palette_select(2'd0),
    .palette_cycle(1'b0), .fast_cycle(1'b0), .palette_freeze(overrender_request),
    .visible(preview_visible), .current_palette_phase(palette_phase),
    .scan_y(preview_scan_y), .scan_active(preview_scan_active),
    .pixel_x(preview_x), .frame_tick(preview_frame_tick), .pixel_tick(preview_pixel_tick),
    .read_borrow_ok(preview_borrow_ok),
    .red(raw_preview_r), .green(raw_preview_g), .blue(raw_preview_b),
    .hsync(raw_preview_hs), .vsync(raw_preview_vs)
);
HDColorEffects #(.SMOOTH_VIVID(1)) preview_effects (
    .clk(engine_clock), .reset(engine_reset), .enabled(preview_visible), .frame_tick(preview_frame_tick),
    .input_red(raw_preview_r), .input_green(raw_preview_g), .input_blue(raw_preview_b),
    .input_hsync(raw_preview_hs), .input_vsync(raw_preview_vs),
    .color_scheme(color_scheme), .color_offset(color_offset), .burn_speed(burn_speed),
    .burn_enable(settings[0]), .stochastic_burn(settings[1]),
    .morph(settings[3]), .prism(settings[2]), .glow(settings[4]), .pixel_tick(preview_pixel_tick),
    .vivid(settings[7]), .fuzz(settings[5]),
    .pixel_active(preview_scan_active && preview_visible), .pixel_x(preview_x), .pixel_y({1'b0,preview_scan_y}),
    .phase_values(57'd0),.phase_state(preview_phase_state),
    .red(preview_r), .green(preview_g), .blue(preview_b), .hsync(), .vsync(), .selected()
);
VideoTimingDelay preview_timing (
    .clk(engine_clock), .reset(engine_reset), .input_hsync(raw_preview_hs), .input_vsync(raw_preview_vs),
    .input_selected(preview_visible), .hsync(preview_hs), .vsync(preview_vs), .selected()
);

wire display_ready;
wire [17:0] progress_gray;
wire raw_hd_active;
wire [10:0] raw_hd_x;
wire [9:0] raw_hd_y;
wire line_request, line_ack, line_bank, line_write;
wire [9:0] line_y, line_write_address, line_read_address;
wire [31:0] line_write_data, line_q;
LineBuffer scanlines (
    .write_clk(engine_clock), .write_enable(line_write), .write_address(line_write_address),
    .write_data(line_write_data), .read_clk(pixel_hd_clock),
    .read_address(line_read_address), .read_data(line_q)
);
HDVideo #(.PROGRESSIVE(1)) hd (
    .clk(pixel_hd_clock), .reset(video_reset), .enable(display_ready),
    .progress_gray(progress_gray),
    .line_request(line_request), .line_y(line_y), .line_bank(line_bank), .line_ack(line_ack),
    .buffer_address(line_read_address), .buffer_q(line_q), .selected(raw_hd_selected),
    .frame_tick(hd_frame_tick), .underflow(hd_underflow),
    .pixel_active(raw_hd_active), .pixel_x(raw_hd_x), .pixel_y(raw_hd_y),
    .red(raw_hd_r), .green(raw_hd_g), .blue(raw_hd_b), .hsync(raw_hd_hs), .vsync(raw_hd_vs)
);
HDColorEffects #(.SMOOTH_VIVID(1)) effects (
    .clk(pixel_hd_clock), .reset(video_reset), .enabled(raw_hd_selected), .frame_tick(hd_frame_tick),
    .input_red(raw_hd_r), .input_green(raw_hd_g), .input_blue(raw_hd_b),
    .input_hsync(raw_hd_hs), .input_vsync(raw_hd_vs),
    .color_scheme(color_scheme), .color_offset(color_offset), .burn_speed(burn_speed),
    .burn_enable(settings[0]), .stochastic_burn(settings[1]),
    .morph(settings[3]), .prism(settings[2]), .glow(settings[4]), .pixel_tick(1'b1),
    .vivid(settings[7]), .fuzz(settings[5]),
    .pixel_active(raw_hd_active), .pixel_x(raw_hd_x), .pixel_y(raw_hd_y),
    .phase_values(57'd0),.phase_state(hd_phase_state),
    .red(hd_r), .green(hd_g), .blue(hd_b), .hsync(), .vsync(), .selected()
);
VideoTimingDelay hd_timing (
    .clk(pixel_hd_clock), .reset(video_reset), .input_hsync(raw_hd_hs), .input_vsync(raw_hd_vs),
    .input_selected(raw_hd_selected), .hsync(hd_hs), .vsync(hd_vs), .selected(hd_selected)
);
wire word_rd, word_wr, word_busy, word_valid;
wire [23:0] word_addr;
wire [31:0] word_data, word_q;
wire [3:0] word_wstrb;
wire [7:0] word_burst_len;
wire dma_accepted,dma_done,dma_valid;
wire [31:0] dma_q;
wire uhd_word_request,bmp_word_request;
wire [7:0] bmp_word_length;
wire [23:0] uhd_word_address,bmp_word_address;
wire [31:0] uhd_word_data;
wire [23:0] hd_allocate_base=({14'd0,group_y}<<9)-({14'd0,group_y}<<5)+({16'd0,group_x}<<1)+group_x;
RenderQueue hd_queue (.clk(engine_clock),.reset(engine_reset),.active(quality_active && request_sync),
    .dispatch(latch && quality_active && !ultra_owner),.dispatch_lane(coordinate_word[75:73]),.dispatch_base(hd_allocate_base),
    .dispatch_ready(hd_queue_ready),.dispatch_slot(hd_dispatch_slot),
    .pixel_valid(buffer_write && buffer_quality && !buffer_ultra),.pixel_slot(buffer_slot),
    .pixel_lane(buffer_write_address[2:0]),.pixel_rgb(buffer_data[11:0]),
    .group_valid(hd_group_valid),.group_base(hd_group_base),.group_pixels(hd_group_pixels),
    .group_ack(tile_ack),.empty(hd_queue_empty),.allocated_groups(),.retired_groups());
LiveStore #(.TILE_WIDTH(320), .TILE_HEIGHT(512), .TILE_COLUMNS(4), .GLOBAL_RASTER(1),.EXTERNAL_CLIENT(1),.QUEUED_UPLOAD(1)) storage (
    .clk(engine_clock), .reset(engine_reset), .render_active(quality_active && request_sync),
    .capture_done(quality_done), .corruption_enable(settings[6] && !screenshot_busy),
    .pixel_valid(buffer_write && buffer_quality && !buffer_ultra), .pixel_offset(buffer_write_address[2:0]),
    .pixel_rgb(buffer_data[11:0]), .group_done(hd_group_valid), .tile_index(tile_index),
    .queued_pixels(hd_group_pixels),.queued_address(hd_group_base),
    .group_x(group_x), .group_y(group_y), .group_ack(tile_ack),
    .display_ready(display_ready), .progress_gray(progress_gray),
    .line_request(line_request), .line_y(line_y), .line_bank(line_bank),
    .line_ack(line_ack), .line_write(line_write), .line_write_address(line_write_address),
    .line_write_data(line_write_data), .word_rd(word_rd), .word_wr(word_wr), .word_addr(word_addr),
    .word_data(word_data), .word_wstrb(word_wstrb), .word_burst_len(word_burst_len),
    .word_busy(word_busy), .word_valid(word_valid), .word_q(word_q),
    .dma_request(ultra_owner ? uhd_word_request : bmp_word_request),.dma_write(ultra_owner),
    .dma_address(ultra_owner ? uhd_word_address : bmp_word_address),.dma_data(uhd_word_data),
    .dma_length(ultra_owner ? 8'd0 : bmp_word_length),.dma_accepted(dma_accepted),.dma_done(dma_done),.dma_valid(dma_valid),.dma_q(dma_q)
);
wire shot_toggle,uhd_toggle,cancel_toggle,hd_phase_request;
reg phase_request_meta,phase_request_sync,hd_phase_ack;
reg [56:0] held_hd_phases;
always @(posedge pixel_hd_clock or posedge video_reset)
    if(video_reset) begin phase_request_meta<=0;phase_request_sync<=0;hd_phase_ack<=0;held_hd_phases<=0;end
    else begin
        phase_request_meta<=hd_phase_request;phase_request_sync<=phase_request_meta;
        if(hd_frame_tick && phase_request_sync!=hd_phase_ack) begin held_hd_phases<=hd_phase_state;hd_phase_ack<=phase_request_sync;end
    end
ScreenshotKeys screenshot_keys (.clk(CLOCK_50),.reset(top_reset),.keycode(ps2_keycode),.key_ready(ps2_key_ready),
    .key_extended(ps2_key_extended),.key_released(ps2_key_released),.shot_toggle(shot_toggle),.uhd_toggle(uhd_toggle),.cancel_toggle(cancel_toggle));
ScreenshotControl #(.UHD_WIDTH(SCREENSHOT_UHD_WIDTH),.UHD_HEIGHT(SCREENSHOT_UHD_HEIGHT)) screenshot (.clk(engine_clock),.reset(engine_reset),.shot_toggle(shot_toggle),.uhd_toggle(uhd_toggle),
    .cancel_toggle(cancel_toggle),.hd_requested(request_sync),.hd_done(quality_done),.hd_live(raw_hd_selected),
    .workers_idle(&engine_idle),.writes_drained(writes_drained),.scheme(color_scheme),.color_offset(color_offset),.effects(settings),
    .center_x(render_center_x),.center_y(render_center_y),.zoom(render_zoom),.lens(render_lens),
    .preview_phases(preview_phase_state),.hd_phases(held_hd_phases),.hd_phase_ack(hd_phase_ack),.hd_phase_request(hd_phase_request),
    .busy(screenshot_busy),.finished(screenshot_finished),.error(screenshot_error),.render_lock(render_lock),
    .uhd_start(uhd_start),.job_cancel(job_cancel),.uhd_done(uhd_done),.uhd_cancelled(uhd_cancelled),
    .saved_x(screenshot_x),.saved_y(screenshot_y),.saved_zoom(screenshot_zoom),.saved_lens(screenshot_lens),
    .fs_start(fs_start),.fs_done(fs_done),.fs_ready(fs_ready),.begin_payload(begin_payload),.fs_error(fs_error),.file_size(screenshot_size),.mode(screenshot_mode),
    .saved_scheme(saved_scheme),.saved_offset(saved_offset),.saved_effects(saved_effects),.saved_phases(saved_phases));
UhdRenderer #(.WIDTH(SCREENSHOT_UHD_WIDTH),.HEIGHT(SCREENSHOT_UHD_HEIGHT)) uhd_render (.clk(engine_clock),.reset(engine_reset),.start(uhd_start),.cancel(job_cancel),
    .center_x(screenshot_x),.center_y(screenshot_y),.zoom(screenshot_zoom),.lens(screenshot_lens),
    .available(dones),.idle(engine_idle),.writes_drained(writes_drained),.latch(ultra_latch),.engine_address(ultra_engine_address),
    .coordinate_word(ultra_coordinate_word),.sample_step(ultra_sample_step),
    .dispatch_slot(ultra_dispatch_slot),.pixel_slot(buffer_slot),
    .pixel_valid(buffer_write && buffer_ultra),.pixel_offset(buffer_write_address[2:0]),.pixel_rgb(buffer_data[11:0]),
    .busy(uhd_busy),.done(uhd_done),.cancelled(uhd_cancelled),.groups_finished(),
    .word_request(uhd_word_request),.word_address(uhd_word_address),.word_data(uhd_word_data),.word_accepted(dma_accepted),.word_done(dma_done));
wire bmp_start,bmp_valid,bmp_ready;
wire [7:0] bmp_data;
BmpStream #(.UHD_WIDTH(SCREENSHOT_UHD_WIDTH),.UHD_HEIGHT(SCREENSHOT_UHD_HEIGHT),.SMOOTH_VIVID(1)) screenshot_pixels (.clk(engine_clock),.reset(engine_reset),.start(bmp_start),.abort(fs_done),.mode(screenshot_mode),
    .scheme(saved_scheme),.color_offset(saved_offset),.effects(saved_effects),.phases(saved_phases),
    .busy(),.done(),.byte_valid(bmp_valid),.byte_data(bmp_data),.byte_ready(bmp_ready),
    .word_request(bmp_word_request),.word_address(bmp_word_address),.word_length(bmp_word_length),.word_accepted(dma_accepted),.word_done(dma_done),
    .word_valid(dma_valid),.word_q(dma_q),.preview_request(screenshot_preview_request),.preview_address(screenshot_preview_address),
    .preview_accepted(screenshot_preview_accepted),.preview_q(framebuffer_q));
FatScreenshot screenshot_file (.clk(engine_clock),.reset(engine_reset),.start(fs_start),.cancel(job_cancel),.file_size(screenshot_size),
    .busy(),.done(fs_done),.error(fs_error),.file_number(),.payload_start(bmp_start),.payload_valid(bmp_valid),.payload_data(bmp_data),
    .allocation_ready(fs_ready),.begin_payload(begin_payload),
    .payload_ready(bmp_ready),.sd_clk(SD_CLK),.sd_cmd(SD_CMD),.sd_cs_n(SD_DATA[3]),.sd_miso(SD_DATA[0]));
assign SD_DATA[2:0]=3'bzzz;
io_sdram memory (
    .controller_clk(engine_clock), .chip_clk(DRAM_CLK), .clk_90(DRAM_CLK), .reset_n(~engine_reset),
    .phy_cke(DRAM_CKE), .phy_clk(), .phy_cas(DRAM_CAS_N), .phy_ras(DRAM_RAS_N), .phy_we(DRAM_WE_N),
    .phy_ba(DRAM_BA), .phy_a(DRAM_ADDR), .phy_dq(DRAM_DQ), .phy_dqm({DRAM_UDQM, DRAM_LDQM}),
    .burst_rd(1'b0), .burst_addr(25'd0), .burst_len(11'd0), .burst_32bit(1'b1),
    .burst_data(), .burst_data_valid(), .burst_data_done(),
    .burstwr(1'b0), .burstwr_addr(25'd0), .burstwr_ready(),
    .burstwr_strobe(1'b0), .burstwr_data(16'd0), .burstwr_done(1'b0),
    .word_rd(word_rd), .word_wr(word_wr), .word_addr(word_addr), .word_data(word_data),
    .word_wstrb(word_wstrb), .word_burst_len(word_burst_len),
    .word_q(word_q), .word_busy(word_busy), .word_q_valid(word_valid)
);
assign DRAM_CS_N = 1'b0;
assign VGA_R = hd_selected ? hd_r : preview_r;
assign VGA_G = hd_selected ? hd_g : preview_g;
assign VGA_B = hd_selected ? hd_b : preview_b;
assign VGA_HS = hd_selected ? hd_hs : preview_hs;
assign VGA_VS = hd_selected ? hd_vs : preview_vs;

reg done_meta, done_sync, underflow_meta, underflow_sync;
reg screenshot_meta,screenshot_sync,error_meta,error_sync;
reg [24:0] status_counter;
always @(posedge CLOCK_50 or posedge top_reset) begin
    if (top_reset) begin
        done_meta <= 1'b0; done_sync <= 1'b0; underflow_meta <= 1'b0; underflow_sync <= 1'b0;
        screenshot_meta<=0;screenshot_sync<=0;error_meta<=0;error_sync<=0;
        status_counter <= 25'd0;
    end else begin
        done_meta <= quality_done; done_sync <= done_meta;
        underflow_meta <= hd_underflow; underflow_sync <= underflow_meta;
        screenshot_meta<=screenshot_busy;screenshot_sync<=screenshot_meta;
        error_meta<=screenshot_error!=0;error_sync<=error_meta;
        status_counter <= status_counter + 1'b1;
    end
end
assign LEDR[3:0] = color_scheme;
assign LEDR[5:4] = burn_speed;
assign LEDR[6] = error_sync ? 1'b1 : (overrender_request && done_sync) ? underflow_sync : dones[6];
assign LEDR[7] = screenshot_sync || overrender_request;
assign LEDR[8] = screenshot_sync ? status_counter[23] : overrender_request && (done_sync || status_counter[24]);
assign LEDR[9] = bookmark_valid;
endmodule
