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

## Where work happens

| What | Where |
|---|---|
| Firmware, simulation, synthesis, docs | **this repo** |
| Python (`QickSoc`/`RFDC` → AD9361 backend, driver changes) | [`yoshi74ls181/qick`](https://github.com/yoshi74ls181/qick), branch `e200-ad9361-backend` |

Python changes belong in the QICK fork so they stay rebaseable on upstream and
can be offered back as a PR. This repo keeps only what is genuinely
E200-specific.

## Next step

`N_DDS=1` is verified for the phase path
([docs/ndds1-simulation.md](docs/ndds1-simulation.md)). Remaining before
integration:

1. Extend the simulation to cover envelope addressing (`mem_addr_o`) and the
   output mux at `N_DDS=1`, with the regenerated 7-series DDS in the loop.
2. Synthesize `axis_avg_buffer` — the last unmeasured block.
3. First overlay: tProc v2 + 1 gen + 1 readout into the antsdr-pynq `template`
   overlay insertion point.

## Toolchain setup

`setup/xilinx-env.sh` defines `use_vivado`, `use_vitis`, `use_petalinux` and
`xilinx_env`. Source it from `~/.bashrc`:

```sh
_xe="$HOME/pluto/pluto-qick/setup/xilinx-env.sh"
[ -r "$_xe" ] && source "$_xe"; unset _xe
```

It deliberately activates **nothing** at login. Sourcing the Xilinx settings
scripts eagerly is harmful: `settings64.sh` sets `LD_LIBRARY_PATH`, and bitbake
refuses to run when it is set (`Your environment is misconfigured`), so the
`make pynq` flow needs a shell where it ends up unset. PetaLinux's
`settings.sh` also prints a banner and runs checks on every login, and each
sourcing appends to `PATH`.

`use_petalinux` encodes the order the antsdr-pynq build needs — Vitis first,
then PetaLinux, `LD_LIBRARY_PATH` cleared, and `/opt/qemu/bin` ahead of the
distro's qemu 4.2.1 since sdbuild requires 5.2.0.

## Licence

MIT, matching QICK. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) — note
that the ADI HDL reached through antsdr-pynq carries more restrictive terms than
MIT for non-ADI silicon.
