// Adapted from DE0-CV DOOM's rtl/peripherals/sd_spi.v.
`default_nettype none

// Byte-oriented SPI mode-0 master for the DE0-CV microSD socket. The caller
// owns chip select and starts one full-duplex transfer at a time. clk_div is
// the number of system-clock cycles per SCLK half-period (values below two
// are clamped to two).
module sd_spi (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cs_n,
    input  wire [15:0] clk_div,
    input  wire        start,
    input  wire [7:0]  tx_data,
    output reg  [7:0]  rx_data,
    output reg         busy,
    output reg         done,
    output wire        spi_cs_n,
    output reg         spi_clk,
    output wire        spi_mosi,
    input  wire        spi_miso
);
    reg [15:0] divider_count;
    reg [15:0] active_divider;
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;
    reg [2:0] bit_count;

    assign spi_cs_n = cs_n;
    assign spi_mosi = busy ? tx_shift[7] : 1'b1;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            divider_count <= 16'd0;
            active_divider <= 16'd94;
            tx_shift <= 8'hff;
            rx_shift <= 8'd0;
            rx_data <= 8'hff;
            bit_count <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
            spi_clk <= 1'b0;
        end else begin
            if (start && !busy) begin
                active_divider <= (clk_div < 16'd2) ? 16'd2 : clk_div;
                divider_count <= ((clk_div < 16'd2) ? 16'd2 : clk_div) - 1'b1;
                tx_shift <= tx_data;
                rx_shift <= 8'd0;
                bit_count <= 3'd0;
                busy <= 1'b1;
                done <= 1'b0;
                spi_clk <= 1'b0;
            end else if (busy) begin
                if (divider_count != 0) begin
                    divider_count <= divider_count - 1'b1;
                end else begin
                    divider_count <= active_divider - 1'b1;
                    if (!spi_clk) begin
                        // SD samples MOSI and changes MISO around rising and
                        // falling edges respectively in SPI mode 0.
                        spi_clk <= 1'b1;
                        rx_shift <= {rx_shift[6:0], spi_miso};
                    end else begin
                        spi_clk <= 1'b0;
                        if (bit_count == 3'd7) begin
                            rx_data <= rx_shift;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                            tx_shift <= {tx_shift[6:0], 1'b1};
                        end
                    end
                end
            end else begin
                spi_clk <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
