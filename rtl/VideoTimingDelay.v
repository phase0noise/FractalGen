// Fixed timing latency matches HDColorEffects. Effect controls never enter
// the sync/selection path. Both clocks remain free-running during capture.
module VideoTimingDelay #(parameter LATENCY=13) (
    input clk,reset,input_hsync,input_vsync,input_selected,
    output hsync,vsync,selected
);
reg [LATENCY-1:0] hp,vp,sp;
assign hsync=hp[LATENCY-1]; assign vsync=vp[LATENCY-1]; assign selected=sp[LATENCY-1];
always @(posedge clk or posedge reset)
    if(reset) begin hp<={LATENCY{1'b1}}; vp<={LATENCY{1'b1}}; sp<=0; end
    else begin hp<={hp[LATENCY-2:0],input_hsync}; vp<={vp[LATENCY-2:0],input_vsync};
        sp<={sp[LATENCY-2:0],input_selected}; end
endmodule
