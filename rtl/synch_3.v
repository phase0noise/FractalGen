`default_nettype none

// Asynchronous assertion is handled by the reset source. This synchronizer is
// used only to release reset into the 100 MHz PLL domain.
module synch_3 (
    input  wire i,
    output wire o,
    input  wire clk
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] stages = 3'b000;

    always @(posedge clk or negedge i) begin
        if (!i)
            stages <= 3'b000;
        else
            stages <= {stages[1:0], 1'b1};
    end

    assign o = stages[2];
endmodule

`default_nettype wire
