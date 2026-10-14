`timescale 1ns/1ps
// Verify sparse persistent color steps and changing update order, rather
// than per-frame flashing noise. Every eight rounds all pixels advance once.
module StochasticBurn_tb;
localparam PIXELS=2048;
reg clk=0,reset=1,enabled=1,tick=0,stochastic=1,active=0,burn=1;
reg [1:0] speed=2;
reg [10:0] x=0;
reg [9:0] y=0;
reg [11:0] rgb=0;
wire [3:0] r,g,b;
reg [11:0] previous[0:PIXELS-1],current[0:PIXELS-1];
reg first_mask[0:PIXELS-1];
integer tags[0:12];
integer sample=-1,received=0,i,j,round_number,changed,different=0;
HDColorEffects dut (.clk(clk),.reset(reset),.enabled(enabled),.frame_tick(tick),
    .input_red(rgb[11:8]),.input_green(rgb[7:4]),.input_blue(rgb[3:0]),
    .input_hsync(1'b0),.input_vsync(1'b0),.color_scheme(4'd2),.color_offset(4'd0),.burn_speed(speed),.burn_enable(burn),
    .stochastic_burn(stochastic),.morph(1'b0),.prism(1'b0),.glow(1'b0),.pixel_tick(1'b1),
    .vivid(1'b0),.fuzz(1'b0),.pixel_active(active),.pixel_x(x),.pixel_y(y),
    .red(r),.green(g),.blue(b),.hsync(),.vsync(),.selected());
always #5 clk=~clk;
always @(posedge clk) begin
    for(j=12;j>0;j=j-1) tags[j]=tags[j-1]; tags[0]=reset?-1:sample;
    #1;
    if(tags[12]>=0) begin current[tags[12]]={r,g,b}; received=received+1; end
end
task frame_tick;
    begin tick=1; @(negedge clk); tick=0; repeat(16) @(negedge clk); end
endtask
task scan;
    begin
        received=0;
        for(i=0;i<PIXELS;i=i+1) begin
            sample=i; x=11'(i%64); y=10'(i/64); active=1; rgb=12'h693;
            @(negedge clk);
        end
        sample=-1; active=0; rgb=0; repeat(16) @(negedge clk);
        if(received!=PIXELS) $fatal(1,"Incomplete stochastic image");
    end
endtask
task remember;
    begin for(i=0;i<PIXELS;i=i+1) previous[i]=current[i]; end
endtask
initial begin
    for(i=0;i<13;i=i+1) tags[i]=-1;
    repeat(4) @(negedge clk); reset=0; repeat(20) @(negedge clk);
    scan();
    for(i=0;i<PIXELS;i=i+1) if(current[i]!==12'h5f0) $fatal(1,"Stochastic burn changed pixels before its first round");
    remember();
    for(round_number=1;round_number<=16;round_number=round_number+1) begin
        frame_tick(); scan(); changed=0;
        for(i=0;i<PIXELS;i=i+1) begin
            if(current[i]!=previous[i]) begin
                changed=changed+1;
                if((round_number<=8 && (previous[i]!==12'h5f0 || current[i]!==12'h0f3)) ||
                   (round_number>8 && (previous[i]!==12'h0f3 || current[i]!==12'h0f9)))
                    $fatal(1,"Pixel reverted or skipped a color step in round %0d",round_number);
            end
            if(round_number==1) first_mask[i]=current[i]!=previous[i];
            if(round_number==9 && first_mask[i]!=(current[i]!=previous[i])) different=different+1;
        end
        if(changed<160 || changed>350) $fatal(1,"Round %0d changed %0d pixels; expected a sparse subset",round_number,changed);
        if(round_number==8 || round_number==16)
            for(i=0;i<PIXELS;i=i+1) if(current[i] !== (round_number==8?12'h0f3:12'h0f9))
                $fatal(1,"An eight-round epoch failed to advance every pixel once");
        remember();
    end
    if(different<250) $fatal(1,"The next epoch reused the same update order");
    speed=0; repeat(20) @(negedge clk);
    repeat(16) frame_tick(); scan();
    for(i=0;i<PIXELS;i=i+1) if(current[i]!==previous[i]) $fatal(1,"Still speed did not hold stochastic colors");
    speed=1; repeat(20) @(negedge clk);
    repeat(15) frame_tick(); scan();
    for(i=0;i<PIXELS;i=i+1) if(current[i]!==previous[i]) $fatal(1,"Slow burn advanced early");
    frame_tick(); scan(); changed=0;
    for(i=0;i<PIXELS;i=i+1) if(current[i]!=previous[i]) changed=changed+1;
    if(changed<160 || changed>350) $fatal(1,"Slow burn did not advance a sparse subset");
    stochastic=0; repeat(20) @(negedge clk); scan();
    // Slow now interpolates the common global phase with at most one DAC
    // step of uniform rounding. Leaving stochastic style must restore it.
    for(i=0;i<PIXELS;i=i+1) if(current[i]!==12'h07f && current[i]!==12'h08f)
        $fatal(1,"Disabling stochastic burn did not restore the smooth global palette phase");
    burn=0; stochastic=1; speed=3; repeat(20) @(negedge clk);
    repeat(16) frame_tick(); scan();
    for(i=0;i<PIXELS;i=i+1) if(current[i]!==12'h5f0) $fatal(1,"Burn off did not override stochastic burn at Wild speed");
    if({r,g,b}!==0) $fatal(1,"Stochastic burn colored blanking pixels");
    $display("PASS: stochastic subsets hold their color steps, all 2048 pixels advance per epoch, new masks, Still/Slow/Fast and clean disable");
    $finish;
end
initial begin #2000000; $fatal(1,"Stochastic burn timeout"); end
endmodule
