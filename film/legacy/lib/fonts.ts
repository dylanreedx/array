// The caption face: Geist (SIL Open Font License 1.1, public/fonts/GEIST-OFL.txt), the variable
// woff2 from vercel/geist-font v1.7.2. SF Pro stays inside the UI; captions and the lockup use Geist
// so they read as the film's voice, not as app chrome. Loaded once per tab before the first frame.
import { continueRender, delayRender, staticFile } from 'remotion';

export const CAPTION_FONT = '"Geist", system-ui, sans-serif';

if (typeof document !== 'undefined' && !document.fonts.check('600 20px Geist')) {
  const handle = delayRender('load Geist');
  const face = new FontFace('Geist', `url(${staticFile('fonts/Geist-Variable.woff2')}) format('woff2')`, { weight: '100 900' });
  face.load().then((f) => { document.fonts.add(f); continueRender(handle); }, (e) => { throw e; });
}
