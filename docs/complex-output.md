# The signal generator emits a real stream, not I/Q

This is the one gap found so far that needs real HDL work rather than
configuration, and it is on the critical path: the AD9361 takes baseband I/Q,
while QICK's generators are built for RFSoC RF-DACs that take a real stream.

## What `axis_signal_gen_v6` actually computes

`ENVELOPE_TYPE="COMPLEX"` does **not** mean complex output. It controls whether
a second block RAM holds the imaginary envelope (`signal_gen_top.v:183`). The
datapath then computes, in `signal_gen.v:347-354`:

```
prod_y_full_real_a = prod_a_real * prod_b_real     // cos * env_re
prod_y_full_real_b = prod_a_imag * prod_b_imag     // sin * env_im
prod_y_full_real   = real_a - real_b               // cos*env_re - sin*env_im
// assign prod_y_full_imag_a[i] = prod_a_real[i]*prod_b_imag[i];   <- commented
// assign prod_y_full_imag_b[i] = prod_a_imag[i]*prod_b_real[i];   <- commented
```

That is `Re[env * e^{jwt}]`. The complex envelope buys single-sideband
upconversion (an asymmetric spectrum), but the output bus is `N_DDS*16` — one
**real** 16-bit sample per lane. The imaginary partial products are commented
out because an RF-DAC has no use for them.

## QICK does have complex-output generators

`axis_sg_int4_v1` and `axis_sg_int4_v2` output `N_DDS*32` bits — 16-bit I plus
16-bit Q per lane — and their imaginary partial products (`prod_y_full_imag_a/b`)
are live, not commented. So the complex arithmetic exists upstream.

The catch is parameterisation. In `axis_sg_int4_v1.v:64` the lane count is a
**localparam**:

```
localparam [31:0] N_DDS = 4;
```

Only `N` (memory depth) is exposed as an IP parameter. The inner
`signal_gen`/`signal_gen_top` do carry `N_DDS` as a real parameter, but the "int4"
name reflects 4x interpolation as a structural property, so forcing one lane is
not obviously safe.

## Recommendation

Extend `axis_signal_gen_v6` rather than bend `axis_sg_int4_v1`, because v6's
`N_DDS=1` behaviour is already verified (see
[ndds1-simulation.md](ndds1-simulation.md)) and the change is small:

1. Restore the two commented imaginary partial products.
2. Add `prod_y_full_imag = imag_a + imag_b` and quantise it like the real path.
3. Widen `m_axis_tdata` to `N_DDS*32` and pack `{Q, I}`.
4. Carry the second component through the gain stage and output mux.

Cost is 2 extra 16x16 multiplies per lane. At `N_DDS=1` v6 currently uses 3
DSPs of 220, so this is negligible on a 7z020.

The alternative — feeding the complex envelope straight out as I/Q and letting
the AD9361 LO do all frequency placement — avoids HDL changes but gives up the
DDS's fine frequency control and deterministic phase, which is much of why one
would want QICK in the first place.

## Consequence for the simulation

`sim/tb_ndds_envmux.sv` runs with `GEN_DDS="FALSE"`, where the product path
degenerates to `mem >> 1` and the imaginary envelope input is unused. So
`ENVELOPE_TYPE="COMPLEX"` is **not** meaningfully covered yet: exercising it
needs the regenerated 7-series DDS compiler in the simulation loop, so that
`prod_a_real`/`prod_a_imag` carry real cos/sin values.
