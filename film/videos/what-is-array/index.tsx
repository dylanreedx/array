import { useLayoutEffect } from 'react';
import { Freeze, useCurrentFrame, useVideoConfig } from 'remotion';
import { Lockup } from '../../legacy/acts/Lockup';
import { Spotlight } from '../../legacy/acts/edu/Spotlight';
import { SPRING, sprAt, track } from '../../legacy/lib/anim';
import { Film } from '../../legacy/lib/Film';
import { useLens } from '../../legacy/lib/Lens';

import { defineVideo, type CueSheet } from '../../legacy/lib/sheet';
import type { Scene } from '../../legacy/lib/replay';
import scene from './scene.json';
import { BPM, PILL, pillWorld, siteCut, siteLens, subjects, timeline } from './timeline';

/**
 * Witness for PILL: the hook frames the "Needs attention" pill by its measured tile-local rect. If the
 * website moves it (copy, padding, font), this warns with the `[film]` prefix and scripts/gate.ts fails.
 */
const PillProbe: React.FC = () => {
  const f = useCurrentFrame();
  useLayoutEffect(() => {
    const tile = document.querySelector<HTMLElement>('[data-film-stage] [data-assembly-surface="verify"]');
    const pill = tile?.querySelector<HTMLElement>('[class*="statusPill"]');
    if (!tile || !pill || pill.textContent !== 'Needs attention') return;
    let x = 0, y = 0, el: HTMLElement | null = pill;
    while (el && el !== tile) { x += el.offsetLeft; y += el.offsetTop; el = el.offsetParent as HTMLElement | null; }
    const got = { x, y, width: pill.offsetWidth, height: pill.offsetHeight };
    if (Object.entries(PILL).some(([k, v]) => Math.abs(got[k as keyof typeof got] - v) > 1)) console.warn(`[film] what-is-array PILL is ${JSON.stringify(PILL)} but the website draws ${JSON.stringify(got)} at f${f}`);
  });
  return null;
};

const HookSpotlight: React.FC<{ sheet: CueSheet }> = ({ sheet }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const lens = useLens();
  const amount = 1 - sprAt(f, sheet.clock.b(2), fps, SPRING.heavy);
  const r = lens.outRect({ world: pillWorld() });
  return <Spotlight rect={r} amount={amount} radius={8 * lens.uiScale} inflate={r.height * 0.2} />;
};

const SubjectDim: React.FC<{ sheet: CueSheet }> = ({ sheet }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const lens = useLens();
  const s = subjects(sheet.clock);
  const amount = track(f, fps, 0, s.amount, SPRING.soft);
  if (amount < 0.002) return null;
  const at = (k: 'x' | 'y' | 'width' | 'height') => track(f, fps, s.first[k], s.rect.map((r) => ({ at: r.at, to: r.to[k] })), SPRING.soft);
  const r = lens.outRect({ world: { x: at('x'), y: at('y'), width: at('width'), height: at('height') } });
  return <Spotlight rect={r} amount={amount} radius={10 * lens.uiScale} inflate={2} glow={false} />;
};

const Video: React.FC<{ sheet: CueSheet; viewport?: { width: number; height: number }; format?: string }> = ({ sheet, viewport, format }) => {
  const f = useCurrentFrame();
  if (format === 'site') {
    // The website cut replays the master's own frames from bar 2, then holds the last one.
    const { from, to } = siteCut(sheet.clock);
    return <Freeze frame={Math.min(f + from, to - 1)}><Film sheet={sheet} scene={scene as Scene} viewport={viewport} commandCenter="frame" ringScale={2} captions={false} /></Freeze>;
  }
  const { fps, width, height } = useVideoConfig();
  const output = viewport ?? { width, height };
  const lockupAt = sheet.acts.lockup.from;
  const bandFade = track(f, fps, 0, [{ at: lockupAt, to: 1 }], SPRING.heavy);
  return (
    <Film sheet={sheet} scene={scene as Scene} viewport={viewport} commandCenter="frame" ringScale={2} band bandFade={bandFade}
      under={<><PillProbe /><HookSpotlight sheet={sheet} /><SubjectDim sheet={sheet} /></>}
      over={<Lockup from={lockupAt} lines={sheet.lines} output={output} />} />
  );
};

export default defineVideo({
  slug: 'what-is-array',
  title: 'What Array is',
  bpm: BPM,
  formats: ['landscape', 'portrait', 'square', 'site'],
  build: timeline,
  site: (c) => { const s = timeline(c); const { from, to, hold } = siteCut(c); return { ...s, durationInFrames: to - from + hold, lens: siteLens(c, s.lens) }; },
  scene: scene as Scene,
  Component: Video,
});
