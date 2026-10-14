`timescale 1ns/1ps
module ViewControl_tb;
reg clk=0,reset=1,ready=0,released=0,extended=0;
reg [8:0] switches=0;
reg [3:0] keys=4'b1111;
reg [7:0] code=0;
wire signed [31:0] x,y;
wire [31:0] zoom;
wire [7:0] settings;
wire [3:0] color;
wire [3:0] offset;
wire [1:0] speed;
wire quality,favorite,lens;
reg signed [31:0] saved_x,saved_y;
reg [31:0] saved_zoom;
integer i;
reg [7:0] number_codes[0:7];
reg [7:0] function_codes[0:7];
always #10 clk=~clk;
ViewControl #(.DEBOUNCE_CYCLES(3),.REPEAT_CYCLES(1000)) dut (
    .clk(clk),.reset(reset),.switches(switches),.keys(keys),
    .keycode(code),.key_ready(ready),.key_extended(extended),.key_released(released),
    .center_x(x),.center_y(y),.zoom_level(zoom),.settings(settings),
    .color_scheme(color),.color_offset(offset),.burn_speed(speed),
    .overrender(quality),.bookmark_valid(favorite),.lens_enable(lens));
task send_key;
    input [7:0] key; input release_key;
    begin
        @(negedge clk); code=key; released=release_key; ready=1;
        @(negedge clk); ready=0; released=0;
    end
endtask
task tap;
    input [7:0] key;
    begin send_key(key,0); send_key(key,1); end
endtask
task press_button;
    input integer button;
    begin
        @(negedge clk); keys[button]=0;
        repeat(20) @(negedge clk); keys[button]=1; repeat(10) @(negedge clk);
    end
endtask
initial begin
    number_codes[0]=8'h16; number_codes[1]=8'h1e; number_codes[2]=8'h26; number_codes[3]=8'h25;
    number_codes[4]=8'h2e; number_codes[5]=8'h36; number_codes[6]=8'h3d; number_codes[7]=8'h3e;
    function_codes[0]=8'h05; function_codes[1]=8'h06; function_codes[2]=8'h04; function_codes[3]=8'h0c;
    function_codes[4]=8'h03; function_codes[5]=8'h0b; function_codes[6]=8'h83; function_codes[7]=8'h0a;
    repeat(3) @(negedge clk); reset=0; repeat(5) @(negedge clk);
    saved_x=x; saved_y=y; saved_zoom=zoom;
    for(i=0;i<8;i=i+1) begin
        switches[8:1]=8'(1<<i); repeat(5) @(negedge clk);
        if(settings!==8'(1<<i) || color!=0 || speed!=2 || quality)
            $fatal(1,"An effect switch changed a selector or capture");
    end
    switches[8:1]=8'hff; repeat(5) @(negedge clk);
    for(i=0;i<8;i=i+1) begin
        tap(number_codes[i]); if(color!==4'(i)) $fatal(1,"Direct palette selection failed");
    end
    for(i=0;i<8;i=i+1) begin
        tap(function_codes[i]); if(color!==4'(i+8)) $fatal(1,"Function-key palette selection failed");
    end
    send_key(8'h21,0); send_key(8'h21,0); send_key(8'h21,1);
    if(color!=0) $fatal(1,"C wrap or typematic guard failed");
    send_key(8'h2a,0); send_key(8'h2a,0); send_key(8'h2a,1);
    if(color!=15) $fatal(1,"V wrap or typematic guard failed");
    extended=1; tap(8'h21); extended=0;
    if(color!=15) $fatal(1,"An extended code changed the palette");
    tap(8'h54); if(offset!=15) $fatal(1,"Previous hue did not wrap");
    tap(8'h5b); if(offset!=0) $fatal(1,"Next hue did not wrap");
    repeat(4) tap(8'h4e); if(speed!=0) $fatal(1,"Still speed clamp failed");
    repeat(5) tap(8'h55); if(speed!=3) $fatal(1,"Wild speed clamp failed");
    tap(8'h7b); if(speed!=2) $fatal(1,"Keypad minus failed");
    tap(8'h79); if(speed!=3) $fatal(1,"Keypad plus failed");
    if(x!==saved_x || y!==saved_y || zoom!==saved_zoom || quality)
        $fatal(1,"Keyboard visual controls moved the view or started capture");
    press_button(0); if(zoom>=saved_zoom) $fatal(1,"SW1 still steals KEY0 navigation");
    press_button(2); if(y==saved_y) $fatal(1,"SW2 still steals KEY2 navigation");
    tap(8'h04); tap(8'h54); tap(8'h4e); tap(8'h4b);
    saved_x=x; saved_y=y; saved_zoom=zoom;
    tap(8'h32); if(!favorite) $fatal(1,"Bookmark failed");
    tap(8'h23); tap(8'h29); tap(8'h16); tap(8'h5b); tap(8'h4e); tap(8'h4b);
    switches[8:1]=8'h20; repeat(5) @(negedge clk);
    tap(8'h2d);
    if(x!==saved_x || y!==saved_y || zoom!==saved_zoom || color!=10 || offset!=15 || speed!=2 || !lens || settings!==8'h20)
        $fatal(1,"Bookmark did not restore keyboard settings or overrode physical switches");
    send_key(8'h44,0); send_key(8'h44,0); send_key(8'h44,1);
    tap(8'h23); tap(8'h5a); tap(8'h4b);
    tap(8'h21); tap(8'h5b); tap(8'h55);
    switches[8:1]=8'hff; repeat(5) @(negedge clk);
    if(!quality || x!==saved_x || zoom!==saved_zoom || !lens ||
        color!=11 || offset!=0 || speed!=3 || settings!==8'hff)
        $fatal(1,"HD keyboard editing, navigation lock or held O failed");
    tap(8'h76); if(quality || x!==saved_x || zoom!==saved_zoom) $fatal(1,"Escape failed");
    for(i=0;i<200;i=i+1) tap(8'h5a);
    if(zoom!==32'd8192) $fatal(1,"Minimum zoom clamp failed");
    for(i=0;i<250;i=i+1) tap(8'h29);
    if(zoom!==32'd67108864) $fatal(1,"Maximum zoom clamp failed");
    switches[0]=1; repeat(6) @(negedge clk); if(!quality) $fatal(1,"SW0 capture failed");
    switches[0]=0; repeat(6) @(negedge clk); if(quality) $fatal(1,"SW0 cancel failed");
    press_button(3); if(!quality) $fatal(1,"KEY3 capture failed with all effects on");
    press_button(3); if(quality) $fatal(1,"KEY3 cancel failed");
    $display("PASS: simple independent effect switches, sixteen keyboard palettes, hue wrap, four speeds, held keys, physical switches after bookmark restore, live HD editing and unchanged SW0");
    $finish;
end
initial begin #1000000; $fatal(1,"View control timeout"); end
endmodule
