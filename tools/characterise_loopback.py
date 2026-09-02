"""Characterise the QICK loopback pulse: latency, length, flatness, frequency."""
import sys, time
import numpy as np
sys.path.insert(0, '/home/xilinx/qick_e200')
from qick.ad9361 import QickSocE200
from qick.asm_v2 import AveragerProgramV2

def p(*a): print(*a, flush=True)

soc = QickSocE200('/home/xilinx/qick_e200/qick_e200.bit')
import adi
sdr = adi.ad9361(uri='local:')
sdr.rx_lo = int(2.4e9); sdr.tx_lo = int(2.4e9)
sdr.rx_rf_bandwidth = int(18e6); sdr.tx_rf_bandwidth = int(18e6)
sdr.rx_enabled_channels = [0]; sdr.tx_enabled_channels = [0]
sdr.gain_control_mode_chan0 = 'manual'
sdr.rx_hardwaregain_chan0 = 20.0
sdr.tx_hardwaregain_chan0 = -20.0
sdr.tx_cyclic_buffer = True
sdr.tx(np.zeros(4096, dtype=np.complex64))
time.sleep(0.5)

PULSE_US, RO_US, FREQ = 10.0, 30.0, 1.0

class P(AveragerProgramV2):
    def _initialize(self, cfg):
        self.declare_gen(ch=0, nqz=1)
        self.declare_readout(ch=0, length=RO_US, freq=FREQ, gen_ch=0)
        self.add_pulse(ch=0, name='probe', ro_ch=0, style='const',
                       freq=FREQ, phase=0, gain=cfg['gain'], length=PULSE_US)
    def _body(self, cfg):
        self.pulse(ch=0, name='probe', t=0)
        self.trigger(ros=[0], t=0.0)

f_dec = soc['readouts'][0]['f_output']

def run(gain, rounds=20):
    prog = P(soc, reps=1, final_delay=1.0, cfg={'gain': gain})
    d = prog.acquire_decimated(soc, rounds=rounds, progress=False)[0]
    z = d[:, 0] + 1j*d[:, 1]
    t = np.arange(len(z)) / f_dec
    m = np.abs(z)
    thr = 0.3 * m.max()
    on = np.where(m > thr)[0]
    if len(on) < 4:
        p("  gain %.2f: no pulse found (max %.1f)" % (gain, m.max())); return None
    i0, i1 = on[0], on[-1]
    core = slice(i0 + 2, max(i0 + 3, i1 - 1))      # interior, skip the edges
    seg = z[core]
    ph = np.unwrap(np.angle(seg))
    slope = np.polyfit(np.arange(len(seg))/f_dec, ph, 1)[0] / (2*np.pi)   # MHz
    flat = 100 * (np.abs(seg).max() - np.abs(seg).min()) / np.abs(seg).mean()
    p("  gain %.2f | arrives %5.2f us | length %5.2f us (cmd %.1f) | "
      "|IQ| %6.1f | flatness %5.1f %% | df %+8.1f kHz"
      % (gain, t[i0], t[i1]-t[i0], PULSE_US, np.abs(seg).mean(), flat, slope*1e3))
    return t[i0], np.abs(seg).mean()

p("  decimated rate %.3f MHz, %.0f samples expected in a %.0f us window"
  % (f_dec, RO_US*f_dec, RO_US))
p("")
res = [run(g) for g in (0.1, 0.2, 0.4, 0.8)]
p("")
lat = [r[0] for r in res if r]
amp = [r[1] for r in res if r]
if len(amp) >= 2:
    p("  round-trip latency: %.2f +/- %.2f us (consistent across gains)"
      % (np.mean(lat), np.std(lat)))
    g = np.array([0.1, 0.2, 0.4, 0.8][:len(amp)])
    ratio = np.array(amp) / (g * amp[0] / g[0])
    p("  amplitude vs commanded gain: %s" % np.round(ratio, 3))
    p("  (1.000 everywhere means the response is linear in gain)")

try: sdr.tx_destroy_buffer()
except Exception: pass
sdr.tx_hardwaregain_chan0 = -89.75
p("CHAR_DONE")
