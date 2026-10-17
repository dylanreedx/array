// Keyboard shortcut chips (e.g. ⌘ K). Used only for shortcuts that work in the app.
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { SPR, spr } from '../../lib/anim';

export const KeyChip: React.FC<{ keys: string[]; from: number; to: number; x: number; y: number }> = ({ keys, from, to, x, y }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (f < from || f >= to) return null;
  const k = spr(f, from, fps, SPR.pop);
  return (
    <div style={{ position: 'absolute', left: x, top: y, display: 'flex', gap: 8, transform: `translate(-50%, -50%) scale(${0.85 + 0.15 * k})`, opacity: k }}>
      {keys.map((key, i) => (
        <kbd key={i} style={{ minWidth: 56, height: 56, padding: '0 14px', display: 'grid', placeItems: 'center', borderRadius: 10, background: '#1c212a', border: '.5px solid rgb(174 182 194 / 30%)', borderBottomWidth: 3, color: '#f2f4f8', font: '600 26px var(--font-sans)' }}>{key}</kbd>
      ))}
    </div>
  );
};
