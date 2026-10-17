// The full-day film's five chapter transitions (preview). Each is themed on its time of day, runs
// 4.5-5 s, and ends with the clock chip docking in the corner over the next chapter's footage.
// Footage comes in as feeds: `before` plays on from where the last chapter stopped, `after` starts
// the next chapter, and heads down sweeps through `lapse`. With no feeds (the previews) it is the
// power-tour take standing in for the day's chapters.
import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { E, SPRING, mix, prog, rand, springAt } from '../../lib/anim';
import { CAPTION_FONT } from '../../lib/fonts';
import type { PointerTrack } from '../../lib/pointer';
import { HandCursor } from '../../acts/edu/HandCursor';
import { CaptionGlyph } from '../../acts/edu/Icon';
import type { CaptionIcon } from '../../lib/sheet';
import { ChapterPill, ClockChip, Glyph, H, NIGHT, PINK, PLUM, POP, Shot, W, WHITE, mixColor } from './kit';

/** Footage `n` frames into a feed (a take from some frame on), optionally styled (opacity for the shutter). */
export type Feed = (n: number, style?: React.CSSProperties) => React.ReactNode;
const stand = (start: number): Feed => (n, style) => <Shot frame={start + n} style={style} />;
export interface Feeds { before?: Feed; after?: Feed }
export interface Lapse { src: Feed; length: number }

const DOCK = { hz: 1.6, zeta: 0.78 };

// ---- 1 · Sunrise: the sun rises over a white horizon, its rays pop, and it opens as an iris onto the canvas.
export const T1_DUR = 270;
export const Sunrise: React.FC<Feeds> = ({ after = stand(110) }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cx = W / 2, horizon = 690;
  const rise = springAt((f - 10) / fps, { hz: 0.75, zeta: 0.62 });
  const sunR = 120;
  const sunY = mix(horizon + sunR + 40, horizon - 190, rise);
  const dawn = prog(f, 0, 140, E.smooth);
  const swell = prog(f, 128, 160, E.inOut);
  const open = prog(f, 150, 222, E.inOut);
  const irisR = mix(sunR * 1.25, 2300, open);
  const dock = springAt((f - 200) / fps, DOCK);
  const count = prog(f, 80, 150, E.out);
  const mins = mix(6 * 60, 8 * 60 + 45, count);
  return (
    <AbsoluteFill style={{ background: NIGHT, overflow: 'hidden' }}>
      {/* sky and ground */}
      <AbsoluteFill style={{ background: `linear-gradient(180deg, ${mixColor('#0b0d10', '#3a1846', dawn)} 0%, ${mixColor('#121019', '#ff8fb3', dawn)} ${(horizon / H) * 100}%, ${mixColor('#0d0b12', '#2a1230', dawn)} ${(horizon / H) * 100}%, ${mixColor('#0b0d10', '#170a1c', dawn)} 100%)` }} />
      {/* night stars fade as dawn comes */}
      {Array.from({ length: 18 }, (_, i) => (
        <div key={i} style={{ position: 'absolute', left: rand(i) * W, top: rand(i + 50) * horizon * 0.8, width: 4, height: 4, borderRadius: 4, background: WHITE, opacity: (1 - dawn) * (0.4 + 0.6 * rand(i + 9)) }} />
      ))}
      {/* sun and rays, clipped at the horizon */}
      <div style={{ position: 'absolute', inset: 0, clipPath: `inset(0 0 ${H - horizon}px 0)`, transform: `scale(${1 + 0.18 * swell})`, transformOrigin: `${cx}px ${sunY}px` }}>
        {Array.from({ length: 12 }, (_, i) => {
          const k = springAt((f - 44 - i * 2.2) / fps, POP);
          const a = i * 30 + f * 0.25;
          const d = sunR + 34 + 18 * k;
          return <div key={i} style={{ position: 'absolute', left: cx - 9, top: sunY - d - 46, width: 18, height: 46 * Math.max(0, k), borderRadius: 18, background: WHITE, transformOrigin: `9px ${d + 46}px`, transform: `rotate(${a}deg)` }} />;
        })}
        <div style={{ position: 'absolute', left: cx - sunR, top: sunY - sunR, width: sunR * 2, height: sunR * 2, borderRadius: '50%', background: PINK, border: `10px solid ${WHITE}`, boxSizing: 'border-box', boxShadow: `0 0 120px ${PINK}` }} />
      </div>
      {/* horizon line and a few ground dashes */}
      <div style={{ position: 'absolute', left: cx - 700 * prog(f, 0, 40, E.out), top: horizon - 5, width: 1400 * prog(f, 0, 40, E.out), height: 10, borderRadius: 10, background: WHITE }} />
      {[[-420, 70, 160], [260, 110, 220], [-120, 160, 120]].map(([dx, dy, w], i) => (
        <div key={i} style={{ position: 'absolute', left: cx + dx, top: horizon + dy, width: w * prog(f, 20 + i * 8, 60 + i * 8, E.out), height: 8, borderRadius: 8, background: 'rgba(255,255,255,0.35)' }} />
      ))}
      <ChapterPill text="Good morning." f={f} from={62} to={176} x={cx} y={horizon + 118} fps={fps} />
      {/* the iris: the canvas opens out of the sun, rimmed pink and white */}
      {f >= 150 && (
        <>
          <AbsoluteFill style={{ clipPath: `circle(${irisR}px at ${cx}px ${sunY}px)` }}>{after(f - 150)}</AbsoluteFill>
          <div style={{ position: 'absolute', left: cx - irisR - 34, top: sunY - irisR - 34, width: (irisR + 34) * 2, height: (irisR + 34) * 2, borderRadius: '50%', border: `24px solid ${PINK}`, outline: `10px solid ${WHITE}`, outlineOffset: -44, boxSizing: 'border-box', opacity: 1 - prog(f, 200, 222, E.linear) }} />
        </>
      )}
      <ClockChip mins={mins} icon="sun" dock={dock} x0={cx} y0={horizon + 250} big={1.9} opacity={prog(f, 84, 96, E.cssOut)} />
    </AbsoluteFill>
  );
};

