// Hand-cursor candidates for canvas grabs, drawn in the arrow's language (HandCursor.tsx): pink body, fat
// white rim, rounded everything. Each option is a pair, `open` (hovering, about to grab) and `closed`
// (pressed, dragging the canvas). Preview: .plans/68-launch-film/research/17-rebuild/hand-options.html.
//
// A glyph is a stack of LAYERS. Each layer is a set of shapes painted as ONE silhouette: first every shape
// in white with a 2 x RIM stroke (the rim, outside the shape), then every shape in pink on top. So
// overlapping shapes merge into one body, a gap of g between two shapes reads as a white seam of width g,
// and a later layer (a thumb across a palm) gets its own rim over the earlier one. `lines` are white
// strokes (HAND_LINE wide, round caps) painted last: finger seams and knuckle creases.
//
// Units match the arrow's viewBox (the arrow is 32 x 44); render at the arrow's scale. `hot` is the hot
// spot in glyph units: put it on the pointer.
//
// Wiring (HandCursor.tsx), roughly:
//   const Hand = ({ g }: { g: HandGlyph }) => (
//     <svg width={g.box[2]} height={g.box[3]} viewBox={g.box.join(' ')} overflow="visible"
//       style={{ position: 'absolute', left: g.box[0] - g.hot[0], top: g.box[1] - g.hot[1] }}>
//       {g.layers.map((l, k) => <g key={k}>
//         <g fill={INK} stroke={INK} strokeWidth={HAND_RIM * 2} strokeLinejoin="round">{l.map((d, j) => <path key={j} d={d} />)}</g>
//         <g fill={PERSONA}>{l.map((d, j) => <path key={j} d={d} />)}</g>
//       </g>)}
//       <g fill="none" stroke={INK} strokeWidth={HAND_LINE} strokeLinecap="round">{g.lines.map((d, j) => <path key={j} d={d} />)}</g>
//     </svg>);

export const HAND_RIM = 3.4;
export const HAND_LINE = 2.2;

export type HandGlyph = {
  /** viewBox [x, y, w, h] covering the glyph and its rim. */
  box: [number, number, number, number];
  /** Hot spot in glyph units. */
  hot: [number, number];
  layers: string[][];
  lines: string[];
};
export type HandOption = { id: string; name: string; note: string; open: HandGlyph; closed: HandGlyph };

type P = [number, number];
const f = (v: number) => +v.toFixed(2);
/** Drawing scale: shapes are authored large and shrunk so the hand carries the arrow's visual weight; the rim is not scaled. */
const K = 0.9;

/** A capsule (a finger) from base to tip with radius r. */
const cap = (x1: number, y1: number, x2: number, y2: number, r: number) => {
  [x1, y1, x2, y2, r] = [x1 * K, y1 * K, x2 * K, y2 * K, r * K];
  const l = Math.hypot(x2 - x1, y2 - y1), nx = ((y2 - y1) / l) * r, ny = (-(x2 - x1) / l) * r;
  return `M${f(x1 + nx)} ${f(y1 + ny)} L${f(x2 + nx)} ${f(y2 + ny)} A${r} ${r} 0 0 1 ${f(x2 - nx)} ${f(y2 - ny)} L${f(x1 - nx)} ${f(y1 - ny)} A${r} ${r} 0 0 1 ${f(x1 + nx)} ${f(y1 + ny)} Z`;
};

/** A closed polygon with each corner rounded by a quadratic (one radius per corner, or one for all). */
const poly = (raw: P[], radii: number | number[]) => {
  const pts = raw.map(([x, y]) => [x * K, y * K] as P), n = pts.length;
  let d = '';
  for (let k = 0; k < n; k++) {
    const p0 = pts[(k + n - 1) % n], p1 = pts[k], p2 = pts[(k + 1) % n];
    const r = (typeof radii === 'number' ? radii : radii[k % radii.length]) * K;
    const along = (b: P) => {
      const len = Math.hypot(b[0] - p1[0], b[1] - p1[1]), t = Math.min(r / len, 0.5);
      return `${f(p1[0] + (b[0] - p1[0]) * t)} ${f(p1[1] + (b[1] - p1[1]) * t)}`;
    };
    d += `${k ? 'L' : 'M'}${along(p0)} Q${p1[0]} ${p1[1]} ${along(p2)} `;
  }
  return `${d}Z`;
};

/** An open polyline or quadratic stroke for `lines`. */
const seg = (x1: number, y1: number, x2: number, y2: number) => `M${f(x1 * K)} ${f(y1 * K)} L${f(x2 * K)} ${f(y2 * K)}`;
const arc = (x1: number, y1: number, cx: number, cy: number, x2: number, y2: number) => `M${f(x1 * K)} ${f(y1 * K)} Q${f(cx * K)} ${f(cy * K)} ${f(x2 * K)} ${f(y2 * K)}`;

const glyph = (box: [number, number, number, number], hot: P, layers: string[][], lines: string[] = []): HandGlyph =>
  ({ box: box.map((v) => f(v * K)) as HandGlyph['box'], hot: [f(hot[0] * K), f(hot[1] * K)], layers, lines });

