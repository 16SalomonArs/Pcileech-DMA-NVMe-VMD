set origin_dir [file normalize [file dirname [info script]]]
source "$origin_dir/vivado_ip_import.tcl"
build_bitstream_project $origin_dir pcileech_captaindma_100t_nvme pcileech_100t484_x1_top pcileech_captaindma_100t_nvme.bin
exit 0
