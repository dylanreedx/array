#!/usr/bin/env python3
"""Draw the Kinetic Marks and Field Units agent icon packs.

Both packs are original art, drawn here from geometry: nothing is traced or
sampled. Kinetic Marks is twelve flat two-tone shapes that tumble, scan and
orbit; Field Units is twelve small working machines, each moving the way its
build does (wheels, legs, rotors, a hopping pogo, a monowheel, a coil).

Writes, for each pack, Sources/ContinuumRevivedCharacterPacks/Resources/packs/
<id>/theme.json and the sounds it names (synthesised here too). Run
scripts/make-character-pack-cards.py afterwards for card.json and the manifest.

Needs numpy:  python3 -m venv /tmp/v && /tmp/v/bin/pip install numpy
"""
import json
import math
import pathlib
import struct
import wave

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKS = ROOT / "Sources/ContinuumRevivedCharacterPacks/Resources/packs"

W, H = 80, 48          # helper frame at scale 4 (20 x 12 points)
LW, LH = 112, 64       # lead frame at scale 4 (28 x 16 points)
SS = 3                 # supersamples per side; a pixel is set at 5 of 9


# --------------------------------------------------------------------------
# Raster: shapes are masks over sample coordinates; a canvas paints letters.

class Shape:
    def __init__(self, fn):
        self.fn = fn

    def mask(self, x, y):
        return self.fn(x, y)

    def __or__(self, other):
        return Shape(lambda x, y: self.fn(x, y) | other.fn(x, y))

    def __and__(self, other):
        return Shape(lambda x, y: self.fn(x, y) & other.fn(x, y))

    def __sub__(self, other):
        return Shape(lambda x, y: self.fn(x, y) & ~other.fn(x, y))

    def xf(self, cx=0.0, cy=0.0, rot=0.0, sx=1.0, sy=1.0, dx=0.0, dy=0.0):
        """Rotate (degrees, clockwise on screen) and scale about (cx, cy), then move."""
        c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))

        def fn(x, y):
            u, v = x - cx - dx, y - cy - dy
            ru, rv = c * u + s * v, -s * u + c * v
            return self.fn(ru / sx + cx, rv / sy + cy)
        return Shape(fn)


def circle(cx, cy, r):
    return Shape(lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r)


def ellipse(cx, cy, rx, ry):
    return Shape(lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1)


def ring(cx, cy, r_out, r_in):
    return circle(cx, cy, r_out) - circle(cx, cy, r_in)


def rect(x0, y0, w, h, r=0.0):
    def fn(x, y):
        qx = np.abs(x - (x0 + w / 2)) - (w / 2 - r)
        qy = np.abs(y - (y0 + h / 2)) - (h / 2 - r)
        return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) <= r
    return Shape(fn)


def poly(points):
    pts = list(points)

    def fn(x, y):
        inside = np.zeros_like(x, dtype=bool)
        n = len(pts)
        for i in range(n):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % n]
            if y1 == y2:
                continue
            cond = (y1 > y) != (y2 > y)
            xi = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            inside ^= cond & (x < xi)
        return inside
    return Shape(fn)


def seg(x1, y1, x2, y2, w):
    def fn(x, y):
        dx, dy = x2 - x1, y2 - y1
        L = dx * dx + dy * dy
        t = np.clip(((x - x1) * dx + (y - y1) * dy) / L, 0, 1) if L else 0
        return np.hypot(x - x1 - t * dx, y - y1 - t * dy) <= w / 2
    return Shape(fn)


def path(points, w):
    shape = seg(*points[0], *points[1], w)
    for a, b in zip(points[1:], points[2:]):
        shape = shape | seg(*a, *b, w)
    return shape


def half_plane(cx, cy, angle):
    """Points on the side the angle (degrees) points to, from (cx, cy)."""
    nx, ny = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    return Shape(lambda x, y: (x - cx) * nx + (y - cy) * ny >= 0)


def band(y0, y1):
    return Shape(lambda x, y: (y >= y0) & (y < y1))


def regular(cx, cy, r, n, start=-90):
    return poly([(cx + r * math.cos(math.radians(start + 360 * i / n)),
                  cy + r * math.sin(math.radians(start + 360 * i / n))) for i in range(n)])


def star(cx, cy, r_out, r_in, n=4, start=-90):
    pts = []
    for i in range(2 * n):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(start + 180 * i / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return poly(pts)


class Canvas:
    _grids = {}

    def __init__(self, w=W, h=H):
        self.w, self.h = w, h
        self.g = np.full((h, w), ".", dtype="<U1")
        if (w, h) not in Canvas._grids:
            o = (np.arange(SS) + 0.5) / SS
            xs = (np.arange(w)[:, None] + o[None, :]).reshape(-1)
            ys = (np.arange(h)[:, None] + o[None, :]).reshape(-1)
            Canvas._grids[(w, h)] = np.meshgrid(xs, ys)
        self.x, self.y = Canvas._grids[(w, h)]

    def fill(self, shape, letter, clip=None):
        m = shape.mask(self.x, self.y)
        if clip is not None:
            m &= clip.mask(self.x, self.y)
        cover = m.reshape(self.h, SS, self.w, SS).sum(axis=(1, 3))
        self.g[cover >= (SS * SS + 1) // 2] = letter

    def ink(self):
        return self.g != "."

    def rows(self):
        return ["".join(r) for r in self.g]


# --------------------------------------------------------------------------
# Colour helpers.

def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def rgbhex(c):
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(v))) for v in c)


def mix(a, b, t):
    a, b = hexrgb(a), hexrgb(b)
    return rgbhex([a[i] + (b[i] - a[i]) * t for i in range(3)])


SHARED = {
    "0": "#262A31",   # deep graphite: small inner details only
    "1": "#F6F7F9",   # white
    "2": "#2FBF62",   # done green
    "3": "#E5484D",   # failed red
    "4": "#F5A524",   # needs-you amber
    "5": "#8B95A3",   # machine grey (legs, wheels, rotors)
    "6": "#5E6773",   # machine grey, shade
    "7": "#7FE3FF",   # lens glow
    "8": "#BFC6D0",   # machine grey, light
    "9": "#A4ACB8",   # sleepy grey
}
MAIN, LIGHT, SHADE = "abcdefghijkl", "ABCDEFGHIJKL", "mnopqrstuvwx"


