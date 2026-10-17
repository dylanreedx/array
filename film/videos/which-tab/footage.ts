// The real-footage half (S4 pull-back, S5 payoff): a harness take of the real app, played through
// kit/footage. The seam reads only the `PULLBACK` object, so changing the take is ONE LINE at the bottom.
//
// REAL: the primary take (tracks/pullback.json `source` names the run; scripts/which-tab-footage.sh imports it) (600 PNGs, 3840x2096,
// 60 fps), copied to public/footage/which-tab/pullback/; tracks/pullback.json is its frames.json cut down
// to the tile rects. Take marks: tight 0 (Cart total ~59% of the width), pullStart 48 (3 s on
// cubic-bezier(.65,0,.35,1)), wide 228, bell 262 (Cart total finishes), focus 264 (a real click on it), and Array's own marching-ants
// border from ~4.48 s (animated; the take steps the Core Animation clock).
//
// STANDIN: the r0 placeholder (one still from full-day v2, its pull-back faked by the film lens), kept
// so the seam can be checked without the take.
import { E } from '../../kit/anim';
import type { FootageKey, Take } from '../../kit/footage';
import { insideCrop, type PlateHandoff } from '../../kit/handoff';
import type { Rect as Frame } from '../../kit/rect';
import type { TabKey } from './constants';
import track from './tracks/pullback.json';
import plateTrack from './tracks/plate.json';

export interface Pullback {
  /** true draws the STAND-IN slate over the footage half */
  standIn: boolean;
  take: Take;
  /** take frames: the camera starts pulling back / the landing agent finishes */
  pullStart: number;
  finishAt: number;
  /** film-lens keys, given the composition frame S4 starts on */
  keys: (s4: number, fps: number) => FootageKey[];
  /** the landing tile (the LANDING tab's agent) in take px at take frame i */
  tile: (i: number) => Frame;
  /** any tab's tile in take px at take frame i (UNSTACK flies every tab window to its own tile) */
  tileOf: (key: TabKey, i: number) => Frame;
  /** the tile that finishes on camera, in take px at take frame i: S5's one lime mark */
  finish: (i: number) => Frame;
}

const px = (r: number[]): Frame => ({ x: r[0] * 2, y: r[1] * 2, width: r[2] * 2, height: r[3] * 2 }); // frames.json points -> 2x px
/** a tile's corner, 23 take px at take frame 0 (zoom 1.667): scales with the tile's width */
export const tileRadius = (tile: Frame) => (23 * tile.width) / 2266.6;
const at = (rects: number[][], i: number) => px(rects[Math.max(0, Math.min(rects.length - 1, Math.round(i)))]);

/**
 * frames.json records a tile only while it is on screen ([0,0,0,0] otherwise: every tile but Cart total
 * and Dark mode until take frame ~140). The camera is a scale + translate, so an unrecorded tile is where
 * Cart total is, plus its offset at the wide frame scaled by the zoom since.
 */
const WIDE = 228;
const tileRects = (key: string, i: number): Frame => {
  const rects = (track.rects as Record<string, number[][]>)[key];
  const j = Math.max(0, Math.min(rects.length - 1, Math.round(i)));
  if (rects[j][2] > 0) return px(rects[j]);
  const c = px(track.rects.cart[j]), cw = px(track.rects.cart[WIDE]), r = px(rects[WIDE]);
  const z = c.width / cw.width;
  return { x: c.x + (r.x - cw.x) * z, y: c.y + (r.y - cw.y) * z, width: r.width * z, height: r.height * z };
};

const REAL_TAKE: Take = { dir: 'which-tab/pullback', frames: track.count, width: 3840, height: 2096 };
/**
 * The take is 3840x2096 (1920x1048 pt at 2x), wider than 16:9, and the window's rounded bottom
 * corners leave transparent wedges in its bottom corners (~30 px) and a 2 px edge at the sides: so
 * cover a 16:9 crop that stops 40 px short of the bottom and clears the sides.
 */
