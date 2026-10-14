`timescale 1ns/1ps
// Equal orbit/sample values must have equal colors at every pixel location.
// Check exact DAC rounding across its complete legal four-sample range.
module SmoothColor_tb;
reg clk=0,reset=1,latch=0,ack=0;
reg [9:0] x=0,red_sum=0,green_sum=0,blue_sum=0;
reg [8:0] y=0;
reg signed [31:0] re=0,im=0;
wire [11:0] rgb;
wire [26:0] fast_word,interleaved_word;
wire fast_ready,interleaved_ready,fast_req,interleaved_req;
integer sum,position,point,checks=0;
reg [11:0] wanted;
reg [7:0] wanted_index;
always #5 clk=~clk;
SupersampleColor quantizer (.red_sum(red_sum),.green_sum(green_sum),.blue_sum(blue_sum),
    .pixel_x(x),.pixel_y(y),.rgb(rgb));
Engine_fast fast (.my_addr(3'd0),.engine_addr(3'd0),.in_word({x,y,re,im}),
    .latch_en(latch),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b1),
    .deep_enable(1'b0),.overrender_enable(1'b0),.iteration_level(2'd0),
    .out_word(fast_word),.available(fast_ready),.idle(),.service_req(fast_req));
Engine_interleaved interleaved (.my_addr(3'd0),.engine_addr(3'd0),.in_word({x,y,re,im}),
    .latch_en(latch),.eRST(reset),.Engine_CLK(clk),.req_ack(ack),.detail_enable(1'b1),
    .deep_enable(1'b0),.overrender_enable(1'b0),.iteration_level(2'd0),.turbo_enable(1'b0),
    .out_word(interleaved_word),.available(interleaved_ready),.idle(),.service_req(interleaved_req));
initial begin
    for(sum=0;sum<=1020;sum=sum+1) begin
        red_sum=10'(sum);green_sum=10'(1020-sum);blue_sum=10'(sum/2);
        // An eight-bit channel expands from the DAC by x17. Find the DAC
        // value whose expanded four-sample sum is closest, ties rounding up.
        wanted={4'((sum+34)/68),4'((1020-sum+34)/68),4'((sum/2+34)/68)};
        for(position=0;position<16;position=position+1) begin
            x=10'(position%4);y=9'(position/4);#1;
            if(rgb!==wanted) $fatal(1,"Spatial dots/quantization error: sum=%0d position=%0d expected=%h actual=%h",sum,position,wanted,rgb);
            checks=checks+1;
        end
    end
    repeat(4) @(negedge clk);reset=0;
    for(point=0;point<2;point=point+1) for(position=0;position<16;position=position+1) begin
        wait(fast_ready && interleaved_ready);@(negedge clk);
        x=10'(position%4);y=9'(position/4);
        re=point==0 ? 32'sh02000000 : 32'sh03000000;
        im=point==0 ? 32'sh01000000 : 0;
        // Both points escape on the first iteration. Their squared
        // magnitudes are 5 and 9: fractions 2/16 and 10/16 round to 0 and 1.
        wanted_index=8'(point);latch=1;@(negedge clk);latch=0;
        wait(fast_req && interleaved_req);@(negedge clk);
        if(fast_word!=={x,y,wanted_index} || interleaved_word!=={x,y,wanted_index})
            $fatal(1,"Orbit color depends on pixel position: point=%0d position=%0d fast=%h interleaved=%h",point,position,fast_word,interleaved_word);
        ack=1;@(negedge clk);ack=0;
    end
    $display("PASS: %0d exact RGB444 quantization checks, full range/endpoints/ties and all spatial residues; both escape engines have position-independent detail colors",checks);
    $finish;
end
initial begin #1000000;$fatal(1,"Smooth color timeout");end
endmodule
