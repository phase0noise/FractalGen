`timescale 1ns/1ps
// Expected results come from an independent Python oracle that retains every
// exact orbit state, rather than reproducing the hardware checkpoint schedule.
module EngineCycle_tb;
reg clk=0, reset=1, latch=0, ack=0;
reg [82:0] word;
reg [1:0] level;
reg detail;
reg stress_mode=0;
wire [26:0] result0,result1;
wire idle0,idle1,req0,req1;
reg [31:0] re,im;
reg [7:0] expected;
integer file,status,i,lev,det,period,cycles;
reg [82:0] inputs[0:218];
reg [26:0] answers[0:218];
reg [1:0] levels[0:218];
reg details[0:218];
reg [218:0] retired_mask;
integer sent,retired,tag;
always #5 clk=~clk;
Engine_fast fast (.my_addr(3'd0),.engine_addr(3'd0),.in_word(word),
    .latch_en(latch && !stress_mode),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),
    .detail_enable(detail),.deep_enable(1'b0),.overrender_enable(1'b1),
    .iteration_level(level),.out_word(result0),.available(),.idle(idle0),.service_req(req0));
Engine_interleaved interleaved (.my_addr(3'd0),.engine_addr(3'd0),.in_word(word),
    .latch_en(latch),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),
    .detail_enable(detail),.deep_enable(1'b0),.turbo_enable(1'b0),.overrender_enable(1'b1),
    .iteration_level(level),.out_word(result1),.available(),.idle(idle1),.service_req(req1));
initial begin
    file=$fopen("output_files/sim/engine_cycle_vectors.txt","r");
    if(!file) $fatal(1,"Missing exact engine vectors");
    repeat(4) @(negedge clk); reset=0;
    for(i=0;i<219;i=i+1) begin
        status=$fscanf(file,"%h %h %d %d %h %d\n",re,im,lev,det,expected,period);
        if(status!=6) $fatal(1,"Invalid engine vector %0d",i);
        wait(idle0 && idle1); @(negedge clk);
        word={10'(i),9'(i),re,im}; level=2'(lev); detail=1'(det); latch=1;
        inputs[i]=word; answers[i]={10'(i),9'(i),expected};
        levels[i]=level; details[i]=detail;
        @(negedge clk); latch=0; level=0; detail=~detail; word=0;
        cycles=0;
        while(!(req0 && req1)) begin
            @(negedge clk); cycles=cycles+1;
            if(cycles>131100) $fatal(1,"Engine vector %0d timeout",i);
        end
        // A period-three interior must finish long before its iteration limit.
        if(period==3 && cycles>2048) $fatal(1,"Period-three speed regression %0d clocks",cycles);
        repeat(5) begin
            @(negedge clk);
            if(result0!=={10'(i),9'(i),expected} || result1!=={10'(i),9'(i),expected})
                $fatal(1,"Exact vector %0d c=%h,%h expected=%h fast=%h interleaved=%h",i,re,im,expected,result0,result1);
        end
        ack=1; @(negedge clk); ack=0;
    end
    $fclose(file);
    wait(idle0 && idle1); stress_mode=1;
    sent=0; retired=0; cycles=0; retired_mask=0;
    // Refill either context while its neighbor computes or holds a result.
    // Every context carries its own budget/detail/checkpoint metadata.
    while(retired<219) begin
        @(negedge clk); cycles=cycles+1; latch=0; ack=0;
        if(req1) begin
            tag=result1[26:17];
            if(tag>=sent || tag>=219 || retired_mask[tag] || result1!==answers[tag])
                $fatal(1,"Interleaved stream corrupt/duplicate result %h sent=%0d",result1,sent);
            if(cycles%5!=0) begin
                ack=1; retired_mask[tag]=1; retired=retired+1;
            end
        end
        if(interleaved.available && sent<219) begin
            word=inputs[sent]; level=levels[sent]; detail=details[sent];
            latch=1; sent=sent+1;
        end else begin word=0; level=0; detail=~detail; end
        if(cycles>3000000) $fatal(1,"Interleaved stream timeout");
    end
    @(negedge clk); latch=0; ack=0; wait(idle1);
    // Reset with both contexts in a long-running orbit, then restart. No
    // checkpoint, pending multiply or result may survive the cancellation.
    @(negedge clk); word={10'd1,9'd1,32'd4194305,32'd0}; level=3; detail=0; latch=1;
    repeat(2) @(negedge clk); latch=0;
    repeat(100) @(negedge clk); reset=1;
    @(negedge clk); reset=0;
    repeat(4) @(negedge clk);
    if(!idle1 || req1) $fatal(1,"Reset left a stale interleaved context");
    word={10'd999,9'd511,64'd0}; latch=1;
    @(negedge clk); latch=0; word=0;
    wait(req1);
    repeat(8) begin
        @(negedge clk);
        if(result1!=={10'd999,9'd511,8'hfe}) $fatal(1,"Reset/restart result corrupt");
    end
    ack=1; @(negedge clk); ack=0; wait(idle1);
    $display("PASS: 219 independent exact-orbit vectors on both engines plus 219 mixed-budget two-context refills, stalls and active reset/restart");
    $finish;
end
initial begin #100000000; $fatal(1,"Exact engine test timeout"); end
endmodule
