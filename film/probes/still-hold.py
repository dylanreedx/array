#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "pillow>=11"]
# ///
"""Still hold: does a beat that should be perfectly still actually hold?

Usage: probes/still-hold.py <frames dir|video> <from> <to> [--rect X,Y,W,H] [--thr 0]

Compares every frame in from..to with the one before it and with the first, inside --rect (default: the whole
frame). Prints the max channel difference, how many pixels changed by more than --thr, and which frames moved.
A held end card must print 0 changed frames (on lossless frames from scripts/render --sequence; an encoded
video adds codec noise, so use --thr 8 there). which-tab r5.3, frames 870-990 of the end card: 0 frames changed.
"""
import sys

import numpy as np

from _frames import frames

args = sys.argv[1:]
if len(args) < 3:
    sys.exit(__doc__)
src, lo, hi = args[0], int(args[1]), int(args[2])
opt = dict(zip(args[3::2], args[4::2]))
thr = float(opt.get('--thr', 0))
x, y, w, h = map(int, opt['--rect'].split(',')) if '--rect' in opt else (0, 0, 10**6, 10**6)
first = prev = None
moved, worst, drift = [], 0.0, 0.0
for n, im in frames(src, lo, hi):
    im = im[y:y + h, x:x + w]
    if prev is not None:
        d = np.abs(im - prev).max(axis=2)
        changed = int((d > thr).sum())
        worst = max(worst, float(d.max()))
        drift = max(drift, float(np.abs(im - first).max()))
        if changed:
            moved.append((n, changed, float(d.max())))
    else:
        first = im
    prev = im
print(f'frames {lo}..{hi}: {len(moved)} frames changed (> {thr:g}); max frame-to-frame diff {worst:.0f}/255; max drift from the first frame {drift:.0f}/255')
for n, c, m in moved[:12]:
    print(f'  f{n}: {c} px changed, max {m:.0f}')
