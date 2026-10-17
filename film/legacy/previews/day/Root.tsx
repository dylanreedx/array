// Preview entry for the full-day film's transitions: one composition per transition, plus the reel.
import { AbsoluteFill, Composition, Img, Sequence, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Bubble } from '../../acts/edu/Bubble';
import { HandCursor } from '../../acts/edu/HandCursor';
import { Tag } from '../../acts/edu/Tag';
import type { PointerTrack } from '../../lib/pointer';
import type { CaptionIcon, Line } from '../../lib/sheet';
import { MacMenu, menuPointer, type MenuItem } from './MacMenu';
import { KeyCaps, Label, Shot } from './kit';
import { TRANSITIONS } from './Transitions';

const Reel: React.FC = () => {
  let at = 0;
  return (
    <>
      {TRANSITIONS.map((t, i) => {
        const from = at;
        at += t.dur;
        return (
          <Sequence key={t.id} from={from} durationInFrames={t.dur}>
            <t.C />
            <Label n={i + 1} title={t.title} />
          </Sequence>
        );
      })}
    </>
  );
};

const Keys: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill>
      <Shot frame={900} />
      <KeyCaps keys={['⌘', 'K']} f={f} from={10} to={80} fps={fps} />
      <KeyCaps keys={['⌥']} f={f} from={100} to={170} fps={fps} />
      <KeyCaps keys={['Return']} f={f} from={190} to={240} fps={fps} />
    </AbsoluteFill>
  );
};

const MENU: MenuItem[] = [{"enabled": false, "on": false, "title": "roast-web / Project Root"}, {"separator": true}, {"enabled": true, "on": false, "title": "Rename"}, {"enabled": true, "on": false, "submenu": [{"enabled": true, "on": false, "title": "Teal"}, {"enabled": true, "on": true, "title": "Blue"}, {"enabled": true, "on": false, "title": "Mint"}, {"enabled": true, "on": false, "title": "Purple"}, {"enabled": true, "on": false, "title": "Orange"}, {"enabled": true, "on": false, "title": "Yellow"}, {"enabled": true, "on": false, "title": "Red"}], "title": "Color"}, {"enabled": true, "on": false, "title": "Change Project/Home\u2026"}, {"separator": true}, {"enabled": true, "on": false, "submenu": [{"enabled": true, "on": true, "title": "Use Global"}, {"enabled": true, "on": false, "title": "On"}, {"enabled": true, "on": false, "title": "Off"}], "title": "Auto Layout"}, {"separator": true}, {"enabled": true, "on": false, "title": "Tidy Zone Now"}, {"enabled": true, "on": false, "title": "Collapse"}, {"separator": true}, {"enabled": true, "on": false, "title": "Close Zone\u2026"}];
const Menu: React.FC = () => {
  const f = useCurrentFrame();
  const k = 1080 / 1048;
  const p = menuPointer(MENU, [1431.5, 233.5], k, ['Color', 'Orange'], [24, 46], f);
  return (
    <AbsoluteFill style={{ background: '#000' }}>
      <Img src={staticFile('footage/smoke/zone-250.png')} style={{ position: 'absolute', left: 0, top: 0, width: 1920 * k, height: 1080 }} />
      <MacMenu items={MENU} anchor={[1431.5, 233.5]} k={k} f={f} open={8} path={['Color', 'Orange']} hoverAt={[24, 46]} choose={64} />
      {p && <div style={{ position: 'absolute', left: p[0] - 9, top: p[1] - 9, width: 18, height: 18, borderRadius: 9, background: '#ff4f8b', border: '3px solid #fff' }} />}
    </AbsoluteFill>
  );
};

// Caption icons: one tile tag per icon (the real Tag, pinned to an invisible rect), a dark-ink tone,
// and the motivating two-logo line spoken by the cursor's Bubble.
const ICON_TAGS: [CaptionIcon, string, Line['tone']?][] = [
  ['claude', 'Claude'], ['codex', 'Codex'], ['branch', 'On its own branch.'], ['push', 'Pushed.'],
  ['merge', 'Merged.'], ['sound', 'Sounds on.'], ['check', 'Done.'], ['ticket', 'RST-43'],
  ['eye', 'Seen it?'], ['keyboard', 'Shortcuts.'], ['wand', 'Close'], ['tidy', 'Tidy.'],
  ['board', 'Board'], ['sidebar', 'Sidebar'], ['check', 'Done.', 'green'], ['codex', 'Codex is done.', 'green'],
];
const ICON_RECT = (k: number): [number, number, number, number] => [80 + (k % 4) * 450, 120 + Math.floor(k / 4) * 150, 400, 60];
const ICON_TRACK: PointerTrack = {
  fps: 60, pointSize: [1920, 1080], frames: 1, p: [[600, 760, 0, 0]], v: [[0, 0, 1]], events: [], marks: {},
  rects: Object.fromEntries(ICON_TAGS.map((_, k) => [`r${k}`, [ICON_RECT(k)]])),
};
const ICON_LINES: Line[] = [
  ...ICON_TAGS.map(([icon, text, tone], k): Line => ({ id: `icon${k}`, from: 4 + k * 3, to: 600, text, icon, tone, place: 'tile', pin: { rect: `r${k}`, side: 'inside-top' } })),
  { id: 'two', from: 30, to: 600, text: '{claude} Claude and {codex} Codex, side by side.', place: 'cursor' },
];
const Icons: React.FC = () => {
  const f = useCurrentFrame();
  const map = (x: number, y: number) => ({ x, y });
  const output = { width: 1920, height: 1080 };
  return (
    <AbsoluteFill>
      <Shot frame={900} />
      <AbsoluteFill style={{ background: 'rgba(11,13,16,0.55)' }} />
      <HandCursor t={ICON_TRACK} i={0} map={map} unit={1} />
      <Tag t={ICON_TRACK} lines={ICON_LINES} f={f} offset={0} map={map} unit={1} output={output} />
      <Bubble t={ICON_TRACK} lines={ICON_LINES} f={f} offset={0} map={map} unit={1} output={output} />
    </AbsoluteFill>
  );
};

export const PreviewRoot: React.FC = () => (
  <>
    {TRANSITIONS.map((t) => <Composition key={t.id} id={`day-${t.id}`} component={t.C} durationInFrames={t.dur} fps={60} width={1920} height={1080} />)}
    <Composition id="day-icons" component={Icons} durationInFrames={180} fps={60} width={1920} height={1080} />
    <Composition id="day-keys" component={Keys} durationInFrames={250} fps={60} width={1920} height={1080} />
    <Composition id="day-menu" component={Menu} durationInFrames={80} fps={60} width={1920} height={1080} />
    <Composition id="day-reel" component={Reel} durationInFrames={TRANSITIONS.reduce((s, t) => s + t.dur, 0)} fps={60} width={1920} height={1080} />
  </>
);
