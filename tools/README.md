# validate_hwh.py

Exercises QICK's connectivity tracing against an overlay's `.hwh`, on the host,
with no board and no PL programming. `QickMetadata` only needs an XML root, so
the whole discovery surface the drivers rely on can be checked before the
bitstream is ever deployed:

    PYTHONPATH=tools/stubs:../qick/qick_lib \
      python3 tools/validate_hwh.py path/to/system.hwh

`stubs/` holds do-nothing `pynq` and `tqdm` modules. `qick.ip` imports
`pynq.overlay.DefaultIP` as a driver base class and `qick` pulls in `tqdm`, but
neither is used by the parsing code, so stubbing them is enough and avoids
needing PYNQ on a development machine.

## What it checks

- every QICK block is present with the expected IP type
- hwh parameters the drivers read (`N_DDS`, `N`, `ENVELOPE_TYPE`)
- DMA discovery via `trace_dma`, including that the switchless path returns
  `(dma, None, None)`
- signal paths that pass *through* intermediate blocks: `sg0/s1_axis` back to
  the tProc through `sg_translator`, and `avg0/m2_axis` forward to the tProc
  through the clock converter
- `trace_trigger`, which must resolve `qick_processor_0/trig_0_o` to
  `('tport', 0, 0)` via the direct-connection branch

## The clock annotation is wrong, deliberately not trusted

`get_fclk` reports **100 MHz** for `c_clk_i`, `t_clk_i`, `sg0/aclk` and
`ro0/aclk`. Those all run on `util_ad9361_divclk/clk_out`, which is 122.88 MHz
in hardware. The hwh has no truthful value to report: the divider ratio is
selected at runtime from the AD9361 configuration, so no single number is
correct, and Vivado has annotated a default.

This is why `QickSocE200` overrides `clk_src` rather than letting the tProc
driver call `get_fclk`. Trusting the annotation would put every tProc time
value out by 22 %. The two `KeyError`s on `avg0/s_axis_aclk` and
`avg0/m_axis_aclk` are missing annotations on pins nothing reads
(`AxisAvgBuffer` has no `trace_clocks`), and are harmless.
