// Type that enters word by word: each word rises into place from below through a mask, one after another,
// on the look's ease (WordMotion); a line leaves by lifting and fading as one piece. Faces, weights,
// tracking and every timing come from the look.
import { prog } from './anim';
import type { HeadlineStyle, WordMotion } from './look';

/** Progress of word k of a line entering at `from` (frames). */
export const wordIn = (m: WordMotion, f: number, from: number, k: number, fps: number) =>
  prog(f, from + k * fps * m.stagger, from + k * fps * m.stagger + fps * m.dur, m.ease);

/** One masked word at entrance progress t. The mask's padding keeps descenders and a question mark's dot inside. */
export const Word: React.FC<{ m: WordMotion; text: string; t: number; size: number; last: boolean }> = ({ m, text, t, size, last }) => (
  <span style={{ display: 'inline-block', overflow: 'hidden', verticalAlign: 'top', padding: `${size * m.maskTop}px 0 ${size * m.maskBottom}px`, margin: `${-size * m.maskTop}px 0 ${-size * m.maskBottom}px`, marginRight: last ? 0 : size * m.space }}>
    <span style={{ display: 'inline-block', transform: `translateY(${(1 - t) * m.travel}%)`, opacity: Math.min(1, t * m.fadeRate) }}>{text}</span>
  </span>
);

/**
 * A headline at (x, baseline). `from` <= 0 means it is set before the film starts (legible on frame 0, the
 * thumbnail). `out` lifts it away.
 */
export const Headline: React.FC<{ text: string; f: number; fps: number; from: number; out?: number; size: number; color: string; x: number; baseline: number; family: string; style: HeadlineStyle; words: WordMotion }> =
  ({ text, f, fps, from, out, size, color, x, baseline, family, style, words }) => {
  const parts = text.split(' ');
  const leave = out === undefined ? 0 : prog(f, out, out + fps * style.leave, style.leaveEase);
  if (leave >= 1) return null;
  // Held type never drifts: a sub-pixel creep re-rasterises the glyphs every frame and reads as jitter
  // (which-tab round 4, measured with probes/jitter.py).
  const drift = 0;
  return (
    <div style={{ position: 'absolute', left: x, top: baseline - size * style.ascent, whiteSpace: 'nowrap', font: `${style.weight} ${size}px/1 ${family}`, letterSpacing: style.tracking, color,
      transform: `translate(${drift}px, ${-leave * size * style.leaveLift}px)`, opacity: 1 - leave, fontFeatureSettings: style.features }}>
      {parts.map((w, k) => <Word key={k} m={words} text={w} size={size} last={k === parts.length - 1} t={from <= 0 ? 1 : wordIn(words, f, from, k, fps)} />)}
    </div>
  );
};
