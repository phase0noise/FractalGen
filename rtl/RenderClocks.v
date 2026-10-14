// 75 MHz renderer/SDRAM clocks, with a half-cycle SDRAM phase shift.
// The HD pixel clock runs at 108 MHz.
module RenderClocks (
    input refclk, input reset,
    output engine_clk, output sdram_clk, output pixel_hd_clk,
    output engine_locked, output pixel_locked
);
wire [1:0] system_clocks;
wire [0:0] video_clock;
altera_pll #(
    .fractional_vco_multiplier("false"), .reference_clock_frequency("50.0 MHz"),
    .operation_mode("normal"), .number_of_clocks(2),
    .output_clock_frequency0("75.000000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
    .output_clock_frequency1("75.000000 MHz"), .phase_shift1("-6667 ps"), .duty_cycle1(50),
    .pll_type("General"), .pll_subtype("General")
) system_pll (
    .refclk(refclk), .rst(reset), .outclk(system_clocks), .locked(engine_locked),
    .fboutclk(), .fbclk(1'b0)
);
altera_pll #(
    .fractional_vco_multiplier("false"), .reference_clock_frequency("75.0 MHz"),
    .operation_mode("normal"), .number_of_clocks(1),
    .output_clock_frequency0("108.000000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
    .pll_type("General"), .pll_subtype("General")
) video_pll (
    .refclk(system_clocks[0]), .rst(reset), .outclk(video_clock), .locked(pixel_locked),
    .fboutclk(), .fbclk(1'b0)
);
assign engine_clk = system_clocks[0];
assign sdram_clk = system_clocks[1];
assign pixel_hd_clk = video_clock[0];
endmodule
