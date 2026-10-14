`timescale 1ns/1ps
// Color/edge oracles, fixed geometry and measurable per-frame smoothness.
module MorphEffects_tb;
parameter PIXEL_CYCLES=1;
reg clk=0,reset=1,enabled=1,tick=0,pixel_tick=0,active=0,morph=1,prism=0,glow=0,hs=0,vs=0,burn=0,uniform_image=0;
reg [1:0] speed=2;
reg [3:0] palette=2;
reg [10:0] x=0;
reg [9:0] y=0;
reg [11:0] rgb=0;
wire [3:0] r,g,b;
wire oh,ov,selected;
reg [11:0] palettes[0:255],expected[0:12],previous[0:511],current[0:511];
reg eh[0:12],ev[0:12];
integer tags[0:12];
reg checking=0;
integer phase=0,fire=0,valid=0,checks=0,j,frame,px,row,cycle,mode,look,sample=-1,received=0,changed,delta,channel,i,changed_frames=0;
HDColorEffects dut (.clk(clk),.reset(reset),.enabled(enabled),.frame_tick(tick),
    .input_red(rgb[11:8]),.input_green(rgb[7:4]),.input_blue(rgb[3:0]),
    .input_hsync(hs),.input_vsync(vs),.color_scheme(palette),.color_offset(4'd0),
    .burn_speed(speed),.burn_enable(burn),.stochastic_burn(1'b0),
    .morph(morph),.prism(prism),.glow(glow),.pixel_tick(pixel_tick),
    .vivid(1'b0),.fuzz(1'b0),.pixel_active(active),.pixel_x(x),.pixel_y(y),
    .red(r),.green(g),.blue(b),.hsync(oh),.vsync(ov),.selected(selected));
always #5 clk=~clk;
function [11:0] pattern;
    input integer px,py;
    begin pattern=px%17==5 ? 12'd0 : {4'((px*3+py*5)%14+2),4'((px+py*3)%14+2),4'((px*7+py*11)%14+2)}; end
endfunction
function [11:0] vivid_color;
    input [11:0] value;
    integer a[0:2],k,minimum;
    begin a[0]=value[11:8]; a[1]=value[7:4]; a[2]=value[3:0];
        minimum=a[0]; for(k=1;k<3;k=k+1) if(a[k]<minimum) minimum=a[k];
        for(k=0;k<3;k=k+1) begin a[k]=a[k]+(a[k]-minimum)/2; if(a[k]>15) a[k]=15; end
        vivid_color={4'(a[0]),4'(a[1]),4'(a[2])}; end
endfunction
function [11:0] mapped;
    input integer px,py;
    integer lum,field,weight,k,secondary,out[0:2],rounding;
    reg [11:0] raw,current_color,next_color,target;
    begin
        raw=uniform_image ? 12'h693 : pattern(px,py);
        lum=raw[11:8]+2*raw[7:4]+raw[3:0];
        field=palette==1 ? lum/4 : (lum+(burn?fire/4096:0))%16;
        current_color=palette==0 ? raw : palettes[palette*16+field];
        next_color=palettes[palette*16+(field+1)%16];
        if(palette>1 && lum/4<4) begin
            current_color={1'b0,current_color[11:9],1'b0,current_color[7:5],1'b0,current_color[3:1]};
            next_color={1'b0,next_color[11:9],1'b0,next_color[7:5],1'b0,next_color[3:1]};
        end
        rounding=128;
        weight=burn ? (fire%4096)/16 : 0;
        if(burn) begin
            for(k=0;k<3;k=k+1) out[k]=(current_color[k*4 +:4]*(256-weight)+next_color[k*4 +:4]*weight+rounding)/256;
            current_color={4'(out[2]),4'(out[1]),4'(out[0])};
        end
        if(morph || prism || glow) current_color=vivid_color(current_color);
        secondary=palette==1 ? 3 : palette==2 ? (phase>=32768 ? 3 : 5) :
            palette==5 ? (phase>=32768 ? 2 : 3) : (phase>=32768 ? 5 : 2);
        target=palettes[secondary*16+field];
        if(palette!=1 && lum/4<4) target={1'b0,target[11:9],1'b0,target[7:5],1'b0,target[3:1]};
        if(morph || prism || glow) target=vivid_color(target);
        weight=!morph ? 0 : (phase%32768)<16384 ? (phase%16384)/64 : 255-(phase%16384)/64;
        for(k=0;k<3;k=k+1) out[k]=(current_color[k*4 +:4]*(256-weight)+target[k*4 +:4]*weight+rounding)/256;
        mapped=px<0 || raw==0 ? 12'd0 : {4'(out[2]),4'(out[1]),4'(out[0])};
    end
endfunction
function [11:0] reference;
    input integer px,py;
    integer k,out[0:2],diff;
    reg [11:0] current_color,nearby,distant,echo_r,echo_g,echo_b;
    begin
        current_color=mapped(px,py);
        echo_r=px<3 ? current_color : mapped(px-3,py);
        echo_g=px<7 ? current_color : mapped(px-7,py);
        echo_b=px<11 ? current_color : mapped(px-11,py);
        nearby=mapped(px-8,py); distant=mapped(px-16,py);
        for(k=0;k<3;k=k+1) begin
            out[k]=current_color[k*4 +:4];
            if(prism) begin
                diff=k==2 ? echo_r[11:8] : k==1 ? echo_g[7:4] : echo_b[3:0];
                diff=out[k]-diff; if(diff<0) diff=-diff;
                out[k]=out[k]+diff/2; if(out[k]>15) out[k]=15;
            end
            if(glow) out[k]=out[k]+nearby[k*4 +:4]/4+distant[k*4 +:4]/8;
            if(out[k]>15) out[k]=15;
        end
        reference={4'(out[2]),4'(out[1]),4'(out[0])};
    end
endfunction
always @(posedge clk) if(!reset && checking) begin
    for(j=12;j>0;j=j-1) begin expected[j]=expected[j-1]; eh[j]=eh[j-1]; ev[j]=ev[j-1]; tags[j]=tags[j-1]; end
    expected[0]=active ? reference(x,y) : 12'd0; eh[0]=hs; ev[0]=vs;
    tags[0]=active && pixel_tick ? sample : -1; valid=valid+1;
    #1;
    if(valid>=13) begin
        if({r,g,b}!==expected[12] || oh!==eh[12] || ov!==ev[12] || !selected)
            $fatal(1,"Morph/edge mismatch cadence=%0d phase=%0d palette=%0d effects=%b%b%b pixel=(%0d,%0d) expected=%h actual=%h",
                PIXEL_CYCLES,phase,palette,morph,prism,glow,x,y,expected[12],{r,g,b});
        checks=checks+1;
        if(tags[12]>=0) begin current[tags[12]]={r,g,b}; received=received+1; end
    end
end
task frame_tick;
    begin tick=1; @(negedge clk); tick=0; repeat(16) @(negedge clk); end
endtask
task image;
    input integer width,height;
    begin
        received=0;
        for(row=0;row<height;row=row+1) begin
            for(px=0;px<width;px=px+1) begin
                x=11'(px); y=10'(row); active=1; rgb=uniform_image ? 12'h693 : pattern(px,row);
                hs=px[2]; vs=row[0]; sample=uniform_image ? row*width+px : -1;
                for(cycle=0;cycle<PIXEL_CYCLES;cycle=cycle+1) begin pixel_tick=cycle==0; @(negedge clk); end
            end
            sample=-1; active=0; rgb=0; hs=0; vs=0; pixel_tick=0; repeat(16) @(negedge clk);
        end
        if(uniform_image && received!=512) $fatal(1,"Smoothness image was incomplete");
    end
endtask
task remember;
    begin for(i=0;i<512;i=i+1) previous[i]=current[i]; end
endtask
task check_step;
    begin
        changed=0;
        for(i=0;i<512;i=i+1) begin
            if(current[i]!=previous[i]) changed=changed+1;
            if(current[i]!==current[0]) $fatal(1,"Uniform input acquired spatial color dots");
            for(channel=0;channel<3;channel=channel+1) begin
                delta=integer'(current[i][channel*4 +:4])-integer'(previous[i][channel*4 +:4]);
                if(delta>1 || delta < -1) $fatal(1,"Slow jumped by %0d DAC levels in one frame",delta);
            end
        end
        if(changed!=0 && changed!=512) $fatal(1,"Uniform color changed only some pixels");
        if(changed!=0) changed_frames=changed_frames+1;
        remember();
    end
endtask
initial begin
    $readmemh("tests/effect_palettes.hex",palettes); for(i=0;i<13;i=i+1) tags[i]=-1;
    repeat(4) @(negedge clk); reset=0; repeat(20) @(negedge clk); checking=1;
    for(frame=0;frame<=256;frame=frame+1) begin
        if(frame>0) begin frame_tick(); phase=(frame*256)%65536; end
        image(96,2);
    end
    for(look=0;look<16;look=look+1) for(mode=0;mode<8;mode=mode+1) begin
        morph=0; repeat(20) @(negedge clk); phase=0;
        palette=4'(look); morph=mode[0]; prism=mode[1]; glow=mode[2];
        repeat(20) @(negedge clk); image(96,2);
        if(morph) begin repeat(64) frame_tick(); phase=16384; image(96,2); end
    end
    // With a four-bit DAC, fractional motion rounds uniformly across the
    // image. Held frames are expected; individual scattered changes are not.
    morph=0; prism=0; glow=0; palette=2; uniform_image=1; speed=1;
    repeat(20) @(negedge clk); phase=0; morph=1; repeat(20) @(negedge clk);
    image(64,8); remember();
    for(frame=1;frame<=32;frame=frame+1) begin frame_tick(); phase=frame*64; image(64,8); check_step(); end
    if(changed_frames==0) $fatal(1,"Slow Morph never advanced");
    speed=0; repeat(20) @(negedge clk); repeat(8) frame_tick(); image(64,8);
    for(i=0;i<512;i=i+1) if(current[i]!==previous[i]) $fatal(1,"Still failed to hold the fractional Morph color");
    morph=0; phase=0; speed=1; burn=1; changed_frames=0; repeat(20) @(negedge clk); image(64,8); remember();
    for(frame=1;frame<=32;frame=frame+1) begin frame_tick(); fire=frame*64; image(64,8); check_step(); end
    if(changed_frames==0) $fatal(1,"Slow Burn never advanced");
    speed=0; repeat(20) @(negedge clk); repeat(8) frame_tick(); image(64,8);
    for(i=0;i<512;i=i+1) if(current[i]!==previous[i]) $fatal(1,"Still failed to hold the fractional Burn color");
    checking=0; active=0; rgb=0; enabled=0; repeat(20) @(negedge clk);
    if(selected || {r,g,b}!==0) $fatal(1,"Disable did not flush output");
    $display("PASS: %0d color/sync samples, all sixteen palettes and Morph/Prism/Glow combinations, uniform colors without spatial dots, bounded Slow steps, exact Still hold (pixel cycles=%0d)",checks,PIXEL_CYCLES);
    $finish;
end
initial begin #12000000; $fatal(1,"Morph effects timeout"); end
endmodule
