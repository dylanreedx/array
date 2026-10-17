// The hook's cold open: everything black except one subject, which glows at the app's attention
// rhythm (1.4 s, MacWorkspace's attention ring). `amount` 1 is full black around the subject; the
// pull-back eases it to 0 so the subject is revealed in place, never cut to.
import { useCurrentFrame, useVideoConfig } from 'remotion';
import type { Frame } from '@website/features/demo/types';

export const Spotlight: React.FC<{ rect: Frame; amount: number; radius: number; inflate: number; color?: string; glow?: boolean }> = ({ rect, amount, radius, inflate, color = '255 179 71', glow = true }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (amount <= 0.001) return null;
  const pulse = 0.5 - 0.5 * Math.cos((2 * Math.PI * f) / (1.4 * fps)); // 0 at frame 0, peak at 0.7 s
  return (
    <div style={{
      position: 'absolute', left: rect.x - inflate, top: rect.y - inflate, width: rect.width + 2 * inflate, height: rect.height + 2 * inflate,
      borderRadius: radius + inflate, pointerEvents: 'none',
      boxShadow: `${glow ? `0 0 0 ${inflate * 0.2}px rgb(${color} / ${0.22 * amount * (0.4 + 0.6 * pulse)}), 0 0 ${inflate * 2.4}px ${inflate * 0.5}px rgb(${color} / ${0.2 * amount * pulse}), ` : ''}0 0 0 99999px rgb(8 9 11 / ${amount})`,
    }} />
  );
};
