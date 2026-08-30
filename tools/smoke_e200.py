"""Load the E200 QICK overlay and report what QICK discovered.

Run on the board, as root, with the modified qick lib on the path:

    ssh e200
    echo xilinx | sudo -S bash -lc \
      'cd /home/xilinx/qick_e200 && python3 -W ignore smoke_e200.py'

-W ignore suppresses the four expected MDIO polarity warnings (see
antsdr-pynq's pynqmetadata_polarity package).

Note fs is deliberately not passed: reprogramming the PL resets axi_ad9361 and
the driver re-establishes the sample rate, so any value known beforehand may be
stale. config_rf_alt() runs after Overlay.__init__, so letting
read_ad9361_fs() read it back afterwards is the correct order.
"""
import sys

ROOT = '/home/xilinx/qick_e200'
sys.path.insert(0, ROOT)

from qick.ad9361 import QickSocE200

print("loading overlay...", flush=True)
soc = QickSocE200(ROOT + '/qick_e200.bit')
print("LOADED OK", flush=True)

print("\n=== soccfg ===")
print(soc)

print("\n=== discovery ===")
print("  tproc version :", soc.TPROC_VERSION)
print("  generators    :", [g['fullpath'] for g in soc.gens])
print("  readouts      :", [r['fullpath'] for r in soc.readouts])
print("  avg buffers   :", [b['fullpath'] for b in soc.avg_bufs])
for i, g in enumerate(soc.gens):
    print("  gen[%d] dac=%s samps_per_clk=%s maxlen=%s complex_env=%s f_fabric=%s"
          % (i, g['dac'], g['samps_per_clk'], g['maxlen'], g['complex_env'], g['f_fabric']))
    print("         dma=%s switch_ch=%s" % (getattr(g, 'dma', None), g.switch_ch))
for i, r in enumerate(soc['readouts']):
    print("  ro[%d]  adc=%s f_output=%s decimation=%s avgbuf trigger=%s"
          % (i, r.get('ro_adc', r.get('adc')), r.get('f_output'), r.get('decimation'),
             (r.get('trigger_type'), r.get('trigger_port'), r.get('trigger_bit'))))
t = soc['tprocs'][0]
print("  tproc  f_core=%s f_time=%s pmem=%s dmem=%s wmem=%s"
      % (t['f_core'], t['f_time'], t['pmem_size'], t['dmem_size'], t['wmem_size']))

print("\n=== TX mux ===")
print("  reset default:", soc.get_tx_source())
soc.tx_source('qick');  print("  after set qick:", soc.get_tx_source())
soc.tx_source('dma');   print("  restored to   :", soc.get_tx_source())

print("\nSMOKE_OK")
