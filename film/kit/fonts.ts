// Load a look's faces before the first frame: one delayRender per face, released when the face is in
// document.fonts. Files live in public/fonts/ with their licences beside them.
import { continueRender, delayRender, staticFile } from 'remotion';
import type { FontFile } from './look';

export const loadFonts = (fonts: FontFile[]) => {
  for (const { family, file, weight } of fonts) {
    if (typeof document === 'undefined' || document.fonts.check(`500 20px "${family}"`)) continue;
    const handle = delayRender(`load ${family}`);
    const face = new FontFace(family, `url(${staticFile(`fonts/${file}`)})`, { weight });
    face.load().then((f) => { document.fonts.add(f); continueRender(handle); }, (e) => { throw e; });
  }
};
