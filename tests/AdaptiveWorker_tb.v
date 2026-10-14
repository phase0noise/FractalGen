`timescale 1ns/1ps
module AdaptiveWorker_tb;
reg clk=0,reset=1,latch=0,ack=0,deep=0;
reg [82:0] input_word=0;
reg [31:0] step=0;
reg [1:0] palette=0;
reg [7:0] phase=0;
wire [34:0] result0,result1,full_result;
wire req0,req1,req_full,idle0,idle1,idle_full;
reg [161:0] vectors[0:44];
integer i,count0=0,count1=0,count_full=0,cycle=0,time0=0,time_full=0;
integer short_cases=0,full_cases=0,adaptive_clocks=0,reference_clocks=0;
reg [34:0] expected;
always #5 clk=~clk;
RenderWorker #(.USE_INTERLEAVED(1),.ADAPTIVE(1)) adaptive (
    .my_addr(3'd0),.engine_addr(3'd0),.in_word(input_word),.latch_en(latch),.eRST(reset),.Engine_CLK(clk),
    .req_ack(ack),.detail_enable(1'b1),.deep_enable(deep),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .sample_step(step),.palette(palette),.palette_phase(phase),.iteration_level(deep ? 2'd2 : 2'd0),
    .out_word(result0),.available(),.idle(idle0),.service_req(req0));
RenderWorker #(.USE_INTERLEAVED(0),.ADAPTIVE(1)) baseline (
    .my_addr(3'd0),.engine_addr(3'd0),.in_word(input_word),.latch_en(latch),.eRST(reset),.Engine_CLK(clk),
    .req_ack(ack),.detail_enable(1'b1),.deep_enable(deep),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .sample_step(step),.palette(palette),.palette_phase(phase),.iteration_level(deep ? 2'd2 : 2'd0),
    .out_word(result1),.available(),.idle(idle1),.service_req(req1));
RenderWorker #(.USE_INTERLEAVED(1),.ADAPTIVE(0)) reference (
    .my_addr(3'd0),.engine_addr(3'd0),.in_word(input_word),.latch_en(latch),.eRST(reset),.Engine_CLK(clk),
    .req_ack(ack),.detail_enable(1'b1),.deep_enable(deep),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .sample_step(step),.palette(palette),.palette_phase(phase),.iteration_level(deep ? 2'd2 : 2'd0),
    .out_word(full_result),.available(),.idle(idle_full),.service_req(req_full));
always @(posedge clk) begin
    cycle=cycle+1;
    if(adaptive.quality_latch) count0=count0+1;
    if(baseline.quality_latch) count1=count1+1;
    if(reference.quality_latch) count_full=count_full+1;
    if(req0 && time0==0) time0=cycle;
    if(req_full && time_full==0) time_full=cycle;
end
initial begin
    $readmemh("output_files/sim/adaptive_cases.hex",vectors);
    repeat(4) @(negedge clk);reset=0;
    for(i=0;i<45;i=i+1) begin
        wait(idle0 && idle1 && idle_full);@(negedge clk);
        input_word=vectors[i][159:77];step=vectors[i][76:45];palette=vectors[i][44:43];phase=vectors[i][42:35];
        deep=vectors[i][160];expected=vectors[i][34:0];
        count0=0;count1=0;count_full=0;time0=0;time_full=0;cycle=0;latch=1;
        @(negedge clk);latch=0;wait(req0 && req1 && req_full);@(negedge clk);
        if(count0!=(vectors[i][161] ? 2 : 4) || count1!=count0 || count_full!=4)
            $fatal(1,"Adaptive sample count vector=%0d expected=%0d got=%0d/%0d",i,vectors[i][161]?2:4,count0,count1);
        repeat(7) begin @(negedge clk);if(result0!==expected || result1!==expected)
            $fatal(1,"Adaptive independent reference vector=%0d expected=%h got=%h/%h",i,expected,result0,result1);end
        if(vectors[i][161]) begin
            short_cases=short_cases+1;adaptive_clocks=adaptive_clocks+time0;reference_clocks=reference_clocks+time_full;
            if(time0>=time_full) $fatal(1,"Adaptive shortcut did not reduce latency");
        end else begin full_cases=full_cases+1;if(result0!==full_result) $fatal(1,"Boundary lost four-sample precision");end
        ack=1;@(negedge clk);ack=0;
    end
    if(short_cases<4 || full_cases<4) $fatal(1,"Adaptive branch coverage");
    $display("PASS: 45 adaptive vectors on both core types, %0d two-sample and %0d full-sample cases, identical-step deep escape preserved; shortcut latency %0d vs %0d clocks",short_cases,full_cases,adaptive_clocks,reference_clocks);$finish;
end
initial begin #50000000;$fatal(1,"Adaptive worker timeout");end
endmodule
