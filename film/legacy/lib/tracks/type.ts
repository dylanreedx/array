// Typing as a track: the draft grows one character per step on the clock's grid.
import type { DemoAction, DemoState } from '@website/features/demo/types';
import type { Track } from '../sheet';

export const typeTrack = (id: string, from: number, to: number, text: string, set: (draft: string, s: DemoState) => DemoAction): Track => ({
  id, from, to, ease: (t) => t,
  action: (t, s) => set(text.slice(0, Math.round(t * text.length)), s),
});

/** Frames on which a new character appears, for key-click sounds. */
export const keyFrames = (from: number, to: number, text: string) =>
  Array.from({ length: text.length }, (_, i) => Math.round(from + ((i + 0.5) / text.length) * (to - from)));
