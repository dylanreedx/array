#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "scipy==1.18.1", "soundfile==0.14.0", "pyloudnorm==0.1.1"]
# ///
"""
Array film soundtrack: score + sound design synthesised from code, in the manner of the Tessel
launch film's scripts/soundtrack.py (MIT, see THIRD_PARTY_NOTICES.md; the DSP helpers below are
adapted from it). Reads a cues.json (scripts/render exports it from the same timeline the picture uses)
and writes a 48 kHz stereo wav, -14 LUFS, true peak under -1 dBTP.

A score MODE is a look-level choice (CueSheet.music). The modes below are the ones the films so far
used; a new video with a new look should get a new mode, written here beside them.

Array's state colours are the motif:
  blue  working        a low hum (A2 + E3) whose level follows the number of working agents
  amber needs you      a two-note ping, E5 then A5 (up a fourth), bright FM bell
  green done           a resolving chime, C#5 E5 then A4+A5, landing on the tonic
Everything is seeded, so re-running reproduces the exact mix.

music: 'tabs' (which-tab) is sparse sound design over a drone and a pad; see its section below.
music: 'app' (see the section of that name below) scores the film from Array's own bundled agent
sounds instead: the bed is built from them and every sfx kind maps to one of them.

Usage: uv run kit/soundtrack.py <cues.json> <out.wav> [--loop <loop.wav>]
  --loop ('app' only) also writes a seamless 4-bar music-only loop of the bed.
"""
import json
import os
import sys
from fractions import Fraction

import numpy as np
from scipy import signal

SR = 48000
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CUES_PATH, OUT_PATH = sys.argv[1], sys.argv[2]
CUES = json.load(open(CUES_PATH))
SLUG = CUES['slug']
FPS, BPM = CUES['fps'], CUES['bpm']
DUR = CUES['total'] / FPS
N = int(DUR * SR)
BEAT = 60.0 / BPM
rng = np.random.default_rng(7)


def fr(frame):
    return frame / FPS


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(d):
    return np.arange(int(d * SR)) / SR


def buf():
    return np.zeros((N, 2))


def place(dst, x, t, gain=1.0, pan=0.0):
    """Add mono x at t seconds with constant-power pan (adapted from Tessel)."""
    i = int(round(t * SR))
    if i >= N or i + len(x) <= 0:
        return
    a = (pan + 1) * np.pi / 4
    st = np.stack([x * np.cos(a), x * np.sin(a)], axis=1)
    if i < 0:
        st, i = st[-i:], 0
    n = min(len(st), N - i)
    dst[i:i + n] += st[:n] * gain


def sos(kind, f, order=2):
    return signal.butter(order, f, kind, fs=SR, output='sos')


def filt(x, s):
    return signal.sosfilt(s, x, axis=0)


def expdec(d, tau):
    return np.exp(-tt(d) / tau)


def fm_bell(midi, d=2.4, idx=2.0, ratio=3.5, tau=0.9):
    t, f = tt(d), mtof(midi)
    mod = np.sin(2 * np.pi * f * ratio * t) * idx * np.exp(-t / (tau * 0.4))
    return np.sin(2 * np.pi * f * t + mod) * np.exp(-t / tau) * np.minimum(1, t / 0.003)


def make_ir(rt60=1.8, seed=3):
    r = np.random.default_rng(seed)
    t = tt(rt60)
    ir = r.standard_normal((len(t), 2)) * np.exp(-6.9 * t / rt60)[:, None]
    return filt(ir, sos('low', 6000)) * 0.05


IR = make_ir()


def reverb(x):
    return signal.fftconvolve(x, IR, axes=0)[:len(x)]


# --- the motif -------------------------------------------------------------------------
def hum(level):
    """Blue: A2 + E3 drone, slow tremolo, level follows the working-agent count (smoothed)."""
    t = np.arange(N) / SR
    tone = (np.sin(2 * np.pi * mtof(45) * t) + 0.6 * np.sin(2 * np.pi * mtof(52) * t)
            + 0.15 * np.sin(2 * np.pi * mtof(57) * t)) * (0.85 + 0.15 * np.sin(2 * np.pi * 0.5 * t))
    env = np.interp(t, np.arange(len(level)) / FPS, np.minimum(1.0, np.array(level, float) / 2) ** 0.5)
    env = filt(env, sos('low', 1.5, 1))  # ~0.1 s glide in/out
    return tone * env * 0.22


def ping():
    """Amber: two notes up a fourth, an eighth apart."""
    x = np.zeros(int(1.6 * SR))
    for k, m in enumerate((76, 81)):
        b = fm_bell(m, d=1.2, idx=2.6, tau=0.35)
        i = int(k * BEAT / 2 * SR)
        x[i:i + len(b)] += b[: len(x) - i]
    return x * 0.5


def chime():
    """Green: C#5, E5, then the tonic A4 + A5 together. Resolves."""
    x = np.zeros(int(3.2 * SR))
    for k, ms in enumerate(((73,), (76,), (69, 81))):
        i = int(k * BEAT / 4 * SR)
        for m in ms:
            b = fm_bell(m, d=2.6, idx=1.4, ratio=2.0, tau=1.1 if k == 2 else 0.4)
            x[i:i + len(b)] += b[: len(x) - i] * (0.8 if k == 2 else 0.55)
    return x * 0.45


