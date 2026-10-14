`timescale 1ns/1ps
// Read the actual pin-level SDRAM controller through LiveStore and export
// complete BMP rows. The last two pixels exercise the last burst halfword.
module BmpSdram_tb;
parameter real DATA_DELAY=5.4;
parameter real CLOCK_DELAY=4.0;
parameter real CAPTURE_DELAY=0.0;
parameter real RELEASE_DELAY=DATA_DELAY+1.5;
parameter real REPEAT_READ_DELAY=DATA_DELAY+1.5;
parameter MODE=1;
parameter TAIL_REPLAY=0;
parameter BASE_WORD=24'h100000;
localparam WIDTH=MODE==2 ? 3840 : 1280, HEIGHT=MODE==2 ? 2 : 3;
reg clk=0,reset=1,start=0;
always #6.667 clk=~clk;
wire pin_source=~clk;
wire capture_clk;
assign #(CAPTURE_DELAY) capture_clk=pin_source;
wire chip_clk;
assign #(CLOCK_DELAY) chip_clk=pin_source;
wire request,accepted,finished,valid,ready,busy,done,dma_valid;
wire [7:0] value;
wire [23:0] address;
wire [31:0] data;
wire [7:0] length;
integer burst_beats=0;reg [7:0] guard_length=0;
wire [31:0] screenshot_q=TAIL_REPLAY && burst_beats==guard_length ? {data[15:0],data[15:0]} : data;
wire rd,wr,mem_busy,mem_valid;
wire [23:0] mem_address;
wire [31:0] mem_data,mem_q;
wire [7:0] mem_length;
wire [3:0] mem_mask;
wire cke,cas_n,ras_n,we_n;
wire [12:0] a;
wire [1:0] ba,dqm;
tri [15:0] dq;
integer cycles=0,bytes=0,pixel,x,y,channel,read_words=0;
reg [7:0] wanted;
assign ready=cycles%41==0 || cycles%41==8;
BmpStream #(.HD_HEIGHT(3),.UHD_HEIGHT(2),.UHD_BASE(BASE_WORD)) bmp (
    .clk(clk),.reset(reset),.start(start),.abort(1'b0),.mode(2'(MODE)),
    .scheme(4'd0),.color_offset(4'd0),.effects(8'd0),.phases(57'd0),
    .busy(busy),.done(done),.byte_valid(valid),.byte_data(value),.byte_ready(ready),
    .word_request(request),.word_address(address),.word_accepted(accepted),
    .word_length(length),.word_done(finished),.word_valid(dma_valid),.word_q(screenshot_q),
    .preview_request(),.preview_address(),.preview_accepted(1'b0),.preview_q(16'd0));
LiveStore #(.EXTERNAL_CLIENT(1),.GLOBAL_RASTER(1),.STARTUP_CYCLES(32)) store (
    .clk(clk),.reset(reset),.render_active(1'b0),.capture_done(1'b0),.corruption_enable(1'b0),
    .pixel_valid(1'b0),.pixel_offset(3'd0),.pixel_rgb(12'd0),.group_done(1'b0),
    .tile_index(3'd0),.group_x(8'd0),.group_y(10'd0),.group_ack(),.display_ready(),.progress_gray(),
    .line_request(1'b0),.line_y(10'd0),.line_bank(1'b0),.line_ack(),.line_write(),
    .line_write_address(),.line_write_data(),.word_rd(rd),.word_wr(wr),.word_addr(mem_address),
    .word_data(mem_data),.word_wstrb(mem_mask),.word_burst_len(mem_length),
    .word_busy(mem_busy),.word_valid(mem_valid),.word_q(mem_q),
    .dma_request(request),.dma_write(1'b0),.dma_address(address),.dma_data(32'd0),
    .dma_length(length),.dma_accepted(accepted),.dma_done(finished),.dma_valid(dma_valid),.dma_q(data));
io_sdram controller (
    .controller_clk(clk),.chip_clk(capture_clk),.clk_90(capture_clk),.reset_n(!reset),
    .phy_cke(cke),.phy_clk(),.phy_cas(cas_n),.phy_ras(ras_n),.phy_we(we_n),.phy_ba(ba),
    .phy_a(a),.phy_dq(dq),.phy_dqm(dqm),.burst_rd(1'b0),.burst_addr(25'd0),.burst_len(11'd0),
    .burst_32bit(1'b1),.burst_data(),.burst_data_valid(),.burst_data_done(),.burstwr(1'b0),
    .burstwr_addr(25'd0),.burstwr_ready(),.burstwr_strobe(1'b0),.burstwr_data(16'd0),
    .burstwr_done(1'b0),.word_rd(rd),.word_wr(wr),.word_addr(mem_address),.word_data(mem_data),
    .word_wstrb(mem_mask),.word_burst_len(mem_length),.word_q(mem_q),.word_busy(mem_busy),.word_q_valid(mem_valid));
VideoSdramModel #(.DATA_DELAY(DATA_DELAY+1.5),.RELEASE_DELAY(RELEASE_DELAY),
    .REPEAT_READ_DELAY(REPEAT_READ_DELAY),
    .PATTERN_BASE(MODE==2 ? BASE_WORD : 0),.ROW_WORDS(WIDTH*12/32)) chip (
    .clk(chip_clk),.cke(cke),.cas_n(cas_n),.ras_n(ras_n),.we_n(we_n),.a(a),.ba(ba),.dqm(dqm),.dq(dq));
always @(posedge clk) begin
    cycles=cycles+1;
    if(accepted) begin burst_beats<=0;guard_length<=length;end
    else if(dma_valid) burst_beats<=burst_beats+1;
    if(!reset && mem_valid) read_words=read_words+1;
    if(!reset && valid && ready) begin
        if(bytes>=54) begin
            pixel=(bytes-54)/3;x=pixel%WIDTH;y=pixel/WIDTH;channel=(bytes-54)%3;
            case(channel)
                0:wanted=8'((y>>3)&15)*17;
                1:wanted=8'((x>>4)&15)*17;
                2:wanted=8'((x+y)&15)*17;
            endcase
            if(value!==wanted) $fatal(1,"Screenshot-only artifact at (%0d,%0d) lane=%0d channel=%0d: got=%h wanted=%h delay=%0.1f",x,y,x%8,channel,value,wanted,DATA_DELAY);
        end
        bytes=bytes+1;
    end
end
initial begin
    repeat(4) @(negedge clk);reset=0;repeat(31000) @(negedge clk);
    start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
    if(bytes!=54+WIDTH*HEIGHT*3 || read_words!=WIDTH*HEIGHT/8*3+WIDTH/128*HEIGHT) $fatal(1,"BMP SDRAM coverage/length");
    $display("PASS: %0d BMP bytes, %0d actual SDRAM read beats, all pixel lanes and row crossings, mode=%0d width=%0d tAC=%0.1f clock-delay=%0.1f capture-skew=%0.1f release=%0.1f repeat-read=%0.1f",bytes,read_words,MODE,WIDTH,DATA_DELAY,CLOCK_DELAY,CAPTURE_DELAY,RELEASE_DELAY,REPEAT_READ_DELAY);$finish;
end
initial begin #20000000;$fatal(1,"BMP SDRAM test timeout");end
endmodule
