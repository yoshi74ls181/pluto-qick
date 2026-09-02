# QICK loopback on the AntSDR E200

A pulse from the QICK signal generator, out of the AD9361, around an external
TX -> 10 dB attenuator -> RX loop, and back through the QICK readout.
`boards/e200/qick/notebooks/qick_loopback_demo.ipynb` in antsdr-pynq runs it;
`tools/characterise_loopback.py` sweeps gain and reports the numbers below.

    gain   arrives   length (cmd 10.0 us)   |IQ|    flatness   freq error
    0.10   5.99 us   9.90 us                 33.9    6.7 %      +0.0 kHz
    0.20   5.99 us   9.90 us                 67.9    5.8 %      -0.0 kHz
    0.40   5.99 us   9.90 us                135.9    6.6 %      +0.0 kHz
    0.80   6.25 us   9.90 us                272.8    6.5 %      +0.1 kHz

Amplitude linearity across that range: 1.000, 1.001, 1.002, 1.006.

These reproduce across the removal of the transmit mux (below) to within about
3 % on amplitude, exactly on pulse length, and below resolution on frequency,
which is what establishes that simplification as behaviour neutral.

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

## There is no transmit mux

The generator drives `axi_ad9361_dac_fifo` directly: `m_axis` is sliced into the
fifo's two 16-bit channels by a pair of `xlslice`, and `din_valid_in_*` plus the
generator's `tready` are tied high by an `xlconstant`. Nothing selects between
this and the stock ADI transmit data.

The consequence is deliberate: **this overlay and the board's own
`e200_loopback_demo.ipynb` are mutually exclusive.** While this bitstream is
loaded the stock demo will not transmit, and there is no way back short of a
reboot. An earlier version had a software-selectable mux for exactly that
reason, removed to simplify the design once it was no longer needed.

Tying `tready` high is not a shortcut. Gating it on the fifo's read request
couples the generator to the stock transmit path: with that path idle the fifo
never asks for a sample, the generator never advances, and the back-pressure
stalls the tProc on the instruction that writes the waveform descriptor. Both
sides run on the same divided clock at one complex sample per clock, so they are
inherently rate matched and the handshake achieves nothing.

## The transmit channel still has to be in DMA mode

The AD9361 only forwards fabric data when its transmit channel is in DMA mode,
which requires an active ADI transmit buffer. Without one the converter silently
ignores the generator: the capture reads zero while the tProc runs, the shot
counter increments, the descriptor reaches the generator and the mux switches
correctly. Nothing anywhere reports an error.

This is a property of the converter, not of the mux that used to exist, so
removing the mux did not change it. A cyclic buffer of zeros selects the mode and
contributes no signal of its own -- the generator's samples take its place in the
fifo:

    sdr.tx_cyclic_buffer = True
    sdr.tx(np.zeros(4096, dtype=np.complex64))

## Analysis has to find the pulse

The pulse arrives about 6 us in, not at t=0. An analysis window assuming t=0
measures mostly dead time and reports nonsense -- 271 % "ripple" on a pulse whose
real flatness is under 7 %. Detect the pulse by threshold and measure its
interior.
