`timescale 1ns/1ps
// Identical quality pixels through the old and new cycle detectors. Measure
// acceptance-to-result clocks; result backpressure is excluded from latency.
module RenderPerformance_tb #(parameter CYCLE_BITS=8);
reg clk=0,reset=1,latch=0,ack=0;
reg [82:0] word;
reg [31:0] step;
reg [1:0] palette;
reg [7:0] phase;
wire [34:0] result0,result1;
wire idle0,idle1,req0,req1;
reg [34:0] expected;
integer file,csv,status,i,scene,pal,cycles,latency0,latency1;
integer sum0[0:2],sum1[0:2];
always #5 clk=~clk;
RenderWorker #(.USE_INTERLEAVED(1),.ADAPTIVE(1),.BRENT_CYCLE(1),.CYCLE_BITS(CYCLE_BITS)) candidate (
    .my_addr(3'd0),.engine_addr(3'd0),.in_word(word),.latch_en(latch),
    .eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b0),
    .deep_enable(1'b1),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .iteration_level(2'd2),.sample_step(step),.palette(palette),.palette_phase(phase),
    .out_word(result0),.available(),.idle(idle0),.service_req(req0));
RenderWorker #(.USE_INTERLEAVED(1),.ADAPTIVE(1),.BRENT_CYCLE(0)) baseline (
    .my_addr(3'd0),.engine_addr(3'd0),.in_word(word),.latch_en(latch),
    .eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b0),
    .deep_enable(1'b1),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .iteration_level(2'd2),.sample_step(step),.palette(palette),.palette_phase(phase),
    .out_word(result1),.available(),.idle(idle1),.service_req(req1));
initial begin
    file=$fopen("output_files/sim/engine_render_vectors.txt","r");
    csv=$fopen($sformatf("output_files/sim/render_performance_%0d.csv",CYCLE_BITS),"w");
    if(!file || !csv) $fatal(1,"Missing diagnostic render fixtures");
    $fdisplay(csv,"scene,pixel,baseline_clocks,candidate_clocks");
    for(i=0;i<3;i=i+1) begin sum0[i]=0; sum1[i]=0; end
    repeat(4) @(negedge clk); reset=0;
    for(i=0;i<144;i=i+1) begin
        status=$fscanf(file,"%d %h %h %d %h %h\n",scene,word,step,pal,phase,expected);
        if(status!=6) $fatal(1,"Invalid render vector %0d",i);
        palette=2'(pal);
        wait(idle0 && idle1); @(negedge clk); latch=1;
        @(negedge clk); latch=0; cycles=0; latency0=0; latency1=0;
        while(!(req0 && req1)) begin
            @(negedge clk); cycles=cycles+1;
            if(req0 && latency0==0) latency0=cycles;
            if(req1 && latency1==0) latency1=cycles;
            if(cycles>262300) $fatal(1,"Render vector %0d timeout",i);
        end
        repeat(4) begin
            @(negedge clk);
            if(result0!==expected || result1!==expected)
                $fatal(1,"Render vector %0d expected=%h candidate=%h baseline=%h",i,expected,result0,result1);
        end
        sum0[scene]=sum0[scene]+latency0; sum1[scene]=sum1[scene]+latency1;
        $fdisplay(csv,"%0d,%0d,%0d,%0d",scene,i,latency1,latency0);
        ack=1; @(negedge clk); ack=0;
    end
    for(i=0;i<3;i=i+1) begin
        $display("PERFORMANCE window=%0d scene=%0d baseline=%0d candidate=%0d speedup=%0f",1<<CYCLE_BITS,i,sum1[i],sum0[i],1.0*sum1[i]/sum0[i]);
    end
    if(sum0[0]+sum0[1]+sum0[2]>=sum1[0]+sum1[1]+sum1[2])
        $fatal(1,"Aggregate diagnostic render latency failed to improve");
    $fclose(file); $fclose(csv);
    $display("PASS: 144 independent quality pixels match both detectors; aggregate measured worker latency improves");
    $finish;
end
initial begin #200000000; $fatal(1,"Render performance timeout"); end
endmodule
