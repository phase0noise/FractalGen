// Combinational priority arbiter for completed engine results.
// It accepts one result on every engine-clock edge instead of spending four
// clocks on each framebuffer write transaction.

`include "mandel_constants.vh"

module ResultArbiter (
    input  [`NUM_PROC-1:0] engine_req,
    input  [`NUM_PROC*35-1:0] engine_words,
    input  [8:0] scanline,
    input        scan_active,
    output reg [`NUM_PROC-1:0] req_ack,
    output reg [34:0] selected_word,
    output reg [`E_ADDR_WIDTH-1:0] selected_engine,
    output write_enable
);

integer j;
reg found;
reg [8:0] candidate_y;
reg conflicts_with_scan;

always @(*) begin
    req_ack      = {`NUM_PROC{1'b0}};
    selected_word = 35'd0;
    selected_engine=0;
    found         = 1'b0;

    // Lowest-numbered requesting engine wins, matching the old arbiter.
    for (j = 0; j < `NUM_PROC; j = j + 1) begin
        candidate_y = engine_words[j*35+16 +: 9];
        conflicts_with_scan = scan_active &&
            ((candidate_y == scanline) ||
             ((scanline != 9'd0) && (candidate_y == scanline - 1'b1)) ||
             ((scanline != 9'd479) && (candidate_y == scanline + 1'b1)));
        if (engine_req[j] && !found && !conflicts_with_scan) begin
            req_ack[j]   = 1'b1;
            selected_word = engine_words[j*35 +: 35];
            selected_engine=j;
            found         = 1'b1;
        end
    end
end

assign write_enable = found;

endmodule
