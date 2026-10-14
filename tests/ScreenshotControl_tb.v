`timescale 1ns/1ps
// Events cross unrelated clock domains; no SD token is started before a
// potentially long UHD render, and unfinished HD captures can still finish.
module ScreenshotControl_tb;
reg clk=0,keyclk=0,reset=1;
always #5 clk=~clk;
always #7 keyclk=~keyclk;
reg [7:0] code=0;
reg ready=0,extended=0,released=0;
wire shot,ultra,cancel;
reg hd_requested=0,hd_live=0,hd_done=0,idle=0,drained=0;
reg [3:0] scheme=11;
reg [3:0] offset=9;
reg [7:0] effects=8'h9b;
reg [56:0] preview_phases=57'h123456789abcd,hd_phases=57'h76543210fedcb;
reg phase_ack=0;
reg fs_done=0,fs_ready=0;
reg [7:0] fs_error=0;
reg uhd_done=0,uhd_cancelled=0;
wire busy,finished,lock,uhd_start,job_cancel,fs_start,begin_payload,phase_request;
wire [7:0] error;
wire [31:0] size;
wire [1:0] mode;
wire [3:0] saved_scheme;
wire [3:0] saved_offset;
wire [7:0] saved_effects;
wire [56:0] saved_phases;
integer fs_starts=0,uhd_starts=0,jobs=0;
ScreenshotKeys keys (.clk(keyclk),.reset(reset),.keycode(code),.key_ready(ready),.key_extended(extended),
    .key_released(released),.shot_toggle(shot),.uhd_toggle(ultra),.cancel_toggle(cancel));
ScreenshotControl dut (.clk(clk),.reset(reset),.shot_toggle(shot),.uhd_toggle(ultra),.cancel_toggle(cancel),
    .hd_requested(hd_requested),.hd_done(hd_done),.hd_live(hd_live),.workers_idle(idle),.writes_drained(drained),
    .scheme(scheme),.color_offset(offset),.effects(effects),.center_x(-32'sd123),.center_y(32'sd456),.zoom(32'd789),.lens(1'b1),
    .preview_phases(preview_phases),.hd_phases(hd_phases),.hd_phase_ack(phase_ack),.hd_phase_request(phase_request),
    .busy(busy),.finished(finished),.error(error),.render_lock(lock),.uhd_start(uhd_start),.job_cancel(job_cancel),
    .uhd_done(uhd_done),.uhd_cancelled(uhd_cancelled),.saved_x(),.saved_y(),.saved_zoom(),.saved_lens(),
    .fs_start(fs_start),.fs_done(fs_done),.fs_ready(fs_ready),.fs_error(fs_error),.begin_payload(begin_payload),
    .file_size(size),.mode(mode),.saved_scheme(saved_scheme),.saved_offset(saved_offset),.saved_effects(saved_effects),.saved_phases(saved_phases));
always @(posedge clk) begin if(fs_start) fs_starts=fs_starts+1;if(uhd_start) uhd_starts=uhd_starts+1;if(finished) jobs=jobs+1;end
task event_key;
    input [7:0] value;input release_key;
    begin @(negedge keyclk);code=value;released=release_key;ready=1;@(negedge keyclk);ready=0;repeat(8) @(negedge clk);end
endtask
task tap;
    input [7:0] value;
    begin event_key(value,0);event_key(value,1);end
endtask
task complete_fs;
    input [7:0] value;
    begin @(negedge clk);fs_error=value;fs_done=1;@(negedge clk);fs_done=0;fs_ready=0;repeat(3) @(negedge clk);end
endtask
initial begin
    repeat(4) @(negedge clk);reset=0;
    event_key(8'h07,0);wait(busy);repeat(8) @(negedge clk);
    if(mode!=0 || size!=921654 || !lock || saved_phases!=preview_phases || fs_starts!=0) $fatal(1,"Preview/drain setup");
    scheme=1;offset=2;effects=0;preview_phases=0;
    event_key(8'h07,0);tap(8'h78);
    if(saved_scheme!=11 || saved_offset!=9 || saved_effects!=8'h9b || mode!=0) $fatal(1,"Snapshot changed or busy keys queued");
    idle=1;repeat(6) @(negedge clk);if(fs_starts) $fatal(1,"Filesystem started before writes drained");
    drained=1;wait(fs_start);repeat(6) @(negedge clk);if(begin_payload) $fatal(1,"Payload before allocation");
    fs_ready=1;wait(begin_payload);complete_fs(0);
    event_key(8'h07,0);if(busy) $fatal(1,"Held key repeated after completion");event_key(8'h07,1);
    hd_requested=1;hd_live=1;repeat(6) @(negedge clk);tap(8'h07);
    if(mode!=1 || size!=3932214 || !lock) $fatal(1,"HD phase setup");
    phase_ack=phase_request;wait(dut.state==dut.WAIT_IMAGE);@(negedge clk);
    if(lock || saved_phases!=hd_phases) $fatal(1,"Unfinished HD image was paused or phase bus incoherent");
    tap(8'h76);repeat(6) @(negedge clk);if(busy || fs_starts!=1) $fatal(1,"Cancel waiting for HD");
    hd_live=0;hd_requested=0;repeat(6) @(negedge clk);
    tap(8'h78);wait(dut.state==dut.ALLOC_WAIT);repeat(6) @(negedge clk);
    if(mode!=2 || size!=24883254 || uhd_starts || begin_payload) $fatal(1,"UHD started before card preflight");
    complete_fs(8'h81);if(error!=8'h81 || busy || uhd_starts) $fatal(1,"Bad card did not release capture");
    tap(8'h78);wait(dut.state==dut.ALLOC_WAIT);repeat(6) @(negedge clk);fs_ready=1;wait(uhd_start);repeat(6) @(negedge clk);
    if(begin_payload || !lock) $fatal(1,"SD payload was opened during UHD rendering");
    tap(8'h76);if(!job_cancel) $fatal(1,"Cancel was lost crossing clock domains");
    uhd_cancelled=1;uhd_done=1;@(negedge clk);uhd_done=0;repeat(4) @(negedge clk);
    if(busy || begin_payload) $fatal(1,"Cancelled UHD began export");fs_ready=0;uhd_cancelled=0;
    tap(8'h78);wait(dut.state==dut.ALLOC_WAIT);fs_ready=1;wait(uhd_start);repeat(6) @(negedge clk);
    uhd_done=1;@(negedge clk);uhd_done=0;wait(begin_payload);complete_fs(0);
    // If HD mode goes away before its frame acknowledgement, finish waiting
    // with preview phases rather than hanging until a nonexistent HD frame.
    hd_live=1;hd_requested=1;hd_done=1;repeat(6) @(negedge clk);tap(8'h07);
    hd_live=0;hd_requested=0;repeat(12) @(negedge clk);
    if(busy) $fatal(1,"HD phase cancellation/fallback hung");
    if(fs_starts!=4 || uhd_starts!=2) $fatal(1,"Unexpected capture jobs: FS=%0d UHD=%0d",fs_starts,uhd_starts);
    $display("PASS: asynchronous screenshot keys, held/busy key suppression, stable settings, HD phase capture, finish-before-pause, worker drain, SD preflight, errors and cancellation");$finish;
end
initial begin #100000;$fatal(1,"Screenshot control timeout state=%0d",dut.state);end
endmodule
