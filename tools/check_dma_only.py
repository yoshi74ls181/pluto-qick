"""Check that every tProc v2 memory access on this board goes through the DMA.

Axis_QICK_Proc.single_read and single_write say "Do not use! Use the DMA
instead." -- and single_write adds "This seems to crash the DMA." Neither has a
caller anywhere in QICK: the only single_read/single_write call sites are in
QickSoc's TPROC_VERSION == 1 branches, which reach the same-named methods of
AxisTProc64x32_x8, a different class.

Grep establishes that statically. This establishes it at runtime: make both
methods fatal, count the DMA entry points, and run a real acquisition. If the
shot completes with zero single-access calls, then construction, program load
and readback all went through load_mem/read_mem and the AXI DMA.

Override the radio settings with FS_MHZ / LO_GHZ.
"""
import os
import sys, time
import numpy as np
import adi
sys.path.insert(0, '/home/xilinx/qick_e200')
from qick.drivers.tproc import Axis_QICK_Proc
from qick.ad9361 import QickSocE200
from qick.asm_v2 import AveragerProgramV2

calls = {'single_read': 0, 'single_write': 0, 'load_mem': 0, 'read_mem': 0}

def fatal(name):
    def f(self, *a, **k):
        calls[name] += 1
        raise AssertionError("%s reached: this board is NOT DMA-only" % name)
    return f

_load_mem, _read_mem = Axis_QICK_Proc.load_mem, Axis_QICK_Proc.read_mem
def counting(name, orig):
    def f(self, *a, **k):
        calls[name] += 1
        return orig(self, *a, **k)
    return f

Axis_QICK_Proc.single_read  = fatal('single_read')
Axis_QICK_Proc.single_write = fatal('single_write')
Axis_QICK_Proc.load_mem = counting('load_mem', _load_mem)
Axis_QICK_Proc.read_mem = counting('read_mem', _read_mem)

FS_MHZ = float(os.environ.get('FS_MHZ', '50'))
LO_GHZ = float(os.environ.get('LO_GHZ', '6.0'))

soc = QickSocE200('/home/xilinx/qick_e200/qick_e200.bit')
sdr = adi.ad9361(uri='local:')
sdr.rx_rf_bandwidth = int(40e6); sdr.tx_rf_bandwidth = int(40e6)
sdr.sample_rate = int(FS_MHZ * 1e6); time.sleep(0.5)
sdr.rx_lo = int(LO_GHZ * 1e9); sdr.tx_lo = int(LO_GHZ * 1e9); time.sleep(0.3)
sdr.rx_enabled_channels = [0]; sdr.tx_enabled_channels = [0]
sdr.gain_control_mode_chan0 = 'manual'
sdr.rx_hardwaregain_chan0 = 20.0; sdr.tx_hardwaregain_chan0 = -20.0
for step in ('alert', 'fdd'):
    sdr._ctrl.attrs['ensm_mode'].value = step; time.sleep(0.2)
soc.refresh_rf()
sdr.tx_cyclic_buffer = True
sdr.tx(np.zeros(4096, dtype=np.complex64))
time.sleep(0.5)

class Loop(AveragerProgramV2):
    # axis_readout_v2 here is static (tproc_ch is None), so the downconversion
    # frequency goes in the declaration rather than a readoutconfig sent from
    # the program -- same shape as the loopback notebook.
    def _initialize(self, cfg):
        self.declare_gen(ch=0, nqz=1)
        self.declare_readout(ch=0, length=cfg['ro_len'], freq=cfg['f'], gen_ch=0)
        self.add_pulse(ch=0, name='p', ro_ch=0, style='const',
                       freq=cfg['f'], phase=0, gain=0.4, length=cfg['len'])
    def _body(self, cfg):
        self.pulse(ch=0, name='p', t=0)
        self.trigger(ros=[0], t=0)

fs = soc['refclk_freq']
prog = Loop(soc, reps=1, final_delay=100.0,
            cfg={'f': fs/8, 'len': 10.0, 'ro_len': 30.0})
iq = prog.acquire_decimated(soc, rounds=1, progress=False)
d = np.asarray(iq[0])
mag = np.abs(d[..., 0] + 1j*d[..., 1]).ravel()
print("acquisition completed: shape %s, %d samples, peak |IQ| = %.1f"
      % (d.shape, mag.size, mag.max()))
print("call counts:", calls)
assert calls['single_read'] == 0 and calls['single_write'] == 0
assert calls['load_mem'] > 0 and calls['read_mem'] > 0
print("DMA_ONLY_OK")
