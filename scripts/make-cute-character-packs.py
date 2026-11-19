#!/usr/bin/env python3
"""Draw the two cute built-in character packs, Burrow Buddies and Lunchbox Pals.

Every character is original art, drawn here from shapes on a 40 x 24 grid and
written doubled (scale 4, 80 x 48 frames), so one grid pixel is one device pixel
in the sidebar on a Retina display. Each character is a list of filled shapes
(body, ears, tail, details); the script outlines them, shades them, poses them
(squash, lean, bounce, feet, arms, eyes) and adds the props a state needs
(laptop, book, magnifier, thought bubble, sparkles, Zz). The sounds are
synthesised here too, so the packs carry nothing they did not make.

    python3 scripts/make-cute-character-packs.py            # write both packs
    python3 scripts/make-cute-character-packs.py --sheets DIR --scales 1,3
                                                           # also contact sheets

Then run scripts/make-character-pack-cards.py to refresh cards and the manifest.
"""
import json
import math
import pathlib
import random
import struct
import sys
import wave
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKS = ROOT / "Sources/ContinuumRevivedCharacterPacks/Resources/packs"

W, H = 40, 24          # the design grid; written doubled
G = 23                 # ground row: the lowest row a foot touches
CX = 16                # body centre column (props sit to its right)

# ---------------------------------------------------------------- palette

# Letters every character shares. Per-character letters are w x y z u v t:
# highlight, main, shade, outline, accent, second accent, third accent.
SHARED = {
    "k": "#221C2B",  # eyes, ink
    "W": "#FFFFFF",  # eye glint, teeth, paper white
    "p": "#FF8FAB",  # blush
    "L": "#D3D8E2",  # laptop lid
    "l": "#9AA1B1",  # laptop lid shade
    "m": "#4A4F5E",  # prop outline
    "g": "#7FE8FF",  # screen glow
    "B": "#F2726B",  # book cover
    "b": "#B9483F",  # book cover shade
    "P": "#FFF8E6",  # paper
    "q": "#C9BDA2",  # paper lines
    "R": "#5B6F96",  # magnifier rim
    "r": "#CDEFFF",  # lens
    "h": "#9A6A3E",  # magnifier handle
    "s": "#FFD23F",  # sparkle
    "S": "#FFF7C2",  # sparkle core
    "Z": "#8DB3FF",  # sleep Z
    "d": "#E3DACB",  # dust
    "D": "#BDB2A0",  # dust shade
    "e": "#73C8FF",  # sweat drop
    "E": "#FF5266",  # exclamation
    "o": "#FFFFFF",  # thought bubble
    "O": "#A3ABBD",  # thought bubble outline
    "n": "#7A5CFF",  # question mark
}


def shade_set(main, shade, light, outline, accent, accent2, accent3=None):
    out = {"w": light, "x": main, "y": shade, "z": outline, "u": accent, "v": accent2}
    if accent3:
        out["t"] = accent3
    return out


# ---------------------------------------------------------------- geometry

class Pose:
    def __init__(self, **kw):
        self.ox = 0         # shift right
        self.oy = 0         # shift down (negative = up)
        self.sq = 0         # squash: + shorter and wider, - taller and narrower
        self.lean = 0       # shear: + leans the top forward (right)
        self.ear = 0        # ear sway: + back (left), - forward
        self.eyes = "open"  # open blink happy closed x wide up left right sad
        self.mouth = "smile"  # smile open o flat frown none
        self.arms = "down"  # down type0 type1 up wave0 wave1 hold glass none
        self.feet = None    # run phase 0..5, or None standing
        self.blush = True
        self.tail = 0       # tail wag phase
        for key, value in kw.items():
            setattr(self, key, value)

    def clone(self, **kw):
        p = Pose(**self.__dict__)
        for key, value in kw.items():
            setattr(p, key, value)
        return p


class Frame:
    """A 40 x 24 grid of palette letters (None is clear)."""

    def __init__(self):
        self.px = [[None] * W for _ in range(H)]

    def get(self, x, y):
        return self.px[y][x] if 0 <= x < W and 0 <= y < H else None

    def put(self, x, y, k):
        if 0 <= x < W and 0 <= y < H:
            self.px[y][x] = k

    def rows(self):
        return ["".join(c or "." for c in row) for row in self.px]

    def doubled(self):
        out = []
        for row in self.rows():
            wide = "".join(c * 2 for c in row)
            out += [wide, wide]
        return out


