# Feasibility: QICK tProc v2 on the AntSDR E200

All numbers measured on `xc7z020clg484-1`, Vivado 2022.1, out-of-context
synthesis. Reproduce with `syn/run.sh` (see below).

## Resource budget — not the constraint

| Block | LUT | FF | BRAM | DSP |
|---|---|---|---|---|
| antsdr-pynq base AD9361 design *(post-place)* | 12,945 | 20,391 | 4 | 28 |
| **tProc v2** (`ARITH=0 DIVIDER=0 PMEM_AW=10 DMEM_AW=10 WMEM_AW=8`, 2 wave ports) | 5,758 | 5,290 | 19 | 1 |
| `axis_signal_gen_v6` (`N_DDS=1 N=12`) | 758 | 1,516 | 8.5 | 3 |
| `axis_readout_v2` (`N_DDS=1`) | 1,662 | 3,336 | 16 | 2 |
| **1 TX + 1 RX total** | **21,123 (40%)** | **30,533 (29%)** | **47.5 (34%)** | **34 (15%)** |

xc7z020 has 53,200 LUT / 106,400 FF / 140 BRAM / 220 DSP. A 2 TX + 2 RX build
lands near 48% LUT and 66% BRAM. `axis_avg_buffer` is **not** in that total.

All blocks inferred 7-series primitives only (RAMB36E1/RAMB18E1, DSP48E1) — no
DSP48E2 or URAM leaked in.

## Timing

tProc v2 constrained at 122.88 MHz (4 × 30.72 MSPS, the antsdr-pynq template
overlay clock): **WNS +0.387 ns**, post-synthesis. QICK runs the tProc at
215.04 MHz on ZCU216, so we ask less of a slower fabric.

Caveat: +0.387 ns of an 8.138 ns period is 4.8% margin, and this is
**post-synthesis, out-of-context**. Post-route will be worse and is unverified.

## Porting blockers

1. **`RAM_DECOMP`** — QICK targets Vivado 2023.1; this XPM parameter does not
   exist in 2022.1. Fixed by `patches/0001-*`. Verified exhaustively: it is the
   *only* XPM parameter QICK overrides that 2022.1 lacks. See
   [vivado-version.md](vivado-version.md).
2. **`dsp_macro_0` is RFSoC-only** — a 27×18 DSP48E2 macro generated for
   `xczu49dr`. 7-series DSP48E1 is 25×18, so it cannot be regenerated as-is.
   It is instantiated only inside `generate if (ARITH == 1)`, so `ARITH=0`
   avoids it. But the `.xci` sits in the IP's *synthesis* fileset, so the
   packaged IP needs repackaging, or a stub — see `stubs/`. Enabling `ARITH`
   needs a real 25×18 or cascaded-DSP replacement.
3. **DDS Compiler regenerates for 7-series**, but in `System_Parameters` entry
   mode it derives `Phase_Width=31`, not QICK's 32
   (`WARNING: [IP_Flow 19-3374] ... 'Phase_Width' from '31' to '32' has been
   ignored`). That changes frequency resolution. Use `Hardware_Parameters`
   entry to force 32.
4. **Sources live in subdirectories** (`src/fifo/`), which naive globbing misses.

## Software — the good news

- `Axis_QICK_Proc` (the tProc v2 driver, `drivers/tproc.py`) has **zero**
  references to RF/DAC/ADC.
- `asm_v2.py` has **zero** RFSoC references. `tprocv2_assembler.py` appears to
  have 8, but they are opcode bit patterns like `'0111'`, not board strings.

So the assembler and program model port **unchanged**. The RFSoC coupling is
concentrated in `qick.py` — 25 references, essentially `class RFDC(SocIP,
xrfdc.RFdc)` and `QickSoc`. That is what an AD9361/libiio backend replaces,
plus the `fs`-dependent frequency↔register conversions in the
generator/readout drivers.

## What limits the physics, not the FPGA

- **Bandwidth and channels.** AD9361 is ≤61.44 MSPS I/Q, ≤56 MHz RF bandwidth,
  2 TX / 2 RX — versus GS/s direct synthesis and 8–16 channels on RFSoC. You
  generate baseband and let the AD9361 LO upconvert, rather than synthesising
  the drive tone directly.
- **LO phase indeterminacy.** The AD9361 LO is fractional-N. Baseband DDS phase
  is deterministic, but each retune adds an unknown constant phase. Fixed-LO
  operation with a calibrated offset is fine; fast frequency hopping with known
  phase is not.
- **Feedback latency.** The AD9361 decimation/interpolation chains add tens to
  hundreds of samples. At 32.5 ns/sample that is µs-scale — fine for many
  experiments, poor for fast mid-circuit feedback, which is a headline tProc v2
  feature.

## Not yet verified

- ~~`N_DDS=1` functional correctness~~ — **now verified for the phase path.**
  See [ndds1-simulation.md](ndds1-simulation.md). Still uncovered at N_DDS=1:
  the DDS compiler output itself, envelope-memory addressing (`mem_addr_o`),
  and the output multiplexer.
- `axis_avg_buffer` resource cost.
- Post-route timing.
- I/Q pairing: the siggen emits a real stream for an RF-DAC, so complex output
  must be routed from `mem_dob_real`/`mem_dob_imag`.

## Reproducing

```
git clone https://github.com/openquantumhardware/qick.git third_party/qick
git -C third_party/qick apply ../../patches/0001-*.patch
export QICK_ROOT=$PWD/third_party/qick
source /tools/Xilinx/Vitis/2022.1/settings64.sh
./syn/run.sh
```
