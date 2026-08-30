# Getting QICK's packaged IP to instantiate on Zynq-7000

Two independent blockers stop QICK's IP-XACT packages from being used in a
Vivado 2022.1 block design for `xc7z020clg400-2`. Both are metadata problems,
not RTL or resource problems.

## 1. `supportedFamilies` (patch 0003)

`axis_signal_gen_v6` and `axis_readout_v2` declare only `zynquplus`:

    ERROR: [BD 5-683] VLNV <QICK:QICK:axis_signal_gen_v6:1.0> is not supported
    for the current part.

`qick_processor` and `axis_avg_buffer` ship *no* `supportedFamilies` block, which
is exactly why those two instantiated unmodified while the other two did not.
Adding `zynq` alongside `zynquplus` is sufficient.

## 2. `cell_name` in JSON `.xci` (patch 0004)

Some subcore `.xci` files were written by a newer Vivado, which records a
`cell_name` provenance field. The 2022.1 JSON schema disallows it:

    ERROR: [IP_Flow 19-8166] Failed to verify json document against the schema
    { "additionalProperties": { "disallowed": "cell_name", ... } }
    CRITICAL WARNING: [IP_Flow 19-979] Failed to recreate IP instance
    'fir_compiler_0'. Error setting original project options.

`axis_signal_gen_v6`'s DDS happens not to carry the field, so it generated while
`axis_readout_v2` (whose FIR *and* DDS both carry it) did not.

## What Vivado retargets for you

With both patches applied, all four IP generate for `xc7z020clg400-2`, and
Vivado retargets the DDS/FIR subcores itself (`ARCHITECTURE` becomes `zynq`).
Critically it *preserves* the parameters the RTL depends on:

| DDS parameter | value | why it matters |
|---|---|---|
| `Phase_Width` | 32 | `signal_gen.v` is written against a 32-bit accumulator |
| `Latency` | 10 | `signal_gen.v` pipeline depth assumes 10, not Auto=9 |
| `Phase_Increment` | Streaming | per-sample frequency control |
| `Resync` | true | phase reset on `phrst` |
| `SFDR` | 96 | sets the LUT/Taylor-correction structure |

This is a better outcome than recreating the DDS from scratch, which is how the
OOC synthesis configs in `syn/cfg/` do it: there the phase width is *derived*
from `DDS_Clock_Rate` and `Frequency_Resolution`, and getting it wrong silently
yields a 31-bit accumulator, i.e. every tone at exactly 2x the intended
frequency. Retargeting keeps `DDS_Clock_Rate 256`, which derives 32 bits by
construction. The readout's 121-tap `fir.coe` is copied through byte-identical.

## Still not usable: `dsp_macro_0`

`qick_processor`'s `dsp_macro_0` *generates* for zynq, but keeps `a_width` and
`d_width` at 27. A DSP48E1 is 25x18 (DSP48E2 is 27x18), so this only maps by
decomposing across slices. Generation succeeding is not evidence it maps well:
the overlay continues to instantiate `qick_processor` with `ARITH=0` and stub
`dsp_macro_0` out, as `syn/cfg/` already does.
