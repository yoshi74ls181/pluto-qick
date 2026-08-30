# Third-party code and licensing

## QICK — MIT
<https://github.com/openquantumhardware/qick>, Copyright (c) Open Quantum Hardware.

This project ports a subset of QICK's firmware and software. QICK sources are
**not vendored** here: the build fetches upstream QICK at a pinned commit and
applies the patches in `patches/`. That keeps attribution unambiguous and makes
it obvious what we changed.

## Analog Devices HDL — see upstream
The AD9361 datapath comes from the ADI `hdl` repository via
[`antsdr-pynq`](https://github.com/yoshi74ls181/antsdr-pynq). ADI's HDL carries
its own licence, which is **more restrictive than MIT** for non-ADI silicon.
Read it before redistributing bitstreams built from it.

## PYNQ — BSD 3-Clause
<https://github.com/Xilinx/PYNQ>
