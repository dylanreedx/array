import { spring } from './guided-toolbar';

// A port of the app's composer dictation (ComposerDictationButton,
// ComposerDictationPillView, ComposerDictationStripView, ComposerDictationController).
// The mic is a 32 pt circle beside Send. A session grows it, on the canvas's
// jelly spring, into a capsule over the provider controls: waveform, elapsed
// time, and a stop button exactly where the mic was. Words land at the caret,
// the live hypothesis in the secondary text colour until it settles. Return
// finishes and keeps the words; it never sends.
export const DICTATION = {
  /** ComposerActionButton.controlHeight: the mic's side and the capsule's height. */
  control: 32,
  /** Space.l: the waveform's leading inset. Space.m: the gap before the time. */
  inset: 12, gap: 8,
  /** The stop glyph: 10 pt square, 2.5 pt corners, centred in the trailing circle. */
  glyph: 10, glyphRadius: 2.5,
  /** ComposerDictationStripView: 16 pt strip, 2 pt bars, 1 pt gaps. */
  waveHeight: 16, barWidth: 2, barGap: 1,
  /** DictationLevelMeter: 48 buckets, a resting floor, a bar every 50 ms. */
  bars: 48, restingLevel: .06, advance: 1 / 20, release: .15,
  /** ComposerDictationPillView.spring = FloatingToolbarSpring(response: 0.38, dampingRatio: 0.74). */
  response: .38, damping: .74,
  /** Content fades in over this span of the growth so nothing reads half-clipped. */
  reveal: [.35, .5],
  hint: '↩ done · esc discard',
} as const;

/**
 * The agent's identity colour: NSColor.systemPurple in dark appearance, from
 * the palette the tile's Color menu offers (ZoneColorConfig.palette).
 */
export const DICTATION_TINT = { name: 'purple', color: '#bf5af2' } as const;

/** Seconds of real time per unit of the beat's own clock. */
const SECONDS = 8;
/** Where the beat's moments fall on its own 0…1 clock. */
export const DICTATION_BEAT = {
  seconds: SECONDS,
  /** The hand travels to the mic, presses it, and the session opens on mouse-down. */
  approach: [0, .09], press: [.1, .125], open: .1,
  /** ↩: the session stops listening and the last words settle. */
  finish: .1 + 4.6 / SECONDS,
  /** Idle: the capsule folds back into the mic, then hides once the spring settles. */
  close: .1 + 4.8 / SECONDS,
  hidden: .1 + 4.8 / SECONDS + .56 / SECONDS,
  /** Then the hand goes to Send and sends what is on screen. */
  toSend: [.78, .85], sendPress: [.86, .885], sent: .865,
  camera: { in: [0, .12], out: [.88, 1] },
} as const;

type Word = { text: string; start: number; end: number; amp: number };
/** The spoken prompt, in seconds after listening begins, phrase by phrase. */
const PHRASES: ReadonlyArray<{ words: Word[]; settled: string; settleAt: number | null }> = [
  { settled: 'Review the native spacing,', settleAt: 2.3, words: [
    { text: 'Review', start: .5, end: .85, amp: .86 }, { text: 'the', start: .9, end: 1, amp: .62 },
    { text: 'native', start: 1.05, end: 1.4, amp: .9 }, { text: 'spacing', start: 1.45, end: 1.95, amp: .82 },
  ] },
  // The last phrase settles when the session stops, as SpeechAnalyzer's final result does.
  { settled: 'colors, and canvas controls.', settleAt: null, words: [
    { text: 'colors', start: 2.35, end: 2.75, amp: .88 }, { text: 'and', start: 2.8, end: 2.95, amp: .6 },
    { text: 'canvas', start: 3, end: 3.35, amp: .92 }, { text: 'controls', start: 3.4, end: 3.95, amp: .84 },
  ] },
];
/** A word reaches the hypothesis a beat after it is spoken. */
const HEARD = .2;
const WORDS = PHRASES.flatMap(phrase => phrase.words);

const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));
const between = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
const smooth = (p: number) => p * p * (3 - 2 * p);

