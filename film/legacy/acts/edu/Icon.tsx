// Icons for the narration pill (Line.icon, or `{name}` tokens inside a line's text). Line icons are
// drawn on the clock chip's grid (previews/day/kit.tsx `Glyph`: 24 units, 2.4 stroke, round caps), so
// a caption and the chip read as one set; the two provider marks are the website's own SVGs
// (public/icons, copied from website/public), filled in the pill's ink. Every icon occupies a 1em
// square whose drawing spans ~17 units, which at Geist's proportions is the cap height.
import { Img, staticFile } from 'remotion';
import { CAPTION_ICONS, type CaptionIcon } from '../../lib/sheet';

/** Units of the 24-unit box a drawing spans: the box is sized so this equals the cap height. */
const SPAN = 17;
/** The icon's square side for a caption set at `size` px, and its cap height (Geist ~0.71em). */
export const iconBox = (size: number, cap = size * 0.71) => (cap * 24) / SPAN;

/** `{name}` → the icon it names; anything else is a word. An unknown name is an authoring error. */
export const iconToken = (word: string): CaptionIcon | null => {
  const m = /^\{([a-z-]+)\}$/.exec(word);
  if (!m) return null;
  if (!(CAPTION_ICONS as readonly string[]).includes(m[1])) throw new Error(`caption icon "{${m[1]}}" is not in CAPTION_ICONS (${CAPTION_ICONS.join(', ')})`);
  return m[1] as CaptionIcon;
};

/** A line's words as the pill sets them: its leading icon (if any) as a token, then the text. */
export const lineText = (l: { text: string; icon?: CaptionIcon }) => (l.icon ? `{${l.icon}} ${l.text}` : l.text);

/** 0..1 luminance of '#rrggbb' or 'rgb(r, g, b)' (the inks Pill and Bubble pass). */
const luma = (c: string) => {
  const v = c.startsWith('#') ? [1, 3, 5].map((k) => parseInt(c.slice(k, k + 2), 16)) : (c.match(/\d+(\.\d+)?/g) ?? ['255', '255', '255']).slice(0, 3).map(Number);
  return (0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]) / 255;
};

const MARKS: Partial<Record<CaptionIcon, string>> = { claude: 'icons/provider-anthropic.svg', codex: 'icons/provider-openai.svg' };

/** One icon, `px` square, stroked (or for a provider mark, filled) in `color`. */
export const CaptionGlyph: React.FC<{ icon: CaptionIcon; px: number; color?: string; style?: React.CSSProperties }> = ({ icon, px, color = '#ffffff', style }) => {
  const mark = MARKS[icon];
  if (mark) {
    // The marks are black-filled SVGs: invert to white, or keep them dark on a light tone's pill.
    const inset = (px * (24 - SPAN)) / 2 / 24;
    const light = luma(color) > 0.5;
    return (
      <span style={{ display: 'inline-block', width: px, height: px, position: 'relative', ...style }}>
        <Img src={staticFile(mark)} style={{ position: 'absolute', left: inset, top: inset, width: px - inset * 2, height: px - inset * 2, objectFit: 'contain', filter: light ? 'brightness(0) invert(1)' : 'brightness(0)' }} />
      </span>
    );
  }
  const s = { fill: 'none', stroke: color, strokeWidth: 2.4, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <svg width={px} height={px} viewBox="0 0 24 24" style={{ display: 'inline-block', overflow: 'visible', ...style }}>
      {icon === 'branch' && <><path d="M6.5 3.5v13" {...s} /><circle cx={6.5} cy={18} r={2.5} {...s} /><circle cx={17.5} cy={6} r={2.5} {...s} /><path d="M17.5 8.5a8 8 0 0 1-8 8H9" {...s} /></>}
      {icon === 'push' && <><path d="M5 4h14" {...s} /><path d="M12 20.5V8.5" {...s} /><path d="M7 13.5l5-5 5 5" {...s} /></>}
      {icon === 'merge' && <><circle cx={6.5} cy={6} r={2.5} {...s} /><circle cx={17.5} cy={17.5} r={2.5} {...s} /><path d="M6.5 8.5v12" {...s} /><path d="M6.5 9.5a8 8 0 0 0 8 8H15" {...s} /></>}
      {icon === 'sound' && <><path d="M4 9.5h3l4.5-4v13l-4.5-4H4z" {...s} /><path d="M15 9a4.2 4.2 0 0 1 0 6" {...s} /><path d="M18 6a8.5 8.5 0 0 1 0 12" {...s} /></>}
      {icon === 'check' && <path d="M5 12.5l4.5 4.5L19 7.5" {...s} />}
      {icon === 'ticket' && <><path d="M3.5 8a2 2 0 0 1 2-2h13a2 2 0 0 1 2 2v1.5a2.5 2.5 0 0 0 0 5V16a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2v-1.5a2.5 2.5 0 0 0 0-5z" {...s} /><path d="M14 8.5v1M14 11.5v1M14 14.5v1" {...s} /></>}
      {icon === 'eye' && <><path d="M3 12s3.3-6 9-6 9 6 9 6-3.3 6-9 6-9-6-9-6z" {...s} /><circle cx={12} cy={12} r={2.6} {...s} /></>}
      {icon === 'keyboard' && <><rect x={3} y={6.5} width={18} height={11} rx={2.5} {...s} /><path d="M7 10.5h0M10.3 10.5h0M13.7 10.5h0M17 10.5h0M8.5 14h7" {...s} /></>}
      {icon === 'wand' && <><path d="M5 19.5L15 9.5" {...s} /><path d="M13 7.5l3.5 3.5" {...s} /><path d="M18.5 3.5v4M16.5 5.5h4" {...s} /><path d="M19.5 12.5v2.5M18.25 13.75h2.5" {...s} /><path d="M10 3.5v2.5M8.75 4.75h2.5" {...s} /></>}
      {icon === 'tidy' && <><rect x={4} y={4} width={16} height={4.5} rx={1.6} {...s} /><rect x={4} y={10.5} width={16} height={4.5} rx={1.6} {...s} /><rect x={4} y={17} width={9.5} height={3.5} rx={1.6} {...s} /></>}
      {icon === 'board' && <><rect x={3.5} y={3.5} width={17} height={17} rx={3} {...s} /><path d="M8 7.5v8M12 7.5v4.5M16 7.5v6" {...s} /></>}
      {icon === 'sidebar' && <><rect x={3.5} y={4.5} width={17} height={15} rx={2.5} {...s} /><path d="M9.5 4.5v15" {...s} /><path d="M6 8.5h1M6 11.5h1" {...s} /></>}
    </svg>
  );
};
