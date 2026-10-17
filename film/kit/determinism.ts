// Imported first by src/index.ts. A frame must be a pure function of useCurrentFrame(): Remotion renders
// frames out of order across several tabs, so anything on wall-clock time (a CSS transition, an animation,
// a blinking caret, a focus ring) would make a frame depend on how long its screenshot took.
//
//   - kit/base.css: the page every film draws on (box model, replaced elements, smoothing)
//   - no CSS transition or animation anywhere; motion is a function of the frame, written in the video
//   - no caret, no focus ring
//   - randomness only from rand(seed) (kit/anim.ts), never Math.random()
import './base.css';

const css = document.createElement('style');
css.dataset.film = 'determinism';
css.textContent = `
*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }
:focus, :focus-visible { outline: none !important; }
`;
document.head.appendChild(css);
document.documentElement.dataset.film = 'true';
