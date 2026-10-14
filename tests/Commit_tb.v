`timescale 1ns/1ps
// Exercise the actual top-level commit pipeline with behavioral PLL/RAM
// models. Change mode every pixel and sustain one accepted result per clock.
// Then verify physical visual switches drive the same preview/HD effects.
module Commit_tb;
reg clk=0;
always #10 clk=~clk;
reg [9:0] sw=10'b1000000000;
reg [3:0] keys=4'b1111;
tri1 ps_clk,ps_data;
reg ps_clock=1,ps_bits=1;
assign ps_clk=ps_clock ? 1'bz : 1'b0;
assign ps_data=ps_bits ? 1'bz : 1'b0;
tri [15:0] dq;
Mandel dut (.CLOCK_50(clk),.SW(sw),.KEY(keys),.LEDR(),.VGA_R(),.VGA_G(),.VGA_B(),
    .VGA_HS(),.VGA_VS(),.PS2_CLK(ps_clk),.PS2_DAT(ps_data),.DRAM_DQ(dq),
    .DRAM_ADDR(),.DRAM_BA(),.DRAM_CAS_N(),.DRAM_CKE(),.DRAM_CLK(),.DRAM_CS_N(),
    .DRAM_LDQM(),.DRAM_RAS_N(),.DRAM_UDQM(),.DRAM_WE_N());
defparam dut.controls.DEBOUNCE_CYCLES=3;
defparam dut.controls.REPEAT_CYCLES=1000;
reg inject_write=0,inject_quality=0;
reg [34:0] inject_word=0;
reg [34:0] expected_words[0:127];
reg expected_quality[0:127];
integer accepted=0,written=0,i,x,y,byte_address;
reg [15:0] wanted_data;
reg [1:0] wanted_mask;
reg [11:0] effect_input=12'h693;
reg effect_frame=0;
reg [10:0] effect_x=0;
reg [9:0] effect_y=0;
wire [3:0] effect_red=effect_input[11:8],effect_green=effect_input[7:4],effect_blue=effect_input[3:0];
wire [8:0] preview_effect_y=effect_y[8:0];
// Still retains Slow's fractional blend with uniform color rounding.
wire matching_coordinates=sw[2] || sw[4] || (sw[1] && dut.preview_effects.smooth_mode);
wire [10:0] hd_effect_x=matching_coordinates ? effect_x : 11'd1279-effect_x;
wire [9:0] hd_effect_y=matching_coordinates ? effect_y : 10'd1023-effect_y;
integer mode,pixel,scheme,pace;
task send_bit;
    input value;
    begin
        ps_bits=value; repeat(8) @(negedge clk);
        ps_clock=0; repeat(8) @(negedge clk); ps_clock=1; repeat(8) @(negedge clk);
    end
endtask
task send_byte;
    input [7:0] value;
    integer bit_index;
    reg [10:0] frame;
    begin
        frame={1'b1,~^value,value,1'b0};
        for(bit_index=0;bit_index<11;bit_index=bit_index+1) send_bit(frame[bit_index]);
        ps_bits=1; repeat(8) @(negedge clk);
    end
endtask
task tap;
    input [7:0] value;
    begin send_byte(value); send_byte(8'hf0); send_byte(value); end
endtask
task select_scheme;
    input [3:0] wanted;
    reg [7:0] code;
    begin
        case(wanted)
            0: code=8'h16; 1: code=8'h1e; 2: code=8'h26; 3: code=8'h25;
            4: code=8'h2e; 5: code=8'h36; 6: code=8'h3d; 7: code=8'h3e;
            8: code=8'h05; 9: code=8'h06; 10: code=8'h04; 11: code=8'h0c;
            12: code=8'h03; 13: code=8'h0b; 14: code=8'h83; default: code=8'h0a;
        endcase
        tap(code); repeat(16) @(negedge clk);
        if(dut.color_scheme!==wanted || dut.LEDR[3:0]!==wanted)
            $fatal(1,"Serial palette selection or LED feedback failed");
    end
endtask
task select_speed;
    input [1:0] wanted;
    begin
        while(dut.burn_speed>wanted) tap(8'h4e);
        while(dut.burn_speed<wanted) tap(8'h55);
        repeat(16) @(negedge clk);
        if(dut.LEDR[5:4]!==wanted) $fatal(1,"Serial speed selection or LED feedback failed");
    end
endtask
task check_effect;
    input [11:0] expected;
    begin
        repeat(20) @(negedge clk);
        for(pixel=0;pixel<32;pixel=pixel+1) begin
            effect_x=11'(pixel*37); effect_y=10'((pixel*53)%480);
            @(negedge clk);
            if(dut.preview_x!==effect_x || dut.raw_hd_x!==hd_effect_x ||
               dut.preview_scan_y!==preview_effect_y || dut.raw_hd_y!==hd_effect_y)
                $fatal(1,"Effect coordinates were not driven dynamically");
            if({dut.preview_r,dut.preview_g,dut.preview_b}!==expected ||
               {dut.hd_r,dut.hd_g,dut.hd_b}!==expected)
                $fatal(1,"Selected color/speed has wrong preview/HD palette at (%0d,%0d)",effect_x,effect_y);
        end
    end
endtask
task advance_frames;
    input integer count;
    integer frame;
    begin
        for(frame=0;frame<count;frame=frame+1) begin
            effect_frame=1; @(negedge clk);
            effect_frame=0; @(negedge clk);
        end
        repeat(16) @(negedge clk);
    end
endtask
initial begin
    force dut.latch=0;
    force dut.write_enable=inject_write;
    force dut.result_word=inject_word;
    force dut.quality_active=inject_quality;
    force dut.engine_idle=7'b1111111;
    force dut.tile_done=0;
    repeat(8) @(negedge clk); sw[9]=0;
    wait(!dut.engine_reset);
    for(i=0;i<96;i=i+1) begin
        @(negedge clk);
        inject_quality=i[0];
        x=(i*53)%(inject_quality?1024:640); y=(i*37)%(inject_quality?512:480);
        inject_word={10'(x),9'(y),16'(i*31)};
        inject_write=1;
        if(i%11==10) begin @(negedge clk); inject_write=0; end
    end
    @(negedge clk); inject_write=0;
    repeat(6) @(negedge clk);
    if(accepted!=96 || written!=96 || !dut.writes_drained) $fatal(1,"Commit pipeline did not drain");
    // Drive identical stored colors into both actual top-level display paths.
    // Their coordinates differ to expose spatial stripe formulas. Palette
    // controls travel through the actual PS/2 receiver and ViewControl.
    force dut.preview_visible=1;
    force dut.raw_hd_selected=1;
    force dut.preview_scan_active=1;
    force dut.raw_hd_active=1;
    force dut.raw_preview_r=effect_red;
    force dut.raw_preview_g=effect_green;
    force dut.raw_preview_b=effect_blue;
    force dut.raw_hd_r=effect_red;
    force dut.raw_hd_g=effect_green;
    force dut.raw_hd_b=effect_blue;
    force dut.raw_preview_hs=1; force dut.raw_preview_vs=1;
    force dut.raw_hd_hs=1; force dut.raw_hd_vs=1;
    force dut.preview_frame_tick=effect_frame;
    force dut.hd_frame_tick=effect_frame;
    force dut.preview_pixel_tick=1;
    force dut.preview_x=effect_x; force dut.preview_scan_y=preview_effect_y;
    force dut.raw_hd_x=hd_effect_x; force dut.raw_hd_y=hd_effect_y;
    sw=10'b1000000000;
    repeat(8) @(negedge clk); sw[9]=0;
    repeat(16) @(negedge clk);
    if(dut.preview.palette_select!==0 || dut.preview.palette_cycle!==0 || dut.preview.fast_cycle!==0)
        $fatal(1,"Preview still enables a second palette/effect path");
    check_effect(12'h693);
    select_scheme(1); check_effect(12'h47f);
    select_speed(1); sw[1]=1; repeat(16) @(negedge clk);
    advance_frames(128);
    check_effect(12'h59f);
    select_scheme(2); check_effect(12'h0f9);
    select_speed(2);
    advance_frames(4);
    check_effect(12'h0ff);
    for(scheme=0;scheme<16;scheme=scheme+1) for(pace=0;pace<4;pace=pace+1) begin
        select_scheme(4'(scheme)); select_speed(2'(pace));
        for(mode=0;mode<128;mode=mode+1) begin
        sw[8:1]={mode[6],1'b0,mode[5:0]};
        // Flush control/RGB latency plus Glow's sixteen-pixel history.
        repeat(40) @(negedge clk);
        if(dut.settings!=={mode[6],1'b0,mode[5:0]}) $fatal(1,"Visual switch mapping is inconsistent");
        if(mode[3]) advance_frames(8);
        for(pixel=0;pixel<32;pixel=pixel+1) begin
            effect_input=12'(pixel*149+mode*29);
            effect_x=11'(pixel*19); effect_y=10'((pixel*53)%480);
            @(negedge clk);
            if({dut.raw_preview_r,dut.raw_preview_g,dut.raw_preview_b}!==effect_input ||
               {dut.raw_hd_r,dut.raw_hd_g,dut.raw_hd_b}!==effect_input)
                $fatal(1,"Stored test colors were not driven dynamically");
            if({dut.preview_r,dut.preview_g,dut.preview_b}!=={dut.hd_r,dut.hd_g,dut.hd_b})
                $fatal(1,"Preview/HD effects differ for color %0d speed %0d effects %b: preview=%h HD=%h",scheme,pace,mode[6:0],{dut.preview_r,dut.preview_g,dut.preview_b},{dut.hd_r,dut.hd_g,dut.hd_b});
        end
        end
    end
    sw[7]=1; repeat(16) @(negedge clk);
    if(!dut.storage.corruption_enable || dut.settings[6]!==1'b1) $fatal(1,"SW7 no longer enables SDRAM corruption");
    sw[7]=0; repeat(16) @(negedge clk);
    if(dut.storage.corruption_enable) $fatal(1,"SW7 did not disable SDRAM corruption");
    tap(8'h5b); repeat(20) @(negedge clk);
    if(dut.color_offset!==1 || dut.preview_effects.offset_sync!==1 || dut.effects.offset_sync!==1)
        $fatal(1,"Serial hue shift failed to reach both pixel paths");
    // Color effects must have no authority over VGA timing or mode selection.
    force dut.effects.hsync=0; force dut.effects.vsync=0; force dut.effects.selected=0;
    repeat(20) @(negedge clk);
    if(!dut.hd_selected || !dut.VGA_HS || !dut.VGA_VS)
        $fatal(1,"Effect outputs still control VGA sync or display selection");
    release dut.effects.hsync; release dut.effects.vsync; release dut.effects.selected;
    $display("PASS: 96 top-level commits, preview RAM isolation, real PS/2 palette/speed/hue controls, LEDs, all 8192 visual combinations match in preview/HD and SW7 corruption mapping");
    $finish;
end
always @(posedge clk) if(!dut.engine_reset) begin
    if(inject_write) begin
        expected_words[accepted]=inject_word;
        expected_quality[accepted]=inject_quality;
        accepted=accepted+1;
    end
    if(dut.buffer_write) begin
        if(written>=accepted) $fatal(1,"Unexpected framebuffer write");
        x=expected_words[written][34:25]; y=expected_words[written][24:16];
        byte_address=y*640+x;
        wanted_data=expected_quality[written]?expected_words[written][15:0]:{2{expected_words[written][7:0]}};
        wanted_mask=expected_quality[written]?2'b11:(x[0]?2'b10:2'b01);
        if(dut.buffer_data!==wanted_data || dut.buffer_byte_enable!==wanted_mask ||
           dut.buffer_write_address!==(expected_quality[written]?18'(byte_address):18'(byte_address/2)) ||
           dut.staging.wren!==!expected_quality[written])
            $fatal(1,"Commit pixel %0d wrote wrong address/data/byte enables",written);
        written=written+1;
    end
    #1;
    if(written<accepted && dut.writes_drained) $fatal(1,"Frame boundary released before RAM writes drained");
end
initial begin #20000000; $fatal(1,"Commit/effect test timeout"); end
endmodule

module RenderClocks(input refclk,reset,output engine_clk,sdram_clk,pixel_hd_clk,engine_locked,pixel_locked);
assign engine_clk=refclk;
assign pixel_hd_clk=refclk;
assign sdram_clk=~refclk;
assign engine_locked=1;
assign pixel_locked=1;
endmodule

module FrameBuffer(input clk,input [15:0] data,input [17:0] wraddress,input [1:0] byteena,
    input wren,input [17:0] rdaddress,output reg [15:0] q);
reg [15:0] memory[0:153599];
always @(posedge clk) begin
    q<=memory[rdaddress];
    if(wren) begin
        if(byteena[0]) memory[wraddress][7:0]<=data[7:0];
        if(byteena[1]) memory[wraddress][15:8]<=data[15:8];
    end
end
endmodule
