`timescale 1ns/1ps
// A complete small image, all packed pixel lanes, competing line fetches,
// disabling/canceling corruption, and recapture. The same scoreboard runs
// against both a stalled native client and the controller's SDRAM pins.
module Corruption_tb;
parameter REAL_SDRAM=0;
parameter PARTIAL_CAPTURE=0;
reg clk=0,reset=1,active=0,captured=0,corrupt=0;
always #6.667 clk=~clk;
reg pixel_valid=0,group_done=0;
reg [2:0] offset=0,tile=0;
reg [7:0] gx=0;
reg [9:0] gy=0;
reg [11:0] rgb=0;
reg request=0,bank=0;
reg [9:0] row=0;
wire ack,ready,line_ack,line_write,rd,wr,busy,valid;
wire [17:0] progress;
wire [9:0] line_address;
wire [31:0] line_data,data,q;
wire [23:0] address;
wire [7:0] length;
reg [31:0] golden[0:191];
reg [95:0] expected_group;
reg rmw_pending=0,fetch_lines=1;
reg [23:0] rmw_base;
reg [7:0] lanes=0;
reg [63:0] groups=0;
integer i,j,cycle_count=0,rmw_words=0,mutations=0,reads=0,line_beats=0,writes=0;
integer fetched_row=0,fetched_bank=0,stopped_mutations;
integer render_start=0,render_end=64;
function [11:0] color;
    input integer x,y;
    begin color={4'((x+y)&15),4'((x*3)&15),4'((y*5)&15)}; end
endfunction
LiveStore #(.TILE_WIDTH(16),.TILE_HEIGHT(4),.TILE_COLUMNS(4),
    .STARTUP_CYCLES(REAL_SDRAM?40000:5),.CORRUPTION_INTERVAL(48),.GLOBAL_RASTER(1)) dut (
    .clk(clk),.reset(reset),.render_active(active),.capture_done(captured),.corruption_enable(corrupt),
    .pixel_valid(pixel_valid),.pixel_offset(offset),.pixel_rgb(rgb),
    .group_done(group_done),.tile_index(tile),.group_x(gx),.group_y(gy),.group_ack(ack),
    .display_ready(ready),.progress_gray(progress),.line_request(request),.line_y(row),.line_bank(bank),
    .line_ack(line_ack),.line_write(line_write),.line_write_address(line_address),.line_write_data(line_data),
    .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(),.word_burst_len(length),
    .word_busy(busy),.word_valid(valid),.word_q(q)
);
generate if(!REAL_SDRAM) begin : native_model
    reg mem_busy=0,mem_valid=0,writing=0;
    reg [31:0] mem_q=0,held_data;
    reg [23:0] held_address;
    reg [31:0] memory[0:191];
    integer delay_count=0,beats=0,cursor=0,k;
    assign busy=mem_busy; assign valid=mem_valid; assign q=mem_q;
    initial for(k=0;k<192;k=k+1) memory[k]=32'hcafecafe;
    always @(posedge clk) begin
        mem_valid<=0;
        if(mem_busy) begin
            if(delay_count>0) delay_count=delay_count-1;
            else if(writing) begin memory[held_address]<=held_data; mem_busy<=0; end
            else if(beats>0) begin
                mem_q<=memory[cursor]; mem_valid<=1; cursor=cursor+1; beats=beats-1; delay_count=1;
            end else mem_busy<=0;
        end else if(wr) begin
            mem_busy<=1; writing<=1; held_address<=address; held_data<=data; delay_count=3+writes%7;
        end else if(rd) begin
            mem_busy<=1; writing<=0; cursor=address; beats=length+1; delay_count=6+reads%5;
        end
    end
end else begin : physical_model
    wire chip_clock,cke,cas_n,ras_n,we_n;
    wire [12:0] a;
    wire [1:0] ba,dqm;
    tri [15:0] dq;
    assign #4 chip_clock=~clk;
    io_sdram controller (
        .controller_clk(clk),.chip_clk(~clk),.clk_90(~clk),.reset_n(!reset),
        .phy_cke(cke),.phy_clk(),.phy_cas(cas_n),.phy_ras(ras_n),.phy_we(we_n),
        .phy_ba(ba),.phy_a(a),.phy_dq(dq),.phy_dqm(dqm),
        .burst_rd(1'b0),.burst_addr(25'd0),.burst_len(11'd0),.burst_32bit(1'b1),
        .burst_data(),.burst_data_valid(),.burst_data_done(),.burstwr(1'b0),.burstwr_addr(25'd0),
        .burstwr_ready(),.burstwr_strobe(1'b0),.burstwr_data(16'd0),.burstwr_done(1'b0),
        .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(4'b1111),
        .word_burst_len(length),.word_q(q),.word_busy(busy),.word_q_valid(valid)
    );
    VideoSdramModel #(.DATA_DELAY(6.9),.ALLOW_WRITES(1),.CHECK_WRITES(0),.MEMORY_HALFWORDS(384)) chip (
        .clk(chip_clock),.cke(cke),.cas_n(cas_n),.ras_n(ras_n),.we_n(we_n),.a(a),.ba(ba),.dqm(dqm),.dq(dq)
    );
end endgenerate
always @(posedge clk) if(!reset) begin
    cycle_count=cycle_count+1;
    if(ready && fetch_lines && request==line_ack && cycle_count%211==0) begin
        row<=cycle_count%8; bank<=~bank; request<=~request;
    end
    if(!active && !busy) rmw_pending=0;
    if(rd) begin
        if(wr || address+length>=192) $fatal(1,"Native command collision/range error");
        if(length==2) begin
            if(!active || rmw_pending || address/3>=dut.progress) $fatal(1,"Corruption touched unpublished data/interrupted a packed write");
            for(j=0;j<3;j=j+1) expected_group[j*32 +:32]=golden[address+j];
            expected_group[dut.corrupt_lane*12 +:12]=dut.corrupt_color;
            rmw_pending=1; rmw_words=0; rmw_base=address;
            lanes[dut.corrupt_lane]=1; groups[address/3]=1;
        end else begin
            if(length!=23 || rmw_pending) $fatal(1,"Scanline interrupted a packed pixel update");
            fetched_row=address/24; fetched_bank=bank; line_beats=0; reads=reads+1;
        end
    end
    if(wr) begin
        if(address>=192) $fatal(1,"Write outside image");
        if(rmw_pending) begin
            if(address!==rmw_base+rmw_words || data!==expected_group[rmw_words*32 +:32])
                $fatal(1,"Corruption damaged an adjacent pixel or packed word: lane=%0d word=%0d",dut.corrupt_lane,rmw_words);
            rmw_words=rmw_words+1;
            if(rmw_words==3) begin mutations=mutations+1; rmw_pending=0; end
        end
        golden[address]=data; writes=writes+1;
    end
    if(line_write) begin
        if(line_address!=={1'(fetched_bank),9'(line_beats)} || line_data!==golden[fetched_row*24+line_beats])
            $fatal(1,"Corruption/scanline arbitration returned torn data at line beat %0d",line_beats);
        line_beats=line_beats+1;
    end
end
task render_image;
    integer group_number,lane,k,global_x,global_y;
    reg [95:0] expected_pixels;
    begin
        for(group_number=render_start;group_number<render_end;group_number=group_number+1) begin
            global_x=(group_number%8)*8; global_y=group_number/8;
            tile=0; gx=8'(global_x/8); gy=10'(global_y);
            for(k=0;k<8;k=k+1) begin
                @(negedge clk); lane=(k*3)%8; offset=3'(lane); rgb=color(global_x+lane,global_y); pixel_valid=1;
            end
            @(negedge clk); pixel_valid=0; group_done=1;
            wait(ack); @(negedge clk); group_done=0;
            for(k=0;k<8;k=k+1) expected_pixels[k*12 +:12]=color(global_x+k,global_y);
            for(k=0;k<3;k=k+1) if(golden[group_number*3+k]!==expected_pixels[k*32 +:32]) $fatal(1,"Missing fresh capture pixels");
        end
    end
endtask
initial begin
    for(i=0;i<192;i=i+1) golden[i]=32'hcafecafe;
    repeat(4) @(negedge clk); reset=0; active=1; wait(ready);
    render_end=PARTIAL_CAPTURE?16:64; render_image();
    if(PARTIAL_CAPTURE) begin
        // Force an eligible address to exercise the live-capture gate quickly;
        // the production RNG and all pixel lanes are checked afterward.
        corrupt=1; force dut.random_group=18'd0;
        wait(mutations>=8); @(negedge clk); corrupt=0;
        repeat(300) @(negedge clk); release dut.random_group;
        if(captured || progress!==(18'd16 ^ (18'd16>>1))) $fatal(1,"Partial capture corruption changed the publication frontier");
        render_start=16; render_end=64; render_image();
    end
    if(progress!==(18'd64 ^ (18'd64>>1))) $fatal(1,"Missing capture data");
    captured=1; corrupt=1; wait(mutations>=128); @(negedge clk); corrupt=0;
    repeat(300) @(negedge clk); stopped_mutations=mutations;
    repeat(300) @(negedge clk);
    if(mutations!=stopped_mutations || lanes!=8'hff || $countones(groups)<20 || reads<10)
        $fatal(1,"Corruption coverage: edits=%0d stopped=%0d lanes=%h groups=%0d reads=%0d",mutations,stopped_mutations,lanes,$countones(groups),reads);
    corrupt=1; wait(dut.state==16 && dut.write_index==0 && busy); @(negedge clk);
    active=0; captured=0; corrupt=0; fetch_lines=0;
    repeat(300) @(negedge clk);
    if(ready || progress!=0 || busy) $fatal(1,"Cancellation retained an active capture/transaction");
    active=1; render_start=0; render_end=64; wait(ready); render_image(); repeat(30) @(negedge clk);
    if(progress!==(18'd64 ^ (18'd64>>1))) $fatal(1,"Recapture frontier failed");
    $display("PASS: %0d persistent pixel edits, all packed lanes, %0d competing fetches, disable, cancel, recapture (SDRAM pins=%0d partial=%0d)",mutations,reads,REAL_SDRAM,PARTIAL_CAPTURE);
    $finish;
end
// Only 64 of the production generator's 262144 candidates fit this fixture;
// allow rejection sampling to run long enough to exercise every pixel lane.
initial begin #100000000; $fatal(1,"Corruption timeout: state=%0d progress=%0d mutations=%0d writes=%0d",dut.state,progress,mutations,writes); end
endmodule

module LiveCorruption_tb;
Corruption_tb #(.REAL_SDRAM(1),.PARTIAL_CAPTURE(1)) test();
endmodule
