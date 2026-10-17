// The film camera. It never moves the app: it scales and translates the whole stage so a
// SUBJECT (a tile, a zone, a world rect, the whole window) fills the output with padding. Because
// keys name subjects rather than pixels, one timeline frames correctly at 16:9, 1:1 and 9:16:
// portrait simply fits the same tile into a tall box (pan-and-scan), and the app keeps its native
// 1380x810 geometry instead of reflowing into a layout the website never ships.
import { createContext, useContext } from 'react';
import { useCurrentFrame, useVideoConfig } from 'remotion';
import type { StageMetrics } from './metrics';
import type { DemoState, Frame } from '@website/features/demo/types';
import { E, prog } from './anim';
import type { FocusTarget, LensKey } from './sheet';
import { STAGE, WINDOW_ORIGIN, type Band } from './formats';

export interface LensTransform { scale: number; x: number; y: number }
export interface LensValue extends LensTransform {
  /** subject rect in OUTPUT px, for overlays */
  outRect: (focus: FocusTarget) => Frame;
  /** the output size (the composition, or a contact-sheet cell's viewport) */
  output: { width: number; height: number };
  /** the part of the stage in view, in STAGE px */
  visible: Frame;
  /** output px per app UI px when UI is drawn at the Mac camera's zoom (WebsiteStage commandCenter="frame") */
  uiScale: number;
  /** the part of the output subjects are framed in: the output minus the caption band, in output px */
  box: Frame;
}
const LensContext = createContext<LensValue>({ scale: 1, x: 0, y: 0, outRect: () => ({ x: 0, y: 0, width: 0, height: 0 }), output: { width: 0, height: 0 }, visible: { x: 0, y: 0, width: 0, height: 0 }, uiScale: 1, box: { x: 0, y: 0, width: 0, height: 0 } });
export const useLens = () => useContext(LensContext);
/** stage px -> output px, for overlays that point at things inside the app */
export const toOutput = (l: LensTransform, p: { x: number; y: number }) => ({ x: l.x + p.x * l.scale, y: l.y + p.y * l.scale });

const resolve = (focus: FocusTarget, s: DemoState, canvas: { x: number; y: number }): Frame => {
  const cam = s.macCamera;
  // MacWorkspace translates the world by whole pixels (Math.round), so the lens does too: a subject
  // resolves to exactly where the website drew it.
  const world = (f: Frame): Frame => ({ x: canvas.x + Math.round(cam.x) + f.x * cam.zoom, y: canvas.y + Math.round(cam.y) + f.y * cam.zoom, width: f.width * cam.zoom, height: f.height * cam.zoom });
  if ('tile' in focus) return world(s.tiles[focus.tile].frame);
  if ('zone' in focus) return world(s.zones[focus.zone].frame);
  if ('world' in focus) return world(focus.world);
  if ('rect' in focus) return focus.rect;
  return { x: WINDOW_ORIGIN.x, y: WINDOW_ORIGIN.y, width: STAGE.window.width, height: STAGE.window.height };
};

const fit = (r: Frame, box: Frame, pad: number): LensTransform => {
  const scale = Math.min(box.width / (r.width + 2 * pad), box.height / (r.height + 2 * pad));
  return { scale, x: box.x + box.width / 2 - (r.x + r.width / 2) * scale, y: box.y + box.height / 2 - (r.y + r.height / 2) * scale };
};

// a*(1-t) + b*t is exactly b at t=1 (a + (b-a)*t is not), so a lens that returns to its first
// framing returns to it bit for bit, and a looping video's last frame matches its first.
const lerp = (a: number, b: number, t: number) => a * (1 - t) + b * t;

export const Lens: React.FC<{ keys: LensKey[]; state: DemoState; metrics: StageMetrics | null; viewport?: { width: number; height: number }; band?: Band | null; children: React.ReactNode; overlay?: React.ReactNode }> = ({ keys, state, metrics, viewport, band, children, overlay }) => {
  const frame = useCurrentFrame();
  const config = useVideoConfig();
  const { fps } = config;
  const { width, height } = viewport ?? config;
  const output = { width, height };
  const box: Frame = !band ? { x: 0, y: 0, width, height } : band.edge === 'top' ? { x: 0, y: band.size, width, height: height - band.size } : { x: 0, y: 0, width, height: height - band.size };
  const canvas = metrics?.origin ?? { x: WINDOW_ORIGIN.x, y: WINDOW_ORIGIN.y + 44 };
  const sorted = [...keys].sort((a, b) => a.at - b.at);
  const focusOf = (k: LensKey | undefined): FocusTarget => !k ? { whole: true } : typeof k.focus === 'function' ? k.focus({ width: box.width, height: box.height }) : k.focus;
  const rectOf = (k: LensKey | undefined) => resolve(focusOf(k), state, canvas);
  let i = sorted.findIndex((k) => k.at > frame) - 1;
  if (i < -1) i = sorted.length - 1;
  const cur = sorted[i];
  const prev = sorted[i - 1];
  const dur = cur?.dur ?? Math.round(fps * 0.9);
  const t = cur ? prog(frame, cur.at, cur.at + dur, cur.ease ?? E.cam) : 1;
  const a = rectOf(prev ?? cur), b = rectOf(cur);
  const r: Frame = { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t) };
  const pad = lerp(prev?.pad ?? cur?.pad ?? 48, cur?.pad ?? 48, t);
  const lens = fit(r, box, pad);
  const outRect = (focus: FocusTarget): Frame => {
    const q = resolve(focus, state, canvas);
    return { x: lens.x + q.x * lens.scale, y: lens.y + q.y * lens.scale, width: q.width * lens.scale, height: q.height * lens.scale };
  };
  const visible: Frame = { x: -lens.x / lens.scale, y: -lens.y / lens.scale, width: width / lens.scale, height: height / lens.scale };
  return (
    <LensContext.Provider value={{ ...lens, outRect, output, visible, uiScale: lens.scale * state.macCamera.zoom, box }}>
      <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background: '#0b0d10' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: STAGE.width, height: STAGE.height, transformOrigin: '0 0', transform: `translate(${lens.x}px, ${lens.y}px) scale(${lens.scale})` }}>
          {children}
        </div>
        {overlay}
      </div>
    </LensContext.Provider>
  );
};
