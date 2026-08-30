# Do we need a newer Vivado?

Short answer: **no**, and upgrading is more expensive than it looks.

## What actually pins the E200 flow to 2022.1

| Pin | Where | Cost to move |
|---|---|---|
| `vivado -version \| fgrep 2022.1` and the same for `vitis` | `PYNQ/sdbuild/Makefile:414-415`, via `KERNEL_VERSION` | one line |
| BSP project name `xilinx-e200-2022.1` | `sdbuild/Makefile:128`, same variable | free (generated) |
| `LINUX_VERSION = 5.15.19-xilinx-v2022.1` | `sdbuild/Makefile:21`, used for `depmod -a` | one line, but must match what PetaLinux builds |
| **The e200 ADI kernel patch, refreshed for linux-xlnx 5.15.19** | `boards/e200/petalinux_bsp` | **the real cost** — a newer PetaLinux builds a different kernel (2023.1 → 6.1.x) and the patch needs re-refreshing |
| PYNQ 3.0.1 itself | submodule | 3.0.1 is aligned with 2022.1; a tools upgrade likely drags in a PYNQ upgrade |

Note the flow is **already off-version on the ADI side and works**:
`hdl/projects/scripts/adi_project_xilinx.tcl:3` declares
`set required_vivado_version "2021.1"`, and we build with 2022.1 plus
`ADI_IGNORE_VERSION_CHECK=1`. (`REQUIRED_VIVADO_VERSION` is also settable from
the environment, which is tidier than blanket-ignoring.) So ADI's HDL tolerates
at least +1 release. Going to 2023.1 puts us +2 past its declared version, with
correspondingly more risk — and the ADI HDL library, not the Xilinx tools, is
what would break.

## Why QICK does not force the issue

- Only **one** Vivado-2023.1-ism blocks QICK on 2022.1: the `RAM_DECOMP` XPM
  parameter (see `patches/0001-*`). Checked exhaustively — every other XPM
  parameter QICK overrides exists in the 2022.1 library.
- tProc v2's IP **synthesises on 2022.1 for xc7z020** with positive slack at
  122.88 MHz. See `docs/feasibility.md`.
- QICK's tProc v2 projects only ship `bd_2023-1.tcl` (the v1 projects ship
  `bd_2022-1.tcl`). That matters less than it appears: **we are not replaying
  QICK's block design.** We integrate their IP into the antsdr-pynq base design
  and write our own BD. The upstream BD tcl version is not on our path.

The caveat worth stating: no one upstream has validated tProc v2 on 2022.1, so
we are first. That is a real risk, just a smaller one than a toolchain migration.

## If an upgrade is ever needed

**Overlay-only (moderate risk).** PYNQ overlays are `.bit` + `.hwh` loaded at
runtime, so a newer-Vivado overlay could in principle run on the existing
2022.1 image. But the overlay is a *modified base design* built against ADI's
`hdl_2019_r2+550`, so this means building ADI HDL two releases past its declared
version, and PYNQ 3.0.1's `.hwh` parser has to accept a 2023.1 `.hwh`.

**Full upgrade (days).** Vivado + Vitis + PetaLinux together, re-refreshing the
ADI kernel patch against the new kernel, moving PYNQ to a matching release, and
re-validating everything. It would also invalidate the hardware validation
already done on this image.