// ---- 2 · Coffee: pink coffee pours up over the canvas, a mug steams, the time runs on, and it drains away.
export const T2_DUR = 270;
const surface = (level: number, f: number, amp: number, phase: number) => {
  const pts: string[] = [];
  for (let x = -20; x <= W + 20; x += 20) pts.push(`${x},${level + amp * Math.sin(x / 210 + f * 0.11 + phase) + amp * 0.5 * Math.sin(x / 93 - f * 0.17 + phase)}`);
  return pts;
};
export const Coffee: React.FC<Feeds> = ({ before = stand(640), after = stand(1250) }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const up = prog(f, 26, 96, E.inOut);
  const down = prog(f, 172, 236, E.inOut);
  const level = mix(H + 120, -120, up * (1 - down));
  const moving = Math.sin(Math.PI * up) + Math.sin(Math.PI * down);
  const amp = 18 + 22 * moving;
  const front = surface(level, f, amp, 0), back = surface(level - 46, f, amp * 0.8, 2.1);
  const mug = springAt((f - 92) / fps, POP) - springAt((f - 168) / fps, SPRING.snappy);
  const count = prog(f, 112, 160, E.out);
  const dock = springAt((f - 214) / fps, DOCK);
  const steam = (i: number) => prog(f, 108 + i * 7, 150 + i * 7, E.out);
  return (
    <AbsoluteFill style={{ background: NIGHT, overflow: 'hidden' }}>
      {f < 130 ? before(f) : after(f - 130)}
      <ClockChip mins={8 * 60 + 45} icon="sun" dock={1} />
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
        <polygon points={[...back, `${W + 20},${H + 20}`, `-20,${H + 20}`].join(' ')} fill="#ff86ad" />
        <polygon points={[...front, `${W + 20},${H + 20}`, `-20,${H + 20}`].join(' ')} fill={PINK} />
        <polyline points={front.join(' ')} fill="none" stroke={WHITE} strokeWidth={10} strokeLinejoin="round" strokeLinecap="round" />
        {Array.from({ length: 16 }, (_, i) => {
          const t = ((f * (1.4 + rand(i) * 1.6) + rand(i + 3) * 900) % 900);
          const y = H + 40 - t;
          if (y < level + 30) return null;
          return <circle key={i} cx={rand(i + 7) * W} cy={y} r={6 + rand(i + 1) * 12} fill="none" stroke="rgba(255,255,255,0.75)" strokeWidth={4} />;
        })}
      </svg>
      {/* the mug */}
      <div style={{ position: 'absolute', left: W / 2 - 150, top: 330, width: 300, height: 300, transform: `scale(${Math.max(0, mug)}) rotate(${(1 - Math.min(1, mug)) * -12}deg)`, transformOrigin: '50% 80%' }}>
        <svg width={300} height={300} viewBox="0 0 300 300">
          {[0, 1, 2].map((i) => (
            <path key={i} d={`M${110 + i * 40} 108 c -22 -22 22 -36 0 -58 c -16 -16 10 -28 0 -40`} fill="none" stroke={WHITE} strokeWidth={12} strokeLinecap="round"
              pathLength={1} strokeDasharray={1} strokeDashoffset={1 - steam(i)} transform={`translate(0 ${-10 * Math.sin(f * 0.08 + i)})`} />
          ))}
          <path d="M224 160 h18 a34 34 0 0 1 0 68 h-22" fill="none" stroke={WHITE} strokeWidth={16} strokeLinecap="round" />
          <path d="M64 132 h170 v86 a58 58 0 0 1 -58 58 h-54 a58 58 0 0 1 -58 -58 z" fill={WHITE} />
          <ellipse cx={149} cy={133} rx={80} ry={10} fill={PLUM} opacity={0.18} />
          <path d="M149 232 c -30 -20 -44 -34 -44 -50 a 20 20 0 0 1 44 -8 a 20 20 0 0 1 44 8 c 0 16 -14 30 -44 50 z" fill={PINK} transform={`translate(149 200) scale(${springAt((f - 128) / fps, POP)}) translate(-149 -200)`} />
        </svg>
      </div>
      <ChapterPill text="Second coffee." f={f} from={116} to={196} x={W / 2} y={712} fps={fps} />
      <ClockChip mins={mix(8 * 60 + 45, 10 * 60 + 30, count)} icon="mug" dock={dock} x0={W / 2} y0={830} opacity={prog(f, 112, 124, E.cssOut)} />
    </AbsoluteFill>
  );
};

