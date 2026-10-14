`timescale 1ns/1ps
module BmpStream_tb;
parameter TAIL_REPLAY=1;
parameter SMOOTH_VIVID=0;
reg clk=0,reset=1,start=0,abort=0,ready=0;
reg [1:0] mode=1;
reg [3:0] scheme=0;reg [7:0] effects=0;
wire valid,request,preview_request,busy,done;
wire [7:0] data;wire [23:0] address;wire [17:0] pa;
wire [7:0] length;
reg accepted=0,word_done=0,word_valid=0;reg [31:0] word_q=0;
integer cycle=0,received=0,word_cycle=0,n,i,phase,expected,fd,word_index=0,request_words=0;
reg [23:0] base;reg [95:0] group;
reg [7:0] bytes[0:2047];reg [11:0] palettes[0:255];
reg [56:0] phases=0;
reg preview_accepted=0;
reg [15:0] preview_q=0;
always #5 clk=~clk;
BmpStream #(.PREVIEW_WIDTH(16),.PREVIEW_HEIGHT(3),.HD_WIDTH(16),.HD_HEIGHT(3),.UHD_WIDTH(24),.UHD_HEIGHT(2),.SMOOTH_VIVID(SMOOTH_VIVID)) dut (
    .clk(clk),.reset(reset),.start(start),.abort(abort),.mode(mode),.scheme(scheme),.color_offset(4'd0),.effects(effects),.phases(phases),
    .busy(busy),.done(done),.byte_valid(valid),.byte_data(data),.byte_ready(ready),.word_request(request),.word_address(address),
    .word_length(length),
    .word_accepted(accepted),.word_done(word_done),.word_valid(word_valid),.word_q(word_q),
    .preview_request(preview_request),.preview_address(pa),.preview_accepted(preview_accepted),.preview_q(preview_q));
function [11:0] raw;
    input integer x,y;integer index;
    begin index=x+y*3;raw=mode==0 ? {4'd0,4'(index/16),4'((64+3*index)/16)} : {4'(x),4'(y+2),4'(x+y)};end
endfunction
function [23:0] gradient;
    input integer x,y;reg [11:0] rgb,p,q;integer lum,w,r,g,b,minimum;
    begin rgb=raw(x,y);lum=rgb[11:8]+2*rgb[7:4]+rgb[3:0];w=(lum%4)*64;
        p=palettes[scheme*16+lum/4];q=palettes[scheme*16+(lum/4+1)%16];
        r=(17*(p[11:8]*(256-w)+q[11:8]*w)+128)/256;
        g=(17*(p[7:4]*(256-w)+q[7:4]*w)+128)/256;
        b=(17*(p[3:0]*(256-w)+q[3:0]*w)+128)/256;
        minimum=r;if(g<minimum) minimum=g;if(b<minimum) minimum=b;
        r=r+(r-minimum)/2;g=g+(g-minimum)/2;b=b+(b-minimum)/2;
        gradient=rgb==0 ? 24'd0 : {8'(r>255 ? 255 : r),8'(g>255 ? 255 : g),8'(b>255 ? 255 : b)};
    end
endfunction
function [11:0] map;
    input integer x,y;reg [11:0] rgb,p;integer lum,minimum,r,g,b;
    begin rgb=raw(x,y);lum=rgb[11:8]+2*rgb[7:4]+rgb[3:0];
        p=scheme==0 ? rgb : palettes[scheme*16+(scheme==1 ? lum/4 : lum%16)];
        if(scheme>1 && lum/4<4) p={1'b0,p[11:9],1'b0,p[7:5],1'b0,p[3:1]};
        if(effects[7]) begin minimum=p[11:8];if(p[7:4]<minimum) minimum=p[7:4];if(p[3:0]<minimum) minimum=p[3:0];
            r=p[11:8]+(p[11:8]-minimum)/2;g=p[7:4]+(p[7:4]-minimum)/2;b=p[3:0]+(p[3:0]-minimum)/2;
            p={4'(r>15 ? 15 : r),4'(g>15 ? 15 : g),4'(b>15 ? 15 : b)};end
        map=p;end
endfunction
always @(posedge clk) begin
    cycle=cycle+1;ready<=cycle%7!=0 && cycle%7!=1;
    accepted<=0;word_done<=0;word_valid<=0;
    preview_accepted<=preview_request && !preview_accepted && cycle%13>3;
    if(preview_request && !preview_accepted && cycle%13>3)
        preview_q<={8'((pa%320)*2+1+(pa/320)*3),8'((pa%320)*2+(pa/320)*3)};
    if(valid && ready) begin bytes[received]=data;received=received+1;end
    if(request && word_cycle==0) begin
        accepted<=1;base=mode==2 ? address-24'h100000 : address;
        request_words=length+1;word_index=0;word_cycle=1;
    end else if(word_cycle!=0) begin
        if(word_cycle%3==1 && word_cycle>=4 && word_index<request_words) begin
            for(n=0;n<8;n=n+1) group[n*12 +:12]=raw(((base+word_index)/3*8+n)%(mode==2 ? 24 : 16),((base+word_index)/3*8+n)/(mode==2 ? 24 : 16));
            word_valid<=1;
            word_q<=TAIL_REPLAY && word_index==request_words-1 ?
                {2{group[(word_index%3)*32 +:16]}} : group[(word_index%3)*32 +:32];
            word_index=word_index+1;word_cycle=word_cycle+1;
        end else if(word_cycle%3==1 && word_cycle>=4 && word_index==request_words) begin word_done<=1;word_cycle=0;end
        else word_cycle=word_cycle+1;
    end
end
task capture;
    integer x,y,p;reg [11:0] wanted;reg [23:0] wanted8;integer width,height;
    begin
        received=0;start=1;@(negedge clk);start=0;wait(done);@(negedge clk);ready=0;
        width=mode==2 ? 24 : 16;height=mode==2 ? 2 : 3;
        if(received!=54+width*height*3 || {bytes[1],bytes[0]}!=16'h4d42 || bytes[28]!=24 || bytes[10]!=54 ||
            {bytes[21],bytes[20],bytes[19],bytes[18]}!=width || $signed({bytes[25],bytes[24],bytes[23],bytes[22]})!=-height)
            $fatal(1,"BMP header/length");
        for(y=0;y<height;y=y+1) for(x=0;x<width;x=x+1) begin wanted=map(x,y);p=54+(y*width+x)*3;
            wanted8=SMOOTH_VIVID && effects[7] ? gradient(x,y) : {wanted[11:8],wanted[11:8],wanted[7:4],wanted[7:4],wanted[3:0],wanted[3:0]};
            if(bytes[p]!==wanted8[7:0] || bytes[p+1]!==wanted8[15:8] || bytes[p+2]!==wanted8[23:16])
                $fatal(1,"BMP RGB palette=%0d pixel=(%0d,%0d) expected=%h bytes=%h %h %h",scheme,x,y,wanted,bytes[p],bytes[p+1],bytes[p+2]);
        end
        abort=1;@(negedge clk);abort=0;repeat(4) @(negedge clk);
    end
endtask
initial begin
    $readmemh("tests/effect_palettes.hex",palettes);repeat(4) @(negedge clk);reset=0;
    for(i=0;i<16;i=i+1) begin scheme=4'(i);effects=0;capture();effects=8'h80;capture();end
    mode=2;for(i=0;i<16;i=i+1) begin scheme=4'(i);effects=0;capture();end
    mode=0;for(i=0;i<16;i=i+1) begin scheme=4'(i);effects=0;capture();effects=8'h80;capture();end
    $display("PASS: byte-exact BMP, all palettes, vividness, cached reads, injected tail halfword replay, stalled consumer, rows, UHD address and restart");$finish;
end
initial begin #5000000;$fatal(1,"BMP timeout state=%0d",dut.state);end
endmodule
