// Thirteen registered stages. Effects never move pixel locations or feed
// VGA timing. Fractional blends use uniform rounding, without spatial noise.
module HDColorEffects #(parameter EXTERNAL_PHASES=0, X_BITS=11, Y_BITS=10, SMOOTH_VIVID=0) (
    input clk,reset,enabled,frame_tick,
    input [3:0] input_red,input_green,input_blue, input input_hsync,input_vsync,
    input [3:0] color_scheme, input [3:0] color_offset,
    input [1:0] burn_speed, input burn_enable,stochastic_burn,
    input morph,prism,glow,pixel_tick,vivid,fuzz,pixel_active,
    input [X_BITS-1:0] pixel_x, input [Y_BITS-1:0] pixel_y,
    input [56:0] phase_values, output [56:0] phase_state,
    output [3:0] red,green,blue, output [7:0] red8,green8,blue8,
    output hsync,vsync,selected
);
localparam C_BITS=SMOOTH_VIVID ? 8 : 4, RGB_BITS=3*C_BITS;
localparam CHANNEL_MAX=(1<<C_BITS)-1;
reg [3:0] scheme_meta,scheme_sync;
reg [3:0] offset_meta,offset_sync;
reg [1:0] speed_meta,speed_sync;
reg burn_meta,burn_sync,stochastic_meta,stochastic_sync,morph_meta,morph_sync;
reg prism_meta,prism_sync,glow_meta,glow_sync,vivid_meta,vivid_sync,fuzz_meta,fuzz_sync;
reg [15:0] hue_accum,fire_accum,morph_phase;
reg [7:0] stochastic_round;
reg [3:0] frame_divider;
reg smooth_mode;
assign phase_state={smooth_mode,stochastic_round,morph_phase,fire_accum,hue_accum};
reg [12:0] sync_select,hsync_pipe,vsync_pipe;
reg [12:0] fine_pipe;
reg [10:0] active_pipe,tick_pipe,prism_pipe,glow_pipe;
reg [6:0] fuzz_pipe;
reg [15:0] noise,noise1,noise2,noise3,noise4,noise5,noise6,noise7;
reg [31:0] hash1,hash2;
reg [2:0] hit_slot;
reg [11:0] source1,source2,source3;
reg [3:0] look1,look2,look3,look4;
reg [3:0] offset1,offset2;
reg [15:0] fire1,fire2,hue1,hue2,morph1,morph2,morph3;
reg [7:0] round1,round2,round3;
reg burn1,burn2,burn3,stochastic1,stochastic2,stochastic3,morph_on1,morph_on2,morph_on3;
reg smooth1,smooth2,smooth3;
reg bright1,bright2,bright3,vivid1,vivid2,vivid3;
reg [5:0] luminance2;
reg [16:0] manual_hue2;
reg [3:0] palette_base3,palette_advanced3;
reg [15:0] phase_base3,phase_advanced3;
reg [7:0] fraction3,fraction_advanced3;
reg dark3,zero3;
reg [11:0] preset_rgb,preset_next;
reg [RGB_BITS-1:0] blended_rgb,output_rgb,color_rgb,morph_rgb,dispersion_rgb,final_rgb;
reg [15:0] preset_phase;
reg [7:0] preset_fraction;
reg [3:0] blend_r,blend_g,blend_b;
reg signed [8:0] blend_dr,blend_dg,blend_db,blend_hr,blend_hg,blend_hb;
reg [RGB_BITS-1:0] target4,target5,target6,target7,target8;
reg [RGB_BITS-1:0] contrast7,target_contrast7;
reg brighten7;
reg [7:0] amount4,amount5,amount6,amount7,amount8;
reg [RGB_BITS-1:0] morph_source,morph_target;
reg morph_fine,morph_fine10,morph_fine11,output_fine;
reg [7:0] morph_amount;
reg [C_BITS-1:0] morph_r,morph_g,morph_b;
reg signed [C_BITS+8:0] morph_dr,morph_dg,morph_db;
reg [11:0] echo_history[0:15];
reg [4:0] echo_count;
reg [RGB_BITS-1:0] glow_near,glow_far;
reg glow_output,active_output;
integer history_index;
wire [31:0] epoch_seed={stochastic_round[7:3],stochastic_round[7:3],
    stochastic_round[7:3],stochastic_round[7:3],stochastic_round[7:3],stochastic_round[7:3],2'b01};
// Preserve preview/HD masks, while mixing the extra 4K coordinate bits.
wire [31:0] hash_seed=({20'd0,pixel_x} ^ ({20'd0,pixel_y}<<11)) ^
    ((pixel_x>>11)!=0 ? 32'h7f4a7c15 : 32'd0) ^
    ((pixel_y>>10)!=0 ? ({20'd0,pixel_y}<<21) : 32'd0) ^ epoch_seed ^ 32'h9e3779b9;
wire [31:0] hash_add1=hash_seed+(hash_seed<<10);
wire [31:0] hash_add2=hash1+(hash1<<3);
wire [31:0] hash_add3=hash2+(hash2<<15);
// Prepare both stochastic outcomes before the hash comparison. The lookup
// stage then needs only a small select, rather than heat/index arithmetic
// followed by three palette ROMs on the same 108 MHz path.
wire [4:0] base_step2=round2[7:3];
wire [4:0] advanced_step2=base_step2+5'd1;
wire [9:0] blue_wave2=fire2[15] ? ~fire2[14:5] : fire2[14:5];
wire [1:0] base_glow2=!burn2 ? 2'd0 : stochastic2 ?
    (base_step2[2] ? ~base_step2[1:0] : base_step2[1:0]) :
    smooth2 ? blue_wave2[9:8] : (fire2[15] ? ~fire2[14:13] : fire2[14:13]);
wire [1:0] advanced_glow2=advanced_step2[2] ? ~advanced_step2[1:0] : advanced_step2[1:0];
wire [4:0] base_heat_sum2={1'b0,luminance2[5:2]}+{3'd0,base_glow2};
wire [4:0] advanced_heat_sum2={1'b0,luminance2[5:2]}+{3'd0,advanced_glow2};
wire [3:0] base_heat2=base_heat_sum2>15 ? 4'd15 : base_heat_sum2[3:0];
wire [3:0] advanced_heat2=advanced_heat_sum2>15 ? 4'd15 : advanced_heat_sum2[3:0];
wire [3:0] palette_step2=!burn2 ? 4'd0 : stochastic2 ? base_step2[3:0] : fire2[15:12];
// SW8 maps the full luminance range continuously across the palette. The two
// low tone bits and eight Burn phase bits survive through RGB888 arithmetic.
wire [11:0] tone_base2=({6'd0,luminance2}<<6)+({8'd0,offset2}<<8)+
    (!burn2 ? 12'd0 : stochastic2 ? {base_step2[3:0],8'd0} : fire2[15:4]);
wire [11:0] tone_advanced2=({6'd0,luminance2}<<6)+({8'd0,offset2}<<8)+{advanced_step2[3:0],8'd0};
wire [12:0] heat_base2=({7'd0,luminance2}<<6)+
    (!burn2 ? 13'd0 : stochastic2 ? {3'd0,base_glow2,8'd0} : {3'd0,blue_wave2});
wire [12:0] heat_advanced2=({7'd0,luminance2}<<6)+{3'd0,advanced_glow2,8'd0};
wire [11:0] heat_tone_base2=(heat_base2>=3840 ? 12'd3840 : heat_base2[11:0])+{offset2,8'd0};
wire [11:0] heat_tone_advanced2=(heat_advanced2>=3840 ? 12'd3840 : heat_advanced2[11:0])+{offset2,8'd0};
wire [11:0] fine_tone_base2=look2==1 ? heat_tone_base2 : tone_base2;
wire [11:0] fine_tone_advanced2=look2==1 ? heat_tone_advanced2 : tone_advanced2;
wire advance3=stochastic3 && round3[2:0]>hit_slot;
wire [3:0] palette_index=advance3 ? palette_advanced3 : palette_base3;
wire [3:0] next_index=palette_index+1'b1;
wire [11:0] palette_rgb,next_rgb,target_rgb;
EffectPalettes colors (.scheme(look3),.index(palette_index),.rgb(palette_rgb));
EffectPalettes next_colors (.scheme(look3),.index(next_index),.rgb(next_rgb));
// The target changes palette only when its blend weight reaches zero.
wire [3:0] target_scheme=look3==1 ? 4'd3 :
    look3==2 ? (morph3[15] ? 4'd3 : 4'd5) :
    look3==5 ? (morph3[15] ? 4'd2 : 4'd3) : (morph3[15] ? 4'd5 : 4'd2);
EffectPalettes morph_colors (.scheme(target_scheme),.index(palette_index),.rgb(target_rgb));
wire [11:0] shaded_rgb=dark3 ?
    {1'b0,palette_rgb[11:9],1'b0,palette_rgb[7:5],1'b0,palette_rgb[3:1]} : palette_rgb;
wire [11:0] shaded_next=dark3 ?
    {1'b0,next_rgb[11:9],1'b0,next_rgb[7:5],1'b0,next_rgb[3:1]} : next_rgb;
wire [11:0] shaded_target=dark3 ?
    {1'b0,target_rgb[11:9],1'b0,target_rgb[7:5],1'b0,target_rgb[3:1]} : target_rgb;
wire [15:0] base_ocean2=({11'd0,base_step2[2:0]}<<12)+({11'd0,base_step2[2:0]}<<11);
wire [15:0] advanced_ocean2=({11'd0,advanced_step2[2:0]}<<12)+({11'd0,advanced_step2[2:0]}<<11);
wire [16:0] base_hue2=manual_hue2+(!burn2 ? 17'd0 : stochastic2 ? {1'b0,base_ocean2} : {1'b0,hue2});
wire [16:0] advanced_hue2=manual_hue2+{1'b0,advanced_ocean2};
wire [15:0] selected_phase3=advance3 ? phase_advanced3 : phase_base3;
wire [7:0] amount=preset_fraction;
reg [3:0] ra,rb,ga,gb,ba,bb;
always @(*) begin
    if(look4!=0 || fine_pipe[3]) begin
        ra=preset_rgb[11:8]; rb=preset_next[11:8];
        ga=preset_rgb[7:4]; gb=preset_next[7:4]; ba=preset_rgb[3:0]; bb=preset_next[3:0];
    end else case(preset_phase[15:14])
        0: begin ra=preset_rgb[11:8]; rb=preset_rgb[7:4]; ga=preset_rgb[7:4];
            gb=preset_rgb[3:0]; ba=preset_rgb[3:0]; bb=preset_rgb[11:8]; end
        1: begin ra=preset_rgb[7:4]; rb=preset_rgb[3:0]; ga=preset_rgb[3:0];
            gb=preset_rgb[11:8]; ba=preset_rgb[11:8]; bb=preset_rgb[7:4]; end
        default: begin ra=preset_rgb[3:0]; rb=preset_rgb[11:8]; ga=preset_rgb[11:8];
            gb=preset_rgb[7:4]; ba=preset_rgb[7:4]; bb=preset_rgb[3:0]; end
    endcase
end
// Each palette product is split into low/high weight nibbles. The next stage
// combines them before rounding, keeping mux/subtract/product work bounded.
function signed [8:0] palette_product;
    input signed [4:0] difference;input [3:0] weight;
    reg signed [8:0] extended,p0,p1,p2,p3;
    begin extended={{4{difference[4]}},difference};
        p0=weight[0] ? extended : 0;p1=weight[1] ? extended<<<1 : 0;
        p2=weight[2] ? extended<<<2 : 0;p3=weight[3] ? extended<<<3 : 0;
        palette_product=(p0+p1)+(p2+p3);end
endfunction
function signed [12:0] palette_delta;
    input signed [8:0] low,high;
    reg signed [12:0] low_extended,high_extended;
    begin low_extended={{4{low[8]}},low};high_extended={{4{high[8]}},high};
        palette_delta=low_extended+(high_extended<<<4);end
endfunction
// Four-bit legacy Morph retains the original shift/add calculation.
function signed [C_BITS+8:0] delta_product;
    input signed [C_BITS:0] difference; input [7:0] weight;
    reg signed [C_BITS+8:0] extended,p[0:7];integer bit_index;
    begin extended={{8{difference[C_BITS]}},difference};
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)
            p[bit_index]=weight[bit_index] ? extended<<<bit_index : 0;
        delta_product=((p[0]+p[1])+(p[2]+p[3]))+((p[4]+p[5])+(p[6]+p[7]));
    end
endfunction
// Cyclone V packs three signed 9x9 products in one DSP block. Only the
// RGB888 Morph stage uses these; palette interpolation stays in shift/add LUTs.
function signed [C_BITS+8:0] morph_product;
    input signed [C_BITS:0] difference;input [7:0] weight;
    reg signed [C_BITS+8:0] result /* synthesis multstyle = "dsp" */;
    begin result=difference*$signed({1'b0,weight});
        morph_product=C_BITS==8 ? result : delta_product(difference,weight);end
endfunction
function [C_BITS-1:0] expand_channel;
    input [3:0] value;
    begin expand_channel=C_BITS==8 ? {value,value} : value;end
endfunction
function [RGB_BITS-1:0] expand_rgb;
    input [11:0] value;
    begin expand_rgb={expand_channel(value[11:8]),expand_channel(value[7:4]),expand_channel(value[3:0])};end
endfunction
function [3:0] dac_channel;
    input [C_BITS-1:0] value;reg [7:0] wide;reg signed [5:0] difference;
    begin
        wide=value;difference=$signed({2'd0,wide[3:0]})-$signed({2'd0,wide[7:4]});
        if(C_BITS==4) dac_channel=value;
        else dac_channel=difference>8 ? wide[7:4]+1'b1 : difference < -8 ? wide[7:4]-1'b1 : wide[7:4];
    end
endfunction
function [11:0] dac_rgb;
    input [RGB_BITS-1:0] value;
    begin dac_rgb={dac_channel(value[3*C_BITS-1:2*C_BITS]),dac_channel(value[2*C_BITS-1:C_BITS]),dac_channel(value[C_BITS-1:0])};end
endfunction
function [15:0] wrap_hue;
    input [16:0] value;
    begin wrap_hue=value>=49152 ? value-17'd49152 : value[15:0]; end
endfunction
function [C_BITS-1:0] palette_average;
    input [3:0] base;input signed [12:0] delta;input fine;
    reg signed [13:0] sum;reg [15:0] fine_sum;reg [3:0] coarse;
    begin sum=$signed({2'd0,base,8'd0})+delta;
        fine_sum=({2'd0,sum}<<4)+sum+16'd128;
        sum=sum+14'sd128;coarse=sum[11:8];
        palette_average=fine && C_BITS==8 ? fine_sum[15:8] : expand_channel(coarse);
    end
endfunction
function [C_BITS-1:0] morph_average;
    input [C_BITS-1:0] base;input signed [C_BITS+8:0] delta;input fine;
    reg signed [C_BITS+8:0] sum;reg [C_BITS-1:0] value;
    begin sum=$signed({1'b0,base,8'd0})+delta+128;value=sum[C_BITS+7:8];
        morph_average=fine ? value : expand_channel(value[3:0]);end
endfunction
// Choose the arithmetic scale at the input register, before multiplication.
// Legacy pixels carry their four-bit levels; SW8 pixels carry eight-bit levels.
// The average stage then rounds once, without a serial RGB888-to-DAC divide.
function [RGB_BITS-1:0] morph_input;
    input [RGB_BITS-1:0] value;input fine;
    reg [C_BITS-1:0] r_value,g_value,b_value;
    begin
        r_value=value[3*C_BITS-1:2*C_BITS]>>(C_BITS-4);
        g_value=value[2*C_BITS-1:C_BITS]>>(C_BITS-4);
        b_value=value[C_BITS-1:0]>>(C_BITS-4);
        morph_input=fine ? value : {r_value,g_value,b_value};
    end
endfunction
function [C_BITS-1:0] raise_channel;
    input [C_BITS-1:0] channel,contrast;input fine;
    reg [C_BITS:0] raised;reg [4:0] coarse;
    reg [3:0] coarse_channel,coarse_contrast;
    begin raised={1'b0,channel}+({1'b0,contrast}>>1);
        coarse_channel=channel>>(C_BITS-4);coarse_contrast=contrast>>(C_BITS-4);
        coarse={1'b0,coarse_channel}+({1'b0,coarse_contrast}>>1);
        raise_channel=fine ? (raised>CHANNEL_MAX ? CHANNEL_MAX : raised[C_BITS-1:0]) :
            expand_channel(coarse>15 ? 4'd15 : coarse[3:0]);end
endfunction
function [RGB_BITS-1:0] color_contrast;
    input [RGB_BITS-1:0] value; reg [C_BITS-1:0] minimum;
    begin minimum=value[3*C_BITS-1:2*C_BITS]<value[2*C_BITS-1:C_BITS] ? value[3*C_BITS-1:2*C_BITS] : value[2*C_BITS-1:C_BITS];
        if(value[C_BITS-1:0]<minimum) minimum=value[C_BITS-1:0];
        color_contrast={value[3*C_BITS-1:2*C_BITS]-minimum,
            value[2*C_BITS-1:C_BITS]-minimum,value[C_BITS-1:0]-minimum};
    end
endfunction
function [RGB_BITS-1:0] raise_rgb;
    input [RGB_BITS-1:0] value,contrast;input fine;
    begin raise_rgb={raise_channel(value[3*C_BITS-1:2*C_BITS],contrast[3*C_BITS-1:2*C_BITS],fine),
        raise_channel(value[2*C_BITS-1:C_BITS],contrast[2*C_BITS-1:C_BITS],fine),
        raise_channel(value[C_BITS-1:0],contrast[C_BITS-1:0],fine)};end
endfunction
function [C_BITS-1:0] prism_edge;
    input [C_BITS-1:0] current,echo;input fine;
    reg [C_BITS-1:0] difference;reg [C_BITS:0] raised;
    reg [3:0] coarse_current,coarse_echo,coarse_difference;reg [4:0] coarse;
    begin difference=current>echo ? current-echo : echo-current;
        raised={1'b0,current}+({1'b0,difference}>>1);
        coarse_current=current>>(C_BITS-4);coarse_echo=echo>>(C_BITS-4);
        coarse_difference=coarse_current>coarse_echo ? coarse_current-coarse_echo : coarse_echo-coarse_current;
        coarse={1'b0,coarse_current}+{2'd0,coarse_difference[3:1]};
        prism_edge=fine ? (raised>CHANNEL_MAX ? CHANNEL_MAX : raised[C_BITS-1:0]) :
            expand_channel(coarse>15 ? 4'd15 : coarse[3:0]);end
endfunction
function [C_BITS-1:0] bloom;
    input [C_BITS-1:0] channel,nearby,distant;input fine;reg [C_BITS:0] raised;reg [5:0] coarse;
    reg [3:0] coarse_channel,coarse_near,coarse_far;
    begin raised={1'b0,channel}+({1'b0,nearby}>>2)+({1'b0,distant}>>3);
        coarse_channel=channel>>(C_BITS-4);coarse_near=nearby>>(C_BITS-4);coarse_far=distant>>(C_BITS-4);
        coarse={2'd0,coarse_channel}+{4'd0,coarse_near[3:2]}+{5'd0,coarse_far[3]};
        bloom=fine ? (raised>CHANNEL_MAX ? CHANNEL_MAX : raised[C_BITS-1:0]) :
            expand_channel(coarse>15 ? 4'd15 : coarse[3:0]);end
endfunction
wire [RGB_BITS-1:0] echo2=expand_rgb(echo_history[2]),echo6=expand_rgb(echo_history[6]),echo10=expand_rgb(echo_history[10]);
wire [RGB_BITS-1:0] raised7=brighten7 ? raise_rgb(output_rgb,contrast7,fine_pipe[6]) : output_rgb;
assign {red,green,blue}=dac_rgb(final_rgb);
assign red8=C_BITS==8 ? final_rgb[3*C_BITS-1:2*C_BITS] : {red,red};
assign green8=C_BITS==8 ? final_rgb[2*C_BITS-1:C_BITS] : {green,green};
assign blue8=C_BITS==8 ? final_rgb[C_BITS-1:0] : {blue,blue};
assign hsync=hsync_pipe[12]; assign vsync=vsync_pipe[12]; assign selected=sync_select[12];
always @(posedge clk or posedge reset) begin
    if(reset) begin
        scheme_meta<=0; scheme_sync<=0; offset_meta<=0; offset_sync<=0; speed_meta<=2; speed_sync<=2;
        burn_meta<=0; burn_sync<=0; stochastic_meta<=0; stochastic_sync<=0; morph_meta<=0; morph_sync<=0;
        prism_meta<=0; prism_sync<=0; glow_meta<=0; glow_sync<=0; vivid_meta<=0; vivid_sync<=0; fuzz_meta<=0; fuzz_sync<=0;
        hue_accum<=0; fire_accum<=0; morph_phase<=0; frame_divider<=0; stochastic_round<=0; smooth_mode<=0;
        sync_select<=0; hsync_pipe<=13'h1fff; vsync_pipe<=13'h1fff; fine_pipe<=0;
        active_pipe<=0; tick_pipe<=0; prism_pipe<=0; glow_pipe<=0; fuzz_pipe<=0;
        noise<=16'h1ace; noise1<=0; noise2<=0; noise3<=0; noise4<=0; noise5<=0; noise6<=0; noise7<=0;
        hash1<=0; hash2<=0; hit_slot<=0;
        source1<=0; source2<=0; source3<=0; look1<=0; look2<=0; look3<=0; look4<=0;
        offset1<=0; offset2<=0; fire1<=0; fire2<=0; hue1<=0; hue2<=0;
        morph1<=0; morph2<=0; morph3<=0; round1<=0; round2<=0; round3<=0;
        burn1<=0; burn2<=0; burn3<=0; stochastic1<=0; stochastic2<=0; stochastic3<=0;
        morph_on1<=0; morph_on2<=0; morph_on3<=0; smooth1<=0; smooth2<=0; smooth3<=0;
        bright1<=0; bright2<=0; bright3<=0; vivid1<=0; vivid2<=0; vivid3<=0;
        luminance2<=0; manual_hue2<=0; palette_base3<=0; palette_advanced3<=0;
        phase_base3<=0; phase_advanced3<=0; fraction3<=0; fraction_advanced3<=0; dark3<=0; zero3<=1;
        preset_rgb<=0; preset_next<=0; preset_phase<=0; preset_fraction<=0;
        blend_r<=0;blend_g<=0;blend_b<=0;blend_dr<=0;blend_dg<=0;blend_db<=0;
        blend_hr<=0;blend_hg<=0;blend_hb<=0;
        blended_rgb<=0; output_rgb<=0; color_rgb<=0;
        target4<=0; target5<=0; target6<=0; target7<=0; target8<=0;
        contrast7<=0;target_contrast7<=0;brighten7<=0;
        amount4<=0; amount5<=0; amount6<=0; amount7<=0; amount8<=0;
        morph_source<=0; morph_target<=0; morph_amount<=0;
        morph_fine<=0;morph_fine10<=0;morph_fine11<=0;output_fine<=0;
        morph_r<=0;morph_g<=0;morph_b<=0;morph_dr<=0;morph_dg<=0;morph_db<=0;morph_rgb<=0;
        echo_count<=0; dispersion_rgb<=0; glow_near<=0; glow_far<=0; glow_output<=0; active_output<=0; final_rgb<=0;
        for(history_index=0;history_index<16;history_index=history_index+1) echo_history[history_index]<=0;
    end else begin
        scheme_meta<=color_scheme; scheme_sync<=scheme_meta; offset_meta<=color_offset; offset_sync<=offset_meta;
        speed_meta<=burn_speed; speed_sync<=speed_meta; burn_meta<=burn_enable; burn_sync<=burn_meta;
        stochastic_meta<=stochastic_burn; stochastic_sync<=stochastic_meta; morph_meta<=morph; morph_sync<=morph_meta;
        prism_meta<=prism; prism_sync<=prism_meta; glow_meta<=glow; glow_sync<=glow_meta;
        vivid_meta<=vivid; vivid_sync<=vivid_meta; fuzz_meta<=fuzz; fuzz_sync<=fuzz_meta;
        if(speed_sync!=0) smooth_mode<=speed_sync==1;
        if(!enabled) begin hue_accum<=0; fire_accum<=0; frame_divider<=0; stochastic_round<=0; noise<=16'h1ace; end
        else begin
            noise<={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
            if(!stochastic_sync || !burn_sync) stochastic_round<=0;
            if(frame_tick) begin
                frame_divider<=speed_sync==1 ? frame_divider+1'b1 : 4'd0;
                if(burn_sync) case(speed_sync)
                    1: begin
                        fire_accum<=fire_accum+16'd64;
                        hue_accum<=hue_accum>=49088 ? hue_accum-16'd49088 : hue_accum+16'd64;
                        if(stochastic_sync && frame_divider==15) stochastic_round<=stochastic_round+1'b1;
                    end
                    2: begin
                        fire_accum<=fire_accum+16'd1024;
                        hue_accum<=hue_accum>=48896 ? hue_accum-16'd48896 : hue_accum+16'd256;
                        if(stochastic_sync) stochastic_round<=stochastic_round+1'b1;
                    end
                    3: begin
                        fire_accum<=fire_accum+16'd3072;
                        hue_accum<=hue_accum>=48384 ? hue_accum-16'd48384 : hue_accum+16'd768;
                        if(stochastic_sync) stochastic_round<=stochastic_round+8'd2;
                    end
                    default: ;
                endcase
            end
        end
        if(!enabled || !morph_sync) morph_phase<=0;
        else if(frame_tick) case(speed_sync)
            1: morph_phase<=morph_phase+16'd64;
            2: morph_phase<=morph_phase+16'd256;
            3: morph_phase<=morph_phase+16'd512;
            default: ;
        endcase
        // An offline screenshot replays a held phase while the live outputs
        // continue independently. No VGA control depends on these values.
        if(EXTERNAL_PHASES) begin
            {smooth_mode,stochastic_round,morph_phase,fire_accum,hue_accum}<=phase_values;
        end
        hsync_pipe<={hsync_pipe[11:0],input_hsync}; vsync_pipe<={vsync_pipe[11:0],input_vsync};
        fine_pipe<={fine_pipe[11:0],SMOOTH_VIVID && vivid_sync};
        sync_select<={sync_select[11:0],enabled}; active_pipe<={active_pipe[9:0],pixel_active};
        tick_pipe<={tick_pipe[9:0],pixel_tick}; prism_pipe<={prism_pipe[9:0],prism_sync}; glow_pipe<={glow_pipe[9:0],glow_sync};
        fuzz_pipe<={fuzz_pipe[5:0],fuzz_sync && pixel_active};
        noise1<=noise; noise2<=noise1; noise3<=noise2; noise4<=noise3; noise5<=noise4; noise6<=noise5; noise7<=noise6;
        hash1<=hash_add1 ^ (hash_add1>>6); hash2<=hash_add2 ^ (hash_add2>>11);
        hit_slot<=hash_add3[31:29] ^ hash_add3[2:0];
        source1<={input_red,input_green,input_blue}; source2<=source1; source3<=source2;
        look1<=scheme_sync; look2<=look1; look3<=look2; look4<=look3;
        offset1<=offset_sync; offset2<=offset1;
        fire1<=fire_accum; fire2<=fire1; hue1<=hue_accum; hue2<=hue1;
        luminance2<={2'd0,source1[11:8]}+({2'd0,source1[7:4]}<<1)+{2'd0,source1[3:0]};
        manual_hue2<=({13'd0,offset1}<<11)+({13'd0,offset1}<<10);
        palette_base3<=fine_pipe[1] ? fine_tone_base2[11:8] : offset2+(look2==1 ? base_heat2 : luminance2[3:0]+palette_step2);
        palette_advanced3<=fine_pipe[1] ? fine_tone_advanced2[11:8] : offset2+(look2==1 ? advanced_heat2 : luminance2[3:0]+advanced_step2[3:0]);
        phase_base3<=wrap_hue(base_hue2); phase_advanced3<=wrap_hue(advanced_hue2);
        fraction3<=fine_pipe[1] ? fine_tone_base2[7:0] : !smooth2 ? 8'd0 : look2==1 ?
            (base_heat_sum2>=15 ? 8'd0 : blue_wave2[7:0]) : fire2[11:4];
        fraction_advanced3<=fine_pipe[1] ? fine_tone_advanced2[7:0] : !smooth2 ? 8'd0 : look2==1 ?
            (base_heat_sum2>=15 ? 8'd0 : blue_wave2[7:0]) : fire2[11:4];
        dark3<=!fine_pipe[1] && luminance2[5:2]<4 && look2!=1; zero3<=luminance2==0;
        morph1<=morph_phase; morph2<=morph1; morph3<=morph2;
        round1<=stochastic_round; round2<=round1; round3<=round2;
        burn1<=burn_sync; burn2<=burn1; burn3<=burn2;
        stochastic1<=burn_sync && stochastic_sync && pixel_active; stochastic2<=stochastic1; stochastic3<=stochastic2;
        morph_on1<=morph_sync; morph_on2<=morph_on1; morph_on3<=morph_on2;
        smooth1<=burn_sync && !stochastic_sync && smooth_mode; smooth2<=smooth1; smooth3<=smooth2;
        bright1<=vivid_sync || morph_sync || prism_sync || glow_sync; bright2<=bright1; bright3<=bright2;
        preset_phase<=selected_phase3;
        // Choose the blend weight BEFORE its product stage. A scheme mux
        // followed by inverse-weight subtraction and shift/add products was
        // too long at 108 MHz.
        preset_fraction<=look3==0 && !fine_pipe[2] ?
            (smooth3 ? selected_phase3[13:6] : {selected_phase3[13:10],4'd0}) :
            advance3 ? fraction_advanced3 : fraction3;
        vivid1<=bright3;
        preset_rgb<=look3==0 && !fine_pipe[2] ? source3 : zero3 ? 12'd0 : shaded_rgb;
        preset_next<=zero3 ? 12'd0 : shaded_next;
        target4<=zero3 ? 0 : expand_rgb(shaded_target);
        target5<=target4;target6<=target5;target7<=target6;target_contrast7<=color_contrast(target6);
        target8<=brighten7 ? raise_rgb(target7,target_contrast7,fine_pipe[6]) : target7;
        amount4<=morph_on3 ? (morph3[14] ? ~morph3[13:6] : morph3[13:6]) : 8'd0;
        amount5<=amount4; amount6<=amount5; amount7<=amount6; amount8<=amount7;
        blend_r<=ra;blend_g<=ga;blend_b<=ba;
        blend_dr<=palette_product($signed({1'b0,rb})-$signed({1'b0,ra}),amount[3:0]);
        blend_dg<=palette_product($signed({1'b0,gb})-$signed({1'b0,ga}),amount[3:0]);
        blend_db<=palette_product($signed({1'b0,bb})-$signed({1'b0,ba}),amount[3:0]);
        blend_hr<=palette_product($signed({1'b0,rb})-$signed({1'b0,ra}),amount[7:4]);
        blend_hg<=palette_product($signed({1'b0,gb})-$signed({1'b0,ga}),amount[7:4]);
        blend_hb<=palette_product($signed({1'b0,bb})-$signed({1'b0,ba}),amount[7:4]);vivid2<=vivid1;
        blended_rgb<={palette_average(blend_r,palette_delta(blend_dr,blend_hr),fine_pipe[4]),
            palette_average(blend_g,palette_delta(blend_dg,blend_hg),fine_pipe[4]),
            palette_average(blend_b,palette_delta(blend_db,blend_hb),fine_pipe[4])};
        // Contrast selection/subtraction and the saturation add occupy
        // separate stages; Fuzz's small XOR shares the second stage.
        vivid3<=vivid2;output_rgb<=blended_rgb;contrast7<=color_contrast(blended_rgb);brighten7<=vivid3;
        color_rgb<=fuzz_pipe[6] && noise7[4:0]<5 ? raised7 ^ expand_rgb(noise7[15:4]) : raised7;
        if(!active_pipe[7]) begin morph_source<=0;morph_target<=0;morph_amount<=0;morph_fine<=0;end
        else if(tick_pipe[7]) begin
            morph_source<=morph_input(color_rgb,fine_pipe[7]);morph_target<=morph_input(target8,fine_pipe[7]);
            morph_amount<=amount8;morph_fine<=fine_pipe[7];end
        morph_r<=morph_source[3*C_BITS-1:2*C_BITS];morph_g<=morph_source[2*C_BITS-1:C_BITS];morph_b<=morph_source[C_BITS-1:0];
        morph_dr<=morph_product($signed({1'b0,morph_target[3*C_BITS-1:2*C_BITS]})-$signed({1'b0,morph_source[3*C_BITS-1:2*C_BITS]}),morph_amount);
        morph_dg<=morph_product($signed({1'b0,morph_target[2*C_BITS-1:C_BITS]})-$signed({1'b0,morph_source[2*C_BITS-1:C_BITS]}),morph_amount);
        morph_db<=morph_product($signed({1'b0,morph_target[C_BITS-1:0]})-$signed({1'b0,morph_source[C_BITS-1:0]}),morph_amount);
        morph_fine10<=morph_fine;morph_fine11<=morph_fine10;
        morph_rgb<={morph_average(morph_r,morph_dr,morph_fine10),morph_average(morph_g,morph_dg,morph_fine10),morph_average(morph_b,morph_db,morph_fine10)};
        if(!active_pipe[10]) begin echo_count<=0;dispersion_rgb<=0;glow_near<=0;glow_far<=0;glow_output<=0;active_output<=0;output_fine<=0;end
        else if(!prism_pipe[10] && !glow_pipe[10]) begin echo_count<=0; dispersion_rgb<=morph_rgb;
            glow_near<=0;glow_far<=0;glow_output<=0;active_output<=1;output_fine<=morph_fine11;end
        else if(tick_pipe[10]) begin
            // Enhance edges on the current pixel; never substitute a displaced
            // pixel or blank the leading edge of the image.
            dispersion_rgb<=prism_pipe[10] ? {
                prism_edge(morph_rgb[3*C_BITS-1:2*C_BITS],echo_count>=3 ? echo2[3*C_BITS-1:2*C_BITS] : morph_rgb[3*C_BITS-1:2*C_BITS],morph_fine11),
                prism_edge(morph_rgb[2*C_BITS-1:C_BITS],echo_count>=7 ? echo6[2*C_BITS-1:C_BITS] : morph_rgb[2*C_BITS-1:C_BITS],morph_fine11),
                prism_edge(morph_rgb[C_BITS-1:0],echo_count>=11 ? echo10[C_BITS-1:0] : morph_rgb[C_BITS-1:0],morph_fine11)} : morph_rgb;
            glow_near<=echo_count>=8 ? expand_rgb(echo_history[7]) : 0; glow_far<=echo_count>=16 ? expand_rgb(echo_history[15]) : 0;
            glow_output<=glow_pipe[10];active_output<=1;output_fine<=morph_fine11;
            if(echo_count<16) echo_count<=echo_count+1'b1;
            for(history_index=15;history_index>0;history_index=history_index-1) echo_history[history_index]<=echo_history[history_index-1];
            echo_history[0]<=dac_rgb(morph_rgb);
        end
        final_rgb<=!active_output ? 0 : glow_output ? {
            bloom(dispersion_rgb[3*C_BITS-1:2*C_BITS],glow_near[3*C_BITS-1:2*C_BITS],glow_far[3*C_BITS-1:2*C_BITS],output_fine),
            bloom(dispersion_rgb[2*C_BITS-1:C_BITS],glow_near[2*C_BITS-1:C_BITS],glow_far[2*C_BITS-1:C_BITS],output_fine),
            bloom(dispersion_rgb[C_BITS-1:0],glow_near[C_BITS-1:0],glow_far[C_BITS-1:0],output_fine)} : dispersion_rgb;
    end
end
endmodule
