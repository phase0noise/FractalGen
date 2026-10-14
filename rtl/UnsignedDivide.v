// One bit per clock. Shared setup/lens divider adds no DSP or block RAM.
module UnsignedDivide #(parameter WIDTH=44, DIVISOR_BITS=13) (
    input clk,reset,start,input [WIDTH-1:0] numerator,
    input [DIVISOR_BITS-1:0] denominator,
    output reg busy,done,output reg [WIDTH-1:0] quotient,
    output reg [DIVISOR_BITS-1:0] remainder
);
reg [WIDTH-1:0] bits;
reg [DIVISOR_BITS-1:0] divisor;
reg [6:0] count;
wire [DIVISOR_BITS:0] trial={remainder,bits[WIDTH-1]};
wire subtract=trial>={1'b0,divisor};
always @(posedge clk or posedge reset)
    if(reset) begin busy<=0; done<=0; quotient<=0; remainder<=0; bits<=0; divisor<=1; count<=0; end
    else begin
        done<=0;
        if(start && !busy) begin busy<=1; bits<=numerator; divisor<=denominator;
            quotient<=0; remainder<=0; count<=0; end
        else if(busy) begin
            bits<=bits<<1; remainder<=subtract ? trial-divisor : trial;
            quotient<={quotient[WIDTH-2:0],subtract};
            if(count==WIDTH-1) begin busy<=0; done<=1; end else count<=count+1'b1;
        end
    end
endmodule
