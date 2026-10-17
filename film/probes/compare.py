#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3"]
# ///
"""Frame-by-frame difference between two videos (or two frame folders): max and mean absolute difference.

Usage: probes/compare.py <a.mp4|dir> <b.mp4|dir> [--audio]

Prints the per-frame worst cases and a summary. Differences are 0..255 per RGB channel, decoded at a's size.
A video is decoded with film's pinned ffmpeg (scripts/ffmpeg.py); a folder is read as its PNGs in name order.
--audio also compares the two soundtracks sample by sample (decoded to 48 kHz float).
"""
import glob
import os
import subprocess
import sys

import numpy as np

FILM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = os.path.join(FILM, 'node_modules', '.cache', 'film-bin', 'ffmpeg')
a, b = sys.argv[1], sys.argv[2]


def size(path):
    if os.path.isdir(path):
        from PIL import Image  # noqa: only for folders
        im = Image.open(sorted(glob.glob(os.path.join(path, '*.png')))[0])
        return im.width, im.height
    err = subprocess.run([FFMPEG, '-hide_banner', '-i', path], capture_output=True, text=True).stderr
    import re
    m = re.search(r'Video:.*?(\d{2,5})x(\d{2,5})', err)
    return int(m.group(1)), int(m.group(2))


def frames(path, w, h):
    if os.path.isdir(path):
        from PIL import Image
        for f in sorted(glob.glob(os.path.join(path, '*.png'))):
            yield np.asarray(Image.open(f).convert('RGB').resize((w, h)))
        return
    p = subprocess.Popen([FFMPEG, '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{w}x{h}', '-'], stdout=subprocess.PIPE)
    n = w * h * 3
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)


w, h = size(a)
rows = []
for i, (x, y) in enumerate(zip(frames(a, w, h), frames(b, w, h))):
    d = np.abs(x.astype(np.int16) - y.astype(np.int16))
    rows.append((i, int(d.max()), float(d.mean()), float((d > 8).mean())))
if not rows:
    sys.exit('compare: no frames decoded')
mx = max(r[1] for r in rows)
mean = sum(r[2] for r in rows) / len(rows)
differ = [r for r in rows if r[1] > 0]
print(f'{len(rows)} frames compared at {w}x{h}')
print(f'max abs diff {mx}/255, mean abs diff {mean:.5f}/255, frames with any difference {len(differ)}')
for r in sorted(rows, key=lambda r: -r[1])[:10]:
    if r[1] == 0:
        break
    print(f'  f{r[0]}: max {r[1]}, mean {r[2]:.5f}, {100 * r[3]:.4f}% of samples off by >8')
if '--audio' in sys.argv:
    def pcm(path):
        raw = subprocess.run([FFMPEG, '-v', 'error', '-i', path, '-f', 'f32le', '-ac', '2', '-ar', '48000', '-'], capture_output=True, check=True).stdout
        return np.frombuffer(raw, np.float32)
    pa, pb = pcm(a), pcm(b)
    n = min(len(pa), len(pb))
    print(f'audio: {len(pa) // 2} vs {len(pb) // 2} samples, max abs diff {float(np.abs(pa[:n] - pb[:n]).max()):.6f}')
