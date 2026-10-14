`timescale 1ns/1ps
`include "mandel_constants.vh"
module UhdRenderer_tb;
reg clk=0,reset=1,start=0,cancel=0,lens=0;
wire latch,busy,done,cancelled,request;wire [`E_ADDR_WIDTH-1:0] ea;
wire [82:0] coordinates;wire [31:0] step,data;wire [23:0] address;wire [19:0] groups;
wire [1:0] dispatch_slot;reg [1:0] pixel_slot=0;
reg pixel_valid=0,accepted=0,word_done=0;reg [2:0] offset=0;reg [11:0] rgb=0;
integer pixels=0,words=0,x,y,k,native=0,checks=0,cycle=0,ahead=0,max_ahead=0;
integer dx,dy,radius,factor;
reg [95:0] expected_pixels;reg [23:0] expected_address;
reg [31:0] zoom=46976205;
reg signed [63:0] expected_x,expected_y,wide_zoom;
wire [`NUM_PROC-1:0] available=cycle%5==0 ? 7'b1000000 : 7'b1111111;
wire [`NUM_PROC-1:0] idle={7{!pixel_valid}};
always #5 clk=~clk;
UhdRenderer #(.WIDTH(40),.HEIGHT(24)) dut (.clk(clk),.reset(reset),.start(start),.cancel(cancel),
    .center_x(-32'sd12582912),.center_y(32'sd0),.zoom(zoom),.lens(lens),.available(available),.idle(idle),.writes_drained(!pixel_valid),
    .latch(latch),.engine_address(ea),.coordinate_word(coordinates),.sample_step(step),
    .dispatch_slot(dispatch_slot),.pixel_slot(pixel_slot),
    .pixel_valid(pixel_valid),.pixel_offset(offset),.pixel_rgb(rgb),.busy(busy),.done(done),.cancelled(cancelled),.groups_finished(groups),
    .word_request(request),.word_address(address),.word_data(data),.word_accepted(accepted),.word_done(word_done));
always @(posedge clk) begin
    cycle=cycle+1;pixel_valid<=0;accepted<=0;word_done<=0;
    if(latch) begin
        x=pixels%40;y=pixels/40;
        wide_zoom={32'd0,zoom};
        expected_x=-64'sd12582912+(x*wide_zoom/24)-(wide_zoom*20/24);
        expected_y=(wide_zoom/2)-(y*wide_zoom/24);
        factor=256;
        if(lens) begin
            dx=x<20 ? 20-x : x-20;dy=y<12 ? 12-y : y-12;
            radius=dx>dy+dy/4 ? dx : dy+dy/4;
            factor=128+radius*41/4;if(factor>256) factor=256;
            expected_x=-64'sd12582912+(((expected_x+64'sd12582912)*factor)>>>8);
            expected_y=(expected_y*factor)>>>8;
        end
        if($signed(coordinates[63:32])!=expected_x ||
            $signed(coordinates[31:0])!=expected_y || step!=((wide_zoom/24/2)*factor)>>8)
            $fatal(1,"UHD coordinate (%0d,%0d): %0d,%0d expected %0d,%0d, sample=%0d",x,y,$signed(coordinates[63:32]),$signed(coordinates[31:0]),expected_x,expected_y,step);
        if(coordinates[82:73]!=x%1024 || coordinates[72:64]!=y%512 || !available[ea]) $fatal(1,"Tags/worker selection");
        pixel_valid<=1;pixel_slot<=dispatch_slot;offset<=x%8;rgb<={4'(x),4'(y),4'(x^y)};
        pixels=pixels+1;checks=checks+1;
        ahead=pixels-(words/3)*8;if(ahead>max_ahead) max_ahead=ahead;
    end
    if(request && native==0) begin
        for(k=0;k<8;k=k+1) begin
            x=((words/3)*8+k)%40;y=((words/3)*8+k)/40;
            expected_pixels[k*12 +:12]={4'(x),4'(y),4'(x^y)};
        end
        if(address!=24'h100000+words || data!==expected_pixels[(words%3)*32 +:32]) $fatal(1,"Packed 4K word/address %0d",words);
        accepted<=1;native=1;words=words+1;
    end else if(native!=0) begin if(native==9+words%7) begin word_done<=1;native=0;end else native=native+1;end
end
task launch;
    begin pixels=0;words=0;start=1;@(negedge clk);start=0;wait(done);@(negedge clk);end
endtask
initial begin
    repeat(4) @(negedge clk);reset=0;launch();if(pixels!=960 || words!=360 || groups!=120 || max_ahead<=8) $fatal(1,"Raster/queue incomplete");
    lens=1;launch();if(pixels!=960 || words!=360) $fatal(1,"Lens incomplete");
    lens=0;pixels=0;words=0;start=1;@(negedge clk);start=0;wait(pixels>12);@(negedge clk);cancel=1;@(negedge clk);cancel=0;
    wait(done);@(negedge clk);if(!cancelled || busy) $fatal(1,"Cancel did not drain");
    zoom=8192;launch();if(cancelled || pixels!=960) $fatal(1,"Recapture after cancel");
    $display("PASS: %0d UHD dispatches, exact rational projection and sample spacing, all raster/group addresses, packed colors, worker stalls, lens, cancellation and recapture",checks);$finish;
end
initial begin #20000000;$fatal(1,"UHD timeout state=%0d",dut.state);end
endmodule
