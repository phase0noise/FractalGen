package require ::quartus::project
package require ::quartus::sta
file mkdir output_files/timing
project_open Mandel
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 12 -detail full_path -file output_files/timing/setup_paths.txt
report_timing -setup -to [get_ports {DRAM_DQ[*] DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_LDQM DRAM_RAS_N DRAM_UDQM DRAM_WE_N}] -npaths 4 -detail full_path -file output_files/timing/sdram_output_paths.txt
report_timing -setup -from [get_ports {DRAM_DQ[*]}] -npaths 4 -detail full_path -file output_files/timing/sdram_input_paths.txt
report_timing -setup -to_clock [get_clocks {*video_pll*divclk}] -npaths 4 -detail full_path -file output_files/timing/video_paths.txt
report_timing -setup -to_clock [get_clocks {CLOCK_50}] -npaths 4 -detail full_path -file output_files/timing/control_paths.txt
report_timing -setup -to [get_registers {*u1|*}] -npaths 2 -detail full_path -file output_files/timing/coordinate_paths.txt
report_timing -setup -to [get_registers {*eng*worker*}] -npaths 2 -detail full_path -file output_files/timing/worker_paths.txt
report_timing -setup -to [get_registers {commit_* buffer_*}] -npaths 2 -detail full_path -file output_files/timing/commit_paths.txt
report_timing -setup -to [get_registers {*preview|*}] -npaths 2 -detail full_path -file output_files/timing/preview_paths.txt
report_timing -setup -to [get_registers {*storage|*}] -npaths 2 -detail full_path -file output_files/timing/transfer_paths.txt
foreach stage {palette_base3 palette_advanced3 fraction3 preset_rgb preset_fraction blend_dr blended_rgb contrast7 color_rgb target_contrast7 target8 morph_source morph_dr morph_rgb dispersion_rgb final_rgb} {
    set stage_registers [get_registers [list "*HDColorEffects:effects|${stage}*"]]
    if {[get_collection_size $stage_registers] > 0} {
        report_timing -setup -to $stage_registers -npaths 1 -detail full_path -file "output_files/timing/shader_${stage}.txt"
    }
}
report_ucp -file output_files/timing/unconstrained_paths.txt
set_operating_conditions -model slow -temperature 0 -voltage 1100
update_timing_netlist
report_timing -setup -npaths 4 -detail full_path -file output_files/timing/cold_setup_paths.txt
report_timing -setup -to_clock [get_clocks {*system_pll*divclk}] -npaths 4 -detail full_path -file output_files/timing/cold_system_paths.txt
delete_timing_netlist
project_close
