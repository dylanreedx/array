// Burned-in caption for the current Line. Social cuts burn captions in (most feeds autoplay
// muted); the landscape master ships a sidecar .srt instead (scripts/export-srt.ts).
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { E, prog } from '../../lib/anim';
import type { Line } from '../../lib/sheet';

export const CaptionBar: React.FC<{ lines: Line[] }> = ({ lines }) => {
  const f = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const line = lines.find((l) => f >= l.from && f < l.to);
  if (!line) return null;
  const k = prog(f, line.from, line.from + 10, E.out) * (1 - prog(f, line.to - 8, line.to, E.in));
  const portrait = height > width;
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: portrait ? height * 0.14 : height * 0.07, display: 'flex', justifyContent: 'center', opacity: k, transform: `translateY(${(1 - k) * 10}px)` }}>
      <span style={{ maxWidth: width * 0.8, padding: '10px 18px', borderRadius: 10, background: 'rgb(16 19 24 / 88%)', border: '.5px solid rgb(174 182 194 / 30%)', color: '#f2f4f8', font: `500 ${portrait ? 40 : 34}px/1.25 var(--font-sans)`, textAlign: 'center', letterSpacing: '-0.01em' }}>
        {line.text}
      </span>
    </div>
  );
};
