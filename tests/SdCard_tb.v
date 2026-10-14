`timescale 1ns/1ps
module SdCard_tb;
parameter SDSC=0;
reg clk=0,reset=1,initialize=0,request=0,write_sector=0,write_valid=1,reject_write=0;
reg [31:0] lba=17;
wire ready,busy,accepted,done,rv,wr,sclk,cmd,cs,miso;
wire [8:0] ri;wire [7:0] rd,error;
integer read_count=0,write_count=0,i,cycles=0;
wire [7:0] data=8'(write_count*37+11);
always #5 clk=~clk;
SdCard #(.INIT_DIV(2),.FAST_DIV(2)) dut (.clk(clk),.reset(reset),.initialize(initialize),.request(request),
    .write_sector(write_sector),.lba(lba),.ready(ready),.busy(busy),.accepted(accepted),.done(done),.error(error),
    .read_valid(rv),.read_index(ri),.read_data(rd),.read_ready(1'b1),.write_valid(write_valid),.write_data(data),
    .write_ready(wr),.sd_clk(sclk),.sd_cmd(cmd),.sd_cs_n(cs),.sd_miso(miso));
SpiCardModel #(.SDSC(SDSC)) card (.cs_n(cs),.sclk(sclk),.mosi(cmd),.miso(miso),.reject_write(reject_write));
always @(posedge clk) begin
    cycles=cycles+1;write_valid<=cycles%19!=0 && cycles%19!=1;
    if(rv) begin if(ri!=read_count || rd!==8'(read_count^8'ha5)) $fatal(1,"Read byte %0d/%0d %h",read_count,ri,rd);read_count=read_count+1;end
    if(wr) write_count=write_count+1;
end
task launch;
    begin request=1;@(negedge clk);request=0;wait(done);@(negedge clk);end
endtask
initial begin
    for(i=0;i<512;i=i+1) card.memory[17*512+i]=8'(i^8'ha5);
    repeat(4) @(negedge clk);reset=0;initialize=1;@(negedge clk);initialize=0;
    wait(done);@(negedge clk);if(!ready || error || card.resets<2 || card.acmds!=3) $fatal(1,"Card initialization failed %h",error);
    launch();if(error || read_count!=512) $fatal(1,"Sector read failed");
    lba=18;write_sector=1;launch();if(error || write_count!=512) $fatal(1,"Sector write failed %h/%0d",error,write_count);
    for(i=0;i<512;i=i+1) if(card.memory[18*512+i]!==8'(i*37+11)) $fatal(1,"Saved byte %0d",i);
    reject_write=1;write_count=0;lba=19;launch();if(error!=8'h08 || busy || !cs) $fatal(1,"Rejected write did not fail cleanly");
    $display("PASS: SD SPI pins, retried CMD0, ACMD41, SDHC/SDSC addressing, 512-byte read/write, source stalls, busy and write rejection (SDSC=%0d)",SDSC);$finish;
end
initial begin #5000000;$fatal(1,"SD card timeout state=%0d",dut.state);end
endmodule
