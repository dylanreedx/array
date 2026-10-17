// The narration: one line at a time in the format's reserved band (lib/formats.ts bandOf), never
// over UI. Enter is a quick critically damped rise with opacity (SPRING.type), exit an 8-frame fade.
// `words` lines reveal word by word, two beats' sixteenth apart. Social cuts burn these in (most
// feeds autoplay muted); the srt sidecar comes from the same lines (scripts/export-srt.ts).
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { E, prog, SPRING, sprAt } from '../../lib/anim';
import { CAPTION_FONT } from '../../lib/fonts';
import type { Band } from '../../lib/formats';
import type { Line } from '../../lib/sheet';

export const BAND_FILL = '#08090b';

/** Caption size in px for an output: 84 at 1080p landscape, 120 for the hook; smaller on narrow frames. */
export const captionSize = ({ width, height }: { width: number; height: number }, hook = false) => {
  const unit = Math.min(width, height) / 1080;
  if (height > width) return (hook ? 92 : 70) * unit;
  if (height === width) return (hook ? 88 : 66) * unit;
  return (hook ? 120 : 84) * unit;
};

export const CaptionBand: React.FC<{ lines: Line[]; band: Band; output: { width: number; height: number }; fade?: number }> = ({ lines, band, output, fade = 0 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const { width } = output;
  const top = band.edge === 'top';
  const line = lines.find((l) => (l.place ?? 'band') === 'band' && f >= l.from && f < l.to);
  const size = line ? captionSize(output, line.size === 'hook') : 0;
  const exit = line ? 1 - prog(f, line.to - 8, line.to, E.in) : 0;
  const rise = (start: number) => sprAt(f, start, fps, SPRING.type);
  const words = line ? line.text.split(' ') : [];
  const stagger = Math.round((60 / 120) * fps / 4); // a sixteenth at 120 BPM
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, [top ? 'top' : 'bottom']: 0, height: band.size, opacity: 1 - fade, pointerEvents: 'none' }}>
      {/* The band is solid; a short gradient on its inner edge lets the canvas fall off instead of cutting. */}
      <div style={{ position: 'absolute', inset: 0, background: BAND_FILL }} />
      <div style={{ position: 'absolute', left: 0, right: 0, height: band.size * 0.22, [top ? 'top' : 'bottom']: '100%', background: `linear-gradient(${top ? '180deg' : '0deg'}, ${BAND_FILL}, ${BAND_FILL}00)` }} />
      {line && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: `0 ${width * 0.06}px` }}>
          <div style={{ maxWidth: width * 0.88, textAlign: 'center', color: '#f2f4f8', font: `600 ${size}px/1.08 ${CAPTION_FONT}`, letterSpacing: '-0.025em', opacity: exit, textWrap: 'balance' as never }}>
            {line.words
              ? words.map((w, i) => {
                  const k = rise(line.from + i * stagger);
                  return <span key={i} style={{ display: 'inline-block', opacity: k, transform: `translateY(${(1 - k) * size * 0.32}px)`, marginRight: i < words.length - 1 ? '0.26em' : 0 }}>{w}</span>;
                })
              : <span style={{ display: 'inline-block', opacity: rise(line.from), transform: `translateY(${(1 - rise(line.from)) * size * 0.32}px)` }}>{line.text}</span>}
          </div>
        </div>
      )}
    </div>
  );
};