def palette_for(members):
    pal = dict(SHARED)
    for i, (_, colour) in enumerate(members):
        pal[MAIN[i]] = colour
        pal[LIGHT[i]] = mix(colour, "#FFFFFF", 0.42)
        pal[SHADE[i]] = mix(colour, "#000000", 0.32)
    return pal


# --------------------------------------------------------------------------
# Shared overlays (both packs).

def check_badge(c, x, y, r=5.5):
    c.fill(circle(x, y, r), "2")
    c.fill(path([(x - 2.8, y + 0.2), (x - 0.6, y + 2.4), (x + 3.0, y - 2.2)], 1.9), "1")


def cross_badge(c, x, y, r=5.5):
    c.fill(circle(x, y, r), "3")
    c.fill(seg(x - 2.3, y - 2.3, x + 2.3, y + 2.3, 1.9) | seg(x - 2.3, y + 2.3, x + 2.3, y - 2.3, 1.9), "1")


def zees(c, x, y, k, letter="9"):
    for i in range(k):
        s = 3.2 + i * 0.9
        zx, zy = x + i * 5, y - i * 6
        c.fill(path([(zx, zy), (zx + s, zy), (zx, zy + s), (zx + s, zy + s)], 1.4), letter)


def exclaim(c, x, y, lift=0.0):
    c.fill(rect(x - 1.6, y - 9 + lift, 3.2, 7, 1.4), "4")
    c.fill(circle(x, y + 1.6 + lift, 1.7), "4")


def dots(c, x, y, k, letter):
    for i in range(k):
        c.fill(circle(x + i * 5, y, 1.7), letter)


def speed_lines(c, x, y, k, letter, gap=6):
    """Three trailing dashes that slide back as k steps."""
    for i, (dy, ln) in enumerate([(-6, 7), (0, 10), (6, 6)]):
        off = ((k * 3 + i * 4) % 9)
        c.fill(rect(x - ln - off, y + dy, ln, 1.6, 0.8), letter)


def sparkles(c, cx, cy, r, letter, phase=0):
    for i in range(4):
        a = math.radians(45 + 90 * i + phase)
        x1, y1 = cx + math.cos(a) * r, cy + math.sin(a) * r
        x2, y2 = cx + math.cos(a) * (r + 4), cy + math.sin(a) * (r + 4)
        c.fill(seg(x1, y1, x2, y2, 1.6), letter)


# --------------------------------------------------------------------------
# Kinetic Marks: twelve flat shapes, two-tone, with a facet that turns with
# them so a roll reads even on the disc.

CX, CY = 40.0, 24.0

KINETIC = [
    ("Disc", "#FF5A4E"),
    ("Delta", "#FF9A3C"),
    ("Crescent", "#EDC531"),
    ("Spark", "#9FCF35"),
    ("Cross", "#35B866"),
    ("Rhomb", "#1FBFAE"),
    ("Arch", "#3EADEB"),
    ("Block", "#3D78F5"),
    ("Hexa", "#9B59E8"),
    ("Slant", "#D9529E"),
    ("Halo", "#FF7C8F"),
    ("Chevron", "#9AA5B4"),
]


MARK_SCALE = 1.18


def mark_shape(name, cx=CX, cy=CY):
    return _mark_shape(name, cx, cy).xf(cx, cy, 0, MARK_SCALE, MARK_SCALE)


def _mark_shape(name, cx, cy):
    if name == "Disc":
        return circle(cx, cy, 14.5)
    if name == "Delta":
        return regular(cx, cy + 2.5, 18.5, 3)
    if name == "Crescent":
        return circle(cx, cy, 15) - circle(cx + 8.5, cy - 4.5, 11.5)
    if name == "Spark":
        return star(cx, cy, 17.5, 6.2, 4)
    if name == "Cross":
        return rect(cx - 15, cy - 5.5, 30, 11, 2.5) | rect(cx - 5.5, cy - 15, 11, 30, 2.5)
    if name == "Rhomb":
        return poly([(cx, cy - 17), (cx + 14, cy), (cx, cy + 17), (cx - 14, cy)])
    if name == "Arch":
        return rect(cx - 14, cy - 15, 28, 30, 3) - (rect(cx - 6, cy - 1, 12, 20, 0) | circle(cx, cy - 1, 6))
    if name == "Block":
        return rect(cx - 13.5, cy - 13.5, 27, 27, 4)
    if name == "Hexa":
        return regular(cx, cy, 17, 6, 0).xf(cx, cy, 0, 1.0, 0.78)
    if name == "Slant":
        return poly([(cx - 9, cy - 13), (cx + 17, cy - 13), (cx + 9, cy + 13), (cx - 17, cy + 13)])
    if name == "Halo":
        return ring(cx, cy, 15, 7.5)
    if name == "Chevron":
        return poly([(cx - 12, cy - 15), (cx - 1, cy - 15), (cx + 14, cy), (cx - 1, cy + 15),
                     (cx - 12, cy + 15), (cx + 2, cy)])
    raise KeyError(name)


def kinetic_pose(c, i, name, dx=0.0, dy=0.0, rot=0.0, sx=1.0, sy=1.0, tone="main", scan=None, pivot=None):
    """Draw member i: its body, a lighter facet on the upper-left half that
    turns with it, and optionally a light scan band."""
    px, py = pivot if pivot else (CX, CY)
    body = mark_shape(name).xf(px, py, rot, sx, sy, dx, dy)
    facet = (mark_shape(name) & half_plane(CX, CY, 225) & circle(CX - 5, CY - 5, 15)).xf(px, py, rot, sx, sy, dx, dy)
    main, light = (MAIN[i], LIGHT[i]) if tone == "main" else (SHADE[i], MAIN[i])
    c.fill(body, main)
    c.fill(facet, light)
    if scan is not None:
        c.fill(body & band(scan, scan + 3.5), "1")
    return body


