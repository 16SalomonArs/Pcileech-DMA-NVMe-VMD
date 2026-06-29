# Generate the CaptainDMA 75T NVMe disk firmware project.
# Run from Vivado Tcl Shell:
#   source vivado_generate_project_captain_75T.tcl -notrace

set origin_dir [file normalize [file dirname [info script]]]
source "$origin_dir/vivado_ip_import.tcl"
set project_name "pcileech_captaindma_75t_nvme"
set part_name "xc7a75tfgg484-2"
set ip_dir "$origin_dir/ip_captaindma_75t"

clean_project_tree $origin_dir $project_name
create_project -force $project_name "$origin_dir/$project_name" -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property verilog_define {NVME_PROFILE_75T} [get_filesets sources_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_high [get_runs synth_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE ExploreArea [get_runs impl_1]

set sv_files [list \
    "$origin_dir/src/pcileech_header.svh" \
    "$origin_dir/src/nvme_board_profile.svh" \
    "$origin_dir/src/pcileech_com.sv" \
    "$origin_dir/src/pcileech_fifo.sv" \
    "$origin_dir/src/pcileech_ft601.sv" \
    "$origin_dir/src/pcileech_mux.sv" \
    "$origin_dir/src/pcileech_pcie_a7.sv" \
    "$origin_dir/src/pcileech_pcie_cfg_a7.sv" \
    "$origin_dir/src/pcileech_pcie_tlp_a7.sv" \
    "$origin_dir/src/pcileech_nvme_dma_disk.sv" \
    "$origin_dir/src/pcileech_tlps128_bar_controller.sv" \
    "$origin_dir/src/pcileech_tlps128_cfgspace_shadow.sv" \
    "$origin_dir/src/pcileech_75t484_x1_top.sv" \
]
add_files -norecurse -fileset sources_1 $sv_files
set_property file_type "SystemVerilog" [get_files -regexp {.*\.sv$}]
set_property file_type "Verilog Header" [get_files "pcileech_header.svh"]
set_property file_type "Verilog Header" [get_files "nvme_board_profile.svh"]

add_staged_board_ip $origin_dir $project_name $ip_dir
add_files -fileset constrs_1 "$origin_dir/src/pcileech_75t484_x1_captaindma_75t.xdc"

set_property top pcileech_75t484_x1_top [get_filesets sources_1]
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]
update_compile_order -fileset sources_1

puts "Created $project_name for $part_name"
