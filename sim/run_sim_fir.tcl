# Simulate axis_readout_v2's down_conversion_fir with the regenerated 1-lane FIR.
#   vivado -mode batch -source sim/run_sim_fir.tcl
# expects QICK_ROOT in the environment.
#
# Goes through a project so Vivado compiles fir_compiler_0's and dds_compiler_0's
# simulation models. Both .xci were customised for xczu49dr, so a standalone
# import lands locked and upgrade_ip is needed to retarget them.

set qick $env(QICK_ROOT)
set here [file normalize [file dirname [info script]]]
set work $here/work/fir
file delete -force $work
file mkdir $work

create_project -force firsim $work/proj -part xc7z020clg400-2

set RO $qick/firmware/ip/axis_readout_v2/src
foreach ip {dds_compiler_0 fir_compiler_0} {
    import_ip $RO/$ip/$ip.xci -name $ip
    upgrade_ip [get_ips $ip]
    puts "IP $ip locked after upgrade: [get_property IS_LOCKED [get_ips $ip]]"
}
# The FIR reads its coefficients from the relative path ../fir.coe, so the file
# has to be staged next to the imported IP *before* generation, not after.
set firdir [file dirname [get_property IP_FILE [get_ips fir_compiler_0]]]
file copy -force $RO/fir.coe [file dirname $firdir]/fir.coe
puts "staged coe at [file dirname $firdir]/fir.coe"

foreach ip {dds_compiler_0 fir_compiler_0} {
    generate_target all [get_ips $ip]
}

add_files -norecurse [list $RO/ctrl.sv $RO/down_conversion.v $RO/down_conversion_fir.v]
add_files -fileset sim_1 -norecurse $here/tb_fir_decim.sv
catch { set_property file_type {SystemVerilog} [get_files *.sv] }
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property top tb_fir_decim [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation
puts "SIM_LAUNCHED"
