// "Which tab was that?" (research/21-which-tab/brief.md, with the footage agent's story change: no bell in
// the hunt; you can't tell which tab is done, and the finish happens LIVE on the canvas instead).
// One timeline for picture, sound and SRT.
//
//   S1 hook     0.0 - 1.2   the tab bar fills 3 -> 6, a soft tick per tab; the hook line is up from frame 0
//   S2 hunt     0.8 - 5.0   REACTIVE (round 4): a status dot changes, you jump to that tab (motion-blurred
//                           swap), and while you read it another changes, so you jump again, one step behind:
//                           Renewal emails needs input, Order export fails, Dark mode finishes, the first two
//                           nudge again, and you land back on Cart total
//   S3 beat     5.0 - 6.1   the jumping stops; the line swaps
//   S4 unstack  6.1 - 8.8   the tab pills lift off the bar and unfurl into their windows, fanned in tab order;
//                           the windows fly to their own tiles while the take pulls back (2x); the ink lifts as
//                           they land (see Plan.seam)
//   S5 payoff   8.8 - 11.1  wide canvas, picture only: Cart total finishes on camera (take frame 262,
//                           film ~9.4 s), the finish mark, a small "Cart total · done" tag
//   S6 end     11.1 - 16.5  two beats: "Keep every agent in view." alone; then the Array lockup alone, arrayapp.dev
import type { Clock } from '../../kit/clock';
import { lockupBeats as kitLockupBeats } from '../../kit/lockup';
import type { Act, Cue, CueSheet, Line } from '../../kit/sheet';
import { COPY, LANDING, LOOK, TABS, tabIndex, type Status, type TabKey } from './constants';
import { PULLBACK } from './footage';

/** The end card's beats (kit/lockup.tsx) for the payoff line. */
export const lockupBeats = (from: number, fps: number) => kitLockupBeats(LOOK.lockup!, COPY.payoff.split(' ').length, LOOK.words.stagger, LOOK.words.dur, from, fps);

export const BPM = 100;

export interface Flight { key: TabKey; start: number; land: number; order: number }

/** A tab's status changes at a frame. */
export interface StatusEvent { key: TabKey; at: number; state: Status }

export interface Plan {
  acts: Record<'s1' | 's2' | 's3' | 's4' | 's5' | 's6', Act>;
  /** frame each tab joins the bar (negative: open on frame 0) */
  tabAt: number[];
  /** status changes (every tab starts 'working'), and the "still waiting" halos on unanswered tabs */
  status: StatusEvent[];
  nudges: { key: TabKey; at: number }[];
  /** tab jumps (⌘N): at frame, from and to tab index, direction of the blur */
  switches: { at: number; from: number; to: number; dir: 1 | -1 }[];
  /** S3: the hook line leaves, the beat line enters */
  beatAt: number;
  /**
   * S4, UNSTACK. Tabs are windows stacked behind each other, and Array unstacks them.
   *   pills   (round 4) each tab pill lifts off the bar (`lift`), then unfurls into its own window, the pill
   *           becoming that window's title bar, fanned out in tab order (`unfurl`, staggered outward from
   *           the front tab); the front window steps back with them. One motion, one easing family.
   *   flights each window flies to its OWN tile. Cart total (front) lands first, on the take's tight
   *           framing, at `pull`; the rest leave on a 75 ms stagger and land while the camera pulls back,
   *           tracking their tiles. Each resolves into its real tile mid-flight, under motion blur.
   *   lift    the ink outside the cards lifts as they land
   */
  seam: { headlineOut: number; fan: number; fanDur: number; pillLift: number; pillLiftDur: number; unfurl: number; unfurlDur: number; unfurlStagger: number;
    pull: number; flights: Flight[]; lift: { from: number; to: number };
    /**
     * Round 5, the hand-off on Cart total: its terminal turns into its tile row by row (geometry.ts CART_ROWS),
     * each row sliding and reforming into its counterpart, top to bottom, `stagger` apart, `dur` each, then the
     * whole real tile settles over it (`faceAt`). Its header, colour, composer and model bar morph with it.
     */
    morph: { start: number; stagger: number; dur: number; header: number; headerDur: number } };
  /** take frame shown at film frame f: 1x, except 2x through the pull-back (an even cadence, 1.5 s) */
  takeAt: (f: number) => number;
  /** S5: Cart total finishes on camera */
  payoff: { mark: number; tag: number };
  lockup: number;
  total: number;
}

/** A tab's status at frame f, when it last changed, and every halo it has sent so far. */
export const statusOf = (P: Plan, key: TabKey, f: number) => {
  let state: Status = 'working', since = -999;
  const halos: number[] = [];
  for (const e of P.status) if (e.key === key && e.at <= f) { state = e.state; since = e.at; halos.push(e.at); }
  for (const n of P.nudges) if (n.key === key && n.at <= f) halos.push(n.at);
  return { state, since, halos };
};

/** The take's pull-back runs PULL_RATE take frames per film frame (an integer, so the cadence stays even). */
const PULL_RATE = 2;
const WIDE = 228;

