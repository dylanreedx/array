// Ink + lime: "Which tab was that?" (2026-10-16). Tokens, type and motion as the film shipped them at r5.3.
// README.md beside this file says why each value is what it is. Borrow it only when asked: a new video
// starts with its own look (scripts/new-video).
import { E, expo } from '../../kit/anim';
import type { Look } from '../../kit/look';

const DISPLAY = '"Schibsted Grotesk", system-ui, sans-serif';
const MONO = '"JetBrains Mono", ui-monospace, monospace';
const SYSTEM = 'system-ui, -apple-system, sans-serif';

export const inkLime: Look = {
  name: 'ink-lime',
  color: {
    ground: '#0E0F0C',
    text: '#F2F0E9',
    textDim: 'rgba(242, 240, 233, 0.56)',
    /** ONE accent: lime means "finished" and nothing else */
    accent: '#D2E823',
  },
  type: { display: DISPLAY, mono: MONO, system: SYSTEM },
  fonts: [
    { family: 'Schibsted Grotesk', file: 'SchibstedGrotesk-Variable.woff2', weight: '400 900' },
    { family: 'JetBrains Mono', file: 'JetBrainsMono-Variable.ttf', weight: '100 800' },
  ],
  headline: { weight: 600, tracking: '-0.032em', features: '"ss01" 0', ascent: 0.92, leave: 0.35, leaveLift: 0.22, leaveEase: E.in },
  // Words rise through a mask on an exponential ease-out: settled in ~0.6 s, most of the travel in the first 0.25 s.
  words: { stagger: 0.065, dur: 0.62, ease: expo(0.13, 0.62), travel: 108, fadeRate: 2.2, maskTop: 0.08, maskBottom: 0.2, space: 0.24 },
  lockup: {
    cap: 75,
    markOfH: 1.4,
    gapOfH: 0.5,
    // website/public/array-mark.svg with its viewBox cropped to the glyph's ink (161 206.2 158 92.8)
    markAspect: 158 / 92.8,
    markSrc: 'marks/array-mark.svg',
    // SF Pro Display 720 "Array", per em, read off Chrome's render
    word: { text: 'Array', family: `"SF Pro Display", ${SYSTEM}`, weight: 720, tracking: '-0.035em', cap: 0.71, capTop: 0.165, lsb: 0.01, inkW: 2.36 },
    // JetBrains Mono "arrayapp.dev", per em (ascender top re-measured at the 50 px it is set at)
    url: { family: MONO, weight: 400, asc: 0.745, ascTop: 0.08, lsb: 0.06, inkW: 7.08, ascOfH: 0.5, topOfH: 1.2, opacity: 0.6 },
    line: 76,
    beats: { ground: 0.5, lineDelay: 0.25, lineHold: 1.2, lineOut: 0.2, gap: 0.25, lockIn: 0.45, rise: 12, urlDelay: 0.3, urlIn: 0.3 },
    lockEase: E.smooth,
  },
};

export default inkLime;
