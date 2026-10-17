// The pointer track: where the user's hand was on every frame of a real-footage take, as the harness
// drove it (frames.json v2 `pointer`, `rects`, `events`, `viewport`), compacted by scripts/track.py.
// Everything here is a pure function of the frame, so the cursor, its caption bubble and any framing
// that follows the hand stay deterministic: frame 812 never depends on having rendered frame 811.

export type PointerMode = 'arrow' | 'hand' | 'grab' | 'pinch' | 'scroll';
export const MODES: PointerMode[] = ['arrow', 'hand', 'grab', 'pinch', 'scroll'];

export interface PointerTrack {
  fps: number;
  /** the take's window in points; footage pixels are 2x */
  pointSize: [number, number];
  frames: number;
  /** per frame: x, y (window points, top-left), down 0|1, index into MODES */
  p: [number, number, number, number][];
  /** per frame: the canvas viewport x, y, zoom */
  v: [number, number, number][];
  /** per frame rect of a tile/card in window points, or null when off-window */
  rects: Record<string, ([number, number, number, number] | null)[]>;
  events: { frame: number; type: string }[];
  marks: Record<string, number>;
  /** frames.json `keys`: shortcuts and typing (video 2's key caps) */
  keys?: { frame: number; label: string; kind: 'press' | 'holdStart' | 'holdEnd' | 'type'; text?: string }[];
  /** frames.json `menus`: menus production built, which the overlay redraws */
  menus?: { frame: number; kind: 'open' | 'choose' | 'dismiss'; anchor?: [number, number]; title?: string; items?: unknown[]; path?: string[] }[];
}

export interface Sample { x: number; y: number; down: boolean; mode: PointerMode }

const clampI = (t: PointerTrack, i: number) => Math.max(0, Math.min(t.frames - 1, Math.round(i)));

export const sample = (t: PointerTrack, i: number): Sample => {
  const [x, y, d, m] = t.p[clampI(t, i)];
  return { x, y, down: d === 1, mode: MODES[m] ?? 'arrow' };
};

/**
 * The hand smoothed over the last `n` frames (a triangular window, newest heaviest): a lag that reads as
 * something attached to the cursor by a short spring, without simulating. n = 1 is the raw position.
 */
export const lagged = (t: PointerTrack, i: number, n = 6) => {
  let x = 0, y = 0, w = 0;
  for (let k = 0; k < n; k++) {
    const s = sample(t, i - k), wk = n - k;
    x += s.x * wk; y += s.y * wk; w += wk;
  }
  return { x: x / w, y: y / w };
};

/** Smoothed velocity in points per frame (difference of two short lags, so a step reads as a swing). */
export const velocity = (t: PointerTrack, i: number) => {
  const a = lagged(t, i, 4), b = lagged(t, i - 3, 4);
  return { vx: (a.x - b.x) / 3, vy: (a.y - b.y) / 3 };
};

/** Frames since the mode last changed to `mode` at or before i (Infinity if never). */
export const since = (t: PointerTrack, i: number, test: (s: Sample) => boolean) => {
  let k = clampI(t, i);
  if (!test(sample(t, k))) return Infinity;
  while (k > 0 && test(sample(t, k - 1))) k--;
  return i - k;
};

/** The most recent event of `type` at or before i, as frames ago. */
export const lastEvent = (t: PointerTrack, i: number, types: string[]) => {
  let best = Infinity;
  for (const e of t.events) if (types.includes(e.type) && e.frame <= i) best = Math.min(best, i - e.frame);
  return best;
};

export const rectAt = (t: PointerTrack, key: string, i: number) => t.rects[key]?.[clampI(t, i)] ?? null;
