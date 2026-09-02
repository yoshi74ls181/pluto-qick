"""Exercise QICK's connectivity tracing against the E200 overlay's .hwh.

Runs on the host: QickMetadata only needs an XML root, so no board and no PL
programming is involved.
"""
import sys, xml.etree.ElementTree as ET
from qick.ip import QickMetadata

HWH = sys.argv[1]

class FakeParser:
    def __init__(self, root): self.root = root
class FakeTproc:
    """Just enough to answer port2ch the way QickProcessor does."""
    def port2ch(self, portname):
        words = portname.split('_')
        if words[-1] == 'axis':
            return int(words[0][1:]), {'m':'wport','s':'input'}[words[0][0]]
        return int(words[1]), {'trig':'tport','port':'dport'}[words[0]]
class FakeSoc:
    def __init__(self, root): self.parser = FakeParser(root)
    def _get_block(self, path): return FakeTproc()

md = QickMetadata(FakeSoc(ET.parse(HWH).getroot()))

qick_blocks = [k for k in md.modinfo if any(t in k for t in
    ('qick_processor_0','sg0','sgt0','ro0','avg0','axi_dma','qick_avg2tproc','qick_adc_cat'))]
print("QICK blocks found in the hwh:")
for b in sorted(qick_blocks):
    print("   %-22s %s" % (b, md.mod2type(b)))

fails = []
# Pins nothing reads: AxisAvgBuffer has no trace_clocks, so a missing FREQ_HZ
# annotation on its stream clocks is expected rather than a problem.
EXPECTED_MISSING = ('get_fclk avg0/s_axis_aclk', 'get_fclk avg0/m_axis_aclk')

def check(label, fn, want=None):
    try:
        got = fn()
    except Exception as e:
        expected = label in EXPECTED_MISSING
        print("   %-4s %-42s %s: %s" % ("n/a" if expected else "FAIL", label, type(e).__name__, e))
        if not expected: fails.append(label)
        return None
    ok = (want is None) or (want in str(got))
    print("   %-4s %-42s %s" % ("ok" if ok else "BAD", label, got))
    if not ok: fails.append(label)
    return got

print("\nParameters read from the hwh (drivers depend on these):")
check("sg0 N_DDS",         lambda: md.get_param('sg0','N_DDS'), '1')
check("sg0 N",             lambda: md.get_param('sg0','N'))
check("sg0 ENVELOPE_TYPE", lambda: md.get_param('sg0','ENVELOPE_TYPE'), 'COMPLEX')

print("\nDMA discovery (QickMetadata.trace_dma):")
check("gen envelope  sg0/s0_axis  <- ", lambda: md.trace_dma('backward','sg0','s0_axis'), 'axi_dma_gen')
check("avg results   avg0/m0_axis -> ", lambda: md.trace_dma('forward','avg0','m0_axis'), 'axi_dma_avg')
check("buf samples   avg0/m1_axis -> ", lambda: md.trace_dma('forward','avg0','m1_axis'), 'axi_dma_buf')

print("\nSignal-path discovery:")
RO_TYPES = ["axis_readout_v2","axis_readout_v3","axis_pfb_readout_v2","axis_pfb_readout_v3","axis_pfb_readout_v4","axis_dyn_readout_v1"]
check("avg0/s_axis  <- readout",   lambda: md.trace_back('avg0','s_axis',RO_TYPES), 'ro0')
check("sg0/s1_axis  <- tproc",     lambda: md.trace_back('sg0','s1_axis',["axis_tproc64x32_x8","qick_processor","axis_tmux_v1"]), 'qick_processor_0')
check("avg0/m2_axis -> tproc",     lambda: md.trace_forward('avg0','m2_axis',["axis_tproc64x32_x8","qick_processor"]), 'qick_processor_0')
check("avg0/trigger <- tproc",     lambda: md.trace_trigger('avg0','trigger'))

print("\nClock frequency the hwh reports for the QICK datapath:")
for blk, port in [('qick_processor_0','c_clk_i'), ('qick_processor_0','t_clk_i'),
                  ('qick_processor_0','ps_clk_i'), ('sg0','aclk'), ('ro0','aclk'),
                  ('avg0','s_axis_aclk'), ('avg0','m_axis_aclk')]:
    check("get_fclk %s/%s" % (blk, port), lambda b=blk,p=port: md.get_fclk(b,p))

print("\n%s" % ("ALL CHECKS PASSED" if not fails else "FAILURES: %s" % fails))
sys.exit(1 if fails else 0)
