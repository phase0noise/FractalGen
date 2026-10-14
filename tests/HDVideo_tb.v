`timescale 1ns/1ps
module HDVideo_tb;
parameter REAL_SDRAM = 0;
parameter LIVE_STORE = 0;
parameter PROGRESSIVE_MASK = 0;
parameter CORRUPT_STORE = 0;
parameter SCREENSHOT_DMA = 0;
parameter real DATA_DELAY = 5.4;
reg mem_clk=0, pixel_clk=0, reset=1, enable=0;
always #6.667 mem_clk=~mem_clk;
always #4.629630 pixel_clk=~pixel_clk;
wire request, ack, bank, selected, underflow;
wire [9:0] line_y, read_addr, write_addr;
wire [31:0] read_q, write_data;
wire line_write, rd, wr;
wire [23:0] address;
wire [31:0] data;
wire [7:0] length;
wire [3:0] r,g,b;
wire hs,vs;
wire busy, valid;
wire [31:0] q;
wire [17:0] progress_gray;
wire [31:0] uploaded_groups;
reg [17:0] gray_meta=0,gray_sync=0,visible_groups=0;
reg [17:0] old_visible_groups;
reg [17:0] previous_visible=0,requested_visible=0,bank0_visible=0,bank1_visible=0;
reg previous_request=0,model_ack_meta=0,model_ack_sync=0,model_ack_seen=0;
reg [9:0] requested_row=0;
function [17:0] decode;
    input [17:0] gray;
    integer bit_number;
    begin for(bit_number=0;bit_number<18;bit_number=bit_number+1) decode[bit_number]=^(gray>>bit_number); end
endfunction
always @(posedge pixel_clk) begin
    gray_meta<=progress_gray; gray_sync<=gray_meta; visible_groups<=decode(gray_sync);
    previous_visible<=visible_groups;
    model_ack_meta<=ack; model_ack_sync<=model_ack_meta;
    if(request!=previous_request) begin
        previous_request<=request; requested_visible<=previous_visible; requested_row<=line_y;
    end
    if(model_ack_sync!=model_ack_seen) begin
        model_ack_seen<=model_ack_sync;
        if(requested_row[0]) bank1_visible<=requested_visible;
        else bank0_visible<=requested_visible;
    end
end
integer beats=0, wait_count=0;
reg [23:0] cursor;
integer pixels=0, lines=0, old_h, old_v, sx, sy;
integer corruption_writes=0,changed_pixels=0,group_word;
integer dma_checks=0;
reg [31:0] fetched_words[0:1023];
reg [95:0] fetched_group;
always @(posedge mem_clk) begin
    if(line_write) fetched_words[write_addr]=write_data;
    if(wr && CORRUPT_STORE) corruption_writes=corruption_writes+1;
end
reg [11:0] wanted;
function [11:0] color;
    input integer x,y;
    begin color = {4'((x+y)&15),4'((x>>4)&15),4'((y>>3)&15)}; end
endfunction
function [31:0] memory_word;
    input integer addr;
    integer row, col, group_number, k;
    reg [95:0] packed_word;
    begin
        row=addr/480; col=addr%480; group_number=col/3;
        for(k=0;k<8;k=k+1) packed_word[k*12 +:12]=color(group_number*8+k,row);
        memory_word=packed_word[(col%3)*32 +:32];
    end
endfunction
generate if (!REAL_SDRAM) begin : simulated_client
reg simulated_busy=0, simulated_valid=0;
reg [31:0] simulated_q=0;
assign busy=simulated_busy;
assign valid=simulated_valid;
assign q=simulated_q;
always @(posedge mem_clk) begin
    simulated_valid <= 0;
    if (busy) begin
        if(wait_count!=0) wait_count<=wait_count-1;
        else if(beats!=0) begin
            simulated_q<=memory_word(cursor); simulated_valid<=1; cursor<=cursor+1;
            beats<=beats-1; wait_count<=1;
        end else simulated_busy<=0;
    end else if(rd) begin
        simulated_busy<=1; cursor<=address; beats<=length+1; wait_count<=18;
    end else if(wr && LIVE_STORE) begin
        simulated_busy<=1; beats<=0; wait_count<=18;
    end
    if(wr && !LIVE_STORE) $fatal(1,"Display unexpectedly wrote SDRAM");
end
end else begin : actual_controller
wire capture_clk = ~mem_clk;
wire chip_pin_clk;
// Model 4 ns of forwarding delay and 1.5 ns of FPGA input routing, in
// addition to the chip's slowest 5.4 ns tAC. The capture clock stays internal.
assign #4 chip_pin_clk = capture_clk;
wire cke,cas_n,ras_n,we_n;
wire [12:0] a;
wire [1:0] ba,dqm;
tri [15:0] dq;
io_sdram controller (
    .controller_clk(mem_clk),.chip_clk(capture_clk),.clk_90(capture_clk),.reset_n(!reset),
    .phy_cke(cke),.phy_clk(),.phy_cas(cas_n),.phy_ras(ras_n),.phy_we(we_n),
    .phy_ba(ba),.phy_a(a),.phy_dq(dq),.phy_dqm(dqm),
    .burst_rd(1'b0),.burst_addr(25'd0),.burst_len(11'd0),.burst_32bit(1'b1),
    .burst_data(),.burst_data_valid(),.burst_data_done(),.burstwr(1'b0),
    .burstwr_addr(25'd0),.burstwr_ready(),.burstwr_strobe(1'b0),
    .burstwr_data(16'd0),.burstwr_done(1'b0),.word_rd(rd),.word_wr(wr),
    .word_addr(address),.word_data(data),.word_wstrb(4'b1111),.word_burst_len(length),
    .word_q(q),.word_busy(busy),.word_q_valid(valid)
);
VideoSdramModel #(.DATA_DELAY(DATA_DELAY+1.5),.ALLOW_WRITES(LIVE_STORE),
    .CHECK_WRITES(!CORRUPT_STORE),.INITIAL_PATTERN(CORRUPT_STORE)) chip (
    .clk(chip_pin_clk),.cke(cke),.cas_n(cas_n),.ras_n(ras_n),.we_n(we_n),
    .a(a),.ba(ba),.dqm(dqm),.dq(dq)
);
end endgenerate
generate if(!LIVE_STORE) begin : legacy_storage
assign progress_gray=18'd0;
assign uploaded_groups=32'd0;
TileStore storage (
    .clk(mem_clk),.reset(reset),.tile_done(1'b0),.tile_index(3'd0),.tile_ack(),
    .tile_reading(),.tile_address(),.tile_q(16'd0),.display_ready(enable),
    .line_request(request),.line_y(line_y),.line_bank(bank),.line_ack(ack),
    .line_write(line_write),.line_write_address(write_addr),.line_write_data(write_data),
    .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(),
    .word_burst_len(length),.word_busy(busy),.word_valid(valid),.word_q(q)
);
end else begin : live_storage
reg pixel_valid=0,group_done=0;
reg [2:0] pixel_offset=0;
reg [11:0] pixel_rgb=0;
integer group_number=0,lane=0,uploaded=0;
assign uploaded_groups=uploaded;
wire group_ack,ready;
wire [2:0] tile=3'(((group_number/160)/512)*4+((group_number%160)/40));
reg dma_request=0;
reg [23:0] dma_address=0;
wire dma_accepted,dma_done,dma_valid;
wire [31:0] dma_q;
integer dma_beats=0,dma_reads=0;
always @(posedge mem_clk) begin
    if(SCREENSHOT_DMA && enable && uploaded>2) begin
        if(!dma_request && dma_beats==0) begin dma_address<=(dma_reads%uploaded)*3;dma_request<=1;end
        if(dma_accepted) begin dma_request<=0;dma_beats=1;end
        if(dma_valid) begin
            if(dma_beats<1 || dma_q!==memory_word(dma_address+dma_beats-1)) $fatal(1,"SD screenshot DMA read corrupted");
            dma_beats=dma_beats+1;dma_checks=dma_checks+1;
        end
        if(dma_done) begin if(dma_beats!=4) $fatal(1,"DMA burst incomplete");dma_beats=0;dma_reads=dma_reads+1;end
        if(!ready) $fatal(1,"Screenshot DMA changed HD readiness");
    end
end
LiveStore #(.TILE_WIDTH(320),.TILE_HEIGHT(512),.TILE_COLUMNS(4),.GLOBAL_RASTER(1),.EXTERNAL_CLIENT(SCREENSHOT_DMA)) storage (
    .clk(mem_clk),.reset(reset),.render_active(enable),
    .capture_done(1'(CORRUPT_STORE)),.corruption_enable(1'(CORRUPT_STORE)),
    .pixel_valid(pixel_valid),.pixel_offset(pixel_offset),.pixel_rgb(pixel_rgb),
    .group_done(group_done),.tile_index(3'd0),.group_x(8'(group_number%160)),
    .group_y(10'(group_number/160)),.group_ack(group_ack),
    .display_ready(ready),.progress_gray(progress_gray),
    .line_request(request),.line_y(line_y),.line_bank(bank),.line_ack(ack),
    .line_write(line_write),.line_write_address(write_addr),.line_write_data(write_data),
    .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(),
    .word_burst_len(length),.word_busy(busy),.word_valid(valid),.word_q(q),
    .dma_request(dma_request),.dma_write(1'b0),.dma_address(dma_address),.dma_data(32'd0),.dma_length(8'd2),
    .dma_accepted(dma_accepted),.dma_done(dma_done),.dma_valid(dma_valid),.dma_q(dma_q)
);
if(CORRUPT_STORE) begin : held_image
    // Start with a completed image supplied by the SDRAM fixture. This
    // avoids a long full capture while testing steady-state display edits.
    initial begin
        force storage.progress=18'd163840;
        force storage.progress_gray=(18'd163840 ^ (18'd163840>>1));
    end
end else begin : live_capture
always @(negedge mem_clk) begin
    pixel_valid=0;
    if(ready) begin
        if(group_ack) begin group_done=0; group_number=group_number+1; lane=0; uploaded=uploaded+1; end
        else if(!group_done) begin
            if(lane<8) begin
                pixel_valid=1; pixel_offset=3'(lane);
                pixel_rgb=color((group_number%160)*8+lane,group_number/160);
                lane=lane+1;
            end else group_done=1;
        end
    end
end
end
end endgenerate
LineBuffer cache (
    .write_clk(mem_clk),.write_enable(line_write),.write_address(write_addr),.write_data(write_data),
    .read_clk(pixel_clk),.read_address(read_addr),.read_data(read_q)
);
HDVideo #(.PROGRESSIVE(PROGRESSIVE_MASK)) dut (
    .clk(pixel_clk),.reset(reset),.enable(enable),.line_request(request),.line_y(line_y),
    .progress_gray(progress_gray),
    .line_bank(bank),.line_ack(ack),.buffer_address(read_addr),.buffer_q(read_q),
    .selected(selected),.underflow(underflow),.red(r),.green(g),.blue(b),.hsync(hs),.vsync(vs)
);
always @(posedge pixel_clk) begin
    old_h=dut.h; old_v=dut.v;
    old_visible_groups=(old_v-41)%2 ? bank1_visible : bank0_visible;
    #1;
    if(selected && (hs!==(old_h<112) || vs!==(old_v<3))) $fatal(1,"HD sync timing/polarity mismatch");
    if(selected && old_h>=360 && old_h<1640 && old_v>=41 && old_v<1065) begin
        sx=old_h-360; sy=old_v-41; wanted=color(sx,sy);
        if(CORRUPT_STORE) begin
            group_word=(sy%2)*512+(sx/8)*3;
            fetched_group={fetched_words[group_word+2],fetched_words[group_word+1],fetched_words[group_word]};
            wanted=fetched_group[(sx%8)*12 +:12];
            if(wanted!=color(sx,sy)) changed_pixels=changed_pixels+1;
        end
        if(PROGRESSIVE_MASK && sy*160+sx/8>=old_visible_groups) wanted=0;
        if({r,g,b} !== wanted) $fatal(1,"HD pixel (%0d,%0d): expected=%h actual=%h",sx,sy,wanted,{r,g,b});
        pixels=pixels+1;
        if(sx==1279) lines=lines+1;
        if(lines==1024) begin
            if(underflow || pixels!=1280*1024) $fatal(1,"HD scanout incomplete or underflowed");
            if(LIVE_STORE && !CORRUPT_STORE && uploaded_groups<100) $fatal(1,"Concurrent upload coverage incomplete");
            if(CORRUPT_STORE && (corruption_writes<100 || changed_pixels<5))
                $fatal(1,"Ongoing corruption not visible: writes=%0d changed=%0d",corruption_writes,changed_pixels);
            if(SCREENSHOT_DMA && dma_checks<100) $fatal(1,"SDRAM screenshot DMA coverage");
            $display("PASS: 1,310,720 HD pixels, concurrent writes, frontier, CDC, refresh (actual SDRAM=%0d live=%0d mask=%0d corruption=%0d changed=%0d)",REAL_SDRAM,LIVE_STORE,PROGRESSIVE_MASK,CORRUPT_STORE,changed_pixels);
            if(SCREENSHOT_DMA) $display("PASS: %0d concurrent screenshot SDRAM read beats with no VGA underflow",dma_checks);
            $finish;
        end
    end
end
initial begin #100; reset=0; #1000000; enable=1; end
initial begin #45000000; $fatal(1,"HD video timeout"); end
endmodule

module HDVideoCorruption_tb;
HDVideo_tb #(.REAL_SDRAM(1),.LIVE_STORE(1),.PROGRESSIVE_MASK(1),.CORRUPT_STORE(1)) test();
endmodule
module HDVideoScreenshot_tb;
HDVideo_tb #(.REAL_SDRAM(1),.LIVE_STORE(1),.PROGRESSIVE_MASK(1),.SCREENSHOT_DMA(1)) test();
endmodule
