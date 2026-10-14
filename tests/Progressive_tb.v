`timescale 1ns/1ps
// Out-of-order workers, native-memory stalls, and concurrent scanline reads.
// Poison initial SDRAM; every published group must contain complete new data.
module Progressive_tb;
parameter SCREENSHOT_PAUSE=0;
parameter QUEUED=0;
reg clk=0,reset=1,quality=0,refine=0;
reg pause=0,dma_request=0;
wire dma_accepted,dma_done,dma_valid;
wire [31:0] dma_q;
integer dma_beats=0;
always #6.667 clk=~clk;
wire latch,active,finished,done,ack,display;
wire [2:0] tile,worker;
wire [7:0] gx;
wire [9:0] gy;
wire [1:0] level;
wire [82:0] coordinate;
wire [17:0] progress_gray;
reg [6:0] free=7'b1111111;
integer remaining[0:6],px[0:6],py[0:6],pass[0:6];
reg [1:0] slots[0:6];
reg [1:0] pixel_slot=0;
wire queue_ready,queue_empty,queue_valid;
wire [1:0] dispatch_slot;
wire [95:0] queue_pixels;
wire [23:0] queue_address;
integer max_ahead=0;
reg pixel_valid=0;
reg [2:0] offset=0;
reg [11:0] rgb=0;
integer i,choice,dispatches=0,published=0,writes=0,reads=0,returned=0,cycle_count=0;
reg rd_request=0,rd_bank=0;
reg [9:0] rd_y=0;
wire line_ack,line_write;
wire [9:0] line_address;
wire [31:0] line_data;
wire rd,wr;
wire [23:0] address;
wire [31:0] data;
wire [7:0] burst;
reg busy=0,valid=0;
reg [31:0] q=0;
reg [31:0] memory[0:191];
integer delay_count=0,beats=0,cursor=0;
reg writing=0;
reg [23:0] held_address;
reg [31:0] held_data;
reg [95:0] wanted;
integer row,col,n,global_x,global_y,expected_pass;
reg signed [63:0] wanted_x,wanted_y;
function [11:0] color;
    input integer x,y,p;
    begin color={4'((x+p*3)&15),4'((y+p*5)&15),4'((x+y+p*7)&15)}; end
endfunction
function [17:0] decode;
    input [17:0] gray;
    integer bit_number;
    begin for(bit_number=0;bit_number<18;bit_number=bit_number+1) decode[bit_number]=^(gray>>bit_number); end
endfunction
Coor_gen #(.SCREEN_WIDTH(16),.SCREEN_HEIGHT(8),.QUALITY_TILE_HEIGHT(4),.PROGRESSIVE(1),.EXTERNAL_PAUSE(SCREENSHOT_PAUSE),.QUEUED(QUEUED)) coordinates (
    .cclk(clk),.ckey(4'b1111),.creset(reset),.cdones(free),.cidle(free & {7{!pixel_valid}}),
    .pause(pause),
    .queue_ready(queue_ready),
    .clatch_en(latch),.cengine_addr(worker),.cword2engines(coordinate),.frame(),
    .zoom_level(32'd8525),.center_x(-32'sd12582912),.center_y(32'sd2211681),
    .lens_enable(1'b0),.detail_enable(1'b0),.deep_enable(1'b0),.turbo_enable(1'b0),
    .overrender_enable(quality),.refine_enable(refine),.palette_select(2'd0),.palette_phase(8'd0),
    .tile_ack(QUEUED ? queue_empty : ack),.detail_active(),.deep_active(),.turbo_active(),.overrender_active(active),
    .overrender_done(finished),.tile_done(done),.tile_index(tile),.normal_ready(),
    .sample_step(),.render_palette(),.render_phase(),.group_x(gx),.group_y(gy),.iteration_level(level)
);
RenderQueue queue (.clk(clk),.reset(reset),.active(active && quality),
    .dispatch(latch && active),.dispatch_lane(coordinate[75:73]),.dispatch_base(24'(gy*12+gx*3)),
    .dispatch_ready(queue_ready),.dispatch_slot(dispatch_slot),
    .pixel_valid(pixel_valid),.pixel_slot(pixel_slot),.pixel_lane(offset),.pixel_rgb(rgb),
    .group_valid(queue_valid),.group_base(queue_address),.group_pixels(queue_pixels),.group_ack(ack),
    .empty(queue_empty),.allocated_groups(),.retired_groups());
LiveStore #(.TILE_WIDTH(16),.TILE_HEIGHT(4),.STARTUP_CYCLES(5),.GLOBAL_RASTER(1),.EXTERNAL_CLIENT(SCREENSHOT_PAUSE),.QUEUED_UPLOAD(QUEUED)) storage (
    .clk(clk),.reset(reset),.render_active(active && quality),
    .capture_done(finished),.corruption_enable(1'b0),
    .pixel_valid(pixel_valid),.pixel_offset(offset),.pixel_rgb(rgb),
    .group_done(QUEUED ? queue_valid : done),.tile_index(tile),.group_x(gx),.group_y(gy),.group_ack(ack),
    .queued_pixels(queue_pixels),.queued_address(queue_address),
    .display_ready(display),.progress_gray(progress_gray),
    .line_request(rd_request),.line_y(rd_y),.line_bank(rd_bank),.line_ack(line_ack),
    .line_write(line_write),.line_write_address(line_address),.line_write_data(line_data),
    .word_rd(rd),.word_wr(wr),.word_addr(address),.word_data(data),.word_wstrb(),
    .word_burst_len(burst),.word_busy(busy),.word_valid(valid),.word_q(q),
    .dma_request(dma_request),.dma_write(1'b0),.dma_address(24'd0),.dma_data(32'd0),.dma_length(8'd2),
    .dma_accepted(dma_accepted),.dma_done(dma_done),.dma_valid(dma_valid),.dma_q(dma_q)
);
always @(posedge clk) begin
    pixel_valid<=0;
    if(reset) begin free<=7'b1111111; for(i=0;i<7;i=i+1) remaining[i]=0; end
    else begin
        cycle_count=cycle_count+1;
        if(pause && latch) $fatal(1,"Screenshot pause dispatched a main-render pixel");
        if(dma_valid) begin
            if(dma_q!==memory[dma_beats]) $fatal(1,"Paused screenshot SDRAM contents");dma_beats=dma_beats+1;
        end
        for(i=0;i<7;i=i+1) if(remaining[i]>0) remaining[i]=remaining[i]-1;
        choice=-1;
        for(i=0;i<7;i=i+1) if(!free[i] && remaining[i]==0) choice=i;
        if(choice>=0) begin
            free[choice]<=1; pixel_valid<=1;pixel_slot<=slots[choice];offset<=px[choice]%8;
            rgb<=color(px[choice],py[choice],pass[choice]);
        end
        if(latch) begin
            if(!free[worker]) $fatal(1,"Busy worker dispatched");
            free[worker]<=0; remaining[worker]=4+(worker*7)%13;
            px[worker]=coordinate[82:73]+(tile[0]?16:0);
            py[worker]=coordinate[72:64]+tile[2:1]*4;
            pass[worker]=level;
            slots[worker]<=dispatch_slot;
            // Preview results do not enter the HD packing register.
            if(!active) begin remaining[worker]=1; pass[worker]=0; end
            else begin
                global_x=dispatches%32; global_y=(dispatches/32)%16;
                wanted_x=-12582912+((global_x*64'sd8525)>>>10)-((320*64'sd8525)>>>9);
                wanted_y=2211681-((global_y*64'sd8525)>>>10)+((240*64'sd8525)>>>9);
                if(px[worker]!=global_x || py[worker]!=global_y ||
                   $signed(coordinate[63:32])!==wanted_x[31:0] || $signed(coordinate[31:0])!==wanted_y[31:0])
                    $fatal(1,"Discontinuous progressive projection at pixel %0d",dispatches);
                dispatches=dispatches+1;
                if(QUEUED && global_x==0 && global_y==0) remaining[worker]=1000;
                if(dispatches-published*8>max_ahead) max_ahead=dispatches-published*8;
            end
        end
        if(display && rd_request==line_ack && cycle_count%51==0) begin
            rd_y<=cycle_count%16; rd_bank<=~rd_bank; rd_request<=~rd_request;
        end
        if(ack) begin
            published=published+1;
            if(writes!=published*3 || decode(progress_gray)!=(published>64?64:published))
                $fatal(1,"Published partial/missing group: writes=%0d groups=%0d frontier=%0d",writes,published,decode(progress_gray));
        end
    end
end
always @(posedge clk) begin
    valid<=0;
    if(busy) begin
        if(delay_count>0) delay_count=delay_count-1;
        else if(writing) begin
            memory[held_address]=held_data; writes=writes+1; busy<=0;
        end else if(beats>0) begin
            q<=memory[cursor]; valid<=1; cursor=cursor+1; beats=beats-1; delay_count=1;
        end else busy<=0;
    end else if(wr) begin
        if(rd) $fatal(1,"Simultaneous native read/write");
        row=(writes%192)/12; col=writes%12;
        expected_pass=writes/192;
        for(n=0;n<8;n=n+1) wanted[n*12 +:12]=color((col/3)*8+n,row,expected_pass);
        if(address!==(writes%192) || data!==wanted[(col%3)*32 +:32])
            $fatal(1,"Live upload seam/write %0d: address=%0d data=%h wanted=%h",writes,address,data,wanted[(col%3)*32 +:32]);
        held_address<=address; held_data<=data; writing<=1; busy<=1; delay_count=3+writes%5;
    end else if(rd) begin
        if(burst!=11 && !(SCREENSHOT_PAUSE && burst==2)) $fatal(1,"Wrong native scanline/screenshot length");
        writing<=0; busy<=1; cursor=address; beats=burst+1; delay_count=5; reads=reads+1;
    end
    if(line_write) returned=returned+1;
end
task screenshot_read;
    begin
        dma_beats=0;dma_request=1;wait(dma_accepted);@(negedge clk);dma_request=0;
        wait(dma_done);@(negedge clk);if(dma_beats!=3 || !display) $fatal(1,"Screenshot DMA stalled HD storage");
    end
endtask
initial begin
    for(i=0;i<192;i=i+1) memory[i]=32'hdeadcafe;
    repeat(4) @(negedge clk); reset=0;
    repeat(20) @(negedge clk); quality=1;
    if(SCREENSHOT_PAUSE) begin
        wait(dispatches==3);@(negedge clk);pause=1;repeat(40) @(negedge clk);
        if(dispatches!=3 || done) $fatal(1,"Partial group did not hold");
        screenshot_read();pause=0;
        if(QUEUED) wait(dispatches==11);else wait(done);
        @(negedge clk);pause=1;wait(ack);repeat(20) @(negedge clk);
        if(dispatches!=(QUEUED ? 11 : 8) || done || coordinates.frame_hold || !display) $fatal(1,"Paused group lost its completion acknowledgement");
        screenshot_read();pause=0;
    end
    wait(finished); repeat(20) @(negedge clk);
    if(dispatches!=512 || writes!=192 || published!=64 || reads<10) $fatal(1,"First live pass incomplete");
    if(QUEUED && (max_ahead<=8 || !queue_empty)) $fatal(1,"Queued rendering did not progress past a slow group or drain");
    refine=1; wait(level==3 && finished); repeat(20) @(negedge clk);
    if(dispatches!=2048 || writes!=768 || published!=256 || decode(progress_gray)!=64)
        $fatal(1,"Refinement did not retain and replace the full image");
    quality=0; repeat(20) @(negedge clk);
    if(display || progress_gray!=0) $fatal(1,"Cancel did not hide/reset old capture");
    // Abort after a native write is accepted, before the group is published.
    // The next capture must replace the partial data without leaking it.
    wait(!busy && !active); @(negedge clk);
    refine=0; dispatches=0; published=0; writes=0;
    quality=1; wait(wr); @(negedge clk); quality=0;
    repeat(100) @(negedge clk);
    if(display || progress_gray!=0 || published!=0 || writes!=1)
        $fatal(1,"Partial upload cancellation exposed/acknowledged incomplete pixels");
    wait(!busy && !active); @(negedge clk);
    dispatches=0; published=0; writes=0; quality=1;
    wait(finished); repeat(20) @(negedge clk);
    if(dispatches!=512 || published!=64 || writes!=192) $fatal(1,"Recapture after partial upload failed");
    $display("PASS: 4 deeper passes, all live section edges, %0d competing reads, frontier, partial-upload cancel and recapture",reads);
    if(SCREENSHOT_PAUSE) $display("PASS: screenshot pauses inside a group and during upload, no extra dispatch, retained packed pixels, consumed acknowledgements, concurrent scanout/DMA and full HD resume");
    $finish;
end
initial begin #10000000; $fatal(1,"Progressive render timeout"); end
endmodule
module ProgressiveScreenshot_tb;
Progressive_tb #(.SCREENSHOT_PAUSE(1)) test();
endmodule
module QueuedProgressive_tb;
Progressive_tb #(.QUEUED(1),.SCREENSHOT_PAUSE(1)) test();
endmodule
