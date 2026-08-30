#!/bin/bash
# Reproduce the feasibility numbers in docs/feasibility.md.
#
#   export QICK_ROOT=/path/to/qick        # upstream checkout, patches applied
#   source /tools/Xilinx/Vitis/2022.1/settings64.sh
#   ./syn/run.sh [cfg-name ...]           # default: all
set -u
here=$(cd "$(dirname "$0")" && pwd)
: "${QICK_ROOT:?set QICK_ROOT to an upstream QICK checkout with patches/ applied}"
command -v vivado >/dev/null || { echo "vivado not on PATH; source settings64.sh"; exit 1; }

cfgs=("$@")
if [ ${#cfgs[@]} -eq 0 ]; then
    mapfile -t cfgs < <(cd "$here/cfg" && ls *.tcl | sed 's/\.tcl$//')
fi
rc=0
for c in "${cfgs[@]}"; do
    echo "=============== $c ==============="
    vivado -mode batch -nojournal -nolog \
        -source "$here/qick_ip_synth.tcl" -tclargs "$here/cfg/$c.tcl" \
        | grep -E '^(===|  |SYNTH_OK|NOTE|ERROR)' || rc=1
done
exit $rc
