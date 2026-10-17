// The narration pill both caption kinds share: the cursor's speech bubble (Bubble.tsx) and the
// tile-pinned tag (Tag.tsx). Tone colours, the type measure, the shadow, and the word-by-word pop with
// blur live here, so the two read as one voice that sometimes rides the hand and sometimes pins to a tile.
import { E, prog, springAt, type Spring } from '../../lib/anim';
import { CAPTION_FONT } from '../../lib/fonts';
import type { Line } from '../../lib/sheet';
import { PERSONA } from './HandCursor';
import { CaptionGlyph, iconBox, iconToken } from './Icon';

export const TONES: Record<NonNullable<Line['tone']> | 'persona', { bg: string; ink: string }> = {
  persona: { bg: PERSONA, ink: '#ffffff' },
  amber: { bg: '#ffb347', ink: '#2a1700' },
  green: { bg: '#4fd07a', ink: '#04210f' },
  blue: { bg: '#5fa8ff', ink: '#03162e' },
};

/** The pill's pop (scale) and each word's arrival: friendly overshoot, slower than r0's { 3.1, 0.5 }. */
export const POP: Spring = { hz: 2.2, zeta: 0.55 };
/** Seconds for a word (and a tag) to fade up; a line's last words lift away over EXIT frames at 60 fps. */
export const RISE = 0.15;
export const EXIT_S = 10 / 60;
/** Frames between successive words: ~4.5 at 60 fps. */
export const wordStagger = (fps: number) => Math.max(2, Math.round(fps * 0.075));
/** Frames from a line's start to its first word. */
export const WORD_DELAY = 3;

/** Type metrics at a given output unit (px per 1080p design px). */
export const pillMetrics = (unit: number) => {
  const size = 40 * unit, padX = 22 * unit, padY = 13 * unit, lineH = size * 1.18;
  return { size, padX, padY, lineH, h: lineH + padY * 2 };
};

/** The outer shadow: as a box-shadow on the bubble, as a drop-shadow over the tag's pill + notch. */
export const pillShadow = (unit: number) => `0 ${8 * unit}px ${22 * unit}px rgba(0,0,0,0.42)`;
export const pillHighlight = (unit: number) => `inset 0 ${1.5 * unit}px 0 rgba(255,255,255,0.28)`;

let ctx: CanvasRenderingContext2D | null = null;
const canvas = () => (ctx ??= document.createElement('canvas').getContext('2d')!);
/** Geist's cap height at `size` px, measured, so an icon matches the type it sits in. */
export const capHeight = (size: number) => {
  const c = canvas();
  c.font = `650 ${size}px ${CAPTION_FONT}`;
  return c.measureText('H').actualBoundingBoxAscent || size * 0.71;
};
/** The square an icon token takes in a line set at `size` px. */
export const iconPx = (size: number) => iconBox(size, capHeight(size));
/**
 * The rendered width of a line as the pill sets it: word by word, 0.25em gaps, -0.02em tracking. A
 * `{name}` token (an icon, see Icon.tsx) counts as its square, so the pill always fits its icons.
 */
export const measure = (text: string, size: number) => {
  const c = canvas();
  (c as CanvasRenderingContext2D & { letterSpacing: string }).letterSpacing = `${-0.02 * size}px`;
  const words = text.split(' ');
  return words.reduce((sum, w) => {
    if (iconToken(w)) return sum + iconPx(size);
    c.font = `${/^\[.*\]/.test(w) ? 800 : 650} ${size}px ${CAPTION_FONT}`;
    return sum + c.measureText(w.replace(/[[\]]/g, '')).width;
  }, 0) + 0.25 * size * (words.length - 1);
};

/**
 * One line of words popping in one by one from `from` (each rises, grows from 55% and unblurs on POP)
 * and lifting away together over the EXIT frames before `to`. `[Word]` sets that word in the accent weight;
 * `{name}` sets that icon (Icon.tsx), popping in like a word.
 */
export const Words: React.FC<{ text: string; f: number; from: number; to: number; fps: number; unit: number; ink: string }> = ({ text, f, from, to, fps, unit, ink }) => {
  const { size, padX, padY, lineH } = pillMetrics(unit);
  const stagger = wordStagger(fps);
  const exit = 1 - prog(f, to - EXIT_S * fps, to, E.in);
  const words = text.split(' ');
  // An icon sits on the baseline raised so its square centres on the cap height (an inline-block
  // svg's baseline is its bottom edge, so vertical-align lifts it by that length).
  const px = iconPx(size), lift = (capHeight(size) - px) / 2;
  return (
    <div style={{ position: 'absolute', left: padX, top: padY, height: lineH, whiteSpace: 'nowrap', color: ink, font: `650 ${size}px/${lineH}px ${CAPTION_FONT}`, letterSpacing: '-0.02em', opacity: exit, transform: `translateY(${(1 - exit) * -10 * unit}px)` }}>
      {words.map((w, k) => {
        const start = from + WORD_DELAY + k * stagger;
        const kk = springAt((f - start) / fps, POP);
        const fade = prog(f, start, start + RISE * fps, E.cssOut);
        const accent = /^\[.*\]/.test(w);
        const icon = iconToken(w);
        return (
          <span key={k} style={{ display: 'inline-block', opacity: fade, transform: `translateY(${(1 - kk) * size * 0.45}px) scale(${0.55 + 0.45 * kk})`, transformOrigin: '50% 80%', filter: kk < 0.98 ? `blur(${Math.max(0, 1 - kk) * 6 * unit}px)` : undefined, marginRight: k < words.length - 1 ? '0.25em' : 0, fontWeight: accent ? 800 : undefined }}>
            {icon ? <CaptionGlyph icon={icon} px={px} color={ink} style={{ verticalAlign: lift }} /> : w.replace(/[[\]]/g, '')}
          </span>
        );
      })}
    </div>
  );
};
