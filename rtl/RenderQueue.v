// Ordered publication with out-of-order worker returns. A slow pixel holds
// only its group; workers can fill the other slots while SDRAM drains the head.
module RenderQueue #(parameter SLOTS=4, SLOT_BITS=$clog2(SLOTS)) (
    input clk,reset,active,
    input dispatch,input [2:0] dispatch_lane,input [23:0] dispatch_base,
    output dispatch_ready,output [SLOT_BITS-1:0] dispatch_slot,
    input pixel_valid,input [SLOT_BITS-1:0] pixel_slot,input [2:0] pixel_lane,
    input [11:0] pixel_rgb,
    output group_valid,output [23:0] group_base,output [95:0] group_pixels,
    input group_ack,output empty,
    output reg [31:0] allocated_groups,retired_groups
);
reg [SLOT_BITS-1:0] head,tail,current;
reg [SLOT_BITS:0] count;
reg [7:0] seen[0:SLOTS-1];
reg [23:0] addresses[0:SLOTS-1];
// Separate lane banks allow a 12-bit write without a 96-bit masked register
// mux. Validity is reset; color RAM becomes visible only after all lanes return.
(* ramstyle = "MLAB, no_rw_check" *) reg [11:0] color0[0:SLOTS-1],color1[0:SLOTS-1],color2[0:SLOTS-1],color3[0:SLOTS-1],
    color4[0:SLOTS-1],color5[0:SLOTS-1],color6[0:SLOTS-1],color7[0:SLOTS-1];
wire allocate=active && dispatch && dispatch_lane==0;
wire retire=active && group_ack && group_valid;
assign dispatch_ready=dispatch_lane!=0 || count<SLOTS;
assign dispatch_slot=dispatch_lane==0 ? tail : current;
assign group_valid=active && count!=0 && &seen[head];
assign group_base=addresses[head];
assign group_pixels={color7[head],color6[head],color5[head],color4[head],color3[head],color2[head],color1[head],color0[head]};
assign empty=count==0;
integer slot;
always @(posedge clk or posedge reset) begin
    if(reset) begin
        head<=0;tail<=0;current<=0;count<=0;allocated_groups<=0;retired_groups<=0;
        for(slot=0;slot<SLOTS;slot=slot+1) begin seen[slot]<=0;addresses[slot]<=0;end
    end else if(!active) begin
        head<=0;tail<=0;current<=0;count<=0;allocated_groups<=0;retired_groups<=0;
        for(slot=0;slot<SLOTS;slot=slot+1) seen[slot]<=0;
    end else begin
        case({allocate,retire})
            2'b10: count<=count+1'b1;
            2'b01: count<=count-1'b1;
            default: ;
        endcase
        if(allocate) begin
            addresses[tail]<=dispatch_base;seen[tail]<=0;
            current<=tail;tail<=tail+1'b1;allocated_groups<=allocated_groups+1'b1;
        end
        if(pixel_valid) begin
            seen[pixel_slot][pixel_lane]<=1'b1;
        end
        if(retire) begin
            seen[head]<=0;head<=head+1'b1;retired_groups<=retired_groups+1'b1;
        end
    end
end
always @(posedge clk) if(active && pixel_valid) begin
    case(pixel_lane)
        0: color0[pixel_slot]<=pixel_rgb;
        1: color1[pixel_slot]<=pixel_rgb;
        2: color2[pixel_slot]<=pixel_rgb;
        3: color3[pixel_slot]<=pixel_rgb;
        4: color4[pixel_slot]<=pixel_rgb;
        5: color5[pixel_slot]<=pixel_rgb;
        6: color6[pixel_slot]<=pixel_rgb;
        7: color7[pixel_slot]<=pixel_rgb;
    endcase
end
endmodule
