// A LOOK is everything a video's palette, type and motion grammar decide. Kit pieces never hard-code a
// colour, a face or a timing: they take a Look (or the slice of one they need). A video picks its look in
// one line; looks/<name>/look.ts holds the saved ones, and a new video starts with its own.
import type { Ease } from './anim';

export interface FontFile { family: string; file: string; weight: string }

/** Word-by-word entrance through a mask (kit/type.tsx). Times in seconds. */
export interface WordMotion {
  /** delay between words */
  stagger: number;
  /** each word's rise */
  dur: number;
  ease: Ease;
  /** % of the word's height it rises from */
  travel: number;
  /** opacity reaches 1 at t = 1 / fadeRate */
  fadeRate: number;
  /** mask padding above / below the glyphs, as a fraction of the size (keeps descenders and accents inside) */
  maskTop: number;
  maskBottom: number;
  /** space after a word, as a fraction of the size */
  space: number;
}

/** A headline (kit/type.tsx Headline): face settings and how a line leaves. */
export interface HeadlineStyle {
  weight: number;
  tracking: string;
  features: string;
  /** baseline sits this fraction of the size below the line box's top */
  ascent: number;
  /** a line leaves by lifting `leaveLift` x size and fading over `leave` s on `leaveEase` */
  leave: number;
  leaveLift: number;
  leaveEase: Ease;
}

/**
 * The end-card lockup (kit/lockup.tsx). Proportions are in H, the wordmark's cap height; font metrics are
 * per em, read off Chrome's own render of THIS text in THIS face (probes/lockup.py measures them).
 */
export interface LockupStyle {
  /** H, the wordmark's cap height, in px on a 1080-high frame (scales with the frame) */
  cap: number;
  markOfH: number;
  gapOfH: number;
  /** the mark's aspect (width / height), after its viewBox is cropped to its ink */
  markAspect: number;
  markSrc: string;
  word: { text: string; family: string; weight: number; tracking: string; cap: number; capTop: number; lsb: number; inkW: number };
  url: { family: string; weight: number; asc: number; ascTop: number; lsb: number; inkW: number; ascOfH: number; topOfH: number; opacity: number };
  /** the payoff line before the lockup: its size in px on a 1080-high frame */
  line: number;
  /** beats, seconds: ground fade, line delay, line hold, line out, empty gap, lockup in, lockup rise (px at 1080), URL delay, URL in */
  beats: { ground: number; lineDelay: number; lineHold: number; lineOut: number; gap: number; lockIn: number; rise: number; urlDelay: number; urlIn: number };
  lockEase: Ease;
}

export interface Look {
  name: string;
  color: {
    /** the field everything sits on */
    ground: string;
    /** type on the ground */
    text: string;
    textDim: string;
    /** the one signal colour, if the look has one */
    accent: string;
    [token: string]: string;
  };
  type: { display: string; mono: string; system: string };
  fonts: FontFile[];
  headline: HeadlineStyle;
  words: WordMotion;
  lockup?: LockupStyle;
}

/** '#0E0F0C' + 0.5 -> 'rgba(14,15,12,0.5)' (the exact string the films have always written). */
export const alpha = (hex: string, a: number) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
};
