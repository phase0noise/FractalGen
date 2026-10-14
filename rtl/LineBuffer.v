// Two packed scanlines. 4 M10Ks; writer fills the bank that VGA is not using.
module LineBuffer (
    input write_clk, input write_enable,
    input [9:0] write_address, input [31:0] write_data,
    input read_clk, input [9:0] read_address,
    output reg [31:0] read_data
);
(* ramstyle = "M10K, no_rw_check" *) reg [31:0] words [0:1023];
always @(posedge write_clk)
    if (write_enable) words[write_address] <= write_data;
always @(posedge read_clk) read_data <= words[read_address];
endmodule
