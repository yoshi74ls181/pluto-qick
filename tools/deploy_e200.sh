#!/bin/bash
# Copy the E200 QICK overlay, the patched qick library, and the notebooks to the
# board. Does not program the PL -- that happens when the notebook (or
# smoke_e200.py) constructs QickSocE200.
#
#   tools/deploy_e200.sh [ssh-host]
#
# Expects an ssh host alias reachable without a password (see docs). PYNQ needs
# the .hwh basename to match the .bit, hence the rename to qick_e200.*.
set -euo pipefail

HOST=${1:-e200}
DEST=/home/xilinx/qick_e200
NBDEST=/home/xilinx/jupyter_notebooks/qick

here=$(cd "$(dirname "$0")/.." && pwd)
ANTSDR=${ANTSDR_DIR:-$here/../antsdr-pynq}
QICK=${QICK_FORK_DIR:-$here/../qick}
PRJ=$ANTSDR/boards/e200/qick/antsdre200

BIT=$PRJ/antsdre200.runs/impl_1/system_top.bit
HWH=$PRJ/antsdre200.gen/sources_1/bd/system/hw_handoff/system.hwh

for f in "$BIT" "$HWH"; do
  [ -f "$f" ] || { echo "missing $f -- build the overlay first" >&2; exit 1; }
done

echo "==> $HOST:$DEST"
ssh "$HOST" "mkdir -p $DEST $NBDEST"
scp -q "$BIT" "$HOST:$DEST/qick_e200.bit"
scp -q "$HWH" "$HOST:$DEST/qick_e200.hwh"
# __pycache__ gets written by root when the notebook or smoke test runs under
# sudo, so a non-root deploy cannot delete it. It is regenerated anyway.
rsync -az --delete --exclude '__pycache__' "$QICK/qick_lib/qick/" "$HOST:$DEST/qick/"
scp -q "$here/tools/smoke_e200.py" "$here/tools/acq.py" \
    "$here/tools/characterise_loopback.py" "$HOST:$DEST/"
scp -q "$ANTSDR"/boards/e200/qick/notebooks/*.ipynb "$HOST:$NBDEST/"

# PYNQ keys its parsed-metadata cache on the loaded bitstream, and a rebuild
# under the same filename can be served a stale parse -- which silently reports
# the *previous* build's IP parameters (a raised PMEM_AW looked like it had not
# applied at all). Drop the cache so the new .hwh is actually read.
echo "==> clearing PYNQ metadata cache"
CACHE=/usr/local/share/pynq-venv/lib/python3.10/site-packages/pynq/pl_server/_current_metadata.pkl
echo "${E200_SUDO_PASS:-xilinx}" | ssh "$HOST" "sudo -S -p '' rm -f $CACHE" 2>/dev/null \
  && echo "  cache cleared" \
  || echo "  could not clear cache; remove $CACHE on the board by hand" >&2

echo "==> deployed"
ssh "$HOST" "ls -l $DEST | sed 's/^/  /'"
cat <<'MSG'

To load the overlay and check discovery:
  ssh <host>
  echo xilinx | sudo -S bash -lc \
    'cd /home/xilinx/qick_e200 && python3 -W ignore smoke_e200.py'

The notebook needs a root kernel to program the PL. -W ignore suppresses the
four expected MDIO polarity warnings (see antsdr-pynq's pynqmetadata_polarity
package for why they are warnings and not errors).
MSG
