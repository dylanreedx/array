import { AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Lockup } from '../../legacy/acts/Lockup';
import { Bubble } from '../../legacy/acts/edu/Bubble';
import { HandCursor } from '../../legacy/acts/edu/HandCursor';
import { Tag } from '../../legacy/acts/edu/Tag';
import { SPRING, sprAt, track } from '../../legacy/lib/anim';
import { lagged } from '../../legacy/lib/pointer';
import { defineVideo, type CueSheet } from '../../legacy/lib/sheet';
import type { Scene } from '../../legacy/lib/replay';
import '../../legacy/lib/fonts';
import { BPM, TAKE, TRACK, timeline, type Punch } from './timeline';

const PUNCH = { hz: 2.2, zeta: 0.7 };

const Video: React.FC<{ sheet: CueSheet; viewport?: { width: number; height: number } }> = ({ sheet, viewport }) => {
  const f = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const output = viewport ?? { width, height };
  const lockupAt = sheet.acts.lockup.from;
  const punches = (sheet as CueSheet & { punches?: Punch[] }).punches ?? [];

  // The take fills the frame (cover): window points -> output px. Any horizontal crop comes off the
  // right, so the sidebar along the left edge keeps its labels.
  const k = Math.max(output.width / TRACK.pointSize[0], output.height / TRACK.pointSize[1]);
  const ox = 0, oy = (output.height - TRACK.pointSize[1] * k) / 2;
  // Punch-ins push toward where the hand was when the payoff landed, then ease back out.
  const punch = punches.reduce((acc, p) => {
    const a = p.amount * (sprAt(f, p.at, fps, PUNCH) - sprAt(f, p.at + p.dur, fps, SPRING.soft));
    if (Math.abs(a) < 1e-4) return acc;
    const h = lagged(TRACK, p.at, 6);
    return { s: acc.s + a, x: ox + h.x * k, y: oy + h.y * k };
  }, { s: 0, x: output.width / 2, y: output.height / 2 });
  const s = 1 + punch.s;
  const map = (x: number, y: number) => ({ x: punch.x + (ox + x * k - punch.x) * s, y: punch.y + (oy + y * k - punch.y) * s });
  const unit = output.height / 1080;
  const fade = track(f, fps, 1, [{ at: lockupAt - 10, to: 0 }], SPRING.snappy);
  const i = Math.min(f, TRACK.frames - 1);

  return (
    <AbsoluteFill style={{ background: '#0b0d10', overflow: 'hidden' }}>
      <div style={{ position: 'absolute', inset: 0, transform: `scale(${s})`, transformOrigin: `${punch.x}px ${punch.y}px` }}>
        <OffthreadVideo src={staticFile(`footage/${TAKE.video}`)} muted style={{ position: 'absolute', left: ox, top: oy, width: TRACK.pointSize[0] * k, height: TRACK.pointSize[1] * k, maxWidth: 'none' }} />
      </div>
      <HandCursor t={TRACK} i={i} map={map} unit={unit} opacity={Math.max(0, fade)} />
      <Tag t={TRACK} lines={sheet.lines} f={f} offset={0} map={map} unit={unit} output={output} opacity={Math.max(0, fade)} />
      <Bubble t={TRACK} lines={sheet.lines} f={f} offset={0} map={map} unit={unit} output={output} opacity={Math.max(0, fade)} />
      <Lockup from={lockupAt} lines={sheet.lines} output={output} />
    </AbsoluteFill>
  );
};

export default defineVideo({
  slug: 'power-tour',
  title: 'A power user’s tour',
  bpm: BPM,
  formats: ['landscape'],
  build: timeline,
  scene: {} as Scene,
  Component: Video,
});
