proc vivado_build_root {origin_dir} {
    if {[info exists ::env(NVME_VIVADO_BUILD_ROOT)] && $::env(NVME_VIVADO_BUILD_ROOT) ne ""} {
        return [file normalize $::env(NVME_VIVADO_BUILD_ROOT)]
    }
    set origin_path [file normalize $origin_dir]
    set volume [lindex [file split $origin_path] 0]
    if {![regexp {^[A-Za-z]:[/\\]?$} $volume]} {
        return [file normalize [file join [pwd] nvme_vmd_build]]
    }
    return [file normalize [file join $volume nvme_vmd_build]]
}

proc vivado_project_dir {origin_dir project_name} {
    return [file normalize [file join [vivado_build_root $origin_dir] $project_name]]
}

proc vivado_job_count {} {
    if {[info exists ::env(NVME_VIVADO_JOBS)] && [string is integer -strict $::env(NVME_VIVADO_JOBS)] && $::env(NVME_VIVADO_JOBS) > 0} {
        return $::env(NVME_VIVADO_JOBS)
    }
    if {[info exists ::env(NUMBER_OF_PROCESSORS)] && [string is integer -strict $::env(NUMBER_OF_PROCESSORS)] && $::env(NUMBER_OF_PROCESSORS) > 0} {
        return $::env(NUMBER_OF_PROCESSORS)
    }
    return 8
}

proc vivado_thread_count {} {
    set jobs [vivado_job_count]
    if {$jobs > 8} {
        return 8
    }
    return $jobs
}

proc apply_vivado_runtime_limits {} {
    set_param general.maxThreads [vivado_thread_count]
}

proc delete_tree_under {base_dir path} {
    set base [file normalize $base_dir]
    set normalized [file normalize $path]
    set base_prefix "$base/"
    if {($normalized ne $base) && ([string first $base_prefix $normalized] != 0)} {
        error "Refusing to clean path outside target root: $normalized"
    }
    if {[file exists $normalized]} {
        file delete -force $normalized
    }
}

proc clean_project_tree {origin_dir project_name} {
    set root [file normalize $origin_dir]
    set build_root [vivado_build_root $origin_dir]
    if {[llength [get_projects -quiet]] != 0} {
        close_project
    }
    file mkdir $build_root
    foreach path [list \
        [vivado_project_dir $origin_dir $project_name] \
        "$build_root/.Xil" \
    ] {
        delete_tree_under $build_root $path
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
        delete_tree_under $root $path
    }
}

proc add_staged_board_ip {origin_dir project_name ip_dir {skip_ip_names {}}} {
    set project_dir [vivado_project_dir $origin_dir $project_name]
    set stage_dir "$project_dir/$project_name.srcs/sources_1/ip_staged"
    file delete -force $stage_dir
    file mkdir $stage_dir

    set coe_files [lsort [glob -nocomplain "$ip_dir/*.coe"]]
    set xci_files [lsort [glob -nocomplain "$ip_dir/*.xci"]]
    set staged_xci_files [list]
    if {[llength $xci_files] == 0} {
        error "No XCI files found in $ip_dir"
    }

    foreach xci_file $xci_files {
        set ip_name [file rootname [file tail $xci_file]]
        if {[lsearch -exact $skip_ip_names $ip_name] >= 0} {
            puts "Skipping board IP $ip_name"
            continue
        }
        set dst_dir "$stage_dir/$ip_name"
        set dst_xci "$dst_dir/[file tail $xci_file]"

        file mkdir $dst_dir
        file copy -force $xci_file $dst_xci
        lappend staged_xci_files [file normalize $dst_xci]

        foreach coe_file $coe_files {
            file copy -force $coe_file "$dst_dir/[file tail $coe_file]"
        }

        import_ip -files $dst_xci
    }

    set ips [get_ips -quiet]
    if {[llength $ips] != 0} {
        upgrade_ip -quiet $ips
        foreach ip $ips {
            set ip_files [get_files -quiet -all -of_objects $ip]
            if {[llength $ip_files] == 0} {
                set ip_name [get_property NAME $ip]
                foreach staged_xci $staged_xci_files {
                    if {[file rootname [file tail $staged_xci]] eq $ip_name} {
                        foreach candidate [get_files -quiet -all $staged_xci] {
                            lappend ip_files $candidate
                        }
                    }
                }
            }
            set checkpoint_files 0
            foreach ip_file $ip_files {
                if {[string equal -nocase [file extension $ip_file] ".xci"]} {
                    set_property GENERATE_SYNTH_CHECKPOINT true $ip_file
                    incr checkpoint_files
                }
            }
            if {$checkpoint_files == 0} {
                puts "WARNING: no XCI file object found for IP [get_property NAME $ip]; using Vivado default checkpoint handling"
            }
        }
        generate_target all $ips
        foreach xdc_file [get_files -quiet -all -regexp {.*_in_context\.xdc$}] {
            set_property USED_IN_SYNTHESIS false $xdc_file
            set_property USED_IN_IMPLEMENTATION false $xdc_file
        }
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
    set project_dir [vivado_project_dir $origin_dir $project_name]
    apply_vivado_runtime_limits
    open_clean_project "$project_dir/$project_name.xpr"
    set jobs [vivado_job_count]

    reset_run synth_1
    reset_run impl_1
    launch_runs synth_1 -jobs $jobs
    wait_run_or_error synth_1

    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_run_or_error impl_1

    open_run impl_1
    report_utilization -file "$origin_dir/${project_name}_utilization.rpt"
    report_timing_summary -file "$origin_dir/${project_name}_timing_summary.rpt"

    set src_bin "$project_dir/$project_name.runs/impl_1/$top_name.bin"
    if {![file exists $src_bin]} {
        error "Bitstream bin not found: $src_bin"
    }
    file copy -force $src_bin "$origin_dir/$bin_name"
}
