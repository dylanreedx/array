#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "pillow>=11"]
# ///
"""Plate-to-live parity per tile: from which take frame does each tile look the same in both takes?

Usage: probes/plate-parity.py <live take> <plate take> [--from 0] [--to 599] [--step 2] [--keys a,b,c] [--tol 2.0]

Both takes are recorder takes (frames.json + frames/). For each frame and tile, the tile is cut from each take
at its OWN rect (each take's frames.json; the two cameras differ), the plate's crop is resampled to the live
crop's size, and the two are compared: mean absolute difference (0..255) and the share of pixels off by more
than 40. A tile AGREES at a frame when the mean is under --tol. The hand-off frame is the first frame from which
it agrees to the end of the range; a card can switch from plate to live there and nobody can see the swap.
Tiles outside the live frame at a frame are skipped (that is what the plate is for).

Prints one row per tile (hand-off frame, worst mean before and after it) and a ready-to-paste table, e.g.
which-tab's HANDOFF = { cart: 0, dark: 238, emails: 238, export: 238, picker: 301, subs: 312 }.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
live, plate = args[0], args[1]
opt = dict(zip(args[2::2], args[3::2]))
L = json.load(open(os.path.join(live, 'frames.json')))
P = json.load(open(os.path.join(plate, 'frames.json')))
lo, hi, step = int(opt.get('--from', 0)), int(opt.get('--to', min(L['count'], P['count']) - 1)), int(opt.get('--step', 2))
tol = float(opt.get('--tol', 2.0))
scale = L['pixelSize'][0] / L['pointSize'][0]
keys = opt['--keys'].split(',') if '--keys' in opt else sorted({k for fr in L['frames'] for k in fr.get('rects', {})})


def load(take, i):
    return Image.open(os.path.join(take, 'frames', f'{i:06d}.png')).convert('RGB')


def crop(im, r, size=None):
    c = im.crop(tuple(round(v * scale) for v in (r[0], r[1], r[0] + r[2], r[1] + r[3])))
    return np.asarray(c.resize(size, Image.LANCZOS) if size else c).astype(float)


W, H = L['pixelSize']
agree = {k: [] for k in keys}
for i in range(lo, hi + 1, step):
    live_im = plate_im = None
    for k in keys:
        rl, rp = L['frames'][i]['rects'].get(k), P['frames'][i]['rects'].get(k)
        if not rl or not rp or rl[2] <= 0 or rp[2] <= 0:
            continue
        if rl[0] * scale < 0 or rl[1] * scale < 0 or (rl[0] + rl[2]) * scale > W or (rl[1] + rl[3]) * scale > H:
            continue  # not wholly inside the live frame
        live_im = live_im or load(live, i)
        plate_im = plate_im or load(plate, i)
        a = crop(live_im, rl)
        b = crop(plate_im, rp, (a.shape[1], a.shape[0]))
        d = np.abs(a - b).max(axis=2)
        agree[k].append((i, float(d.mean()), float((d > 40).mean())))
table = {}
print(f'tile        hand-off   worst mean before / after   (frames {lo}..{hi} every {step}, tolerance {tol})')
for k, s in agree.items():
    if not s:
        print(f'{k:10s}  never wholly in the live frame')
        continue
    first = next((s[j][0] for j in range(len(s)) if all(m < tol for _, m, _ in s[j:])), None)
    before = max((m for i, m, _ in s if first is None or i < first), default=0)
    after = max((m for i, m, _ in s if first is not None and i >= first), default=0)
    table[k] = first
    print(f'{k:10s}  {str(first) if first is not None else "never":>8s}   {before:6.2f} / {after:6.2f}')
print('HANDOFF = {', ', '.join(f'{k}: {v}' for k, v in table.items() if v is not None), '}')
