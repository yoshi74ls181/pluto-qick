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

## Not covered

The test isolates `ctrl_sg_v6`, so it says nothing about:

- the DDS compiler's own output at `N_DDS=1` (needs the regenerated 7-series IP
  in the loop)
- envelope-memory addressing, `mem_addr_o`
- the output multiplexer and gain path
- a sweep over `PINC`, waveform length, or `phrst`/`stdysel` combinations

## Reproducing

```
export QICK_ROOT=$PWD/third_party/qick
source /tools/Xilinx/Vitis/2022.1/settings64.sh
./sim/run_sim.sh
```
