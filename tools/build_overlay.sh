#!/bin/bash
# Build the E200 QICK overlay.
#
#   tools/build_overlay.sh            full synthesis + implementation + bitstream
#   tools/build_overlay.sh --bd-only  stop after the block design validates
#
# The two environment settings are not optional:
#
#   ADI_IGNORE_VERSION_CHECK  ADI pins the flow to Vivado 2021.1 and errors out
#                             otherwise. The E200 flow is on 2022.1 because
#                             PetaLinux 2022.1 builds the kernel the ADI patch in
#                             antsdr-pynq matches, so the check is downgraded to a
#                             critical warning.
#   QICK_IP_DIR               QICK's IP-XACT packages live outside the ADI library
#                             tree; qick_bd.tcl appends this to ip_repo_paths.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ANTSDR=${ANTSDR_DIR:-$here/../antsdr-pynq}
PRJ=$ANTSDR/boards/e200/qick/antsdre200
LOG=${BUILD_LOG:-$here/build/overlay.log}

[ -d "$PRJ" ] || { echo "no project at $PRJ" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

# shellcheck disable=SC1091
source "$here/setup/xilinx-env.sh" >/dev/null 2>&1
use_vivado >/dev/null 2>&1

export ADI_IGNORE_VERSION_CHECK=1
export QICK_IP_DIR=${QICK_IP_DIR:-$here/third_party/qick/firmware/ip}
if [ "${1:-}" = "--bd-only" ]; then
    export QICK_BD_ONLY=1
else
    unset QICK_BD_ONLY || true
fi

cd "$PRJ"
rm -rf antsdre200.srcs antsdre200.gen antsdre200.xpr .Xil \
       antsdre200.cache antsdre200.runs 2>/dev/null || true

echo "==> building in $PRJ (log: $LOG)"
set +e
vivado -mode batch -nojournal -source system_project.tcl > "$LOG" 2>&1
rc=$?
set -e
echo "EXIT=$rc" >> "$LOG"

echo "==> vivado exit $rc"
grep -E '^ERROR' "$LOG" | sort -u | head -5 | sed 's/^/  /' || true
grep -E 'Route 35-57' "$LOG" | tail -1 | sed 's/^/  /' || true
if [ -f timing_impl.log ]; then
    echo "  violated paths: $(grep -c 'Slack (VIOLATED)' timing_impl.log)"
fi
U=antsdre200.runs/impl_1/system_top_utilization_placed.rpt
[ -f "$U" ] && awk '/^\| *(Slice LUTs|Block RAM Tile|DSPs) /' "$U" | head -3 | sed 's/^/  /'
exit $rc
