// The power user's pointer, drawn over real footage from the harness's pointer track (lib/pointer.ts).
// The harness decides WHERE the hand is (the app saw the same drags and pans); this file decides how it
// FEELS: a bubbly coloured arrow that leans into its motion, squashes on press and springs back past
// round on release, rings on a click, and breathes when it has stopped. Every gesture that moves the
// canvas (a hand-grab pan or a pinch zoom) swaps it for one cartoon glove drawn in the arrow's own
// language (filled pink, fat white rim, rounded): open over the canvas, closed while it holds it. There
// is no other gesture glyph; a two-finger scroll stays an arrow.
import { useVideoConfig } from 'remotion';
import { springAt, track, type Spring } from '../../lib/anim';
import { lastEvent, MODES, sample, velocity, type PointerMode, type PointerTrack } from '../../lib/pointer';
import { HAND_F, HAND_LINE, HAND_RIM, type HandGlyph } from './hand-options';

export const PERSONA = '#ff4f8b';
const INK = '#ffffff';
const RIM = 3.4;

/** Playful: visible overshoot for presence pops and the release bounce (a touch slower than r0). */
const PLAY: Spring = { hz: 2.4, zeta: 0.45 };
const PRESS: Spring = { hz: 3.6, zeta: 0.75 };

const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));

type Change = { at: number; mode: PointerMode; down: boolean };
/** Frames where the track's mode or down-state changes, memoised per track. */
const changes = new WeakMap<PointerTrack, Change[]>();
const changesOf = (t: PointerTrack) => {
  let c = changes.get(t);
  if (!c) {
    c = [];
    for (let i = 0; i < t.frames; i++) {
      const [, , d, m] = t.p[i], prev = t.p[i - 1];
      if (!prev || prev[2] !== d || prev[3] !== m) c.push({ at: i, mode: MODES[m], down: d === 1 });
    }
    changes.set(t, c);
  }
  return c;
};

/** [start, end] frames of every canvas pan (panStart .. panEnd events). */
const panIntervals = (t: PointerTrack) => {
  const out: [number, number][] = [];
  let open: number | null = null;
  for (const e of [...t.events].sort((a, b) => a.frame - b.frame)) {
    if (e.type === 'panStart') open = e.frame;
    if (e.type === 'panEnd' && open !== null) { out.push([open, e.frame]); open = null; }
  }
  return out;
};


/** 0..1 presence of a glyph, sprung on every change (pops in past full size, settles). */
const presence = (t: PointerTrack, i: number, fps: number, on: (c: Change) => boolean) => {
  const keys = changesOf(t).map((c) => ({ at: c.at, to: on(c) ? 1 : 0 }));
  const first = keys[0];
  return track(i, fps, first ? first.to : 0, keys.slice(1), PLAY);
};

const Arrow: React.FC = () => (
  // Tip at (0, 0). Rounded joins and a fat white rim read as friendly at video scale.
  <svg width={40} height={52} viewBox="-4 -4 40 52" style={{ position: 'absolute', left: -4, top: -4, overflow: 'visible' }}>
    <path d="M2 2 L2 37 Q2 39.5 4.2 38 L12.4 30.6 L17.6 42.4 Q18.6 44.4 20.6 43.5 L24.4 41.8 Q26.3 40.9 25.4 38.9 L20.3 27.6 L31 27 Q33.6 26.8 31.8 25 L4.6 1.6 Q2 -0.4 2 2 Z"
      fill={PERSONA} stroke={INK} strokeWidth={RIM} strokeLinejoin="round" />
  </svg>
);

// Grabbing the canvas: Dylan's pick (option F of research/17-rebuild/hand-options.html), a puffy cartoon
// glove with a rolled cuff, open while hovering and closed while the canvas is held. Layers paint as one
// silhouette each: white rim first, pink body on top; `lines` are the white finger seams.
const Glove: React.FC<{ g: HandGlyph }> = ({ g }) => (
  <svg width={g.box[2]} height={g.box[3]} viewBox={g.box.join(' ')} overflow="visible"
    style={{ position: 'absolute', left: g.box[0] - g.hot[0], top: g.box[1] - g.hot[1] }}>
    {g.layers.map((l, k) => (
      <g key={k}>
        <g fill={INK} stroke={INK} strokeWidth={HAND_RIM * 2} strokeLinejoin="round">{l.map((d, j) => <path key={j} d={d} />)}</g>
        <g fill={PERSONA}>{l.map((d, j) => <path key={j} d={d} />)}</g>
      </g>
    ))}
    <g fill="none" stroke={INK} strokeWidth={HAND_LINE} strokeLinecap="round">{g.lines.map((d, j) => <path key={j} d={d} />)}</g>
  </svg>
);
/** Drawn at the arrow's units, a closed glove reads small beside it at video size: GLOVE scales it up. */
const GLOVE = 1.35;
const Drag: React.FC<{ closed: number }> = ({ closed }) => (
  <div style={{ position: 'absolute', transform: `scale(${GLOVE})`, transformOrigin: '0 0' }}>
    <div style={{ position: 'absolute', opacity: 1 - closed }}><Glove g={HAND_F.open} /></div>
    <div style={{ position: 'absolute', opacity: closed }}><Glove g={HAND_F.closed} /></div>
  </div>
);

