#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "pillow>=11"]
# ///
"""Edge jitter and reversals: does a border or a label that should hold still (or move smoothly) wobble?

Usage: probes/jitter.py <frames dir|video> <from> <to> --edge NAME=x,ROW,LO,HI ... --label NAME=X0,Y0,X1,Y1,LUM ...

  --edge   the strongest luminance step along one line, to a sub-pixel (a parabola through the peak):
           x,ROW,LO,HI scans columns LO..HI of row ROW (a vertical border); y,COL,LO,HI scans rows (a horizontal one)
  --label  the luminance-weighted centroid of pixels brighter than LUM inside the box (a text label's position)

A single jump of many px that comes straight back is the detector switching between two edges: narrow LO..HI.

Per probe it prints the range, how many frame-to-frame moves exceed 0.02 px, the largest move and the number of
REVERSALS (a move against the previous one). Read it as: held = 0 moves; a smooth camera move = moves of one
sign, 0 reversals; pixel snapping or a re-rasterising glyph = reversals (which-tab r4: a centred tab label stepped
back +1.1 px while its tab only shrank; a 1.8% scale creep shimmered every glyph by 0.4-0.9 px).
"""
import sys

import numpy as np

from _frames import frames, lum

args = sys.argv[1:]
if len(args) < 3:
    sys.exit(__doc__)
src, lo, hi = args[0], int(args[1]), int(args[2])
probes = []
for flag, spec in zip(args[3::2], args[4::2]):
    name, v = spec.split('=', 1)
    p = v.split(',')
    probes.append((flag, name, p[0], *map(float, p[1:])) if flag == '--edge' else (flag, name, *map(float, p)))
if not probes:
    sys.exit('jitter: give at least one --edge or --label')


def edge(profile):
    d = np.abs(np.diff(profile))
    i = int(np.argmax(d))
    if 0 < i < len(d) - 1:
        a, b, c = d[i - 1], d[i], d[i + 1]
        den = a - 2 * b + c
        return i + 0.5 + (0.5 * (a - c) / den if den else 0)
    return i + 0.5


series = {p[1]: [] for p in probes}
for n, im in frames(src, lo, hi):
    L = lum(im)
    for p in probes:
        if p[0] == '--edge':
            _, name, axis, fixed, a, b = p
            a, b, fixed = int(a), int(b), int(fixed)
            prof = L[fixed, a:b] if axis == 'x' else L[a:b, fixed]
            series[name].append((n, a + edge(prof)))
        else:
            _, name, x0, y0, x1, y1, thr = p
            box = L[int(y0):int(y1), int(x0):int(x1)]
            w = np.clip(box - thr, 0, None)
            ys, xs = np.mgrid[int(y0):int(y1), int(x0):int(x1)]
            s = w.sum()
            series[name].append((n, (float((xs * w).sum() / s), float((ys * w).sum() / s)) if s else (np.nan, np.nan)))

worst_rev = 0
for name, s in series.items():
    vals = np.array([v for _, v in s], dtype=float)
    axes = [('', vals)] if vals.ndim == 1 else [(' x', vals[:, 0]), (' y', vals[:, 1])]
    for suffix, v in axes:
        d = np.diff(v)
        nz = d[np.abs(d) > 0.02]
        rev = int(np.sum(np.sign(nz[1:]) * np.sign(nz[:-1]) < 0))
        worst_rev = max(worst_rev, rev)
        print(f'{name + suffix:28s} range {np.nanmin(v):8.2f}..{np.nanmax(v):8.2f}  moves {len(nz):3d}/{len(d)}  max|d| {np.nanmax(np.abs(d)) if len(d) else 0:.2f} px  reversals {rev}')
print(f'frames {lo}..{hi}: worst reversals {worst_rev}')
