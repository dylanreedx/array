// This film's faces come from its look (looks/ink-lime): Schibsted Grotesk (the film's voice) and
// JetBrains Mono (Ghostty's own default face, so the terminal reads as Ghostty), both SIL OFL 1.1 with their
// licences in public/fonts/. SF Pro (system-ui) stays the macOS chrome's face: title bar and tabs.
import { loadFonts } from '../../kit/fonts';
import { LOOK } from './constants';

export const DISPLAY = LOOK.type.display;
export const MONO = LOOK.type.mono;
export const SYSTEM = LOOK.type.system;
loadFonts(LOOK.fonts);
