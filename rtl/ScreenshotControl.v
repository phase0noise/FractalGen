// Keyboard events cross by toggles. Busy jobs ignore additional capture keys.
module ScreenshotKeys (
    input clk,reset,input [7:0] keycode,input key_ready,key_extended,key_released,
    output reg shot_toggle,uhd_toggle,cancel_toggle
);
reg shot_held,uhd_held,cancel_held;
always @(posedge clk or posedge reset)
    if(reset) begin shot_toggle<=0;uhd_toggle<=0;cancel_toggle<=0;shot_held<=0;uhd_held<=0;cancel_held<=0;end
    else if(key_ready && !key_extended) case(keycode)
        8'h07: begin shot_held<=!key_released;if(!key_released && !shot_held) shot_toggle<=~shot_toggle;end // F12
        8'h78: begin uhd_held<=!key_released;if(!key_released && !uhd_held) uhd_toggle<=~uhd_toggle;end // F11
        8'h76: begin cancel_held<=!key_released;if(!key_released && !cancel_held) cancel_toggle<=~cancel_toggle;end
        default:;
    endcase
endmodule

module ScreenshotControl #(parameter UHD_WIDTH=3840,UHD_HEIGHT=2160) (
    input clk,reset,shot_toggle,uhd_toggle,cancel_toggle,
    input hd_requested,hd_done,hd_live,workers_idle,writes_drained,
    input [3:0] scheme,input [3:0] color_offset,input [7:0] effects,
    input signed [31:0] center_x,center_y,input [31:0] zoom,input lens,
    input [56:0] preview_phases,hd_phases,input hd_phase_ack,
    output reg hd_phase_request,
    output reg busy,finished,output reg [7:0] error,output render_lock,
    output reg uhd_start,output job_cancel,input uhd_done,uhd_cancelled,
    output reg signed [31:0] saved_x,saved_y,output reg [31:0] saved_zoom,output reg saved_lens,
    output reg fs_start,input fs_done,fs_ready,input [7:0] fs_error,output reg begin_payload,
    output [31:0] file_size,output reg [1:0] mode,
    output reg [3:0] saved_scheme,output reg [3:0] saved_offset,output reg [7:0] saved_effects,
    output reg [56:0] saved_phases
);
localparam IDLE=0,PHASE_WAIT=1,WAIT_IMAGE=2,DRAIN=3,UHD_WAIT=4,FS_WAIT=5,ALLOC_WAIT=6;
reg [2:0] state;
reg [2:0] keys_meta,keys_sync,keys_seen;
reg ack_meta,ack_sync,hd_meta,hd_sync,cancel_pending;
wire new_shot=keys_sync[0]!=keys_seen[0],new_uhd=keys_sync[1]!=keys_seen[1],new_cancel=keys_sync[2]!=keys_seen[2];
assign render_lock=busy && state!=WAIT_IMAGE;
assign job_cancel=cancel_pending || (busy && new_cancel);
assign file_size=mode==0 ? 32'd921654 : mode==1 ? 32'd3932214 : UHD_WIDTH*UHD_HEIGHT*3+54;
always @(posedge clk or posedge reset)
    if(reset) begin
        state<=IDLE;keys_meta<=0;keys_sync<=0;keys_seen<=0;ack_meta<=0;ack_sync<=0;hd_meta<=0;hd_sync<=0;
        busy<=0;finished<=0;error<=0;cancel_pending<=0;hd_phase_request<=0;uhd_start<=0;fs_start<=0;begin_payload<=0;
        mode<=0;saved_scheme<=0;saved_offset<=0;saved_effects<=0;saved_phases<=0;
        saved_x<=0;saved_y<=0;saved_zoom<=0;saved_lens<=0;
    end else begin
        keys_meta<={cancel_toggle,uhd_toggle,shot_toggle};keys_sync<=keys_meta;keys_seen<=keys_sync;
        ack_meta<=hd_phase_ack;ack_sync<=ack_meta;hd_meta<=hd_live;hd_sync<=hd_meta;
        finished<=0;uhd_start<=0;fs_start<=0;
        if(busy && new_cancel) cancel_pending<=1;
        case(state)
            IDLE: if(new_shot || new_uhd) begin
                busy<=1;error<=0;cancel_pending<=0;begin_payload<=0;mode<=new_uhd ? 2 : hd_requested ? 1 : 0;
                saved_scheme<=scheme;saved_offset<=color_offset;saved_effects<=effects;
                saved_x<=center_x;saved_y<=center_y;saved_zoom<=zoom;saved_lens<=lens;
                if(hd_sync) begin hd_phase_request<=~hd_phase_request;state<=PHASE_WAIT;end
                else begin saved_phases<=preview_phases;state<=WAIT_IMAGE;end
            end
            PHASE_WAIT: if(job_cancel) begin busy<=0;finished<=1;state<=IDLE;end
                else if(!hd_sync && !hd_requested) begin saved_phases<=preview_phases;state<=WAIT_IMAGE;end
                else if(ack_sync==hd_phase_request) begin saved_phases<=hd_phases;state<=WAIT_IMAGE;end
            WAIT_IMAGE: if(job_cancel || (mode==1 && !hd_requested)) begin busy<=0;finished<=1;state<=IDLE;end
                else if(mode!=1 || hd_done) state<=DRAIN;
            DRAIN: if(job_cancel) begin busy<=0;finished<=1;state<=IDLE;end
                else if(workers_idle && writes_drained) begin fs_start<=1;state<=ALLOC_WAIT;end
            ALLOC_WAIT: if(fs_done) begin busy<=0;finished<=1;error<=fs_error==8'h40 ? 0 : fs_error;state<=IDLE;end
                else if(fs_ready && !job_cancel) begin
                    if(mode==2) begin uhd_start<=1;state<=UHD_WAIT;end else begin begin_payload<=1;state<=FS_WAIT;end
                end
            UHD_WAIT: if(uhd_done) begin
                if(uhd_cancelled || job_cancel) begin busy<=0;finished<=1;state<=IDLE;end
                else begin begin_payload<=1;state<=FS_WAIT;end
            end
            FS_WAIT: if(fs_done) begin busy<=0;finished<=1;error<=fs_error==8'h40 ? 0 : fs_error;state<=IDLE;end
            default:begin busy<=0;state<=IDLE;error<=8'hff;end
        endcase
    end
endmodule