class Shape:
    """A filled region in model space: a set of pixels with letters, outlined
    as one piece when stamped."""

    def __init__(self, pose):
        self.pose = pose
        self.cells = {}

    # Model space -> frame space for the pose.
    def tx(self, x, y):
        p = self.pose
        sx = 1 + 0.07 * p.sq
        sy = 1 - (0.09 if p.sq > 0 else 0.05) * p.sq
        nx = CX + (x - CX) * sx + p.lean * (G + 1 - y) / 12.0 + p.ox
        ny = (G + 1) - ((G + 1) - y) * sy + p.oy
        return nx, ny

    def scale(self):
        p = self.pose
        return 1 + 0.07 * p.sq, 1 - (0.09 if p.sq > 0 else 0.05) * p.sq

    def ell(self, cx, cy, rx, ry, k="x", shade=True, light=True):
        (fx, fy), (sx, sy) = self.tx(cx, cy), self.scale()
        rx, ry = rx * sx, ry * sy
        for y in range(int(fy - ry) - 1, int(fy + ry) + 2):
            for x in range(int(fx - rx) - 1, int(fx + rx) + 2):
                nx, ny = (x + 0.5 - fx) / rx, (y + 0.5 - fy) / ry
                d = nx * nx + ny * ny
                if d > 1.0:
                    continue
                key = k
                if shade and k == "x" and 0.5 * nx + 0.85 * ny > 0.52:
                    key = "y"
                if light and k == "x" and (nx + 0.42) ** 2 + (ny + 0.5) ** 2 < 0.05:
                    key = "w"
                self.cells[(x, y)] = key
        return self

    def poly(self, pts, k="x", shade_below=None):
        pts = [self.tx(x, y) for x, y in pts]
        ys = [y for _, y in pts]
        for y in range(int(min(ys)) - 1, int(max(ys)) + 2):
            cy = y + 0.5
            xs = []
            for i in range(len(pts)):
                (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
                if (y0 <= cy < y1) or (y1 <= cy < y0):
                    xs.append(x0 + (cy - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for a, b in zip(xs[0::2], xs[1::2]):
                for x in range(int(math.floor(a + 0.5)), int(math.floor(b + 0.5))):
                    key = k
                    if shade_below is not None and y >= shade_below + self.pose.oy and k == "x":
                        key = "y"
                    self.cells[(x, y)] = key
        return self

    def rect(self, x0, y0, x1, y1, k="x"):
        return self.poly([(x0, y0), (x1 + 1, y0), (x1 + 1, y1 + 1), (x0, y1 + 1)], k)

    def dot(self, x, y, k):
        fx, fy = self.tx(x + 0.5, y + 0.5)
        self.cells[(int(math.floor(fx)), int(math.floor(fy)))] = k
        return self


def stamp(frame, shape, outline="z"):
    """Outline a shape (4-neighbours) over what is already drawn, then fill it."""
    cells = shape.cells
    if outline:
        for (x, y) in cells:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = (x + dx, y + dy)
                if n not in cells:
                    frame.put(n[0], n[1], outline)
    for (x, y), k in cells.items():
        frame.put(x, y, k)


def paint(frame, shape):
    """Fill without an outline: details inside a body (belly, patterns)."""
    for (x, y), k in shape.cells.items():
        if frame.get(x, y) not in (None, "z"):
            frame.put(x, y, k)


# ---------------------------------------------------------------- the rig

class Rig:
    """What a character tells the shared poser: where its face, arms and feet go."""

    def __init__(self, eyes, mouth, arms, feet, foot="y", arm="x", eye_gap=None, cheeks=None):
        self.eyes = eyes      # ((lx, ly), (rx, ry)) model space, top-left of a 2x2 eye
        self.mouth = mouth    # (x, y) model space, centre
        self.arms = arms      # ((lx, ly), (rx, ry)) shoulder points, or None
        self.feet = feet      # (lx, rx) model x of each foot, or None
        self.foot = foot
        self.arm = arm
        self.cheeks = cheeks  # ((lx, ly), (rx, ry)) or None


def draw_feet(frame, pose, rig):
    if rig.feet is None:
        return
    lx, rx = rig.feet
    if pose.feet is None:
        offs = [(0, 0), (0, 0)]
    else:
        # A six-step run: each foot sweeps back along the ground and lifts on the way forward.
        cycle = [(3, 0), (1, 0), (-2, 0), (-3, -1), (-1, -2), (2, -1)]
        offs = [cycle[pose.feet % 6], cycle[(pose.feet + 3) % 6]]
    for (fx, (dx, dy)) in zip((lx, rx), offs):
        # Running, the feet stay near the ground while the body bobs, so the
        # stride shows below it.
        s = Shape(pose.clone(sq=0, lean=0, oy=pose.oy if pose.feet is None else pose.oy // 2))
        s.ell(fx + dx + 0.5, G - 0.5 + dy, 1.9, 1.2, rig.foot, shade=False, light=False)
        stamp(frame, s)


def arm_points(pose, rig):
    """Where each hand goes for the pose, model space, or None to hide it."""
    if rig.arms is None or pose.arms == "none":
        return []
    (lx, ly), (rx, ry) = rig.arms
    a = pose.arms
    if a == "down":
        return [(lx - 0.5, ly + 1), (rx + 0.5, ry + 1)]
    if a in ("type0", "type1"):
        up = 1 if a == "type0" else 0
        return [(lx + 2.5, G - 5 - up), (rx - 2.5, G - 6 + up)]
    if a == "up":
        return [(lx - 2, ly - 5), (rx + 2, ry - 5)]
    if a in ("wave0", "wave1"):
        swing = 0 if a == "wave0" else 1.5
        return [(lx - 0.5, ly + 1), (rx + 2.5 + swing, ry - 5)]
    if a == "hold":
        return [(lx + 1.5, G - 5), (rx - 1.5, G - 5)]
    if a == "glass":
        return [(lx - 0.5, ly + 1), (rx + 2.5, ry)]
    return []


def draw_arms(frame, pose, rig):
    for (hx, hy) in arm_points(pose, rig):
        s = Shape(pose)
        s.ell(hx, hy, 1.5, 1.4, rig.arm, shade=False, light=False)
        stamp(frame, s)


EYE_ART = {
    # 2 x 2 eyes; each list is (dx, dy, letter) from the eye's top-left.
    "open": [(0, 0, "W"), (1, 0, "k"), (0, 1, "k"), (1, 1, "k")],
    "left": [(0, 0, "k"), (1, 0, "W"), (0, 1, "k"), (1, 1, "k")],
    "right": [(0, 0, "W"), (1, 0, "k"), (0, 1, "k"), (1, 1, "k")],
    "up": [(0, 0, "k"), (1, 0, "k")],
    "wide": [(0, -1, "k"), (1, -1, "k"), (0, 0, "W"), (1, 0, "k"), (0, 1, "k"), (1, 1, "k")],
    "blink": [(0, 1, "k"), (1, 1, "k")],
    "closed": [(0, 1, "k"), (1, 1, "k")],
    "happy": [(-1, 1, "k"), (0, 0, "k"), (1, 0, "k"), (2, 1, "k")],
    "sad": [(0, 0, "k"), (1, 1, "k"), (0, 1, "k")],
    "x": [(0, 0, "k"), (1, 1, "k"), (1, 0, "k"), (0, 1, "k")],
}


def draw_face(frame, pose, rig):
    shape = Shape(pose)
    eye = pose.eyes
    for i, (ex, ey) in enumerate(rig.eyes):
        art = EYE_ART[eye]
        if eye == "sad" and i == 1:
            art = [(1, 0, "k"), (0, 1, "k"), (1, 1, "k")]
        if eye == "x":
            art = [(0, 0, "k"), (1, 1, "k")] if True else art
            art = [(0, 0, "k"), (1, 1, "k"), (1, 0, "W"), (0, 1, "W")]
        fx, fy = shape.tx(ex, ey)
        fx, fy = int(math.floor(fx + 0.5)), int(math.floor(fy + 0.5))
        for dx, dy, k in art:
            if k == "W" and eye == "x":
                continue
            frame.put(fx + dx, fy + dy, k)
        if eye == "x":
            frame.put(fx + 1, fy, "k")
            frame.put(fx, fy + 1, "k")
    if pose.blush and rig.cheeks:
        for (cx, cy) in rig.cheeks:
            fx, fy = shape.tx(cx, cy)
            fx, fy = int(math.floor(fx + 0.5)), int(math.floor(fy + 0.5))
            for dx in (0, 1):
                if frame.get(fx + dx, fy) not in (None, "z", "k"):
                    frame.put(fx + dx, fy, "p")
    mx, my = shape.tx(*rig.mouth)
    mx, my = int(math.floor(mx)), int(math.floor(my))
    m = pose.mouth
    if m == "smile":
        frame.put(mx, my, "k")
    elif m == "open":
        frame.put(mx, my, "k")
        frame.put(mx, my + 1, "E")
    elif m == "o":
        frame.put(mx, my, "k")
        frame.put(mx, my + 1, "k")
    elif m == "flat":
        frame.put(mx - 1, my, "k")
        frame.put(mx, my, "k")
    elif m == "frown":
        frame.put(mx, my, "k")
        frame.put(mx - 1, my + 1, "k")
        frame.put(mx + 1, my + 1, "k")


def build(char, pose):
    """One frame of a character in a pose, before props."""
    f = Frame()
    rig = char.rig
    if char.back:
        for s in char.back(pose):
            stamp(f, s)
    if pose.feet is None:
        draw_feet(f, pose, rig)
    for s in char.body(pose):
        if isinstance(s, tuple):
            paint(f, s[1])
        else:
            stamp(f, s)
    if pose.feet is not None:
        draw_feet(f, pose, rig)
    draw_face(f, pose, rig)
    return f


# ---------------------------------------------------------------- props

def sprite(frame, x, y, art, mapping):
    for dy, row in enumerate(art):
        for dx, c in enumerate(row):
            if c != "." and c != " ":
                frame.put(x + dx, y + dy, mapping.get(c, c))


LAPTOP = [
    ".mmmmmmmmmm.",
    "mLLLLlLLLLLm",
    "mLLLlllLLLLm",
    "mLLLLlLLLLLm",
    "mLLLLLLLLLLm",
    "mmmmmmmmmmmm",
]
BOOK = [
    "mmmmmm.mmmmmm",
    "mPqqqPmPqqqPm",
    "mPPPPPmPPPPPm",
    "mPqqqPmPqqPPm",
    "mBBBBBBBBBBBm",
    ".mmmmmmmmmmm.",
]
BOOK_FLIP = [
    "mmmmmm.......",
    "mPqqqPmmmmmm.",
    "mPPPPPmPqqqPm",
    "mPqqqPmPPPPPm",
    "mBBBBBBBBBBBm",
    ".mmmmmmmmmmm.",
]
GLASS = [
    ".RRR..",
    "RrrrR.",
    "RrWrR.",
    "RrrrR.",
    ".RRRh.",
    "....hh",
]
SPARK = [".S.", "SsS", ".S."]
SPARK_BIG = ["..s..", ".sSs.", "sSSSs", ".sSs.", "..s.."]
Z_SMALL = ["ZZ", ".Z", "ZZ"]
Z_BIG = ["ZZZ", "..Z", ".Z.", "Z..", "ZZZ"]
BANG = ["E", "E", "E", ".", "E"]
QUESTION = [".nn.", "n..n", "..n.", "....", "..n."]
SWEAT = [".e", "ee", "ee"]
DUST = [".d.", "dDd"]
DUST_SMALL = ["d"]


def thought(frame, step, x=27, y=0):
    """Dots rise to a bubble; the last step shows a lit idea in it."""
    if step >= 1:
        frame.put(x - 3, y + 10, "O")
    if step >= 2:
        sprite(frame, x - 1, y + 7, ["OO", "OO"], {})
    if step >= 3:
        sprite(frame, x, y, [
            ".OOOOOOOO.",
            "OooooooooO",
            "OooooooooO",
            "OooooooooO",
            "OooooooooO",
            ".OOOOOOOO.",
        ], {})
        if step == 3:
            for i in range(3):
                frame.put(x + 2 + i * 2, y + 3, "k")
        else:
            sprite(frame, x + 3, y + 1, [".ss.", "sSSs", ".ss.", ".mm."], {})


def apply_props(frame, char, pose, props, step=0):
    rig = char.rig
    probe = Shape(pose)
    for prop in props:
        if prop == "laptop":
            sprite(frame, CX - 6 + pose.ox, G - 6, LAPTOP, {})
            # The arms tap on the lid's top edge, drawn over it.
            draw_arms(frame, pose, rig)
            if step % 2 == 0:
                frame.put(CX + 7, G - 8, "g")
            else:
                frame.put(CX + 9, G - 9, "g")
        elif prop in ("book", "bookflip"):
            sprite(frame, CX - 6 + pose.ox, G - 5, BOOK if prop == "book" else BOOK_FLIP, {})
            draw_arms(frame, pose, rig)
        elif prop == "glass":
            (rx, ry) = rig.arms[1] if rig.arms else (CX + 6, G - 9)
            hx, hy = probe.tx(rx + 2.5, ry)
            sprite(frame, int(hx) - 1 + step, int(hy) - 6 + (step % 2), GLASS, {})
        elif prop.startswith("think"):
            thought(frame, int(prop[5:]))
        elif prop.startswith("spark"):
            n = int(prop[5:] or 0)
            spots = [(27, 4), (5, 6), (30, 12), (24, 1)]
            sx, sy = spots[n % len(spots)]
            sprite(frame, sx, sy, SPARK_BIG if n % 2 == 0 else SPARK, {})
        elif prop.startswith("z"):
            n = int(prop[1:])
            sprite(frame, 24 + n, 8 - n * 2, Z_SMALL if n % 2 == 0 else Z_BIG, {})
            if n >= 1:
                sprite(frame, 29 + n, 2 - (n - 1), Z_SMALL, {})
        elif prop == "bang":
            sprite(frame, 25, 2, BANG, {})
        elif prop == "bang2":
            sprite(frame, 25, 1, BANG, {})
            sprite(frame, 27, 2, BANG, {})
        elif prop == "question":
            sprite(frame, 25, 1, QUESTION, {})
        elif prop.startswith("sweat"):
            n = int(prop[5:] or 0)
            sprite(frame, 23, 6 + n, SWEAT, {})
        elif prop.startswith("dust"):
            n = int(prop[4:])
            bx = CX - 10 + pose.ox
            if n == 0:
                sprite(frame, bx, G - 1, DUST, {})
            elif n == 1:
                sprite(frame, bx - 2, G - 2, DUST_SMALL, {})
                frame.put(bx - 1, G - 1, "d")
        elif prop.startswith("lines"):
            n = int(prop[5:])
            for i, (lx, ly) in enumerate([(CX - 12, 12), (CX - 13, 16), (CX - 11, 19)]):
                if (i + n) % 3 != 2:
                    for dx in range(3):
                        frame.put(lx - n % 2 + dx + pose.ox, ly + pose.oy, "D")


# ---------------------------------------------------------------- animation

def frames_for(char):
    """Every loop and end clip for a character, as 40 x 24 frames."""
    base = Pose()

    def f(pose, props=(), step=0):
        fr = build(char, pose)
        if pose.arms not in ("type0", "type1", "hold") or not any(p in props for p in ("laptop", "book", "bookflip")):
            draw_arms(fr, pose, char.rig)
        apply_props(fr, char, pose, props, step)
        return fr

    run = []
    bob = [0, -1, -2, -1, 0, -1]
    for i in range(6):
        run.append(f(base.clone(lean=2, oy=bob[i], sq=1 if i in (0, 3) else (-1 if i in (1, 4) else 0),
                                feet=i, ear=1, arms="none", mouth="open" if i % 3 == 1 else "smile",
                                tail=i),
                     ["lines%d" % (i % 3), "dust%d" % (0 if i in (0, 3) else 1)] if i in (0, 1, 3, 4) else ["lines%d" % (i % 3)]))
    type_ = [f(base.clone(arms="type%d" % (i % 2), eyes="open" if i != 2 else "right", oy=0 if i % 2 else 0,
                          mouth="smile", sq=1 if i % 2 else 0), ["laptop"], i) for i in range(4)]
    read = [f(base.clone(arms="hold", eyes=["left", "left", "right", "right"][i],
                         mouth="o" if i == 3 else "smile"), ["book" if i != 2 else "bookflip"]) for i in range(4)]
    dabble = [f(base.clone(arms="glass", eyes="right", lean=1 if i % 2 else 0, mouth="o" if i == 1 else "smile",
                           tail=i), ["glass"], [0, 1, 2, 1][i]) for i in range(4)]
    think = [f(base.clone(eyes="up", mouth="flat" if i < 3 else "smile", lean=-1 if i in (1, 2) else 0),
               ["think%d" % (i + 1)]) for i in range(4)]
    loops = {
        "dabble": (220, dabble),
        "read": (320, read),
        "type": (120, type_),
        "run": (90, run),
        "think": (380, think),
    }
    done = f(base.clone(eyes="happy", mouth="open", arms="up"), ["spark0"])
    failed = f(base.clone(eyes="x", mouth="frown", sq=1, ear=1, blush=False), ["sweat0"])
    ends = {
        "cheer": [
            f(base.clone(sq=2, eyes="happy", arms="down", mouth="smile")),
            f(base.clone(oy=-2, eyes="happy", arms="up", mouth="open"), ["spark0"]),
            f(base.clone(oy=-1, eyes="happy", arms="up", mouth="open"), ["spark1", "spark2"]),
            f(base.clone(sq=1, eyes="happy", arms="up", mouth="smile"), ["spark3"]),
        ],
        "droop": [
            f(base.clone(eyes="sad", mouth="flat")),
            f(base.clone(eyes="sad", mouth="frown", sq=1, ear=1), ["sweat0"]),
            f(base.clone(eyes="closed", mouth="frown", sq=2, ear=1, blush=False), ["sweat1"]),
        ],
        "asleep": [
            f(base.clone(eyes="closed", mouth="flat", sq=1, arms="down"), ["z0"]),
            f(base.clone(eyes="closed", mouth="o", sq=0, arms="down"), ["z1"]),
            f(base.clone(eyes="closed", mouth="flat", sq=1, arms="down"), ["z2"]),
        ],
        "idle": [
            f(base),
            f(base.clone(sq=1)),
            f(base.clone(eyes="blink")),
            f(base.clone(tail=1)),
        ],
        "idleMove": [
            f(base.clone(oy=-1, ox=-1)),
            f(base.clone(oy=-1, ox=1)),
            f(base.clone(sq=1)),
        ],
        "flinch": [
            f(base.clone(ox=0, lean=-2, eyes="wide", mouth="o", arms="up", blush=False), ["bang"]),
            f(base.clone(ox=-1, lean=-1, eyes="sad", mouth="flat"), ["sweat0"]),
        ],
        "wave": [
            f(base.clone(arms="wave0", eyes="open", mouth="open"), ["question"]),
            f(base.clone(arms="wave1", eyes="happy", mouth="smile", oy=-1), ["question"]),
            f(base.clone(arms="wave0", eyes="open", mouth="smile"), ["question"]),
        ],
        "noticed": [
            f(base.clone(eyes="wide", mouth="o", sq=1), ["bang"]),
            f(base.clone(eyes="wide", mouth="open", oy=-1, sq=-1, arms="up"), ["bang2"]),
            f(base.clone(eyes="happy", mouth="smile")),
        ],
    }
    return loops, done, failed, ends


# ---------------------------------------------------------------- characters

class Char:
    def __init__(self, name, colors, rig, body, back=None, voice=None):
        self.name, self.colors, self.rig, self.body, self.back = name, colors, rig, body, back
        self.voice = voice or {}


def S(pose):
    return Shape(pose)


def blob(p, rx=7.5, ry=6.5, cy=None):
    cy = G - 1 - ry + 0.5 if cy is None else cy
    return S(p).ell(CX, cy, rx, ry)


def belly(p, rx=4, ry=3.2, cy=G - 4.5, k="u"):
    return ("paint", S(p).ell(CX, cy, rx, ry, k, shade=False, light=False))


STD_RIG = Rig(eyes=((CX - 4, G - 10), (CX + 2, G - 10)), mouth=(CX, G - 7.5),
              arms=((CX - 7, G - 6), (CX + 7, G - 6)), feet=(CX - 4, CX + 3),
              cheeks=((CX - 6, G - 8), (CX + 4, G - 8)))


def rig(**kw):
    r = Rig(STD_RIG.eyes, STD_RIG.mouth, STD_RIG.arms, STD_RIG.feet, cheeks=STD_RIG.cheeks)
    for k, v in kw.items():
        setattr(r, k, v)
    return r


def ears_point(p, dx=4.5, top=6, k="x", inner="u", w=2.5):
    out = []
    for side in (-1, 1):
        x = CX + side * dx - p.ear * (1 if side > 0 else 0.5)
        s = S(p).poly([(x - w, G - 9), (x + side * 0.5 - p.ear * 0.6, top), (x + w, G - 9)], k)
        s.poly([(x - w + 1.2, G - 9.5), (x + side * 0.4 - p.ear * 0.6, top + 2.2), (x + w - 1.2, G - 9.5)], inner)
        out.append(s)
    return out


def ears_round(p, dx=5.5, cy=G - 12, r=2.4, k="x", inner="u"):
    out = []
    for side in (-1, 1):
        s = S(p).ell(CX + side * dx - p.ear * 0.4, cy, r, r, k, shade=False)
        s.ell(CX + side * dx - p.ear * 0.4, cy + 0.3, r - 1.1, r - 1.1, inner, shade=False, light=False)
        out.append(s)
    return out


# ---- Burrow Buddies -------------------------------------------------------

def bunny_back(p):
    return []


def bunny(p):
    parts = []
    for side, tilt in ((-1, -1.0), (1, 0.6)):
        x = CX + side * 2.6 - p.ear * 1.2
        s = S(p).poly([(x - 1.6, G - 10), (x - 1.6 + tilt * 0.4 - p.ear, 5.2), (x + tilt * 0.4 - p.ear, 3.6),
                       (x + 1.6 + tilt * 0.4 - p.ear, 5.2), (x + 1.6, G - 10)], "x")
        s.poly([(x - 0.6, G - 10.5), (x - 0.5 + tilt * 0.4 - p.ear, 5.0), (x + 0.6 + tilt * 0.4 - p.ear, 5.0),
                (x + 0.6, G - 10.5)], "u")
        parts.append(s)
    parts.append(blob(p, 7, 6.5))
    parts.append(belly(p, 3.4, 2.6, k="v"))
    return parts


def fox_back(p):
    sway = [0, 1, 0, -1, 0, 1][p.tail % 6]
    s = S(p).ell(CX - 8.5, G - 5 + sway * 0.5, 3.6, 2.6, "x", shade=False)
    s.ell(CX - 11, G - 6 + sway * 0.5, 1.6, 1.6, "u", shade=False, light=False)
    return [s]


def fox(p):
    parts = ears_point(p, dx=4.2, top=7, inner="t")
    parts.append(blob(p, 7.5, 6.3))
    # A pale muzzle from the cheeks down.
    parts.append(("paint", S(p).poly([(CX - 5, G - 8), (CX + 5, G - 8), (CX + 2, G - 2), (CX - 2, G - 2)], "u")))
    return parts


def mouse_back(p):
    s = S(p)
    wag = p.tail % 2
    for i, (x, y) in enumerate([(CX - 8, G - 2), (CX - 9.5, G - 3), (CX - 10.5, G - 4.5 - wag), (CX - 11, G - 6 - wag)]):
        s.dot(x, y, "t")
    return [s]


def mouse(p):
    parts = ears_round(p, dx=5.6, cy=G - 12.5, r=3.4)
    parts.append(blob(p, 6.8, 6.2))
    parts.append(("paint", S(p).ell(CX, G - 6.8, 1, 0.8, "t", shade=False, light=False)))
    return parts


def bear(p):
    parts = ears_round(p, dx=5.3, cy=G - 12, r=2.4)
    parts.append(blob(p, 7.8, 6.8))
    parts.append(("paint", S(p).ell(CX, G - 6.6, 2.6, 1.8, "u", shade=False, light=False)))
    parts.append(("paint", S(p).rect(CX - 1, G - 8, CX, G - 8, "k")))
    return parts


def frog(p):
    parts = []
    for side in (-1, 1):
        s = S(p).ell(CX + side * 4.5, G - 11, 2.8, 2.4, "x", shade=False)
        parts.append(s)
    parts.append(S(p).ell(CX, G - 5.5, 8.5, 5.5))
    parts.append(belly(p, 5, 2.4, cy=G - 3, k="u"))
    return parts


def chick(p):
    parts = []
    tuft = S(p).poly([(CX - 1, G - 12), (CX - 1.5 - p.ear, G - 15.5), (CX + 0.5, G - 13), (CX + 1.8 - p.ear, G - 15),
                      (CX + 1.2, G - 12)], "x")
    parts.append(tuft)
    parts.append(S(p).ell(CX, G - 6.5, 7, 6.5))
    for side in (-1, 1):
        wing = S(p).ell(CX + side * 6.2, G - 5.5, 1.8, 2.6, "y", shade=False, light=False)
        parts.append(wing)
    beak = S(p).poly([(CX - 1.5, G - 8), (CX + 1.5, G - 8), (CX, G - 6.2)], "u")
    parts.append(("paint", beak))
    return parts


def owl(p):
    parts = []
    for side in (-1, 1):
        x = CX + side * 4.6 - p.ear * 0.5
        parts.append(S(p).poly([(x - 2.4, G - 10), (x + side * 1.6, G - 15), (x + 2.4, G - 10)], "x"))
    parts.append(S(p).ell(CX, G - 6.8, 7.6, 7))
    # Big pale eye discs, a belly, and the beak.
    face = S(p)
    face.ell(CX - 3.1, G - 9.2, 2.7, 2.6, "u", shade=False, light=False)
    face.ell(CX + 3.1, G - 9.2, 2.7, 2.6, "u", shade=False, light=False)
    face.ell(CX, G - 3.5, 4.2, 2.6, "t", shade=False, light=False)
    parts.append(("paint", face))
    parts.append(("paint", S(p).poly([(CX - 1, G - 8), (CX + 1, G - 8), (CX, G - 6.2)], "v")))
    return parts


def penguin(p):
    parts = [S(p).ell(CX, G - 7.5, 6.6, 8)]
    parts.append(("paint", S(p).ell(CX, G - 5.6, 4.6, 5.6, "u", shade=False, light=False)))
    parts.append(("paint", S(p).poly([(CX - 1.2, G - 8.8), (CX + 1.2, G - 8.8), (CX, G - 7.3)], "v")))
    return parts


def hedgehog_back(p):
    s = S(p)
    spikes = []
    for i in range(7):
        a = math.pi * (0.95 + i * 0.16)
        bx, by = CX + math.cos(a) * 7, G - 6.5 + math.sin(a) * 6.5
        tx, ty = CX + math.cos(a) * 10.5 - p.ear * 0.5, G - 6.5 + math.sin(a) * 9.8
        side = 1.4
        nx, ny = -math.sin(a) * side, math.cos(a) * side
        s.poly([(bx - nx, by - ny), (tx, ty), (bx + nx, by + ny)], "y")
    return [s]


def hedgehog(p):
    parts = [S(p).ell(CX, G - 6.5, 7.4, 6.5)]
    parts.append(("paint", S(p).ell(CX + 0.5, G - 6, 5.6, 4.6, "u", shade=False, light=False)))
    parts.append(("paint", S(p).ell(CX, G - 6.9, 1, 0.7, "k", shade=False, light=False)))
    return parts


def axolotl(p):
    parts = []
    for side in (-1, 1):
        for i, dy in enumerate((-2.2, 0, 2.2)):
            x0 = CX + side * 6.5
            sway = (p.tail % 2) * (1 if i == 1 else 0) * side * 0.5
            s = S(p).poly([(x0, G - 8.5 + dy * 0.6 - 0.8), (x0 + side * (3.6 - abs(dy) * 0.3) + sway, G - 8.5 + dy * 1.3),
                           (x0, G - 8.5 + dy * 0.6 + 0.8)], "u")
            parts.append(s)
    parts.append(S(p).ell(CX, G - 6.6, 7.2, 6.3))
    parts.append(belly(p, 3.4, 2.2, cy=G - 3.4, k="v"))
    return parts


def snail_back(p):
    # The shell rides on the back, a spiral in two tones.
    s = S(p).ell(CX - 3, G - 7.5, 6.4, 6.4, "u", shade=False)
    s.ell(CX - 3, G - 7.5, 4.0, 4.0, "v", shade=False, light=False)
    s.ell(CX - 2.5, G - 7.8, 2.0, 2.0, "u", shade=False, light=False)
    s.dot(CX - 2.5, G - 8, "v")
    return [s]


def snail(p):
    parts = []
    body = S(p).ell(CX + 2, G - 3.2, 8.2, 2.8, shade=False)
    body.ell(CX + 6, G - 7.5, 3.6, 4.4)
    parts.append(body)
    for dx in (-1, 1.6):
        stalk = S(p).rect(CX + 6 + dx, G - 14, CX + 6 + dx, G - 11, "x")
        stalk.ell(CX + 6.5 + dx, G - 14.2, 1.1, 1.1, "x", shade=False, light=False)
        parts.append(stalk)
    return parts


def cat_back(p):
    s = S(p)
    wag = [0, 1, 1, 0][p.tail % 4]
    for i in range(6):
        s.ell(CX - 7.5 - i * 0.6 - wag * (i / 5), G - 3 - i * 1.6, 1.1, 1.1, "x", shade=False, light=False)
    s.ell(CX - 11 - wag, G - 12, 1.2, 1.2, "u", shade=False, light=False)
    return [s]


def cat(p):
    parts = ears_point(p, dx=4.6, top=6.5, inner="u", w=2.6)
    parts.append(blob(p, 7.6, 6.4))
    stripes = S(p)
    for x in (CX - 1, CX + 1):
        stripes.rect(x, G - 13, x, G - 12, "y")
    parts.append(("paint", stripes))
    parts.append(("paint", S(p).ell(CX, G - 3.8, 3.6, 2.4, "u", shade=False, light=False)))
    return parts


BURROW = [
    Char("Clover", shade_set("#FFF3E6", "#F1CFB5", "#FFFFFF", "#8A5A4E", "#FFB3C1", "#FFE0CC"),
         rig(cheeks=((CX - 6, G - 8), (CX + 4, G - 8)), foot="v"), bunny,
         voice={"base": 1180, "kind": "squeak"}),
    Char("Ember", shade_set("#FF8A3D", "#D9612A", "#FFC38F", "#7A2E14", "#FFF2E0", "#4A2A22", "#FFF2E0"),
         rig(foot="v", arm="x"), fox, fox_back, voice={"base": 760, "kind": "yip"}),
    Char("Marlo", shade_set("#B8B3C9", "#8F89A6", "#E4E1EE", "#4B4560", "#FFB6C9", "#FFB6C9", "#FFB6C9"),
         rig(foot="t"), mouse, mouse_back, voice={"base": 1500, "kind": "squeak"}),
    Char("Biscuit", shade_set("#D9944A", "#B06F2E", "#F4C27F", "#5E3415", "#F7D9AE", "#8A5222"),
         rig(foot="y"), bear, voice={"base": 420, "kind": "hum"}),
    Char("Juniper", shade_set("#7ED957", "#4FAE3B", "#C3F59A", "#24561D", "#E8FAC4", "#3F8F2E"),
         rig(eyes=((CX - 5.5, G - 12), (CX + 3.5, G - 12)), mouth=(CX, G - 7), arms=((CX - 8, G - 4), (CX + 8, G - 4)),
             feet=(CX - 5, CX + 4), cheeks=((CX - 7, G - 8), (CX + 5, G - 8)), foot="v"), frog,
         voice={"base": 300, "kind": "ribbit"}),
    Char("Pip", shade_set("#FFD94A", "#F0AE1E", "#FFF3A8", "#8A5A0A", "#FF8C3A", "#FF8C3A"),
         rig(arms=None, foot="v"), chick, voice={"base": 1700, "kind": "chirp"}),
    Char("Sorrel", shade_set("#6C63D9", "#4B43A8", "#A9A3F5", "#231E5C", "#F2EEFF", "#FFC23D", "#B7B0F7"),
         rig(eyes=((CX - 4, G - 10), (CX + 2, G - 10)), mouth=(CX, G - 30), arms=None, foot="v",
             cheeks=None), owl, voice={"base": 520, "kind": "hoot"}),
    Char("Frost", shade_set("#5FB8F0", "#3A8DCC", "#B3E3FF", "#173E66", "#FFFFFF", "#FF9F43"),
         rig(eyes=((CX - 3.5, G - 12), (CX + 1.5, G - 12)), mouth=(CX, G - 30), arms=((CX - 6.5, G - 7), (CX + 6.5, G - 7)),
             feet=(CX - 3, CX + 2), cheeks=((CX - 5, G - 10), (CX + 3, G - 10)), foot="v", arm="y"), penguin,
         voice={"base": 880, "kind": "honk"}),
    Char("Thistle", shade_set("#C46FD6", "#9147A8", "#E9B5F2", "#4A1E57", "#FFE3C7", "#5A2A68"),
         rig(eyes=((CX - 3, G - 9), (CX + 2, G - 9)), mouth=(CX + 1, G - 30), foot="v", arm="u",
             cheeks=((CX - 5, G - 7), (CX + 4, G - 7))), hedgehog, hedgehog_back, voice={"base": 980, "kind": "sniff"}),
    Char("Lotus", shade_set("#FF9EC4", "#E9709E", "#FFD3E4", "#7A2850", "#FF5C93", "#FFE6EF"),
         rig(foot="y", cheeks=((CX - 6, G - 8), (CX + 4, G - 8))), axolotl, voice={"base": 1320, "kind": "bubble"}),
    Char("Moss", shade_set("#F2E3B3", "#D6BF80", "#FFF8DC", "#6B5520", "#FF6B5A", "#C8392B"),
         rig(eyes=((CX + 4, G - 9), (CX + 7, G - 9)), mouth=(CX + 6.5, G - 6.5), arms=None, feet=None,
             cheeks=((CX + 3, G - 7), (CX + 8, G - 7))), snail, snail_back, voice={"base": 640, "kind": "slide"}),
    Char("Juno", shade_set("#3FC9B0", "#249C88", "#9FF0E0", "#0F4D44", "#FFF7EC", "#1E7D6E"),
         rig(foot="v"), cat, cat_back, voice={"base": 980, "kind": "mew"}),
]


# ---- Lunchbox Pals --------------------------------------------------------

def toast(p):
    s = S(p)
    crust = [(CX - 7.5, G - 1), (CX - 7.5, G - 9), (CX - 8.5, G - 12), (CX - 6, G - 14.5), (CX - 2, G - 14.8),
             (CX, G - 13.5), (CX + 2, G - 14.8), (CX + 6, G - 14.5), (CX + 8.5, G - 12), (CX + 7.5, G - 9),
             (CX + 7.5, G - 1)]
    s.poly(crust, "y")
    s.poly([(x * 0.82 + CX * 0.18, y + 0.9 if y < G - 2 else y - 0.9) for x, y in crust], "x")
    s.ell(CX - 4, G - 11, 1.2, 1.0, "w", shade=False, light=False)
    return [s]


def egg(p):
    s = S(p).poly([(CX - 9, G - 1), (CX - 10, G - 4), (CX - 8, G - 7), (CX - 4, G - 8.5), (CX + 1, G - 7.6),
                   (CX + 5, G - 9), (CX + 9, G - 7), (CX + 10, G - 3.5), (CX + 8.5, G - 1)], "u")
    s.ell(CX - 6, G - 6, 1.2, 0.8, "W", shade=False, light=False)
    yolk = S(p).ell(CX, G - 8.5, 5.4, 5)
    return [s, yolk]


def pudding(p):
    s = S(p).poly([(CX - 8, G - 0.6), (CX - 6, G - 11), (CX + 6, G - 11), (CX + 8, G - 0.6)], "x", shade_below=G - 3)
    s.ell(CX - 4.5, G - 8, 0.9, 1.6, "w", shade=False, light=False)
    top = S(p).poly([(CX - 6.4, G - 11.5), (CX - 5.5, G - 13.6), (CX + 5.5, G - 13.6), (CX + 6.4, G - 11.5),
                     (CX + 5, G - 9.5), (CX + 3.6, G - 11), (CX + 1, G - 9), (CX - 1.5, G - 11), (CX - 4, G - 9.5)], "u")
    cherry = S(p).ell(CX + 1, G - 15, 1.6, 1.6, "v", shade=False)
    return [s, top, cherry]


def riceball(p):
    s = S(p).poly([(CX - 9, G - 2), (CX - 8, G - 0.5), (CX + 8, G - 0.5), (CX + 9, G - 2), (CX + 2, G - 15),
                   (CX - 2, G - 15)], "x", shade_below=G - 2)
    band = S(p).rect(CX - 3.5, G - 4.8, CX + 3, G - 0.6, "u")
    band.rect(CX - 2.5, G - 3.5, CX - 2.5, G - 2.5, "v")
    return [s, ("paint", band)]


def donut(p):
    s = S(p).ell(CX, G - 6.5, 8.8, 6.5, "v")
    icing = S(p).ell(CX, G - 7.6, 8.2, 5.4, "x")
    icing.poly([(CX - 7.5, G - 6), (CX - 6, G - 3.5), (CX - 4.5, G - 5), (CX - 2, G - 3), (CX + 0.5, G - 5),
                (CX + 3, G - 3.5), (CX + 5, G - 5), (CX + 6.5, G - 3.5), (CX + 7.6, G - 6), (CX + 7, G - 8), (CX - 7, G - 8)], "x")
    hole = S(p).ell(CX, G - 11, 2.6, 1.1, "z", shade=False, light=False)
    sprinkles = S(p)
    for (x, y, k) in [(CX - 6, G - 9, "u"), (CX + 5, G - 10, "t"), (CX - 4, G - 11.5, "t"), (CX + 6, G - 7, "u"),
                      (CX - 7, G - 6.5, "t"), (CX + 3, G - 12, "u")]:
        sprinkles.dot(x, y, k)
    return [s, icing, ("paint", hole), ("paint", sprinkles)]


def cupcake(p):
    cup = S(p).poly([(CX - 6.5, G - 7), (CX + 6.5, G - 7), (CX + 5, G - 0.5), (CX - 5, G - 0.5)], "u")
    for x in range(-4, 5, 2):
        cup.poly([(CX + x, G - 6.5), (CX + x + 0.9, G - 6.5), (CX + x * 0.8 + 0.9, G - 1), (CX + x * 0.8, G - 1)], "v")
    swirl = S(p).ell(CX, G - 8.6, 8, 3.2)
    swirl.ell(CX, G - 10.8, 6.6, 3.6)
    swirl.ell(CX + 0.5, G - 13.4, 3.8, 2.4)
    swirl.ell(CX + 1 - p.ear * 0.5, G - 15.4, 1.6, 1.4)
    swirl.dot(CX - 4, G - 12, "t")
    swirl.dot(CX + 3, G - 12.5, "u")
    swirl.dot(CX + 5, G - 10, "t")
    return [cup, swirl]


def strawberry(p):
    s = S(p).poly([(CX - 8, G - 11), (CX - 8.5, G - 7), (CX - 6, G - 3), (CX - 2, G - 0.5), (CX + 2, G - 0.5),
                   (CX + 6, G - 3), (CX + 8.5, G - 7), (CX + 8, G - 11), (CX + 4, G - 13), (CX - 4, G - 13)], "x",
                  shade_below=G - 4)
    for (x, y) in [(CX - 5, G - 8), (CX + 5, G - 8), (CX - 2, G - 4), (CX + 2, G - 4), (CX - 6, G - 11),
                   (CX + 6, G - 11), (CX, G - 2)]:
        s.dot(x, y, "t")
    leaves = S(p).poly([(CX - 7, G - 12), (CX - 4, G - 15), (CX - 1, G - 13), (CX, G - 16), (CX + 1, G - 13),
                        (CX + 4, G - 15), (CX + 7, G - 12), (CX + 3, G - 11.5), (CX, G - 12.5), (CX - 3, G - 11.5)], "u")
    stem = S(p).rect(CX, G - 18 - min(0, -p.ear), CX, G - 16, "v")
    return [s, leaves, stem]


def mochi(p):
    s = S(p).ell(CX, G - 6.2, 8.6, 6.2)
    leaf = S(p).poly([(CX + 1, G - 10.5), (CX + 4 - p.ear, G - 14), (CX + 7 - p.ear, G - 13.5), (CX + 4, G - 10.5)], "u")
    leaf.rect(CX + 2, G - 11.2, CX + 4, G - 11.2, "v")
    return [s, leaf]


def icepop(p):
    stick = S(p).rect(CX - 1, G - 4, CX, G - 0.5, "t")
    s = S(p).poly([(CX - 5.5, G - 4), (CX - 5.5, G - 13), (CX - 4, G - 15.5), (CX + 4, G - 15.5), (CX + 5.5, G - 13),
                   (CX + 5.5, G - 4)], "x", shade_below=G - 6)
    s.rect(CX - 5.5, G - 15, CX + 5.5, G - 12, "u")
    s.poly([(CX - 5.5, G - 12), (CX - 3.5, G - 10.5), (CX - 1, G - 12), (CX + 1.5, G - 10.5), (CX + 4, G - 12),
            (CX + 5.5, G - 11), (CX + 5.5, G - 12)], "u")
    s.rect(CX - 4.5, G - 9, CX - 4, G - 6, "w")
    return [stick, s]


def taco(p):
    filling = S(p).poly([(CX - 8, G - 7), (CX - 6, G - 11), (CX - 3, G - 10), (CX - 1, G - 12.5), (CX + 2, G - 10.5),
                         (CX + 5, G - 12), (CX + 8, G - 7)], "u")
    for (x, y) in [(CX - 4, G - 10), (CX + 3, G - 11), (CX + 6, G - 9)]:
        filling.dot(x, y, "t")
    shell = S(p).ell(CX, G - 1, 9.5, 8.6)
    shell.cells = {(x, y): k for (x, y), k in shell.cells.items() if y <= G - 0 + p.oy}
    dots = S(p)
    for (x, y) in [(CX - 6, G - 3), (CX + 5, G - 2), (CX - 2, G - 2)]:
        dots.dot(x, y, "v")
    return [filling, shell, ("paint", dots)]


def cookie(p):
    s = S(p).ell(CX, G - 6.8, 8, 6.8)
    chips = S(p)
    for (x, y) in [(CX - 5, G - 11), (CX + 4, G - 12), (CX - 6, G - 5), (CX + 6, G - 6), (CX + 1, G - 2.5),
                   (CX - 2, G - 2.2)]:
        chips.rect(x, y, x + 1, y, "u")
    return [s, ("paint", chips)]


def soda_back(p):
    straw = S(p).rect(CX + 2, G - 19, CX + 3, G - 12, "u")
    straw.rect(CX + 3, G - 19, CX + 6 - p.ear, G - 18, "u")
    straw.rect(CX + 2, G - 16, CX + 3, G - 15, "v")
    return [straw]


def soda(p):
    lid = S(p).rect(CX - 7, G - 14, CX + 6, G - 12, "t")
    cup = S(p).poly([(CX - 6.5, G - 12), (CX + 6.5, G - 12), (CX + 5, G - 0.5), (CX - 5, G - 0.5)], "x", shade_below=G - 3)
    cup.rect(CX - 5, G - 5.5, CX + 4.5, G - 4, "u")
    cup.rect(CX - 5, G - 11, CX - 4, G - 7, "w")
    return [cup, lid]


FOOD_FACE = rig(eyes=((CX - 4, G - 8), (CX + 2, G - 8)), mouth=(CX, G - 5.5), arms=((CX - 7.5, G - 5), (CX + 7.5, G - 5)),
                feet=(CX - 4, CX + 3), cheeks=((CX - 6, G - 6), (CX + 4, G - 6)))


def frig(**kw):
    r = rig(eyes=FOOD_FACE.eyes, mouth=FOOD_FACE.mouth, arms=FOOD_FACE.arms, feet=FOOD_FACE.feet,
            cheeks=FOOD_FACE.cheeks)
    for k, v in kw.items():
        setattr(r, k, v)
    return r


LUNCHBOX = [
    Char("Toastie", shade_set("#F7D08A", "#B9773A", "#FFF0C9", "#5C3714", "#F7D08A", "#5C3714"),
         frig(foot="z", arm="y"), toast, voice={"base": 520, "kind": "pop"}),
    Char("Sunny", shade_set("#FFC21A", "#F09400", "#FFF0A0", "#7A4A00", "#FFFFFF", "#7A4A00"),
         frig(eyes=((CX - 3, G - 10), (CX + 1, G - 10)), mouth=(CX, G - 7.2), arms=((CX - 9, G - 3), (CX + 9, G - 3)),
              feet=(CX - 5, CX + 4), cheeks=((CX - 5, G - 8), (CX + 3, G - 8)), foot="z", arm="u"), egg,
         voice={"base": 1040, "kind": "boing"}),
    Char("Wobble", shade_set("#FFE27A", "#F2BE3A", "#FFF6C8", "#7A5410", "#8A4B1F", "#FF4F6D"),
         frig(eyes=((CX - 4, G - 8), (CX + 2, G - 8)), arms=((CX - 7.5, G - 4), (CX + 7.5, G - 4)), foot="z"), pudding,
         voice={"base": 360, "kind": "wobble"}),
    Char("Nori", shade_set("#FFFFFF", "#E2E6EC", "#FFFFFF", "#3A4250", "#2D5A3D", "#3F7A54"),
         frig(eyes=((CX - 3.5, G - 9), (CX + 1.5, G - 9)), mouth=(CX, G - 6.6), arms=((CX - 8, G - 3.5), (CX + 8, G - 3.5)),
              cheeks=((CX - 5.5, G - 7), (CX + 3.5, G - 7)), foot="u", arm="y"), riceball,
         voice={"base": 700, "kind": "pop"}),
    Char("Sprinkle", shade_set("#FF7EB6", "#E2558F", "#FFC4DE", "#6B1E43", "#FFFFFF", "#D79A55", "#7FE3FF"),
         frig(eyes=((CX - 4, G - 8.5), (CX + 2, G - 8.5)), mouth=(CX, G - 6), arms=((CX - 8.5, G - 4), (CX + 8.5, G - 4)),
              cheeks=((CX - 7, G - 7), (CX + 5, G - 7)), foot="v", arm="v"), donut,
         voice={"base": 880, "kind": "boing"}),
    Char("Swirl", shade_set("#B48CFF", "#8C62E0", "#E3D3FF", "#3A2370", "#FFA8C5", "#F27BA3", "#FFF2A8"),
         frig(eyes=((CX - 4, G - 10), (CX + 2, G - 10)), mouth=(CX, G - 7.6), arms=((CX - 7, G - 4), (CX + 7, G - 4)),
              cheeks=((CX - 6, G - 8), (CX + 4, G - 8)), foot="v", arm="u"), cupcake,
         voice={"base": 1180, "kind": "twinkle"}),
    Char("Berry", shade_set("#FF4D5E", "#D42A3D", "#FF99A3", "#6B0F1C", "#4CC26B", "#2D7A3F", "#FFE48A"),
         frig(eyes=((CX - 4, G - 9), (CX + 2, G - 9)), mouth=(CX, G - 6.5), arms=((CX - 8, G - 6), (CX + 8, G - 6)),
              cheeks=((CX - 6, G - 7), (CX + 4, G - 7)), foot="v", arm="y"), strawberry,
         voice={"base": 1320, "kind": "pop"}),
    Char("Matcha", shade_set("#A7DB6E", "#7AB548", "#DDF5B8", "#355A16", "#5FA83A", "#355A16"),
         frig(eyes=((CX - 4, G - 8), (CX + 2, G - 8)), mouth=(CX, G - 5.6), arms=((CX - 8.5, G - 3.5), (CX + 8.5, G - 3.5)),
              cheeks=((CX - 6, G - 6), (CX + 4, G - 6)), foot="y", arm="y"), mochi,
         voice={"base": 300, "kind": "squish"}),
    Char("Popsy", shade_set("#4F9BFF", "#2D6FD6", "#A9CDFF", "#122E66", "#8FE7FF", "#D9B07A", "#E8C58F"),
         frig(eyes=((CX - 3.5, G - 10), (CX + 1.5, G - 10)), mouth=(CX, G - 7.6), arms=((CX - 6.5, G - 8), (CX + 6.5, G - 8)),
              cheeks=((CX - 5.5, G - 8), (CX + 3.5, G - 8)), foot="y", arm="y"), icepop,
         voice={"base": 1560, "kind": "twinkle"}),
    Char("Crunch", shade_set("#FFB547", "#E08A1E", "#FFE0A3", "#6B3A08", "#58C14B", "#B85A12", "#FF4D4D"),
         frig(eyes=((CX - 4, G - 8), (CX + 2, G - 8)), mouth=(CX, G - 5.6), arms=((CX - 9, G - 3), (CX + 9, G - 3)),
              feet=(CX - 5, CX + 4), cheeks=((CX - 6, G - 6), (CX + 4, G - 6)), foot="v", arm="y"), taco,
         voice={"base": 460, "kind": "crunch"}),
    Char("Chip", shade_set("#E0A867", "#B67A3C", "#F7D49E", "#5A3212", "#3D2412", "#3D2412"),
         frig(eyes=((CX - 4, G - 9), (CX + 2, G - 9)), mouth=(CX, G - 6.4), arms=((CX - 8, G - 5), (CX + 8, G - 5)),
              cheeks=((CX - 6, G - 7), (CX + 4, G - 7)), foot="u", arm="y"), cookie,
         voice={"base": 600, "kind": "crunch"}),
    Char("Fizz", shade_set("#3FD9D0", "#1FA9A2", "#A6F5EF", "#0E4D4A", "#FFFFFF", "#FF5C8A", "#F4F7FA"),
         frig(eyes=((CX - 4, G - 10), (CX + 2, G - 10)), mouth=(CX, G - 7.5), arms=((CX - 7, G - 6), (CX + 7, G - 6)),
              cheeks=((CX - 6, G - 8), (CX + 4, G - 8)), foot="y", arm="y"), soda, soda_back,
         voice={"base": 1240, "kind": "fizz"}),
]


# ---------------------------------------------------------------- lead art

LW, LH = 56, 32   # lead grid, written doubled: 112 x 64 at scale 4 (28 x 16 pt)


def lead_frame():
    return [[None] * LW for _ in range(LH)]


def lput(fr, x, y, k):
    if 0 <= x < LW and 0 <= y < LH:
        fr[y][x] = k


def lell(fr, cx, cy, rx, ry, k, shade=None, outline=None):
    cells = {}
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            nx, ny = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
            if nx * nx + ny * ny <= 1:
                cells[(x, y)] = shade if shade and 0.5 * nx + 0.85 * ny > 0.5 else k
    lstamp(fr, cells, outline)


def lrect(fr, x0, y0, x1, y1, k, outline=None):
    lstamp(fr, {(x, y): k for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)}, outline)


def lstamp(fr, cells, outline):
    if outline:
        for (x, y) in cells:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                if (x + dx, y + dy) not in cells:
                    lput(fr, x + dx, y + dy, outline)
    for (x, y), k in cells.items():
        lput(fr, x, y, k)


def lsprite(fr, x, y, art):
    for dy, row in enumerate(art):
        for dx, c in enumerate(row):
            if c not in ". ":
                lput(fr, x + dx, y + dy, c)


def burrow_lead(level, step, rising=None):
    """A hill burrow with a round door; one window lights per helper."""
    fr = lead_frame()
    # Smoke from the chimney drifts up.
    lrect(fr, 37, 4, 40, 10, "C", "K")
    for i in range(3):
        y = 2 - ((step + i * 2) % 6) // 2 + i * 0
        x = 39 + ((step + i) % 3) - 1 + i
        if 0 <= 3 - i * 1:
            lput(fr, x, max(0, 3 - i - (step % 2)), "F")
    lell(fr, 26, 31, 25, 21, "A", "a", "K")
    # Grass tufts and a flower.
    for x in (8, 15, 44):
        lput(fr, x, 13 + abs(x - 26) // 6, "a")
    lsprite(fr, 43, 15, [".J.", "JfJ", ".J.", ".a."])
    # Windows: up to three light, one per level.
    for i, (wx, wy) in enumerate([(12, 18), (40, 18), (26, 11)]):
        lit = i < level and (level > 0)
        flicker = "I" if lit and (step + i) % 4 == 0 else ("i" if lit else "G")
        lell(fr, wx, wy, 3.2, 3.2, flicker, None, "K")
        lput(fr, wx, wy - 1 if True else wy, "K")
        lrect(fr, wx - 2, wy, wx + 2, wy, "K")
    # The round door, opening as it rises.
    open_ = 0 if rising is None else rising
    lell(fr, 26, 27, 6.2, 6.5, "c", None, "K")
    if open_:
        lell(fr, 26, 27.5, 5.0 - (3 - open_), 5.5, "k", None, None)
    else:
        lrect(fr, 26, 21, 26, 31, "C")
        lput(fr, 29, 27, "J")
    # A path stone.
    lrect(fr, 22, 31, 30, 31, "G")
    return fr


def lunchbox_lead(level, step, rising=None):
    """An open lunchbox with a face; one compartment fills per helper."""
    fr = lead_frame()
    bob = (step % 2) if level else 0
    lid = 1 if rising is None else rising
    # Lid, tipped open behind the box.
    lrect(fr, 9, 2 - lid + bob, 46, 7 - lid + bob, "c", "K")
    lrect(fr, 10, 6 - lid + bob, 45, 7 - lid + bob, "C")
    lrect(fr, 22, 0 + bob, 33, 1 + bob, "G", "K")  # handle
    # Box.
    lrect(fr, 6, 10 + bob, 49, 30, "A", "K")
    lrect(fr, 6, 27, 49, 30, "a")
    # Compartments: rice, berries, an egg roll; each lights up with a helper.
    slots = [(9, 12, 20, 19), (23, 12, 32, 19), (35, 12, 46, 19)]
    fills = ["F", "J", "I"]
    for i, (x0, y0, x1, y1) in enumerate(slots):
        lrect(fr, x0, y0 + bob, x1, y1 + bob, fills[i] if i < level else "G", "K")
        if i < level:
            for j in range(3):
                lput(fr, x0 + 2 + j * 3 + ((step + j) % 2), y0 + 2 + bob + (j % 2) * 2, "f" if i != 1 else "i")
    # Face on the box front.
    for ex in (21, 33):
        lrect(fr, ex, 22 + bob, ex + 1, 23 + bob, "k")
        lput(fr, ex, 22 + bob, "W")
    lrect(fr, 26, 25 + bob, 29, 25 + bob, "k")
    lrect(fr, 17, 24 + bob, 18, 24 + bob, "p")
    lrect(fr, 37, 24 + bob, 38, 24 + bob, "p")
    return fr


def lead_rows(fr):
    out = []
    for row in fr:
        wide = "".join((c or ".") * 2 for c in row)
        out += [wide, wide]
    return out


def lead_art(pack):
    draw = burrow_lead if pack == "burrow" else lunchbox_lead
    rest = [lead_rows(draw(0, s)) for s in range(4)]
    rising = [lead_rows(draw(0, s, rising=r)) for s, r in enumerate([1, 2, 3, 3])]
    levels = [[lead_rows(draw(n, s)) for s in range(4)] for n in (1, 2, 3)]
    return {"rest": rest, "rising": rising, "levels": levels}


LEAD_PALETTE = {
    "burrow": {
        "A": "#8FD16A", "a": "#5FA845", "K": "#2E4A24", "C": "#B5835A", "c": "#E2A35F",
        "F": "#E6E6EE", "G": "#7D8A70", "I": "#FFF2A8", "i": "#FFC94A", "J": "#FF8FB1", "f": "#FFE45C",
    },
    "lunchbox": {
        "A": "#FF8F70", "a": "#E0664A", "K": "#5A2418", "C": "#FFB09A", "c": "#FFC4B2",
        "F": "#FFFFFF", "G": "#E9D2C6", "I": "#FFD94A", "i": "#FF4D5E", "J": "#FFB3C1", "f": "#3F7A54",
    },
}


# ---------------------------------------------------------------- sounds

RATE = 22050


def write_wav(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = max(1e-6, max(abs(s) for s in samples))
    gain = 0.6 / peak
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * gain)) * 32767)) for s in samples))


