`timescale 1ns/1ps
// Independent RGB888 oracle, including a DAC-quantized history, rather than
// deriving expected colors from the shader's own functions/registers.
module HDGradient_tb;
parameter PIXEL_CYCLES=1;
reg clk=0,reset=1,active=1,pixel_tick=1,vivid=1,burn=0,morph=0,prism=0,glow=0,stoch=0,fuzz=0;
reg hs=1,vs=1;
reg [11:0] input_rgb=0;
reg [3:0] scheme=0,offset=0;
reg [11:0] x=0,y=0;
reg [56:0] phases=0;
wire [3:0] r,g,b,lr,lg,lb;
wire [7:0] r8,g8,b8;
wire oh,ov;
reg [11:0] palettes[0:255];
reg [23:0] golden[0:12],history[0:15],held=0;
reg gh[0:12],gv[0:12];
reg checking=0,legacy_checking=0;
integer valid=0,history_count=0,checks=0,fractional=0,legacy_checks=0;
integer i,j,look,flags,phase,pixel,mode;
reg [23:0] source,morphed,shaded,nearby,distant;
always #5 clk=~clk;
HDColorEffects #(.SMOOTH_VIVID(1),.EXTERNAL_PHASES(1),.X_BITS(12),.Y_BITS(12)) dut (
    .clk(clk),.reset(reset),.enabled(1'b1),.frame_tick(1'b0),
    .input_red(input_rgb[11:8]),.input_green(input_rgb[7:4]),.input_blue(input_rgb[3:0]),
    .input_hsync(hs),.input_vsync(vs),.color_scheme(scheme),.color_offset(offset),.burn_speed(2'd0),
    .burn_enable(burn),.stochastic_burn(stoch),.morph(morph),.prism(prism),.glow(glow),.pixel_tick(pixel_tick),
    .vivid(vivid),.fuzz(fuzz),.pixel_active(active),.pixel_x(x),.pixel_y(y),.phase_values(phases),.phase_state(),
    .red(r),.green(g),.blue(b),.red8(r8),.green8(g8),.blue8(b8),.hsync(oh),.vsync(ov),.selected());
HDColorEffects #(.EXTERNAL_PHASES(1),.X_BITS(12),.Y_BITS(12)) legacy (
    .clk(clk),.reset(reset),.enabled(1'b1),.frame_tick(1'b0),
    .input_red(input_rgb[11:8]),.input_green(input_rgb[7:4]),.input_blue(input_rgb[3:0]),
    .input_hsync(hs),.input_vsync(vs),.color_scheme(scheme),.color_offset(offset),.burn_speed(2'd0),
    .burn_enable(burn),.stochastic_burn(stoch),.morph(morph),.prism(prism),.glow(glow),.pixel_tick(pixel_tick),
    .vivid(vivid),.fuzz(fuzz),.pixel_active(active),.pixel_x(x),.pixel_y(y),.phase_values(phases),.phase_state(),
    .red(lr),.green(lg),.blue(lb),.hsync(),.vsync(),.selected());
function [7:0] clipped;
    input integer value;begin clipped=8'(value>255 ? 255 : value);end
endfunction
function [23:0] vivid_rgb;
    input [23:0] rgb;integer minimum,rr,gg,bb;
    begin rr=rgb[23:16];gg=rgb[15:8];bb=rgb[7:0];minimum=rr;if(gg<minimum) minimum=gg;if(bb<minimum) minimum=bb;
        vivid_rgb={clipped(rr+(rr-minimum)/2),clipped(gg+(gg-minimum)/2),clipped(bb+(bb-minimum)/2)};end
endfunction
function [23:0] base_color;
    input [11:0] rgb;input target;
    integer lum,tone,w,index,wave,target_scheme;
    reg [11:0] a,z;
    begin
        lum=rgb[11:8]+2*rgb[7:4]+rgb[3:0];
        tone=lum*64+(burn ? phases[31:16]/16 : 0);
        if(scheme==1) begin
            wave=phases[31:16]%32768/32;if(phases[31]) wave=1023-wave;
            tone=lum*64+(burn ? wave : 0);if(tone>3840) tone=3840;
        end
        tone=(tone+offset*256)%4096;index=tone/256;w=tone%256;
        target_scheme=scheme==1 ? 3 : scheme==2 ? (phases[47] ? 3 : 5) :
            scheme==5 ? (phases[47] ? 2 : 3) : (phases[47] ? 5 : 2);
        a=palettes[(target ? target_scheme : scheme)*16+index];
        z=palettes[scheme*16+(index+1)%16];
        if(target) begin w=0;z=a;end
        base_color=rgb==0 ? 24'd0 : {
            8'((17*(a[11:8]*(256-w)+z[11:8]*w)+128)/256),
            8'((17*(a[7:4]*(256-w)+z[7:4]*w)+128)/256),
            8'((17*(a[3:0]*(256-w)+z[3:0]*w)+128)/256)};
        base_color=vivid_rgb(base_color);
    end
endfunction
function [23:0] morph_color;
    input [23:0] a,z;integer w;
    begin w=morph ? phases[45:38] : 0;if(morph && phases[46]) w=255-w;
        morph_color={8'((a[23:16]*(256-w)+z[23:16]*w+128)/256),
            8'((a[15:8]*(256-w)+z[15:8]*w+128)/256),8'((a[7:0]*(256-w)+z[7:0]*w+128)/256)};end
endfunction
function [7:0] edge_color;
    input integer current,echo;integer d;
    begin d=current>echo ? current-echo : echo-current;edge_color=clipped(current+d/2);end
endfunction
function [23:0] history_color;
    input [23:0] rgb;
    begin history_color={8'(((rgb[23:16]+8)/17)*17),8'(((rgb[15:8]+8)/17)*17),8'(((rgb[7:0]+8)/17)*17)};end
endfunction
always @(posedge clk) begin
    if(checking) begin
        for(j=12;j>0;j=j-1) begin golden[j]=golden[j-1];gh[j]=gh[j-1];gv[j]=gv[j-1];end
        if(!active) begin history_count=0;held=0;end
        else if(pixel_tick) begin
            source=base_color(input_rgb,0);morphed=morph_color(source,base_color(input_rgb,1));shaded=morphed;
            if(prism) shaded={
                edge_color(morphed[23:16],history_count>=3 ? history[2][23:16] : morphed[23:16]),
                edge_color(morphed[15:8],history_count>=7 ? history[6][15:8] : morphed[15:8]),
                edge_color(morphed[7:0],history_count>=11 ? history[10][7:0] : morphed[7:0])};
            nearby=history_count>=8 ? history[7] : 24'd0;distant=history_count>=16 ? history[15] : 24'd0;
            held=glow ? {clipped(shaded[23:16]+nearby[23:16]/4+distant[23:16]/8),
                clipped(shaded[15:8]+nearby[15:8]/4+distant[15:8]/8),
                clipped(shaded[7:0]+nearby[7:0]/4+distant[7:0]/8)} : shaded;
            if(prism || glow) begin
                for(j=15;j>0;j=j-1) history[j]=history[j-1];history[0]=history_color(morphed);
                if(history_count<16) history_count=history_count+1;
            end else history_count=0;
        end
        golden[0]=held;gh[0]=hs;gv[0]=vs;valid=valid+1;
    end
    #1;
    if(checking && valid>12) begin
        if({r8,g8,b8}!==golden[12] || oh!==gh[12] || ov!==gv[12])
            $fatal(1,"RGB888 gradient/effect/latency look=%0d flags=%0d phase=%0d got=%h expected=%h",look,flags,phase,{r8,g8,b8},golden[12]);
        if(r!=(r8+8)/17 || g!=(g8+8)/17 || b!=(b8+8)/17) $fatal(1,"VGA DAC rounding");
        checks=checks+1;if(r8%17 || g8%17 || b8%17) fractional=fractional+1;
    end
    if(legacy_checking) begin
        if({r,g,b}!=={lr,lg,lb} || {r8,g8,b8}!=={lr,lr,lg,lg,lb,lb})
            $fatal(1,"SW8-off behavior changed look=%0d mode=%0d wide=%h legacy=%h",look,mode,{r8,g8,b8},{lr,lg,lb});
        legacy_checks=legacy_checks+1;
    end
end
task draw;
    input [11:0] value;input visible;integer k;
    begin input_rgb=value;active=visible;x=x+17;y=y+19;hs=x%11!=3;vs=y%17!=4;
        for(k=0;k<PIXEL_CYCLES;k=k+1) begin pixel_tick=k==0;@(negedge clk);end
    end
endtask
initial begin
    $readmemh("tests/effect_palettes.hex",palettes);repeat(4) @(negedge clk);reset=0;
    for(look=0;look<16;look=look+1) for(flags=0;flags<8;flags=flags+1) for(phase=0;phase<4;phase=phase+1) begin
        checking=0;scheme=look;offset=phase*5;burn=phase!=0;morph=flags[0];prism=flags[1];glow=flags[2];
        phases={1'b1,8'd0,16'(phase*6173),16'(phase*12345),16'd0};
        active=0;pixel_tick=1;repeat(40) @(negedge clk);
        history_count=0;valid=0;held=0;for(i=0;i<16;i=i+1) history[i]=0;checking=1;
        for(pixel=0;pixel<64;pixel=pixel+1) draw(pixel==0 ? 12'd0 : 12'(pixel*149),pixel!=31);
        draw(0,0);repeat(20) @(negedge clk);checking=0;
    end
    vivid=0;active=1;
    for(look=0;look<16;look=look+1) for(mode=0;mode<64;mode=mode+1) begin
        legacy_checking=0;scheme=look;offset=look;{fuzz,glow,morph,prism,stoch,burn}=mode[5:0];
        phases={1'b1,8'd77,16'd12345,16'd23456,16'd34567};
        pixel_tick=1;repeat(45) @(negedge clk);legacy_checking=1;
        for(pixel=0;pixel<24;pixel=pixel+1) draw(12'(pixel*157+mode*29),pixel%17!=0);
    end
    legacy_checking=0;
    if(checks<30000 || fractional<1000 || legacy_checks<20000) $fatal(1,"Gradient coverage");
    $display("PASS: %0d independent RGB888/effect/sync checks, %0d non-RGB444 outputs, %0d SW8-off legacy comparisons, all palettes, offsets, Morph/Prism/Glow, black/blanking and %0d clocks/pixel",checks,fractional,legacy_checks,PIXEL_CYCLES);$finish;
end
initial begin #10000000;$fatal(1,"Gradient timeout");end
endmodule
