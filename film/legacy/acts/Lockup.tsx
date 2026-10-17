// The end card: the canvas dims, the Array mark springs in (heavy, no overshoot), then the lockup's
// lines reveal. Drawn over the whole output (the caption band dims with everything else). The mark
// is website/public/array-logo-blue.svg (copied to public/marks/), the favicon artwork, cropped to an icon tile around its glyph.
import { Img, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { SPRING, sprAt, track } from '../lib/anim';
import { CAPTION_FONT } from '../lib/fonts';
import type { Line } from '../lib/sheet';

/** The glyph's box inside the 480-unit artwork, padded to a square. */
const CROP = { x: 128, y: 140, size: 224 };

export const Mark: React.FC<{ size: number }> = ({ size }) => {
  const k = size / CROP.size;
  return (
    <div style={{ position: 'relative', width: size, height: size, borderRadius: size * 0.225, overflow: 'hidden', flex: 'none', boxShadow: `0 ${size * 0.06}px ${size * 0.3}px rgb(124 195 219 / 0.18)` }}>
      {/* maxWidth: Tailwind's preflight clamps every img to its container */}
      <Img src={staticFile('marks/array-logo-blue.svg')} style={{ position: 'absolute', left: -CROP.x * k, top: -CROP.y * k, width: 480 * k, height: 480 * k, maxWidth: 'none' }} />
    </div>
  );
};

export const Lockup: React.FC<{ from: number; lines: Line[]; output: { width: number; height: number } }> = ({ from, lines, output }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (f < from) return null;
  const { width, height } = output;
  const unit = Math.min(width, height) / 1080;
  const portrait = height > width;
  const dim = track(f, fps, 0, [{ at: from, to: 0.975 }], SPRING.heavy);
  const mark = sprAt(f, from + Math.round(fps * 0.1), fps, SPRING.heavy);
  const word = sprAt(f, from + Math.round(fps * 0.25), fps, SPRING.heavy);
  // Every line is laid out from the start (invisible until its frame), so nothing shifts as they reveal.
  const own = lines.filter((l) => l.place === 'lockup');
  const markSize = (portrait ? 150 : 132) * unit;
  return (
    <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
      <div style={{ position: 'absolute', inset: 0, background: `rgb(8 9 11 / ${dim})` }} />
      <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 40 * unit }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 34 * unit }}>
          <div style={{ opacity: mark, transform: `scale(${0.86 + 0.14 * mark})` }}><Mark size={markSize} /></div>
          <div style={{ opacity: word, transform: `translateX(${(1 - word) * -24 * unit}px)`, color: '#f2f4f8', font: `600 ${markSize * 0.92}px/1 ${CAPTION_FONT}`, letterSpacing: '-0.045em' }}>Array</div>
        </div>
        {own.map((l, i) => {
          const k = sprAt(f, l.from, fps, SPRING.type);
          const big = l.size === 'hook';
          return (
            <div key={l.id} style={{ maxWidth: width * 0.86, textAlign: 'center', opacity: k, transform: `translateY(${(1 - k) * 18 * unit}px)`, marginTop: i === 0 ? 8 * unit : -12 * unit,
              color: big ? '#f2f4f8' : '#9aa4b2', font: `${big ? 600 : 500} ${(big ? (portrait ? 64 : 76) : (portrait ? 34 : 38)) * unit}px/1.15 ${CAPTION_FONT}`, letterSpacing: big ? '-0.03em' : '-0.005em' }}>
              {l.text}
            </div>
          );
        })}
      </div>
    </div>
  );
};