def tone(f0, f1, dur, wave_="sine", vib=0.0, attack=0.005, decay=None, noise=0.0, seed=0):
    rnd = random.Random(seed)
    n = int(RATE * dur)
    out, phase = [], 0.0
    for i in range(n):
        t = i / n
        f = f0 + (f1 - f0) * t
        if vib:
            f *= 1 + vib * math.sin(2 * math.pi * 22 * i / RATE)
        phase += 2 * math.pi * f / RATE
        if wave_ == "sine":
            v = math.sin(phase)
        elif wave_ == "tri":
            v = 2 / math.pi * math.asin(math.sin(phase))
        else:
            v = 1.0 if math.sin(phase) >= 0 else -1.0
            v *= 0.5
        if noise:
            v = v * (1 - noise) + (rnd.random() * 2 - 1) * noise
        env = min(1.0, (i / RATE) / attack) if attack else 1.0
        tail = (1 - t) ** (decay or 1.6)
        out.append(v * env * tail)
    return out


def silence(dur):
    return [0.0] * int(RATE * dur)


def mix(*parts):
    out = []
    for p in parts:
        out += p
    return out


def voice(kind, base, variant=0):
    b = base * (1 + 0.06 * variant)
    if kind == "squeak":
        return mix(tone(b, b * 1.5, 0.07, "tri", vib=0.02), silence(0.03), tone(b * 1.2, b * 1.7, 0.09, "tri", vib=0.03))
    if kind == "yip":
        return mix(tone(b * 1.4, b * 0.9, 0.08, "tri"), silence(0.04), tone(b * 1.5, b, 0.1, "tri"))
    if kind == "hum":
        return tone(b, b * 1.25, 0.32, "tri", vib=0.04, attack=0.03, decay=1.2)
    if kind == "ribbit":
        return mix(tone(b, b * 1.1, 0.06, "square"), silence(0.025), tone(b * 1.3, b * 1.2, 0.09, "square"))
    if kind == "chirp":
        return mix(tone(b, b * 1.6, 0.05, "sine"), silence(0.02), tone(b * 1.1, b * 1.8, 0.05, "sine"),
                   silence(0.02), tone(b * 1.2, b * 2.0, 0.06, "sine"))
    if kind == "hoot":
        return mix(tone(b, b * 0.92, 0.16, "sine", vib=0.01, attack=0.02), silence(0.05),
                   tone(b * 0.95, b * 0.85, 0.22, "sine", attack=0.02))
    if kind == "honk":
        return mix(tone(b, b * 0.95, 0.12, "square", vib=0.02), silence(0.03), tone(b * 1.12, b * 1.05, 0.14, "square"))
    if kind == "sniff":
        return mix(tone(b * 2, b * 2, 0.04, "sine", noise=0.85, seed=1), silence(0.04),
                   tone(b * 2, b * 2, 0.04, "sine", noise=0.85, seed=2), silence(0.03), tone(b, b * 1.4, 0.1, "tri"))
    if kind == "bubble":
        return mix(*[mix(tone(b * (1 + i * 0.25), b * (1.6 + i * 0.25), 0.05, "sine"), silence(0.025)) for i in range(3)])
    if kind == "slide":
        return tone(b * 0.8, b * 1.6, 0.35, "sine", vib=0.05, attack=0.04, decay=1.0)
    if kind == "mew":
        return tone(b * 1.2, b * 0.9, 0.24, "tri", vib=0.03, attack=0.02, decay=1.1)
    if kind == "pop":
        return mix(tone(b * 1.8, b * 0.7, 0.05, "sine", decay=2.5), silence(0.04), tone(b * 1.5, b * 2.2, 0.08, "sine"))
    if kind == "boing":
        return tone(b * 0.6, b * 1.8, 0.28, "sine", vib=0.12, decay=1.5)
    if kind == "wobble":
        return tone(b, b * 1.2, 0.36, "tri", vib=0.15, attack=0.01, decay=1.2)
    if kind == "twinkle":
        return mix(*[tone(b * r, b * r, 0.07, "sine", decay=2.2) for r in (1, 1.26, 1.5, 2)])
    if kind == "squish":
        return mix(tone(b * 1.5, b * 0.8, 0.12, "sine", noise=0.2, seed=3), tone(b, b * 1.3, 0.12, "tri"))
    if kind == "crunch":
        return mix(tone(b, b, 0.05, "sine", noise=0.9, seed=4), silence(0.03), tone(b, b, 0.05, "sine", noise=0.9, seed=5),
                   silence(0.03), tone(b * 1.4, b * 1.8, 0.08, "tri"))
    if kind == "fizz":
        return mix(tone(b * 3, b * 3, 0.18, "sine", noise=0.95, seed=6, decay=1.0), tone(b, b * 1.5, 0.08, "sine"))
    raise ValueError(kind)