// A: classic. macOS's open/closed hand redrawn chunky: four fanned fingers and a thumb splayed out; closed
// shows the knuckle row with the thumb folded in front.
const A_PALM_OPEN = poly([[-13, -3], [14.5, -3], [15, 8], [9, 19], [-7, 19], [-13.5, 9]], [3, 3, 5, 4, 4, 5]);
export const HAND_A: HandOption = {
  id: 'A', name: 'Classic', note: 'macOS anatomy: four fanned fingers, thumb out; closed shows the knuckle row with the thumb tucked at the side',
  open: glyph([-28, -28, 50, 52], [1, 4], [[
    cap(-9.5, 2, -12.5, -16.5, 3.4),
    cap(-2.5, 2, -3, -20.5, 3.4),
    cap(4.5, 2, 6, -18.5, 3.4),
    cap(11, 4, 14.5, -11.5, 3.4),
    cap(-10, 10, -21, -1, 3.6),
    A_PALM_OPEN,
  ]]),
  closed: glyph([-28, -28, 50, 52], [1, 3], [[
    cap(-8.6, -2, -8.6, -6.5, 3.6),
    cap(-1.6, -2, -1.6, -8, 3.6),
    cap(5.4, -2, 5.4, -7, 3.6),
    cap(12, -1, 12, -4.5, 3.4),
    cap(-10.5, 7, -15.5, 0.5, 3.8),
    poly([[-12.4, -4], [15.4, -4], [15.4, 6], [9.5, 15.5], [-6, 15.5], [-12.6, 7]], [3, 3, 6, 5, 5, 6]),
  ]], [seg(-5.1, -8, -5.1, -3), seg(1.9, -9, 1.9, -3), seg(8.8, -8, 8.8, -2.5)]),
};

// B: mitten. One rounded lobe for the fingers and one for the thumb: the most cartoon-friendly, fewest parts.
export const HAND_B: HandOption = {
  id: 'B', name: 'Mitten', note: 'one finger lobe plus a thumb lobe, no seams; closed is the lobe curled short, thumb tucked, three knuckle ticks on top',
  open: glyph([-28, -28, 50, 52], [1, 5], [[
    poly([[-10.5, 19], [-12, -20], [13, -20], [12.5, 19]], [5, 12, 12, 5]),
    cap(-8, 9, -20.5, -3.5, 4.6),
  ]]),
  closed: glyph([-28, -28, 50, 52], [1, 3], [[
    poly([[-12, 15], [-12.5, -8], [13.5, -8], [13, 15]], [7, 10, 10, 7]),
    cap(-10, 8.5, -17, 1.5, 4.4),
  ]], [seg(-6.5, -9.5, -6.5, -5), seg(0.5, -10.5, 0.5, -5), seg(7.5, -9.5, 7.5, -5)]),
};

// C: three chunky fingers. Fat sausage fingers, big palm: the toy version, readable at any size.
export const HAND_C: HandOption = {
  id: 'C', name: 'Chunky three', note: 'three fat fingers and a thumb, cartoon-glove proportions; closed is three fat knuckles',
  open: glyph([-30, -28, 54, 52], [1, 5], [[
    cap(-10, 2, -12.5, -14.5, 4.5),
    cap(0.5, 2, 0.5, -19, 4.5),
    cap(10.5, 3, 13, -13.5, 4.5),
    cap(-11, 10, -22.5, 0.5, 4.6),
    poly([[-15, -2], [16, -2], [16, 8], [10, 19.5], [-8.5, 19.5], [-15.5, 9]], [4, 4, 6, 5, 5, 6]),
  ]]),
  closed: glyph([-30, -28, 54, 52], [1, 3], [[
    cap(-9.6, -1, -9.6, -5, 4.6),
    cap(0.5, -1, 0.5, -7, 4.6),
    cap(10.6, -1, 10.6, -4, 4.6),
    cap(-11.5, 7, -17.5, -0.5, 4.4),
    poly([[-14.5, -3], [15.5, -3], [15.5, 6], [10, 16], [-8, 16], [-15, 8]], [4, 4, 7, 5, 5, 6]),
  ]], [seg(-4.6, -7, -4.6, -2), seg(5.6, -7, 5.6, -2)]),
};

