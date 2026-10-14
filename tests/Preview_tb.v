`timescale 1ns/1ps
// Model the staging RAM's registered read address; check both byte lanes and
// every image edge against the blue/violet palette with an independent formula.
module Preview_tb;
parameter CAPTURE_READS=0;
reg clk=0,reset=1;
always #6.667 clk=~clk;
wire [17:0] address;
reg [15:0] q;
wire [3:0] r,g,b;
wire hs,vs;
wire borrow_ok;
integer cycle=0,borrows=0;
wire borrow=CAPTURE_READS && borrow_ok && cycle%7!=0;
wire [17:0] capture_address=18'((cycle*131)%153600);
integer addr,x,y,even_x,idx0,idx1,old_h,old_v,next_h,next_v,pixels=0,level;
reg enabled;
reg [11:0] wanted;
function integer triangle(input integer value);
    integer p;
    begin p=value&255; triangle=p<128?p*2:255-(p-128)*2; end
endfunction
function [7:0] pixel_index(input integer px,py);
    pixel_index=(px+py*3)%254;
endfunction
always @(posedge clk) begin
    cycle=cycle+1;
    addr=borrow ? capture_address : address;if(borrow) borrows=borrows+1;
    y=addr/320; even_x=(addr%320)*2;
    q<={pixel_index(even_x+1,y),pixel_index(even_x,y)};
end
VGA dut (.clk(clk),.reset(reset),.framebuffer_q(q),.framebuffer_address(address),
    .palette_select(2'd3),.palette_cycle(1'b0),.fast_cycle(1'b0),.palette_freeze(1'b0),.visible(1'b1),
    .current_palette_phase(),.scan_y(),.scan_active(),.read_borrow_ok(borrow_ok),.red(r),.green(g),.blue(b),.hsync(hs),.vsync(vs));
always @(posedge clk) begin
    old_h=dut.h; old_v=dut.v; enabled=dut.pixel_enable;
    next_h=(old_h==799)?0:old_h+1;
    next_v=(old_h==799)?((old_v==524)?0:old_v+1):old_v;
    #1;
    if(!reset && enabled) begin
        if(hs!==(next_h>=96) || vs!==(next_v>=2)) $fatal(1,"Preview sync mismatch");
        if(next_h>=144 && next_h<784 && next_v>=35 && next_v<515) begin
            x=next_h-144; y=next_v-35; idx0=pixel_index(x,y);
            wanted={4'(triangle(idx0+64)/16),4'(triangle(idx0)/64),4'((96+triangle(idx0-32)/2)/16)};
            if({r,g,b}!==wanted)
                $fatal(1,"Preview pixel (%0d,%0d), expected=%h actual=%h",x,y,wanted,{r,g,b});
            pixels=pixels+1;
            if(pixels==640*480) begin
                if(CAPTURE_READS && borrows<1000) $fatal(1,"Screenshot RAM borrowing coverage");
                $display("PASS: all 307200 preview pixels, byte lanes, RAM latency, sync and image edges");
                if(CAPTURE_READS) $display("PASS: %0d screenshot RAM reads during blanking preserved all display pixels",borrows);
                $finish;
            end
        end else if({r,g,b}!==12'd0) $fatal(1,"Preview blanking mismatch");
    end
end
initial begin #100; reset=0; end
initial begin #20000000; $fatal(1,"Preview test timeout"); end
endmodule
module PreviewBorrow_tb;
Preview_tb #(.CAPTURE_READS(1)) test();
endmodule
