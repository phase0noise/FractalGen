`timescale 1ns/1ps
// Complete PS/2 -> actual orbit workers -> shared SDRAM -> BMP -> FAT ->
// physical SD SPI pins. Shrink only the off-screen raster to keep it fast.
module MandelScreenshot_tb;
reg clk=0;
always #10 clk=~clk;
reg [9:0] sw=10'b1100000000;
tri1 ps_clk,ps_data;
reg ps_clock=1,ps_bits=1;
assign ps_clk=ps_clock ? 1'bz : 1'b0;
assign ps_data=ps_bits ? 1'bz : 1'b0;
wire sclk,cmd,miso;
tri [3:0] sd_data;
assign sd_data[0]=miso;
tri [15:0] dq;
wire hs,vs;
integer i,j,fd,first,completed=0,commits=0,job_pixels=0;
reg [127:0] seen=0;
reg [11:0] expected_pixels[0:127];
reg [7:0] expected_bmp[0:437];
reg [12:0] hs_history=13'h1fff,vs_history=13'h1fff;
Mandel #(.SCREENSHOT_UHD_WIDTH(16),.SCREENSHOT_UHD_HEIGHT(8)) dut (
    .CLOCK_50(clk),.SW(sw),.KEY(4'b1111),.LEDR(),.VGA_R(),.VGA_G(),.VGA_B(),.VGA_HS(hs),.VGA_VS(vs),
    .PS2_CLK(ps_clk),.PS2_DAT(ps_data),.SD_CLK(sclk),.SD_CMD(cmd),.SD_DATA(sd_data),.DRAM_DQ(dq),
    .DRAM_ADDR(),.DRAM_BA(),.DRAM_CAS_N(),.DRAM_CKE(),.DRAM_CLK(),.DRAM_CS_N(),
    .DRAM_LDQM(),.DRAM_RAS_N(),.DRAM_UDQM(),.DRAM_WE_N());
defparam dut.screenshot_file.card.INIT_DIV=2;
SpiCardModel card (.cs_n(sd_data[3]),.sclk(sclk),.mosi(cmd),.miso(miso),.reject_write(1'b0));
task put16;
    input integer a,v;begin card.memory[a]=8'(v);card.memory[a+1]=8'(v>>8);end
endtask
function [31:0] get32;
    input integer a;begin get32={card.memory[a+3],card.memory[a+2],card.memory[a+1],card.memory[a]};end
endfunction
task send_bit;
    input value;
    begin ps_bits=value;repeat(8) @(negedge clk);ps_clock=0;repeat(8) @(negedge clk);ps_clock=1;repeat(8) @(negedge clk);end
endtask
task send_byte;
    input [7:0] value;integer b;reg [10:0] frame;
    begin frame={1'b1,~^value,value,1'b0};for(b=0;b<11;b=b+1) send_bit(frame[b]);ps_bits=1;repeat(8) @(negedge clk);end
endtask
task tap;
    input [7:0] value;begin send_byte(value);send_byte(8'hf0);send_byte(value);end
endtask
task capture;
    begin tap(8'h78);wait(dut.screenshot_finished);@(negedge clk);
        if(dut.screenshot_error || dut.screenshot_busy || job_pixels!=128 || seen!={128{1'b1}})
            $fatal(1,"Complete screenshot error=%h pixels=%0d",dut.screenshot_error,job_pixels);
        completed=completed+1;end
endtask
task verify_file;
    input integer entry_number,cluster;
    integer p,a;
    begin
        a=41*512+entry_number*32;
        if(get32(a)!=32'h43415246 || card.memory[a+7]!=8'h30+entry_number ||
            get32(a+28)!=438 || {card.memory[a+27],card.memory[a+26]}!=cluster) $fatal(1,"Root BMP name/size/cluster");
        a=(42+cluster-2)*512;
        for(p=0;p<512;p=p+1) if(card.memory[a+p]!==(p<438 ? expected_bmp[p] : 8'd0))
            $fatal(1,"Saved BMP differs from independent fractal/palette reference: byte=%0d expected=%h actual=%h",p,expected_bmp[p],card.memory[a+p]);
        if({card.memory[512+cluster*2+1],card.memory[512+cluster*2]}!=16'hffff ||
            card.memory[512+cluster*2]!==card.memory[21*512+cluster*2]) $fatal(1,"FAT root file allocation");
    end
endtask
always @(posedge clk) begin
    if(dut.engine_reset) begin hs_history<=13'h1fff;vs_history<=13'h1fff;end
    else begin
        hs_history<={hs_history[11:0],dut.raw_preview_hs};vs_history<={vs_history[11:0],dut.raw_preview_vs};
        if(dut.uhd_start) begin seen=0;job_pixels=0;end
        if(dut.buffer_write && dut.buffer_ultra) begin
            // commit_word may have moved on; the registered RAM address tags
            // are the stable source accompanying this registered data stage.
            i=(dut.buffer_write_address/640)*16+dut.buffer_write_address%640;
            if(i>=128 || seen[i] || dut.buffer_data[11:0]!==expected_pixels[i])
                $fatal(1,"Actual supersampled worker pixel %0d: %h expected %h",i,dut.buffer_data,expected_pixels[i]);
            seen[i]=1;job_pixels=job_pixels+1;commits=commits+1;
        end
        if(dut.uhd_busy && !sd_data[3]) $fatal(1,"SD data token open during long render");
        #1;
        if(hs!==hs_history[12] || vs!==vs_history[12] || dut.hd_selected)
            $fatal(1,"Capture changed monitor timing or resolution");
    end
end
initial begin
    $readmemh("output_files/sim/screenshot_pixels.hex",expected_pixels);$readmemh("output_files/sim/screenshot_bmp.hex",expected_bmp);
    for(j=0;j<2048*512;j=j+1) card.memory[j]=0;
    put16(510,16'haa55);put16(11,512);card.memory[13]=1;put16(14,1);card.memory[16]=2;
    put16(17,16);put16(19,5042);put16(22,20);
    put16(512,16'hfff8);put16(514,16'hffff);put16(21*512,16'hfff8);put16(21*512+2,16'hffff);
    force dut.latch=0;
    force dut.u1.center_x_active=32'sd83886080;force dut.u1.center_y_active=32'sd0;
    force dut.u1.zoom_active=32'd46976205;force dut.u1.lens_active=0;
    repeat(8) @(negedge clk);sw[9]=0;wait(!dut.engine_reset);tap(8'h1e);
    if(dut.color_scheme!=1 || dut.settings!=8'h80) $fatal(1,"Real keyboard palette/switch selection");
    capture();verify_file(0,2);
    fd=$fopen("output_files/sim/FRAC0000.BMP","wb");
    for(j=0;j<438;j=j+1) $fwrite(fd,"%c",card.memory[42*512+j]);$fclose(fd);
    capture();verify_file(1,3);verify_file(0,2);
    tap(8'h78);wait(dut.screenshot_file.payload_start);wait(dut.screenshot_file.card.position>80);
    tap(8'h76);wait(dut.screenshot_finished);@(negedge clk);
    if(dut.screenshot_error || card.memory[41*512+64]!=0 || get32(512+8)!=0) $fatal(1,"Cancel allocated/published a BMP");
    capture();verify_file(2,4);verify_file(0,2);verify_file(1,3);
    $display("PASS: %0d complete actual-PS/2 screenshots, %0d real supersampled worker commits, independent orbit/BMP reference, SDRAM DMA, SD pins, FAT root auto names, cancellation and preserved VGA timing",completed,commits);$finish;
end
initial begin #30000000;$fatal(1,"Screenshot integration timeout control=%0d UHD=%0d FS=%0d",dut.screenshot.state,dut.uhd_render.state,dut.screenshot_file.state);end
endmodule

module RenderClocks(input refclk,reset,output engine_clk,sdram_clk,pixel_hd_clk,engine_locked,pixel_locked);
assign engine_clk=refclk;assign pixel_hd_clk=refclk;assign sdram_clk=~refclk;assign engine_locked=1;assign pixel_locked=1;
endmodule
module FrameBuffer(input clk,input [15:0] data,input [17:0] wraddress,input [1:0] byteena,input wren,input [17:0] rdaddress,output reg [15:0] q);
always @(posedge clk) begin q<=16'h0000;if(wren) $fatal(1,"UHD wrote preview staging RAM");end
endmodule
// Native words are checked here; HDVideoScreenshot_tb separately tests the
// actual SDRAM PHY at worst-case read timing and refresh during VGA scanout.
module io_sdram (
    input controller_clk,chip_clk,clk_90,reset_n,output phy_cke,phy_clk,phy_cas,phy_ras,phy_we,
    output [1:0] phy_ba,output [12:0] phy_a,inout [15:0] phy_dq,output [1:0] phy_dqm,
    input burst_rd,input [24:0] burst_addr,input [10:0] burst_len,input burst_32bit,
    output [15:0] burst_data,output burst_data_valid,burst_data_done,input burstwr,input [24:0] burstwr_addr,
    output burstwr_ready,input burstwr_strobe,input [15:0] burstwr_data,input burstwr_done,
    input word_rd,word_wr,input [23:0] word_addr,input [31:0] word_data,input [3:0] word_wstrb,input [7:0] word_burst_len,
    output reg [31:0] word_q,output reg word_busy,word_q_valid
);
reg [31:0] memory[0:48];
integer cursor=0,beats=0,delay=0;
initial begin word_busy=0;word_q_valid=0;end
always @(posedge controller_clk) begin
    word_q_valid<=0;
    if(!reset_n) begin word_busy<=0;beats=0;delay=0;end
    else if(word_busy) begin
        if(delay!=0) delay=delay-1;
        else if(beats!=0) begin word_q<=memory[cursor];word_q_valid<=1;cursor=cursor+1;beats=beats-1;delay=2;end
        else word_busy<=0;
    end else if(word_rd || word_wr) begin
        if(word_addr<24'h100000 || word_addr>=24'h100030 || word_wstrb!=4'hf) $fatal(1,"UHD memory bounds/address/mask");
        word_busy<=1;cursor=word_addr-24'h100000;delay=7;
        if(word_wr) begin memory[cursor]=word_data;beats=0;end else beats=word_burst_len+1;
    end
end
endmodule
