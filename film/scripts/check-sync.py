#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "scipy==1.18.1", "soundfile==0.14.0"]
# ///
"""Fails if the muxed audio is offset from the soundtrack by more than 1 ms, if it differs by more
than codec noise once aligned, or if the delivered true peak is above -1 dBTP.

Replaces the windowed check in scripts/tessel/check-sync.py (kept for reference): that one
correlates three 2 s windows and, on Array's tonal hum-and-pad score, aliased to false lags of
55-91 ms in windows with no transient, while the whole track was sample-exact (prototype run).
The true-peak test is Tessel's, unchanged.  Usage: check-sync.py <video.mp4> <soundtrack.wav>"""
import subprocess
import sys

import numpy as np
import soundfile as sf
from scipy import signal

video, wav = sys.argv[1:3]
ref, sr = sf.read(wav, always_2d=True)
raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-f', 'f32le', '-ac', '2', '-ar', str(sr), '-'],
                     capture_output=True, check=True).stdout
dec = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)
r, d = ref[:, 0], dec[: len(ref), 0]
c = signal.correlate(d, r, mode='full', method='fft')
lag = int(np.argmax(c)) - (len(r) - 1)
n = min(len(r), len(d)) - abs(lag)
a, b = (r[:n], d[lag:lag + n]) if lag >= 0 else (r[-lag:-lag + n], d[:n])
resid_db = 20 * np.log10(np.sqrt(np.mean((a - b) ** 2)) / (np.sqrt(np.mean(a ** 2)) + 1e-12) + 1e-12)
tp = 20 * np.log10(np.max(np.abs(signal.resample_poly(dec, 4, 1, axis=0))) + 1e-12)
ok_lag, ok_res, ok_tp = abs(lag) <= sr // 1000, resid_db < -30, tp <= -1.0
print(f'lag {lag:+d} samples ({lag / sr * 1000:+.2f} ms) {"OK" if ok_lag else "FAIL"}; '
      f'residual {resid_db:.1f} dB {"OK" if ok_res else "FAIL"}; true peak {tp:.2f} dBTP {"OK" if ok_tp else "FAIL"}')
sys.exit(0 if ok_lag and ok_res and ok_tp else 1)
