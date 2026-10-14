`timescale 1ns/1ps
`include "mandel_constants.vh"

module Engine_interleaved_tb;
reg clk = 1'b0;
reg reset = 1'b1;
reg [82:0] input_word = 83'd0;
reg latch_interleaved = 1'b0;
reg latch_reference0 = 1'b0;
reg latch_reference1 = 1'b0;
reg ack_interleaved = 1'b0;
reg ack_reference0 = 1'b0;
reg ack_reference1 = 1'b0;
reg detail = 1'b0;
reg deep = 1'b0;

wire [26:0] interleaved_word, reference_word0, reference_word1;
wire available_interleaved, idle_interleaved, request_interleaved;
wire available_reference0, available_reference1;
wire idle_reference0, idle_reference1;
wire request_reference0, request_reference1;

integer failures = 0;
integer tests = 0;
integer cycle_count = 0;
integer pair_start;
integer interleaved_pair_cycles = 0;
reg [26:0] expected0, expected1, actual0, actual1;

always #5 clk = ~clk;
always @(posedge clk) cycle_count <= cycle_count + 1;

Engine_interleaved dut (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word),
    .latch_en(latch_interleaved), .eRST(reset), .Engine_CLK(clk),
    .req_ack(ack_interleaved), .detail_enable(detail), .deep_enable(deep),
    .turbo_enable(1'b0), .overrender_enable(1'b0),
    .out_word(interleaved_word), .available(available_interleaved),
    .idle(idle_interleaved), .service_req(request_interleaved)
);

Engine_fast reference0 (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word),
    .latch_en(latch_reference0), .eRST(reset), .Engine_CLK(clk),
    .req_ack(ack_reference0), .detail_enable(detail), .deep_enable(deep),
    .overrender_enable(1'b0), .out_word(reference_word0), .available(available_reference0),
    .idle(idle_reference0), .service_req(request_reference0)
);

Engine_fast reference1 (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word),
    .latch_en(latch_reference1), .eRST(reset), .Engine_CLK(clk),
    .req_ack(ack_reference1), .detail_enable(detail), .deep_enable(deep),
    .overrender_enable(1'b0), .out_word(reference_word1), .available(available_reference1),
    .idle(idle_reference1), .service_req(request_reference1)
);

task run_pair;
    input signed [31:0] real0;
    input signed [31:0] imag0;
    input signed [31:0] real1;
    input signed [31:0] imag1;
    input detail_mode;
    input deep_mode;
    begin
        wait (idle_interleaved && idle_reference0 && idle_reference1);
        detail = detail_mode;
        deep = deep_mode;
        pair_start = cycle_count;

        @(negedge clk);
        input_word = {10'd101, 9'd77, real0, imag0};
        latch_interleaved = 1'b1;
        latch_reference0 = 1'b1;
        @(negedge clk);
        input_word = {10'd202, 9'd155, real1, imag1};
        latch_reference0 = 1'b0;
        latch_reference1 = 1'b1;
        @(negedge clk);
        latch_interleaved = 1'b0;
        latch_reference1 = 1'b0;

        // Deliberately leave the result path stalled until both context slots
        // are DONE. This proves that simultaneous pending results are retained.
        wait (request_reference0 && request_reference1 &&
              (dut.context_state[0] == 2'd2) &&
              (dut.context_state[1] == 2'd2));
        #1; // Allow the combinational selector to settle after DONE.
        interleaved_pair_cycles = interleaved_pair_cycles +
                                  (cycle_count - pair_start);
        expected0 = reference_word0;
        expected1 = reference_word1;
        actual0 = interleaved_word;

        @(negedge clk);
        ack_interleaved = 1'b1;
        ack_reference0 = 1'b1;
        ack_reference1 = 1'b1;
        @(posedge clk);
        #1 actual1 = interleaved_word;
        @(posedge clk);
        @(negedge clk);
        ack_interleaved = 1'b0;
        ack_reference0 = 1'b0;
        ack_reference1 = 1'b0;

        tests = tests + 2;
        if (actual0 !== expected0) begin
            failures = failures + 1;
            $display("MISMATCH A expected=%h actual=%h", expected0, actual0);
        end
        if (actual1 !== expected1) begin
            failures = failures + 1;
            $display("MISMATCH B expected=%h actual=%h", expected1, actual1);
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    run_pair(-32'sd12582912, 32'sd1677720,
             -32'sd33554432, 32'sd0, 1'b0, 1'b0);
    run_pair(32'sd8388608, 32'sd4194304,
             -32'sd16777216, 32'sd0, 1'b1, 1'b0);
    run_pair(-32'sd12398378, 32'sd220117,
             -32'sd20971520, 32'sd10485760, 1'b1, 1'b1);

    if (failures == 0)
        $display("PASS: %0d interleaved/reference results matched; aggregate pair latency %0d clocks",
                 tests, interleaved_pair_cycles);
    else
        $display("FAIL: %0d of %0d results mismatched", failures, tests);
    $finish;
end

initial begin
    #1000000;
    $display("FAIL: timeout");
    $finish;
end

endmodule
