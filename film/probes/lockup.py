#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "pillow>=11"]
# ///
"""Lockup proportions, measured off a rendered end card: mark/H, gap/H, centring, URL.

Usage: probes/lockup.py <still.png> [--bg auto|#RRGGBB] [--thr 60]

Finds the ink (pixels differing from the ground by more than --thr) and splits it into the lockup row (mark +
wordmark) and, below it, the URL. In the lockup row the widest run of empty columns is the mark/wordmark gap.
H is the cap height of the wordmark's first glyph (its first column run). Reports, as research/22-end-cards
measured them on 14 launch films:
  mark h / H         Linear 1.42, Vercel 1.39 (target 1.4)
  gap / H            ink to ink, Linear 0.62, Notion 0.53 (target 0.5)
  mark centre - cap centre (px, 0 = centred on the caps)
  lockup centre vs frame centre (px)
  URL ascender / H and URL top below the baseline / H (targets 0.5 and 1.2)
  cap height / frame height (Linear 6.7-7.4%)
"""
import sys

import numpy as np
from PIL import Image

args = sys.argv[1:]
if not args:
    sys.exit(__doc__)
opt = dict(zip(args[1::2], args[2::2]))
im = np.asarray(Image.open(args[0]).convert('RGB')).astype(int)
Hf, Wf, _ = im.shape
bg = np.median(im.reshape(-1, 3), axis=0) if opt.get('--bg', 'auto') == 'auto' else np.array([int(opt['--bg'][i:i + 2], 16) for i in (1, 3, 5)])
ink = np.abs(im - bg).sum(axis=2) > float(opt.get('--thr', 60))


def runs(mask):
    out, s = [], None
    for i, v in enumerate(mask):
        if v and s is None:
            s = i
        if not v and s is not None:
            out.append((s, i - 1))
            s = None
    if s is not None:
        out.append((s, len(mask) - 1))
    return out


bands = [b for b in runs(ink.any(axis=1)) if b[1] - b[0] > 2]
if not bands:
    sys.exit('lockup: no ink found')
row = max(bands, key=lambda b: b[1] - b[0])  # the lockup row is the tallest band
r0, r1 = row
cols = runs(ink[r0:r1 + 1].any(axis=0))
gaps = [(cols[i + 1][0] - cols[i][1] - 1, i) for i in range(len(cols) - 1)]
g, gi = max(gaps)
mark = (cols[0][0], cols[gi][1])
word = (cols[gi + 1][0], cols[-1][1])
mys = np.where(ink[r0:r1 + 1, mark[0]:mark[1] + 1].any(axis=1))[0] + r0
first = cols[gi + 1]
cys = np.where(ink[r0:r1 + 1, first[0]:first[1] + 1].any(axis=1))[0] + r0
cap_top, base = cys[0], cys[-1] + 1
H = base - cap_top
mark_h = mys[-1] - mys[0] + 1
print(f'frame {Wf}x{Hf}, ground {bg.astype(int).tolist()}')
print(f'H (cap height) {H} px = {100 * H / Hf:.2f}% of frame height')
print(f'mark {mark[1] - mark[0] + 1}x{mark_h} px: mark h / H = {mark_h / H:.3f}')
print(f'gap mark -> wordmark {g} px ink to ink: gap / H = {g / H:.3f}')
print(f'mark centre - cap centre = {(mys[0] + mys[-1] + 1) / 2 - (cap_top + base) / 2:+.1f} px')
print(f'lockup centre - frame centre: x {(mark[0] + word[1] + 1) / 2 - Wf / 2:+.1f} px, y {(min(mys[0], cap_top) + max(mys[-1] + 1, r1 + 1)) / 2 - Hf / 2:+.1f} px')
below = [b for b in bands if b[0] > r1]
if below:
    u0, u1 = below[0]
    ucols = runs(ink[u0:u1 + 1].any(axis=0))
    uys = np.where(ink[u0:u1 + 1, ucols[0][0]:ucols[-1][1] + 1].any(axis=1))[0] + u0
    print(f'URL: top {uys[0] - base} px below the baseline = {(uys[0] - base) / H:.3f} H; ink height {uys[-1] - uys[0] + 1} px; '
          f'centre x {(ucols[0][0] + ucols[-1][1] + 1) / 2 - Wf / 2:+.1f} px from the frame centre')