def chord(notes, dur=0.12, wave_="tri"):
    return mix(*[tone(n, n, dur, wave_, decay=1.8) for n in notes])


def pack_sounds(folder, chars, family):
    voices = {"spawn": [], "done": {}}
    for i in range(3):
        rel = "voice/hello-%d.wav" % (i + 1)
        c = chars[i * 4]
        write_wav(folder / rel, voice(c.voice["kind"], c.voice["base"], variant=i + 1))
        voices["spawn"].append(rel)
    for c in chars:
        rel = "voice/%s.wav" % c.name.lower()
        write_wav(folder / rel, mix(voice(c.voice["kind"], c.voice["base"]), silence(0.02)))
        voices["done"][c.name] = [rel]
    up = 1.0 if family == "burrow" else 1.12
    write_wav(folder / "over-to-you.wav", chord([523 * up, 659 * up, 784 * up, 1047 * up], 0.11))
    write_wav(folder / "uh-oh.wav", chord([494 * up, 415 * up, 330 * up], 0.16, "sine"))
    write_wav(folder / "psst.wav", mix(tone(1320 * up, 1560 * up, 0.07, "sine"), silence(0.06),
                                       tone(1320 * up, 1760 * up, 0.09, "sine")))
    sounds = {"quack": "over-to-you.wav", "honk": "uh-oh.wav", "chirp": "psst.wav"}
    return voices, sounds


