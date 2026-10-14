`include "mandel_constants.vh"
// Independent 3840x2160 raster; borrows the existing orbit workers. The VGA
// image stays in its original SDRAM region. Eight RGB444 pixels use 3 words.
module UhdRenderer #(parameter WIDTH=3840, HEIGHT=2160, BASE_WORD=24'h100000) (
    input clk,reset,start,cancel,input signed [31:0] center_x,center_y,
    input [31:0] zoom,input lens,
    input [`NUM_PROC-1:0] available,idle,input writes_drained,
    output latch,output reg [`E_ADDR_WIDTH-1:0] engine_address,
    output reg [82:0] coordinate_word,output reg [31:0] sample_step,
    output [1:0] dispatch_slot,input [1:0] pixel_slot,
    input pixel_valid,input [2:0] pixel_offset,input [11:0] pixel_rgb,
    output reg busy,done,cancelled,output reg [19:0] groups_finished,
    output word_request,output [23:0] word_address,output [31:0] word_data,
    input word_accepted,word_done
);
localparam IDLE=0,STEP_BEGIN=1,STEP_WAIT=2,OFFSET_BEGIN=3,OFFSET_WAIT=4,
    PREPARE=5,LENS_WAIT=6,LENS_LOW=7,LENS_HIGH=8,LENS_SUM=9,DISPATCH=10,
    DRAIN=11,WRITE_REQUEST=12,WRITE_WAIT=13,ABORT=14,FINISH=15,LENS_RADIUS=16;
reg [4:0] state;
reg [11:0] x,y;
reg [31:0] saved_zoom,step;
reg signed [31:0] saved_x,saved_y,origin_x,current_x,current_y;
reg saved_lens;
reg [12:0] step_remainder,x_error,y_error;
wire [13:0] next_x_error={1'b0,x_error}+{1'b0,step_remainder};
wire [13:0] next_y_error={1'b0,y_error}+{1'b0,step_remainder};
reg divide_start;
reg [43:0] divide_numerator;
reg [12:0] divide_denominator;
wire divide_busy,divide_done;
wire [43:0] quotient;
wire [12:0] remainder;
UnsignedDivide divider (.clk(clk),.reset(reset),.start(divide_start),.numerator(divide_numerator),
    .denominator(divide_denominator),.busy(divide_busy),.done(divide_done),.quotient(quotient),.remainder(remainder));
wire queue_ready,queue_empty,group_valid;
wire [95:0] group_pixels;
wire [23:0] completed_base;
reg group_ack;
reg [95:0] upload_pixels;
reg [23:0] upload_base;
localparam W_IDLE=0,W_REQUEST=1,W_WAIT=2,W_RELEASE=3;
reg [1:0] write_state;
reg [1:0] write_index;
reg [23:0] group_base;
RenderQueue queue (.clk(clk),.reset(reset),.active(busy && !cancelled && !cancel),
    .dispatch(latch),.dispatch_lane(x[2:0]),.dispatch_base(group_base),
    .dispatch_ready(queue_ready),.dispatch_slot(dispatch_slot),
    .pixel_valid(pixel_valid),.pixel_slot(pixel_slot),.pixel_lane(pixel_offset),.pixel_rgb(pixel_rgb),
    .group_valid(group_valid),.group_base(completed_base),.group_pixels(group_pixels),
    .group_ack(group_ack),.empty(queue_empty),.allocated_groups(),.retired_groups());
wire [12:0] dx=x<WIDTH/2 ? WIDTH/2-x : x-WIDTH/2;
wire [12:0] dy=y<HEIGHT/2 ? HEIGHT/2-y : y-HEIGHT/2;
wire [13:0] scaled_y={1'b0,dy}+({1'b0,dy}>>2);
wire [13:0] radius=dx>scaled_y ? {1'b0,dx} : scaled_y;
reg [13:0] lens_radius;
reg [8:0] factor;
reg signed [32:0] relative_x,relative_y,relative_step;
reg signed [42:0] low_x,low_y,low_step,high_x,high_y,high_step;
wire signed [42:0] summed_x=low_x+(high_x<<<4),summed_y=low_y+(high_y<<<4),summed_step=low_step+(high_step<<<4);
wire signed [31:0] lens_output_x=saved_x+(summed_x>>>8),lens_output_y=saved_y+(summed_y>>>8);
function [43:0] offset_product;
    input [31:0] value;reg [43:0] p[0:11];integer b;
    begin for(b=0;b<12;b=b+1) p[b]=((WIDTH/2)>>b)&1 ? {12'd0,value}<<b : 44'd0;
        offset_product=((p[0]+p[1])+(p[2]+p[3]))+((p[4]+p[5])+(p[6]+p[7]))+((p[8]+p[9])+(p[10]+p[11]));end
endfunction
function signed [42:0] partial;
    input signed [32:0] value;input [4:0] amount;
    reg signed [42:0] wide;reg signed [42:0] p[0:4];integer b;
    begin wide={{10{value[32]}},value};for(b=0;b<5;b=b+1) p[b]=amount[b] ? wide<<<b : 43'sd0;
        partial=(p[0]+p[1])+(p[2]+p[3])+p[4];end
endfunction
assign latch=state==DISPATCH && available[engine_address] && queue_ready && !cancelled && !cancel;
assign word_request=write_state==W_REQUEST && !cancelled && !cancel;
assign word_address=upload_base+write_index;
assign word_data=write_index==0 ? upload_pixels[31:0] : write_index==1 ? upload_pixels[63:32] : upload_pixels[95:64];
// The upload runs independently of coordinate dispatch and orbit work.
always @(posedge clk or posedge reset) begin
    if(reset) begin write_state<=W_IDLE;write_index<=0;group_ack<=0;upload_base<=0;upload_pixels<=0;groups_finished<=0;end
    else begin
        group_ack<=0;
        if(start && !busy) groups_finished<=0;
        case(write_state)
            W_IDLE: if(group_valid && !cancelled && !cancel) begin
                upload_pixels<=group_pixels;upload_base<=completed_base;write_index<=0;write_state<=W_REQUEST;
            end
            W_REQUEST: if(word_accepted) write_state<=W_WAIT;
                else if(cancelled || cancel || !busy) write_state<=W_IDLE;
            W_WAIT: if(word_done) begin
                if(cancelled || cancel) write_state<=W_RELEASE;
                else if(write_index==2) begin
                    group_ack<=1;groups_finished<=groups_finished+1'b1;write_state<=W_RELEASE;
                end else begin write_index<=write_index+1'b1;write_state<=W_REQUEST;end
            end
            W_RELEASE: write_state<=W_IDLE;
        endcase
    end
end
integer j;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        state<=IDLE;busy<=0;done<=0;cancelled<=0;
        x<=0;y<=0;saved_zoom<=0;step<=0;saved_x<=0;saved_y<=0;origin_x<=0;current_x<=0;current_y<=0;saved_lens<=0;
        step_remainder<=0;x_error<=0;y_error<=0;divide_start<=0;divide_numerator<=0;divide_denominator<=1;
        group_base<=BASE_WORD;
        engine_address<=0;coordinate_word<=0;sample_step<=0;factor<=0;lens_radius<=0;relative_x<=0;relative_y<=0;relative_step<=0;
        low_x<=0;low_y<=0;low_step<=0;high_x<=0;high_y<=0;high_step<=0;
    end else begin
        done<=0;divide_start<=0;
        engine_address<=0;for(j=`NUM_PROC-1;j>=0;j=j-1) if(available[j]) engine_address<=j;
        if(busy && cancel) cancelled<=1;
        if(cancelled && state!=WRITE_WAIT && state!=WRITE_REQUEST && state!=IDLE && state!=ABORT && state!=FINISH) state<=ABORT;
        else case(state)
            IDLE: if(start) begin
                busy<=1;cancelled<=0;group_base<=BASE_WORD;
                saved_zoom<=zoom;saved_x<=center_x;saved_y<=center_y;saved_lens<=lens;
                x<=0;y<=0;x_error<=0;y_error<=0;state<=STEP_BEGIN;
            end
            STEP_BEGIN: begin divide_numerator<={12'd0,saved_zoom};divide_denominator<=HEIGHT;divide_start<=1;state<=STEP_WAIT;end
            STEP_WAIT: if(divide_done) begin step<=quotient[31:0];step_remainder<=remainder;state<=OFFSET_BEGIN;end
            OFFSET_BEGIN: begin divide_numerator<=offset_product(saved_zoom);divide_denominator<=HEIGHT;divide_start<=1;state<=OFFSET_WAIT;end
            OFFSET_WAIT: if(divide_done) begin
                origin_x<=saved_x-$signed(quotient[31:0]);current_x<=saved_x-$signed(quotient[31:0]);
                current_y<=saved_y+$signed(saved_zoom>>1);state<=PREPARE;
            end
            PREPARE: if(saved_lens) begin
                relative_x<={current_x[31],current_x}-{saved_x[31],saved_x};
                relative_y<={current_y[31],current_y}-{saved_y[31],saved_y};relative_step<={1'b0,step>>1};
                // Separate the distance/maximum calculation from its scale
                // product; neither path should cross both carry chains.
                lens_radius<=radius;state<=LENS_RADIUS;
                end else begin coordinate_word<={x[9:0],y[8:0],current_x,current_y};sample_step<=step>>1;state<=DISPATCH;end
            LENS_RADIUS: begin
                divide_numerator<=({30'd0,lens_radius}<<5)+({30'd0,lens_radius}<<3)+lens_radius;
                divide_denominator<=HEIGHT>=5 ? HEIGHT/5 : 1;divide_start<=1;state<=LENS_WAIT;
            end
            LENS_WAIT: if(divide_done) begin factor<=quotient>=128 ? 9'd256 : 9'd128+quotient[7:0];state<=LENS_LOW;end
            LENS_LOW: begin low_x<=partial(relative_x,{1'b0,factor[3:0]});low_y<=partial(relative_y,{1'b0,factor[3:0]});
                low_step<=partial(relative_step,{1'b0,factor[3:0]});state<=LENS_HIGH;end
            LENS_HIGH: begin high_x<=partial(relative_x,factor[8:4]);high_y<=partial(relative_y,factor[8:4]);
                high_step<=partial(relative_step,factor[8:4]);state<=LENS_SUM;end
            LENS_SUM: begin coordinate_word<={x[9:0],y[8:0],lens_output_x,lens_output_y};
                sample_step<=summed_step>>>8;state<=DISPATCH;end
            DISPATCH: if(latch) begin
                if(x[2:0]==7) group_base<=group_base+3;
                if(x==WIDTH-1 && y==HEIGHT-1) state<=DRAIN;
                else begin
                    if(x==WIDTH-1) begin x<=0;y<=y+1'b1;current_x<=origin_x;x_error<=0;
                        current_y<=current_y-$signed(step)-(next_y_error>=HEIGHT ? 1 : 0);
                        y_error<=next_y_error>=HEIGHT ? next_y_error-HEIGHT : next_y_error;
                    end else begin x<=x+1'b1;current_x<=current_x+$signed(step)+(next_x_error>=HEIGHT ? 1 : 0);
                        x_error<=next_x_error>=HEIGHT ? next_x_error-HEIGHT : next_x_error;end
                    state<=PREPARE;
                end
            end
            DRAIN: if(&idle && writes_drained && queue_empty && write_state==W_IDLE) state<=FINISH;
            ABORT: if(&idle && writes_drained && write_state==W_IDLE) begin busy<=0;done<=1;state<=IDLE;end
            FINISH: begin busy<=0;done<=1;state<=IDLE;end
            default:state<=ABORT;
        endcase
    end
end
endmodule
