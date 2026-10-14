`timescale 1ns/1ps
module RenderWorker_tb;
reg clk = 1'b0, reset = 1'b1, latch = 1'b0, ack = 1'b0;
reg [82:0] input_word;
reg [31:0] step;
reg [1:0] palette;
reg [7:0] phase;
reg deep;
wire [34:0] result0, result1;
wire ready0, ready1, idle0, idle1, req0, req1;
reg [160:0] vectors [0:44];
integer i;
reg [34:0] expected;
always #5 clk = ~clk;

RenderWorker #(.USE_INTERLEAVED(1)) interleaved (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word), .latch_en(latch),
    .eRST(reset), .Engine_CLK(clk), .req_ack(ack), .detail_enable(1'b0),
    .deep_enable(deep), .turbo_enable(1'b1), .overrender_enable(1'b1),
    .sample_step(step), .palette(palette), .palette_phase(phase),
    .out_word(result0), .available(ready0), .idle(idle0), .service_req(req0)
);
RenderWorker #(.USE_INTERLEAVED(0)) baseline (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word), .latch_en(latch),
    .eRST(reset), .Engine_CLK(clk), .req_ack(ack), .detail_enable(1'b0),
    .deep_enable(deep), .turbo_enable(1'b1), .overrender_enable(1'b1),
    .sample_step(step), .palette(palette), .palette_phase(phase),
    .out_word(result1), .available(ready1), .idle(idle1), .service_req(req1)
);
initial begin
    $readmemh("output_files/sim/overrender_cases.hex", vectors);
    repeat (4) @(negedge clk);
    reset = 1'b0;
    for (i = 0; i < 45; i = i + 1) begin
        wait (idle0 && idle1);
        @(negedge clk);
        input_word = vectors[i][159:77];
        deep = vectors[i][160];
        step = vectors[i][76:45];
        palette = vectors[i][44:43];
        phase = vectors[i][42:35];
        expected = vectors[i][34:0];
        latch = 1'b1;
        @(negedge clk) latch = 1'b0;
        wait (req0 && req1);
        // The two implementations must hold their results under backpressure.
        repeat (12) begin
            @(negedge clk);
            if (result0 !== expected || result1 !== expected || ready0 || ready1)
                $fatal(1, "Quality vector %0d expected=%h interleaved=%h baseline=%h", i, expected, result0, result1);
        end
        ack = 1'b1;
        @(negedge clk) ack = 1'b0;
    end
    wait (idle0 && idle1);
    $display("PASS: 45 independent supersampling vectors on both workers, including 15233-iteration deep escape and stalled results");
    $finish;
end
initial begin
    #50000000;
    $fatal(1, "Quality worker timeout");
end
endmodule