// ---- 3 · Lunch: the canvas becomes a card and flips; on its back the agents finish while you eat; flip back.
export const T3_DUR = 300;
export type LunchRow = { name: string; who: string; at: number };
const ROWS: LunchRow[] = [
  { name: 'Hero refresh', who: 'Claude', at: 140 },
  { name: 'Mobile nav', who: 'Codex', at: 160 },
  { name: 'Search docs', who: 'Pi', at: 180 },
];
export const Lunch: React.FC<Feeds & { rows?: LunchRow[]; to?: number }> = ({ before = stand(1340), after = stand(1620), rows = ROWS, to = 12 * 60 + 30 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const shrink = prog(f, 20, 68, E.inOut) - prog(f, 252, 294, E.inOut);
  const s = mix(1, 0.6, shrink);
  const flip1 = prog(f, 70, 114, E.inOut), flip2 = prog(f, 210, 254, E.inOut);
  const rot = 180 * (flip1 + flip2);
  const lift = 1 + 0.07 * (Math.sin(Math.PI * flip1) + Math.sin(Math.PI * flip2));
  const dock = springAt((f - 248) / fps, DOCK);
  const count = prog(f, 118, 150, E.out);
  const border = 10 / s;
  return (
    <AbsoluteFill style={{ background: PINK, overflow: 'hidden' }}>
      {/* polka dots drifting behind the card */}
      <AbsoluteFill style={{ backgroundImage: 'radial-gradient(rgba(255,255,255,0.22) 9px, transparent 10px)', backgroundSize: '64px 64px', backgroundPosition: `${f * 0.6}px ${f * 0.6}px`, opacity: shrink }} />
      <AbsoluteFill style={{ perspective: 2600 }}>
        <div style={{ position: 'absolute', inset: 0, transformStyle: 'preserve-3d', transform: `scale(${s * lift}) rotateY(${rot}deg)` }}>
          {/* front: the canvas, before lunch then after */}
          <div style={{ position: 'absolute', inset: 0, backfaceVisibility: 'hidden', borderRadius: 44 * shrink / s, overflow: 'hidden', boxShadow: shrink > 0.01 ? `0 0 0 ${border}px ${WHITE}, 0 40px 120px rgba(0,0,0,0.35)` : undefined }}>
            {f < 160 ? before(f) : after(f - 160)}
            <ClockChip mins={f < 160 ? 10 * 60 + 30 : to} icon={f < 160 ? 'mug' : 'lunch'} dock={1} opacity={f < 160 ? 1 : dock} />
          </div>
          {/* back: lunch */}
          <div style={{ position: 'absolute', inset: 0, backfaceVisibility: 'hidden', transform: 'rotateY(180deg)', borderRadius: 44 / s, background: '#fff6f9', boxShadow: `0 0 0 ${border}px ${WHITE}, 0 40px 120px rgba(0,0,0,0.35)`, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 120 }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 34 }}>
              <div style={{ transform: `rotate(${6 * Math.sin(f * 0.09)}deg) scale(${springAt((f - 100) / fps, POP)})` }}><Glyph icon="lunch" size={300} color={PINK} /></div>
              <div style={{ color: PLUM, font: `700 120px/1 ${CAPTION_FONT}`, letterSpacing: '-0.04em' }}>Lunch</div>
              <div style={{ color: PINK, font: `700 64px/1 ${CAPTION_FONT}`, letterSpacing: '-0.02em', fontVariantNumeric: 'tabular-nums' }}>{clockText(mix(10 * 60 + 30, to, count))}</div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 30 }}>
              {rows.map((r) => {
                const done = springAt((f - r.at) / fps, POP);
                return (
                  <div key={r.name} style={{ width: 760, height: 128, borderRadius: 36, background: WHITE, boxShadow: `0 0 0 6px ${mixColor('#f3d6e1', '#4fd07a', Math.min(1, done))}`, display: 'flex', alignItems: 'center', padding: '0 40px', gap: 28 }}>
                    <div style={{ width: 28, height: 28, borderRadius: 28, background: done > 0.5 ? '#4fd07a' : '#ffb347', transform: `scale(${done > 0 ? 1 : 0.8 + 0.2 * Math.sin(f * 0.2)})` }} />
                    <div style={{ flex: 1 }}>
                      <div style={{ color: PLUM, font: `700 50px/1.1 ${CAPTION_FONT}`, letterSpacing: '-0.02em' }}>{r.name}</div>
                      <div style={{ color: '#a07386', font: `600 34px/1.2 ${CAPTION_FONT}` }}>{r.who}</div>
                    </div>
                    <div style={{ position: 'relative', width: 210, height: 72 }}>
                      <div style={{ position: 'absolute', inset: 0, borderRadius: 72, background: '#fde7c8', color: '#8a5200', font: `700 34px/72px ${CAPTION_FONT}`, textAlign: 'center', opacity: 1 - Math.min(1, done * 2) }}>Working</div>
                      <div style={{ position: 'absolute', inset: 0, borderRadius: 72, background: '#4fd07a', color: '#04210f', font: `800 34px/72px ${CAPTION_FONT}`, textAlign: 'center', transform: `scale(${Math.max(0, done)})` }}>Done ✓</div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </AbsoluteFill>
      <ChapterPill text="They kept going." f={f} from={192} to={240} x={W / 2} y={H - 120} fps={fps} />
    </AbsoluteFill>
  );
};
const clockText = (mins: number) => {
  const m = Math.floor(mins), h = Math.floor(m / 60), mm = m % 60;
  return `${((h + 11) % 12) + 1}:${String(mm).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};

// ---- 4 · Heads down: the afternoon time-lapses past at 12x under a spinning clock; a little sun crosses its arc.
export const T4_DUR = 270;
const speed = (f: number) => 1 + 11 * (prog(f, 24, 84, E.smooth) - prog(f, 168, 228, E.smooth));
const SRC_AT: number[] = (() => { const a = [0]; for (let i = 1; i <= T4_DUR; i++) a.push(a[i - 1] + speed(i)); return a; })();
const TOTAL = SRC_AT[T4_DUR];
/** The take frame (fractional) the lapse shows at its frame `n`, for a take `length` frames long. */
const lapseAt = (n: number, length: number) => SRC_AT[Math.max(0, Math.min(T4_DUR, n))] * ((length - 1) / TOTAL);

/** Output frames a press holds when the sweep skipped over a click shorter than one lapse frame. */
const PRESS_HOLD = 6;
const lapsed = new WeakMap<PointerTrack, Map<number, PointerTrack>>();
/**
 * The lapse take's pointer track resampled onto the lapse's own frames through the same mapping as the
 * footage (frame n shows take frame round(lapseAt(n)), as the feed rounds it), so the glove sits where
 * the head frame's hand was. Events move to the first lapse frame that reaches them. A click the 12x
 * sweep jumps over still presses: any press that starts between two lapse frames holds the hand down
 * for PRESS_HOLD frames, so the squash and ring play at film speed. Memoised per (track, length).
 */
const lapseTrack = (t: PointerTrack, length: number): PointerTrack => {
  let byLen = lapsed.get(t);
  if (!byLen) lapsed.set(t, (byLen = new Map()));
  const hit = byLen.get(length);
  if (hit) return hit;
  const head = (n: number) => Math.max(0, Math.min(t.frames - 1, Math.round(lapseAt(n, length))));
  const p: PointerTrack['p'] = [];
  let hold = 0;
  for (let n = 0; n <= T4_DUR; n++) {
    const k = head(n), prev = n === 0 ? k - 1 : head(n - 1);
    const [x, y, d, m] = t.p[k];
    for (let j = Math.max(0, prev + 1); j <= k; j++) if (t.p[j][2] === 1 && (j === 0 || t.p[j - 1][2] === 0)) hold = PRESS_HOLD;
    p.push([x, y, d === 1 || hold > 0 ? 1 : 0, m]);
    hold = Math.max(0, hold - 1);
  }
  const reach = (frame: number) => { for (let n = 0; n <= T4_DUR; n++) if (head(n) >= frame) return n; return T4_DUR; };
  const out: PointerTrack = { ...t, frames: T4_DUR + 1, p, v: [], rects: {}, marks: {}, keys: [], menus: [], events: t.events.map((e) => ({ ...e, frame: reach(e.frame) })) };
  byLen.set(length, out);
  return out;
};
/**
 * A long-exposure shutter over the time-lapse: the output frame is the weighted average of the source
 * frames it sweeps past, newest strongest, so motion smears into a trail behind itself. At 1x it is a
 * single sharp frame; at 12x it averages up to 14 frames spread over ~2.2 output frames of travel.
 * Layers are stacked oldest first, each at w_i / (w_0 + ... + w_i), which composites to the exact
 * weighted mean.
 */
const Shutter: React.FC<{ head: number; step: number; src: Feed }> = ({ head, step, src }) => {
  const n = Math.max(1, Math.min(14, Math.round(step * 1.2)));
  const span = n === 1 ? 0 : step * 2.2;
  const taps = Array.from({ length: n }, (_, k) => ({ at: head - (span * k) / Math.max(1, n - 1), w: Math.exp(-k / (n * 0.42)) })).reverse();
  let acc = 0;
  return (
    <>
      {taps.map((t, i) => {
        acc += t.w;
        return <React.Fragment key={i}>{src(t.at, { opacity: i === 0 ? 1 : t.w / acc })}</React.Fragment>;
      })}
    </>
  );
};

const arc = (r: number, a: number, b: number) => {
  const p = (d: number) => `${r * Math.cos((d * Math.PI) / 180)} ${r * Math.sin((d * Math.PI) / 180)}`;
  return `M ${p(a)} A ${r} ${r} 0 0 1 ${p(b)}`;
};
/**
 * `track` is the lapse take's pointer track: when given, the glove rides the time-lapse (no trail, just
 * the hand at the head frame, pressing on clicks). `map` turns its window points into frame px; the
 * default is the footage's own framing (scale H/1048, anchored left).
 */
export const HeadsDown: React.FC<{ lapse?: Lapse; track?: PointerTrack; map?: (x: number, y: number) => { x: number; y: number }; from?: number; to?: number }> = ({ lapse = { src: stand(820), length: 1700 }, track, map = (x, y) => ({ x: x * (H / 1048), y: y * (H / 1048) }), from = 12 * 60 + 30, to = 15 * 60 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  // The source position: the whole of `lapse` swept in T4_DUR frames, at 1x at both ends.
  const src = (n: number) => lapseAt(n, lapse.length);
  const sp = speed(f), fast = (sp - 1) / 11;
  const along = SRC_AT[f] / TOTAL;
  const mins = mix(from, to, along);
  const pop = springAt((f - 30) / fps, POP);
  const away = prog(f, 196, 232, E.inOut);
  const dock = springAt((f - 214) / fps, DOCK);
  const R = 170;
  const cx = mix(W / 2, W - 140, away), cy = mix(470, 80, away);
  const k = Math.max(0, pop) * mix(1, 0.15, away);
  const minuteDeg = (mins % 60) * 6, hourDeg = ((mins / 60) % 12) * 30;
  const sunA = mix(200, 340, along) * (Math.PI / 180);
  return (
    <AbsoluteFill style={{ background: NIGHT, overflow: 'hidden' }}>
      <Shutter head={src(f)} step={src(f) - src(f - 1)} src={lapse.src} />
      <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 45%, rgba(11,13,16,${0.12 * fast}) 0%, rgba(11,13,16,${0.42 * fast}) 80%)` }} />
      {/* speed lines streaming out from the clock while the day races */}
      {fast > 0.02 && (
        <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
          {Array.from({ length: 40 }, (_, i) => {
            const a = ((i * 9 + rand(i + 300) * 6) * Math.PI) / 180;
            const travel = (SRC_AT[f] * 9 + rand(i + 400) * 900) % 900;
            const r0 = 330 + travel, len = (50 + 170 * fast) * (0.6 + 0.4 * rand(i + 500));
            const op = 0.34 * fast * Math.min(1, travel / 160) * (1 - travel / 900);
            return <line key={i} x1={W / 2 + Math.cos(a) * r0} y1={470 + Math.sin(a) * r0} x2={W / 2 + Math.cos(a) * (r0 + len)} y2={470 + Math.sin(a) * (r0 + len)} stroke={WHITE} strokeWidth={3 + 2 * rand(i + 600)} strokeLinecap="round" opacity={op} />;
          })}
        </svg>
      )}
      {track && <HandCursor t={lapseTrack(track, lapse.length)} i={f} map={map} unit={1} rate={Math.max(1, src(f) - src(f - 1))} />}
      <ClockChip mins={from} icon="lunch" dock={1} opacity={1 - prog(f, 20, 34, E.linear)} />
      <div style={{ position: 'absolute', left: cx - R - 120, top: cy - R - 120, width: (R + 120) * 2, height: (R + 120) * 2, transform: `scale(${k})`, opacity: 1 - prog(f, 222, 236, E.linear) }}>
        <svg width={(R + 120) * 2} height={(R + 120) * 2} style={{ position: 'absolute', inset: 0, overflow: 'visible' }}>
          <g transform={`translate(${R + 120} ${R + 120})`}>
            {/* the sun's arc over the clock */}
            <path d={arc(R + 70, 200, 340)} fill="none" stroke="rgba(255,255,255,0.7)" strokeWidth={6} strokeDasharray="2 18" strokeLinecap="round" />
            <circle cx={(R + 70) * Math.cos(sunA)} cy={(R + 70) * Math.sin(sunA)} r={26} fill={PINK} stroke={WHITE} strokeWidth={7} />
            <circle r={R} fill={PINK} stroke={WHITE} strokeWidth={12} />
            {Array.from({ length: 12 }, (_, i) => <line key={i} x1={0} y1={-R + 22} x2={0} y2={-R + (i % 3 ? 38 : 52)} stroke={WHITE} strokeWidth={i % 3 ? 7 : 11} strokeLinecap="round" transform={`rotate(${i * 30})`} />)}
            <line x1={0} y1={14} x2={0} y2={-R * 0.48} stroke={WHITE} strokeWidth={16} strokeLinecap="round" transform={`rotate(${hourDeg})`} />
            <line x1={0} y1={18} x2={0} y2={-R * 0.74} stroke={WHITE} strokeWidth={10} strokeLinecap="round" transform={`rotate(${minuteDeg})`} />
            <circle r={14} fill={WHITE} />
          </g>
        </svg>
      </div>
      <ChapterPill text="Heads down." f={f} from={58} to={196} x={W / 2} y={470 + R + 110} fps={fps} />
      <ClockChip mins={to} icon="clock" dock={1} opacity={dock} />
    </AbsoluteFill>
  );
};

