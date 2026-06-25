# Stage board IP into per-IP local directories before adding it to the project.
# Vivado locks XCI files when several IP instances share one source/output folder.

proc add_staged_board_ip {origin_dir project_name ip_dir} {
    set stage_dir "$origin_dir/$project_name/$project_name.srcs/sources_1/ip_staged"
    file delete -force $stage_dir
    file mkdir $stage_dir

    set coe_files [lsort [glob -nocomplain "$ip_dir/*.coe"]]
    set xci_files [lsort [glob -nocomplain "$ip_dir/*.xci"]]

    foreach xci_file $xci_files {
        set ip_name [file rootname [file tail $xci_file]]
        set dst_dir "$stage_dir/$ip_name"
        set dst_xci "$dst_dir/[file tail $xci_file]"

        file mkdir $dst_dir
        file copy -force $xci_file $dst_xci

        foreach coe_file $coe_files {
            file copy -force $coe_file "$dst_dir/[file tail $coe_file]"
        }

        add_files -norecurse -fileset sources_1 $dst_xci
    }

    set ips [get_ips -quiet]
    if {[llength $ips] != 0} {
        upgrade_ip -quiet $ips
        set_property GENERATE_SYNTH_CHECKPOINT false $ips
        generate_target all $ips
    }
}
