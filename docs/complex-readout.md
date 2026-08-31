# A complex-input readout for the AD9361

## Why

`axis_readout_v2` takes a **real** ADC stream (`s_axis_tdata [N_DDS*16-1:0]`) and
does its own digital down-conversion. That suits an RFSoC sampling a real IF, but
the AD9361 has already quadrature-downconverted to complex baseband. Feeding it
real samples means either throwing away Q, or offsetting the LO so the tone sits
at a real IF and spending half the RX band on an image that gets filtered away.

Patch 0006 adds `INPUT_TYPE`, following the `ENVELOPE_TYPE` idiom already used by
`axis_signal_gen_v6`:

| `INPUT_TYPE` | `s_axis` width | mixer |
|---|---|---|
| `"REAL"` | `N_DDS*16` | `x*cos`, `x*sin` (upstream, unchanged) |
| `"COMPLEX"` | `N_DDS*32` | `I*cos - Q*sin`, `I*sin + Q*cos` |

The two are separate `generate` branches, so the REAL path is bit-identical to
upstream rather than a refactor of it.

## Overflow

The real path multiplies two Q1.15 values, so a 32-bit product cannot overflow.
The complex path adds two such products, and `I*cos - Q*sin` reaches √2 × full
scale when I and Q are both large — which an AD9361 will produce for a signal
near the band edge. The complex branch therefore carries the sum in 33 bits and
saturates to 16, instead of wrapping. A single complex tone of magnitude A
produces a product of magnitude A, so nothing saturates below full scale; the
headroom only matters for independently-large I and Q.

## N_DDS was not overridable

`N_DDS` was a `localparam` in `axis_readout_v2.v`, `readout_top.v` and
`down_conversion_fir.v`. Worth knowing because passing `-generic N_DDS=1` to
synthesis is **silently ignored** for a localparam — earlier out-of-context
synthesis runs here that thought they were measuring one lane were measuring
eight. It is now a real `parameter`, threaded through all three levels.

## The FIR has to match

`fir_compiler_0` is a super-sample-rate decimator, and its input width is
`Number_Paths * Data_Width * (Decimation_Rate / SamplePeriod)`:

| `SamplePeriod` | input rate | `s_axis` |
|---|---|---|
| 1 | 8 samples/clock | 256 bit (QICK, RFSoC) |
| 8 | 1 sample/clock | 32 bit (E200, 122.88 MHz) |

Same `../fir.coe` (121 taps), same decimate-by-8 — only the parallelism changes,
which also cuts the DSP count by 8×. Regenerate with:

    export QICK_ROOT=$PWD/third_party/qick
    vivado -mode batch -source syn/regen_readout_fir_ndds1.tcl

Two traps that script documents: `SamplePeriod` is read-only on an existing IP
(so it must be created fresh, not edited via `read_ip`/`import_ip`), and
`Coefficient_File` and `CoefficientSource` cannot be set one at a time — setting
`CoefficientSource` to `COE_File` validates that a file is already loaded, and
setting `Coefficient_File` alone is silently discarded. They need one atomic
`set_property -dict`.

## Verification

`sim/tb_readout_complex.sv` instantiates `down_conversion` twice, REAL and
COMPLEX, sharing one control word so both see the same DDS phase. Run with:

    vivado -mode batch -source sim/run_sim_readout.tcl

**Equivalence.** Driving COMPLEX with Q=0 makes the complex product reduce
algebraically to the real one. Over 1979 samples the outputs match bit for bit,
which is what establishes that the REAL path still behaves as upstream.

**Single sideband.** A true complex tone gives a flat envelope, because mixing
two complex exponentials yields exactly one tone:

    COMPLEX in : |out| in [14997.8, 14999.8]   ripple 0.01 %
    REAL    in : |out| in [    0.0, 14999.5]   ripple 100.00 %

The real path fed the same signal produces `cos(w_in t) * e^{jw_lo t}`, two tones
whose sum beats to zero — the 100 % figure is the image, and the 0.01 % is its
absence.

One simulator note: `import_ip` of QICK's DDS lands **locked**, because the
`.xci` was customised for `xczu49dr`. `upgrade_ip` retargets it. The block-design
flow does this automatically when the DDS is pulled in as a subcore, which is why
this only bites in a standalone sim project.

## Confirmed on hardware

The overlay has been loaded on a real E200 and QICK's discovery reports the
readout as expected:

    axis_readout_v2 - fs=15.360 Msps, decimated=1.920 MHz, 32-bit DDS
    axis_avg_buffer v1.2 (has edge counter, no weights)
    memory 16384 accumulated, 4096 decimated
    triggered by tport 0, pin 0, feedback to tProc input 0

`decimated = fs/8` is the regenerated 1-lane FIR doing its decimate-by-8 at one
sample per clock, which is the part of this change that could not be checked
without hardware. `tools/smoke_e200.py` reproduces the run.

Sample rate is read back from the AD9361 rather than assumed: reprogramming the
PL resets `axi_ad9361` and the driver re-establishes the rate. It moved from
30.72 to 15.36 MHz across a load here, so a value captured beforehand would
have described the wrong hardware.

## The regenerated FIR, verified in simulation

`syn/regen_readout_fir_ndds1.tcl` rebuilds `fir_compiler_0` at `SamplePeriod 8`,
and that filter was the one part of this change existing only as a generated
artifact -- nothing checked that the regeneration preserved either the rate
change or the response. `sim/tb_fir_decim.sv` now does, driving the whole
`down_conversion_fir` (complex mixer plus filter) at `N_DDS=1`:

    vivado -mode batch -source sim/run_sim_fir.tcl

    Decimation cadence
      m1_axis_tvalid asserted 100 times in 800 clocks
      gap between valids: min 8, max 8      -> decimate-by-8, one sample/clock

    Filter response (input amplitude 20000)
      f = fs/512  (deep passband) : 10253.1
      f = fs/64   (passband)      : 10112.3
      f = 3fs/16  (stopband)      :     3.2   -> 70.2 dB rejection

The cadence check matters because a wrong `SamplePeriod` is the failure mode that
would look plausible: the filter would still decimate by 8, but consume eight
samples per clock instead of one, so the rate would appear right while the data
was wrong. Checking the gap between valids catches that directly.

The response check uses `outsel = 2` (raw input passthrough) so the DDS does not
move the tone away from the frequency under test. Passband gain is about 0.51 of
the input, which is the same product scaling the mixer testbench sees.

Two notes for anyone re-running it: the `.xci` files were customised for
`xczu49dr`, so `import_ip` lands them locked and `upgrade_ip` is needed to
retarget; and `fir.coe` must be staged beside the imported IP *before*
`generate_target`, or generation fails with "Invalid COE File - Unable to open
the file".
