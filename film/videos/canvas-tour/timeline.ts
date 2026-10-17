// Canvas tour: every frame number comes from the clock, so the picture, captions and score
// share one grid. Reads like a score: bar 1 attention, bar 2 working, bar 3 tidy, bar 4 done.
import type { Clock } from '../../legacy/lib/clock';
import type { CueSheet } from '../../legacy/lib/sheet';
import { tidyTrack, TIDY_SECONDS } from '../../legacy/lib/tracks/tidy';

export const BPM = 120;

export const timeline = (c: Clock): CueSheet => {
  const { b } = c;
  const tidyLen = Math.round(c.fps * TIDY_SECONDS); // the website's Tidy transition, in frames
  const CUE = {
    findVerify: b(1, 2),
    ping: b(1, 2, 2),
    approveStart: b(2, 2),
    approved: b(2, 3),
    pullBack: b(3),
    tidyFrom: b(3, 1),
    tidyTo: b(3, 1) + tidyLen,
    findStabilize: b(4),
    done: b(4, 2),
    keys: b(4, 3, 2),
    command: b(5),
    end: b(6, 2),
  };
  return {
    slug: 'canvas-tour',
    title: 'Canvas tour',
    clock: c,
    durationInFrames: CUE.end,
    acts: {
      attention: { name: '1 · Needs you', from: 0, dur: b(3) },
      tidy: { name: '2 · Tidy', from: b(3), dur: b(4) - b(3) },
      done: { name: '3 · Done', from: b(4), dur: CUE.end - b(4) },
    },
    cues: [
      { id: 'ping', at: CUE.ping, sfx: 'ping', pan: 0.3 }, // verify starts in needsAttention, so no transition: authored
      { id: 'approveStart', at: CUE.approveStart, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'start' }, sfx: 'click' },
      { id: 'approved', at: CUE.approved, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'complete' } },
      { id: 'toastOff1', at: CUE.pullBack, action: { type: 'SET_TOAST', message: null } },
      { id: 'tidyWhoosh', at: CUE.tidyFrom, sfx: 'whoosh' },
      { id: 'tidy', at: CUE.tidyTo, action: { type: 'TIDY' }, sfx: 'thud' },
      { id: 'toastOff2', at: CUE.findStabilize + 20, action: { type: 'SET_TOAST', message: null } },
      { id: 'done', at: CUE.done, action: { type: 'ADVANCE_AGENT', id: 'stabilize', status: 'done', operation: 0, entry: { id: 's5', kind: 'assistant', text: 'Placement is stable across zone changes.' } } },
      { id: 'keys', at: CUE.keys, sfx: 'key' },
      { id: 'command', at: CUE.command, action: { type: 'OPEN_COMMAND', open: true }, sfx: 'click' },
    ],
    tracks: [tidyTrack('tidy', CUE.tidyFrom, CUE.tidyTo)],
    lens: [
      { at: 0, focus: { whole: true }, pad: 40 },
      { at: CUE.findVerify, focus: { tile: 'verify' }, pad: 90 },
      { at: CUE.pullBack, focus: { whole: true }, pad: 40 },
      { at: CUE.findStabilize, focus: { tile: 'stabilize' }, pad: 90 },
      { at: CUE.keys, focus: { whole: true }, pad: 40 },
    ],
    lines: [
      { id: 'l1', from: CUE.findVerify, to: b(2, 3), text: 'An agent needs you. You see it.' },
      { id: 'l2', from: CUE.pullBack, to: b(4), text: 'Tidy keeps the canvas readable.' },
      { id: 'l3', from: CUE.findStabilize, to: b(4, 3), text: 'Done is green.' },
      { id: 'l4', from: CUE.command, to: CUE.end - 10, text: 'Everything else is one keystroke away.' },
    ],
    chapters: [
      { id: 'attention', at: 0, title: 'Needs you' },
      { id: 'tidy', at: b(3), title: 'Tidy' },
      { id: 'done', at: b(4), title: 'Done' },
    ],
    overlays: [
      { kind: 'callout', from: CUE.ping, to: CUE.approved, text: 'Needs you', anchor: { tile: 'verify' } },
      { kind: 'key', from: CUE.keys, to: CUE.command + 30, keys: ['⌘', 'K'] },
    ],
  };
};