/** The perceptual level the meter's envelope follows: syllable swells, fast attack, 150 ms release. */
function level(s: number) {
  let value = .02;
  for (const word of WORDS) {
    if (s >= word.start && s <= word.end) {
      const u = (s - word.start) / (word.end - word.start);
      value = Math.max(value, word.amp * (.55 + .45 * Math.sin(Math.PI * u)) * (.86 + .14 * Math.sin(s * 47 + word.start * 13)));
    } else if (s > word.end) value = Math.max(value, word.amp * .5 * Math.exp(-(s - word.end) / DICTATION.release));
  }
  return clamp(value);
}
/** One bucket's peak: the bar the strip draws for the 50 ms ending at tick `m`. */
function bucket(m: number) {
  if (m < 1) return 0;
  const end = m * DICTATION.advance;
  return Math.max(level(end - DICTATION.advance / 2), level(end));
}

export type DictationState = 'idle' | 'listening' | 'finalizing';
export interface DictationSnapshot {
  state: DictationState;
  /** The capsule is on screen (it stays until its fold-back spring settles). */
  visible: boolean;
  /** The spring's value: 0 the mic-sized circle, 1 fully grown; it overshoots. */
  growth: number;
  /** Growth clamped to 0…1, what the covered controls fade by. */
  expansion: number;
  elapsed: string;
  /** Oldest first, newest last: display levels with the resting floor applied. */
  bars: number[];
  settled: string;
  /** The live hypothesis, with its leading space when it follows settled words. */
  provisional: string;
  /** The composer's hint row reads "↩ done · esc discard" while a session is live. */
  hint: boolean;
  /** The ↩ keystroke readout, 0 hidden … 1 shown. */
  keyHud: number;
}

export function dictationSnapshot(t: number): DictationSnapshot {
  const beat = DICTATION_BEAT;
  const s = (t - beat.open) * SECONDS;
  const active = t >= beat.open && t < beat.close;
  const state: DictationState = !active ? 'idle' : t < beat.finish ? 'listening' : 'finalizing';
  const growth = t < beat.open ? 0 : t < beat.close
    ? spring(s, DICTATION.response, DICTATION.damping)
    : 1 - spring((t - beat.close) * SECONDS, DICTATION.response, DICTATION.damping);
  // Bars scroll while listening; finalizing decays them in place, never cut mid-flight.
  const finishTick = Math.floor((beat.finish - beat.open) * SECONDS / DICTATION.advance);
  const tick = Math.floor(Math.max(0, s) / DICTATION.advance + 1e-9);
  const newest = Math.min(tick, finishTick);
  const decay = Math.exp(-Math.max(0, tick - finishTick) * DICTATION.advance / DICTATION.release);
  const bars = Array.from({ length: DICTATION.bars }, (_, k) => Math.max(DICTATION.restingLevel, bucket(newest - (DICTATION.bars - 1 - k)) * decay));
  const seconds = t < beat.open ? 0 : Math.floor(Math.min(s, (beat.close - beat.open) * SECONDS));
  let settled = '', provisional = '';
  for (const phrase of PHRASES) {
    const done = phrase.settleAt === null ? t >= beat.close : s >= phrase.settleAt;
    if (done) { settled += (settled ? ' ' : '') + phrase.settled; continue; }
    const heard = phrase.words.filter(word => s >= word.end + HEARD).map(word => word.text).join(' ');
    if (heard && t >= beat.open) provisional = (settled ? ' ' : '') + heard;
    break;
  }
  if (t < beat.open) settled = '';
  return {
    state, visible: t >= beat.open && t < beat.hidden, growth, expansion: clamp(growth),
    elapsed: `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`,
    bars, settled, provisional, hint: active,
    keyHud: smooth(between(t, beat.finish - .012, beat.finish - .004)) * (1 - smooth(between(t, beat.finish + .03, beat.finish + .04))),
  };
}

/** The resting composer: no session, the mic at rest. */
export const IDLE_DICTATION: DictationSnapshot = dictationSnapshot(0);
