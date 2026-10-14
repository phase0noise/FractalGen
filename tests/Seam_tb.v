`timescale 1ns/1ps
// Full-size geometry with a fractional zoom. Every coordinate must match a
// single global projection; workers keep their free slots until dispatch.
module Seam_tb;
parameter PROGRESSIVE=0;
parameter LENS=0;
parameter COLUMNS=2, TILE_WIDTH=640, TILE_HEIGHT=240, IMAGE_HEIGHT=960, TRIM=0, INITIAL_LEVEL=0;
reg clk=0,reset=1,quality=0,ack=0;
always #5 clk=~clk;
reg [6:0] free=7'b1111111;
integer remaining[0:6];
wire latch,active,finished,tile_done;
wire [2:0] tile,address;
wire [82:0] word;
wire [7:0] global_group;
wire [9:0] global_row;
integer i,x,y,gx,gy,source_x,source_y,count=0,tile_pixels=0,holds=0;
integer dx,dy,radius,factor;
reg signed [63:0] zoom=8525,wanted_x,wanted_y;
Coor_gen #(.SCREEN_HEIGHT(1),.PROGRESSIVE(PROGRESSIVE), .QUALITY_TILE_WIDTH(TILE_WIDTH),
    .QUALITY_TILE_HEIGHT(TILE_HEIGHT),.QUALITY_COLUMNS(COLUMNS),.QUALITY_PROJECTION_HEIGHT(IMAGE_HEIGHT),
    .QUALITY_INITIAL_LEVEL(INITIAL_LEVEL),.TRIM_QUALITY_EDGES(TRIM)) dut (
    .cclk(clk),.ckey(4'b1111),.creset(reset),.cdones(free),.cidle(free),
    .clatch_en(latch),.cengine_addr(address),.cword2engines(word),.frame(),
    .zoom_level(32'd8525),.center_x(-32'sd12582912),.center_y(32'sd2211681),
    .lens_enable(1'(LENS)),.detail_enable(1'b0),.deep_enable(1'b0),.turbo_enable(1'b0),
    .overrender_enable(quality),.palette_select(2'd0),.palette_phase(8'd0),.tile_ack(ack),
    .refine_enable(1'b0),
    .detail_active(),.deep_active(),.turbo_active(),.overrender_active(active),
    .overrender_done(finished),.tile_done(tile_done),.tile_index(tile),.normal_ready(),
    .sample_step(),.render_palette(),.render_phase(),.group_x(global_group),.group_y(global_row)
);
always @(posedge clk) begin
    ack<=0;
    if(reset) begin
        free<=7'b1111111;
        for(i=0;i<7;i=i+1) remaining[i]=0;
    end else begin
        for(i=0;i<7;i=i+1) if(remaining[i]>0) begin
            remaining[i]=remaining[i]-1;
            if(remaining[i]==0) free[i]<=1;
        end
        if(latch) begin
            if(!free[address]) $fatal(1,"Dispatched to a busy worker");
            free[address]<=0; remaining[address]=3+address;
            if(active) begin
                x=word[82:73]; y=word[72:64];
                if(!PROGRESSIVE && (x!=tile_pixels/TILE_HEIGHT || y!=tile_pixels%TILE_HEIGHT)) $fatal(1,"Skipped/repeated tile pixel");
                gx=x+(tile%COLUMNS)*TILE_WIDTH; gy=y+(tile/COLUMNS)*TILE_HEIGHT;
                if(PROGRESSIVE) begin
                    gx=global_group*8+(x%8); gy=global_row;
                    if(tile!=0 || x!=(gx%1024) || y!=(gy%512)) $fatal(1,"Global raster tag/metadata mismatch");
                end
                if(PROGRESSIVE && (gx!=count%1280 || gy!=count/1280))
                    $fatal(1,"Raster skipped/repeated pixel %0d at (%0d,%0d)",count,gx,gy);
                source_x=gx; source_y=gy;
                if(TRIM && !PROGRESSIVE && x==0 && tile%COLUMNS!=0) source_x=gx+1;
                if(TRIM && !PROGRESSIVE && x==TILE_WIDTH-1 && tile%COLUMNS!=COLUMNS-1) source_x=gx-1;
                if(TRIM && !PROGRESSIVE && y==0 && tile/COLUMNS!=0) source_y=gy+1;
                if(TRIM && !PROGRESSIVE && y==TILE_HEIGHT-1 && tile/COLUMNS!=8/COLUMNS-1) source_y=gy-1;
                wanted_x=-12582912+((source_x*zoom)>>>10)-((320*zoom)>>>9);
                wanted_y=2211681-((source_y*zoom)>>>10)+(((IMAGE_HEIGHT/2)*zoom)>>>10);
                if(dut.iteration_level!==2'(INITIAL_LEVEL)) $fatal(1,"Wrong initial quality budget");
                if(LENS) begin
                    dx=(gx/2)-320; if(dx<0) dx=-dx;
                    dy=(gy/2)-IMAGE_HEIGHT/4; if(dy<0) dy=-dy;
                    dy=dy+(dy>>2)+(IMAGE_HEIGHT==1024?0:((dy>>4)+(dy>>6)));
                    radius=dx>dy?dx:dy; factor=128+((radius*205)>>9); if(factor>256) factor=256;
                    wanted_x=-12582912+(((wanted_x+12582912)*factor)>>>8);
                    wanted_y=2211681+(((wanted_y-2211681)*factor)>>>8);
                end
                if($signed(word[63:32])!==wanted_x[31:0] || $signed(word[31:0])!==wanted_y[31:0])
                    $fatal(1,"Projection seam at global pixel (%0d,%0d), tile %0d",gx,gy,tile);
                count=count+1; tile_pixels=tile_pixels+1;
            end
        end
        if(tile_done) begin
            holds=holds+1;
            if(holds==4) begin
                if(tile_pixels!=(PROGRESSIVE?8:TILE_WIDTH*TILE_HEIGHT) || free!=7'b1111111) $fatal(1,"Incomplete pixels acknowledged");
                ack<=1; tile_pixels=0;
            end
        end else holds=0;
    end
end
initial begin
    repeat(4) @(negedge clk); reset=0;
    repeat(8) @(negedge clk); quality=1;
    wait(finished);
    if(count!=1280*IMAGE_HEIGHT) $fatal(1,"Incomplete global coordinate grid");
    $display("PASS: all %0d fractional-zoom coordinates and section edges (progressive=%0d lens=%0d trim=%0d level=%0d)",count,PROGRESSIVE,LENS,TRIM,INITIAL_LEVEL);
    $finish;
end
initial begin #150000000; $fatal(1,"Seam test timeout"); end
endmodule
