// Standard top-down, uncompressed 24-bit BMP. Cache sixteen pixel groups per
// read, plus one discarded guard word. Useful RGB never occupies a burst tail.
// Pixels pass through the same effects as VGA, at a held snapshot phase.
module BmpStream #(
    parameter PREVIEW_WIDTH=640,PREVIEW_HEIGHT=480,HD_WIDTH=1280,HD_HEIGHT=1024,
    UHD_WIDTH=3840,UHD_HEIGHT=2160,UHD_BASE=24'h100000,SMOOTH_VIVID=0
) (
    input clk,reset,start,abort,input [1:0] mode,input [3:0] scheme,input [3:0] color_offset,
    input [7:0] effects,input [56:0] phases,
    output reg busy,done,output byte_valid,output [7:0] byte_data,input byte_ready,
    output word_request,output [23:0] word_address,output [7:0] word_length,
    input word_accepted,word_done,word_valid,input [31:0] word_q,
    output preview_request,output [17:0] preview_address,
    input preview_accepted,input [15:0] preview_q
);
localparam IDLE=0,HEADER=1,GROUP_REQUEST=2,GROUP_WAIT=3,PREVIEW_REQUEST=4,
    PREVIEW_WAIT=5,FEED=6,PIPELINE=7,BLUE=8,GREEN=9,RED=10,ROW_GAP=11,PADDING=12,PREVIEW_COLOR=13,CACHE_LOAD=14;
