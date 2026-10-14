// Average four RGB888 samples and round once to the nearest RGB444 value.
// A DAC step is 17/255 of full scale: one four-sample step is exactly 68.
// Equal sample sums always produce equal colors, independent of location.
// Never average palette indices: doing so invents colors at black boundaries
// and at the palette's wrap point.
module SupersampleColor (
    input [9:0] red_sum,
    input [9:0] green_sum,
    input [9:0] blue_sum,
    input [9:0] pixel_x,
    input [8:0] pixel_y,
    output [11:0] rgb
);
function [3:0] quantize;
    input [9:0] sum;
    begin
        quantize = ({1'b0,sum} + 11'd34) / 11'd68;
    end
endfunction
assign rgb = {quantize(red_sum), quantize(green_sum), quantize(blue_sum)};
endmodule