// ---- 4b · Sounds, "You'll know when it lands": a sound wave rings out of the canvas and floods it
// pink; a card names the signals the app can play (Pushed, Merged, Done), each row's wave sounding in
// turn; then the speaker opens as an iris onto the Settings → Sounds take. No time passes: the clock
// stays docked.
export const T6_DUR = 270;
export type Signal = { icon: CaptionIcon; name: string; when: string };
const SIGNALS: Signal[] = [
  { icon: 'push', name: 'Pushed', when: 'An agent pushes its branch' },
  { icon: 'merge', name: 'Merged', when: 'Its branch merges' },
  { icon: 'check', name: 'Done', when: 'An agent finishes its turn' },
];
/** Frame each row's sound plays, and how long its wave rings. */
const PLAY = (k: number) => 112 + k * 26;
const RING_F = 34;
/** 0..1 loudness of a sound played at `at`: a quick attack and a decay. */
const loud = (f: number, at: number) => prog(f, at, at + 5, E.out) * (1 - prog(f, at + 14, at + RING_F, E.inOut));

const Wave: React.FC<{ f: number; at: number; seed: number }> = ({ f, at, seed }) => {
  const a = loud(f, at);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, height: 72 }}>
      {Array.from({ length: 9 }, (_, i) => {
        const shape = Math.sin(((i + 0.5) / 9) * Math.PI);
        const h = 12 + 58 * a * shape * (0.45 + 0.55 * Math.abs(Math.sin(f * 0.42 + i * 1.7 + seed)));
        return <div key={i} style={{ width: 10, height: h, borderRadius: 10, background: mixColor('#f3d6e1', PINK, Math.min(1, a * 3)) }} />;
      })}
    </div>
  );
};

