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

xvlog -sv --nolog \
  "$HDL/fifo_xpm.sv" \
  "$SG/ctrl_sg_v6.sv" \
  "$here/tb_ndds_equiv.sv" || exit 1
xelab -L xpm --nolog --timescale 1ns/1ps -debug typical tb_ndds_equiv -s tb_snap || exit 1
xsim tb_snap --runall --nolog
