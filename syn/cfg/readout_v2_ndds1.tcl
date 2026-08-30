# axis_readout_v2 at one DDS lane. Needs both a DDS and a FIR Compiler
# regenerated for 7-series; QICK ships them built for xczu49dr.
set name   readout_v2_ndds1
set qick   $env(QICK_ROOT)
set top    axis_readout_v2
set src_dirs [list $qick/firmware/ip/axis_readout_v2/src \
                   $qick/firmware/ip/axis_readout_v2/src/fifo \
                   $qick/firmware/hdl]
set generics {N_DDS=1}
set ip_recreate {
    {dds_compiler_0 dds_compiler {
        CONFIG.PartsPresent {Phase_Generator_and_SIN_COS_LUT}
        CONFIG.Parameter_Entry {System_Parameters}
        CONFIG.DDS_Clock_Rate {122.88}
        CONFIG.Output_Width {16}
        CONFIG.Phase_Increment {Streaming}
        CONFIG.Output_Selection {Sine_and_Cosine}
    }}
    {fir_compiler_0 fir_compiler {
        CONFIG.Clock_Frequency {122.88}
        CONFIG.Sample_Frequency {122.88}
    }}
}