export const Sounds: React.FC<Feeds & { signals?: Signal[]; mins?: number }> = ({ before = stand(1900), after = stand(2200), signals = SIGNALS, mins = 15 * 60 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cx = W / 2, cy = 500;
  // the flood: a pink disc, rimmed white, rings out from the centre behind three sound rings
  const flood = mix(0, 1250, prog(f, 18, 66, E.inOut));
  const card = springAt((f - 58) / fps, POP);
  const cardW = 1400, cardH = 600, cardL = cx - cardW / 2, cardT = cy - cardH / 2;
  // the speaker, on the card's left; the iris opens from its centre
  const sx = cardL + 300, sy = cy - 30, sR = 120;
  const plays = signals.map((_, k) => PLAY(k));
  const now = Math.max(0, ...plays.map((at) => loud(f, at)));
  const open = prog(f, 196, 252, E.inOut);
  const irisR = mix(sR * 1.1, 2300, open);
  return (
    <AbsoluteFill style={{ background: NIGHT, overflow: 'hidden' }}>
      {f < 70 && before(f)}
      {/* sound rings, then the flood */}
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
        {[0, 1, 2].map((i) => {
          const t = prog(f, 4 + i * 10, 74 + i * 10, E.cssOut);
          return t > 0 && t < 1 ? <circle key={i} cx={cx} cy={cy} r={60 + 1300 * t} fill="none" stroke={WHITE} strokeWidth={14 * (1 - t) + 2} opacity={0.85 * (1 - t)} /> : null;
        })}
        {flood > 0 && <circle cx={cx} cy={cy} r={flood} fill={PINK} stroke={WHITE} strokeWidth={12} />}
      </svg>
      {/* while the card is up, rings keep breathing out behind it: the audio motif */}
      {f >= 66 && (
        <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
          {Array.from({ length: 5 }, (_, i) => {
            const r = ((f * 3 + i * 220) % 1100) + 420;
            return <circle key={i} cx={cx} cy={cy} r={r} fill="none" stroke="rgba(255,255,255,0.22)" strokeWidth={10} />;
          })}
        </svg>
      )}
      {/* the card */}
      {f >= 58 && (
        <div style={{ position: 'absolute', left: cardL, top: cardT, width: cardW, height: cardH, transform: `scale(${Math.max(0, card)})`, transformOrigin: `${sx - cardL}px ${sy - cardT}px` }}>
          <div style={{ position: 'absolute', inset: 0, borderRadius: 44, background: '#fff6f9', boxShadow: `0 0 0 10px ${WHITE}, 0 40px 120px rgba(0,0,0,0.35)` }} />
          {/* the speaker and its waves */}
          <svg width={cardW} height={cardH} style={{ position: 'absolute', inset: 0, overflow: 'visible' }}>
            {[0, 1, 2].map((i) => {
              const a = Math.max(0, ...plays.map((at) => loud(f, at + i * 4)));
              return <path key={i} d={arc(sR + 40 + i * 44, -42, 42)} transform={`translate(${sx - cardL} ${sy - cardT})`} fill="none" stroke={PINK} strokeWidth={14} strokeLinecap="round" opacity={0.18 + 0.82 * a} />;
            })}
            <circle cx={sx - cardL} cy={sy - cardT} r={sR * (1 + 0.06 * now)} fill={PINK} stroke={WHITE} strokeWidth={10} />
          </svg>
          <div style={{ position: 'absolute', left: sx - cardL - 70, top: sy - cardT - 70 }}><CaptionGlyph icon="sound" px={140} /></div>
          <div style={{ position: 'absolute', left: 0, width: 600, top: sy - cardT + sR + 44, textAlign: 'center', color: PLUM, font: `700 72px/1 ${CAPTION_FONT}`, letterSpacing: '-0.04em' }}>Sounds</div>
          {/* the signals */}
          <div style={{ position: 'absolute', left: 620, top: 0, bottom: 0, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 30 }}>
            {signals.map((sg, k) => {
              const pop = springAt((f - 74 - k * 12) / fps, POP);
              const a = loud(f, PLAY(k));
              const played = f >= PLAY(k);
              return (
                <div key={sg.name} style={{ width: 740, height: 140, borderRadius: 40, background: WHITE, boxShadow: `0 0 0 6px ${mixColor('#f3d6e1', PINK, played ? 1 : 0)}`, display: 'flex', alignItems: 'center', padding: '0 36px', gap: 28, transform: `scale(${Math.max(0, pop)})`, transformOrigin: '0 50%' }}>
                  <div style={{ position: 'relative', width: 84, height: 84, borderRadius: 84, background: PINK, display: 'grid', placeItems: 'center', transform: `scale(${1 + 0.14 * a})` }}>
                    <CaptionGlyph icon={sg.icon} px={56} />
                    {a > 0 && <div style={{ position: 'absolute', inset: -8 - 22 * prog(f, PLAY(k), PLAY(k) + RING_F, E.out), borderRadius: '50%', border: `5px solid ${PINK}`, opacity: 1 - prog(f, PLAY(k), PLAY(k) + RING_F, E.linear) }} />}
                  </div>
                  <div style={{ flex: 1, whiteSpace: 'nowrap' }}>
                    <div style={{ color: PLUM, font: `700 54px/1.1 ${CAPTION_FONT}`, letterSpacing: '-0.02em' }}>{sg.name}</div>
                    <div style={{ color: '#a07386', font: `600 30px/1.2 ${CAPTION_FONT}` }}>{sg.when}</div>
                  </div>
                  <Wave f={f} at={PLAY(k)} seed={k * 2.3} />
                </div>
              );
            })}
          </div>
        </div>
      )}
      <ChapterPill text="You’ll know when it lands." f={f} from={78} to={204} x={cx} y={H - 120} fps={fps} />
      {/* the hand-over: the speaker opens as an iris onto the Settings take, rimmed pink and white */}
      {f >= 196 && (
        <>
          <AbsoluteFill style={{ clipPath: `circle(${irisR}px at ${sx}px ${sy}px)` }}>{after(f - 196)}</AbsoluteFill>
          <div style={{ position: 'absolute', left: sx - irisR - 34, top: sy - irisR - 34, width: (irisR + 34) * 2, height: (irisR + 34) * 2, borderRadius: '50%', border: `24px solid ${PINK}`, outline: `10px solid ${WHITE}`, outlineOffset: -44, boxSizing: 'border-box', opacity: 1 - prog(f, 236, 256, E.linear) }} />
        </>
      )}
      <ClockChip mins={mins} icon="clock" dock={1} />
    </AbsoluteFill>
  );
};

// ---- 5 · Sunset: a sky blind drops over the canvas, the sun sets, stars and the moon pop, and the blind lifts on the evening.
export const T5_DUR = 300;
const Sparkle: React.FC<{ x: number; y: number; r: number; k: number; tw: number }> = ({ x, y, r, k, tw }) => (
  <svg width={r * 2} height={r * 2} viewBox="-1 -1 2 2" style={{ position: 'absolute', left: x - r, top: y - r, transform: `scale(${Math.max(0, k) * (0.85 + 0.15 * tw)}) rotate(${tw * 12}deg)` }}>
    <path d="M0 -1 Q0.12 -0.12 1 0 Q0.12 0.12 0 1 Q-0.12 0.12 -1 0 Q-0.12 -0.12 0 -1Z" fill={WHITE} />
  </svg>
);
export const Sunset: React.FC<Feeds & { from?: number }> = ({ before = stand(2060), after = stand(2380), from = 15 * 60 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const drop = prog(f, 24, 92, E.inOut), lift = prog(f, 214, 270, E.inOut);
  const edge = H * (drop - lift);
  const dusk = prog(f, 92, 196, E.smooth);
  const horizon = 720;
  const sunY = mix(500, horizon + 150, prog(f, 96, 186, E.inOut));
  const count = prog(f, 110, 176, E.out);
  const dock = springAt((f - 236) / fps, DOCK);
  const moon = springAt((f - 168) / fps, POP);
  const grade = prog(f, 236, 290, E.smooth);
  return (
    <AbsoluteFill style={{ background: NIGHT, overflow: 'hidden' }}>
      {f < 150 ? before(f) : after(f - 150)}
      <AbsoluteFill style={{ background: `rgba(52,30,110,${0.2 * grade})`, mixBlendMode: 'multiply' }} />
      <ClockChip mins={f < 150 ? from : 18 * 60} icon={f < 150 ? 'clock' : 'moon'} dock={1} opacity={f < 150 ? 1 : dock} />
      {/* the blind */}
      <div style={{ position: 'absolute', left: 0, right: 0, top: 0, height: Math.max(0, edge), overflow: 'hidden' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, background: `linear-gradient(180deg, ${mixColor('#ff7a9f', '#1d1446', dusk)} 0%, ${mixColor('#ffb36b', '#4a2a7c', dusk)} ${(horizon / H) * 100}%, ${mixColor('#c7406f', '#120d26', dusk)} ${(horizon / H) * 100}%, ${mixColor('#7a2148', '#0b0918', dusk)} 100%)` }}>
          <div style={{ position: 'absolute', inset: 0, clipPath: `inset(0 0 ${H - horizon}px 0)` }}>
            <div style={{ position: 'absolute', left: W / 2 - 130, top: sunY - 130, width: 260, height: 260, borderRadius: '50%', background: PINK, border: `10px solid ${WHITE}`, boxSizing: 'border-box', boxShadow: `0 0 140px ${mixColor('#ff4f8b', '#ff9a5a', 0.5)}` }} />
          </div>
          <div style={{ position: 'absolute', left: W / 2 - 700, top: horizon - 5, width: 1400, height: 10, borderRadius: 10, background: WHITE }} />
          {Array.from({ length: 16 }, (_, i) => (
            <Sparkle key={i} x={120 + rand(i + 20) * (W - 240)} y={60 + rand(i + 40) * (horizon - 260)} r={10 + rand(i + 60) * 18} k={springAt((f - 132 - i * 4) / fps, POP)} tw={Math.sin(f * 0.15 + i * 1.7)} />
          ))}
          <div style={{ position: 'absolute', left: 1440, top: 160, width: 170, height: 170, transform: `scale(${Math.max(0, moon)}) rotate(${(1 - moon) * -40}deg)` }}>
            <svg width={170} height={170} viewBox="0 0 24 24"><path d="M19 14.5A7.5 7.5 0 1 1 9.5 5a6 6 0 0 0 9.5 9.5z" fill={WHITE} stroke={PINK} strokeWidth={1.2} strokeLinejoin="round" /></svg>
          </div>
          <ChapterPill text="Wrapping up." f={f} from={150} to={226} x={W / 2} y={horizon + 120} fps={fps} />
          <ClockChip mins={mix(from, 18 * 60, count)} icon="moon" dock={0} x0={W / 2} y0={horizon + 240} big={1.8} opacity={prog(f, 106, 118, E.cssOut) * (1 - prog(f, 226, 238, E.linear))} />
        </div>
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 10, background: WHITE }} />
      </div>
    </AbsoluteFill>
  );
};

export const TRANSITIONS = [
  { id: 'sunrise', title: 'Morning · sunrise iris', dur: T1_DUR, C: Sunrise },
  { id: 'coffee', title: 'Mid-morning · coffee pour', dur: T2_DUR, C: Coffee },
  { id: 'lunch', title: 'Lunch · card flip', dur: T3_DUR, C: Lunch },
  { id: 'heads-down', title: 'Afternoon · time-lapse clock', dur: T4_DUR, C: HeadsDown },
  { id: 'sounds', title: 'Afternoon · you’ll know when it lands', dur: T6_DUR, C: Sounds },
  { id: 'sunset', title: 'Evening · sunset blind', dur: T5_DUR, C: Sunset },
] as const;
