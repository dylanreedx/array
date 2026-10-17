# Sound pass for the day-transition reel: only Array's bundled agent sounds, placed on the picture's
# beats, some re-pitched (resampled) or reversed into risers. Usage: sfx.py <sounds dir> <out.wav>
import sys
import numpy as np
import soundfile as sf

SR, FPS = 48000, 60
SOUNDS, OUT = sys.argv[1], sys.argv[2]
OFF = {'t1': 0, 't2': 270, 't3': 540, 't4': 840, 't5': 1110}
TOTAL = 1410
# With a film layout (videos/full-day: {"t1": frame, ..., "total": frames}) the same cues land on the
# film's transitions and the stem is written at unity gain: the film's soundtrack normalises the mix.
FILM = len(sys.argv) > 3
if FILM:
    import json
    lay = json.load(open(sys.argv[3]))
    OFF = {k: lay[k] for k in [*OFF, 't6'] if k in lay}
    TOTAL = lay['total']

def load(name, rate=1.0, rev=False):
    x, sr = sf.read(f'{SOUNDS}/{name}.wav', dtype='float32')
    if x.ndim > 1: x = x.mean(1)
    n = int(len(x) * SR / sr / rate)
    y = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)
    return y[::-1].copy() if rev else y

mix = np.zeros((int(TOTAL / FPS * SR) + SR * 2, 2), np.float32)

def put(t, frame, name, gain=0.7, rate=1.0, rev=False, pan=0.0, end=False):
    if t not in OFF: return
    y = load(name, rate, rev) * gain
    at = int((OFF[t] + frame) / FPS * SR) - (len(y) if end else 0)
    at = max(0, at)
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    mix[at:at + len(y), 0] += y * l * 1.414
    mix[at:at + len(y), 1] += y * r * 1.414

# One sound per beat, quieter, and never two on top of each other (see the gap check below).
# 1 sunrise: the sun rises, the greeting pops, the lens opens, the chip docks
put('t1', 14, 'aurora', 0.42, 0.9)
put('t1', 66, 'pop', 0.3)
put('t1', 152, 'bloom', 0.18, 0.75, rev=True, end=True)
put('t1', 154, 'bloom', 0.55)
put('t1', 210, 'pluck', 0.22, pan=0.5)
# 2 coffee: the pour, the mug, the drain, the dock
put('t2', 30, 'ripple', 0.38, 0.85)
put('t2', 96, 'marimba', 0.45)
put('t2', 178, 'ripple', 0.26, 0.95)
put('t2', 222, 'pluck', 0.22, pan=0.5)
# 3 lunch: the flip, three agents finishing (rising), the flip back, the dock
put('t3', 74, 'warp', 0.2, 1.1)
for k, fr in enumerate([140, 160, 180]): put('t3', fr, 'dewdrop', 0.36, 1.0 + 0.12 * k, pan=0.25 * (k - 1))
put('t3', 214, 'warp', 0.18, 1.15)
put('t3', 262, 'pluck', 0.22, pan=0.5)
# 4 heads down: the clock arrives, a soft tick every quarter hour races with the footage, it lands
put('t4', 32, 'beacon', 0.38)
speed = lambda f: 1 + 11 * (np.clip((f - 24) / 60, 0, 1) - np.clip((f - 168) / 60, 0, 1))
pos = np.concatenate([[0], np.cumsum([speed(i) for i in range(1, 271)])]); pos /= pos[-1]
# the lapse's clock: 12:30 → 15:00 in the reel, 13:30 → 15:30 in the film (videos/full-day/index.tsx)
START, SPAN = (13 * 60 + 30, 120) if FILM else (12 * 60 + 30, 150)
mins = START + pos * SPAN
for k in range(1, 10):
    fr = int(np.searchsorted(mins, START + 15 * k))
    if 60 < fr < 190: put('t4', fr, 'pixel', 0.09, 1.0 if k % 2 else 1.26, pan=0.2 if k % 2 else -0.2)
put('t4', 214, 'pluck', 0.24, pan=0.5)
# 5 sunset: the blind, the sun going down, two twinkles, the moon, the blind lifting
put('t5', 26, 'hush', 0.28, 0.9)
put('t5', 100, 'cloud', 0.32, 0.85)
put('t5', 136, 'spark', 0.14, 0.95, pan=-0.4)
put('t5', 150, 'spark', 0.12, 1.1, pan=0.4)
put('t5', 172, 'prism', 0.38)
put('t5', 220, 'aurora', 0.28, 0.8)
# 6 sounds (film only): the flood, the card, then each row plays the app's own sound for it
# (Pushed = orbit, Merged = prism, Done = bloom, as AgentSoundRules plays them), the hand-over
put('t6', 22, 'ripple', 0.3, 0.85)
put('t6', 60, 'pop', 0.26)
for k, name in enumerate(['orbit', 'prism', 'bloom']): put('t6', 112 + k * 26, name, 0.5)
put('t6', 214, 'pluck', 0.22, pan=0.5)

mix = mix[: int(TOTAL / FPS * SR) + SR // 2]
if not FILM:
    peak = np.abs(mix).max()
    mix = mix / peak * 10 ** (-6 / 20)
sf.write(OUT, mix, SR, subtype='PCM_24')
print('peak', round(float(20 * np.log10(np.abs(mix).max())), 2), 'dBFS', round(len(mix) / SR, 2), 's')
