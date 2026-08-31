#!/bin/bash
# Bring up a freshly power-cycled E200.
#
#   tools/bringup_e200.sh [ssh-host]                 verify only (default)
#   tools/bringup_e200.sh [ssh-host] --run-loopback  also load the overlay and
#                                                    run the capture
#
# Verification is the default deliberately. Programming the PL is what hung the
# board last time, hard enough that magic SysRq over serial got no response and
# only a power cycle recovered it. quiesce_axi_masters() is meant to prevent the
# AXI lockup that caused it, but that fix has never been exercised on hardware.
# If power-cycling is not available, a repeat leaves the board unrecoverable
# rather than merely inconvenient -- so loading the overlay has to be an explicit
# choice, not something a convenience script does on its own.
#
# Encodes the sequence and the several traps found the hard way:
#
#  * check the radio BEFORE loading anything -- a board that came up with the
#    AD9361 asleep or at an unexpected rate is not worth loading an overlay onto
#  * deploy clears PYNQ's parsed-metadata cache, or a rebuild under the same
#    filename is served the previous build's IP parameters
#  * QickSocE200 quiesces the AXI masters and passes a dtbo itself; the first
#    stops a PL reload locking the interconnect, the second stops the AD9361
#    driver being left stale and then wedged
#  * run detached with setsid and unbuffered python, logging to a file on the
#    board. Loading the overlay resets the RGMII Ethernet, so an ssh session
#    holding the process can die and take the output with it -- which is how the
#    first attempt lost its diagnosis
set -uo pipefail

HOST=${1:-e200}
RUN_LOOPBACK=no
for a in "$@"; do [ "$a" = "--run-loopback" ] && RUN_LOOPBACK=yes; done
DEST=/home/xilinx/qick_e200
PW=${E200_SUDO_PASS:-xilinx}
here=$(cd "$(dirname "$0")/.." && pwd)

say() { printf '\n== %s\n' "$*"; }

say "1. boot source -- confirm it came up on PYNQ from SD, not QSPI firmware"
timeout 30 ssh -o BatchMode=yes "$HOST" 'bash -lc "
echo \"   kernel   = \$(uname -r)\"
echo \"   board    = \$BOARD\"
echo \"   rootfs   = \$(findmnt -no SOURCE / 2>/dev/null)\"
echo \"   pynq     = \$(python3 -c \"import pynq;print(pynq.__version__)\" 2>/dev/null || echo absent)\"
echo \"   overlay  = \$(cat /sys/firmware/devicetree/base/chosen/pynq_board 2>/dev/null | tr -d \\\\0)\"
"' || { echo "   board not reachable" >&2; exit 1; }

say "2. radio state before touching anything"
timeout 30 ssh -o BatchMode=yes "$HOST" 'bash -lc "
for d in /sys/bus/iio/devices/iio:device*; do
  n=\$(cat \$d/name 2>/dev/null)
  [ \"\$n\" = ad9361-phy ]    && echo \"   ensm = \$(cat \$d/ensm_mode)\"
  [ \"\$n\" = cf-ad9361-lpc ] && echo \"   fs   = \$(cat \$d/in_voltage_sampling_frequency)\"
done
echo \"   uptime = \$(cut -d. -f1 /proc/uptime)s\"
"' || { echo "   board not reachable" >&2; exit 1; }

if [ "$RUN_LOOPBACK" != yes ]; then
    cat <<'MSG'

== verification only; stopping here.
   Nothing has been deployed and the PL has NOT been reprogrammed.
   To go further:  tools/bringup_e200.sh <host> --run-loopback
   Be aware that programming the PL is what hung the board previously, and the
   fix for that has not yet been exercised on hardware.
MSG
    exit 0
fi

say "3. deploy bitstream, patched qick lib, notebooks"
E200_SUDO_PASS="$PW" "$here/tools/deploy_e200.sh" "$HOST" 2>&1 | grep -E '==>|cache|error' || true

say "4. smoke test: load the overlay and report discovery"
timeout 300 ssh -o BatchMode=yes "$HOST" \
  "echo '$PW' | sudo -S -p '' bash -lc 'cd $DEST && timeout 240 python3 -u -W ignore smoke_e200.py'" 2>&1 \
  | grep -vE '^\[sudo' | grep -E 'LOADED|memories|generators|readouts|avg buffers|gen\[|ro\[|tproc |tx source|reset default|after set|restored|SMOKE_OK|Error|Traceback' || true

say "5. loopback acquire, detached so a dropped link cannot lose the log"
timeout 60 ssh -o BatchMode=yes "$HOST" "cat > $DEST/run_acq.sh <<'EOS'
#!/bin/bash
cd $DEST
. /etc/environment 2>/dev/null
for f in /etc/profile.d/*.sh; do . \"\$f\" 2>/dev/null; done
rm -f acq.log
timeout 500 python3 -u -W ignore acq.py > acq.log 2>&1
echo \"EXIT=\$?\" >> acq.log
EOS
chmod +x $DEST/run_acq.sh"
timeout 60 ssh -o BatchMode=yes "$HOST" \
  "echo '$PW' | sudo -S -p '' setsid --fork $DEST/run_acq.sh" 2>&1 | grep -vE '^\[sudo' || true

echo "   launched; waiting for it to finish"
for i in $(seq 1 60); do
  if timeout 10 ssh -o BatchMode=yes "$HOST" "grep -qE 'ACQ_DONE|EXIT=' $DEST/acq.log 2>/dev/null" 2>/dev/null; then
    break
  fi
  sleep 10
done

say "6. result"
timeout 40 ssh -o BatchMode=yes "$HOST" "cat $DEST/acq.log 2>/dev/null" \
  | grep -vE 'Exception ignored|iio.py|^TypeError|Traceback \(most recent call last\)' || echo "   no log retrieved"
