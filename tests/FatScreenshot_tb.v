`timescale 1ns/1ps
module FatScreenshot_tb;
reg clk=0,reset=1,start=0,cancel=0,reject_write=0;
reg [31:0] size=1880;
wire busy,done,allocated,payload_start,payload_ready,sclk,cmd,cs,miso;
wire [7:0] error;wire [15:0] number;
integer i,n,position=0,saved_lba,fat0,fat1,data0,root0,first,cluster_count;
reg use32=0;
wire [7:0] payload=position<size ? 8'(position*37^8'ha5) : 8'd0;
always #5 clk=~clk;
FatScreenshot dut (.clk(clk),.reset(reset),.start(start),.cancel(cancel),.file_size(size),
    .busy(busy),.done(done),.error(error),.file_number(number),.allocation_ready(allocated),.begin_payload(1'b1),
    .payload_start(payload_start),.payload_valid(1'b1),.payload_data(payload),.payload_ready(payload_ready),
    .sd_clk(sclk),.sd_cmd(cmd),.sd_cs_n(cs),.sd_miso(miso));
defparam dut.card.INIT_DIV=2;
SpiCardModel card (.cs_n(cs),.sclk(sclk),.mosi(cmd),.miso(miso),.reject_write(reject_write));
always @(posedge clk) begin if(payload_start) position=0;if(payload_ready) position=position+1;end
task put16;
    input integer a,v;begin card.memory[a]=8'(v);card.memory[a+1]=8'(v>>8);end
endtask
task put32;
    input integer a,v;begin put16(a,v);put16(a+2,v>>16);end
endtask
function [31:0] get32;
    input integer a;begin get32={card.memory[a+3],card.memory[a+2],card.memory[a+1],card.memory[a]};end
endfunction
task fat;
    input integer cluster,value;
    begin if(use32) begin put32(fat0*512+cluster*4,value);put32(fat1*512+cluster*4,value);end
        else begin put16(fat0*512+cluster*2,value);put16(fat1*512+cluster*2,value);end end
endtask
task initialize_volume;
    input integer fat32_mode;
    integer b,total,j;
    begin
        use32=fat32_mode;for(j=0;j<2048*512;j=j+1) card.memory[j]=0;
        b=use32 ? 512 : 0;
        if(use32) begin put16(510,16'haa55);card.memory[450]=8'h0c;put32(454,1);end
        put16(b+510,16'haa55);put16(b+11,512);card.memory[b+13]=1;card.memory[b+16]=2;
        if(use32) begin
            put16(b+14,32);put32(b+32,66581);put32(b+36,512);put32(b+44,2);put16(b+48,1);put16(b+50,6);
            fat0=33;fat1=545;data0=1057;root0=1057;
            put32(2*512,32'h41615252);put32(2*512+484,32'h61417272);put32(2*512+508,32'haa550000);
            put32(8*512,32'h41615252);put32(8*512+484,32'h61417272);put32(8*512+508,32'haa550000);
            fat(0,32'h0ffffff8);fat(1,32'h0fffffff);fat(2,32'h0fffffff);
            for(j=0;j<16;j=j+1) begin
                card.memory[root0*512+j*32]=8'h4b;card.memory[root0*512+j*32+11]=8'h20;
                put16(root0*512+j*32+26,j+4);put32(root0*512+j*32+28,512);fat(j+4,32'h0fffffff);
            end
            for(j=20;j<24;j=j+1) fat(j,32'hb0000000);
        end else begin
            put16(b+14,1);put16(b+17,16);put16(b+19,5042);put16(b+22,20);
            fat0=1;fat1=21;root0=41;data0=42;fat(0,16'hfff8);fat(1,16'hffff);fat(3,16'hffff);
            card.memory[root0*512+0]=8'h46;card.memory[root0*512+1]=8'h52;card.memory[root0*512+2]=8'h41;card.memory[root0*512+3]=8'h43;
            for(j=4;j<8;j=j+1) card.memory[root0*512+j]=8'h30;
            card.memory[root0*512+8]=8'h42;card.memory[root0*512+9]=8'h4d;card.memory[root0*512+10]=8'h50;card.memory[root0*512+11]=8'h20;
            put16(root0*512+26,3);put32(root0*512+28,512);
            for(j=0;j<512;j=j+1) card.memory[(data0+1)*512+j]=8'h55;
        end
        reset=1;repeat(4) @(negedge clk);reset=0;
    end
endtask
task save;
    begin start=1;@(negedge clk);start=0;wait(done);@(negedge clk);if(error) $fatal(1,"FAT save error=%h state=%0d",error,dut.state);end
endtask
task expect_error;
    input [7:0] expected_error;
    begin start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
        if(error!=expected_error || busy) $fatal(1,"Expected FAT error %h, got %h",expected_error,error);end
endtask
task verify_payload;
    input integer cluster,bytes;
    integer j,a;
    begin a=(data0+cluster-2)*512;for(j=0;j<((bytes+511)/512)*512;j=j+1)
        if(card.memory[a+j]!==(j<bytes ? 8'(j*37^8'ha5) : 8'd0)) $fatal(1,"File data mismatch byte=%0d",j);end
endtask
initial begin
    initialize_volume(0);save();
    if(number!=1 || get32(root0*512+32+28)!=1880 || card.memory[root0*512+39]!=8'h31) $fatal(1,"Root name/size");
    verify_payload(4,1880);
    for(i=0;i<512;i=i+1) if(card.memory[(data0+1)*512+i]!=8'h55) $fatal(1,"Existing file overwritten");
    for(i=0;i<40*512;i=i+1) if(i<20*512 && card.memory[fat0*512+i]!==card.memory[fat1*512+i]) $fatal(1,"FAT copies differ");
    size=543;save();if(number!=2 || get32(root0*512+64+28)!=543) $fatal(1,"Second name/size");verify_payload(8,543);
    size=1880;start=1;@(negedge clk);start=0;wait(payload_start);wait(position>60);@(negedge clk);cancel=1;@(negedge clk);cancel=0;
    wait(done);@(negedge clk);if(error!=8'h40 || card.memory[root0*512+96]!=0) $fatal(1,"Cancel created a file");
    if(get32(fat0*512+20)!=0) $fatal(1,"Cancel allocated free clusters");
    initialize_volume(1);size=1300;save();verify_payload(20,1300);
    saved_lba=data0+23-2;
    if(number!=0 || get32(saved_lba*512)!=32'h43415246 || get32(saved_lba*512+28)!=1300) $fatal(1,"Extended FAT32 root/file");
    if((get32(fat0*512+2*4)&32'h0fffffff)!=23 || get32(fat0*512+20*4)!=32'hb0000015 || get32(fat0*512+23*4)!=32'hbfffffff)
        $fatal(1,"FAT32 chain or reserved nibble");
    if(get32(2*512+488)!=32'hffffffff || get32(8*512+488)!=32'hffffffff) $fatal(1,"FSInfo not invalidated");
    for(i=0;i<512;i=i+1) if(card.memory[fat0*512+i]!==card.memory[fat1*512+i]) $fatal(1,"FAT32 copies differ");
    initialize_volume(0);size=543;put16(22,1);saved_lba=card.writes;expect_error(8'h11);
    if(card.writes!=saved_lba) $fatal(1,"Invalid FAT capacity caused a write");
    initialize_volume(1);card.memory[512+40]=8'h82;saved_lba=card.writes;expect_error(8'h11);
    if(card.writes!=saved_lba) $fatal(1,"Invalid active FAT caused a write");
    initialize_volume(0);size=543;reject_write=1;expect_error(8'h88);reject_write=0;
    if(card.memory[root0*512+32]!=0 || get32(fat0*512+8)!=0) $fatal(1,"Rejected payload allocated/published a file");
    save();verify_payload(4,543);
    initialize_volume(0);size=3000000;saved_lba=card.writes;expect_error(8'h15);
    if(card.writes!=saved_lba || card.memory[root0*512+32]!=0) $fatal(1,"No-space preflight wrote card data");
    size=543;start=1;@(negedge clk);start=0;wait(dut.read_valid);@(negedge clk);cancel=1;@(negedge clk);cancel=0;
    wait(done);@(negedge clk);
    if(error!=8'h40 || !cs || card.writes!=saved_lba) $fatal(1,"Read/preflight cancel failed to release card");
    $display("PASS: actual SD SPI FAT16/FAT32 file creation, MBR, automatic names, byte-exact contents, FAT mirrors, preserved existing files, cancellation, root growth and FSInfo");$finish;
end
initial begin #50000000;$fatal(1,"FAT timeout state=%0d card=%0d",dut.state,dut.card.state);end
endmodule
