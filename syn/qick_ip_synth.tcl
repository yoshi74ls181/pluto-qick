# Out-of-context synthesis of a single QICK IP for a 7-series part, to answer
# "does it build, and what does it cost?" without a full block design.
#
#   vivado -mode batch -source syn/qick_ip_synth.tcl -tclargs <cfg.tcl>
#
# The config file sets: qick_root, part, top, src_dirs, generics, ip_recreate,
# and optionally clocks. See syn/cfg/*.tcl.

set cfg [lindex $argv 0]
if {![file exists $cfg]} { puts "ERROR: no such config: $cfg"; exit 1 }

# Exposed to configs so they can reference repo paths without guessing at
# `info script`, which inside a sourced config points at the config itself.
set repo_root [file normalize [file dirname [info script]]/..]

# Defaults, overridable by the config.
set part        xc7z020clg484-1
set generics    {}
set clocks      {}
set ip_recreate {}
set extra_files {}
source $cfg

set work [file normalize [file dirname [info script]]/work/$name]
file mkdir $work
create_project -force $name $work/proj -part $part

# Xilinx IP that QICK ships pre-generated for RFSoC parts must be recreated for
# the target device. Each entry: {module_name ip_name {CONFIG.k v ...}}
foreach ip $ip_recreate {
    lassign $ip modname ipname cfgdict
    create_ip -name $ipname -vendor xilinx.com -library ip -module_name $modname
    if {[llength $cfgdict]} {
        # tolerate parameters the 7-series variant computes rather than accepts
        catch { set_property -dict $cfgdict [get_ips $modname] } msg
        if {[info exists msg] && $msg ne ""} { puts "NOTE ($modname): $msg" }
    }
    generate_target {synthesis} [get_ips $modname]
    synth_ip [get_ips $modname]
}

foreach d $src_dirs {
    foreach f [glob -nocomplain $d/*.v $d/*.sv $d/*.vhd] { add_files -norecurse $f }
}
foreach f $extra_files { add_files -norecurse $f }
catch { set_property file_type {SystemVerilog} [get_files *.sv] }

set_property top $top [current_fileset]
if {[llength $generics]} { set_property generic $generics [current_fileset] }

if {[llength $clocks]} {
    set xdc $work/clocks.xdc
    set fh [open $xdc w]
    foreach c $clocks { puts $fh $c }
    close $fh
    add_files -fileset constrs_1 $xdc
}

synth_design -mode out_of_context -flatten_hierarchy rebuilt

report_utilization -file $work/utilization.rpt
puts "=== $name on $part ==="
foreach pat {"Slice LUTs" "Slice Registers" "Block RAM Tile" "DSPs"} {
    set fh [open $work/utilization.rpt r]; set txt [read $fh]; close $fh
    foreach line [split $txt "\n"] {
        if {[string match "*$pat*" $line] && [string match "|*" $line]} { puts "  $line"; break }
    }
}
if {[llength $clocks]} {
    report_timing_summary -file $work/timing.rpt
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  WNS (post-synth) = $wns ns"
}
puts "SYNTH_OK $name"
