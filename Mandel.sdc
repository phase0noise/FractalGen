create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_pll_clocks

# Board controls and PS/2 enter through synchronizers. Reset release is
# synchronized independently after each PLL locks.
set_false_path -from [get_ports {SW[*] KEY[*] PS2_CLK PS2_DAT}]
# SPI runs from divided clock enables in the 75 MHz domain, as in DOOM.
set_false_path -from [get_ports {SD_DATA[0]}]
set_false_path -to [get_ports {SD_CLK SD_CMD SD_DATA[3]}]
# Scanline requests use a held bus with toggle/acknowledgement; only the unused
# line-buffer bank is written. The RAM itself provides the mixed-clock port.
set_clock_groups -asynchronous -group [get_clocks {*system_pll*}] -group [get_clocks {*video_pll*}]
set_false_path -from [get_clocks {CLOCK_50}] -to [get_registers {*u1|*_meta* *preview_effects|*_meta* *effects|*_meta* *storage|corruption_meta *screenshot|keys_meta* request_meta}]
set_false_path -to [get_registers {done_meta underflow_meta screenshot_meta error_meta}]

# IS42S16320D-6 at 75 MHz, CL3. Propagate the actual half-cycle PLL clock
# through the board clock pin so setup/hold include clock insertion delay.
# The chip's tAC/tOH and tSU/tH limits come from the DOOM reference.
create_generated_clock -name SDRAM_EXT -source [get_pins {clocks|system_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] -divide_by 1 [get_ports {DRAM_CLK}]
derive_clock_uncertainty
set_input_delay -clock SDRAM_EXT -max 5.4 [get_ports {DRAM_DQ[*]}]
set_input_delay -clock SDRAM_EXT -min 2.5 [get_ports {DRAM_DQ[*]}]
set_output_delay -clock SDRAM_EXT -max 1.5 [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_DQ[*] DRAM_LDQM DRAM_RAS_N DRAM_UDQM DRAM_WE_N}]
set_output_delay -clock SDRAM_EXT -min -0.8 [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_DQ[*] DRAM_LDQM DRAM_RAS_N DRAM_UDQM DRAM_WE_N}]
set_max_delay 10.0 -to [get_ports {DRAM_CLK}]
set_min_delay 0.0 -to [get_ports {DRAM_CLK}]
set_false_path -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS LEDR[*]}]
