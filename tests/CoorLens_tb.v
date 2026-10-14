`timescale 1ns/1ps
module CoorLens_tb;
reg clk=0,reset=1,quality=0,ack=0;
always #5 clk=~clk;
wire latch,active,finished,tile_done;
wire [2:0] tile;
wire [82:0] word;
wire [31:0] step;
integer count=0,hold_cycles=0,x,y,px,py,dx,dy,radius,factor;
reg signed [63:0] zoom=46976205,bx,by,wanted_x,wanted_y,wanted_step;
localparam signed [31:0] CX=-32'sd12582912,CY=32'sd2211681;
Coor_gen #(.SCREEN_WIDTH(4),.SCREEN_HEIGHT(2),.QUALITY_TILE_HEIGHT(240)) dut (
    .cclk(clk),.ckey(4'b1111),.creset(reset),.cdones(7'b1111111),.cidle(7'b1111111),
    .clatch_en(latch),.cengine_addr(),.cword2engines(word),.frame(),
    .zoom_level(32'd46976205),.center_x(CX),.center_y(CY),.lens_enable(1'b1),
    .detail_enable(1'b0),.deep_enable(1'b0),.turbo_enable(1'b0),.overrender_enable(quality),
    .palette_select(2'd0),.palette_phase(8'd0),.tile_ack(ack),
    .detail_active(),.deep_active(),.turbo_active(),.overrender_active(active),
    .overrender_done(finished),.tile_done(tile_done),.tile_index(tile),.normal_ready(),
    .sample_step(step),.render_palette(),.render_phase()
);
always @(posedge clk) begin
    ack<=0;
    if(!reset && latch && active) begin
        x=word[82:73]; y=word[72:64];
        bx=CX+(((x+(tile[0]?640:0))*zoom)>>>10)-((320*zoom)>>>9);
        by=CY-(((y+tile[2:1]*240)*zoom)>>>10)+((240*zoom)>>>9);
        px=(x>>1)+(tile[0]?320:0); py=(y>>1)+tile[2:1]*120;
        dx=px-320; if(dx<0) dx=-dx;
        dy=py-240; if(dy<0) dy=-dy;
        dy=dy+(dy>>2)+(dy>>4)+(dy>>6);
        radius=(dx>dy)?dx:dy;
        factor=128+((radius*205)>>9); if(factor>256) factor=256;
        wanted_x=CX+(((bx-CX)*factor)>>>8);
        wanted_y=CY+(((by-CY)*factor)>>>8);
        wanted_step=((zoom>>11)*factor)>>8;
        if($signed(word[63:32])!==wanted_x[31:0] || $signed(word[31:0])!==wanted_y[31:0] || step!==wanted_step[31:0])
            $fatal(1,"Lens coordinate/spacing mismatch at tile %0d (%0d,%0d)",tile,x,y);
        count=count+1;
    end
    if(tile_done) begin
        hold_cycles=hold_cycles+1;
        if(hold_cycles==4) ack<=1;
    end else hold_cycles=0;
end
initial begin
    repeat(4) @(negedge clk); reset=0;
    repeat(12) @(negedge clk); quality=1;
    wait(finished);
    if(count!=4*240*8) $fatal(1,"Lens render incomplete");
    $display("PASS: 7680 exact lens coordinates and sample spacings across eight tiles, including center and clamped edge");
    $finish;
end
initial begin #1000000; $fatal(1,"Lens test timeout"); end
endmodule
