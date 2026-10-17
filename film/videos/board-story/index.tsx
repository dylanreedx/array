import { AbsoluteFill, Sequence, useCurrentFrame, useVideoConfig } from 'remotion';
import { Lockup } from '../../legacy/acts/Lockup';
import { CaptionBand } from '../../legacy/acts/edu/Caption';
import { SPRING, track } from '../../legacy/lib/anim';
import { Footage } from '../../legacy/lib/Footage';
import { bandOf } from '../../legacy/lib/formats';
import { defineVideo, type CueSheet } from '../../legacy/lib/sheet';
import type { Scene } from '../../legacy/lib/replay';
import '../../legacy/lib/fonts';
import { BPM, TAKES, shots, timeline } from './timeline';

const Video: React.FC<{ sheet: CueSheet; viewport?: { width: number; height: number } }> = ({ sheet, viewport }) => {
  const f = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const output = viewport ?? { width, height };
  const lockupAt = sheet.acts.lockup.from;
  return (
    <AbsoluteFill style={{ background: '#0b0d10' }}>
      {shots(sheet.clock).map((s) => (
        <Sequence key={s.id} from={s.from} durationInFrames={s.len} layout="none">
          {/* inside the shot's Sequence frames are shot-relative, so the take starts at 0 */}
          <Footage take={TAKES[s.id]} from={0} trim={s.trim} keys={[]} viewport={viewport} />
        </Sequence>
      ))}
      <CaptionBand lines={sheet.lines} band={bandOf(output)} output={output} fade={track(f, fps, 0, [{ at: lockupAt, to: 1 }], SPRING.heavy)} />
      <Lockup from={lockupAt} lines={sheet.lines} output={output} />
    </AbsoluteFill>
  );
};

export default defineVideo({
  slug: 'board-story',
  title: 'Hand it to an agent',
  bpm: BPM,
  formats: ['landscape'],
  build: timeline,
  scene: {} as Scene,
  Component: Video,
});
