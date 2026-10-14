`timescale 1ns/1ps
module Keyboard_tb;
reg clk=0,reset=1, psclock=1,psdata=1;
wire [7:0] code;
wire ready, extended,released,quality,favorite;
wire [3:0] palette;
wire [3:0] offset;
wire [1:0] speed;
wire ps2_clk=psclock,ps2_data=psdata;
integer events=0;
always #10 clk=~clk;
keyboard #(.TIMEOUT_CYCLES(1000)) receiver (
    .clk(clk),.reset(reset),.ps2_clk(ps2_clk),.ps2_data(ps2_data),
    .keycode(code),.key_ready(ready),.key_extended(extended),.key_released(released)
);
ViewControl #(.DEBOUNCE_CYCLES(3),.REPEAT_CYCLES(1000)) controls (
    .clk(clk),.reset(reset),.switches(9'd0),.keys(4'b1111),
    .keycode(code),.key_ready(ready),.key_extended(extended),.key_released(released),
    .center_x(),.center_y(),.zoom_level(),.settings(),.overrender(quality),.bookmark_valid(favorite),
    .color_scheme(palette),.color_offset(offset),.burn_speed(speed),.lens_enable()
);
always @(negedge clk) if(ready) events=events+1;
task send_bit;
    input value;
    begin
        psdata=value; repeat(8) @(negedge clk);
        psclock=0; repeat(8) @(negedge clk);
        psclock=1; repeat(8) @(negedge clk);
    end
endtask
task send_byte;
    input [7:0] value;
    input corrupt;
    integer i;
    reg [10:0] frame;
    begin
        frame={1'b1,(~^value)^corrupt,value,1'b0};
        for(i=0;i<11;i=i+1) send_bit(frame[i]);
        psdata=1; repeat(8) @(negedge clk);
    end
endtask
initial begin
    repeat(4) @(negedge clk); reset=0;
    send_byte(8'h44,0); send_byte(8'h44,0);
    send_byte(8'hf0,0); send_byte(8'h44,0);
    if(events!=3 || !quality || !released || extended) $fatal(1,"O make/repeat/break handling failed");
    send_byte(8'he0,0); send_byte(8'h44,0);
    if(!extended || !quality) $fatal(1,"Extended key handling failed");
    send_byte(8'h44,1);
    if(events!=4 || !quality) $fatal(1,"Bad parity emitted an event");
    send_bit(0); send_bit(1);
    repeat(1100) @(negedge clk);
    send_byte(8'h32,0);
    if(events!=5 || !favorite) $fatal(1,"Incomplete-frame timeout recovery failed");
    // The actual serial receiver must reach the new live HD visual controls.
    send_byte(8'h26,0); if(palette!=2) $fatal(1,"Serial number key did not select Vivid Spectrum");
    send_byte(8'h21,0); send_byte(8'h21,0);
    send_byte(8'hf0,0); send_byte(8'h21,0);
    if(palette!=3) $fatal(1,"Serial palette cycle or held-key guard failed");
    send_byte(8'h21,0); if(palette!=4) $fatal(1,"Serial palette key failed after break");
    send_byte(8'h54,0); if(offset!=15) $fatal(1,"Serial hue shift failed");
    send_byte(8'h55,0); if(speed!=3) $fatal(1,"Serial speed control failed during HD");
    send_byte(8'h4e,0); if(speed!=2 || !quality) $fatal(1,"Serial speed key changed capture state");
    send_byte(8'h83,0); send_byte(8'hf0,0); send_byte(8'h83,0);
    if(palette!=14 || !quality) $fatal(1,"Serial F7 palette selection lost its high bit or changed HD");
    $display("PASS: serial PS/2 framing, parity/prefix/timeout handling, held keys and live HD palette/hue/speed controls");
    $finish;
end
initial begin #2000000; $fatal(1,"Keyboard timeout"); end
endmodule
