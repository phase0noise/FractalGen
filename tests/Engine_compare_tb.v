`timescale 1ns/1ps
`include "mandel_constants.vh"

module Engine_compare_tb;
reg clk = 1'b0;
reg reset = 1'b1;
reg latch = 1'b0;
reg ack_reference = 1'b0;
reg ack_fast = 1'b0;
reg [82:0] input_word;
wire [26:0] reference_word;
wire [26:0] fast_word;
wire available_reference, available_fast;
wire idle_fast;
wire request_reference, request_fast;
integer failures = 0;
integer tests = 0;
integer xr, yi;
reg [26:0] captured_reference, captured_fast;

always #5 clk = ~clk;

Engine reference_engine (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word),
    .latch_en(latch), .eRST(reset), .Engine_CLK(clk),
    .req_ack(ack_reference), .out_word(reference_word),
    .available(available_reference), .service_req(request_reference)
);

Engine_fast fast_engine (
    .my_addr(3'd0), .engine_addr(3'd0), .in_word(input_word),
    .latch_en(latch), .eRST(reset), .Engine_CLK(clk),
    .detail_enable(1'b0), .deep_enable(1'b0), .overrender_enable(1'b0),
    .req_ack(ack_fast), .out_word(fast_word),
    .available(available_fast), .idle(idle_fast), .service_req(request_fast)
);

task run_point;
    input signed [31:0] real_part;
    input signed [31:0] imag_part;
    begin
        wait (available_reference && available_fast);
        @(negedge clk);
        input_word = {10'd17, 9'd23, real_part, imag_part};
        latch = 1'b1;
        @(negedge clk);
        latch = 1'b0;

        fork
            begin
                wait (request_reference);
                @(negedge clk);
                ack_reference = 1'b1;
                #1 captured_reference = reference_word;
                @(negedge clk);
                ack_reference = 1'b0;
            end
            begin
                wait (request_fast);
                captured_fast = fast_word;
                @(negedge clk);
                ack_fast = 1'b1;
                @(negedge clk);
                ack_fast = 1'b0;
            end
        join

        tests = tests + 1;
        if (captured_reference !== captured_fast) begin
            failures = failures + 1;
            $display("MISMATCH c=(%0d,%0d) reference=%h fast=%h",
                     real_part, imag_part, captured_reference, captured_fast);
        end
        wait (available_reference && available_fast);
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // Q8.24 grid spanning the interesting part of the Mandelbrot plane.
    for (xr = -2; xr <= 1; xr = xr + 1)
        for (yi = -1; yi <= 1; yi = yi + 1)
            run_point(xr * 32'sd16777216, yi * 32'sd12582912);

    run_point(-32'sd12582912,  32'sd1677720);  // -0.75 + 0.10i
    run_point(-32'sd16777216,  32'sd0);        // -1.0 + 0.0i
    run_point( 32'sd4194304,   32'sd0);        //  0.25 + 0.0i
    run_point(-32'sd12398378,  32'sd220117);   // Seahorse-valley vicinity

    if (failures == 0)
        $display("PASS: %0d legacy/fast engine comparisons matched", tests);
    else
        $display("FAIL: %0d of %0d comparisons mismatched", failures, tests);
    $finish;
end

initial begin
    #2000000;
    $display("FAIL: timeout");
    $finish;
end

endmodule
