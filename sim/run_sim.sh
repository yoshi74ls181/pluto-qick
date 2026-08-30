#!/bin/bash
# Simulate the N_DDS=1 equivalence check with xsim.
#   export QICK_ROOT=$PWD/third_party/qick
#   source /tools/Xilinx/Vitis/2022.1/settings64.sh
#   ./sim/run_sim.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
: "${QICK_ROOT:?set QICK_ROOT}"
work=$here/work; mkdir -p "$work"; cd "$work"

SG=$QICK_ROOT/firmware/ip/axis_signal_gen_v6/src
HDL=$QICK_ROOT/firmware/hdl

# tb_ndds_equiv  : phase-generation path (ctrl_sg_v6 alone)
# tb_ndds_envmux : envelope fetch + source mux + gain (signal_gen, GEN_DDS=FALSE)
xvlog -sv --nolog \
  "$HDL/fifo_xpm.sv" \
  "$SG/ctrl_sg_v6.sv" \
  "$SG/latency_reg.v" \
  "$SG/signal_gen.v" \
  "$here/tb_ndds_equiv.sv" \
  "$here/tb_ndds_envmux.sv" || exit 1

rc=0
for tb in tb_ndds_equiv tb_ndds_envmux; do
    echo ""
    echo "################ $tb ################"
    xelab -L xpm --nolog --timescale 1ns/1ps -debug typical $tb -s ${tb}_snap || { rc=1; continue; }
    xsim ${tb}_snap --runall --nolog || rc=1
done
exit $rc