export const REAL_CROP: Frame = { x: (3840 - (2056 * 16) / 9) / 2, y: 0, width: (2056 * 16) / 9, height: 2056 };

export const REAL: Pullback = {
  standIn: false,
  take: REAL_TAKE,
  pullStart: track.marks.pullStart,
  finishAt: track.marks.bell,
  keys: () => [{ at: 0, rect: REAL_CROP, dur: 1 }], // the app's own camera does every move
  tile: (i) => at(track.rects.cart, i),
  tileOf: (key, i) => tileRects(key, i),
  finish: (i) => at(track.rects.cart, i),
};

/** frames.json (full-day-v2 05-busy, frame 1710): rects.planner and rects.picker, in points. */
const STANDIN_TILE = px([1028.5, 97.7, 240.9, 195.7]);
export const STANDIN: Pullback = {
  standIn: true,
  take: { dir: 'which-tab/standin', frames: 1, width: 3840, height: 2096 },
  pullStart: 0,
  finishAt: 0,
  keys: (s4, fps) => {
    // Opens on the tile at ~1.35x of the still's own pixels (crisp), pulls back to the whole frame.
    const s = 1.35, w = 1920 / s, h = 1080 / s;
    const cx = STANDIN_TILE.x + STANDIN_TILE.width / 2, cy = STANDIN_TILE.y + STANDIN_TILE.height / 2;
    return [
      { at: s4, rect: { x: cx - w / 2, y: Math.max(0, cy - h / 2), width: w, height: h }, dur: 1 },
      { at: s4 + Math.round(fps * 0.75), rect: { x: 0, y: 0, width: 3840, height: 2096 }, dur: Math.round(fps * 1.6), ease: E.smooth },
    ];
  },
  tile: () => STANDIN_TILE,
  tileOf: () => STANDIN_TILE,
  finish: () => px([1275, 296.5, 240.9, 195.7]),
};

export const PULLBACK: Pullback = REAL;

/**
 * The PLATE (round 5): the same run with the camera held wide for all 600 frames, so every tile is fully in
 * frame on every frame with the same content as the pull-back (frames 0-599, same content events, same click).
 * A flying card's face is cut from the plate at the SAME take frame, so it is never blank; it hands off to the
 * live pull-back once its tile is fully inside the live frame (index.tsx faceFor).
 * Both takes come in through ONE command: scripts/which-tab-footage.sh <primary dir> <plate dir>.
 */
export interface Plate { take: Take; frame: (i: number) => number; tile: (key: TabKey, i: number) => Frame }
export const PLATE: Plate = {
  take: { dir: 'which-tab/plate', frames: plateTrack.count, width: 3840, height: 2096 },
  frame: (i) => Math.max(0, Math.min(plateTrack.count - 1, Math.round(i))),
  tile: (key, i) => px((plateTrack.rects as Record<string, number[][]>)[key][Math.max(0, Math.min(plateTrack.count - 1, Math.round(i)))]),
};

/**
 * The take frame from which each tile's plate and live pixels are the same (footage agent's parity report,
 * confirmed by phase correlation: Plan picker and Subscriptions are 1-3 px off until the primary's title bar
 * settles). A card stays on the plate until then and only then hands off to the live take, so the swap is
 * invisible. Cart total is live from frame 0 (always in frame), so it never uses the plate.
 */
export const HANDOFF: Record<TabKey, number> = { cart: 0, dark: 238, emails: 238, export: 238, picker: 301, subs: 312 };

/** Is this rect (take px) wholly inside the part of the live take the film shows? */
export const insideLive = insideCrop(REAL_CROP);

/** The hand-off as the kit reads it (kit/handoff.tsx): live pull-back, plate, parity frames, the crop test. */
export const FACES: PlateHandoff<TabKey> = {
  live: PULLBACK.take, liveTile: (key, i) => PULLBACK.tileOf(key, i),
  plate: PLATE.take, plateFrame: PLATE.frame, plateTile: PLATE.tile,
  from: HANDOFF, inside: insideLive,
};
