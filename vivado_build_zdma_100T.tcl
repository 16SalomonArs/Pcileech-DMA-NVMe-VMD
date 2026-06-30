set origin_dir [file normalize [file dirname [info script]]]
source "$origin_dir/vivado_ip_import.tcl"
build_bitstream_project $origin_dir pcileech_zdma_100t_nvme pcileech_tbx4_100t_top pcileech_zdma_100t_nvme.bin
exit 0
