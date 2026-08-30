# Simulate axis_readout_v2's down_conversion with the complex-input path.
#   vivado -mode batch -source sim/run_sim_readout.tcl
# expects QICK_ROOT in the environment.
#
# Goes through a project so Vivado compiles dds_compiler_0's simulation model;
# xvlog/xelab alone cannot resolve it. The DDS is the one packaged with the IP,
# retargeted to 7-series by Vivado, so the sim sees exactly what the block
# design builds.

set qick $env(QICK_ROOT)
set here [file normalize [file dirname [info script]]]
set work $here/work/readout
file delete -force $work
file mkdir $work

create_project -force rosim $work/proj -part xc7z020clg400-2

set RO $qick/firmware/ip/axis_readout_v2/src
import_ip $RO/dds_compiler_0/dds_compiler_0.xci -name dds_compiler_0
# The .xci was customised for xczu49dr, so a standalone import lands locked.
# upgrade_ip retargets it to the project part -- the BD flow does this itself
# when the IP is pulled in as a subcore.
upgrade_ip [get_ips dds_compiler_0]
puts "   DDS locked after upgrade: [get_property IS_LOCKED [get_ips dds_compiler_0]]"
generate_target all [get_ips dds_compiler_0]
export_ip_user_files -of_objects [get_ips dds_compiler_0] -no_script -force -quiet

add_files -norecurse [list $RO/ctrl.sv $RO/down_conversion.v]
add_files -fileset sim_1 -norecurse $here/tb_readout_complex.sv
catch { set_property file_type {SystemVerilog} [get_files *.sv] }

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property top tb_readout_complex [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation
puts "SIM_LAUNCHED"