def kinetic_member(i, name):
    def frame(**kw):
        c = Canvas()
        extra = kw.pop("extra", None)
        kinetic_pose(c, i, name, **kw)
        if extra:
            extra(c)
        return c.rows()

    loops = {}
    # run: a tumbling roll to the right with a bounce and trailing dashes.
    run = []
    for k in range(8):
        hop = -abs(math.sin(math.pi * k / 4)) * 3.0
        run.append(frame(rot=45 * k, dy=hop, sx=1.0, sy=1.0,
                         extra=lambda c, k=k: speed_lines(c, 18, CY + 2, k, LIGHT[i])))
    loops["run"] = {"frameMs": 100, "frames": run}
    # type: quick taps (squash) while a line of input grows to its right.
    typing = []
    for k in range(6):
        sq = [1.0, 0.9, 1.0, 0.92, 1.0, 0.94][k]

        def extra(c, k=k):
            for j in range(k % 4 + 1):
                c.fill(rect(60 + j * 4, 36, 3, 3, 0.6), MAIN[i])
            if k % 2 == 0:
                c.fill(rect(60 + (k % 4 + 1) * 4, 33, 2, 7, 0.4), "1")
        typing.append(frame(sx=2 - sq, sy=sq, dy=(1 - sq) * 14, dx=-4, extra=extra))
    loops["type"] = {"frameMs": 140, "frames": typing}
    # read: a light band sweeps down through the shape.
    loops["read"] = {"frameMs": 260, "frames": [frame(scan=CY - 16 + 6 * k) for k in range(6)]}
    # dabble (search): a satellite circles while the shape leans to look.
    dab = []
    for k in range(8):
        a = math.radians(360 * k / 8)
        ox, oy = CX + 23 * math.cos(a), CY + 9 * math.sin(a)
        behind = math.sin(a) < 0

        def extra(c, ox=ox, oy=oy, behind=behind):
            if not behind:
                c.fill(circle(ox, oy, 3.2), "1")
                c.fill(circle(ox, oy, 1.6), MAIN[i])
        c = Canvas()
        if behind:
            c.fill(circle(ox, oy, 2.6), LIGHT[i])
        kinetic_pose(c, i, name, rot=10 * math.sin(a))
        extra(c)
        dab.append(c.rows())
    loops["dabble"] = {"frameMs": 180, "frames": dab}
    # think: slow breath and an ellipsis.
    think = []
    for k in range(6):
        s = 1 - 0.06 * (0.5 - 0.5 * math.cos(math.pi * 2 * k / 6))
        think.append(frame(sx=s, sy=s, extra=lambda c, k=k: dots(c, 58, 8, k % 4, LIGHT[i])))
    loops["think"] = {"frameMs": 380, "frames": think}

    ends = {}
    ends["done"] = frame(extra=lambda c: check_badge(c, 56, 37))
    ends["failed"] = frame(tone="shade", sy=0.92, dy=1.5, extra=lambda c: cross_badge(c, 56, 37))
    cheer = []
    for k, (hop, r) in enumerate([(0, 0), (-6, -12), (-8, 12), (-3, 0)]):
        cheer.append(frame(dy=hop, rot=r, extra=(lambda c, hop=hop: sparkles(c, CX, CY + hop, 20, "4")) if k in (1, 2) else None))
    ends["cheer"] = cheer
    ends["droop"] = [frame(sy=s, sx=2 - s, dy=(1 - s) * 16, rot=t) for s, t in [(1, 0), (0.86, 6), (0.74, 10)]]
    ends["asleep"] = [frame(tone="sleep", sy=0.9, dy=1.5, extra=lambda c, k=k: zees(c, 58, 14, k + 1)) for k in range(3)]
    ends["idle"] = [frame(), frame(), frame(dy=-1), frame()]
    ends["flinch"] = [frame(dx=-3, rot=-7), frame(dx=3, rot=7)]
    ends["wave"] = [frame(extra=lambda c: exclaim(c, 62, 14)), frame(dy=-3, extra=lambda c: exclaim(c, 62, 14, -2)),
                    frame(extra=lambda c: exclaim(c, 62, 14))]
    ends["noticed"] = [frame(sx=1.14, sy=0.86, dy=2), frame(sx=0.9, sy=1.12, dy=-2), frame()]
    return {"name": name, "loops": loops, "ends": ends}


def kinetic_lead():
    """The family as a 2 x 2 tile; with n helpers, n marks orbit it."""
    lcx, lcy = LW / 2, LH / 2
    quad = [(0, -11, -10), (7, 11, -10), (1, -11, 10), (5, 11, 10)]   # Disc, Block, Delta, Rhomb

    def core(c, spread=0.0, pulse=1.0):
        for i, ox, oy in quad:
            name = KINETIC[i][0]
            sx = sy = 0.5 * pulse
            body = mark_shape(name, lcx, lcy).xf(lcx, lcy, 0, sx, sy, ox * (1 + spread), oy * (1 + spread))
            c.fill(body, MAIN[i])
            c.fill(body & half_plane(lcx + ox, lcy + oy, 225), LIGHT[i])

    orbiters = [10, 4, 8]  # Halo, Spark, Hexa

    def level(n):
        frames = []
        for k in range(8):
            c = Canvas(LW, LH)
            items = []
            for j in range(n):
                a = math.radians(360 * k / 8 + 360 * j / n)
                items.append((math.sin(a), j, lcx + 40 * math.cos(a), lcy + 14 * math.sin(a)))
            for depth, j, x, y in sorted(items):
                if depth < 0:
                    c.fill(mark_shape(KINETIC[orbiters[j]][0], x, y).xf(x, y, 0, 0.32, 0.32), SHADE[orbiters[j]])
            core(c)
            for depth, j, x, y in sorted(items):
                if depth >= 0:
                    b = mark_shape(KINETIC[orbiters[j]][0], x, y).xf(x, y, 0, 0.4, 0.4)
                    c.fill(b, MAIN[orbiters[j]])
            frames.append(c.rows())
        return frames

    rest = []
    for k in range(4):
        c = Canvas(LW, LH)
        core(c, pulse=[1, 1, 1.04, 1][k])
        rest.append(c.rows())
    rising = []
    for s in (0.15, 0.3, 0.1):
        c = Canvas(LW, LH)
        core(c, spread=s)
        rising.append(c.rows())
    return {"rest": rest, "rising": rising, "levels": [level(1), level(2), level(3)]}


# --------------------------------------------------------------------------
# Field Units: twelve small machines. Each draws itself at a locomotion phase
# `t` (0..1) with a bob and lean; states add a shared overlay at the machine's
# own lens, tool and mast points.

