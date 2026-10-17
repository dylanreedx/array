#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "pillow>=11"]
# ///
"""Blank or near-black card faces: how much of a moving card shows nothing.

Usage: probes/blank-faces.py <frames dir|video> <rects.json> [--lum 17.5] [--inset 6] [--min-e 0.5]

rects.json is the video's own geometry for those frames, in output px (videos/which-tab/rects.ts prints it):
  {"until": <frame>, "rects": {"<frame>": {"<card>": {"x":..,"y":..,"width":..,"height":.., "e": 0..1}}}}
`e` (optional) is how far the card is into its flight; only cards with e >= --min-e are measured (the ones
that should be showing their tile). Frames at or after `until` are skipped (the card is gone).

For each card it prints the worst frame and the mean fraction of its face that is near-black (luminance below
--lum, of 255). Every surface of a real Array tile is lighter than 17.5 (the tile body #12151B is 20.6), so a
near-black pixel on a face is a pixel with nothing on it. The rect is inset so edges and blur fringes don't count.
which-tab r4: the faces cut from the live take went black while its camera was still tight; the plate
(kit/handoff.tsx) fixed it. On r5.3 (frames 396-527) the worst card reads 0.037, Cart total at f423, where
its face is still the terminal (Ghostty's #101010 sits just under the threshold), and the rest read 0.000-0.008.
"""
import json
import sys

import numpy as np

from _frames import frames, lum

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
src, R = args[0], json.load(open(args[1]))
opt = {k: float(v) for k, v in zip(args[2::2], args[3::2])}
thr, inset, min_e = opt.get('--lum', 17.5), opt.get('--inset', 6), opt.get('--min-e', 0.5)
until = R.get('until', 10**9)
keys = sorted(int(k) for k in R['rects'])
series, worst = {}, {}
for n, im in frames(src, keys[0], keys[-1]):
    if str(n) not in R['rects'] or n >= until:
        continue
    L = lum(im)
    H, W = L.shape
    for card, r in R['rects'][str(n)].items():
        if r.get('e', 1) < min_e:
            continue
        x0, y0 = int(max(0, r['x'] + inset)), int(max(0, r['y'] + inset))
        x1, y1 = int(min(W, r['x'] + r['width'] - inset)), int(min(H, r['y'] + r['height'] - inset))
        if x1 - x0 < 8 or y1 - y0 < 8:
            continue  # off screen: nothing to see
        frac = float((L[y0:y1, x0:x1] < thr).mean())
        series.setdefault(card, []).append(frac)
        worst[card] = max(worst.get(card, (-1.0, -1)), (frac, n))
print(f'near-black fraction (lum < {thr}) of each card face; worst frame, mean, frames measured:')
for k, v in series.items():
    print(f'  {k:10s} worst {worst[k][0]:.3f} at f{worst[k][1]}   mean {np.mean(v):.3f}   n={len(v)}')
print(f'worst of all: {max((w[0] for w in worst.values()), default=0):.3f}')
