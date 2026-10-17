// Easing, tween, spring and seeded-random helpers.
// Adapted from Tessel launch film (github.com/Leonxlnx/claude-launchvideo, src/lib/anim.ts).
// Copyright (c) 2026 Leonxlnx. MIT License, full text in film/THIRD_PARTY_NOTICES.md.
// Change from upstream: fps is a parameter (Array renders 60 fps masters and 30 fps loops
// from one timeline), and the native spatial curve from DESIGN_SYSTEM.md is added as E.native.
import { Easing, interpolate, spring, type SpringConfig } from 'remotion';

export type Ease = (t: number) => number;

export const E = {
  out: Easing.bezier(0.16, 1, 0.3, 1),
  outSoft: Easing.bezier(0.22, 1, 0.36, 1),
  in: Easing.bezier(0.7, 0, 0.84, 0),
  inOut: Easing.bezier(0.87, 0, 0.13, 1),
  smooth: Easing.bezier(0.65, 0, 0.35, 1),
  swift: Easing.bezier(0.4, 0, 0.2, 1),
  cam: Easing.bezier(0.48, 0.1, 0.0, 0.9),
  glide: Easing.bezier(0.47, 0.2, 0.15, 1),
  // Array's own: "Tidy, Shuffle, Undo, resize settlement, and zone growth use the native
  // spatial easing cubic-bezier(.16, 1, .3, 1)" (website/DESIGN_SYSTEM.md). Same curve as E.out.
  native: Easing.bezier(0.16, 1, 0.3, 1),
  // CSS `ease-out`.
  cssOut: Easing.bezier(0, 0, 0.58, 1),
  linear: (t: number) => t,
} satisfies Record<string, Ease>;

/** Exponential approach with time constant `tau` (s), normalised to land exactly on 1 at `dur` (s). */
export const expo = (tau: number, dur: number): Ease => {
  const k = dur / tau;
  return (t) => (1 - Math.exp(-k * t)) / (1 - Math.exp(-k));
};

export const tw = (frame: number, from: number, to: number, a: number, b: number, ease: Ease = E.out) =>
  interpolate(frame, [from, Math.max(from + 1e-6, to)], [a, b], { easing: ease, extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

export const prog = (frame: number, from: number, to: number, ease: Ease = E.out) => tw(frame, from, to, 0, 1, ease);
export const mix = (a: number, b: number, t: number) => a + (b - a) * t;

/** Attack-decay envelope so a visual hit peaks with its sound. */
export const hitPulse = (t: number, attack = 2, tau = 5) =>
  t <= 0 || t > attack + 6 * tau ? 0 : t < attack ? Math.sin((t / attack) * (Math.PI / 2)) : Math.exp(-(t - attack) / tau);

export const SPR = {
  snap: { damping: 18, stiffness: 260, mass: 0.7 },
  pop: { damping: 11, stiffness: 180, mass: 0.6 },
  soft: { damping: 26, stiffness: 120, mass: 1 },
  heavy: { damping: 30, stiffness: 90, mass: 1.4 },
} satisfies Record<string, Partial<SpringConfig>>;

export const spr = (frame: number, start: number, fps: number, cfg: Partial<SpringConfig> = SPR.snap) =>
  spring({ frame: frame - start, fps, config: cfg });

/** Deterministic pseudo-random in [0,1) from a seed. Never Math.random() in a film. */
export const rand = (seed: number | string) => {
  let h = typeof seed === 'number' ? seed * 2654435761 : 0;
  if (typeof seed === 'string') for (let i = 0; i < seed.length; i++) h = Math.imul(h ^ seed.charCodeAt(i), 2654435761);
  h ^= h >>> 16; h = Math.imul(h, 2246822507); h ^= h >>> 13; h = Math.imul(h, 3266489909); h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
};

// ---- closed-form springs ------------------------------------------------------------------------
// A damped harmonic oscillator from 0 at rest toward 1, solved analytically, so any frame renders
// from (frame, start) alone: no simulation of the frames before it. Remotion renders frames out of
// order across tabs, and the 0xMovez course's rule is the same: a spring is a function of time.
//
// Presets follow the brief: snappy for chips and pills (a little overshoot), soft for the camera
// and tiles (barely any), heavy for the mark and big type (none, critically damped).
export interface Spring { /** natural frequency, Hz */ hz: number; /** damping ratio, 1 = critical */ zeta: number }
export const SPRING = {
  snappy: { hz: 2.4, zeta: 0.72 },
  soft: { hz: 1.35, zeta: 0.9 },
  heavy: { hz: 0.95, zeta: 1 },
  /** captions: critically damped and quick (settles in ~0.55 s), no overshoot on type */
  type: { hz: 2.6, zeta: 1 },
} satisfies Record<string, Spring>;

/** Spring position at `t` seconds after release (0 before), approaching 1. */
export const springAt = (t: number, { hz, zeta }: Spring) => {
  if (t <= 0) return 0;
  const w = 2 * Math.PI * hz;
  if (zeta < 1) {
    const wd = w * Math.sqrt(1 - zeta * zeta);
    return 1 - Math.exp(-zeta * w * t) * (Math.cos(wd * t) + ((zeta * w) / wd) * Math.sin(wd * t));
  }
  if (zeta === 1) return 1 - Math.exp(-w * t) * (1 + w * t);
  const wh = w * Math.sqrt(zeta * zeta - 1);
  return 1 - Math.exp(-zeta * w * t) * (Math.cosh(wh * t) + ((zeta * w) / wh) * Math.sinh(wh * t));
};

/** Spring value at `frame` for a spring released at `start`. */
export const sprAt = (frame: number, start: number, fps: number, s: Spring = SPRING.soft) => springAt((frame - start) / fps, s);

/**
 * A spring as an Ease over a move of `dur` seconds (lens keys, tracks): exact 0 at t=0 and exact 1
 * at t=1, so a key lands bit for bit. Choose `dur` past the spring's settle time; the residue it
 * removes is then below a pixel.
 */
export const springEase = (s: Spring, dur: number): Ease => {
  const end = springAt(dur, s);
  return (t) => (t >= 1 ? 1 : springAt(t * dur, s) / end);
};

/**
 * One value with several targets over time. Each change starts its own spring from its own frame,
 * and the value is the sum of the deltas each spring has delivered: superposition, so a retarget
 * mid-flight keeps the motion continuous and any frame still renders on its own.
 *   track(f, fps, 0, [{ at: 120, to: 1 }, { at: 300, to: 0.4, spring: SPRING.heavy }])
 */
export const track = (frame: number, fps: number, initial: number, keys: { at: number; to: number; spring?: Spring }[], s: Spring = SPRING.soft) => {
  let value = initial, prev = initial;
  for (const k of [...keys].sort((a, b) => a.at - b.at)) {
    value += (k.to - prev) * sprAt(frame, k.at, fps, k.spring ?? s);
    prev = k.to;
  }
  return value;
};