# ---------------------------------------------------------------- writing

PACKS_DEF = [
    ("burrow-buddies", "Burrow Buddies", "burrow", BURROW),
    ("lunchbox-pals", "Lunchbox Pals", "lunchbox", LUNCHBOX),
]


def helper_json(char):
    loops, done, failed, ends = frames_for(char)
    return {
        "name": char.name,
        "names": [char.name],
        "colors": char.colors,
        "loops": {name: {"frameMs": ms, "frames": [fr.doubled() for fr in frames]} for name, (ms, frames) in loops.items()},
        "ends": {"done": done.doubled(), "failed": failed.doubled(),
                 **{name: [fr.doubled() for fr in frames] for name, frames in ends.items()}},
    }


def used_letters(theme):
    seen = set()

    def walk(v):
        if isinstance(v, str):
            seen.update(v)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)
    for h in theme["helpers"]:
        walk(h["loops"])
        walk(h["ends"])
    return seen


def write_pack(pack_id, title, family, chars):
    folder = PACKS / pack_id
    folder.mkdir(parents=True, exist_ok=True)
    palette = dict(SHARED)
    palette.update(LEAD_PALETTE[family])
    theme = {
        "duckherdTheme": 1, "id": pack_id, "title": title, "scale": 4, "palette": palette,
        "helpers": [helper_json(c) for c in chars],
        "lead": lead_art(family),
    }
    voices, sounds = pack_sounds(folder, chars, family)
    theme["voices"] = voices
    theme["sounds"] = sounds
    missing = used_letters(theme) - {"."} - set(palette) - set("wxyzuvt")
    assert not missing, (pack_id, missing)
    text = json.dumps(theme, separators=(",", ":"))
    (folder / "theme.json").write_text(text)
    return len(text)


