`timescale 1ns/1ps
module RenderQueue_tb;
reg clk=0,reset=1,active=1,dispatch=0,pixel_valid=0,ack=0;
reg [2:0] dispatch_lane=0,pixel_lane=0;
reg [1:0] pixel_slot=0;
reg [23:0] dispatch_base=0;
reg [11:0] rgb=0;
wire ready,valid,empty;
wire [1:0] dispatch_slot;
wire [23:0] base;
wire [95:0] pixels;
wire [31:0] allocated,retired;
integer group,lane,checks=0;
always #5 clk=~clk;
RenderQueue dut (.clk(clk),.reset(reset),.active(active),.dispatch(dispatch),
    .dispatch_lane(dispatch_lane),.dispatch_base(dispatch_base),.dispatch_ready(ready),.dispatch_slot(dispatch_slot),
    .pixel_valid(pixel_valid),.pixel_slot(pixel_slot),.pixel_lane(pixel_lane),.pixel_rgb(rgb),
    .group_valid(valid),.group_base(base),.group_pixels(pixels),.group_ack(ack),.empty(empty),
    .allocated_groups(allocated),.retired_groups(retired));
function [11:0] color;
    input integer g,l;begin color=12'((g+1)*131+l*29);end
endfunction
task allocate;
    input integer g;
    begin
        for(lane=0;lane<8;lane=lane+1) begin
            @(negedge clk);dispatch_lane=lane;dispatch_base=g*3;dispatch=1;#1;
            if(!ready || dispatch_slot!=g%4) $fatal(1,"Dispatch slot/backpressure group=%0d lane=%0d",g,lane);
        end
        @(negedge clk);dispatch=0;dispatch_lane=0;
    end
endtask
task give_pixel;
    input integer g,l;
    begin @(negedge clk);pixel_valid=1;pixel_slot=g%4;pixel_lane=l;rgb=color(g,l);
        @(negedge clk);pixel_valid=0;end
endtask
task check_group;
    input integer g;
    integer l;
    begin
        if(!valid || base!=g*3) $fatal(1,"Publication order group=%0d valid=%b base=%0d",g,valid,base);
        for(l=0;l<8;l=l+1) if(pixels[l*12 +:12]!==color(g,l)) $fatal(1,"Queue color/tag mismatch %0d:%0d",g,l);
        checks=checks+1;
    end
endtask
task retire;
    input integer g;
    begin repeat(5) begin @(negedge clk);check_group(g);end
        ack=1;@(negedge clk);ack=0;end
endtask
initial begin
    repeat(4) @(negedge clk);reset=0;
    for(group=0;group<4;group=group+1) allocate(group);
    #1;if(ready || empty || allocated!=4) $fatal(1,"Full queue failed to stop the fifth group");
    // Finish later groups first. The head's missing pixel must hold publication.
    for(group=3;group>0;group=group-1) for(lane=7;lane>=0;lane=lane-1) give_pixel(group,lane);
    for(lane=7;lane>0;lane=lane-1) give_pixel(0,lane);
    repeat(9) begin @(negedge clk);if(valid || ready) $fatal(1,"Incomplete head was published");end
    give_pixel(0,0);retire(0);
    allocate(4);
    for(lane=7;lane>=0;lane=lane-1) give_pixel(4,lane);
    retire(1);retire(2);
    // Allocate and retire on the same clock, then exercise another wrap.
    @(negedge clk);dispatch=1;dispatch_lane=0;dispatch_base=15;ack=1;check_group(3);
    @(negedge clk);dispatch=0;ack=0;
    if(allocated!=6 || retired!=4) $fatal(1,"Simultaneous allocation/retirement accounting");
    for(lane=0;lane<8;lane=lane+1) give_pixel(5,lane);
    retire(4);retire(5);
    if(!empty || allocated!=6 || retired!=6) $fatal(1,"Queue did not drain exactly once");
    allocate(6);give_pixel(6,3);
    @(negedge clk);active=0;pixel_valid=1;pixel_slot=2;pixel_lane=0;
    repeat(3) @(negedge clk);pixel_valid=0;active=1;
    @(negedge clk);if(valid || !empty || allocated || retired) $fatal(1,"Cancelled queue kept stale data");
    allocate(0);for(lane=0;lane<8;lane=lane+1) give_pixel(0,lane);retire(0);
    $display("PASS: %0d ordered queue checks, slow head, out-of-order returns, full backpressure, stable held results, slot wrap, simultaneous retirement and cancellation",checks);$finish;
end
initial begin #100000;$fatal(1,"Queue timeout");end
endmodule
