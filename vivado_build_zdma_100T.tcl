set origin_dir [file normalize [file dirname [info script]]]
if {[llength [get_projects -quiet]] == 0} {
    open_project "$origin_dir/pcileech_zdma_100t_nvme/pcileech_zdma_100t_nvme.xpr"
}

launch_runs -jobs 6 synth_1
wait_on_run synth_1
launch_runs -jobs 6 impl_1 -to_step write_bitstream
wait_on_run impl_1
open_run impl_1
report_utilization -file "$origin_dir/pcileech_zdma_100t_nvme_utilization.rpt"
report_timing_summary -file "$origin_dir/pcileech_zdma_100t_nvme_timing_summary.rpt"
file copy -force "$origin_dir/pcileech_zdma_100t_nvme/pcileech_zdma_100t_nvme.runs/impl_1/pcileech_tbx4_100t_top.bin" "$origin_dir/pcileech_zdma_100t_nvme.bin"
