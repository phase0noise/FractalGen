`timescale 1ns/1ps
// An enable dropout must not switch VGA clocks or restart the HD raster.
module HDSyncGuard_tb;
reg clk=0,reset=1,enable=0,ack=0,guard=0;
wire selected,hs,vs,request,tick;
wire [3:0] r,g,b;
wire [10:0] x;
wire [9:0] y;
integer old_h,old_v,n,checks=0,frames=0;
reg prior_selected=0;
always #4.63 clk=~clk;
HDVideo dut (.clk(clk),.reset(reset),.enable(enable),.progress_gray(18'd0),
    .line_request(request),.line_y(),.line_bank(),.line_ack(ack),
    .buffer_address(),.buffer_q(32'hf0ff0ff0),.selected(selected),.underflow(),
    .frame_tick(tick),.pixel_active(),.pixel_x(x),.pixel_y(y),
    .red(r),.green(g),.blue(b),.hsync(hs),.vsync(vs));
always @(posedge clk) begin
    ack<=request;
    old_h=dut.h; old_v=dut.v;
    #1;
    if(!reset && guard) begin
        if(!selected) $fatal(1,"Short HD enable dropout switched VGA away from HD");
        if(hs!==(old_h<112) || vs!==(old_v<3)) $fatal(1,"Sync changed independently of the raster");
        if(dut.h!==(old_h==1687 ? 11'd0 : 11'(old_h+1)) ||
           dut.v!==(old_h==1687 ? (old_v==1065 ? 11'd0 : 11'(old_v+1)) : 11'(old_v)))
            $fatal(1,"An HD enable change restarted or stalled the raster");
        checks=checks+1;
    end
    if(tick) frames=frames+1;
    prior_selected=selected;
end
initial begin
    repeat(4) @(negedge clk); reset=0; enable=1;
    wait(selected); repeat(20) @(negedge clk); guard=1;
    for(n=0;n<100;n=n+1) begin
        repeat(31+n%17) @(negedge clk); enable=0;
        repeat(3) @(negedge clk); enable=1;
    end
    wait(frames>=2); @(negedge clk); guard=0; enable=0;
    wait(!selected); repeat(8) @(negedge clk);
    // Cancel must also leave the internal timing clock running.
    old_h=dut.h; repeat(10) @(negedge clk);
    if(dut.h==old_h) $fatal(1,"Inactive HD timing stopped");
    enable=1; wait(selected); guard=1; repeat(2048) @(negedge clk);
    if(checks<1700000) $fatal(1,"Insufficient raster coverage");
    $display("PASS: %0d HD sync checks, 100 enable dropouts, continuous timing, clean frame-boundary cancel and restart",checks);
    $finish;
end
initial begin #110000000; $fatal(1,"HD sync guard timeout"); end
endmodule
