`timescale 1ns/1ps
module TileStore_tb;
reg clk=0, reset=1, done=0;
reg [2:0] tile=0;
wire ack, reading;
wire [17:0] address;
reg [15:0] tile_q;
wire rd, wr;
wire [23:0] word_addr;
wire [31:0] word_data;
wire [3:0] mask;
wire [7:0] length;
reg busy=0;
integer delay_count=0, writes=0, n, x, y, col;
reg [95:0] expected;
always #6.667 clk=~clk;
function [11:0] pixel;
    input integer t, position;
    begin pixel = (t*16'h123 + position*17) & 12'hfff; end
endfunction
always @(posedge clk) tile_q <= {4'd0, pixel(tile, address)};
TileStore #(.TILE_WIDTH(16), .TILE_HEIGHT(4), .STARTUP_CYCLES(5)) dut (
    .clk(clk), .reset(reset), .tile_done(done), .tile_index(tile), .tile_ack(ack),
    .tile_reading(reading), .tile_address(address), .tile_q(tile_q), .display_ready(1'b0),
    .line_request(1'b0), .line_y(10'd0), .line_bank(1'b0), .line_ack(),
    .line_write(), .line_write_address(), .line_write_data(), .word_rd(rd), .word_wr(wr),
    .word_addr(word_addr), .word_data(word_data), .word_wstrb(mask), .word_burst_len(length),
    .word_busy(busy), .word_valid(1'b0), .word_q(32'd0)
);
always @(posedge clk) begin
    if (busy) begin
        if (delay_count==0) busy <= 0;
        else delay_count <= delay_count-1;
    end else if (wr) begin
        if (mask !== 4'b1111) $fatal(1, "Incorrect write mask");
        y = writes/6; col = writes%6; x = (col/3)*8;
        for (n=0;n<8;n=n+1) expected[n*12 +: 12] = pixel(tile,y*16+x+n);
        if (word_addr !== (tile[2:1]*4+y)*12 + (tile[0]?6:0) + col ||
            word_data !== expected[(col%3)*32 +: 32])
            $fatal(1, "Tile %0d write %0d address=%h data=%h expected=%h",tile,writes,word_addr,word_data,expected[(col%3)*32 +: 32]);
        writes <= writes+1; busy <= 1; delay_count <= 2+(writes%5);
    end
end
initial begin
    repeat(4) @(negedge clk); reset=0;
    for (tile=0;tile<7;tile=tile+1) begin
        writes=0; done=1; wait(ack); @(negedge clk); done=0;
        if(writes!=24) $fatal(1,"Incomplete tile upload");
        repeat(4) @(negedge clk);
    end
    writes=0; done=1; wait(ack); @(negedge clk); done=0;
    if(writes!=24) $fatal(1,"Incomplete final tile upload");
    $display("PASS: eight tile positions, RGB444 packing, RAM latency, and variable SDRAM write stalls");
    $finish;
end
initial begin #1000000; $fatal(1,"Tile upload timeout"); end
endmodule
