# Complex I/Q output

The AD9361 takes baseband I/Q. QICK's generators are built for RFSoC RF-DACs,
which take a real stream. **Resolved** by `patches/0002-*`.

## What `axis_signal_gen_v6` computed originally

`ENVELOPE_TYPE="COMPLEX"` does not mean complex output. It selects whether a
second BRAM holds the imaginary envelope (`signal_gen_top.v:183`); the datapath
then computed, in `signal_gen.v`:

```
prod_y_full_real_a = cos * env_re
prod_y_full_real_b = sin * env_im
prod_y_full_real   = real_a - real_b            // Re[env * e^jwt]
// assign prod_y_full_imag_a[i] = ...           <- commented out
// assign prod_y_full_imag_b[i] = ...           <- commented out
```

The complex envelope bought single-sideband upconversion, but the bus was
`N_DDS*16` — one **real** sample per lane. The imaginary partial products were
commented out because an RF-DAC has no use for them.

## Why not reuse `axis_sg_int4_v1` instead

It looked attractive: its imaginary partial products are live and it already
outputs `N_DDS*32`. Two things ruled it out.

Its envelope input is a single `[15:0]`, not `N_DDS*16` — because a **FIR
Compiler** (`src/fir_0/fir_0.xci`, generated for an RFSoC part) sits between the
envelope memory and the multiplier doing 4x interpolation. That is what "int4"
means. At `N_DDS=1` the interpolation is meaningless, so adopting it would mean
deleting that FIR, re-deriving the `latency_reg` constants that are written
against its "Cycle latency + 1 = 11 + 1 = 12", and re-verifying `N_DDS=1`
behaviour for a module with no test coverage.

Also `axis_sg_int4_v1.v:64` fixes the lane count as `localparam [31:0] N_DDS = 4`
and exposes only `N`.

Extending v6 was the lower-risk path: its `N_DDS=1` behaviour is already
verified three ways (see [ndds1-simulation.md](ndds1-simulation.md)) and there is
no interpolator to remove.

## What the patch does

```
real = cos*env_re - sin*env_im      (unchanged)
imag = cos*env_im + sin*env_re      (restored)
```

`m_axis_tdata` widens to `N_DDS*32`, packed `{Q,I}` with I in the low half.
Every imaginary stage mirrors its real counterpart register-for-register,
including a second `latency_reg` for the Q side of the mux — a depth mismatch
would skew Q against I, which is the subtle failure mode and does not look
obviously broken.

For `src=1` Q carries sin, for `src=2` it carries the imaginary envelope. With
`GEN_DDS="FALSE"` Q is held at zero rather than mirroring I, which would look
like a constant 45-degree tone.

### Verification — `sim/tb_iq_ssb.sv`

A constant real envelope should give `A * e^jwt`, whose spectrum is **one-sided**:

```
image rejection : 110 dB        (a real stream gives ~0 dB)
|z| ripple      : 0.024%        (constant envelope -> constant magnitude)
tone frequency  : +0.00967 fs   (target +0.00977, within a bin)
```

Image rejection tests the sign convention and the I/Q pipeline alignment at
once, which is what is easy to get wrong. The magnitude-ripple check is
independent: skewed or mis-signed I/Q makes `|z|` wobble.

### Cost on xc7z020 at `N_DDS=1`

| | real-only | complex | delta |
|---|---|---|---|
| LUT | 758 | 1,040 | +282 |
| FF | 1,516 | 1,986 | +470 |
| BRAM | 8.5 | 8.5 | 0 |
| DSP | 3 | 9 | +6 |

Negligible against 53,200 LUT and 220 DSP.

## A trap found on the way: the DDS phase width is fs-dependent

QICK's DDS is customised in `System_Parameters` mode asking for
`Frequency_Resolution = 0.06` Hz. In that mode the tool **derives**
`Phase_Width = ceil(log2(fs/res))`, and an explicit `Phase_Width` is ignored —
it is a disabled parameter, which the tool says only in a warning.

At the E200's 122.88 MHz:

```
fs/2^31 = 0.0572 Hz    <- 0.06 is coarser, so 31 bits suffice
fs/2^32 = 0.0286 Hz
```

so the regenerated IP came out with a **31-bit** accumulator and every
synthesised tone landed at **exactly twice** the intended frequency. The
simulation caught it: the tone appeared at 0.01959 fs against a 0.00977 target.
On an RFSoC, fs is ~40x higher and 0.06 Hz comfortably forces 32 bits, which is
why upstream never sees this.

`Hardware_Parameters` mode fixes the width but then derives SFDR **down to 45 dB**
from 96 — a bad trade. The fix is to stay in `System_Parameters` and compute the
requested resolution from fs so it lands mid-window:

```tcl
set fs_hz [expr {122.88e6}]
set fres  [expr {$fs_hz * 1.5 / pow(2,32)}]   ;# 0.0429 Hz here
```

which yields `Phase_Width = 32` **and** `SFDR = 96`. Both `sim/` and `syn/`
configs do this. **If the sample rate changes, this recomputes — do not
hardcode the resolution.**

One measurement not chased: the worst spur sits ~43 dB below carrier regardless
of whether SFDR is 45 or 96, so it is not the DDS. Most likely Hanning leakage
in the analysis rather than a real spur, but it was not investigated.
