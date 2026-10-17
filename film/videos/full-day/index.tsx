// "A day in Array" (video 2): see timeline.ts. The takes play through the five time-of-day
// transitions; over each chapter ride the glove (the harness's pointer track), tile tags, key caps
// for every shortcut pressed, the redrawn menus, and the clock docked in the corner.
import { AbsoluteFill, Freeze, OffthreadVideo, Sequence, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Lockup } from '../../legacy/acts/Lockup';
import { Bubble } from '../../legacy/acts/edu/Bubble';
import { HandCursor } from '../../legacy/acts/edu/HandCursor';
import { Tag } from '../../legacy/acts/edu/Tag';
import { defineVideo, type CueSheet } from '../../legacy/lib/sheet';
import type { PointerTrack } from '../../legacy/lib/pointer';
import type { Scene } from '../../legacy/lib/replay';
import { ClockChip, KeyCaps } from '../../legacy/previews/day/kit';
import { MacMenu, menuPointer, type MenuItem } from '../../legacy/previews/day/MacMenu';
import { Coffee, HeadsDown, Lunch, Sounds, Sunrise, Sunset, type Feed } from '../../legacy/previews/day/Transitions';
import '../../legacy/lib/fonts';
import { AFTER, BEFORE, BPM, LAPSE_TAKE, TRACKS, layout, timeline, type ChapterSpec, type Placed, type PlacedChapter } from './timeline';

const H = 1080;
const K = H / 1048;

/** One frame of a take, covering the frame and anchored left (the sidebar keeps its labels). */
const Clip: React.FC<{ take: string; frame: number; style?: React.CSSProperties }> = ({ take, frame, style }) => {
  const last = TRACKS[take].frames - 2;
  return (
    <Freeze frame={0}>
      <AbsoluteFill style={style}>
        <OffthreadVideo src={staticFile(`footage/full-day/${take}.mp4`)} muted trimBefore={Math.max(0, Math.min(last, Math.round(frame)))}
          style={{ position: 'absolute', left: 0, top: 0, width: 1920 * K, height: H, maxWidth: 'none' }} />
      </AbsoluteFill>
    </Freeze>
  );
};

const feed = (take: string, start: number): Feed => (n, style) => <Clip take={take} frame={start + n} style={style} />;

const Transition: React.FC<{ p: Placed }> = ({ p }) => {
  // The sounds interstitial follows the time-lapse, so it floods out of the lapse's last frame.
  const before = p.id === 'sounds' ? feed(LAPSE_TAKE, TRACKS[LAPSE_TAKE].frames - 2 - BEFORE.sounds)
    : p.prev ? feed(p.prev.take, p.prev.to) : undefined;
  const after = feed(p.next.take, p.next.from - AFTER[p.id]);
  switch (p.id) {
    case 'sunrise': return <Sunrise after={after} />;
    case 'coffee': return <Coffee before={before} after={after} />;
    case 'lunch': return <Lunch before={before} after={after} rows={p.cards} to={p.next.clock} />;
    case 'headsdown': return <HeadsDown lapse={{ src: feed(LAPSE_TAKE, 0), length: TRACKS[LAPSE_TAKE].frames }} track={TRACKS[LAPSE_TAKE]} map={(x, y) => ({ x: x * K, y: y * K })} from={13 * 60 + 30} to={p.next.clock} />;
    case 'sounds': return <Sounds before={before} after={after} mins={p.next.clock} />;
    case 'sunset': return <Sunset before={before} after={after} from={p.prev?.clock ?? 15 * 60} />;
  }
};

/** Key caps for the shortcuts pressed in a take (typing is visible in the app itself). */
const takeKeys = (t: PointerTrack) => {
  const out: { keys: string[]; from: number; to: number }[] = [];
  const keys = t.keys ?? [];
  const split = (label: string) => {
    const mods = [...label].filter((ch) => '⌘⌥⇧⌃'.includes(ch));
    const rest = [...label].filter((ch) => !'⌘⌥⇧⌃'.includes(ch)).join('');
    return [...mods, ...(rest ? [rest] : [])];
  };
  for (const k of keys) {
    if (k.kind === 'press' && k.label !== 'Return') out.push({ keys: split(k.label), from: k.frame, to: k.frame + 54 });
    if (k.kind === 'holdStart') {
      const end = keys.find((e) => e.kind === 'holdEnd' && e.frame > k.frame)?.frame ?? k.frame + 90;
      out.push({ keys: split(k.label), from: k.frame, to: end + 8 });
    }
  }
  // one set of caps at a time: a new press ends the one before
  for (let i = 0; i + 1 < out.length; i++) out[i].to = Math.min(out[i].to, out[i + 1].from - 2);
  return out;
};

