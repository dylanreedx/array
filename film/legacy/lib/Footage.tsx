// Real footage: a take captured by the app itself (`--film`, research/07), played back frame for frame
// under the film's lens, caption band and acts. A take is a PNG sequence in public/footage/<take>/
// (000000.png ...) captured at the film's fps, so footage frame i is composition frame `from + i`.
//
// The footage lens frames a rect in FOOTAGE px (a 2x capture: 2560x1600 for a 1280x800 window) inside
// the output box (the output minus any caption band), on the same keyed springs as lib/Lens.tsx. It
// only crops and magnifies what the app drew, so keep it under ~1.5x of the capture's own pixels: the
// app's own camera does the real moves, at real zoom levels, and the lens just frames.
import { Img, OffthreadVideo, Sequence, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import type { Frame } from '@website/features/demo/types';
import { E, prog, type Ease } from './anim';
import { bandOf } from './formats';

/** `video` (public/footage/<video>) plays an encoded take frame-exact; otherwise `dir` holds a PNG sequence. */
export interface Take { dir?: string; video?: string; frames: number; width: number; height: number }
export interface FootageKey { at: number; rect: Frame | ((box: Frame) => Frame); dur?: number; ease?: Ease }

const lerp = (a: number, b: number, t: number) => a * (1 - t) + b * t;
const pad = (i: number) => String(i).padStart(6, '0');

/** The box subjects are framed in: the output minus the format's caption band (when `banded`). */
export const footageBox = (output: { width: number; height: number }, banded: boolean): Frame => {
  if (!banded) return { x: 0, y: 0, ...output };
  const band = bandOf(output);
  return band.edge === 'top' ? { x: 0, y: band.size, width: output.width, height: output.height - band.size } : { x: 0, y: 0, width: output.width, height: output.height - band.size };
};

/**
 * Where the take sits in the output at frame `f`: take px -> output px is (x + px * scale, y + py * scale).
 * Pure, so an overlay can follow a rect inside the take (a shared-element move onto a tile).
 */
export const footageView = (take: Take, keys: FootageKey[], f: number, fps: number, box: Frame, fit: 'contain' | 'cover' = 'contain') => {
  const whole: Frame = { x: 0, y: 0, width: take.width, height: take.height };
  const rectOf = (k?: FootageKey) => (!k ? whole : typeof k.rect === 'function' ? k.rect(box) : k.rect);
  const sorted = [...keys].sort((a, b) => a.at - b.at);
  let n = sorted.findIndex((k) => k.at > f) - 1;
  if (n < -1) n = sorted.length - 1;
  const cur = sorted[n], prev = sorted[n - 1];
  const t = cur ? prog(f, cur.at, cur.at + (cur.dur ?? Math.round(fps * 0.9)), cur.ease ?? E.cam) : 1;
  const a = rectOf(prev ?? cur), b = rectOf(cur);
  const r = { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t) };
  const scale = (fit === 'cover' ? Math.max : Math.min)(box.width / r.width, box.height / r.height);
  return { scale, x: box.x + box.width / 2 - (r.x + r.width / 2) * scale, y: box.y + box.height / 2 - (r.y + r.height / 2) * scale };
};

/**
 * `from` is the composition frame the take's frame `trim` lands on. `fit` 'contain' (default) shows the
 * framed rect whole inside the box, on the desk colour; 'cover' crops to fill the box.
 */
export const Footage: React.FC<{ take: Take; from: number; trim?: number; keys: FootageKey[]; banded?: boolean; fit?: 'contain' | 'cover'; viewport?: { width: number; height: number } }> = ({ take, from, trim = 0, keys, banded = true, fit = 'contain', viewport }) => {
  const f = useCurrentFrame();
  const config = useVideoConfig();
  const output = viewport ?? { width: config.width, height: config.height };
  const box = footageBox(output, banded);
  const i = Math.max(0, Math.min(take.frames - 1, f - from + trim));
  const { scale, x, y } = footageView(take, keys, f, config.fps, box, fit);
  return (
    <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background: '#0b0d10' }}>
      {take.video
        // The Sequence shifts the video's clock so take frame `trim` plays at composition frame `from`.
        ? <Sequence from={from - trim} layout="none"><OffthreadVideo src={staticFile(`footage/${take.video}`)} muted style={{ position: 'absolute', left: x, top: y, width: take.width * scale, height: take.height * scale, maxWidth: 'none' }} /></Sequence>
        : <Img src={staticFile(`footage/${take.dir}/${pad(i)}.png`)} style={{ position: 'absolute', left: x, top: y, width: take.width * scale, height: take.height * scale, maxWidth: 'none' }} />}
    </div>
  );
};
