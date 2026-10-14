// Purpose-built procedural palettes.  This replaces the photograph-derived
// palette ROM, gives predictable Mandelbrot bands, and costs no block RAM.

module ColorMapper (
    input  [7:0] index,
    input  [1:0] palette,
    input  [7:0] phase,
    output reg [23:0] bgr
);

reg [7:0] p;
reg [7:0] r, g, b;
integer s;

function [7:0] sat8;
    input integer value;
    begin
        if (value < 0)
            sat8 = 8'd0;
        else if (value > 255)
            sat8 = 8'd255;
        else
            sat8 = value[7:0];
    end
endfunction

function [7:0] triangle;
    input [7:0] value;
    begin
        if (value[7])
            triangle = 8'd255 - ((value - 8'd128) << 1);
        else
            triangle = value << 1;
    end
endfunction

always @(*) begin
    // 8'hfe is the legacy engine's maximum-iteration result.
    if (index >= 8'hfe) begin
        r = 8'd0;
        g = 8'd0;
        b = 8'd0;
    end else begin
        p = index + phase;
        case (palette)
            2'd0: begin
                // Deep ocean -> electric cyan -> gold -> white.
                if (p < 8'd64) begin
                    s = p;
                    r = 8'd0;
                    g = sat8(s);
                    b = sat8(64 + 3*s);
                end else if (p < 8'd128) begin
                    s = p - 64;
                    r = 8'd0;
                    g = sat8(64 + 3*s);
                    b = 8'd255;
                end else if (p < 8'd192) begin
                    s = p - 128;
                    r = sat8(4*s);
                    g = sat8(255 - s - (s >> 1));
                    b = sat8(255 - 4*s);
                end else begin
                    s = p - 192;
                    r = 8'd255;
                    g = sat8(160 + s + (s >> 1));
                    b = sat8(4*s);
                end
            end

            2'd1: begin
                // Hot ember palette.
                s = p;
                r = sat8(2*s);
                g = (p < 8'd128) ? sat8(s) : sat8(2*(s - 128));
                b = (p < 8'd192) ? 8'd0 : sat8(4*(s - 192));
            end

            2'd2: begin
                // Smooth cyclic neon palette.
                r = triangle(p + 8'd85);
                g = triangle(p);
                b = triangle(p - 8'd85);
            end

            default: begin
                // Electric blue / violet. Keep green low so this remains a
                // colored palette, including when the phase is animated.
                r = triangle(p + 8'd64);
                g = triangle(p) >> 2;
                b = sat8(96 + (triangle(p - 8'd32) >> 1));
            end
        endcase
    end
    bgr = {b, g, r};
end

endmodule