/** The menus a take opened, each paired with what was chosen. */
const takeMenus = (t: PointerTrack) => {
  const menus = t.menus ?? [];
  return menus.filter((x) => x.kind === 'open').map((open) => {
    const choose = menus.find((x) => x.kind === 'choose' && x.frame > open.frame);
    const end = choose?.frame ?? open.frame + 40;
    const span = end - open.frame;
    return { items: open.items as MenuItem[], anchor: open.anchor as [number, number], open: open.frame, choose: end, path: choose?.path ?? [],
      hoverAt: (choose?.path ?? []).map((_, d) => open.frame + Math.round(span * (0.3 + 0.35 * d))) };
  });
};

const Chapter: React.FC<{ p: PlacedChapter; sheet: CueSheet; f: number }> = ({ p, sheet, f }) => {
  const { spec, offset } = p;
  const t = TRACKS[spec.take];
  const i = f - offset;
  const map = (x: number, y: number) => ({ x: x * K, y: y * K });
  const output = { width: 1920, height: H };
  const { fps } = useVideoConfig();
  const lines = sheet.lines.filter((l) => l.id.startsWith(`${spec.id}:`));
  const menus = takeMenus(t);
  // While a redrawn menu is up, the glove walks its rows (the harness's pointer sat still: the real
  // menu never popped).
  const gloveTrack = menus.length === 0 ? t : { ...t, p: t.p.map((pp, n) => {
    const up = menus.find((mm) => n >= mm.open && n <= mm.choose + 8);
    const at = up ? menuPointer(up.items, up.anchor, 1, up.path, up.hoverAt, n) : null;
    return at ? [at[0], at[1], 0, 0] : pp;
  }) as PointerTrack['p'] };
  return (
    <AbsoluteFill>
      <Clip take={spec.take} frame={i} />
      {menus.map((mm, k) => (
        <div key={k} style={{ position: 'absolute', inset: 0, transform: `scale(${K})`, transformOrigin: '0 0' }}>
          <MacMenu items={mm.items} anchor={mm.anchor} k={1} f={i} open={mm.open} path={mm.path} hoverAt={mm.hoverAt} choose={mm.choose} />
        </div>
      ))}
      <HandCursor t={gloveTrack} i={i} map={map} unit={1} />
      <Tag t={t} lines={lines} f={f} offset={offset} map={map} unit={1} output={output} />
      <Bubble t={t} lines={lines} f={f} offset={offset} map={map} unit={1} output={output} />
      {takeKeys(t).map((k, n) => <KeyCaps key={n} keys={k.keys} f={i} from={k.from} to={k.to} fps={fps} />)}
      <ClockChip mins={spec.clock} icon={spec.icon} dock={1} />
    </AbsoluteFill>
  );
};

const Video: React.FC<{ sheet: CueSheet }> = ({ sheet }) => {
  const f = useCurrentFrame();
  const { parts } = layout();
  const lockupAt = sheet.acts.lockup.from;
  const current = parts.find((p) => f >= p.at && f < p.at + p.dur);
  const lastChapter = [...parts].reverse().find((p) => p.kind === 'chapter') as PlacedChapter;
  return (
    <AbsoluteFill style={{ background: '#0b0d10', overflow: 'hidden' }}>
      {parts.filter((p): p is Placed => p.kind === 'transition').map((p) => (
        <Sequence key={p.id} from={p.at} durationInFrames={p.dur}><Transition p={p} /></Sequence>
      ))}
      {current?.kind === 'chapter' && <Chapter p={current} sheet={sheet} f={f} />}
      {f >= lockupAt && <Clip take={lastChapter.spec.take} frame={lastChapter.spec.to} />}
      <Lockup from={lockupAt} lines={sheet.lines} output={{ width: 1920, height: H }} />
    </AbsoluteFill>
  );
};

export default defineVideo({
  slug: 'full-day',
  title: 'A day in Array',
  bpm: BPM,
  formats: ['landscape'],
  build: timeline,
  scene: {} as Scene,
  Component: Video,
});

export type { ChapterSpec };
