`timescale 1ns/1ps
`include "mandel_constants.vh"
// Probe the actual 3840x2160 counter/tag wraps and the final SDRAM words
// without simulating eight million identical interface transactions.
module UhdBoundary_tb;
reg clk=0,reset=1,start=0,cancel=0;
always #5 clk=~clk;
wire busy,done,cancelled,latch,request;
wire [82:0] coordinates;
wire [31:0] step,data;
wire [23:0] address;
wire [19:0] groups;
reg valid=0,accepted=0,word_done=0;
reg [2:0] lane=0;
reg [11:0] rgb=0;
wire [1:0] dispatch_slot;reg [1:0] pixel_slot=0;
wire [6:0] available=pixels>=expected_count ? 7'd0 : 7'h7f;
reg [95:0] expected_group;
integer seed_x,seed_y,expected_count,pixels,words,x,y,k,native=0,checks=0;
reg signed [63:0] zoom=46976205,expected_x,expected_y;
integer first_word;
reg [23:0] last_address;
UhdRenderer dut (.clk(clk),.reset(reset),.start(start),.cancel(cancel),.center_x(-32'sd12582912),.center_y(32'sd0),
    .zoom(32'd46976205),.lens(1'b0),.available(available),.idle({7{!valid}}),.writes_drained(!valid),
    .dispatch_slot(dispatch_slot),.pixel_slot(pixel_slot),
    .latch(latch),.engine_address(),.coordinate_word(coordinates),.sample_step(step),.pixel_valid(valid),.pixel_offset(lane),.pixel_rgb(rgb),
    .busy(busy),.done(done),.cancelled(cancelled),.groups_finished(groups),.word_request(request),.word_address(address),.word_data(data),
    .word_accepted(accepted),.word_done(word_done));
always @(posedge clk) begin
    valid<=0;accepted<=0;word_done<=0;
    if(latch) begin
        x=(seed_y*3840+seed_x+pixels)%3840;y=(seed_y*3840+seed_x+pixels)/3840;
        expected_x=-64'sd12582912-zoom*1920/2160+x*zoom/2160;
        expected_y=zoom/2-y*zoom/2160;
        if(pixels>=expected_count || $signed(coordinates[63:32])!=expected_x || $signed(coordinates[31:0])!=expected_y ||
            coordinates[82:73]!=x%1024 || coordinates[72:64]!=y%512 || step!=zoom/2160/2)
            $fatal(1,"Full UHD coordinate/tag boundary (%0d,%0d)",x,y);
        valid<=1;pixel_slot<=dispatch_slot;lane<=x%8;rgb<={4'(x),4'(y),4'(x^y)};
        pixels=pixels+1;checks=checks+1;
    end
    if(request && native==0) begin
        for(k=0;k<8;k=k+1) begin
            x=(seed_y*3840+seed_x+(words/3)*8+k)%3840;y=(seed_y*3840+seed_x+(words/3)*8+k)/3840;
            expected_group[k*12 +:12]={4'(x),4'(y),4'(x^y)};
        end
        if(address!=first_word+words || data!==expected_group[(words%3)*32 +:32] || address>=24'h3f7600)
            $fatal(1,"Full UHD memory boundary address=%h expected=%h",address,first_word+words);
        last_address=address;words=words+1;accepted<=1;native=1;
    end else if(native!=0) begin if(native==11) begin word_done<=1;native=0;end else native=native+1;end
end
task probe;
    input integer sx,sy,count;
    begin
        seed_x=sx;seed_y=sy;expected_count=count;pixels=0;words=0;start=1;
        @(negedge clk);start=0;wait(dut.state==dut.PREPARE);@(negedge clk);
        if($signed(dut.origin_x)!=-64'sd12582912-zoom*1920/2160 || dut.step!=zoom/2160) $fatal(1,"Full UHD divider setup");
        first_word=24'h100000+((sy*3840+sx)/8)*3;
        dut.x=sx;dut.y=sy;dut.current_x=-64'sd12582912-zoom*1920/2160+sx*zoom/2160;
        dut.current_y=zoom/2-sy*zoom/2160;dut.x_error=(sx*zoom)%2160;dut.y_error=(sy*zoom)%2160;
        dut.group_base=first_word;dut.groups_finished=(sy*3840+sx)/8;
        wait(words==count/8*3);wait(word_done);@(negedge clk);
        if(sy==2159) begin
            wait(done);@(negedge clk);
            if(cancelled || groups!=1036800 || last_address!=24'h3f75ff) $fatal(1,"Last UHD word/raster count: groups=%0d last=%h",groups,last_address);
        end else begin cancel=1;@(negedge clk);cancel=0;wait(done);@(negedge clk);end
    end
endtask
initial begin
    repeat(4) @(negedge clk);reset=0;
    probe(1016,511,16);probe(2040,1023,16);probe(3832,1023,16);probe(3832,2047,16);probe(3832,2159,8);
    $display("PASS: %0d full-4K boundary pixels, rational projection, 10/9-bit worker tag wraps, row carry, 1036800 packed groups and final word 0x3f75ff below 64 MB",checks);$finish;
end
initial begin #1000000;$fatal(1,"UHD boundary timeout state=%0d pixels=%0d words=%0d",dut.state,pixels,words);end
endmodule
