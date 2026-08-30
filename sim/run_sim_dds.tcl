# Simulation with the regenerated 7-series DDS compiler in the loop. Uses a
# Vivado project so the tool compiles the IP's simulation sources for us --
# xvlog/xelab alone cannot resolve dds_compiler_0 without them.
#
#   vivado -mode batch -source sim/run_sim_dds.tcl
# expects QICK_ROOT in the environment.

set qick $env(QICK_ROOT)
set here [file normalize [file dirname [info script]]]
set work $here/work/dds
file mkdir $work

create_project -force ddssim $work/proj -part xc7z020clg484-1

# Same customisation as syn/cfg/signal_gen_v6_ndds1.tcl, so synthesis and
# simulation see the same DDS.
create_ip -name dds_compiler -vendor xilinx.com -library ip -module_name dds_compiler_0

# Apply one at a time and read each back. set_property -dict swallows rejected
# parameters silently: Phase_Offset was dropped that way, and the per-lane phase
# offsets in dds_ctrl are useless without it. Latency also matters -- signal_gen.v
# is written against latency 10 ("// Latency: 10") with matching latency_reg
# delays, and Auto picks 9 on 7-series.
set want [list \
   Parameter_Entry              System_Parameters \
   PartsPresent                 Phase_Generator_and_SIN_COS_LUT \
   DDS_Clock_Rate               122.88 \
   Output_Width                 16 \
   Spurious_Free_Dynamic_Range  96 \
   Frequency_Resolution         0.06 \
   Phase_Increment              Streaming \
   Phase_Offset                 Streaming \
   Resync                       true \
   Output_Selection             Sine_and_Cosine \
   Latency_Configuration        Configurable \
   Latency                      10 ]

foreach {k v} $want {
   if {[catch { set_property CONFIG.$k $v [get_ips dds_compiler_0] } err]} {
      puts "DDSCFG REJECTED $k=$v : $err"
   }
}
puts "--- DDS parameter readback ---"
foreach {k v} $want {
   set got [get_property CONFIG.$k [get_ips dds_compiler_0]]
   if {$got ne $v} { puts "DDSCFG MISMATCH $k: wanted $v got $got" } \
   else            { puts "DDSCFG ok       $k = $got" }
}

generate_target {simulation} [get_ips dds_compiler_0]

set SG $qick/firmware/ip/axis_signal_gen_v6/src
add_files -norecurse [list \
  $qick/firmware/hdl/fifo_xpm.sv \
  $SG/ctrl_sg_v6.sv \
  $SG/latency_reg.v \
  $SG/signal_gen.v ]
add_files -fileset sim_1 -norecurse $here/tb_ndds_complex.sv
catch { set_property file_type {SystemVerilog} [get_files *.sv] }

set_property top tb_ndds_complex [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# Probe the truncation hypothesis: a PINC that divides evenly should not suffer
# the base-phase DSP rounding, so the two configurations should agree exactly.
set pincs [list 8000000 1048576]
foreach pv $pincs {
   set_property -name {xsim.simulate.xsim.more_options} \
      -value "-testplusarg PINC=$pv" -objects [get_filesets sim_1]
   puts "######## PINC = $pv ########"
   launch_simulation
   close_sim
}
puts "SIM_LAUNCHED"
