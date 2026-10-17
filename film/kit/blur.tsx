// Motion blur, two kinds.
//
// 1. Faked, per element (BlurX, VelocityBlur): a directional Gaussian on something that moves fast, sized
//    from its velocity. Cheap, renders in one pass, and what every film has used on swaps and flights.
//    Dylan, 2026-10-16: he loves it on the terminal tab switches; capped at ~10 px (18 smeared the cards
//    into streaks with nothing readable on them).
// 2. Real, by accumulation (sampleTimes/subframes + scripts/tessel): a frame is the average of n renders
//    spread over a 240 degree shutter, n per frame from the measured speed. Adapted from Tessel's
//    src/blur.ts (MIT, see THIRD_PARTY_NOTICES.md). Slow; for a master, never for a proto.
import type { CueSheet } from './sheet';
import type { Rect } from './rect';

/** A horizontal blur wrapper (a content swap's smear). `amount` is the x standard deviation in px. */
export const BlurX: React.FC<{ id: string; amount: number; children: React.ReactNode; style?: React.CSSProperties }> = ({ id, amount, children, style }) => (
  <div style={{ position: 'absolute', inset: 0, ...style, filter: amount > 0.25 ? `url(#${id})` : undefined }}>
    <svg width="0" height="0" style={{ position: 'absolute' }}><filter id={id} x="-10%" y="0" width="120%" height="100%" colorInterpolationFilters="sRGB"><feGaussianBlur stdDeviation={`${amount} 0`} /></filter></svg>
    {children}
  </div>
);

/** The SVG filter for a 2-D directional blur; reference it as `url(#<id>)` on the moving element. */
export const BlurFilter: React.FC<{ id: string; x: number; y: number }> = ({ id, x, y }) => (
  <svg width="0" height="0" style={{ position: 'absolute' }}><filter id={id} x="-20%" y="-20%" width="140%" height="140%" colorInterpolationFilters="sRGB"><feGaussianBlur stdDeviation={`${x} ${y}`} /></filter></svg>
);

/**
 * Blur from a rect's velocity, optionally RELATIVE to a reference rect (a card riding its tile: the take's
 * camera draws its own frames crisp, so a card moving with its tile must be sharp). Velocity is centre
 * travel plus half the size change, per frame; blur = min(cap, v * k) on each axis.
 */
export const velocityBlur = (now: Rect, before: Rect, k: number, cap: number, ref?: { now: Rect; before: Rect }) => {
  const zero = { x: 0, y: 0, width: 0, height: 0 };
  const rel = (a: Rect, b: Rect) => ({ x: a.x - b.x, y: a.y - b.y, width: a.width - b.width, height: a.height - b.height });
  const dr = rel(now, ref?.now ?? zero), dq = rel(before, ref?.before ?? zero);
  const vx = Math.abs(dr.x + dr.width / 2 - (dq.x + dq.width / 2)) + Math.abs(dr.width - dq.width) / 2;
  const vy = Math.abs(dr.y + dr.height / 2 - (dq.y + dq.height / 2)) + Math.abs(dr.height - dq.height) / 2;
  return { x: Math.min(cap, vx * k), y: Math.min(cap, vy * k) };
};

export const SHUTTER = 240; // degrees; scripts/tessel/measure-speed.py assumes the same

export const sampleTimes = (sheet: CueSheet, f: number, n: number): number[] => {
  if (n <= 1) return [f];
  const acts = Object.values(sheet.acts);
  const a = acts.find((x) => f >= x.from && f < x.from + x.dur) ?? { from: 0, dur: sheet.durationInFrames };
  const span = SHUTTER / 360;
  const lo = a.from, hi = a.from + a.dur - 1e-3;
  return Array.from({ length: n }, (_, i) => Math.min(hi, Math.max(lo, f + span * ((i + 0.5) / n - 0.5))));
};

export const subframes = (sheet: CueSheet, groups: number[]) => {
  const out: { f: number; t: number }[] = [];
  for (let f = 0; f < sheet.durationInFrames; f++) for (const t of sampleTimes(sheet, f, groups[f] ?? 1)) out.push({ f, t });
  return out;
};
