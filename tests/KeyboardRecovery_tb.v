`timescale 1ns/1ps
// Exercise recovery through the serial pins, including the real key consumers.
module KeyboardRecovery_tb;
parameter TIMEOUT_CYCLES=1000;
parameter FILTER_CYCLES=4;
reg clk=0,reset=1,psclock=1,psdata=1,noisy=0;
always #10 clk=~clk;
wire ps2_clk=psclock,ps2_data=psdata;
wire [7:0] code;
wire ready,extended,released,quality;
wire [3:0] palette;
wire shot,uhd,cancel;
integer events=0,expected_events=0,i,noise_cycles=1;
reg previous_ready=0;
keyboard #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES),.FILTER_CYCLES(FILTER_CYCLES)) receiver (
    .clk(clk),.reset(reset),.ps2_clk(ps2_clk),.ps2_data(ps2_data),
    .keycode(code),.key_ready(ready),.key_extended(extended),.key_released(released)
);
ViewControl #(.DEBOUNCE_CYCLES(3)) controls (
    .clk(clk),.reset(reset),.switches(9'd0),.keys(4'b1111),
    .keycode(code),.key_ready(ready),.key_extended(extended),.key_released(released),
    .center_x(),.center_y(),.zoom_level(),.settings(),.overrender(quality),
    .bookmark_valid(),.color_scheme(palette),.color_offset(),.burn_speed(),.lens_enable()
);
ScreenshotKeys screenshots (
    .clk(clk),.reset(reset),.keycode(code),.key_ready(ready),
    .key_extended(extended),.key_released(released),
    .shot_toggle(shot),.uhd_toggle(uhd),.cancel_toggle(cancel)
);
always @(negedge clk) begin
    if(ready && previous_ready) $fatal(1,"Key event lasted more than one clock");
    previous_ready=ready;
    if(ready) events=events+1;
end
task send_bit;
    input value;
    begin
        psdata=value; repeat(16) @(negedge clk);
        psclock=0; repeat(16) @(negedge clk);
        // A short high spike must not create another falling edge.
        if(noisy && FILTER_CYCLES>1) begin
            psclock=1;repeat(noise_cycles) @(negedge clk);psclock=0;
        end
        repeat(16) @(negedge clk); psclock=1; repeat(16) @(negedge clk);
    end
endtask
task send_frame;
    input [7:0] value;
    input bad_parity,bad_stop;
    integer bit_index;
    reg [10:0] frame;
    begin
        frame={!bad_stop,(~^value)^bad_parity,value,1'b0};
        for(bit_index=0;bit_index<11;bit_index=bit_index+1) send_bit(frame[bit_index]);
        psdata=1; repeat(16) @(negedge clk);
    end
endtask
task prefix;
    input [7:0] value;
    begin
        send_frame(value,0,0);
        if(events!=expected_events) $fatal(1,"Prefix emitted a key event");
    end
endtask
task check_key;
    input [7:0] value;
    input wanted_extended,wanted_released;
    begin
        expected_events=expected_events+1;
        if(events!=expected_events || code!==value ||
            extended!==wanted_extended || released!==wanted_released)
            $fatal(1,"Serial key %h: events %0d/%0d flags %b%b expected %b%b",
                value,events,expected_events,extended,released,wanted_extended,wanted_released);
    end
endtask
task expect_key;
    input [7:0] value;
    input wanted_extended,wanted_released;
    begin send_frame(value,0,0);check_key(value,wanted_extended,wanted_released);end
endtask
task deadline_key;
    input [7:0] value;
    integer bit_index;
    reg [10:0] frame;
    begin
        frame={1'b1,~^value,value,1'b0};psdata=0;
        // Three synchronizer clocks, FILTER_CYCLES samples, then detection.
        // Drive the start so its accepted edge coincides with expiration.
        while(receiver.timeout_count<TIMEOUT_CYCLES-FILTER_CYCLES-4) @(negedge clk);
        psclock=0;repeat(FILTER_CYCLES+4) @(negedge clk);
        if(receiver.bit_count!=1 || !receiver.extended_pending || receiver.timeout_count!=0)
            $fatal(1,"A valid start edge lost to the prefix timeout");
        repeat(16) @(negedge clk);psclock=1;repeat(16) @(negedge clk);
        for(bit_index=1;bit_index<11;bit_index=bit_index+1) send_bit(frame[bit_index]);
        psdata=1;repeat(16) @(negedge clk);check_key(value,1,0);
    end
endtask
task expire;
    begin repeat(TIMEOUT_CYCLES+32) @(negedge clk); end
endtask
initial begin
    repeat(8) @(negedge clk);reset=0;
    // A missing code after a complete prefix previously poisoned the next key.
    prefix(8'hf0);expire();expect_key(8'h44,0,0);
    if(!quality) $fatal(1,"Lost break prefix blocked the next HD toggle");
    prefix(8'hf0);expect_key(8'h44,0,1);
    prefix(8'he0);expire();expect_key(8'h21,0,0);
    if(palette!=1) $fatal(1,"Lost extended prefix blocked palette control");
    prefix(8'he0);prefix(8'hf0);expire();expect_key(8'h78,0,0);
    if(!uhd) $fatal(1,"Lost combined prefix blocked a screenshot");
    prefix(8'hf0);expect_key(8'h78,0,1);
    // Ordinary prefixes survive a long but legal inter-byte pause.
    prefix(8'he0);repeat(TIMEOUT_CYCLES-100) @(negedge clk);
    prefix(8'hf0);expect_key(8'h75,1,1);
    prefix(8'he0);deadline_key(8'h72);
    // Bad frames clear both prefix flags without leaking an event.
    prefix(8'he0);prefix(8'hf0);send_frame(8'h44,1,0);
    if(events!=expected_events) $fatal(1,"Bad parity emitted an event");
    expect_key(8'h07,0,0);
    if(!shot) $fatal(1,"Parity recovery blocked F12");
    prefix(8'he0);send_frame(8'h44,0,1);
    if(events!=expected_events) $fatal(1,"Bad stop bit emitted an event");
    expect_key(8'h76,0,0);
    if(!cancel) $fatal(1,"Stop-bit recovery blocked cancellation");
    // An incomplete prefixed frame also expires, including wide timeouts.
    prefix(8'he0);prefix(8'hf0);send_bit(0);send_bit(1);expire();
    expect_key(8'h32,0,0);
    if(FILTER_CYCLES>1) begin
        // Short low spikes at idle never start a frame, even with data low.
        psdata=0;repeat(16) @(negedge clk);
        for(i=1;i<FILTER_CYCLES;i=i+1) begin
            psclock=0;repeat(i) @(negedge clk);psclock=1;repeat(16) @(negedge clk);
        end
        psdata=1;
        if(receiver.bit_count!=0 || events!=expected_events) $fatal(1,"Clock glitch started a frame");
        noisy=1;
        for(i=1;i<FILTER_CYCLES;i=i+1) begin noise_cycles=i;expect_key(8'h5a,0,0);end
        prefix(8'he0);prefix(8'hf0);expect_key(8'h74,1,1);noisy=0;
    end
    // Reset discards partial frames and prefix state together.
    prefix(8'he0);prefix(8'hf0);send_bit(0);reset=1;
    repeat(8) @(negedge clk);psclock=1;psdata=1;reset=0;repeat(16) @(negedge clk);
    expect_key(8'h21,0,0);
    if(palette!=1 || shot || uhd || cancel || quality) $fatal(1,"Reset leaked control state");
    $display("PASS: %0d serial recovery events, lost prefixes, parity/stop errors, partial frames, glitches, reset and live controls (timeout=%0d filter=%0d)",events,TIMEOUT_CYCLES,FILTER_CYCLES);
    $finish;
end
initial begin
    repeat(8*TIMEOUT_CYCLES+100000) @(negedge clk);
    $fatal(1,"Keyboard recovery test timeout");
end
endmodule
