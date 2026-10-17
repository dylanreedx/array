// A short label that points at a subject inside the app. Position comes from the lens, so the
// callout follows its tile through camera moves and across formats.
import { useCurrentFrame } from 'remotion';
import { E, prog } from '../../lib/anim';

export const Callout: React.FC<{ text: string; from: number; to: number; x: number; y: number; color?: string }> = ({ text, from, to, x, y, color = '#ffb347' }) => {
  const f = useCurrentFrame();
  if (f < from || f >= to) return null;
  const k = prog(f, from, from + 12, E.out) * (1 - prog(f, to - 8, to, E.in));
  return (
    <div style={{ position: 'absolute', left: x, top: y, transform: `translate(-50%, calc(-100% - 14px)) translateY(${(1 - k) * 8}px)`, opacity: k, display: 'flex', alignItems: 'center', gap: 10, padding: '8px 14px', borderRadius: 10, background: '#14171c', border: `1px solid ${color}`, color: '#f2f4f8', font: '500 22px var(--font-sans)', whiteSpace: 'nowrap' }}>
      <span style={{ width: 9, height: 9, borderRadius: 9, background: color }} />
      {text}
    </div>
  );
};
