# Simulate the tProc descriptor path: sg_translator -> axis_signal_gen_v6.
#   vivado -mode batch -source sim/run_sim_sgchain.tcl
# expects QICK_ROOT in the environment.

set qick $env(QICK_ROOT)
set here [file normalize [file dirname [info script]]]
set work $here/work/sgchain
file delete -force $work
file mkdir $work

create_project -force sgchain $work/proj -part xc7z020clg400-2

set SG $qick/firmware/ip/axis_signal_gen_v6/src
set TR $qick/firmware/ip/qick_sg_translator/src

import_ip $SG/dds_compiler_0/dds_compiler_0.xci -name dds_compiler_0
upgrade_ip [get_ips dds_compiler_0]
puts "dds locked after upgrade: [get_property IS_LOCKED [get_ips dds_compiler_0]]"
generate_target all [get_ips dds_compiler_0]

add_files -norecurse [list \
  $qick/firmware/hdl/fifo_xpm.sv \
  $qick/firmware/hdl/bram_dp_xpm.sv \
  $SG/ctrl_sg_v6.sv $SG/latency_reg.v $SG/signal_gen.v $SG/signal_gen_top.v \
  $SG/axis_signal_gen_v6.v $SG/data_writer.vhd $SG/axi_slv_sg_v6.vhd \
  $SG/synchronizer_n.vhd \
  $TR/sg_translator.v ]
add_files -fileset sim_1 -norecurse $here/tb_sg_chain.sv
catch { set_property file_type {SystemVerilog} [get_files *.sv] }
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property top tb_sg_chain [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation
puts "SIM_LAUNCHED"