export const plan = (fps: number): Plan => {
  const s = (x: number) => Math.round(x * fps);
  const pull = s(7.3);
  const pullLen = (WIDE - PULLBACK.pullStart) / PULL_RATE;
  const takeAt = (f: number) => {
    if (f < pull) return Math.max(0, PULLBACK.pullStart - (pull - f));
    if (f < pull + pullLen) return PULLBACK.pullStart + PULL_RATE * (f - pull);
    return Math.min(PULLBACK.take.frames - 1, WIDE + (f - pull - pullLen));
  };
  // Cart total first; then outward from it: its neighbours, theirs, the last.
  const land = tabIndex(LANDING);
  const others = TABS.map((t, i) => ({ key: t.key, d: Math.abs(i - land) + (i > land ? 0.1 : 0) })).filter((t) => t.key !== LANDING).sort((a, b) => a.d - b.d);
  const flights: Flight[] = [
    { key: LANDING, start: s(6.8), land: pull, order: 0 },
    ...others.map((t, k) => ({ key: t.key, start: s(7.0) + Math.round(k * fps * 0.075), land: s(8.3) + Math.round(k * fps * 0.075), order: k + 1 })),
  ];
  const lastLand = Math.max(...flights.map((x) => x.land));
  const wide = pull + pullLen;
  const finish = wide + (PULLBACK.finishAt - WIDE);
  const lockup = finish + s(1.75);
  const acts = {
    s1: { from: 0, dur: s(1.2), name: 'S1 hook' },
    s2: { from: s(1.2), dur: s(3.8), name: 'S2 hunt' },
    s3: { from: s(5.0), dur: s(1.1), name: 'S3 beat' },
    s4: { from: s(6.1), dur: wide - s(6.1), name: 'S4 unstack' },
    s5: { from: wide, dur: lockup - wide, name: 'S5 payoff' },
    s6: { from: lockup, dur: s(5.4), name: 'S6 end card' }, // line beat, ink, lockup beat, URL, a 2 s+ still hold
  };
  // Three tabs are open on frame 0 (the thumbnail already reads as tabs); three more join, 0.22 s apart.
  const tabAt = TABS.map((_, i) => (i < 3 ? -999 : s(0.14 + (i - 3) * 0.22)));
  // The reactive hunt: each jump answers the dot that just changed, and the next one changes while you read.
  const ix = tabIndex;
  const status: StatusEvent[] = [
    { key: 'emails', at: s(0.8), state: 'input' },
    { key: 'export', at: s(1.55), state: 'failed' },
    { key: 'dark', at: s(2.15), state: 'done' },
  ];
  const nudges = [{ key: 'emails' as TabKey, at: s(2.7) }, { key: 'export' as TabKey, at: s(3.3) }];
  const jumps: [number, TabKey][] = [[1.2, 'emails'], [1.75, 'export'], [2.35, 'dark'], [2.9, 'emails'], [3.5, 'export'], [4.1, LANDING]];
  let from = 0;
  const switches = jumps.map(([t, key]) => {
    const to = ix(key), w = { at: s(t), from, to, dir: (to > from ? 1 : -1) as 1 | -1 };
    from = to;
    return w;
  });
  return {
    acts, tabAt, status, nudges, switches, beatAt: acts.s3.from, takeAt,
    seam: { headlineOut: s(6.75), fan: s(6.1), fanDur: s(0.62), pillLift: s(6.1), pillLiftDur: s(0.26), unfurl: s(6.4), unfurlDur: s(0.6), unfurlStagger: s(0.035),
      pull, flights, lift: { from: flights[1].land - s(0.35), to: lastLand + s(0.15) },
      morph: { start: s(7.3), stagger: s(0.07), dur: 9, header: s(7.1), headerDur: s(0.5) } },
    payoff: { mark: finish, tag: finish + s(0.45) },
    lockup,
    total: lockup + acts.s6.dur,
  };
};

export const timeline = (clock: Clock): CueSheet => {
  const p = plan(clock.fps);
  const pan = (i: number) => -0.5 + i / (TABS.length - 1); // tabs sit left to right in the mix
  const cues: Cue[] = [
    ...p.tabAt.flatMap((at, i) => (at < 0 ? [] : [{ id: `tab:${TABS[i].key}`, at, sfx: 'tab' as const, pan: pan(i) }])),
    ...p.switches.map((w, k) => ({ id: `switch:${k}`, at: w.at, sfx: 'tab' as const, pan: pan(w.to) })),
    ...p.status.map((e) => ({ id: `status:${e.key}`, at: e.at, sfx: `dot.${e.state}`, pan: pan(tabIndex(e.key)) })),
    ...p.nudges.map((n) => ({ id: `nudge:${n.key}`, at: n.at, sfx: 'dot.nudge' as const, pan: pan(tabIndex(n.key)) })),
    { id: 'drone.on', at: p.acts.s2.from - clock.sec(0.4), sfx: 'drone.on' },
    { id: 'drone.off', at: p.beatAt, sfx: 'drone.off' },
    { id: 'breath', at: p.beatAt - clock.sec(0.1), sfx: 'breath' },
    { id: 'lift', at: p.seam.pull - clock.sec(0.7), sfx: 'lift' }, // crests as the cards land and the ink lifts
    ...p.seam.flights.map((x) => ({ id: `fly:${x.key}`, at: Math.round((x.start + x.land) / 2), sfx: 'swish' as const, pan: (tabIndex(x.key) - 2.5) / 3 })),
    { id: 'finish', at: p.payoff.mark, sfx: 'chime' },
    { id: 'lockup', at: lockupBeats(p.lockup, clock.fps).lockAt, sfx: 'bell' }, // on the lockup's own beat, not the line's
  ];
  const lines: Line[] = [
    { id: 'hook', from: 0, to: p.beatAt, text: COPY.hook, size: 'hook' },
    { id: 'beat', from: p.beatAt, to: p.seam.headlineOut + clock.sec(0.3), text: COPY.beat, words: true },
    { id: 'payoff', from: p.lockup, to: p.total, text: COPY.payoff, words: true, place: 'lockup' },
    { id: 'url', from: p.lockup, to: p.total, text: `Array · ${COPY.url}`, place: 'lockup' },
  ];
  return {
    slug: 'which-tab', title: 'Which tab was that?', clock, durationInFrames: p.total,
    acts: p.acts, cues, lines, chapters: [], music: 'tabs',
  };
};