FIELD = [
    ("Rover", "#E8833A"),
    ("Strider", "#1FAE9E"),
    ("Rotor", "#3FA2F0"),
    ("Crane", "#E9B92A"),
    ("Probe", "#8E6CF0"),
    ("Scope", "#47B75A"),
    ("Crawler", "#E5534B"),
    ("Gyro", "#CF58D6"),
    ("Console", "#8DA2BA"),
    ("Hover", "#F27FA5"),
    ("Coil", "#A0C93A"),
    ("Spindle", "#3F68DB"),
]
GROUND = 44.0


class Pose:
    def __init__(self, t=0.0, moving=False, bob=0.0, lean=0.0, lens="on", tool=None, screen=None, dim=False):
        self.t, self.moving, self.bob, self.lean = t, moving, bob, lean
        self.lens, self.tool, self.screen, self.dim = lens, tool, screen, dim


def lens_letter(p):
    return {"on": "7", "blink": None, "red": "3", "green": "2", "off": "6", "amber": "4"}.get(p.lens, "7")


def wheel(c, x, y, r, t, hub="0"):
    c.fill(circle(x, y, r), "5")
    c.fill(circle(x, y, r - 1.6), "6")
    a = 2 * math.pi * t
    for j in range(2):
        b = a + j * math.pi / 2
        c.fill(seg(x - math.cos(b) * (r - 1.6), y - math.sin(b) * (r - 1.6),
                   x + math.cos(b) * (r - 1.6), y + math.sin(b) * (r - 1.6), 1.3), "8")
    c.fill(circle(x, y, 1.4), hub)


def leg(c, hip, foot, bend, w, letter="5"):
    """A two-segment leg; bend > 0 pushes the knee forward (right)."""
    hx, hy = hip
    fx, fy = foot
    mx, my = (hx + fx) / 2, (hy + fy) / 2
    L = math.hypot(fx - hx, fy - hy) or 1
    nx, ny = (fy - hy) / L, -(fx - hx) / L
    kx, ky = mx - nx * bend, my - ny * bend
    c.fill(path([(hx, hy), (kx, ky), (fx, fy)], w), letter)
    c.fill(circle(kx, ky, w * 0.55), "6")


