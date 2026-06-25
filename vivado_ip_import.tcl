proc clean_project_tree {origin_dir project_name} {
    set root [file normalize $origin_dir]
    set root_prefix "$root/"
    if {[llength [get_projects -quiet]] != 0} {
        close_project
    }
    foreach path [list \
        "$origin_dir/$project_name" \
        "$origin_dir/$project_name.cache" \
        "$origin_dir/$project_name.gen" \
        "$origin_dir/$project_name.hw" \
        "$origin_dir/$project_name.ip_user_files" \
        "$origin_dir/$project_name.runs" \
        "$origin_dir/$project_name.sim" \
        "$origin_dir/.Xil" \
    ] {
        set normalized [file normalize $path]
        if {($normalized ne $root) && ([string first $root_prefix $normalized] != 0)} {
            error "Refusing to clean path outside project root: $normalized"
        }
        if {[file exists $normalized]} {
            file delete -force $normalized
        }
    }
}

proc add_staged_board_ip {origin_dir project_name ip_dir} {
    set stage_dir "$origin_dir/$project_name/$project_name.srcs/sources_1/ip_staged"
    file delete -force $stage_dir
    file mkdir $stage_dir

    set coe_files [lsort [glob -nocomplain "$ip_dir/*.coe"]]
    set xci_files [lsort [glob -nocomplain "$ip_dir/*.xci"]]
    set staged_xci_files [list]

    foreach xci_file $xci_files {
        set ip_name [file rootname [file tail $xci_file]]
        set dst_dir "$stage_dir/$ip_name"
        set dst_xci "$dst_dir/[file tail $xci_file]"

        file mkdir $dst_dir
        file copy -force $xci_file $dst_xci

        foreach coe_file $coe_files {
            file copy -force $coe_file "$dst_dir/[file tail $coe_file]"
        }

        lappend staged_xci_files $dst_xci
        import_ip -files $dst_xci
    }

    set ips [get_ips -quiet]
    if {[llength $ips] != 0} {
        upgrade_ip -quiet $ips
        foreach staged_xci_file $staged_xci_files {
            set ip_file [get_files -quiet $staged_xci_file]
            if {[llength $ip_file] != 0} {
                set_property GENERATE_SYNTH_CHECKPOINT true $ip_file
            }
        }
        generate_target all $ips
        synth_ip $ips
    }
}

proc open_clean_project {xpr_file} {
    if {[llength [get_projects -quiet]] != 0} {
        close_project
    }
    if {![file exists $xpr_file]} {
        error "Project not found: $xpr_file"
    }
    open_project $xpr_file
}

proc wait_run_or_error {run_name} {
    wait_on_run $run_name
    set run [get_runs $run_name]
    set progress [get_property PROGRESS $run]
    set status [get_property STATUS $run]
    if {$progress ne "100%" || [string match -nocase "*fail*" $status] || [string match -nocase "*error*" $status]} {
        error "$run_name failed or did not complete: $status ($progress)"
    }
}

proc build_bitstream_project {origin_dir project_name top_name bin_name} {
    open_clean_project "$origin_dir/$project_name/$project_name.xpr"

    reset_run synth_1
    reset_run impl_1
    launch_runs synth_1 -jobs 6
    wait_run_or_error synth_1

    launch_runs impl_1 -to_step write_bitstream -jobs 6
    wait_run_or_error impl_1

    open_run impl_1
    report_utilization -file "$origin_dir/${project_name}_utilization.rpt"
    report_timing_summary -file "$origin_dir/${project_name}_timing_summary.rpt"

    set src_bin "$origin_dir/$project_name/$project_name.runs/impl_1/$top_name.bin"
    if {![file exists $src_bin]} {
        error "Bitstream bin not found: $src_bin"
    }
    file copy -force $src_bin "$origin_dir/$bin_name"
}
