# tProc v2 sized for the E200: one AD9361 TX pair, ARITH off (its DSP macro is
# a 27x18 DSP48E2, unavailable on 7-series), small memories.
set name   tproc_v2_minimal
set qick   $env(QICK_ROOT)
set top    axis_qick_processor
set src_dirs [list $qick/firmware/ip/qick_processor/src]
set extra_files [list [file normalize [file dirname [info script]]/../stubs/dsp_macro_0_stub.v]]
set generics {
    ARITH=0 DIVIDER=0 LFSR=1 DEBUG=0 QCOM=0 QNET=0 CUSTOM_PERIPH=0
    PMEM_AW=10 DMEM_AW=10 WMEM_AW=8 REG_AW=4
    IN_PORT_QTY=2 OUT_TRIG_QTY=4 OUT_WPORT_QTY=2 OUT_DPORT_QTY=1 OUT_DPORT_DW=4
}
# 122.88 MHz = 4 x 30.72 MSPS, the antsdr-pynq template overlay clock.
set clocks {
    "create_clock -period 8.138 -name c_clk  [get_ports c_clk_i]"
    "create_clock -period 8.138 -name t_clk  [get_ports t_clk_i]"
    "create_clock -period 10.000 -name ps_clk [get_ports ps_clk_i]"
    "set_clock_groups -asynchronous -group c_clk -group t_clk -group ps_clk"
}
