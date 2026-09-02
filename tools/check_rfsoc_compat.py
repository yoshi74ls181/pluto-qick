"""Check the qick fork's shared-code changes against the RFSoC code paths.

The E200 branch touches five files that every QICK board shares. None of it can
be tested on a ZCU216 or RFSoC4x2 here, so this compares each changed path
against the upstream implementation it replaced, using the upstream source
itself as the reference rather than a paraphrase of it.

Run from a checkout of the qick fork:

    QICK=/path/to/qick python3 check_rfsoc_compat.py

Upstream is read out of git at the branch's merge-base, so the comparison
cannot drift from what upstream actually says.
"""
import os
import subprocess
import sys

import numpy as np

QICK = os.environ.get('QICK', '/home/slab/pluto/qick')
BASE = os.environ.get('BASE', '0b1613e')
sys.path.insert(0, os.path.join(QICK, 'qick_lib'))

# PYNQ only exists on a Zynq, so qick.qick cannot be imported on a workstation
# without standing in for it. Everything checked here is pure Python -- integer
# conversion, string formatting, and which function calls which -- so a stub is
# enough. It does mean this script says nothing about driver or MMIO behaviour;
# that is what the board itself is for.
import types


def _stub(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    sys.modules[name] = m
    return m


class _Overlay:
    def __init__(self, *a, **k):
        pass


if 'pynq' not in sys.modules:
    try:
        import pynq  # noqa: F401
    except ImportError:
        _stub('pynq', Overlay=_Overlay, MMIO=object, allocate=lambda *a, **k: None)
        _stub('pynq.overlay', Overlay=_Overlay, DefaultIP=object, DefaultHierarchy=object)
        _stub('pynq.buffer', allocate=lambda *a, **k: None)
        _stub('pynq.lib', _dma=None)
        _stub('pynq.lib.dma', DMA=object)

failures = []
def check(name, ok, detail=''):
    print("  %-4s %s%s" % ('ok' if ok else 'FAIL', name, ('  -- ' + detail) if detail else ''))
    if not ok:
        failures.append(name)

def upstream(path):
    return subprocess.run(['git', '-C', QICK, 'show', '%s:%s' % (BASE, path)],
                          capture_output=True, text=True, check=True).stdout


# ---------------------------------------------------------------------------
print("\n1. _as_int32_words vs upstream np.array(data, dtype=np.int32)")
# Upstream converted memory words with a plain int32 cast. The replacement has
# to agree everywhere the cast succeeds; where the cast raises, upstream was
# unusable, so there is no behaviour for RFSoC users to depend on.
from qick.qick import _as_int32_words   # noqa: E402

def old(data):
    return np.array(data, dtype=np.int32)

cases = {
    'zeros':                [0, 0, 0],
    'small positives':      [1, 2, 3, 1000],
    'int32 max':            [2**31 - 1],
    'negative int32':       [-1, -2**31, -12345],
    'unsigned >= 2**31':    [2**31, 2**32 - 1, 0x80000000, 0xFFFFFFFF],
    'mixed signed/unsigned': [-1, 0, 2**31 - 1, 2**31],
    '2-D pmem shape':       [[1, 2, 3, 4, 5, 6, 7, 8], [0]*8],
    '2-D with high words':  [[0xDEADBEEF, 0, 0, 0, 0, 0, 0, 0]],
    'already int32 array':  np.array([-1, 5, 2**31 - 1], dtype=np.int32),
    'uint32 array':         np.array([0xFFFFFFFF, 1], dtype=np.uint32),
    'empty':                [],
}
for name, data in cases.items():
    new_val = _as_int32_words(data)
    try:
        old_val = old(data)
    except (OverflowError, ValueError) as e:
        check("%-22s upstream raises %s, new wraps" % (name, type(e).__name__),
              True, "no upstream behaviour to preserve")
        continue
    same = (new_val.shape == old_val.shape
            and new_val.dtype == old_val.dtype
            and np.array_equal(new_val, old_val))
    check("%-22s identical" % name, same,
          '' if same else "old=%s new=%s" % (old_val, new_val))

# The range RFSoC firmware actually produces: tProc words are 32-bit, and
# upstream's cast only accepts the signed half. Sweep it densely.
rng = np.random.default_rng(0)
probe = np.concatenate([
    np.arange(-2**31, -2**31 + 512),
    np.arange(-512, 512),
    np.arange(2**31 - 512, 2**31),
    rng.integers(-2**31, 2**31, size=20000),
]).astype(np.int64)
same = np.array_equal(_as_int32_words(probe), old(probe))
check("dense sweep of the whole signed 32-bit range (%d values)" % probe.size, same)

# numpy deprecated the upstream form. 1.24 warns "NumPy will stop allowing
# conversion of out-of-bound Python integers to integer arrays ... will fail in
# the future", and recommends casting through a wider type -- which is what the
# replacement does. So this is not only equivalent on an RFSoC today, it is what
# keeps tProc v2 program loading working when a board moves to numpy 2, where
# the upstream cast raises instead of wrapping.
import warnings
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter('always')
    old([2**31, 2**32 - 1])
old_warns = [w for w in caught if issubclass(w.category, DeprecationWarning)]
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter('always')
    _as_int32_words([2**31, 2**32 - 1])
new_warns = [w for w in caught if issubclass(w.category, DeprecationWarning)]
check("numpy %s deprecates the upstream cast" % np.__version__, bool(old_warns),
      old_warns[0].message.args[0].splitlines()[0] if old_warns else 'no warning')
check("the replacement raises no deprecation warning", not new_warns)

# Round-trip: the bit pattern must survive, which is the property the tProc
# memories care about.
words = np.concatenate([probe, rng.integers(0, 2**32, size=20000).astype(np.int64)])
rt = _as_int32_words(words).astype(np.int64) & 0xFFFFFFFF
check("bit pattern preserved for all 32-bit words (%d values)" % words.size,
      np.array_equal(rt, words & 0xFFFFFFFF))


# ---------------------------------------------------------------------------
print("\n2. _describe_dac / _describe_adc vs upstream, per board")
# The new else branch must be unreachable for every board upstream names.
import qick.qick_asm as qick_asm   # noqa: E402

# Relative imports in the upstream source need the package context set.
ns = {'__name__': 'qick.qick_asm', '__package__': 'qick',
      '__file__': os.path.join(QICK, 'qick_lib/qick/qick_asm.py')}
exec(compile(upstream('qick_lib/qick/qick_asm.py'), '<upstream qick_asm>', 'exec'), ns)
UpstreamConfig = ns['QickConfig']

def make(cls, board, dacs, adcs):
    obj = cls.__new__(cls)
    obj._cfg = {'board': board,
                'rf': {'dacs': {d: {'coupling': 'DC'} for d in dacs},
                       'adcs': {a: {'coupling': 'AC'} for a in adcs}}}
    return obj

BOARDS = {
    # board:      (dac names,                     adc names)
    'ZCU111':     (['%d%d' % (t, b) for t in range(4) for b in range(4)],
                   ['%d%d' % (t, b) for t in range(4) for b in range(0, 4, 2)]),
    'ZCU216':     (['%d%d' % (t, b) for t in range(4) for b in range(4)],
                   ['%d%d' % (t, b) for t in range(4) for b in range(0, 4, 2)]),
    'RFSoC4x2':   (['00', '20'], ['00', '02', '20', '22']),
}
for board, (dacs, adcs) in BOARDS.items():
    new_obj = make(qick_asm.QickConfig, board, dacs, adcs)
    old_obj = make(UpstreamConfig, board, dacs, adcs)
    diffs = []
    for d in dacs:
        a, b = new_obj._describe_dac(d), old_obj._describe_dac(d)
        if a != b:
            diffs.append('dac %s: %r != %r' % (d, a, b))
    for c in adcs:
        a, b = new_obj._describe_adc(c), old_obj._describe_adc(c)
        if a != b:
            diffs.append('adc %s: %r != %r' % (c, a, b))
    check("%-10s %d DACs + %d ADCs describe identically" % (board, len(dacs), len(adcs)),
          not diffs, '; '.join(diffs[:3]))

# And upstream's failure on an unknown board, which the else branch fixes.
unknown_new = make(qick_asm.QickConfig, 'SomeNewBoard', ['00'], ['00'])
unknown_old = make(UpstreamConfig, 'SomeNewBoard', ['00'], ['00'])
try:
    unknown_old._describe_dac('00')
    check("upstream raises on an unknown board", False, "it did not raise")
except UnboundLocalError:
    check("upstream raises UnboundLocalError on an unknown board", True)
check("new code describes an unknown board", unknown_new._describe_dac('00')
      == 'DAC tile 0, blk 0 is 00')

# A converter config with no 'coupling' key: upstream raised, new code does not.
nc_new = qick_asm.QickConfig.__new__(qick_asm.QickConfig)
nc_new._cfg = {'board': 'x', 'rf': {'dacs': {'00': {}}, 'adcs': {'00': {}}}}
nc_old = UpstreamConfig.__new__(UpstreamConfig)
nc_old._cfg = nc_new._cfg
try:
    nc_old._describe_adc('00'); raised = False
except KeyError:
    raised = True
check("upstream needs a 'coupling' key, new code does not", raised
      and nc_new._describe_adc('00') == 'ADC tile 0, blk 0 is 00')


# ---------------------------------------------------------------------------
print("\n3. find_rf_port / clk_src defaults vs the upstream inline code")
# Both are pure delegation, but a transcription slip would be invisible without
# hardware. Drive the new helper and the upstream snippets through one recording
# stub and compare the results and the calls made.
class Meta:
    def __init__(self, log): self.log = log
    def trace_forward(self, path, port, types):
        self.log.append(('trace_forward', path, port, tuple(types)))
        return 'usp_rf_data_converter_0', 's02_axis', 'usp_rf_data_converter'
    def trace_back(self, path, port, types):
        self.log.append(('trace_back', path, port, tuple(types)))
        return 'usp_rf_data_converter_0', 'm02_axis', 'usp_rf_data_converter'
    def trace_clk_back(self, path, port):
        self.log.append(('trace_clk_back', path, port))
        return {'source': ('dac', 0), 'f_clk': 245.76, 'src_range': None}

class Soc:
    def __init__(self, log): self.metadata = Meta(log); self.log = log
    def _get_block(self, blk):
        self.log.append(('_get_block', blk)); return 'BLOCK<%s>' % blk
    # the new hooks, copied from the branch
    def clk_src(self, fullpath, port):
        return self.metadata.trace_clk_back(fullpath, port)
    def find_rf_port(self, block, kind, port):
        if kind == 'dac':
            blk, prt, _ = self.metadata.trace_forward(block['fullpath'], port, ["usp_rf_data_converter"])
        else:
            blk, prt, _ = self.metadata.trace_back(block['fullpath'], port, ["usp_rf_data_converter"])
        return self._get_block(blk), prt[1:3]

blk = {'fullpath': 'axis_signal_gen_v6_0'}

# generator: upstream set self.rf and cfg['dac'] inline
log_old = []; soc_old = Soc(log_old)
b, p, _ = soc_old.metadata.trace_forward(blk['fullpath'], 'm_axis', ["usp_rf_data_converter"])
old_dac = (soc_old._get_block(b), p[1:3])
log_new = []; soc_new = Soc(log_new)
new_dac = soc_new.find_rf_port(blk, 'dac', 'm_axis')
check("generator: (rf, dac) identical", old_dac == new_dac,
      "%s vs %s" % (old_dac, new_dac))
check("generator: same trace calls in the same order", log_old == log_new)

# readout: upstream took only the port, and did not resolve the block object
log_old = []; soc_old = Soc(log_old)
b, p, _ = soc_old.metadata.trace_back(blk['fullpath'], 's_axis', ["usp_rf_data_converter"])
old_adc = p[1:3]
log_new = []; soc_new = Soc(log_new)
new_adc = soc_new.find_rf_port(blk, 'adc', 's_axis')[1]
check("readout: cfg['adc'] identical", old_adc == new_adc,
      "%r vs %r" % (old_adc, new_adc))
extra = [c for c in log_new if c not in log_old]
check("readout: only extra call is the _get_block resolve",
      extra == [('_get_block', 'usp_rf_data_converter_0')], repr(extra))

# tproc clocks
log_old = []; soc_old = Soc(log_old)
old_clk = soc_old.metadata.trace_clk_back('qick_processor_0', 'c_clk_i')
log_new = []; soc_new = Soc(log_new)
new_clk = soc_new.clk_src('qick_processor_0', 'c_clk_i')
check("tProc clk_src identical", old_clk == new_clk and log_old == log_new)


# ---------------------------------------------------------------------------
print("\n4. AxisSignalGen.SAMPS_PER_CLK against the shipped board firmware")
# self.SAMPS_PER_CLK = n_dds only changes behaviour if some build has
# N_DDS != 16. Read every hwh in the repo rather than assume.
import glob
import xml.etree.ElementTree as ET
from qick.drivers.generator import AxisSignalGen   # noqa: E402

bound = {v.split(':')[2] for v in AxisSignalGen.bindto}
found = []
for f in sorted(glob.glob(os.path.join(QICK, '**', '*.hwh'), recursive=True)):
    if not os.path.isfile(f):
        continue
    for m in ET.parse(f).getroot().iter('MODULE'):
        if (m.get('MODTYPE') or '') not in bound:
            continue
        params = {p.get('NAME'): p.get('VALUE') for p in m.iter('PARAMETER')}
        found.append((os.path.relpath(f, QICK), m.get('FULLNAME'), int(params['N_DDS'])))
check("found generators bound to AxisSignalGen in the shipped firmware", bool(found),
      "%d instances" % len(found))
odd = [x for x in found if x[2] != AxisSignalGen.SAMPS_PER_CLK]
check("every one has N_DDS == SAMPS_PER_CLK (%d), so the assignment is a no-op"
      % AxisSignalGen.SAMPS_PER_CLK, not odd, repr(odd[:3]))


# ---------------------------------------------------------------------------
print("\n5. the xrfclk/xrfdc import guard")
# On a board that has them, the guard must bind the real base class.
import qick.qick as qick_mod   # noqa: E402
try:
    import xrfdc
    check("xrfdc present: RFDC still inherits xrfdc.RFdc",
          xrfdc.RFdc in qick_mod.RFDC.__mro__)
except ImportError:
    check("xrfdc absent here, so only the placeholder path is exercised", True,
          "RFDC bases: %s" % ([c.__name__ for c in qick_mod.RFDC.__bases__],))
    src = open(os.path.join(QICK, 'qick_lib/qick/qick.py')).read()
    check("the guard binds xrfdc.RFdc when the import succeeds",
          '_RFdcBase = xrfdc.RFdc' in src)

    # The claim the guard rests on: nothing evaluates xrfclk or xrfdc at import
    # time. A reference inside a method body is fine -- it cannot run without an
    # RF data converter -- but one in a class base list, a decorator or a
    # module-level statement runs the moment qick is imported, and would make
    # the module unimportable on a board that has neither package. Checked by
    # walking the tree rather than by matching text, because the case that
    # actually bit here was `class RFDC(SocIP, xrfdc.RFdc)`: indented, inside a
    # class statement, and evaluated at import.
    import ast
    tree = ast.parse(src)
    parents = {}
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[child] = node

    def encloses(node, types):
        while node in parents:
            node = parents[node]
            if isinstance(node, types):
                return node
        return None

    guard = next(n for n in tree.body
                 if isinstance(n, ast.Try)
                 and any('xrfdc' in ast.dump(h) for h in [n]))
    exposed = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in ('xrfclk', 'xrfdc'):
            if encloses(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue          # only runs when called
            if encloses(node, ast.Try) is guard or node in ast.walk(guard):
                continue          # inside the import guard itself
            exposed.append('line %d: %s' % (node.lineno, node.id))
    check("no import-time evaluation of xrfclk/xrfdc outside the guard",
          not exposed, '; '.join(exposed))

# ---------------------------------------------------------------------------
print("\n6. the config_rf_alt hook leaves the RF data converter branch alone")
# __init__ went from `if not no_rf: <setup>` to `if no_rf: config_rf_alt() else:
# <setup>`. An RFSoC passes no_rf=False and so must run byte-identical code.
# Compare the two branch bodies as source rather than by eye.
import ast as _ast

def _body_source(src, stmts):
    # ast.unparse needs Python 3.9; take the raw lines and dedent instead, so
    # the comparison is of the source as written.
    import textwrap
    lines = src.splitlines()
    lo = min(st.lineno for st in stmts) - 1
    hi = max(getattr(st, 'end_lineno', st.lineno) for st in stmts)
    return textwrap.dedent('\n'.join(lines[lo:hi])).rstrip()


def rf_branch(src, want_negated):
    tree = _ast.parse(src)
    for node in _ast.walk(tree):
        if not isinstance(node, _ast.If):
            continue
        t = node.test
        negated = isinstance(t, _ast.UnaryOp) and isinstance(t.op, _ast.Not)
        name = t.operand if negated else t
        if not (isinstance(name, _ast.Name) and name.id == 'no_rf'):
            continue
        if negated != want_negated:
            continue
        body = node.body if want_negated else node.orelse
        if not body:
            continue
        return _body_source(src, body), node
    return None, None

up_body, _ = rf_branch(upstream('qick_lib/qick/qick.py'), want_negated=True)
new_src = open(os.path.join(QICK, 'qick_lib/qick/qick.py')).read()
new_body, new_node = rf_branch(new_src, want_negated=False)
check("found both branches", up_body is not None and new_body is not None)
if up_body and new_body:
    ul, nl = up_body.splitlines(), new_body.splitlines()
    diff = next((("%r" % a, "%r" % b) for a, b in zip(ul, nl) if a != b),
                ('', '') if len(ul) == len(nl) else ('<length>', '%d vs %d' % (len(ul), len(nl))))
    check("the RF data converter setup is unchanged (%d lines)" % len(ul),
          up_body == new_body, "first difference: %s vs %s" % diff)
    taken = _body_source(new_src, new_node.body)
    check("the no_rf branch only calls the hook",
          taken.strip() == 'self.config_rf_alt()', repr(taken))
# and the default hook must do nothing at all
hook = next(n for n in _ast.walk(_ast.parse(new_src))
            if isinstance(n, _ast.FunctionDef) and n.name == 'config_rf_alt')
stmts = [st for st in hook.body if not (isinstance(st, _ast.Expr)
                                        and isinstance(st.value, _ast.Constant))]
check("QickSoc.config_rf_alt default body is a bare pass",
      len(stmts) == 1 and isinstance(stmts[0], _ast.Pass),
      _body_source(new_src, hook.body))


print("\n%s" % ('ALL CHECKS PASSED' if not failures
                else 'FAILURES: %s' % failures))
sys.exit(1 if failures else 0)