def bell(midi, gain=0.5):
    """One FM bell, for arpeggio steps and the lockup."""
    return fm_bell(midi, d=2.6, idx=1.4, ratio=2.0, tau=0.7) * gain


def resolve():
    """An approval answered: the ping's A5 falls a fourth to E5, then settles on the tonic A4."""
    x = np.zeros(int(2.4 * SR))
    for k, (m, g) in enumerate(((81, 0.45), (76, 0.4), (69, 0.5))):
        b = fm_bell(m, d=1.8, idx=1.6, ratio=2.0, tau=0.5 if k < 2 else 0.9) * g
        i = int(k * BEAT / 4 * SR)
        x[i:i + len(b)] += b[: len(x) - i]
    return x * 0.5


def lockup_bell():
    """The end card: A3 and A4 together, long and soft."""
    return (fm_bell(57, d=4.0, idx=1.0, ratio=2.0, tau=1.8) * 0.5 + fm_bell(69, d=4.0, idx=1.2, ratio=2.0, tau=1.4) * 0.35) * 0.6


def click():
    n = rng.standard_normal(int(0.03 * SR)) * expdec(0.03, 0.004)
    return filt(n, sos('high', 2500)) * 0.5


def key():
    return filt(rng.standard_normal(int(0.02 * SR)) * expdec(0.02, 0.003), sos('band', [1800, 6000])) * 0.35


