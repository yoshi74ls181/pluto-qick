# axis_avg_buffer: the readout accumulation + capture buffer. Sizes are the
# defaults (N_AVG=10 -> 1024 accumulated points, N_BUF=10 -> 1024 samples).
set name   avg_buffer
set qick   $env(QICK_ROOT)
set top    axis_avg_buffer
set src_dirs [list $qick/firmware/ip/axis_avg_buffer/src \
                   $qick/firmware/ip/axis_avg_buffer/src/fifo \
                   $qick/firmware/hdl]
set generics {N_AVG=10 N_BUF=10 B=16}