reg [3:0] state;
reg [1:0] saved_mode;
reg [5:0] header_index;
reg [11:0] x,y,width,height;
reg [31:0] byte_count,image_size;
reg [23:0] group_address;
reg [95:0] packed_pixels;
reg [5:0] received;
reg [4:0] cache_groups;
reg [3:0] cache_index,fill_index;
reg [1:0] fill_lane;
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] cache0[0:15],cache1[0:15],cache2[0:15];
wire [8:0] remaining_groups=(width-x)>>3;
wire [4:0] requested_groups=remaining_groups>16 ? 5'd16 : remaining_groups[4:0];
wire [5:0] cache_words=({1'b0,cache_groups}<<1)+cache_groups;
reg [11:0] raw_rgb;
reg [3:0] wait_cycles;
reg [4:0] gap;
reg [23:0] output_rgb;
wire [31:0] header_height=-{20'd0,height};
wire [31:0] total_size=image_size+54;
wire [31:0] header_width={20'd0,width};
wire [7:0] header_byte=header_index==0 ? 8'h42 : header_index==1 ? 8'h4d :
    header_index>=2 && header_index<=5 ? total_size>>((header_index-2)*8) :
    header_index==10 ? 8'd54 : header_index==14 ? 8'd40 :
    header_index>=18 && header_index<=21 ? header_width>>((header_index-18)*8) :
    header_index>=22 && header_index<=25 ? header_height>>((header_index-22)*8) :
    header_index==26 ? 8'd1 : header_index==28 ? 8'd24 :
    header_index>=34 && header_index<=37 ? image_size>>((header_index-34)*8) : 8'd0;
assign byte_valid=state==HEADER || state==BLUE || state==GREEN || state==RED || state==PADDING;
assign byte_data=state==HEADER ? header_byte : state==BLUE ? output_rgb[7:0] :
    state==GREEN ? output_rgb[15:8] : state==RED ? output_rgb[23:16] : 8'd0;
assign word_request=state==GROUP_REQUEST;
assign word_address=group_address;
// Native length counts words minus one: data words plus the guard word.
assign word_length=({3'd0,requested_groups}<<1)+requested_groups;
assign preview_request=state==PREVIEW_REQUEST;
assign preview_address=({9'd0,y}<<8)+({9'd0,y}<<6)+(x>>1);
reg [7:0] preview_index;
wire [23:0] preview_bgr;
ColorMapper preview_colors (.index(preview_index),.palette(2'd0),.phase(8'd0),.bgr(preview_bgr));
wire active=state!=IDLE && state!=HEADER && state!=ROW_GAP && state!=PADDING;
wire [3:0] r,g,b;
wire [7:0] r8,g8,b8;
HDColorEffects #(.EXTERNAL_PHASES(1),.X_BITS(12),.Y_BITS(12),.SMOOTH_VIVID(SMOOTH_VIVID)) shader (
    .clk(clk),.reset(reset),.enabled(busy),.frame_tick(1'b0),
    .input_red(raw_rgb[11:8]),.input_green(raw_rgb[7:4]),.input_blue(raw_rgb[3:0]),
    .input_hsync(1'b1),.input_vsync(1'b1),.color_scheme(scheme),.color_offset(color_offset),
    .burn_speed(2'd0),.burn_enable(effects[0]),.stochastic_burn(effects[1]),
    .morph(effects[3]),.prism(effects[2]),.glow(effects[4]),.pixel_tick(state==FEED),
    .vivid(effects[7]),.fuzz(effects[5]),.pixel_active(active),.pixel_x(x),.pixel_y(y),
    .phase_values(phases),.phase_state(),.red(r),.green(g),.blue(b),.red8(r8),.green8(g8),.blue8(b8),.hsync(),.vsync(),.selected());
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=IDLE;busy<=0;done<=0;saved_mode<=0;header_index<=0;x<=0;y<=0;width<=0;height<=0;
        byte_count<=0;image_size<=0;group_address<=0;packed_pixels<=0;received<=0;raw_rgb<=0;wait_cycles<=0;gap<=0;output_rgb<=0;preview_index<=0;
        cache_groups<=0;cache_index<=0;fill_index<=0;fill_lane<=0;
    end else begin
        done<=0;
        if(word_valid && state==GROUP_WAIT) begin
            received<=received+1'b1;
            if(received<cache_words) begin
                case(fill_lane)
                    0: cache0[fill_index]<=word_q;
                    1: cache1[fill_index]<=word_q;
                    2: cache2[fill_index]<=word_q;
                endcase
                if(fill_lane==2) begin fill_lane<=0;fill_index<=fill_index+1'b1;end
                else fill_lane<=fill_lane+1'b1;
            end
        end
        if(abort) begin state<=IDLE;busy<=0;end else case(state)
            IDLE,PADDING: if(start) begin
                busy<=1;saved_mode<=mode;x<=0;y<=0;header_index<=0;byte_count<=0;received<=0;cache_index<=0;
                width<=mode==0 ? PREVIEW_WIDTH : mode==1 ? HD_WIDTH : UHD_WIDTH;
                height<=mode==0 ? PREVIEW_HEIGHT : mode==1 ? HD_HEIGHT : UHD_HEIGHT;
                image_size<=mode==0 ? PREVIEW_WIDTH*PREVIEW_HEIGHT*3 : mode==1 ? HD_WIDTH*HD_HEIGHT*3 : UHD_WIDTH*UHD_HEIGHT*3;
                group_address<=mode==2 ? UHD_BASE : 0;state<=HEADER;
            end
            HEADER: if(byte_ready) begin
                byte_count<=byte_count+1'b1;
                if(header_index==53) state<=saved_mode==0 ? PREVIEW_REQUEST : GROUP_REQUEST;
                else header_index<=header_index+1'b1;
            end
            GROUP_REQUEST: if(word_accepted) begin
                received<=0;cache_groups<=requested_groups;cache_index<=0;fill_index<=0;fill_lane<=0;state<=GROUP_WAIT;
            end
            GROUP_WAIT: if(word_done && received==cache_words+1'b1) state<=CACHE_LOAD;
            CACHE_LOAD: begin
                packed_pixels<={cache2[cache_index],cache1[cache_index],cache0[cache_index]};
                raw_rgb<=cache0[cache_index][11:0];state<=FEED;
            end
            PREVIEW_REQUEST: if(preview_accepted) state<=PREVIEW_WAIT;
            // Separate the large preview RAM output mux from color mapping.
            PREVIEW_WAIT: begin preview_index<=x[0] ? preview_q[15:8] : preview_q[7:0];state<=PREVIEW_COLOR;end
            PREVIEW_COLOR: begin raw_rgb<={preview_bgr[7:4],preview_bgr[15:12],preview_bgr[23:20]};state<=FEED;end
            FEED: begin wait_cycles<=0;state<=PIPELINE;end
            PIPELINE: if(wait_cycles==12) begin output_rgb<={r8,g8,b8};state<=BLUE;end else wait_cycles<=wait_cycles+1'b1;
            BLUE: if(byte_ready) begin byte_count<=byte_count+1'b1;state<=GREEN;end
            GREEN: if(byte_ready) begin byte_count<=byte_count+1'b1;state<=RED;end
            RED: if(byte_ready) begin
                byte_count<=byte_count+1'b1;
                if(x==width-1) begin
                    if(y==height-1) begin busy<=0;done<=1;state<=PADDING;end
                    else begin x<=0;y<=y+1'b1;gap<=0;group_address<=group_address+3;cache_index<=0;state<=ROW_GAP;end
                end else begin
                    x<=x+1'b1;
                    if(saved_mode==0) state<=PREVIEW_REQUEST;
                    else if(x[2:0]==7) begin
                        group_address<=group_address+3;
                        if({1'b0,cache_index}+1'b1<cache_groups) begin cache_index<=cache_index+1'b1;state<=CACHE_LOAD;end
                        else begin cache_index<=0;state<=GROUP_REQUEST;end
                    end
                    else begin packed_pixels<=packed_pixels>>12;raw_rgb<=packed_pixels[23:12];state<=FEED;end
                end
            end
            ROW_GAP: if(gap==19) state<=saved_mode==0 ? PREVIEW_REQUEST : GROUP_REQUEST;else gap<=gap+1'b1;
            default:state<=IDLE;
        endcase
    end
end
endmodule
