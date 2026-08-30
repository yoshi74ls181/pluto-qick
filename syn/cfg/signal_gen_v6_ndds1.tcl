# axis_signal_gen_v6 at one DDS lane, matching the AD9361's 1 sample/clock
# interface (RFSoC designs use N_DDS=16). IP-XACT permits N_DDS minimum=1.
# NOTE: this proves it *synthesises*; functional correctness at N_DDS=1 is
# not yet verified in simulation.
set name   signal_gen_v6_ndds1
set qick   $env(QICK_ROOT)
set top    axis_signal_gen_v6
set src_dirs [list $qick/firmware/ip/axis_signal_gen_v6/src $qick/firmware/hdl]
set generics {N_DDS=1 N=12}
set ip_recreate {
    {dds_compiler_0 dds_compiler {
        CONFIG.PartsPresent {Phase_Generator_and_SIN_COS_LUT}
        CONFIG.Parameter_Entry {System_Parameters}
        CONFIG.DDS_Clock_Rate {122.88}
        CONFIG.Phase_Width {32}
        CONFIG.Output_Width {16}
        CONFIG.Spurious_Free_Dynamic_Range {96}
        CONFIG.Frequency_Resolution {0.06}
        CONFIG.Phase_Increment {Streaming}
        CONFIG.Phase_Offset {Streaming}
        CONFIG.Resync {true}
        CONFIG.Output_Selection {Sine_and_Cosine}
    }}
}
