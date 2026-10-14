`timescale 1ns/1ps
`include "mandel_constants.vh"
// Real seven-worker raster/queue/commit path, with deterministic native memory
// latency. Both frames must match independent RGB444 and packed-word oracles.
module FrameHarness #(parameter BRENT_CYCLE=1) (
    input clk,reset,start,input [1:0] scene,
    input [31:0] cx,cy,zoom,output reg completed=0,output reg [31:0] clocks=0
);
wire latch,busy,done,request,pixel_valid;
wire [82:0] coordinates;
wire [31:0] step,data;
wire [23:0] address;
wire [19:0] groups;
wire [2:0] engine_address,selected_engine;
wire [1:0] dispatch_slot;
wire [6:0] available,idle,requests,acks;
wire [244:0] results;
wire [34:0] selected;
reg [1:0] worker_slot[0:6];
reg commit_valid=0,buffer_valid=0,accepted=0,word_done=0;
reg [34:0] commit_word,buffer_word;
reg [1:0] commit_slot,buffer_slot;
reg [34:0] expected[0:143];
reg [47:0] seen;
reg [95:0] packed_pixels;
integer pixels=0,words=0,native=0,i,tag;
initial $readmemh("output_files/sim/frame_expected.hex",expected);
genvar w;
generate for(w=0;w<7;w=w+1) begin: workers
    RenderWorker #(.ADAPTIVE(1),.USE_INTERLEAVED(1),.BRENT_CYCLE(BRENT_CYCLE)) worker (
        .my_addr(3'(w)),.engine_addr(engine_address),.in_word(coordinates),.latch_en(latch),
        .eRST(reset),.Engine_CLK(clk),.req_ack(acks[w]),.detail_enable(1'b1),
        .deep_enable(1'b1),.turbo_enable(1'b0),.overrender_enable(1'b1),
        .iteration_level(2'd2),.sample_step(step),.palette(2'd0),.palette_phase(8'd0),
        .out_word(results[w*35 +:35]),.available(available[w]),.idle(idle[w]),.service_req(requests[w]));
    always @(posedge clk) if(latch && engine_address==w) worker_slot[w]<=dispatch_slot;
end endgenerate
ResultArbiter arbiter (.engine_req(requests),.engine_words(results),.scanline(9'd0),
    .scan_active(1'b0),.req_ack(acks),.selected_word(selected),.selected_engine(selected_engine),.write_enable(pixel_valid));
UhdRenderer #(.WIDTH(8),.HEIGHT(6)) raster (.clk(clk),.reset(reset),.start(start),.cancel(1'b0),
    .center_x(cx),.center_y(cy),.zoom(zoom),.lens(1'b0),.available(available),.idle(idle),
    .writes_drained(!pixel_valid && !commit_valid && !buffer_valid),
    .latch(latch),.engine_address(engine_address),.coordinate_word(coordinates),.sample_step(step),
    .dispatch_slot(dispatch_slot),.pixel_slot(buffer_slot),.pixel_valid(buffer_valid),
    .pixel_offset(buffer_word[27:25]),.pixel_rgb(buffer_word[11:0]),.busy(busy),.done(done),
    .cancelled(),.groups_finished(groups),.word_request(request),.word_address(address),
    .word_data(data),.word_accepted(accepted),.word_done(word_done));
always @(posedge clk) begin
    if(reset) begin commit_valid<=0;buffer_valid<=0;completed<=0;clocks<=0;accepted<=0;word_done<=0; end
    else begin
        commit_valid<=pixel_valid; buffer_valid<=commit_valid;
        if(pixel_valid) begin commit_word<=selected;commit_slot<=worker_slot[selected_engine]; end
        if(commit_valid) begin buffer_word<=commit_word;buffer_slot<=commit_slot; end
        if(start) begin completed<=0;clocks<=0;pixels=0;words=0;native=0;seen=0; end
        else if(busy) clocks<=clocks+1;
        if(pixel_valid) begin
            tag=selected[34:25]+8*selected[24:16];
            if(tag>=48 || seen[tag] || selected!==expected[48*scene+tag])
                $fatal(1,"Frame %0d detector=%0d corrupt/duplicate pixel %h",scene,BRENT_CYCLE,selected);
            seen[tag]=1;pixels=pixels+1;
        end
        accepted<=0;word_done<=0;
        if(request && native==0) begin
            for(i=0;i<8;i=i+1) packed_pixels[i*12 +:12]=expected[48*scene+8*(words/3)+i][11:0];
            if(address!==24'h100000+24'(words) || data!==packed_pixels[(words%3)*32 +:32])
                $fatal(1,"Frame %0d detector=%0d packed word %0d corrupt",scene,BRENT_CYCLE,words);
            accepted<=1;native=1;words=words+1;
        end else if(native!=0) begin
            if(native==9+words%7) begin word_done<=1;native=0; end else native=native+1;
        end
        if(done) begin
            if(pixels!=48 || words!=18 || groups!=6 || seen!={48{1'b1}})
                $fatal(1,"Incomplete diagnostic frame");
            completed<=1;
        end
    end
end
endmodule

module FractalFrame_tb;
reg clk=0,reset=1,start=0;
reg [1:0] scene=0;
reg [31:0] cx,cy,zoom;
wire completed0,completed1;
wire [31:0] clocks0,clocks1;
integer file,status,s,csv;
always #5 clk=~clk;
FrameHarness #(.BRENT_CYCLE(1)) candidate(clk,reset,start,scene,cx,cy,zoom,completed0,clocks0);
FrameHarness #(.BRENT_CYCLE(0)) baseline(clk,reset,start,scene,cx,cy,zoom,completed1,clocks1);
initial begin
    file=$fopen("output_files/sim/frame_views.txt","r");
    csv=$fopen("output_files/sim/frame_performance.csv","w");
    if(!file || !csv) $fatal(1,"Missing frame fixtures");
    $fdisplay(csv,"scene,baseline_clocks,candidate_clocks");
    repeat(4) @(negedge clk);reset=0;
    for(s=0;s<3;s=s+1) begin
        status=$fscanf(file,"%h %h %h\n",cx,cy,zoom);
        if(status!=3) $fatal(1,"Invalid frame view");
        scene=2'(s);start=1;@(negedge clk);start=0;
        @(negedge clk);wait(completed0 && completed1);@(negedge clk);
        $display("FRAME scene=%0d baseline=%0d candidate=%0d speedup=%0f",s,clocks1,clocks0,1.0*clocks1/clocks0);
        $fdisplay(csv,"%0d,%0d,%0d",s,clocks1,clocks0);
    end
    $fclose(file);$fclose(csv);
    $display("PASS: three complete seven-worker diagnostic frames, exact pixels/packed memory, real raster/queue/arbiter/commit stages and drained completion");
    $finish;
end
initial begin #10000000;$fatal(1,"Diagnostic frame timeout"); end
endmodule
