`timescale 1ns/1ps
module HDColorEffects_tb;
reg clk=0,reset=1,enabled=1,tick=0,cycle=0,vivid=0,glitch=0,active=1,hs=0,vs=0;
reg stochastic=0,burn=0,smoothing=0;
reg [3:0] offset=0;
reg [3:0] palette=0;
reg [1:0] speed=0;
reg [11:0] input_rgb=0;
reg [10:0] x=0;
reg [9:0] y=0;
wire [3:0] r,g,b;
wire oh,ov,selected;
reg checking=0;
reg [11:0] expected[0:12];
reg eh[0:12],ev[0:12],es[0:12];
integer checks=0,valid=0,phase=0,fire_phase=0,divider=0,round_number=0;
integer i,j,mode,bright,pace,changed=0;
reg [15:0] noise=16'h1ace;
reg [11:0] palettes[0:255];
initial begin
    $readmemh("tests/effect_palettes.hex",palettes);
end
HDColorEffects dut (.clk(clk),.reset(reset),.enabled(enabled),.frame_tick(tick),
    .input_red(input_rgb[11:8]),.input_green(input_rgb[7:4]),.input_blue(input_rgb[3:0]),
    .input_hsync(hs),.input_vsync(vs),.color_scheme(palette),.color_offset(offset),.burn_speed(speed),.burn_enable(burn),
    .stochastic_burn(stochastic),.morph(1'b0),.pixel_tick(1'b1),
    .prism(1'b0),.glow(1'b0),.vivid(vivid),.fuzz(glitch),.pixel_active(active),.pixel_x(x),.pixel_y(y),
    .red(r),.green(g),.blue(b),.hsync(oh),.vsync(ov),.selected(selected));
always #4.63 clk=~clk;
function [11:0] reference;
    input [11:0] rgb;
    input integer look,hue,flame,px,py,round_value;
    input bright,fuzz,pixel_on,stoch,running;
    input integer manual;
    input fine_mode;
    input [15:0] random_bits;
    integer a[0:2],b[0:2],out[0:2],k,lum,field,wave,heat,w,sector,minimum,epoch,slot,step,roll_hue,rounding,wave_fine;
    reg [31:0] hash,seed;
    reg [11:0] color,next_color;
    reg fine;
    begin
        a[0]=rgb[11:8]; a[1]=rgb[7:4]; a[2]=rgb[3:0]; b[0]=0; b[1]=0; b[2]=0;
        lum=(a[0]+2*a[1]+a[2])/4;
        epoch=round_value/8; seed=1;
        for(k=0;k<6;k=k+1) seed=seed | (32'(epoch)<<(2+5*k));
        hash=32'((py<<11)|px)^seed^32'h9e3779b9;
        hash=hash+(hash<<10); hash=hash^(hash>>6);
        hash=hash+(hash<<3); hash=hash^(hash>>11); hash=hash+(hash<<15);
        slot=hash[31:29]^hash[2:0]; step=(epoch+(round_value%8>slot?1:0))%32;
        fine=fine_mode && running && !stoch;
        rounding=128; w=0;
        if(look==1) begin
            field=!running ? 0 : stoch && pixel_on ? step%8 : (flame/8192)%8;
            wave=field%4; if(field>=4) wave=3-wave;
            if(fine) begin
                wave_fine=(flame%32768)/32; if(flame>=32768) wave_fine=1023-wave_fine;
                wave=wave_fine/256; w=wave_fine%256;
            end
            heat=lum+wave; if(heat>=15) begin heat=15; w=0; end
            field=(heat+manual)%16;
            color=rgb==0 ? 12'd0 : palettes[look*16+field];
            next_color=rgb==0 ? 12'd0 : palettes[look*16+(field+1)%16];
            a[0]=color[11:8]; a[1]=color[7:4]; a[2]=color[3:0];
            b[0]=next_color[11:8]; b[1]=next_color[7:4]; b[2]=next_color[3:0];
        end else if(look>1) begin
            field=(a[0]+2*a[1]+a[2]+manual+(!running ? 0 : stoch && pixel_on ? step : flame/4096))%16;
            color=rgb==0 ? 12'd0 : palettes[look*16+field];
            next_color=rgb==0 ? 12'd0 : palettes[look*16+(field+1)%16];
            a[0]=color[11:8]; a[1]=color[7:4]; a[2]=color[3:0];
            b[0]=next_color[11:8]; b[1]=next_color[7:4]; b[2]=next_color[3:0];
            if(lum<4) for(k=0;k<3;k=k+1) begin a[k]=a[k]/2; b[k]=b[k]/2; end
            if(fine) w=(flame%4096)/16;
        end
        if(look==0) begin
            roll_hue=(manual*3072+(!running ? 0 : stoch && pixel_on ? (step%8)*6144 : hue))%49152;
            sector=roll_hue/16384; w=fine ? (roll_hue%16384)/64 : ((roll_hue%16384)/1024)*16;
            for(k=0;k<3;k=k+1) out[k]=(a[(k+sector)%3]*(256-w)+a[(k+sector+1)%3]*w+rounding)/256;
        end else for(k=0;k<3;k=k+1) out[k]=(a[k]*(256-w)+b[k]*w+rounding)/256;
        minimum=out[0]; for(k=1;k<3;k=k+1) if(out[k]<minimum) minimum=out[k];
        if(bright) for(k=0;k<3;k=k+1) begin
            out[k]=out[k]+(out[k]-minimum)/2; if(out[k]>15) out[k]=15;
        end
        color={4'(out[0]),4'(out[1]),4'(out[2])};
        if(fuzz && pixel_on && random_bits%32<5) color=color ^ random_bits[15:4];
        reference=pixel_on ? color : 12'd0;
    end
endfunction
always @(posedge clk) begin
    if(reset) begin phase=0; fire_phase=0; divider=0; round_number=0; noise=16'h1ace; smoothing=0; end
    else begin
        if(checking) begin
            for(j=12;j>0;j=j-1) begin expected[j]=expected[j-1]; eh[j]=eh[j-1]; ev[j]=ev[j-1]; es[j]=es[j-1]; end
            expected[0]=reference(input_rgb,palette,phase,fire_phase,x,y,round_number,vivid,glitch,active,stochastic,burn,offset,smoothing,noise);
            eh[0]=hs; ev[0]=vs; es[0]=enabled; valid=valid+1;
        end
        if(speed!=0) smoothing=speed==1;
        if(!enabled) begin phase=0; fire_phase=0; divider=0; round_number=0; noise=16'h1ace; end
        else begin
            noise={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
            if(!stochastic || !burn) round_number=0;
            if(tick) begin
                if(burn && speed==3) begin
                    fire_phase=(fire_phase+3072)%65536; phase=(phase+768)%49152;
                    if(stochastic) round_number=(round_number+2)%256;
                end else if(burn && speed==2) begin fire_phase=(fire_phase+1024)%65536; phase=(phase+256)%49152;
                    if(stochastic) round_number=(round_number+1)%256;
                end else if(burn && speed==1) begin
                    fire_phase=(fire_phase+64)%65536; phase=(phase+64)%49152;
                    if(stochastic && divider==15) round_number=(round_number+1)%256;
                end
                divider=speed==1 ? (divider+1)%16 : 0;
            end
        end
        #1;
        if(checking && valid>=13) begin
            if({r,g,b}!==expected[12] || oh!==eh[12] || ov!==ev[12] || selected!==es[12])
                $fatal(1,"Effect mismatch mode=%0d speed=%0d phase=%0d flame=%0d expected=%h actual=%h",palette,speed,phase,fire_phase,expected[12],{r,g,b});
            checks=checks+1;
        end
    end
end
task settle;
    begin
        checking=0; valid=0; tick=0; repeat(20) @(negedge clk); checking=1;
    end
endtask
initial begin
    repeat(4) @(negedge clk); reset=0;
    for(mode=0;mode<16;mode=mode+1) for(bright=0;bright<2;bright=bright+1) begin
        palette=4'(mode); vivid=bright; cycle=0; settle();
        for(i=0;i<4096;i=i+1) begin
            input_rgb=12'(i); x=11'(i); y=10'(i/7); hs=i[1]; vs=i[5]; @(negedge clk);
        end
    end
    burn=1;
    for(mode=0;mode<16;mode=mode+1) for(pace=0;pace<4;pace=pace+1) begin
        palette=4'(mode); speed=2'(pace); vivid=1; cycle=1; settle(); tick=1;
        for(i=0;i<512;i=i+1) begin input_rgb=12'(i*197); x=11'(i*3); y=10'(i/3); hs=i[0]; vs=i[4]; @(negedge clk); end
    end
    stochastic=1; cycle=0;
    for(mode=0;mode<16;mode=mode+1) begin
        palette=4'(mode); speed=2; vivid=0; settle(); tick=1;
        for(i=0;i<512;i=i+1) begin input_rgb=12'(i*197); x=11'(i*3); y=10'(i/3); @(negedge clk); end
    end
    stochastic=0; burn=0; speed=0;
    for(mode=0;mode<16;mode=mode+1) for(pace=0;pace<16;pace=pace+1) begin
        palette=4'(mode); offset=4'(pace); vivid=0; settle();
        for(i=0;i<64;i=i+1) begin input_rgb=12'(i*137); @(negedge clk); end
    end
    offset=0; enabled=0; settle(); enabled=1;
    cycle=0; palette=0; speed=0; vivid=0; glitch=1; settle();
    for(i=0;i<4096;i=i+1) begin
        active=i%4!=0; input_rgb=active?12'habc:12'd0; y=10'(i/16); x=11'(i);
        @(negedge clk); if({r,g,b}!=0 && {r,g,b}!=12'habc) changed=changed+1;
    end
    if(changed<100) $fatal(1,"Glitch did not visibly corrupt pixels");
    glitch=0; enabled=0; active=0; input_rgb=0; settle(); repeat(16) @(negedge clk);
    if(checks<93000) $fatal(1,"Effects coverage incomplete");
    $display("PASS: %0d color/sync checks, sixteen palettes, four speeds, 16 manual shifts, burn-off, smooth Slow, preserved vivid spectrum, stochastic steps, fuzz and blanking",checks);
    $finish;
end
initial begin #3000000; $fatal(1,"HD effects timeout"); end
endmodule
