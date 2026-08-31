# Why the RX tap does not depend on the ADI DMA

The QICK readout is fed from `util_ad9361_adc_fifo/dout_data_{0,1}` with
`dout_valid_0`, i.e. the divided-clock side of the crossing out of `l_clk`. An
obvious worry is that those signals only move when the ADI capture DMA is
running, in which case the readout would see nothing unless a libiio buffer
happened to be active. Reading `util_wfifo.v` settles it: they do not.

The path is entirely upstream of the DMA:

    axi_ad9361/adc_valid_i0  ->  din_valid_0
      din_wr <= din_valid_s[0]                     (M_MEM_RATIO == 1 here)
      every 8 writes:  din_req_t <= ~din_req_t     (din_waddr[2:0] == 7)
    din_req_t  -(resync to dout_clk)->  dout_req_t
      dout_req_cnt <= 8, counts while bit 3 is set
      dout_valid <= dout_rd_d <= dout_req_cnt[3]   (8 valid cycles per request)

The DMA sits *downstream* of `util_ad9361_adc_pack` and never appears here, so
the only thing that has to be true is that the AD9361 is delivering samples --
which means the chip awake and in FDD.

The rates also line up exactly, which is what makes a one-sample-per-clock
readout the right shape:

* `adc_valid_i0` pulses at the sample rate, i.e. every other `l_clk` in LVDS
* so 8 samples occupy 16 `l_clk`, which is 8 `divclk` periods
* and the fifo emits exactly 8 `dout_valid` cycles per request

So `dout_valid_0` is asserted essentially every `divclk`, one complex sample per
clock, which is what `axis_readout_v2` at `N_DDS=1` consumes.

One consequence worth remembering: if the AD9361 is asleep, `adc_valid_i0`
stops, `dout_valid` stops, and the readout goes quiet -- and because the AD9361
also sources the LVDS DATA_CLK that `divclk` is derived from, the datapath is
not merely idle but unclocked. A dead readout is therefore a symptom to check
the radio state for, not only the QICK logic.
