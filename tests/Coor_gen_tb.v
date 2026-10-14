`timescale 1ns/1ps
module Coor_gen_tb;
reg clk=0, reset=1, quality_request=0, ack=0;
reg signed [31:0] center_x=1000, center_y=-2000;
reg [2:0] busy=0;
wire latch, active, finished, tile_done, normal_ready;
wire [2:0] tile;
wire [82:0] word;
wire [31:0] sample_step;
integer quality_pixels=0, tile_pixels=0, hold_cycles=0, completed_tiles=0;
reg signed [63:0] expected_x,expected_y;
reg [2:0] previous_tile=0;
always #5 clk=~clk;
Coor_gen #(.SCREEN_WIDTH(8),.SCREEN_HEIGHT(3),.QUALITY_TILE_HEIGHT(4)) dut (
    .cclk(clk),.ckey(4'b1111),.creset(reset),.cdones(7'b1111111),
    .cidle({7{busy==0}}),.clatch_en(latch),.cengine_addr(),.cword2engines(word),.frame(),
    .zoom_level(32'd81920),.center_x(center_x),.center_y(center_y),
    .lens_enable(1'b0),.detail_enable(1'b0),.deep_enable(1'b0),.turbo_enable(1'b0),
    .overrender_enable(quality_request),.palette_select(2'd2),.palette_phase(8'd73),
    .tile_ack(ack),.detail_active(),.deep_active(),.turbo_active(),.overrender_active(active),
    .overrender_done(finished),.tile_done(tile_done),.tile_index(tile),.normal_ready(normal_ready),
    .sample_step(sample_step),.render_palette(),.render_phase()
);
always @(posedge clk) begin
    if(reset) begin busy<=0; ack<=0; end
    else begin
        ack<=0;
        if(latch) busy<=3;
        else if(busy!=0) busy<=busy-1;
        if(latch && active) begin
            if(word[82:73] !== tile_pixels/4 || word[72:64] !== tile_pixels%4)
                $fatal(1,"Tile coordinate sequence failed");
            expected_x=1000+(word[82:73]*81920>>10)-51200+(tile[0]?51200:0);
            expected_y=-2000-(word[72:64]*81920>>10)+38400-tile[2:1]*19200;
            if($signed(word[63:32]) !== expected_x[31:0] || $signed(word[31:0]) !== expected_y[31:0] || sample_step!=40)
                $fatal(1,"Tile projection or frozen view failed");
            quality_pixels=quality_pixels+1; tile_pixels=tile_pixels+1;
        end
        if(tile_done) begin
            if(latch || busy!=0) $fatal(1,"Tile upload started before engines drained");
            hold_cycles=hold_cycles+1;
            if(hold_cycles==8) begin
                if(tile_pixels!=32) $fatal(1,"Incomplete tile");
                completed_tiles=completed_tiles+1; ack<=1;
                tile_pixels=0;
            end
        end else hold_cycles=0;
    end
end
initial begin
    repeat(4) @(negedge clk); reset=0;
    repeat(12) @(negedge clk); quality_request=1;
    wait(active); repeat(10) @(negedge clk);
    center_x=12345; center_y=54321; // Must not alter later tiles of this render.
    wait(finished); repeat(50) @(negedge clk);
    if(quality_pixels!=256 || completed_tiles!=8 || latch) $fatal(1,"One-shot completion failed");
    quality_request=0; wait(!active); wait(normal_ready);
    $display("PASS: eight-tile projection, frozen view, engine drain, upload acknowledgement, one-shot hold, and navigation return");
    $finish;
end
initial begin #200000; $fatal(1,"Coordinate coordinator timeout"); end
endmodule
