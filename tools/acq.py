"""Fire a QICK pulse into the AD9361 loopback and capture it on the readout.

Run on the board as root. Deliberately does not pass fs: reprogramming the PL
resets axi_ad9361 and the driver re-establishes the sample rate, so any value
known beforehand can be stale. config_rf_alt() runs after Overlay.__init__, which
makes reading it back afterwards both the default and the correct order.
"""
import sys
import time

import numpy as np

ROOT = '/home/xilinx/qick_e200'
sys.path.insert(0, ROOT)

from qick.ad9361 import QickSocE200          # noqa: E402
from qick.asm_v2 import AveragerProgramV2    # noqa: E402

soc = QickSocE200(ROOT + '/qick_e200.bit')

import adi                                    # noqa: E402
sdr = adi.ad9361(uri='local:')
sdr.rx_lo = int(2.4e9)
sdr.tx_lo = int(2.4e9)
sdr.rx_rf_bandwidth = int(18e6)
sdr.tx_rf_bandwidth = int(18e6)
sdr.rx_enabled_channels = [0]
sdr.tx_enabled_channels = [0]
sdr.gain_control_mode_chan0 = 'manual'
sdr.rx_hardwaregain_chan0 = 20.0
sdr.tx_hardwaregain_chan0 = -20.0
print("  radio:", sdr._ctrl.attrs['ensm_mode'].value, " fs =", soc['refclk_freq'], "MHz")

soc.tx_source('qick')
print("  tx source:", soc.get_tx_source())


class Loopback(AveragerProgramV2):
    def _initialize(self, cfg):
        self.declare_gen(ch=cfg['gen_ch'], nqz=1)
        # axis_readout_v2 is not tProc-driven (tproc_ch is None), so QICK calls it
        # static: the downconversion frequency is written here by software rather
        # than sent as a readoutconfig from the program.
        self.declare_readout(ch=cfg['ro_ch'], length=cfg['ro_len'],
                             freq=cfg['freq'], gen_ch=cfg['gen_ch'])
        self.add_pulse(ch=cfg['gen_ch'], name='probe', ro_ch=cfg['ro_ch'],
                       style='const', freq=cfg['freq'], phase=0,
                       gain=cfg['gain'], length=cfg['pulse_len'])

    def _body(self, cfg):
        self.pulse(ch=cfg['gen_ch'], name='probe', t=0)
        self.trigger(ros=[cfg['ro_ch']], t=cfg['trig_t'])


cfg = dict(gen_ch=0, ro_ch=0, freq=1.0, gain=0.5,
           pulse_len=10.0, ro_len=30.0, trig_t=0.0)

prog = Loopback(soc, reps=1, final_delay=1.0, cfg=cfg)
print("  acquiring...")
t0 = time.time()
iq = prog.acquire_decimated(soc, rounds=5, progress=False)
print("  acquire returned in %.1f s" % (time.time() - t0))

d = iq[0]
i, q = d[:, 0], d[:, 1]
f_dec = soc['readouts'][0]['f_output']
t = np.arange(len(i)) / f_dec
mag = np.abs(i + 1j * q)

print("  %d samples over %.1f us, decimated rate %.3f MHz" % (len(i), t[-1], f_dec))
print("  |IQ| min=%.1f max=%.1f at t=%.2f us" % (mag.min(), mag.max(), t[np.argmax(mag)]))

inside = (t > 1.0) & (t < cfg['pulse_len'] - 1.0)
seg = (i + 1j * q)[inside]
if len(seg) >= 8:
    ph = np.unwrap(np.angle(seg))
    slope = np.polyfit(np.arange(len(seg)) / f_dec, ph, 1)[0] / (2 * np.pi)
    print("  in-pulse: |IQ| mean %.1f, ripple %.1f %%, residual %.3f kHz"
          % (np.abs(seg).mean(),
             100 * (np.abs(seg).max() - np.abs(seg).min()) / np.abs(seg).mean(),
             slope * 1e3))
print("  first 6 |IQ|:", np.round(mag[:6], 1), " ... last 6:", np.round(mag[-6:], 1))

soc.tx_source('dma')
sdr.tx_hardwaregain_chan0 = -89.75
print("  restored: tx source", soc.get_tx_source())
print("ACQ_DONE")