def draw_field(c, i, name, p):
    M, L, S = (MAIN[i], LIGHT[i], SHADE[i]) if not p.dim else (SHADE[i], MAIN[i], SHADE[i])
    lens = lens_letter(p)
    t, b, lean = p.t, p.bob, p.lean
    pts = {}

    def body(shape, letter):
        c.fill(shape.xf(40, 34, lean, 1, 1, 0, b), letter)

    if name == "Rover":
        for k, x in enumerate((27, 40, 53)):
            wheel(c, x, 39, 5.2, t + k * 0.1)
        body(rect(22, 25, 36, 11, 2.5), M)
        body(rect(22, 25, 36, 3.5, 1.6), L)
        body(rect(25, 31, 30, 2, 0.8), S)
        body(seg(51, 25, 51, 16, 2.2), "5")
        body(rect(45, 11, 13, 6, 2), M)
        if lens:
            body(rect(49, 12.8, 8, 2.4, 1), lens)
        pts = {"lens": (57, 14 + b), "tool": (60, 30 + b), "mast": (51, 9 + b)}
    elif name == "Strider":
        ph = 2 * math.pi * t
        for side, off in ((0, 0.0), (1, math.pi)):
            sw = math.sin(ph + off) * (7 if p.moving else 0)
            lift = max(0, math.cos(ph + off)) * (3.5 if p.moving else 0)
            hip = (36 + side * 8, 30 + b)
            foot = (36 + side * 8 + sw, GROUND - 2 - lift)
            leg(c, hip, foot, 3.0, 3.4, "5" if side else "6")
            c.fill(rect(foot[0] - 4, foot[1] - 1, 8, 3, 1.2), "6" if not side else "5")
        body(rect(27, 9, 26, 22, 5), M)
        body(rect(27, 9, 26, 5, 3), L)
        body(rect(30, 16, 20, 5.5, 2.7), "0")
        if lens:
            sx = {"scan": 6 * math.sin(2 * math.pi * t)}.get(p.screen, 0) + 4
            body(rect(36 + sx - 4, 17.2, 8, 3.2, 1.6), lens)
        body(seg(48, 9, 51, 3, 1.4), "5")
        body(circle(51, 3, 1.6), "4")
        pts = {"lens": (50, 18 + b), "tool": (56, 26 + b), "mast": (51, 2 + b)}
    elif name == "Rotor":
        body(seg(25, 22, 55, 22, 2.6), "5")
        for x in (25, 55):
            blade = abs(math.cos(math.pi * 2 * t * (2 if p.moving else 1))) * 9 + 2
            body(rect(x - blade, 18.5, blade * 2, 2.4, 1.2), "8")
            body(rect(x - 1.5, 19, 3, 4, 1), "6")
        body(ellipse(40, 28, 11, 7.5), M)
        body(ellipse(40, 25.5, 9, 4), L)
        body(seg(33, 35, 31, 41, 1.6) | seg(47, 35, 49, 41, 1.6), "5")
        body(seg(28, 41, 36, 41, 1.6) | seg(44, 41, 52, 41, 1.6), "5")
        body(circle(45, 30, 3.6), "0")
        if lens:
            body(circle(45.5, 30, 2.2), lens)
        pts = {"lens": (49, 30 + b), "tool": (52, 36 + b), "mast": (40, 15 + b)}
    elif name == "Crane":
        c.fill(rect(19, 35, 30, 9, 4.5), "5")
        for k in range(4):
            x = 23 + ((k * 7 + t * 7) % 24)
            c.fill(circle(x, 39.5, 1.7), "0")
        c.fill(rect(25, 26, 18, 10, 2), M)
        c.fill(rect(25, 26, 18, 3, 1.4), L)
        if lens:
            c.fill(rect(35, 29.5, 6, 2.6, 1.2), lens)
        tap = p.tool if p.tool is not None else 0.0
        a1 = math.radians(-58 + tap * 10)
        jx, jy = 40 + math.cos(a1) * 16, 27 + math.sin(a1) * 16
        a2 = math.radians(40 + tap * 22)
        ex, ey = jx + math.cos(a2) * 13, jy + math.sin(a2) * 13
        c.fill(seg(40, 27, jx, jy, 4.2), S)
        c.fill(seg(jx, jy, ex, ey, 3.2), M)
        c.fill(circle(jx, jy, 2.4), "6")
        c.fill(path([(ex - 3, ey + 1), (ex, ey + 4), (ex + 3, ey + 1)], 1.6), "5")
        pts = {"lens": (41, 30), "tool": (ex, ey + 5), "mast": (jx, jy - 4)}
    elif name == "Probe":
        cy = 23 + b
        c.fill((ellipse(40, cy, 19, 5) - ellipse(40, cy, 15.5, 3)) & band(0, cy), "6")
        c.fill(circle(40, cy, 12.5), M)
        c.fill(circle(40, cy, 12.5) & half_plane(40, cy, 230) & circle(36, cy - 4, 10), L)
        c.fill((ellipse(40, cy, 19, 5) - ellipse(40, cy, 15.5, 3)) & band(cy, 99), "8")
        off = 5 * math.sin(2 * math.pi * t) if p.screen == "scan" else 3
        c.fill(rect(37 + off - 4.5, cy - 6, 9, 3.4, 1.7), "0")
        if lens:
            c.fill(rect(37 + off - 3, cy - 5.3, 6, 2, 1), lens)
        if p.moving:
            fl = 4 + 3 * (int(t * 8) % 2)
            c.fill(poly([(36, cy + 13), (44, cy + 13), (40, cy + 13 + fl)]), "4")
        pts = {"lens": (44, cy - 4.5), "tool": (56, cy + 4), "mast": (40, cy - 15)}
    elif name == "Scope":
        hop = p.bob
        sq = 1.0 if hop < -1 else 0.8 if p.moving else 1.0
        c.fill(ellipse(40, GROUND - 1.5, 9, 2.5), "6")
        c.fill(path([(40, GROUND - 3), (40, 36 + hop)], 2.2), "5")
        for k in range(3):
            c.fill(seg(36, 38 + hop + k * 2 * sq, 44, 37 + hop + k * 2 * sq, 1.2), "8")
        c.fill(rect(34, 18 + hop, 12, 18, 3), M)
        c.fill(rect(34, 18 + hop, 4, 18, 2), L)
        c.fill(rect(38.5, 13 + hop, 3, 6, 1), "5")
        c.fill(circle(40, 10 + hop, 7), S)
        c.fill(circle(40, 10 + hop, 7) & half_plane(40, 10 + hop, 220), M)
        look = 3 * math.sin(2 * math.pi * t) if p.screen == "scan" else 2.5
        c.fill(circle(40 + look, 10 + hop, 3.6), "0")
        if lens:
            c.fill(circle(40 + look, 10 + hop, 2.2), lens)
        pts = {"lens": (44, 10 + hop), "tool": (50, 26 + hop), "mast": (40, 2 + hop)}
    elif name == "Crawler":
        ph = 2 * math.pi * t
        for k, x in enumerate((29, 39, 49)):
            for side in (0, 1):
                off = (k + side) % 2 * math.pi
                sw = math.sin(ph + off) * (4 if p.moving else 0)
                lift = max(0, math.cos(ph + off)) * (3 if p.moving else 0)
                col = "6" if side == 0 else "5"
                hx, hy = x + (side * 2 - 1), 32 + b
                kx, ky = x + sw * 0.5 + (side * 2 - 1) * 3, 26 + b
                fx, fy = x + sw + (side * 2 - 1) * 5, GROUND - 1 - lift
                c.fill(path([(hx, hy), (kx, ky), (fx, fy)], 2.2), col)
        c.fill(ellipse(39, 31 + b, 15, 6.5), M)
        c.fill(ellipse(37, 28.5 + b, 11, 3), L)
        c.fill(poly([(52, 26 + b), (60, 29 + b), (60, 34 + b), (52, 36 + b)]), S)
        if lens:
            c.fill(rect(55, 29 + b, 4, 2.4, 1), lens)
        c.fill(seg(57, 27 + b, 63, 21 + b, 1.2), "5")
        pts = {"lens": (60, 30 + b), "tool": (64, 34 + b), "mast": (63, 19 + b)}
    elif name == "Gyro":
        cy = 27
        c.fill(ring(40, cy, 16, 11.5), "5")
        for k in range(8):
            a = 2 * math.pi * (k / 8 + t / 4)
            c.fill(circle(40 + math.cos(a) * 14.2, cy + math.sin(a) * 14.2, 1.3), "0")
        c.fill(ring(40, cy, 11.5, 10.5), "6")
        sway = lean * 0.25
        c.fill(ellipse(40 + sway, cy + 1, 8.5, 9), M)
        c.fill(ellipse(38 + sway, cy - 3, 6, 4), L)
        c.fill(rect(40 + sway, cy - 3, 7, 4, 2), "0")
        if lens:
            c.fill(rect(41.5 + sway, cy - 2.2, 5, 2.4, 1.2), lens)
        pts = {"lens": (48, cy - 1), "tool": (58, cy + 6), "mast": (40, cy - 18)}
    elif name == "Console":
        ph = 2 * math.pi * t
        for side in (0, 1):
            lift = max(0, math.sin(ph + side * math.pi)) * (3 if p.moving else 0)
            x = 34 + side * 12
            c.fill(rect(x - 1.5, 32 + b, 3, 9 - lift, 1), "5")
            c.fill(rect(x - 4, GROUND - 3.5 - lift, 8, 3.5, 1.4), "6")
        c.fill(rect(26, 8 + b, 28, 25, 3.5), M)
        c.fill(rect(26, 8 + b, 28, 4, 2.5), L)
        c.fill(rect(29.5, 12 + b, 21, 15, 2), "0")
        console_screen(c, 30, 13 + b, p)
        c.fill(circle(50, 30 + b, 1.2), "4" if p.lens == "amber" else "2")
        pts = {"lens": (50, 18 + b), "tool": (57, 24 + b), "mast": (40, 5 + b)}
    elif name == "Hover":
        cy = 25 + b
        if p.moving:
            c.fill(ellipse(40, GROUND - 1, 11 + 2 * (int(t * 8) % 2), 1.5), "6")
        c.fill(ellipse(40, cy - 3, 9, 8) & band(0, cy - 1), "7" if lens else "6")
        c.fill(ellipse(38, cy - 6, 3.5, 2.5), "1")
        c.fill(ellipse(40, cy + 1, 20, 5.5).xf(40, cy, lean), M)
        c.fill((ellipse(40, cy + 1, 20, 5.5) & band(0, cy)).xf(40, cy, lean), L)
        for k in range(4):
            on = (k + int(t * 8)) % 4 == 0 if p.moving else k % 2 == 0
            c.fill(circle(28 + k * 8, cy + 3, 1.4).xf(40, cy, lean), "4" if on else S)
        pts = {"lens": (46, cy - 5), "tool": (40, cy + 12), "mast": (40, cy - 13)}
    elif name == "Coil":
        ph = 2 * math.pi * t
        segs = []
        for k in range(5):
            x = 22 + k * 7.5
            y = 33 + math.sin(ph - k * 1.1) * (3.5 if p.moving else 1.2) + b
            segs.append((x, y, 4.2 + k * 0.45))
        for (x1, y1, _), (x2, y2, _) in zip(segs, segs[1:]):
            c.fill(seg(x1, y1, x2, y2, 3), "6")
        for k, (x, y, r) in enumerate(segs):
            c.fill(circle(x, y, r), M if k % 2 else S)
            c.fill(circle(x - 0.8, y - 1.6, r * 0.5), L)
        hx, hy = 61, segs[-1][1] - 3
        c.fill(rect(hx - 9, hy - 6, 14, 11, 4), M)
        c.fill(rect(hx - 9, hy - 6, 14, 3.5, 2), L)
        c.fill(rect(hx - 2, hy - 2, 6, 3.4, 1.7), "0")
        if lens:
            c.fill(rect(hx - 1, hy - 1.3, 4.5, 2, 1), lens)
        pts = {"lens": (hx + 4, hy - 1), "tool": (hx + 7, hy + 4), "mast": (hx - 2, hy - 9)}
    elif name == "Spindle":
        ph = 2 * math.pi * t
        for k, (hx, fx) in enumerate(((35, 22), (45, 58), (37, 28), (43, 52))):
            off = (k % 2) * math.pi
            sw = math.sin(ph + off) * (4 if p.moving else 0)
            lift = max(0, math.cos(ph + off)) * (3.5 if p.moving else 0)
            kx = hx + (fx - hx) * 0.7 + sw * 0.4
            col = "5" if k < 2 else "6"
            c.fill(path([(hx, 19 + b), (kx, 9 + b), (fx + sw, GROUND - 1 - lift)], 2.3), col)
            c.fill(circle(kx, 9 + b, 1.6), "8")
        c.fill(ellipse(40, 21 + b, 10, 7), M)
        c.fill(ellipse(38, 18.5 + b, 7, 3), L)
        c.fill(rect(41, 20 + b, 8, 3.6, 1.8), "0")
        if lens:
            c.fill(rect(42.5, 20.8 + b, 5.5, 2, 1), lens)
        pts = {"lens": (49, 21 + b), "tool": (52, 28 + b), "mast": (40, 13 + b)}
    else:
        raise KeyError(name)
    return pts


