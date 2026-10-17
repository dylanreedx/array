// "Hand it to an agent": video 2 of the social series, cut from REAL app footage. The app filmed itself
// (`--film`, bench .worktrees/film-harness, scene film/scenes/board-story.json): seven takes at 60 fps.
// This file only trims the takes onto the bar grid and writes the narration and sound on the marks the
// harness recorded in each take's frames.json. 120 BPM: a beat is 30 frames, a bar 120.
import type { Clock } from '../../legacy/lib/clock';
import type { Take } from '../../legacy/lib/Footage';
import type { Cue, CueSheet, Line } from '../../legacy/lib/sheet';

export const BPM = 120;

/** Capture size of every take: a 1440 x 778 pt window at 2x. */
const W = 2880, H = 1556;
const take = (video: string, frames: number): Take => ({ video: `board-story/${video}.mp4`, frames, width: W, height: H });
export const TAKES = {
  wide: take('01-wide-glide', 300),   // marks: glideStart 90
  assign: take('02-assign', 380),     // dragStart 24, send 120, toDoing 128
  edit: take('03-edit', 420),         // edit 170
  tests: take('04-tests', 430),       // testsRun 120
  site: take('05-browser', 240),
  approval: take('06-approval', 500), // needsYou 210, approved 370
  done: take('07-done', 440),         // agentDone 214, toDone 226, pullBackWide 300
};

export interface Shot { id: keyof typeof TAKES; from: number; trim: number; len: number }

export const shots = (c: Clock): Shot[] => {
  const list: Omit<Shot, 'from'>[] = [
    { id: 'wide', trim: 0, len: c.bar * 2.5 },
    { id: 'assign', trim: 0, len: c.bar * 2.5 },
    { id: 'edit', trim: 120, len: c.bar * 2 },
    { id: 'tests', trim: 90, len: c.bar * 2 },
    { id: 'site', trim: 30, len: c.bar * 1.25 },
    { id: 'approval', trim: 150, len: c.bar * 2.5 },
    { id: 'done', trim: 140, len: c.bar * 2.5 },
  ];
  let at = 0;
  return list.map((s) => { const shot = { ...s, from: at, len: Math.round(s.len) }; at += shot.len; return shot; });
};

export const timeline = (c: Clock): CueSheet => {
  const S = Object.fromEntries(shots(c).map((s) => [s.id, s])) as Record<Shot['id'], Shot>;
  /** Composition frame of take frame `f` in shot `id`. */
  const at = (id: Shot['id'], f: number) => S[id].from + f - S[id].trim;
  const end = (id: Shot['id']) => S[id].from + S[id].len;
  const lockup = end('done');
  const total = lockup + c.bar * 2;
  const line = (id: string, from: number, to: number, text: string, extra: Partial<Line> = {}): Line => ({ id, from, to, text, ...extra });
  const lines: Line[] = [
    line('hook', 12, at('wide', 150), 'All your agents. One canvas.', { size: 'hook', words: true }),
    line('zones', at('wide', 156), end('wide'), 'Every project gets a zone.'),
    line('assign', S.assign.from + 6, at('assign', 180), 'Drag a task onto an agent.'),
    line('starts', at('assign', 186), end('assign'), 'It works in its own tile.'),
    line('edit', S.edit.from + 6, end('edit'), 'Its files and code sit right beside it.'),
    line('tests', S.tests.from + 6, end('tests'), 'Tests run in a real terminal.'),
    line('site', S.site.from + 6, end('site'), 'Your app, live, next to the work.'),
    line('amber', S.approval.from + 6, at('approval', 360), 'Amber means it needs you.'),
    line('allow', at('approval', 370), end('approval'), 'You spot it from any zone.'),
    line('green', S.done.from + 6, at('done', 296), 'Green is done.'),
    line('all', at('done', 302), lockup, 'Every agent, in view.'),
    line('promise', lockup + Math.round(c.beat * 1.5), total, 'Keep every agent in view.', { place: 'lockup', size: 'hook' }),
    line('where', lockup + c.bar, total, 'arrayapp.dev · Free during alpha · macOS 14+', { place: 'lockup' }),
  ];
  const sfx = (id: string, f: number, kind: Cue['sfx']): Cue => ({ id, at: f, sfx: kind });
  const cues: Cue[] = [
    sfx('glide', at('wide', 90), 'whoosh'),
    sfx('drag', at('assign', 24), 'click'),
    sfx('drop', at('assign', 100), 'thud'),
    sfx('send', at('assign', 120), 'key'),
    sfx('editLands', at('edit', 170), 'tick'),
    sfx('testsRun', at('tests', 120), 'key'),
    sfx('testsPass', at('tests', 300), 'tick'),
    sfx('needsYou', at('approval', 210), 'ping'),
    sfx('approved', at('approval', 372), 'resolve'),
    sfx('agentDone', at('done', 214), 'chime'),
    sfx('toDone', at('done', 226), 'click'),
    sfx('pullBack', at('done', 300), 'whoosh'),
    sfx('lockup', lockup, 'whoosh'),
    sfx('mark', lockup + Math.round(c.beat / 2), 'bell'),
  ];
  const acts = Object.fromEntries(shots(c).map((s, i) => [s.id, { name: `${i + 1} · ${s.id}`, from: s.from, dur: s.len }]));
  acts.lockup = { name: '8 · lockup', from: lockup, dur: total - lockup };
  return { slug: 'board-story', title: 'Hand it to an agent', clock: c, durationInFrames: total, acts, cues, tracks: [], lens: [], lines, chapters: [], overlays: [] };
};
