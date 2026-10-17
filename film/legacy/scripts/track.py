#!/usr/bin/env python3
"""Compact a harness take's frames.json (array.film.frames.v2) into the pointer track a video imports.

Usage: scripts/track.py <take>/frames.json <out.json> [rect keys...]
Keeps every frame's pointer and viewport, the rects of the named tiles/cards only, events and marks.
"""
import json, sys

MODES = ['arrow', 'hand', 'grab', 'pinch', 'scroll']
src, out, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(src))
assert d.get('schema') == 'array.film.frames.v2', f"{src}: want frames v2, got {d.get('schema')}"
fr = d['frames']
r1 = lambda v: round(v, 1)
track = {
    'fps': d['fps'],
    'pointSize': d['pointSize'],
    'frames': len(fr),
    'p': [[r1(f['pointer']['x']), r1(f['pointer']['y']), 1 if f['pointer']['down'] else 0, MODES.index(f['pointer']['mode'])] for f in fr],
    'v': [[round(f['viewport']['x'], 2), round(f['viewport']['y'], 2), round(f['viewport']['zoom'], 5)] for f in fr],
    'rects': {k: [([r1(c) for c in f.get('rects', {}).get(k)] if f.get('rects', {}).get(k) else None) for f in fr] for k in keys},
    'events': d.get('events', []),
    'marks': d.get('marks', {}),
    # video 2: the shortcuts pressed (key caps) and the menus production built (redrawn in the overlay)
    'keys': d.get('keys', []),
    'menus': d.get('menus', []),
}
json.dump(track, open(out, 'w'), separators=(',', ':'))
print(f"{out}: {len(fr)} frames, rects {keys}, {len(track['events'])} events, marks {track['marks']}")