def console_screen(c, x, y, p):
    """The Console's face: what it shows is its state."""
    s = p.screen or "idle"
    k = int(p.t * 6 + 0.001)
    clip = rect(x, y, 19, 13, 1)
    if s == "type":
        for row in range(3):
            n = [3, 2, 1][row] if row < k % 4 else 0
            ln = min(15, n * 5 + (k % 2) * 2) if row == k % 4 - 1 or row < k % 4 else 0
            if row < k % 4:
                c.fill(rect(x + 2, y + 2 + row * 4, [13, 9, 15][row] if row < k % 4 - 1 else 4 + 3 * (k % 3), 2, 0.6), "7")
        c.fill(rect(x + 2 + (k % 3) * 3, y + 2 + (k % 4) * 4 - (4 if k % 4 == 3 else 0), 2, 2.5, 0.4), "1")
    elif s == "read":
        for row in range(3):
            c.fill(rect(x + 2, y + 2 + row * 4, [14, 10, 13][row], 1.6, 0.6), "6")
        c.fill(rect(x + 1, y + 1 + (k % 6) * 2, 17, 1.8, 0.6), "7", clip)
    elif s == "scan":
        a = 2 * math.pi * k / 6
        cx, cy = x + 9.5, y + 6.5
        c.fill(ring(cx, cy, 5.5, 4.5), "6")
        c.fill(seg(cx, cy, cx + math.cos(a) * 5, cy + math.sin(a) * 5, 1.5), "7")
    elif s == "think":
        for j in range(3):
            c.fill(circle(x + 5 + j * 4.5, y + 6.5, 1.5), "7" if j == k % 3 else "6")
    elif s == "run":
        for j in range(2):
            ox = x + 3 + ((k * 2 + j * 7) % 14)
            c.fill(path([(ox, y + 3), (ox + 3.5, y + 6.5), (ox, y + 10)], 1.6), "7", clip)
    elif s == "done":
        c.fill(path([(x + 5, y + 6.5), (x + 8.5, y + 10), (x + 14.5, y + 3)], 2), "2")
    elif s == "failed":
        c.fill(seg(x + 6, y + 3, x + 13, y + 10, 2) | seg(x + 6, y + 10, x + 13, y + 3, 2), "3")
    elif s == "sleep":
        c.fill(rect(x + 5, y + 6, 9, 1.6, 0.6), "6")
    elif s == "wave":
        c.fill(rect(x + 8.5, y + 2, 2.2, 6, 1), "4")
        c.fill(circle(x + 9.6, y + 10, 1.3), "4")
    else:
        c.fill(rect(x + 4, y + 5, 3, 3, 1) | rect(x + 12, y + 5, 3, 3, 1), "7")


