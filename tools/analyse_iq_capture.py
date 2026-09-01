#!/usr/bin/env python3
"""Turn tb_iq_ssb's capture into a pass/fail verdict.

tb_iq_ssb writes iq_capture.txt and finishes without asserting anything, so in a
suite it reads as neither passing nor failing -- which is worse than either,
because a capture-only testbench is easy to mistake for a passing one.

The property worth checking is single-sideband behaviour: the complex output
should put a tone at +f and essentially nothing at -f. Image rejection is the
ratio between them.
"""
import sys
import numpy as np

MIN_REJECTION_DB = 40.0     # generous; the design measures far better

def main(path):
    vals = []
    for line in open(path):
        parts = line.replace(',', ' ').split()
        if len(parts) < 2:
            continue
        try:
            vals.append(complex(int(parts[0]), int(parts[1])))
        except ValueError:
            continue
    if len(vals) < 256:
        print("  FAIL only %d samples in %s" % (len(vals), path))
        return 1

    z = np.asarray(vals)
    z = z - z.mean()                       # drop any DC offset
    w = np.hanning(len(z))
    sp = np.fft.fftshift(np.fft.fft(z * w))
    fx = np.fft.fftshift(np.fft.fftfreq(len(z)))
    mag = np.abs(sp)

    k = int(np.argmax(mag))
    f_tone = fx[k]
    # the image sits at the mirrored frequency
    k_img = int(np.argmin(np.abs(fx + f_tone)))
    # look in a small window around each, so a bin-straddling tone is not penalised
    def peak(idx, half=3):
        lo, hi = max(0, idx - half), min(len(mag), idx + half + 1)
        return mag[lo:hi].max()

    sig, img = peak(k), peak(k_img)
    rej = 20 * np.log10(sig / max(img, 1e-12))
    print("  tone at %+0.4f (normalised), signal %.3e, image %.3e" % (f_tone, sig, img))
    print("  image rejection %.1f dB" % rej)
    if rej >= MIN_REJECTION_DB:
        print("  PASS single sideband, image suppressed by %.1f dB" % rej)
        return 0
    print("  FAIL image rejection %.1f dB is below the %.0f dB threshold"
          % (rej, MIN_REJECTION_DB))
    return 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'iq_capture.txt'))