// D: fist. Open is a flat hand with the fingers held together (seams drawn in white); closed is a front-on
// fist: a scalloped knuckle row, a crease where the fingertips tuck under, the thumb wrapped across.
export const HAND_D: HandOption = {
  id: 'D', name: 'Fist', note: 'flat hand with fingers held together; closed is a front-on fist, knuckle seams, the thumb wrapped across',
  open: glyph([-28, -28, 50, 52], [1, 5], [[
    cap(-9.3, 0, -9.3, -15.5, 3.6),
    cap(-2.3, 0, -2.3, -19.5, 3.6),
    cap(4.7, 0, 4.7, -17.5, 3.6),
    cap(11.5, 2, 11.5, -12, 3.6),
    cap(-10, 10, -18, 2, 3.7),
    poly([[-13, -4], [15, -4], [15.1, 8], [9.5, 19], [-7, 19], [-13.5, 9]], [3, 3, 5, 4, 4, 5]),
  ]], [seg(-5.8, -14, -5.8, -1), seg(1.2, -16, 1.2, -1), seg(8.1, -13, 8.1, 0)]),
  closed: glyph([-28, -28, 50, 52], [1, 3], [[
    cap(-8.6, -2, -8.6, -6.5, 3.6),
    cap(-1.6, -2, -1.6, -8, 3.6),
    cap(5.4, -2, 5.4, -7, 3.6),
    cap(12, -1, 12, -4.5, 3.4),
    poly([[-12.6, -4], [15.4, -4], [15.4, 6], [9.5, 15.5], [-6, 15.5], [-12.6, 7]], [3, 3, 6, 5, 5, 6]),
  ], [
    poly([[-15, 0.5], [4.5, 1.5], [4.5, 8.5], [-13.5, 9]], [3.5, 3.4, 3.4, 4]),
  ]], [seg(-5.1, -8, -5.1, -3), seg(1.9, -9, 1.9, -3), seg(8.8, -8, 8.8, -2.5)]),
};

// E: seams. One continuous silhouette, the fingers touching, separated only by long white seams that run
// into the palm; closed folds the fingers down to a row of seamed knuckles over a fingertip crease.
export const HAND_E: HandOption = {
  id: 'E', name: 'Seams', note: 'single silhouette, long white finger seams into the palm; closed is a seamed knuckle row over a fingertip crease',
  open: glyph([-28, -28, 50, 52], [1, 5], [[
    cap(-9, 2, -10.5, -16, 3.5),
    cap(-2.4, 2, -2.8, -20, 3.5),
    cap(4.2, 2, 5, -18.5, 3.5),
    cap(10.6, 3, 12.2, -12.5, 3.5),
    cap(-9, 10, -20, -1.5, 3.7),
    poly([[-12.6, -3], [15, -3], [15.3, 8], [9.5, 19], [-7, 19], [-13.2, 9]], [3, 3, 5, 4, 4, 5]),
  ]], [arc(-6.7, -15.5, -6.2, -6, -5.6, 5), arc(0.6, -17.5, 0.8, -6, 1, 5.5), arc(8.5, -14, 7.8, -5, 7.6, 6)]),
  closed: glyph([-28, -28, 50, 52], [1, 3], [[
    cap(-8.6, -2, -8.6, -6.5, 3.6),
    cap(-1.6, -2, -1.6, -8, 3.6),
    cap(5.4, -2, 5.4, -7, 3.6),
    cap(12, -1, 12, -4.5, 3.4),
    cap(-10.5, 7.5, -15.5, 1, 3.8),
    poly([[-12.4, -4], [15.4, -4], [15.4, 6], [9.5, 15.5], [-6, 15.5], [-12.6, 7]], [3, 3, 6, 5, 5, 6]),
  ]], [seg(-5.1, -8, -5.1, 0.5), seg(1.9, -9, 1.9, 0.5), seg(8.8, -8, 8.8, 1), arc(-8, 2.5, 3, 5.5, 13, 3)]),
};

// F: glove. A cartoon glove: puffy fingers and a rolled cuff at the wrist, the cuff alone says "hand".
export const HAND_F: HandOption = {
  id: 'F', name: 'Glove', note: 'puffy cartoon glove with a rolled cuff at the wrist; the cuff reads as a hand at any size',
  open: glyph([-28, -30, 50, 56], [1, 2], [[
    cap(-9.6, 0, -12.3, -17, 3.7),
    cap(-2.2, 0, -2.6, -21, 3.7),
    cap(5.2, 0, 6.6, -19, 3.7),
    cap(11.8, 2, 15, -12, 3.7),
    cap(-10, 7, -21, -3, 3.8),
    poly([[-13.5, -4], [15.5, -4], [15.5, 7], [10, 15], [-7.5, 15], [-14, 7]], [3, 3, 5, 3, 3, 5]),
  ], [
    poly([[-11.5, 13], [13, 13], [13.5, 21.5], [-12, 21.5]], 3.6),
  ]]),
  closed: glyph([-28, -30, 50, 56], [1, 2], [[
    cap(-8.8, -3, -8.8, -7.5, 3.9),
    cap(-1.2, -3, -1.2, -9, 3.9),
    cap(6.4, -3, 6.4, -8, 3.9),
    cap(13, -2, 13, -5.5, 3.7),
    cap(-10.5, 5, -16, -2, 3.9),
    poly([[-13, -5], [16.6, -5], [16.6, 6], [10.5, 14.5], [-7.5, 14.5], [-13.5, 6]], [3, 3, 5, 3, 3, 5]),
  ], [
    poly([[-11, 12.5], [13.5, 12.5], [14, 21], [-11.5, 21]], 3.6),
  ]], [seg(-5, -9, -5, -4), seg(2.6, -10, 2.6, -4), seg(9.8, -9, 9.8, -3.5)]),
};

export const HAND_OPTIONS: HandOption[] = [HAND_A, HAND_B, HAND_C, HAND_D, HAND_E, HAND_F];
