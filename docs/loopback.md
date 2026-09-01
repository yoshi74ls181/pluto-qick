# QICK loopback on the AntSDR E200

A pulse from the QICK signal generator, out of the AD9361, around an external
TX -> 10 dB attenuator -> RX loop, and back through the QICK readout.
`boards/e200/qick/notebooks/qick_loopback_demo.ipynb` in antsdr-pynq runs it;
`tools/characterise_loopback.py` sweeps gain and reports the numbers below.

    gain   arrives   length (cmd 10.0 us)   |IQ|    flatness   freq error
    0.10   5.99 us   9.90 us                 34.5    6.0 %      +0.0 kHz
    0.20   5.73 us   9.90 us                 65.3    6.3 %      -0.0 kHz
    0.40   5.99 us   9.90 us                137.1    5.1 %      -0.0 kHz
    0.80   5.99 us   9.90 us                274.4    6.9 %      +0.0 kHz

Each column is a separate thing working:

* **Length** agrees with the command to within one decimated sample (0.26 us at
  3.84 MHz), so the tProc's timing, `sg_translator`'s nsamp field and the
  generator's sample counter all agree.
* **Amplitude** is linear in gain over an 8x range (ratios 1.000, 0.947, 0.994,
  0.995).
* **Frequency error** is below the measurement resolution, which is what setting
  `refclk_freq = fs` with `fs_mult = fs_div = 1` buys: the generator and readout
  DDSs land on the same grid.
* **Latency** is 5.92 +/- 0.11 us, stable across gains -- the converter's
  internal filters, the cable, and the readout's 121-tap decimating FIR.

## The transmit channel has to be in DMA mode

The AD9361 only forwards fabric data when its transmit channel is in DMA mode,
which requires an active ADI transmit buffer. Without one the converter silently
ignores the generator: the capture reads zero while the tProc runs, the shot
counter increments, the descriptor reaches the generator and the mux switches
correctly. Nothing anywhere reports an error.

A cyclic buffer of zeros selects the mode and contributes no signal of its own;
the TX mux substitutes the generator's samples for its data:

    sdr.tx_cyclic_buffer = True
    sdr.tx(np.zeros(4096, dtype=np.complex64))
    soc.tx_source('qick')          # only after the buffer is running

The order matters. `qick_tx_mux` asserts the generator's `tready` only while
selected, so switching the mux first, with the transmit path idle, back-pressures
`sg_translator` and stalls the tProc on the instruction that writes the waveform
descriptor.

## Analysis has to find the pulse

The pulse arrives about 6 us in, not at t=0. An analysis window assuming t=0
measures mostly dead time and reports nonsense -- 271 % "ripple" on a pulse whose
real flatness is under 7 %. Detect the pulse by threshold and measure its
interior.