def field_member(i, name):
    def frame(pose, extra=None, before=None):
        c = Canvas()
        if before:
            before(c)
        pts = draw_field(c, i, name, pose)
        if extra:
            extra(c, pts)
        return c.rows()

    hopper = name == "Scope"
    loops = {}
    # run: the machine's own locomotion at speed, with dust behind.
    run = []
    for k in range(8):
        t = k / 8
        bob = -abs(math.sin(math.pi * 2 * t)) * (7 if hopper else 1.2)
        lean = {"Rotor": 10, "Hover": 8, "Gyro": 10, "Probe": 0}.get(name, 0)
        run.append(frame(Pose(t=t, moving=True, bob=bob, lean=lean, screen="run"),
                         before=lambda c, k=k: speed_lines(c, 20, 36, k, "8")))
    loops["run"] = {"frameMs": 100, "frames": run}

    # type: a tool taps at the front and throws a spark on contact.
    typing = []
    for k in range(6):
        down = k % 2 == 1

        def extra(c, pts, k=k, down=down):
            if name == "Crane":
                if down:
                    sparkles(c, *pts["tool"], 1.5, "4", phase=k * 20)
                return
            tx, ty = pts["tool"]
            c.fill(seg(tx - 5, ty, tx, ty + (3 if down else -1), 1.8), "5")
            c.fill(circle(tx, ty + (3 if down else -1), 1.6), "8")
            if down:
                sparkles(c, tx + 1, ty + 4, 1.2, "4", phase=k * 20)
        typing.append(frame(Pose(t=k / 6, tool=1.0 if down else 0.0, bob=0.6 if down else 0, screen="type"), extra))
    loops["type"] = {"frameMs": 140, "frames": typing}

    # read: the lens sweeps a scan line across what is in front of it.
    read = []
    for k in range(6):
        def extra(c, pts, k=k):
            lx, ly = pts["lens"]
            a = math.radians(-18 + 36 * (0.5 - 0.5 * math.cos(math.pi * 2 * k / 6)))
            for j in range(3):
                r0 = 3 + j * 4.5
                c.fill(seg(lx + math.cos(a) * r0, ly + math.sin(a) * r0,
                           lx + math.cos(a) * (r0 + 2.4), ly + math.sin(a) * (r0 + 2.4), 1.5), "7")
        read.append(frame(Pose(t=k / 6, screen="read" if name == "Console" else "scan"), extra))
    loops["read"] = {"frameMs": 260, "frames": read}

    # dabble (search): radar arcs rise from the mast.
    dab = []
    for k in range(6):
        def extra(c, pts, k=k):
            mx, my = pts["mast"]
            for j in range(2):
                r = 2.5 + ((k + j * 3) % 6) * 1.6
                arc = ring(mx, my, r + 0.9, r - 0.7) & band(0, my - r * 0.35)
                c.fill(arc, "7" if j == 0 else "8")
        dab.append(frame(Pose(t=k / 6, screen="scan", lean=3 * math.sin(math.pi * 2 * k / 6)), extra))
    loops["dabble"] = {"frameMs": 180, "frames": dab}

    # think: a slow lens pulse and an ellipsis off its mast.
    think = []
    for k in range(6):
        def extra(c, pts, k=k):
            mx, my = pts["mast"]
            dots(c, min(66, mx + 6), max(4, my), k % 4, "8")
        think.append(frame(Pose(t=k / 6, lens="on" if k % 3 else "off", screen="think"), extra))
    loops["think"] = {"frameMs": 380, "frames": think}

    ends = {}
    ends["done"] = frame(Pose(lens="green", screen="done"),
                         lambda c, pts: None if name == "Console" else check_badge(c, 64, 36))
    ends["failed"] = frame(Pose(lens="red", dim=True, bob=1, screen="failed"),
                           lambda c, pts: None if name == "Console" else cross_badge(c, 64, 36))
    ends["cheer"] = [frame(Pose(bob=h, screen="done"), (lambda c, pts: sparkles(c, *pts["mast"], 3, "4")) if h < -2 else None)
                     for h in (0, -4, -6, -2)]
    ends["droop"] = [frame(Pose(bob=h, lean=l, lens=ln, screen="failed")) for h, l, ln in ((0, 0, "on"), (1, 5, "off"), (2, 8, "red"))]
    ends["asleep"] = [frame(Pose(lens="off", dim=True, bob=1, screen="sleep"),
                            lambda c, pts, k=k: zees(c, min(62, pts["mast"][0] + 6), max(10, pts["mast"][1] + 4), k + 1))
                      for k in range(3)]
    ends["idle"] = [frame(Pose()), frame(Pose()), frame(Pose(lens="off")), frame(Pose())]
    ends["flinch"] = [frame(Pose(lean=-8, bob=-1)), frame(Pose(lean=8, bob=0))]
    ends["wave"] = [frame(Pose(lens="amber", screen="wave", bob=b), lambda c, pts, b=b: exclaim(c, 66, 16, b))
                    for b in (0, -2, 0)]
    ends["noticed"] = [frame(Pose(bob=-3, lens="amber")), frame(Pose(bob=-1)), frame(Pose())]
    return {"name": name, "loops": loops, "ends": ends}


def field_lead():
    """The Carrier: a long hauler; with n helpers, n bays light and n small
    drones circle it."""
    def carrier(c, lit, beacon, lift=0.0):
        y = 30 + lift
        c.fill(rect(16, y, 80, 16, 6), MAIN[8])
        c.fill(rect(16, y, 80, 4.5, 3), LIGHT[8])
        c.fill(rect(70, y - 8, 20, 10, 4), SHADE[8])
        c.fill(rect(76, y - 5, 11, 3.4, 1.7), "7")
        for k in range(3):
            c.fill(rect(24 + k * 14, y + 7, 9, 5, 1.5), "4" if k < lit else "0")
        c.fill(rect(19, y + 16, 22, 4, 2) | rect(69, y + 16, 22, 4, 2), "5")
        c.fill(seg(30, y, 30, y - 9, 1.6), "5")
        c.fill(circle(30, y - 10, 2.2), "3" if beacon else SHADE[0])

    def drone(c, x, y, i, k):
        c.fill(rect(x - 6, y - 3, 12, 1.8, 0.9), "8" if k % 2 else "5")
        c.fill(ellipse(x, y + 1, 4.5, 3), MAIN[i])
        c.fill(circle(x + 1.5, y + 1.2, 1.2), "7")

    def level(n):
        frames = []
        for k in range(8):
            c = Canvas(LW, LH)
            carrier(c, n, k % 4 < 2)
            for j in range(n):
                a = 2 * math.pi * (k / 8 + j / n)
                drone(c, 56 + 46 * math.cos(a), 9 + 4 * math.sin(a), [0, 2, 6][j], k)
            frames.append(c.rows())
        return frames

    rest = []
    for k in range(4):
        c = Canvas(LW, LH)
        carrier(c, 0, k == 0)
        rest.append(c.rows())
    rising = []
    for lift in (-2, -4, -1):
        c = Canvas(LW, LH)
        carrier(c, 3, True, lift)
        rising.append(c.rows())
    return {"rest": rest, "rising": rising, "levels": [level(1), level(2), level(3)]}


