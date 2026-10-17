// Shared pieces for the full-day film's chapter transitions (preview): the footage shot, the
// chapter pill, the docked clock chip, colour mixing. Brand: persona pink fills with white outlines
// (the glove cursor's look), Geist type, the caption pill's word pop.
import { AbsoluteFill, Freeze, OffthreadVideo, staticFile } from 'remotion';
import { E, mix, prog, springAt, type Spring } from '../../lib/anim';
import { CAPTION_FONT } from '../../lib/fonts';
import { POP, Words, measure, pillMetrics, pillShadow, pillHighlight } from '../../acts/edu/Pill';
import '../../lib/fonts';

export const PINK = '#ff4f8b';
export const WHITE = '#ffffff';
export const NIGHT = '#0b0d10';
export const PLUM = '#2a0f1c';
export const W = 1920, H = 1080;
export { POP };

const hex = (c: string) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
export const mixColor = (a: string, b: string, t: number) => {
  const x = hex(a), y = hex(b);
  return `rgb(${x.map((v, i) => Math.round(mix(v, y[i], Math.max(0, Math.min(1, t))))).join(' ')})`;
};

// The power-tour proxy (1920x1048) covering the frame, anchored left so the sidebar keeps its labels.
const SRC = staticFile('footage/power-tour/01-tour.mp4');
const K = H / 1048;
export const Shot: React.FC<{ frame: number; style?: React.CSSProperties }> = ({ frame, style }) => (
  <Freeze frame={0}>
    <AbsoluteFill style={style}>
      <OffthreadVideo src={SRC} muted trimBefore={Math.max(0, Math.min(2580, Math.round(frame)))} style={{ position: 'absolute', left: 0, top: 0, width: 1920 * K, height: H, maxWidth: 'none' }} />
    </AbsoluteFill>
  </Freeze>
);

