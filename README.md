# pluto-qick

Porting a subset of [QICK](https://github.com/openquantumhardware/qick) —
specifically **tProcessor v2** — to the [MicroPhase AntSDR
E200](https://github.com/MicroPhase/antsdr-fw) (Zynq-7020 + AD9361) running
PYNQ, on top of
[antsdr-pynq](https://github.com/yoshi74ls181/antsdr-pynq).

QICK targets Xilinx RFSoC boards with multi-GS/s RF data converters. The E200 is
a much smaller, much cheaper part with an AD9361 transceiver instead. This repo
explores how much of QICK's timed-processor model survives that move.

**Status: feasibility established, no integration yet.**

## What is known

Measured, not estimated — see [docs/feasibility.md](docs/feasibility.md).

- **It fits.** tProc v2 + one signal generator + one readout costs ~40% of the
  xc7z020's LUTs and ~34% of its BRAM *on top of* the existing AD9361 base
  design. Resources are not the limiting factor.
- **It closes timing**, marginally: WNS +0.387 ns at 122.88 MHz post-synthesis.
  Post-route is unverified.
- **Vivado 2022.1 is enough.** Exactly one Vivado-2023.1-ism blocks QICK
  (`RAM_DECOMP`); it is a one-line patch. No toolchain upgrade needed — see
  [docs/vivado-version.md](docs/vivado-version.md).
- **The software layer ports nearly free.** QICK's tProc v2 driver and
  assembler contain *zero* RF-specific code. The RFSoC coupling is confined to
  `QickSoc`/`RFDC`.
- **The real limits are physical, not logical**: ≤56 MHz RF bandwidth, 2 TX /
  2 RX, an LO whose phase is indeterminate across retunes, and µs-scale
  datapath latency that constrains fast feedback.

## Layout

```
docs/feasibility.md     measured resources, timing, blockers, open questions
docs/vivado-version.md  why we stay on Vivado 2022.1
patches/                minimal changes to upstream QICK (not vendored)
syn/                    out-of-context synthesis harness + per-IP configs
stubs/                  stand-ins for RFSoC-only IP that ARITH=0 excludes
```

Upstream QICK is **fetched, never vendored** — `patches/` shows exactly what we
change and attribution stays unambiguous.

## Next step

Simulate `axis_signal_gen_v6` at `N_DDS=1` against QICK's own testbench. It
synthesises, but QICK only ever ships `N_DDS≥4`, so the per-lane phase-advance
semantics at a single lane are unproven — and every later integration decision
rests on that being sound.

## Licence

MIT, matching QICK. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) — note
that the ADI HDL reached through antsdr-pynq carries more restrictive terms than
MIT for non-ADI silicon.
