// Real footage: a take the app captured of itself (the film recorder, `--film`), played back frame for
// frame. scripts/import-take puts a take's frames at public/footage/<video>/<take>/000000.png ...; a take
// is captured at the film's fps, so take frame i is composition frame `from + i`.
//
// The footage lens frames a rect in TAKE px (a 2x capture: 3840x2096 for a 1920x1048 pt window) inside
// the output box. It only crops and magnifies what the app drew, so keep it under ~1.5x of the capture's
// own pixels: the app's own camera does the real moves, at real zoom levels, and the lens just frames.
import { Img, OffthreadVideo, Sequence, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { E, prog, type Ease } from './anim';
import { bandOf } from './formats';
import { lerp, type Rect } from './rect';

/** `video` (public/footage/<video>) plays an encoded take frame-exact; otherwise `dir` holds a PNG sequence. */
export interface Take { dir?: string; video?: string; frames: number; width: number; height: number }
export interface FootageKey { at: number; rect: Rect | ((box: Rect) => Rect); dur?: number; ease?: Ease }

const pad = (i: number) => String(i).padStart(6, '0');

/** The box subjects are framed in: the output, minus a caption band when `banded`. */
export const footageBox = (output: { width: number; height: number }, banded: boolean): Rect => {
  if (!banded) return { x: 0, y: 0, ...output };
  const band = bandOf(output);
  return band.edge === 'top' ? { x: 0, y: band.size, width: output.width, height: output.height - band.size } : { x: 0, y: 0, width: output.width, height: output.height - band.size };
};

/**
 * Where the take sits in the output at frame `f`: take px -> output px is (x + px * scale, y + py * scale).
 * Pure, so an overlay can follow a rect inside the take (a shared-element move onto a tile).
 */
export const footageView = (take: Take, keys: FootageKey[], f: number, fps: number, box: Rect, fit: 'contain' | 'cover' = 'contain') => {
  const whole: Rect = { x: 0, y: 0, width: take.width, height: take.height };
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

/** take px -> output px through a footageView. */
export const toOutput = (view: { scale: number; x: number; y: number }) => (r: Rect): Rect =>
  ({ x: view.x + r.x * view.scale, y: view.y + r.y * view.scale, width: r.width * view.scale, height: r.height * view.scale });

/**
 * `from` is the composition frame the take's frame `trim` lands on. `fit` 'contain' (default) shows the
 * framed rect whole inside the box, on `background`; 'cover' crops to fill the box.
 */
export const Footage: React.FC<{ take: Take; from: number; trim?: number; keys: FootageKey[]; banded?: boolean; fit?: 'contain' | 'cover'; viewport?: { width: number; height: number }; background: string }> = ({ take, from, trim = 0, keys, banded = true, fit = 'contain', viewport, background }) => {
  const f = useCurrentFrame();
  const config = useVideoConfig();
  const output = viewport ?? { width: config.width, height: config.height };
  const box = footageBox(output, banded);
  const i = Math.max(0, Math.min(take.frames - 1, f - from + trim));
  const { scale, x, y } = footageView(take, keys, f, config.fps, box, fit);
  return (
    <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background }}>
      {take.video
        // The Sequence shifts the video's clock so take frame `trim` plays at composition frame `from`.
        ? <Sequence from={from - trim} layout="none"><OffthreadVideo src={staticFile(`footage/${take.video}`)} muted style={{ position: 'absolute', left: x, top: y, width: take.width * scale, height: take.height * scale, maxWidth: 'none' }} /></Sequence>
        : <Img src={staticFile(`footage/${take.dir}/${pad(i)}.png`)} style={{ position: 'absolute', left: x, top: y, width: take.width * scale, height: take.height * scale, maxWidth: 'none' }} />}
    </div>
  );
};

/**
 * A take's frames.json, cut down by scripts/import-take to what the edit reads: per-frame rects (in POINTS,
 * [x, y, w, h], [0,0,0,0] when off screen) and the take's marks.
 */
export interface TakeTrack { source: string; take: string; count: number; fps: number; pixelSize: number[]; pointSize: number[]; marks: Record<string, number>; rects: Record<string, number[][]> }

/** A rect of the track at take frame i, in take PX (points x the capture's scale). */
export const trackRect = (track: TakeTrack, key: string, i: number, scale = track.pixelSize[0] / track.pointSize[0]): Rect => {
  const r = track.rects[key][Math.max(0, Math.min(track.count - 1, Math.round(i)))];
  return { x: r[0] * scale, y: r[1] * scale, width: r[2] * scale, height: r[3] * scale };
};
