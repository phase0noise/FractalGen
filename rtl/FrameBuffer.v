// One 304-M10K memory is shared between the 640x480 indexed preview and
// 640x240 RGB444 render tiles. Normal writes update one byte of a word;
// quality writes update the complete word. The second port runs in the same
// 75 MHz domain and is borrowed by the tile uploader while VGA is blanked.
module FrameBuffer (
    input clk,
    input [15:0] data,
    input [17:0] wraddress,
    input [1:0] byteena,
    input wren,
    input [17:0] rdaddress,
    output [15:0] q
);
altsyncram #(
    .intended_device_family("Cyclone V"), .ram_block_type("M10K"),
    .operation_mode("DUAL_PORT"), .numwords_a(153600), .numwords_b(153600),
    .widthad_a(18), .widthad_b(18), .width_a(16), .width_b(16),
    .width_byteena_a(2), .byte_size(8), .address_reg_b("CLOCK1"),
    .outdata_reg_b("UNREGISTERED"), .outdata_aclr_b("NONE"),
    .address_aclr_b("NONE"), .clock_enable_input_a("BYPASS"),
    .clock_enable_input_b("BYPASS"), .clock_enable_output_b("BYPASS"),
    .power_up_uninitialized("FALSE"), .init_file("framebuffer.mif")
) memory (
    .address_a(wraddress), .address_b(rdaddress), .clock0(clk),
    .clock1(clk), .data_a(data), .wren_a(wren), .q_b(q),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(byteena), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .data_b(16'd0), .wren_b(1'b0),
    .rden_a(1'b1), .rden_b(1'b1), .q_a(), .eccstatus()
);
endmodule
