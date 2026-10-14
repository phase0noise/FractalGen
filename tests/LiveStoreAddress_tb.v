`timescale 1ns/1ps
// Audit real HD addressing across former sections and truncated worker tags.
// The native port stalls each write; pixels arrive in a permuted lane order.
module LiveStoreAddress_tb;
reg clk=0,reset=1,active=0,pixel_valid=0,group_done=0,busy=0;
always #5 clk=~clk;
reg [7:0] group_x=0;
reg [9:0] group_y=0;
reg [2:0] offset=0;
reg [11:0] rgb=0;
wire ack,ready,rd,wr;
wire [23:0] address;
wire [31:0] data;
wire [3:0] mask;
wire [7:0] length;
wire [17:0] progress;
integer columns[0:9];
integer rows[0:3];
integer row,column,lane,index,writes=0,groups=0,latency=0,word_index=0;
integer expected_base;
reg [95:0] expected_pixels;
LiveStore #(.TILE_WIDTH(320),.TILE_HEIGHT(512),.TILE_COLUMNS(4),
    .GLOBAL_RASTER(1),.STARTUP_CYCLES(4)) dut (
    .clk(clk),.reset(reset),.render_active(active),.capture_done(1'b0),.corruption_enable(1'b0),
    .pixel_valid(pixel_valid),.pixel_offset(offset),.pixel_rgb(rgb),.group_done(group_done),
    .tile_index(3'd0),.group_x(group_x),.group_y(group_y),.group_ack(ack),
    .display_ready(ready),.progress_gray(progress),.line_request(1'b0),.line_y(10'd0),
    .line_bank(1'b0),.line_ack(),.line_write(),.line_write_address(),.line_write_data(),
    .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(mask),
    .word_burst_len(length),.word_busy(busy),.word_valid(1'b0),.word_q(32'd0)
);
always @(posedge clk) begin
    if(reset) begin busy<=0; latency=0; end
    else if(busy) begin
        if(latency==0) busy<=0;
        else latency=latency-1;
    end else if(wr) begin
        if(address!==24'(expected_base+word_index) ||
           data!==expected_pixels[word_index*32 +:32] || mask!==4'b1111 || length!==0)
            $fatal(1,"HD upload address/color error at group (%0d,%0d), word %0d",group_x,group_y,word_index);
        word_index=word_index+1; writes=writes+1;
        busy<=1; latency=3+writes%5;
    end
    if(rd) $fatal(1,"Unexpected read in upload address test");
end
initial begin
    columns[0]=0; columns[1]=39; columns[2]=40; columns[3]=79; columns[4]=80;
    columns[5]=119; columns[6]=120; columns[7]=127; columns[8]=128; columns[9]=159;
    rows[0]=0; rows[1]=511; rows[2]=512; rows[3]=1023;
    repeat(4) @(negedge clk); reset=0; active=1;
    wait(ready);
    for(row=0;row<4;row=row+1) for(column=0;column<10;column=column+1) begin
        @(negedge clk);
        group_x=8'(columns[column]); group_y=10'(rows[row]);
        expected_base=rows[row]*480+columns[column]*3;
        expected_pixels=0; word_index=0;
        for(lane=0;lane<8;lane=lane+1) begin
            index=(lane*3+5)%8;
            offset=3'(index); rgb=12'(groups*137+index*413);
            expected_pixels[index*12 +:12]=rgb; pixel_valid=1;
            @(negedge clk);
        end
        pixel_valid=0; group_done=1;
        wait(ack); @(negedge clk);
        if(word_index!=3) $fatal(1,"Group acknowledged before all packed words drained");
        group_done=0; groups=groups+1;
        repeat(3) @(negedge clk);
    end
    if(writes!=120 || progress!==18'(40^(40>>1))) $fatal(1,"Upload coverage/publication error");
    $display("PASS: 40 full-size HD group addresses across X=320/640/960/1024 and Y=511/512/1023, packed RGB and stalled writes");
    $finish;
end
initial begin #1000000; $fatal(1,"LiveStore address test timeout"); end
endmodule
