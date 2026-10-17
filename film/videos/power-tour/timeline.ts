// "A power user's tour": video 3 of the social series, one continuous take of the REAL app (the
// harness filmed it: bench .worktrees/film-harness, scene film/scenes/power-tour.json) with the user's
// hand on screen. The narration is first person. Each line is a tag pinned to the tile it is about, and
// only a line whose subject IS the cursor rides the bubble on it, so the eye never leaves the action.
// One thing moves at a time: a line lands on a still frame and the camera never moves under it. Every line and sound sits on a mark the harness recorded (track.json, compacted
// from the take's frames.json by scripts/track.py). 120 BPM: a beat is 30 frames, a bar 120.
import type { Clock } from '../../legacy/lib/clock';
import type { Take } from '../../legacy/lib/Footage';
import type { PointerTrack } from '../../legacy/lib/pointer';
import type { Cue, CueSheet, Line } from '../../legacy/lib/sheet';
import trackJson from './track.json';

export const BPM = 120;
export const TRACK = trackJson as unknown as PointerTrack;
export const TAKE: Take = { video: 'power-tour/01-tour.mp4', frames: TRACK.frames, width: TRACK.pointSize[0] * 2, height: TRACK.pointSize[1] * 2 };

/** A quick push toward the hand on a payoff: in at `at`, back out after `dur` frames. */
export interface Punch { at: number; dur: number; amount: number }

export const timeline = (c: Clock): CueSheet & { punches: Punch[] } => {
  const m = (k: string, fallback: number) => TRACK.marks[k] ?? fallback;
  const lockup = TRACK.frames;
  const total = lockup + c.bar * 2;
  const say = (id: string, from: number, to: number, text: string, extra: Partial<Line> = {}): Line => ({ id, from, to, text, place: 'cursor', ...extra });
  // Tile-pinned: the line lands on the tile it is about, after the camera has settled (its rect is read at `from`).
  const tag = (id: string, from: number, to: number, text: string, pin: Line['pin'], extra: Partial<Line> = {}): Line => ({ id, from, to, text, place: 'tile', pin, ...extra });
  const lines: Line[] = [
    tag('hook', m('hook', 60), m('grabLine', 180) - 8, 'Let’s ship one fix.', { rect: 'board' }),
    say('grab', m('grabLine', 180), m('drop', 270) + 30, 'Drop it on an agent.'),
    tag('status', m('status', 380), m('status', 380) + 115, 'Status, at a glance.', { rect: 'sidebar:fix', side: 'right', align: 'center' }),
    tag('reads', m('reads', 630), m('reads', 630) + 128, 'It reads the code first.', { rect: 'fix' }),
    tag('aware', m('aware', 800), m('aware', 800) + 125, 'It sees what’s around it.', { rect: 'fix' }),
    tag('code', m('code', 1045), m('code', 1045) + 125, '…and opens code beside it.', { rect: 'editor' }),
    tag('tests', m('tests', 1320), m('tests', 1320) + 120, 'Tests run next door.', { rect: 'term' }),
    tag('done', m('doneLine', 1625), m('doneLine', 1625) + 120, '[Done.] All tests pass.', { rect: 'fix' }, { tone: 'green' }),
    say('next', m('nextLine', 1765), m('toDone', 1775) + 70, 'Done. Next!'),
    tag('list', m('listLine', 2085), m('listLine', 2085) + 120, 'Every agent, one list.', { rect: 'sidebar', side: 'right', align: 'start', dy: 110 }),
    tag('ask', m('askLine', 2460), m('askLine', 2460) + 118, 'It needs my answer.', { rect: 'push' }),
    { id: 'promise', from: lockup + Math.round(c.beat * 1.5), to: total, text: 'Keep every agent in view.', place: 'lockup', size: 'hook' },
    { id: 'where', from: lockup + c.bar, to: total, text: 'arrayapp.dev · Free during alpha · macOS 14+', place: 'lockup' },
  ];
  const sfx = (id: string, f: number, kind: Cue['sfx']): Cue => ({ id, at: f, sfx: kind });
  const ev = (type: string) => TRACK.events.filter((e) => e.type === type).map((e) => e.frame);
  const cues: Cue[] = [
    ...lines.filter((l) => l.place === 'cursor' || l.place === 'tile').map((l) => sfx(`pop:${l.id}`, l.from, 'pop')),
    // A click logs press, then release + click 5 frames later: one sound, on the press.
    ...ev('press').map((f, k) => sfx(`press${k}`, f, 'click')),
    ...ev('drop').map((f, k) => sfx(`drop${k}`, f, 'thud')),
    ...ev('panStart').map((f, k) => sfx(`pan${k}`, f + 12, 'swish')),
    ...ev('zoomStart').map((f, k) => sfx(`zoom${k}`, f + 20, 'swish')),
    ...(TRACK.marks.testsPass ? [sfx('testsPass', TRACK.marks.testsPass, 'tick')] : []),
    ...ev('revealStart').map((f, k) => sfx(`reveal${k}`, f + 20, 'swish')),
    // An agent finishing its turn sounds exactly as it does in the app: bloom.wav.
    ...(TRACK.marks.pushDone ? [sfx('pushDone', TRACK.marks.pushDone, 'bloom')] : []),
    ...(TRACK.marks.done ? [sfx('done', TRACK.marks.done, 'bloom')] : []),
    sfx('lockup', lockup, 'whoosh'),
    sfx('mark', lockup + Math.round(c.beat / 2), 'bell'),
  ];
  const punches: Punch[] = [
    ...(TRACK.marks.drop ? [{ at: TRACK.marks.drop, dur: 50, amount: 0.06 }] : []),
    ...(TRACK.marks.done ? [{ at: TRACK.marks.done, dur: 60, amount: 0.05 }] : []),
  ];
  return {
    slug: 'power-tour', title: 'A power user’s tour', clock: c, durationInFrames: total, music: 'app',
    acts: { tour: { name: '1 · tour', from: 0, dur: lockup }, lockup: { name: '2 · lockup', from: lockup, dur: total - lockup } },
    cues, tracks: [], lens: [], lines, chapters: [], overlays: [], punches,
  };
};