def whoosh(d=0.7):
    n = rng.standard_normal(int(d * SR))
    env = np.sin(np.pi * np.linspace(0, 1, len(n))) ** 2
    out = np.zeros_like(n)
    for j, f in enumerate(np.geomspace(300, 2400, 8)):  # crude swept band
        seg = slice(j * len(n) // 8, (j + 1) * len(n) // 8)
        out[seg] = filt(n, sos('band', [f * 0.7, f * 1.4]))[seg]
    return out * env * 0.35


def thud():
    t = tt(0.4)
    return np.sin(2 * np.pi * (70 - 30 * t / 0.4) * t) * expdec(0.4, 0.09) * 0.6


POP_NOTES = (76, 79, 81, 83, 85, 88)  # A major pentatonic-ish, cycled so consecutive bubbles climb
_pop_n = [0]


def pop():
    """The caption bubble: a short rounded blip whose pitch climbs through POP_NOTES."""
    m = POP_NOTES[_pop_n[0] % len(POP_NOTES)]
    _pop_n[0] += 1
    t = tt(0.12)
    f = mtof(m) * (1 + 0.5 * np.exp(-t / 0.012))  # a quick downward chirp into the note
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * expdec(0.12, 0.035)
    return x * 0.32


def swish():
    return whoosh(0.32) * 0.55


SFX = {'pop': pop, 'swish': swish, 'ping': ping, 'state.ping': ping, 'chime': chime, 'state.chime': chime, 'resolve': resolve, 'bell': lockup_bell,
       'click': click, 'key': key, 'whoosh': whoosh, 'thud': thud, 'tick': key}

# Done chimes that land within a bar of each other are one gesture: an ascending arpeggio, A4 then
# C#5, and the last of the run plays the full chime that resolves onto the tonic.
ARPEGGIO = (69, 73)


def chime_runs(hits):
    """For each state.chime hit index, its position in its run and the run's length."""
    idx = [i for i, h in enumerate(hits) if h['kind'] == 'state.chime']
    runs, cur = [], []
    for i in idx:
        if cur and hits[i]['f'] - hits[cur[-1]]['f'] > 4 * BEAT * FPS:
            runs.append(cur); cur = []
        cur.append(i)
    if cur:
        runs.append(cur)
    return {i: (k, len(r)) for r in runs for k, i in enumerate(r)}


def limiter(x, ceiling=0.77, look=0.004, release=0.08):
    """True-peak-aware lookahead limiter, lifted verbatim from Tessel's soundtrack.py (MIT)."""
    up = signal.resample_poly(x, 4, 1, axis=0)
    a4 = np.max(np.abs(up), axis=1)
    a = a4[: (len(a4) // 4) * 4].reshape(-1, 4).max(axis=1)
    a = np.pad(a, (0, max(0, len(x) - len(a))))[: len(x)]
    la = int(look * SR)
    peak = np.maximum.reduce([np.roll(a, -k) for k in range(0, la, 8)])
    gain = np.minimum(1.0, ceiling / np.maximum(peak, 1e-9))
    win = np.hanning(max(3, la))
    win /= win.sum()
    gain = np.minimum(gain, np.convolve(gain, win, mode='same'))
    rel = np.exp(-1 / (release * SR))
    out = np.empty_like(gain)
    g = 1.0
    for i in range(len(gain)):
        g = gain[i] if gain[i] < g else gain[i] + (g - gain[i]) * rel
        out[i] = g
    return x * out[:, None]


def pad_bed():
    """A quiet bed so the motif has a key to resolve in: I - vi - IV - V, one bar each."""
    prog = [(57, 61, 64), (54, 57, 61), (50, 54, 57), (52, 56, 59)]
    x = np.zeros(N)
    bar = 4 * BEAT
    for k in range(int(DUR / bar) + 1):
        t0, notes = k * bar, prog[k % 4]
        t = tt(bar + 0.4)
        env = np.minimum(1, t / 0.6) * np.minimum(1, (bar + 0.4 - t) / 0.4)
        s = sum(np.sin(2 * np.pi * mtof(m) * t) for m in notes) * env * 0.05
        i = int(t0 * SR)
        x[i:i + len(s)] += s[: max(0, N - i)]
    return x


def kick():
    t = tt(0.32)
    f = 48 + 110 * np.exp(-t / 0.028)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * expdec(0.32, 0.075) * 0.85


def clap():
    n = rng.standard_normal(int(0.22 * SR))
    env = np.zeros(len(n))
    for k, at in enumerate((0.0, 0.009, 0.018)):  # three hands, then the room
        i = int(at * SR)
        env[i:] += np.exp(-np.arange(len(n) - i) / SR / (0.006 if k < 2 else 0.07))
    return filt(n * env, sos('band', [900, 3200])) * 0.32


def hat(tau=0.022, gain=0.12):
    n = rng.standard_normal(int(0.08 * SR))
    return filt(n * expdec(0.08, tau), sos('high', 7500)) * gain


def pluck(midi, d=0.3, tau=0.085, gain=0.11):
    t = tt(d)
    x = sum(signal.sawtooth(2 * np.pi * mtof(midi) * (1 + det) * t) for det in (-0.004, 0.004))
    return filt(x * expdec(d, tau), sos('low', 3200)) * gain


def bass_note(midi, d=0.24):
    t = tt(d)
    x = np.sin(2 * np.pi * mtof(midi) * t) + 0.35 * np.sin(4 * np.pi * mtof(midi) * t)
    env = np.minimum(1, t / 0.004) * expdec(d, 0.11)
    return filt(x * env, sos('low', 1100)) * 0.3


def pop_groove():
    """A bright groove in A major, I - V - vi - IV, a bar each: four-on-the-floor kick, claps on 2 and 4,
    offbeat hats, an eighth-note bass and offbeat chord plucks. The drums come in after the first bar
    (the hook breathes) and drop out under the lockup, where the chords ring alone."""
    prog = [(57, (69, 73, 76)), (52, (68, 71, 76)), (54, (69, 73, 78)), (50, (69, 74, 78))]
    x = np.zeros(N)
    bar = 4 * BEAT
    lock = CUES['acts'].get('lockup', {}).get('from', CUES['total']) / FPS

    def add(s, t, g=1.0):
        i = int(round(t * SR))
        if i < N:
            x[i:i + len(s)] += (s * g)[: N - i]
    for k in range(int(DUR / bar) + 1):
        t0 = k * bar
        root, chord = prog[k % 4]
        drums = t0 >= bar - 1e-6 and t0 < lock - 1e-6
        for e in range(8):  # eighths
            t = t0 + e * BEAT / 2
            if t >= DUR:
                break
            on_beat = e % 2 == 0
            if drums:
                if on_beat:
                    add(kick(), t)
                if e in (2, 6):
                    add(clap(), t)
                add(hat(0.03 if not on_beat else 0.014, 0.13 if not on_beat else 0.06), t)
            if t < lock:
                add(bass_note(root + (12 if e in (3, 7) else 0)), t, 1.0 if drums else 0.6)
            if not on_beat:
                for m in chord:
                    add(pluck(m, tau=0.4 if t >= lock else 0.085), t, 1.4 if t >= lock else 1.0)
    return x


# --- 'app': the score made of Array's own sounds -------------------------------------------
# Array's bundled agent sounds, read straight from the app's Resources/AgentSounds (the files behind
# Settings > Sounds; 44.1 kHz mono). They are first-party: no licence text exists for them and none is needed.
# The palette is written in C major (bloom and aurora arpeggiate C E G C, marimba plays C4 G4 C5,
# pluck A4 E5 A5, ripple G B D), so the 'app' score is in C, not the A major of 'pop': bloom has to
# play untouched, because it is exactly what a user hears when an agent finishes its turn.
APP_DIR = os.path.join(ROOT, '..', 'Resources', 'AgentSounds')
_app = {}


def app(name, semis=0, start=0.0, end=None):
    """One app sound, or the slice [start, end) s of it, at 48 kHz, pitched `semis` semitones by
    resampling (so, like tape, it also gets shorter going up). Slices get 2 ms / 8 ms edge fades."""
    key = (name, semis, start, end)
    if key not in _app:
        import soundfile as sf
        x, sr = sf.read(os.path.join(APP_DIR, f'{name}.wav'))
        x = x.mean(axis=1) if x.ndim > 1 else x
        x = x[int(start * sr): None if end is None else int(end * sr)].copy()
        if start or end is not None:
            a, b = int(0.002 * sr), int(0.008 * sr)
            x[:a] *= np.linspace(0, 1, a)
            x[-b:] *= np.linspace(1, 0, b)
        r = Fraction(SR / (sr * 2 ** (semis / 12))).limit_denominator(4000)
        _app[key] = signal.resample_poly(x, r.numerator, r.denominator)
    return _app[key]


# Each tonal sample is a three-note figure with one clean note per step; these are the note slices.
MARIMBA = {60: (0.0, 0.250), 67: (0.250, 0.510), 72: (0.510, None)}  # C4 G4 C5
PLUCK = {69: (0.0, 0.168), 76: (0.168, 0.340), 81: (0.340, None)}    # A4 E5 A5


def tone(name, midi, gain=1.0):
    """`midi` played on an app sample, resampled from its nearest note slice."""
    table = MARIMBA if name == 'marimba' else PLUCK
    src = min(table, key=lambda s: abs(s - midi))
    return app(name, midi - src, *table[src]) * gain


#            bass  marimba (mid)   pluck (upper)
APP_PROG = [(48, (60, 64, 67), (72, 76, 79)),   # C   I
            (43, (59, 62, 67), (71, 74, 79)),   # G   V
            (45, (60, 64, 69), (72, 76, 81)),   # Am  vi
            (41, (60, 65, 69), (72, 77, 81))]   # F   IV
MARIMBA_STEPS = (0, 2, 1, 3, 2, 1, 2, 1)        # index into the chord + its octave, one per eighth
PLUCK_HOOK = (((0, 2), (3, 1), (6, 2)),          # (eighth, upper-chord index): a 3-3-2 call...
              ((0, 1), (3, 2), (5, 0), (6, 1)))  # ...and its answer, alternating bars


def app_groove(dur, lock):
    """The 'app' bed, stereo, `dur` s long: I - V - vi - IV in C at the film's tempo. A marimba
    ostinato in eighths (left of centre), a marimba bass an octave or two down with a soft sine
    under it, a pluck hook (right of centre) and a dewdrop on each phrase turnaround, over a soft
    synthesised kick, clap and hat. Bar 1 is marimba and bass alone; drums, hook and dewdrop enter
    on bar 2. From `lock` (the end card) the drums, bass and hook stop and the marimba keeps
    rocking on the tonic chord while it fades, under aurora."""
    n = int(dur * SR)
    x = np.zeros((n, 2))
    bar = 4 * BEAT

    def add(s, t, g=1.0, pan=0.0):
        i = int(round(t * SR))
        if i >= n:
            return
        a = (pan + 1) * np.pi / 4
        m = min(len(s), n - i)
        x[i:i + m, 0] += s[:m] * g * np.cos(a)
        x[i:i + m, 1] += s[:m] * g * np.sin(a)
    for k in range(int(dur / bar) + 1):
        t0 = k * bar
        root, mid, upper = APP_PROG[k % 4]
        full = k >= 1
        for e in range(8):
            t = t0 + e * BEAT / 2
            if t >= dur:
                break
            on_beat = e % 2 == 0
            if t >= lock:  # the end card: the tonic, rocking, fading out over two bars
                c = APP_PROG[0][1] + (APP_PROG[0][1][0] + 12,)
                fade = max(0.0, 1 - (t - lock) / (2 * bar))
                add(tone('marimba', c[MARIMBA_STEPS[e]]), t, 0.12 * fade, -0.25)
                continue
            chord = mid + (mid[0] + 12,)
            add(tone('marimba', chord[MARIMBA_STEPS[e]]), t, 0.12 if on_beat else 0.09, -0.25)
            if e in (0, 3, 4, 7):  # bass: 1, the and of 2, 3, the and of 4 (up an octave)
                m = root + (12 if e == 7 else 0)
                add(tone('marimba', m + 12), t, 0.13)
                add(bass_note(m), t, 0.16)
            if full:
                if on_beat:
                    add(kick(), t, 0.24)
                if e in (2, 6):
                    add(clap(), t, 0.3)
                # hats rounded off above 12 kHz: softer, and nothing up there for the AAC encode to throw away
                add(filt(hat(0.03 if not on_beat else 0.014, 0.065 if not on_beat else 0.03), sos('low', 12000)), t)
                for step, idx in PLUCK_HOOK[k % 2]:
                    if step == e:
                        add(tone('pluck', upper[idx]), t, 0.16, 0.3)
                if k % 4 == 3 and e == 7:
                    add(app('dewdrop'), t, 0.08, 0.45)
    if lock < dur:  # one low tonic under the end card
        add(tone('marimba', APP_PROG[0][0] + 12), lock, 0.2)
        add(bass_note(APP_PROG[0][0], d=1.2), lock, 0.22)
    return x


# --- 'day': video 2's score, the same samples, a different song --------------------------------
# F major, swung eighths, I - IV - vi - V by day and IV - V - iii - vi from sunset. The arrangement
# follows the clock: each act names a part of the day and DAY_ENERGY sets how much plays in it, so
# the music is sparse at sunrise, fills through the morning, peaks heads down and winds down at
# night. Energy is read at each bar line (a part starts on the bar its act starts in).
DAY_PROG = [(41, (57, 60, 65), (69, 72, 77)),   # F   I
            (46, (58, 62, 65), (70, 74, 77)),   # Bb  IV
            (38, (57, 62, 65), (69, 74, 77)),   # Dm  vi
            (36, (55, 60, 64), (67, 72, 76))]   # C   V
DUSK_PROG = [(46, (58, 62, 65), (70, 74, 77)),  # Bb  IV
             (36, (55, 60, 64), (67, 72, 76)),  # C   V
             (45, (57, 60, 64), (69, 72, 76)),  # Am  iii
             (38, (57, 62, 65), (69, 74, 77))]  # Dm  vi
DAY_STEPS = (0, 1, 2, 3, 2, 1, 3, 2)            # marimba, one per (swung) eighth
DAY_HOOK = (((0, 2), (2, 1), (5, 2), (7, 0)),
            ((1, 1), (3, 2), (4, 0)))
DAY_ENERGY = {'sunrise': 0, 'morning': 2, 'coffee': 1, 'late': 3, 'lunch': 1, 'afternoon': 3,
              'headsdown': 4, 'sounds': 2, 'peak': 4, 'sunset': 1, 'evening': 1, 'lockup': 0}
DAY_SWING = 0.58


def day_groove(dur, acts):
    """The 'day' bed, stereo. `acts` maps an act id (a DAY_ENERGY key) to {from, dur} in frames.
    Energy 0: marimba on the chord's half notes under a slow air swell. 1: quarter-note marimba,
    a held bass, a soft kick on 1. 2: swung eighths, a walking bass, kick on 1 and 3, shaker on the
    off-beats, a sparse pluck hook. 3: plus claps on 2 and 4, the full hook and a dewdrop on each
    turnaround. 4: plus sixteenth shakers and a pluck counter-line an octave up."""
    n = int(dur * SR)
    x = np.zeros((n, 2))
    bar = 4 * BEAT
    spans = sorted(((a['from'] / FPS, (a['from'] + a['dur']) / FPS, DAY_ENERGY.get(k, 2), k) for k, a in acts.items()))
    dusk = min([s for s, _, _, k in spans if k in ('sunset', 'evening')], default=float('inf'))

    def energy(t):
        for s, e, en, _ in spans:
            if s <= t + 0.05 < e:
                return en
        return 0

    def add(s, t, g=1.0, pan=0.0):
        i = int(round(t * SR))
        if i >= n or i < 0:
            return
        a = (pan + 1) * np.pi / 4
        m = min(len(s), n - i)
        x[i:i + m, 0] += s[:m] * g * np.cos(a)
        x[i:i + m, 1] += s[:m] * g * np.sin(a)

    def eighth(t0, e):
        return t0 + (e // 2) * BEAT + (BEAT * DAY_SWING if e % 2 else 0.0)

    for k in range(int(dur / bar) + 1):
        t0 = k * bar
        en = energy(t0)
        prog = DUSK_PROG if t0 >= dusk else DAY_PROG
        root, mid, upper = prog[k % 4]
        chord = mid + (mid[0] + 12,)
        if en == 0:
            for h in (0, 2):
                add(tone('marimba', chord[h * 1]), t0 + h * BEAT, 0.12, -0.2)
                add(tone('marimba', upper[h]), t0 + h * BEAT + BEAT, 0.07, 0.25)
            continue
        for e in range(8):
            t = eighth(t0, e)
            if t >= dur:
                break
            on_beat = e % 2 == 0
            if en == 1:
                if on_beat:
                    add(tone('marimba', chord[DAY_STEPS[e]]), t, 0.11, -0.25)
            else:
                add(tone('marimba', chord[DAY_STEPS[e]]), t, 0.12 if on_beat else 0.085, -0.25)
            # bass
            if en == 1 and e == 0:
                add(bass_note(root, d=1.6), t, 0.15)
                add(tone('marimba', root + 12), t, 0.1)
            elif en >= 2 and e in (0, 3, 4, 6):
                m = root + (7 if e == 6 else 0) + (12 if (en >= 4 and e == 3) else 0)
                add(tone('marimba', m + 12), t, 0.12)
                add(bass_note(m), t, 0.15)
            # drums
            if en == 1 and e == 0:
                add(kick(), t, 0.14)
            if en >= 2:
                if e in (0, 4):
                    add(kick(), t, 0.22)
                if not on_beat:
                    add(filt(hat(0.03, 0.06), sos('low', 12000)), t, 1.0, 0.15)
            if en >= 3 and e in (2, 6):
                add(clap(), t, 0.26)
            if en >= 4:
                add(filt(hat(0.012, 0.03), sos('low', 12000)), t + BEAT / 4, 1.0, -0.15)
            # hook
            if en >= 2:
                hook = DAY_HOOK[k % 2] if en >= 3 else DAY_HOOK[0][:2]
                for step, idx in hook:
                    if step == e:
                        add(tone('pluck', upper[idx]), t, 0.15, 0.3)
            if en >= 4 and e in (1, 5):
                add(tone('pluck', upper[(e // 2) % 3] + 12), t, 0.07, 0.45)
            if en >= 3 and k % 4 == 3 and e == 7:
                add(app('dewdrop'), t, 0.08, 0.45)
    # the air swells under the energy-0 bars (sunrise, end card)
    for s, e, en, _ in spans:
        if en == 0 and e - s > 1.0:
            add(app_air(min(4.0, e - s)) * 0.05, s, 1.0)
    return x


def app_air(d, bright=6000):
    """A soft air move from hush: slowed an octave (darker, twice as long), its own decay flattened
    out and replaced by a rise-and-fall with the apex at the middle, the band opening as it rises."""
    a = filt(app('hush', -12), sos('high', 450))
    a = a / (np.sqrt(filt(a ** 2, sos('low', 6, 1))) + 1e-3)
    nn = int(d * SR)
    a = np.pad(a, (0, max(0, nn - len(a))))[:nn]
    shape = np.sin(np.pi * np.linspace(0, 1, nn)) ** 2
    dark, light = filt(a, sos('band', [450, 1600])), filt(a, sos('band', [1600, bright]))
    return (dark * (1 - shape) + light * shape) * shape


def app_swish():
    """A camera move: a short, quiet air move."""
    return app_air(0.6) * 0.05


def app_whoosh():
    """Into the end card: a longer air move, with ripple (G B D) reversed swelling up under it, so the
    dominant leans into the tonic that the marimba and aurora land on."""
    air = app_air(0.9) * 0.045
    rev = filt(app('ripple')[::-1], sos('low', 3000))
    h = min(len(rev), len(air) // 2)
    air[len(air) // 2 - h:len(air) // 2] += rev[-h:] * 0.12
    return air


POP_STEPS = (0, 2, 4, 2, 5, 3, -1, 4)  # semitones: each caption pop a little different from the last
_app_pop_n = [0]


def app_pop():
    """A caption bubble: the app's pop, pitched along POP_STEPS, its low tail cut so it stays light."""
    k = _app_pop_n[0]
    _app_pop_n[0] += 1
    return filt(app('pop', POP_STEPS[k % len(POP_STEPS)]), sos('high', 260)) * 0.28 * (1, 0.9, 1.05, 0.95)[k % 4]


def app_press():
    """A cursor press: the attack of acorn, high-passed to a small wooden tock."""
    return filt(app('acorn', 0, 0.0, 0.11), sos('high', 900)) * 0.3


def app_drop():
    """A card lands on an agent or a column: sprout, two notes up a third."""
    return filt(app('sprout'), sos('high', 150)) * 0.22


# The real app events play their app sound verbatim; bloom and beacon are the app's defaults for
# 'turn completed' and 'needs attention' (AgentSoundRules.defaults). Dry, no reverb send.
APP_VERBATIM = {'bloom': 'bloom', 'chime': 'bloom', 'state.chime': 'bloom', 'ping': 'beacon', 'state.ping': 'beacon',
                'orbit': 'orbit', 'prism': 'prism'}
APP_GAIN = {'bloom': 0.55, 'beacon': 0.4, 'orbit': 0.45, 'prism': 0.45}
APP_SFX = {'pop': app_pop, 'click': app_press, 'thud': app_drop, 'swish': app_swish, 'whoosh': app_whoosh,
           'bell': lambda: app('aurora') * 0.3,
           # tests passing lands 5 frames before that line's caption pop: two hits would flam, so it rides the pop
           'tick': lambda: None,
           **{k: (lambda v=v: app(v) * APP_GAIN[v]) for k, v in APP_VERBATIM.items()}}
# Duck the bed under the hits: (dB, hold in s after the hit), then a 350 ms release.
APP_DUCK = {'bloom': (4.0, 0.85), 'chime': (4.0, 0.85), 'ping': (4.0, 0.65), 'pop': (3.0, 0.3),
            'thud': (3.0, 0.45), 'bell': (3.5, 1.0), 'whoosh': (2.0, 0.3)}


def duck_gain(hits, n):
    """Per-sample bed gain from APP_DUCK: down in 30 ms just before each hit, held, released over 350 ms."""
    cr = 1000  # control rate, Hz
    m = int(n / SR * cr) + 1
    target = np.zeros(m)
    for h in hits:
        if h['kind'] in APP_DUCK:
            depth, hold = APP_DUCK[h['kind']]
            a, b = int((fr(h['f']) - 0.03) * cr), int((fr(h['f']) + hold) * cr)
            target[max(0, a):b] = np.minimum(target[max(0, a):b], -depth)
    att, rel = np.exp(-1 / (0.012 * cr)), np.exp(-1 / (0.35 * cr))
    g, out = 0.0, np.empty(m)
    for i in range(m):
        c = att if target[i] < g else rel
        g = target[i] + (g - target[i]) * c
        out[i] = g
    return 10 ** (np.interp(np.arange(n) / SR, np.arange(m) / cr, out) / 20)


def normalise(x, meter):
    """-14 LUFS integrated, the limiter holding the true peak for the AAC encode (-1 dBTP after)."""
    for _ in range(4):
        x = x * 10 ** ((-14.0 - meter.integrated_loudness(x)) / 20)
        x = limiter(x)
    return x


def write_loop(path, meter):
    """Four bars of the bed alone, cut from the middle of a longer render so the reverb and the
    ringing notes coming in at the top are the ones going out at the bottom: it loops seamlessly."""
    import soundfile as sf
    bar = 4 * BEAT
    g = app_groove(12 * bar, float('inf'))
    g = filt(g + reverb(g) * 0.3, sos('high', 28))
    loop = normalise(g[int(4 * bar * SR):int(8 * bar * SR)], meter)
    sf.write(path, loop.astype(np.float32), SR, subtype='PCM_24')
    print(f'wrote {path} {len(loop) / SR:.2f}s, {meter.integrated_loudness(loop):.1f} LUFS')


# --- 'tabs': "Which tab was that?" (which-tab) -------------------------------------------------
# Sparse and dry on purpose: the picture is a terminal, then a quiet canvas. A soft tick for every tab
# (opened or switched to), panned where the tab sits; a low drone under the hunt that rises a little as
# the hunt slows; a breath when it stops; a lift into the pull-back; then Array's own 'bloom' (the
# sound the app plays when an agent finishes its turn) verbatim, on the frame Cart total finishes; a
# warm pad from the lift to the end; the lockup bell. Seeded, so re-running reproduces the mix.
_tab_n = [0]


def tab_tick():
    """A soft, woody tick: a 2.6 kHz-ish band click with a little body, each a touch different."""
    k = _tab_n[0]
    _tab_n[0] += 1
    r = np.random.default_rng(100 + k)
    d = 0.05
    n = r.standard_normal(int(d * SR)) * expdec(d, 0.0045)
    f = 2300 + 500 * r.random()
    click = filt(n, sos('band', [f * 0.6, f * 1.5]))
    t = tt(d)
    body = np.sin(2 * np.pi * (520 + 60 * r.random()) * t) * expdec(d, 0.011) * 0.35
    return (click + body) * 0.1  # quiet: a texture under the hunt, not a beat (director, round 2)


def breath():
    """An intake of air: band noise swelling over 0.35 s and falling away."""
    d = 0.95
    n = rng.standard_normal(int(d * SR))
    t = tt(d)
    env = np.where(t < 0.35, (t / 0.35) ** 2, np.exp(-(t - 0.35) / 0.18))
    return filt(n, sos('band', [380, 1900])) * env * 0.07


def lift(d=1.9):
    """Into the pull-back: filtered air rising to a crest ~1.3 s in, under a quiet upward fifth."""
    n = rng.standard_normal(int(d * SR))
    t = tt(d)
    env = np.where(t < 1.3, (t / 1.3) ** 2.2, np.exp(-(t - 1.3) / 0.22))
    out = np.zeros_like(n)
    for j, fc in enumerate(np.geomspace(260, 3600, 10)):
        seg = slice(j * len(n) // 10, (j + 1) * len(n) // 10)
        out[seg] = filt(n, sos('band', [fc * 0.6, fc * 1.6]))[seg]
    f0 = mtof(57) * (1 + 0.5 * np.minimum(1, t / 1.3))  # A3 gliding up to E4
    tone = np.sin(2 * np.pi * np.cumsum(f0) / SR) * env * 0.05
    return out * env * 0.11 + tone


def tabs_bed(hits):
    """The drone under the hunt (drone.on -> drone.off) and a warm pad from the lift to the end."""
    t = np.arange(N) / SR
    out = np.zeros((N, 2))
    on = next((fr(h['f']) for h in hits if h['kind'] == 'drone.on'), None)
    off = next((fr(h['f']) for h in hits if h['kind'] == 'drone.off'), None)
    if on is not None and off is not None:
        # A1 + E2, a slow beat between two detuned partials; it swells as the hunt slows, then cuts to a short tail
        env = np.clip((t - on) / 0.6, 0, 1) * (0.7 + 0.3 * np.clip((t - on) / max(0.1, off - on), 0, 1))
        env *= np.where(t < off, 1.0, np.exp(-(t - off) / 0.12))
        tone = (np.sin(2 * np.pi * mtof(33) * t) + 0.55 * np.sin(2 * np.pi * mtof(40) * 1.002 * t)
                + 0.3 * np.sin(2 * np.pi * mtof(45) * 0.998 * t))
        tone = filt(tone + 0.04 * rng.standard_normal(N), sos('low', 420))
        out += np.stack([tone * env, tone * env], 1) * 0.16
    lifted = next((fr(h['f']) for h in hits if h['kind'] == 'lift'), None)
    if lifted is not None:
        # A major add9, open voicing, slow attack, very quiet: room tone for the canvas half
        chord = sum(np.sin(2 * np.pi * mtof(m) * t + k) * g for k, (m, g) in enumerate(((45, 0.5), (52, 0.4), (59, 0.25), (61, 0.22), (64, 0.18))))
        env = np.clip((t - lifted - 0.8) / 2.0, 0, 1) ** 1.5 * (0.85 + 0.15 * np.sin(2 * np.pi * 0.2 * t))
        pad = filt(chord, sos('low', 1400)) * env * 0.06
        out += np.stack([pad, np.roll(pad, int(0.011 * SR))], 1)
    return out


def card_swish():
    """A tab window flying to its tile: a short, soft air move (the stack's six overlap into one gesture)."""
    return whoosh(0.42) * 0.16


def dot_sound(kind):
    """A status dot changing: needs input = two quick notes up (a question), failed = a low muted
    knock, done = one small bright bell, nudge = the question again, quieter."""
    if kind == 'input':
        x = np.zeros(int(0.5 * SR))
        for k, m in enumerate((79, 84)):
            b = fm_bell(m, d=0.4, idx=1.2, ratio=2.0, tau=0.12)
            i = int(k * 0.09 * SR)
            x[i:i + len(b)] += b[: len(x) - i]
        return x * 0.14
    if kind == 'nudge':
        return dot_sound('input') * 0.6
    if kind == 'failed':
        t = tt(0.32)
        return (np.sin(2 * np.pi * 150 * t) * expdec(0.32, 0.06) + filt(rng.standard_normal(len(t)), sos('low', 900)) * expdec(0.32, 0.02) * 0.4) * 0.2
    return fm_bell(88, d=1.2, idx=1.0, ratio=2.0, tau=0.35) * 0.12


TABS_SFX = {'tab': tab_tick, 'swish': card_swish,
            'dot.input': lambda: dot_sound('input'), 'dot.failed': lambda: dot_sound('failed'), 'dot.done': lambda: dot_sound('done'), 'dot.nudge': lambda: dot_sound('nudge'), 'breath': breath, 'lift': lift, 'drone.on': lambda: None, 'drone.off': lambda: None,
            'chime': lambda: app('bloom') * 0.55, 'bell': lockup_bell}


def main():
    import pyloudnorm as pyln
    import soundfile as sf

    meter = pyln.Meter(SR)
    music, fx, dry = buf(), buf(), buf()
    mode = CUES.get('music')
    sfx = {**SFX, **APP_SFX} if mode in ('app', 'day') else {**SFX, 'bloom': lambda: app('bloom') * APP_GAIN['bloom']}
    if mode == 'tabs':
        sfx = {**SFX, **TABS_SFX}
    hits = CUES['hits']
    if mode == 'day':
        blooms = [fr(h['f']) for h in hits if APP_VERBATIM.get(h['kind']) == 'bloom']
        hits = [h for h in hits if not (h['kind'] == 'pop' and any(0 <= fr(h['f']) - b < 0.6 for b in blooms))]
        music += day_groove(DUR, CUES['acts']) * duck_gain(hits, N)[:, None]
        mode = 'app'  # every sfx kind maps as in 'app'
    elif mode == 'app':
        # a caption that lands inside a bloom rides it: the bloom already announces that line
        blooms = [fr(h['f']) for h in hits if APP_VERBATIM.get(h['kind']) == 'bloom']
        hits = [h for h in hits if not (h['kind'] == 'pop' and any(0 <= fr(h['f']) - b < 0.6 for b in blooms))]
        lock = CUES['acts'].get('lockup', {}).get('from', CUES['total']) / FPS
        music += app_groove(DUR, lock) * duck_gain(hits, N)[:, None]
    elif mode == 'tabs':
        music += tabs_bed(hits)
    elif mode == 'pop':
        place(music, pop_groove(), 0, 1.0)
    else:
        place(music, pad_bed(), 0, 1.0)
        place(music, hum(CUES['working']), 0, 1.0)
    runs = chime_runs(hits)
    for n, h in enumerate(hits):
        gen = sfx.get(h['kind'])
        if mode != 'app' and n in runs and runs[n][1] > 1 and runs[n][0] < runs[n][1] - 1:
            gen = lambda m=ARPEGGIO[min(runs[n][0], len(ARPEGGIO) - 1)]: bell(m, 0.32)
        x = gen() if gen else None
        if x is not None:
            lead = len(x) / SR / 2 if h['kind'] in ('whoosh', 'swish') else 0  # whoosh apex on the cue
            verbatim = h['kind'] == 'bloom' or (mode == 'app' and h['kind'] in APP_VERBATIM) or (mode == 'tabs' and h['kind'] == 'chime')
            place(dry if verbatim else fx, x, fr(h['f']) - lead, 1.0, h.get('pan', 0))
    # Pre-made stems (<cues dir>/stems/*.wav, 48 kHz): e.g. full-day's transition sound design.
    stems = os.path.join(os.path.dirname(CUES_PATH), 'stems')
    if os.path.isdir(stems):
        import soundfile as sf_
        for name in sorted(os.listdir(stems)):
            if name.endswith('.wav'):
                x, sr = sf_.read(os.path.join(stems, name), dtype='float64')
                assert sr == SR, f'{name}: {sr} Hz, want {SR}'
                x = x if x.ndim == 2 else np.stack([x, x], 1)
                n = min(len(x), N)
                dry[:n] += x[:n]
    mix = music + fx + dry + reverb(fx) * (0.35 if mode == 'app' else 0.5) + reverb(music) * 0.3
    mix = filt(mix, sos('high', 28))
    fade = np.minimum(1, (DUR - np.arange(N) / SR) / 0.5)[:, None]
    mix *= np.clip(fade, 0, 1)
    mix = normalise(mix, meter)
    out = OUT_PATH
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    sf.write(out, mix.astype(np.float32), SR, subtype='PCM_24')
    print(f'wrote {out} {DUR:.2f}s, {meter.integrated_loudness(mix):.1f} LUFS, '
          f'{len(hits)} hits, hum peak {max(CUES["working"])} agents')
    if '--loop' in sys.argv:
        if mode != 'app':
            sys.exit("--loop renders the 'app' bed; this video's music is " + repr(mode))
        write_loop(sys.argv[sys.argv.index('--loop') + 1], meter)


if __name__ == '__main__':
    main()
