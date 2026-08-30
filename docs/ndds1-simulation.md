# Is `N_DDS=1` actually correct?

`axis_signal_gen_v6` must run at one sample per clock to match the AD9361;
QICK only ever ships `N_DDS >= 4` for RFSoC RF-DACs. The IP-XACT permits
`minimum="1"` and it synthesises, but neither of those is evidence of
correctness. `sim/tb_ndds_equiv.sv` checks it.

**Result: PASS** for the phase-generation path.

```
pinc_N: ref[0]=004b5a1c (want 004b5a1c)  cnd[0]=0012d687 (want 0012d687)  bad=0
lane offsets: 0 deviation(s) from i*PINC (ref) / 0 (cnd)
effective phase: 0 mismatch(es) over 128 samples
RESULT: PASS - N_DDS=1 is equivalent to N_DDS=4 per sample
```

## What the invariant is

With `N` lanes on one clock, lane `i` of clock `t` carries sample `s = t*N + i`.
`dds_ctrl_o` packs `{sync, phase, pinc_N}`, and the key thing to understand is
that **`phase` is a static per-lane start offset, not a running phase** —
`cnt_n_reg` only latches at `sync`, so the accumulation happens inside the DDS
compiler at `pinc_N` per clock. Therefore:

    effective phase(s) = phase[i] + t * pinc_N
                       = i*PINC   + t * (N*PINC)
                       = (t*N + i) * PINC
                       = s * PINC

independent of `N`. The test drives an `N_DDS=4` reference and an `N_DDS=1`
candidate with identical `PINC`, reconstructs the effective phase on both, and
requires them to agree sample-for-sample — and to equal `s*PINC`.

Confirmed by the run: `pinc_N` scales (4x for the reference, 1x for the
candidate) while the lane offsets are `i*PINC` and `0` respectively, and the
reconstructed phases match exactly.

## Two traps worth recording

Both cost time and would mislead anyone repeating this.

**`mode=1` is periodic replay, not "enable".** `READ_ST: if (mode_int ||
~fifo_empty_i) state <= CNT_ST;` re-enters the counting state unconditionally,
and `sync_reg <= load_r` fires on every reload. With `phrst=1` that resets the
phase accumulator every period, so the base phase never advances. Use `mode=0`
for one-shot.

**`nsamp` is in clocks, not samples.** `cnt_nsamp_r` decrements once per clock
and each clock emits `N_DDS` samples, so a waveform of `L` samples needs
`nsamp = L/N_DDS`. QICK's own `tb.sv` hints at this with `nsamp_r <= 400/N_DDS`.
This matters for the software port: any `nsamp` computation must divide by
`N_DDS`.

## Envelope fetch and output mux — `sim/tb_ndds_envmux.sv`

**Result: PASS.**

```
--- src=2 : best sample shift = 3   output: 0 mismatch(es) over 96 samples   mem_addr_o: 0 step(s) != +1
--- src=3 : best sample shift = -16 output: 0 mismatch(es) over 96 samples   mem_addr_o: 0 step(s) != +1
--- src=1 : best sample shift = -8  output: 0 mismatch(es) over 96 samples   mem_addr_o: 0 step(s) != +1
--- src=0 : best sample shift = 3   output: 0 mismatch(es) over 96 samples   mem_addr_o: 0 step(s) != +1
RESULT: PASS - all four source selections agree
```

The envelope is stored **interleaved** across `N_DDS` block RAMs — lane `i` at
address `a` holds sample `a*N_DDS + i` — and `addr_cnt` advances by 1 per clock
regardless of `N_DDS`. The test models that contract with a one-clock-latency
memory on each DUT and compares output streams for every source selection:
`0` product, `1` DDS, `2` envelope, `3` zero.

**Read the two vacuous passes with care.** With `GEN_DDS="FALSE"` the DDS
becomes a full-scale constant, so `src=1` emits a constant and `src=3` emits
zero. Those match at *any* shift, which is why their reported best-shift is
arbitrary (`-8`, `-16`). Only `src=2` and `src=0` genuinely exercise the
envelope path. Testing `src=1` meaningfully needs the regenerated 7-series DDS
in the loop.

The two meaningful cases both landed on **shift = 3**, which is a useful
self-consistency check: `L` clocks of pipeline latency displaces the
`N_DDS=4` reference by `4L` samples and the `N_DDS=1` candidate by `L`, so the
relative offset is `3L`. Shift 3 implies `L = 1` — exactly the one-clock memory
latency modelled. A wrong interleaving would not produce a clean single-shift
match at all.

### A third trap

The first version of this test used a *zero-latency* combinational memory and
failed all 96 samples on both envelope selections. That was the testbench, not
the design: real BRAM has read latency, and `signal_gen`'s `latency_reg` stages
are there to align it. Because one address feeds `N_DDS` samples, a latency of
`L` clocks shifts the two configurations by *different sample counts*, so raw
sequence comparison cannot work — the comparison has to be shift-tolerant.

## Not covered

- the DDS compiler's own output at `N_DDS=1` (needs the regenerated 7-series IP
  in the loop); consequently `src=0`/`src=1` are only tested with the DDS
  stubbed to a constant
- a sweep over `PINC`, waveform length, or `phrst`/`stdysel` combinations
- `ENVELOPE_TYPE="COMPLEX"` (both tests drive `mem_dout_imag_i = 0`)
- the AXI-Lite register path and the real `axis_signal_gen_v6` top level

## Reproducing

```
export QICK_ROOT=$PWD/third_party/qick
source /tools/Xilinx/Vitis/2022.1/settings64.sh
./sim/run_sim.sh
```
