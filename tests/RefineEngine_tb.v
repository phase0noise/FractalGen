`timescale 1ns/1ps
// The Q8.24 point immediately outside the cardioid cusp escapes at 15233.
// Verify that increasing the budget reveals it, including the 65535 limit.
module RefineEngine_tb;
reg clk=0,reset=1,latch=0,ack=0;
reg [1:0] level=0;
wire req0,req1,free0,free1;
wire [26:0] word0,word1;
integer i;
always #5 clk=~clk;
Engine_fast a (.my_addr(3'd0),.engine_addr(3'd0),.in_word({10'd1,9'd1,32'd4194305,32'd0}),
    .latch_en(latch),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b0),
    .deep_enable(1'b0),.overrender_enable(1'b1),.iteration_level(level),
    .out_word(word0),.available(free0),.idle(),.service_req(req0));
Engine_interleaved b (.my_addr(3'd0),.engine_addr(3'd0),.in_word({10'd1,9'd1,32'd4194305,32'd0}),
    .latch_en(latch),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b0),
    .deep_enable(1'b0),.turbo_enable(1'b0),.overrender_enable(1'b1),.iteration_level(level),
    .out_word(word1),.available(free1),.idle(),.service_req(req1));
initial begin
    repeat(4) @(negedge clk); reset=0;
    for(i=0;i<4;i=i+1) begin
        wait(free0 && free1); @(negedge clk); level=2'(i); latch=1;
        @(negedge clk); latch=0; level=0; // Budget must be latched per context.
        wait(req0 && req1);
        if(word0!==word1 || word0[7:0]!==(i==0?8'hfe:8'd129))
            $fatal(1,"Refinement level %0d failed: fast=%h interleaved=%h",i,word0,word1);
        repeat(4) @(negedge clk); ack=1; @(negedge clk); ack=0;
    end
    $display("PASS: latched 8191/16383/32767/65535 budgets on both engines; late escape becomes visible");
    $finish;
end
initial begin #20000000; $fatal(1,"Refinement engine timeout"); end
endmodule
