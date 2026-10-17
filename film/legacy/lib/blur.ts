// Temporal motion blur by accumulation. Adapted from Tessel's src/blur.ts (MIT, see
// THIRD_PARTY_NOTICES.md): the only change is that acts and total come from a cue sheet
// instead of one global timeline. A frame is the average of n renders spread across a 240°
// shutter; n per frame comes from scripts/tessel/measure-speed.py (optical flow on the sharp
// render), and scripts/tessel/accumulate.py averages the sub-frames in float, outside Chromium.
import type { CueSheet } from './sheet';

export const SHUTTER = 240; // degrees; measure-speed.py assumes the same

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
