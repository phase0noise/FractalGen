`timescale 1ns/1ps
module BmpHeader_tb;
reg clk=0,reset=1,start=0,abort=0;
reg [1:0] mode=0;
always #5 clk=~clk;
wire valid;
wire [7:0] data;
reg [7:0] bytes[0:53];
integer count=0,i,w,h;
BmpStream dut (.clk(clk),.reset(reset),.start(start),.abort(abort),.mode(mode),.scheme(4'd0),.color_offset(4'd0),.effects(8'd0),.phases(57'd0),
    .busy(),.done(),.byte_valid(valid),.byte_data(data),.byte_ready(1'b1),.word_request(),.word_address(),
    .word_accepted(1'b0),.word_done(1'b0),.word_valid(1'b0),.word_q(32'd0),
    .preview_request(),.preview_address(),.preview_accepted(1'b0),.preview_q(16'd0));
always @(posedge clk) if(valid) begin if(count<54) bytes[count]=data;count=count+1;end
function [31:0] le;
    input integer p;begin le={bytes[p+3],bytes[p+2],bytes[p+1],bytes[p]};end
endfunction
initial begin
    repeat(4) @(negedge clk);reset=0;
    for(i=0;i<3;i=i+1) begin
        mode=2'(i);count=0;start=1;@(negedge clk);start=0;wait(count==54);@(negedge clk);
        w=i==0 ? 640 : i==1 ? 1280 : 3840;h=i==0 ? 480 : i==1 ? 1024 : 2160;
        if({bytes[1],bytes[0]}!=16'h4d42 || le(2)!=54+w*h*3 || le(10)!=54 || le(14)!=40 || le(18)!=w ||
            $signed(le(22))!=-h || bytes[26]!=1 || bytes[28]!=24 || le(30)!=0 || le(34)!=w*h*3)
            $fatal(1,"Production BMP header mode=%0d",i);
        abort=1;@(negedge clk);abort=0;repeat(4) @(negedge clk);
    end
    $display("PASS: production 640x480, 1280x1024 and 3840x2160 BMP dimensions, top-down orientation, RGB24 format and exact file sizes");$finish;
end
endmodule