# --------------------------------------------------------------------------
# Sounds: short synthesised clips. Kinetic Marks rings soft mallet tones;
# Field Units speaks in servo chirps and square-wave beeps.

RATE = 22050


def write_wav(file, samples):
    file.parent.mkdir(parents=True, exist_ok=True)
    peak = max(1e-6, max(abs(s) for s in samples))
    with wave.open(str(file), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(32767 * 0.6 * s / peak)) for s in samples))


def mallet(freqs, dur=0.42, gap=0.09):
    out = []
    for n, f in enumerate(freqs):
        start = n * gap
        for i in range(int((start + dur) * RATE)):
            t = i / RATE - start
            if len(out) <= i:
                out.append(0.0)
            if t < 0:
                continue
            env = math.exp(-t * 9) * min(1, t * 400)
            out[i] += env * (math.sin(2 * math.pi * f * t) + 0.25 * math.sin(4 * math.pi * f * t))
    return out


def beeps(freqs, step=0.07, slide=0.0, duty=0.5):
    out = []
    for n, f in enumerate(freqs):
        for i in range(int(step * RATE)):
            t = i / RATE
            ff = f * (1 + slide * t / step)
            phase = (ff * t) % 1
            env = min(1, t * 300) * min(1, (step - t) * 300) * 0.7
            out.append(env * (1 if phase < duty else -1) * 0.5 + env * 0.5 * math.sin(2 * math.pi * ff * t))
        out.extend([0.0] * int(0.012 * RATE))
    return out


PENTA = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66, 1318.5, 1567.98, 1760.0, 2093.0, 2349.3]


def kinetic_sounds(folder, names):
    voices = {"spawn": [], "done": {}}
    for k, notes in enumerate(([0, 3], [1, 4])):
        rel = f"tones/spawn-{k + 1}.wav"
        write_wav(folder / rel, mallet([PENTA[n] for n in notes], 0.3, 0.07))
        voices["spawn"].append(rel)
    for i, name in enumerate(names):
        rel = f"tones/{name.lower()}.wav"
        write_wav(folder / rel, mallet([PENTA[i] * 0.5, PENTA[i]], 0.45, 0.08))
        voices["done"][name] = [rel]
    write_wav(folder / "resolve.wav", mallet([523.25, 659.25, 783.99, 1046.5], 0.6, 0.08))
    write_wav(folder / "falter.wav", mallet([392.0, 329.63], 0.5, 0.14))
    write_wav(folder / "attention.wav", mallet([880.0, 1174.66, 880.0, 1174.66], 0.25, 0.11))
    return voices, {"quack": "resolve.wav", "honk": "falter.wav", "chirp": "attention.wav"}


def field_sounds(folder, names):
    voices = {"spawn": [], "done": {}}
    for k, fs in enumerate(([400, 600, 900], [500, 750, 1100])):
        rel = f"servo/spawn-{k + 1}.wav"
        write_wav(folder / rel, beeps(fs, 0.05, 0.3))
        voices["spawn"].append(rel)
    for i, name in enumerate(names):
        rel = f"servo/{name.lower()}.wav"
        base = 300 + i * 70
        pattern = [base, base * 1.5, base * 2] if i % 3 == 0 else [base * 2, base] if i % 3 == 1 else [base, base * 2, base * 1.25, base * 2]
        write_wav(folder / rel, beeps(pattern, 0.06, 0.15 if i % 2 else -0.1, 0.3 + 0.05 * (i % 4)))
        voices["done"][name] = [rel]
    write_wav(folder / "complete.wav", beeps([660, 880, 1320], 0.08, 0.0))
    write_wav(folder / "fault.wav", beeps([300, 200], 0.14, -0.3, 0.5))
    write_wav(folder / "request.wav", beeps([1000, 0.1, 1000], 0.06, 0.0, 0.25))
    return voices, {"quack": "complete.wav", "honk": "fault.wav", "chirp": "request.wav"}


# --------------------------------------------------------------------------

def trim_lead(lead):
    """Store lead frames trimmed, as the format allows: each row stops at its
    last coloured pixel and a frame at its last coloured row. Keeps the set
    under the parser's 3,000,000-character cap."""
    def trim(frame):
        rows = [r.rstrip(".") for r in frame]
        while rows and not rows[-1]:
            rows.pop()
        return rows
    return {key: [trim(f) for f in value] if key != "levels" else [[trim(f) for f in level] for level in value]
            for key, value in lead.items()}


def emit(pack_id, title, members, member_fn, lead_fn, sounds_fn):
    folder = PACKS / pack_id
    folder.mkdir(parents=True, exist_ok=True)
    names = [n for n, _ in members]
    voices, sounds = sounds_fn(folder, names)
    theme = {
        "duckherdTheme": 1,
        "id": pack_id,
        "title": title,
        "scale": 4,
        "palette": palette_for(members),
        "helpers": [member_fn(i, n) for i, n in enumerate(names)],
        "lead": trim_lead(lead_fn()),
        "voices": voices,
        "sounds": sounds,
    }
    text = json.dumps(theme, separators=(",", ":"))
    assert len(text) < 2_900_000, f"{pack_id}: {len(text)} characters, near the parser's 3,000,000 cap"
    (folder / "theme.json").write_text(text)
    print(f"{pack_id}: {len(names)} members")


def main():
    emit("kinetic-marks", "Kinetic Marks", KINETIC, kinetic_member, kinetic_lead, kinetic_sounds)
    emit("field-units", "Field Units", FIELD, field_member, field_lead, field_sounds)


if __name__ == "__main__":
    main()