def check_letters(chars):
    for c in chars:
        h = helper_json(c)
        used = set()
        for loop in h["loops"].values():
            for fr in loop["frames"]:
                used.update("".join(fr))
        for name, v in h["ends"].items():
            frames = [v] if isinstance(v[0], str) else v
            for fr in frames:
                used.update("".join(fr))
        own = set("wxyzuvt")
        missing = {k for k in used & own if k not in c.colors}
        assert not missing, (c.name, missing)


# ---------------------------------------------------------------- previews

def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def write_png(path, width, height, pixels):
    raw = b"".join(b"\x00" + bytes(v for px in pixels[y * width:(y + 1) * width] for v in px) for y in range(height))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def sheet(theme_path, out_dir, scales=(1, 3)):
    """Contact sheet from the written theme.json: each character's idle and two
    working frames (run, type), light and dark, at tile size (1 grid pixel per
    device pixel: 40 x 24) and at 3x."""
    theme = json.loads(pathlib.Path(theme_path).read_text())
    pal = theme["palette"]
    picks = [("idle", lambda h: h["ends"]["idle"][0]), ("run", lambda h: h["loops"]["run"]["frames"][1]),
             ("run", lambda h: h["loops"]["run"]["frames"][4]), ("type", lambda h: h["loops"]["type"]["frames"][0]),
             ("read", lambda h: h["loops"]["read"]["frames"][0]), ("think", lambda h: h["loops"]["think"]["frames"][3])]
    bgs = [(246, 246, 248), (30, 31, 36)]
    for scale in scales:
        cw, ch = 40 * scale, 24 * scale
        pad = 4 * scale
        cols = len(picks) * 2
        width = cols * (cw + pad) + pad
        height = len(theme["helpers"]) * (ch + pad) + pad
        pixels = [None] * (width * height)
        for col in range(cols):
            bg = bgs[col // len(picks)]
            for y in range(height):
                for x in range(pad // 2 + col * (cw + pad), pad // 2 + (col + 1) * (cw + pad)):
                    if x < width:
                        pixels[y * width + x] = bg
        for i in range(width * height):
            if pixels[i] is None:
                pixels[i] = bgs[1]
        for row, h in enumerate(theme["helpers"]):
            colours = dict(pal)
            colours.update(h.get("colors", {}))
            for col in range(cols):
                _, pick = picks[col % len(picks)]
                fr = pick(h)
                ox, oy = pad + col * (cw + pad), pad + row * (ch + pad)
                for y in range(24):
                    for x in range(40):
                        c = fr[y * 2][x * 2]
                        if c == ".":
                            continue
                        rgb = hexrgb(colours[c])
                        for sy in range(scale):
                            for sx in range(scale):
                                pixels[(oy + y * scale + sy) * width + ox + x * scale + sx] = rgb
        write_png(pathlib.Path(out_dir) / ("%s-%dx.png" % (theme["id"], scale)), width, height, pixels)


def strip(theme_path, out_dir, scale=3):
    """Every frame of every character, one row per clip, for checking by eye."""
    theme = json.loads(pathlib.Path(theme_path).read_text())
    pal = theme["palette"]
    for h in theme["helpers"]:
        clips = [(k, v["frames"]) for k, v in h["loops"].items()]
        clips += [("done", [h["ends"]["done"]]), ("failed", [h["ends"]["failed"]])]
        clips += [(k, v) for k, v in h["ends"].items() if k not in ("done", "failed")]
        cw, ch = 40 * scale, 24 * scale
        cols = max(len(f) for _, f in clips)
        width, height = cols * (cw + scale) + scale, len(clips) * (ch + scale) + scale
        pixels = [(255, 255, 255)] * (width * height)
        colours = dict(pal)
        colours.update(h.get("colors", {}))
        for r, (_, frames) in enumerate(clips):
            for c, fr in enumerate(frames):
                ox, oy = scale + c * (cw + scale), scale + r * (ch + scale)
                for y in range(24):
                    for x in range(40):
                        k = fr[y * 2][x * 2]
                        rgb = (232, 234, 240) if k == "." else hexrgb(colours[k])
                        for sy in range(scale):
                            row = (oy + y * scale + sy) * width + ox + x * scale
                            pixels[row:row + scale] = [rgb] * scale
        write_png(pathlib.Path(out_dir) / ("%s-%s.png" % (theme["id"], h["name"].lower())), width, height, pixels)


def main():
    args = sys.argv[1:]
    only = None
    if "--only" in args:
        only = args[args.index("--only") + 1]
    for pack_id, title, family, chars in PACKS_DEF:
        if only and only != pack_id:
            continue
        check_letters(chars)
        size = write_pack(pack_id, title, family, chars)
        print("%s: %d characters, theme.json %d bytes" % (pack_id, len(chars), size))
        if "--sheets" in args:
            out = args[args.index("--sheets") + 1]
            scales = (1, 3)
            if "--scales" in args:
                scales = tuple(int(s) for s in args[args.index("--scales") + 1].split(","))
            sheet(PACKS / pack_id / "theme.json", out, scales)
        if "--strips" in args:
            strip(PACKS / pack_id / "theme.json", args[args.index("--strips") + 1])


if __name__ == "__main__":
    main()