/**
 * The glyphs at one instant, without the track: presences 0..1 (they pop past 1 and settle), `scale`
 * in output px per glyph unit, `lean` in degrees. Exported for the cursor review sheet.
 */
export const CursorGlyphs: React.FC<{ arrow: number; drag: number; closed?: number; scale: number; lean: number; unit: number }> = ({ arrow, drag, closed = 0, scale, lean, unit }) => {
  const layer = (p: number, origin: string, child: React.ReactNode) => p > 0.002 && (
    <div style={{ position: 'absolute', opacity: clamp(p, 0, 1), transform: `scale(${clamp(0.5 + 0.5 * p, 0, 1.25)})`, transformOrigin: origin }}>{child}</div>
  );
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, transform: `rotate(${lean}deg) scale(${scale})`, transformOrigin: '0 0', filter: `drop-shadow(0 ${4 * unit}px ${7 * unit}px rgba(0,0,0,0.45))` }}>
      {layer(arrow, '0 0', <Arrow />)}
      {layer(drag, '0 0', <Drag closed={clamp(closed, 0, 1)} />)}
    </div>
  );
};

/**
 * `i` is the take frame; `map` turns window points into output px; `unit` is output px per design px
 * (height / 1080 at 1:1 framing). `opacity` lets the film hand the pointer off to the lockup. `rate` is
 * the take frames one track frame stands for (a time-lapse's resampled track): the lean and the
 * breathing read the hand's speed in the take's own time, so a 12x sweep does not pin it sideways.
 */
export const HandCursor: React.FC<{ t: PointerTrack; i: number; map: (x: number, y: number) => { x: number; y: number }; unit: number; opacity?: number; rate?: number }> = ({ t, i, map, unit, opacity = 1, rate = 1 }) => {
  const { fps } = useVideoConfig();
  const s = sample(t, i);
  const at = map(s.x, s.y);
  const v = velocity(t, i), vx = v.vx / rate, vy = v.vy / rate;
  const speed = Math.hypot(vx, vy);

  // The arrow stays an arrow for clicks, card drags (direct manipulation: the card is the feedback) and
  // two-finger scrolls; the glove appears only for grabbing the canvas itself.
  const pans = panIntervals(t);
  const inPan = (f: number) => pans.some(([a, b]) => f >= a && f <= b);
  const dragLike = (c: Change) => c.mode === 'hand' || c.mode === 'pinch' || (c.mode === 'grab' && inPan(c.at));
  const arrow = presence(t, i, fps, (c) => !dragLike(c));
  const drag = presence(t, i, fps, dragLike);
  // A pinch holds the canvas the way a grab does: the glove closes for it too.
  const pinch = presence(t, i, fps, (c) => c.mode === 'pinch');
  // Press squashes fast and critically; release springs back past round.
  const press = track(i, fps, 0, changesOf(t).map((c) => ({ at: c.at, to: c.down ? 1 : 0, spring: c.down ? PRESS : PLAY })), PRESS);

  // Lean into the motion (degrees), a touch bigger when quick, and breathe when still.
  const lean = clamp(vx * 0.9, -14, 14);
  const excite = 1 + clamp(speed * 0.004, 0, 0.07);
  let still = 0;
  for (let k = 0; k < 40 && speed < 0.25; k++) { if (Math.hypot(velocity(t, i - k).vx, velocity(t, i - k).vy) / rate >= 0.25) break; still = k; }
  const breathe = still > 24 ? Math.sin(((i - 24) / fps) * Math.PI * 2 * 0.75) * 1.6 * unit * Math.min(1, (still - 24) / 12) : 0;
  const scale = unit * 1.15 * excite * (1 - 0.16 * press);

  // A click (or a drop) rings out from the tip.
  const RING = 32;
  const ago = lastEvent(t, i, ['click', 'press', 'drop', 'release']);
  const ring = ago <= RING ? ago / RING : -1;
  const grow = ring >= 0 ? springAt(ring * 0.55, { hz: 2, zeta: 1 }) : 0;

  return (
    <div style={{ position: 'absolute', left: at.x, top: at.y + breathe, width: 0, height: 0, opacity, pointerEvents: 'none' }}>
      {ring >= 0 && (
        <div style={{ position: 'absolute', left: -60 * unit * grow, top: -60 * unit * grow, width: 120 * unit * grow, height: 120 * unit * grow, borderRadius: '50%', border: `${4 * unit}px solid ${PERSONA}`, opacity: 0.7 * (1 - ring) }} />
      )}
      <CursorGlyphs arrow={arrow} drag={drag} closed={Math.max(press, pinch)} scale={scale} lean={lean} unit={unit} />
    </div>
  );
};
