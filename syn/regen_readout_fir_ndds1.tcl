# Regenerate axis_readout_v2's fir_compiler_0 for N_DDS=1 and install it into the
# QICK tree, replacing the 8-lane version QICK ships.
#
#   export QICK_ROOT=$PWD/third_party/qick
#   vivado -mode batch -source syn/regen_readout_fir_ndds1.tcl
#
# The filter itself is unchanged: same ../fir.coe (121 taps), same decimate-by-8.
# Only the hardware parallelism moves. The FIR is a super-sample-rate decimator
# whose input width is Number_Paths * Data_Width * (Decimation_Rate/SamplePeriod):
#
#   SamplePeriod 1  ->  8 samples/clock in, 256-bit s_axis   (QICK, RFSoC)
#   SamplePeriod 8  ->  1 sample/clock  in,  32-bit s_axis   (E200, 122.88 MHz)
#
# Why this is a script and not a patch: the .xci is a generated artifact, and the
# 2022.1 output is XML where QICK's was JSON, so a diff would be a 58 kB rewrite
# that says nothing about intent. These parameters are the intent.
#
# Two traps worth knowing:
#   - SamplePeriod is read-only on an existing IP, so the IP must be created
#     fresh rather than edited via read_ip/import_ip.
#   - Coefficient_File and CoefficientSource cannot be set one at a time:
#     setting CoefficientSource to COE_File validates that a file is already
#     loaded, and setting Coefficient_File alone is silently ignored. They have
#     to go in one atomic set_property -dict.

set qick $env(QICK_ROOT)
set src  $qick/firmware/ip/axis_readout_v2/src
set work [file normalize [file dirname [info script]]]/work/firgen
file delete -force $work
file mkdir $work

create_project -force firgen $work/proj -part xc7z020clg400-2
create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 \
          -module_name fir_compiler_0
set ip [get_ips fir_compiler_0]

# Coefficient_File is the relative "../fir.coe", so stage a copy where it resolves.
set ipdir [file dirname [get_property IP_FILE $ip]]
file copy -force $src/fir.coe [file dirname $ipdir]/fir.coe

set want [list \
  CONFIG.Filter_Type           {Decimation} \
  CONFIG.Decimation_Rate       {8} \
  CONFIG.Interpolation_Rate    {1} \
  CONFIG.Number_Paths          {2} \
  CONFIG.Number_Channels       {1} \
  CONFIG.Data_Width            {16} \
  CONFIG.Data_Sign             {Signed} \
  CONFIG.Coefficient_Width     {16} \
  CONFIG.Coefficient_Sign      {Signed} \
  CONFIG.Coefficient_Structure {Inferred} \
  CONFIG.Quantization          {Integer_Coefficients} \
  CONFIG.Coefficient_Sets      {1} \
  CONFIG.CoefficientSource     {COE_File} \
  CONFIG.Coefficient_File      {../fir.coe} \
  CONFIG.Output_Rounding_Mode  {Symmetric_Rounding_to_Zero} \
  CONFIG.Output_Width          {16} \
  CONFIG.Filter_Architecture   {Systolic_Multiply_Accumulate} \
  CONFIG.Optimization_Goal     {Area} \
  CONFIG.RateSpecification     {Output_Sample_Period} \
  CONFIG.SamplePeriod          {8} \
  CONFIG.Clock_Frequency       {300.0} \
  CONFIG.Sample_Frequency      {0.001} \
  CONFIG.Has_ARESETn           {false} \
  CONFIG.Has_ACLKEN            {false} \
  CONFIG.M_DATA_Has_TREADY     {false} ]
set_property -dict $want $ip

# Read every parameter back: -dict drops rejected values silently.
set bad 0
foreach {k v} $want {
  set got [get_property $k $ip]
  if {$got ne $v} { puts "FIRCFG MISMATCH $k: wanted $v got $got" ; set bad 1 }
}
if {$bad} { return -code error "FIR configuration did not take" }
puts "FIRCFG all [expr {[llength $want]/2}] parameters verified"

generate_target all $ip

set gen [get_property IP_FILE $ip]
file copy -force $gen $src/fir_compiler_0/fir_compiler_0.xci
puts "FIRGEN installed $src/fir_compiler_0/fir_compiler_0.xci"
puts "FIRGEN_DONE"
