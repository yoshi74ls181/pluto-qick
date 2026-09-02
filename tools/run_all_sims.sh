#!/bin/bash
# Run every simulation in sim/ against the current RTL and summarise.
#
#   tools/run_all_sims.sh
#
# Worth running after any RTL change, not just before. A Vivado implementation
# never invokes xelab, so a build passing says nothing about whether the
# testbenches still even compile -- tb_tx_mux.sv silently stopped building when
# the mux lost a port, and went unnoticed through several builds.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
export QICK_ROOT=${QICK_ROOT:-$here/third_party/qick}
LOGDIR=$here/build/sims; mkdir -p "$LOGDIR"

# shellcheck disable=SC1091
source "$here/setup/xilinx-env.sh" >/dev/null 2>&1
use_vivado >/dev/null 2>&1

declare -a NAMES RESULTS

record() { NAMES+=("$1"); RESULTS+=("$2"); printf '  %-22s %s\n' "$1" "$2"; }

# --- standalone xsim testbenches (no IP needed) ---------------------------
run_xsim() {                       # name, top, sources...
    local name=$1 top=$2; shift 2
    local d="$LOGDIR/$name"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || return
    if ! xvlog -sv --nolog "$@" > compile.log 2>&1; then
        record "$name" "COMPILE FAIL"; return
    fi
    # -L xpm: fifo_xpm.sv instantiates xpm_fifo_sync
    if ! xelab -L xpm --nolog --timescale 1ns/1ps -debug typical "$top" -s snap > elab.log 2>&1; then
        record "$name" "ELAB FAIL"; return
    fi
    xsim snap --runall --nolog > run.log 2>&1
    if   grep -qE '(^|: )(PASS|ALL PASS)|RESULT: PASS' run.log; then record "$name" "PASS"
    elif grep -qiE 'FAIL' run.log;                then record "$name" "FAIL"
    else                                               record "$name" "no verdict"
    fi
}

SG=$QICK_ROOT/firmware/ip/axis_signal_gen_v6/src
HDL=$QICK_ROOT/firmware/hdl
run_xsim tb_ndds_equiv  tb_ndds_equiv  "$HDL/fifo_xpm.sv" "$SG/ctrl_sg_v6.sv" \
         "$SG/latency_reg.v" "$SG/signal_gen.v" "$here/sim/tb_ndds_equiv.sv"
run_xsim tb_ndds_envmux tb_ndds_envmux "$HDL/fifo_xpm.sv" "$SG/ctrl_sg_v6.sv" \
         "$SG/latency_reg.v" "$SG/signal_gen.v" "$here/sim/tb_ndds_envmux.sv"

# --- project-based runs (need generated IP) -------------------------------
run_proj() {                       # name, tcl, pattern
    local name=$1 tcl=$2 pat=$3
    local log="$LOGDIR/$name.log"
    cd "$here" || return
    if ! vivado -mode batch -nojournal -nolog -source "$tcl" > "$log" 2>&1; then
        record "$name" "VIVADO FAIL"; return
    fi
    if   grep -qE "$pat" "$log"; then record "$name" "PASS"
    elif grep -qiE 'FAIL'  "$log"; then record "$name" "FAIL"
    else                               record "$name" "no verdict"
    fi
}

run_proj tb_fir_decim     sim/run_sim_fir.tcl     'PASS  passband preserved'
run_proj tb_sg_chain      sim/run_sim_sgchain.tcl 'PASS  the descriptor produced a pulse'
run_proj tb_readout_cplx  sim/run_sim_readout.tcl 'PASS  complex input gives'

# tb_ndds_complex compares N_DDS=1 against N_DDS=4 for two phase increments. The
# evenly dividing one must agree within tolerance; the other is expected to leave
# a few samples over it, which is the base-phase rounding effect it exists to
# probe, so a bare "FAIL" in that log is not conclusive on its own.
run_proj tb_ndds_complex  sim/run_sim_dds.tcl     'RESULT: PASS'
# tb_iq_ssb only captures to iq_capture.txt and asserts nothing itself, so the
# verdict comes from analysing that file. A capture-only testbench in a suite is
# easy to mistake for a passing one.
cd "$here" || exit
if vivado -mode batch -nojournal -nolog -source sim/run_sim_iq.tcl > "$LOGDIR/tb_iq_ssb.log" 2>&1; then
    cap=$(find "$here/sim/work" -name iq_capture.txt 2>/dev/null | head -1)
    if [ -n "$cap" ] && python3 "$here/tools/analyse_iq_capture.py" "$cap" \
           >> "$LOGDIR/tb_iq_ssb.log" 2>&1; then
        record tb_iq_ssb "PASS"
    else
        record tb_iq_ssb "FAIL"
    fi
else
    record tb_iq_ssb "VIVADO FAIL"
fi

echo
fails=0
for i in "${!NAMES[@]}"; do [ "${RESULTS[$i]}" = PASS ] || fails=$((fails+1)); done
echo "  ${#NAMES[@]} suites, $fails not passing  (logs in $LOGDIR)"
exit $((fails > 0))