/** Minutes after midnight as "8:45 AM". */
export const clock = (mins: number) => {
  const m = Math.floor(mins) % (24 * 60);
  const h = Math.floor(m / 60), mm = m % 60;
  return `${((h + 11) % 12) + 1}:${String(mm).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};

/** A caption pill in the chapter style: pink, white outline, words popping in. Centred on (x, y). */
export const ChapterPill: React.FC<{ text: string; f: number; from: number; to: number; x: number; y: number; fps: number; unit?: number }> = ({ text, f, from, to, x, y, fps, unit = 1.15 }) => {
  if (f < from - 1 || f > to + 1) return null;
  const { size, padX, h } = pillMetrics(unit);
  const w = measure(text, size) + padX * 2;
  const open = springAt((f - from) / fps, POP);
  const exit = prog(f, to - 10, to, E.in);
  return (
    <div style={{ position: 'absolute', left: x - w / 2, top: y - h / 2, width: w, height: h, transform: `scale(${Math.max(0, open) * (1 - 0.1 * exit)})`, opacity: 1 - exit, filter: `drop-shadow(${pillShadow(unit)})` }}>
      <div style={{ position: 'absolute', inset: -5 * unit, borderRadius: h, background: WHITE }} />
      <div style={{ position: 'absolute', inset: 0, borderRadius: h, background: PINK, boxShadow: pillHighlight(unit) }} />
      <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: h }}>
        <Words text={text} f={f} from={from} to={to} fps={fps} unit={unit} ink={WHITE} />
      </div>
    </div>
  );
};

export type Icon = 'sun' | 'mug' | 'lunch' | 'clock' | 'moon';

/** The small line icons the chip carries, white on pink. */
export const Glyph: React.FC<{ icon: Icon; size: number; color?: string }> = ({ icon, size, color = WHITE }) => {
  const s = { fill: 'none', stroke: color, strokeWidth: 2.4, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: 'block' }}>
      {icon === 'sun' && <><circle cx={12} cy={12} r={4.5} {...s} />{[0, 45, 90, 135, 180, 225, 270, 315].map((a) => <line key={a} x1={12} y1={2.5} x2={12} y2={4.5} {...s} transform={`rotate(${a} 12 12)`} />)}</>}
      {icon === 'mug' && <><path d="M5 9h11v6a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4z" {...s} /><path d="M16 11h1.5a2.5 2.5 0 0 1 0 5H16" {...s} /><path d="M8.5 3.5c-1 1.2 1 1.8 0 3M12 3.5c-1 1.2 1 1.8 0 3" {...s} /></>}
      {icon === 'lunch' && <><path d="M4 11a8 6 0 0 1 16 0z" {...s} /><path d="M3.5 14c2 1.2 3.5-1 5.5 0s3.5 1.2 5.5 0 3.5-1 5.5 0" {...s} /><rect x={4} y={16.5} width={16} height={3.5} rx={1.75} {...s} /></>}
      {icon === 'clock' && <><circle cx={12} cy={12} r={8.5} {...s} /><path d="M12 7.5V12l3 2" {...s} /></>}
      {icon === 'moon' && <path d="M19 14.5A7.5 7.5 0 1 1 9.5 5a6 6 0 0 0 9.5 9.5z" {...s} />}
    </svg>
  );
};

/**
 * The chapter's clock chip. `dock` 0 = big at (x0, y0), 1 = small in the top-right corner, where it
 * rides over the footage for the rest of the chapter.
 */
export const ClockChip: React.FC<{ mins: number; icon: Icon; dock: number; x0?: number; y0?: number; big?: number; opacity?: number }> = ({ mins, icon, dock, x0 = W / 2, y0 = H / 2, big = 2.2, opacity = 1 }) => {
  const label = clock(mins);
  const size = 30, padX = 20, h = 60;
  const w = 30 + 12 + label.length * 17.5 + padX * 2;
  const s = mix(big, 1, dock);
  const x = mix(x0, W - 40 - w / 2, dock), y = mix(y0, 40 + h / 2, dock);
  return (
    <div style={{ position: 'absolute', left: x - w / 2, top: y - h / 2, width: w, height: h, transform: `scale(${s})`, opacity, filter: `drop-shadow(0 8px 22px rgba(0,0,0,0.42))` }}>
      <div style={{ position: 'absolute', inset: -4, borderRadius: h, background: WHITE }} />
      <div style={{ position: 'absolute', inset: 0, borderRadius: h, background: PINK, boxShadow: pillHighlight(1), display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12 }}>
        <Glyph icon={icon} size={size} />
        <span style={{ color: WHITE, font: `700 ${size}px/1 ${CAPTION_FONT}`, letterSpacing: '-0.02em', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>{label}</span>
      </div>
    </div>
  );
};

/** A spring that returns to rest: up at `a`, back down at `b`. */
export const pulse = (f: number, a: number, b: number, fps: number, s: Spring) => springAt((f - a) / fps, s) - springAt((f - b) / fps, s);

/** Review label (preview only): which transition this is. */
export const Label: React.FC<{ n: number; title: string }> = ({ n, title }) => (
  <div style={{ position: 'absolute', left: 36, bottom: 30, color: 'rgba(255,255,255,0.75)', font: `600 26px/1 ${CAPTION_FONT}`, letterSpacing: '-0.01em', textShadow: '0 2px 10px rgba(0,0,0,0.6)' }}>
    {n} · {title}
  </div>
);

/**
 * Key caps for a shortcut the user presses (e.g. ["⌘", "K"]): pink keys with a white outline, popping
 * in one after another on the POP spring, held while `held` (a modifier being held down), and leaving
 * together. Centred on (x, y).
 */
export const KeyCaps: React.FC<{ keys: string[]; f: number; from: number; to: number; fps: number; x?: number; y?: number; size?: number }> = ({ keys, f, from, to, fps, x = W / 2, y = H - 120, size = 76 }) => {
  if (f < from - 1 || f > to + 1) return null;
  const exit = prog(f, to - 9, to, E.in);
  const gap = 16;
  const widths = keys.map((k) => Math.max(size, k.length * size * 0.38 + size * 0.5));
  const total = widths.reduce((a, b) => a + b, 0) + gap * (keys.length - 1);
  let left = x - total / 2;
  return (
    <div style={{ position: 'absolute', inset: 0, opacity: 1 - exit }}>
      {keys.map((k, i) => {
        const s = Math.max(0, springAt((f - from - i * 5) / fps, POP));
        // the press: the cap dips 4px and back as it lands
        const dip = 4 * Math.max(0, Math.sin(Math.min(1, Math.max(0, (f - from - i * 5 - 6) / 8)) * Math.PI));
        const w = widths[i];
        const el = (
          <div key={i} style={{ position: 'absolute', left, top: y - size / 2 + dip, width: w, height: size, transform: `scale(${s * (1 - 0.08 * exit)})`, filter: 'drop-shadow(0 10px 24px rgba(0,0,0,0.45))' }}>
            <div style={{ position: 'absolute', inset: -5, borderRadius: size * 0.3, background: WHITE }} />
            <div style={{ position: 'absolute', inset: 0, borderRadius: size * 0.26, background: PINK, boxShadow: `inset 0 -${size * 0.07}px 0 rgba(0,0,0,0.16), ${pillHighlight(1)}`, display: 'grid', placeItems: 'center', paddingBottom: size * 0.05 }}>
              <span style={{ color: WHITE, font: `700 ${k.length > 1 ? size * 0.36 : size * 0.48}px/1 ${CAPTION_FONT}`, letterSpacing: '-0.01em' }}>{k}</span>
            </div>
          </div>
        );
        left += w + gap;
        return el;
      })}
    </div>
  );
};
