// "What Array is": video 1 of the social series. 12 bars at 120 BPM = 24.0 s = 1440 frames at 60 fps.
// Director's brief: ./brief.md. One line: an agent needs you, and on Array's canvas you can see which
// one, because every agent, and everything it touches, is a tile in view.
//
// Scripted scene: the website's own demo components, replayed from scene.json through the website's
// reducer. The Mac camera holds still the whole film (scene.json centres the world as it is after the
// fourth agent lands); every move is a LENS move, on a closed-form spring (lib/anim.ts springEase).
// Captions sit in the format's reserved band and the lens never frames a subject into it.
import type { AgentStatus, DemoAction, DemoState, Frame } from '@website/features/demo/types';
import { E, SPRING, springEase, type Spring } from '../../legacy/lib/anim';
import type { Clock } from '../../legacy/lib/clock';
import type { Cue, CueSheet, FocusTarget, LensKey, Line } from '../../legacy/lib/sheet';
import { TIDY_SECONDS, TIDY_EASE } from '../../legacy/lib/tracks/tidy';
import { keyFrames, typeTrack } from '../../legacy/lib/tracks/type';
import sceneJson from './scene.json';

export const BPM = 120;

const scene = sceneJson as unknown as { state: Pick<DemoState, 'agents' | 'approval' | 'shell' | 'macCamera' | 'tiles' | 'zones'> };
const OP = 1; // scene.json's operationGeneration: every agent and shell step runs as generation 1
const LEFT = 'stabilize', MIDDLE = 'audit', RIGHT = 'verify';
const NEW = 'agent-4'; // SPAWN_AGENT names the fourth agent `agent-${count + 1}`

// ---- geometry (world px) ------------------------------------------------------------------------
const tile = (id: string) => scene.state.tiles[id].frame;
const zone = (id: string) => scene.state.zones[id].frame;
const right = (f: Frame) => f.x + f.width;
const bottom = (f: Frame) => f.y + f.height;
const union = (...fs: Frame[]): Frame => {
  const x = Math.min(...fs.map((f) => f.x)), y = Math.min(...fs.map((f) => f.y));
  return { x, y, width: Math.max(...fs.map(right)) - x, height: Math.max(...fs.map(bottom)) - y };
};

/**
 * The "Needs attention" pill in Release notes' title bar, in TILE-LOCAL px. Measured from the
 * rendered DOM (index.tsx PillProbe warns, and the gate fails, if the website ever moves it).
 */
export const PILL = { x: 197, y: 4, width: 87, height: 16 };
const pillWorld = (): Frame => ({ x: tile(RIGHT).x + PILL.x, y: tile(RIGHT).y + PILL.y, width: PILL.width, height: PILL.height });

/** The fourth agent's slot: a fourth column, at the agents' size. */
export const SLOT: Frame = { x: right(tile(RIGHT)) + 16, y: tile(RIGHT).y, width: 330, height: 420 };
const grownRuntime: Frame = { ...zone('runtime'), width: right(SLOT) + 24 - zone('runtime').x };
const shiftedCompanion: Frame = { ...zone('companion'), x: right(grownRuntime) + 24 };
const companionShift = shiftedCompanion.x - zone('companion').x;

// ---- framings ------------------------------------------------------------------------------------
/** A world rect at the box's aspect, `w` wide, centred on (cx, cy). */
const view = (cx: number, cy: number, w: number, aspect: number): Frame => ({ x: cx - w / 2, y: cy - w / aspect / 2, width: w, height: w / aspect });
/** Frame `r` so it fills `share` of the box on its tighter axis (never cropped). */
const around = (r: Frame, share: number) => ({ width, height }: { width: number; height: number }): FocusTarget => {
  const aspect = width / height;
  const w = Math.max(r.width / share, (r.height / share) * aspect);
  return { world: view(r.x + r.width / 2, r.y + r.height / 2, w, aspect) };
};
/** The pill alone at `share` of the frame width (the hook drifts from 52% to 60%). */
const HOOK = (share: number) => ({ width, height }: { width: number; height: number }): FocusTarget => {
  const p = pillWorld(), aspect = width / height;
  return { world: view(p.x + p.width / 2, p.y + p.height / 2, p.width / share, aspect) };
};
type Box = { width: number; height: number };
/** One framing for landscape and square boxes, another for portrait: a phone frames two columns, never a whole zone. */
const pick = (wide: (b: Box) => FocusTarget, tall: (b: Box) => FocusTarget) => (b: Box) => (b.width < b.height ? tall(b) : wide(b));
/** Columns `from`..`to` (tile ids) between world y `top` and `bot`, with Tidy's 24 px padding either side. */
const columns = (from: string, to: string, top: number, bot: number): Frame => ({ x: tile(from).x - 24, y: top, width: right(tile(to)) + 24 - (tile(from).x - 24), height: bot - top });
const runtimeTop = zone('runtime').y, agentsBottom = bottom(tile(LEFT)) + 24, zoneBottom = bottom(zone('runtime'));

// The zone's header and its agent row: the pill's tile and its neighbours, under "Canvas fixes".
const AGENTS_ROW = pick(around({ ...zone('runtime'), height: agentsBottom - runtimeTop }, 0.94), around(columns(MIDDLE, RIGHT, runtimeTop, agentsBottom), 0.96));
const TILE = (id: string, share = 0.9) => around(tile(id), share);
const ZONE = pick(around(union(zone('runtime'), zone('companion')), 0.95), around(columns(MIDDLE, RIGHT, runtimeTop, zoneBottom), 0.96));
const GROWN = pick(around(union(grownRuntime, shiftedCompanion), 0.96), around({ ...columns(RIGHT, RIGHT, runtimeTop, zoneBottom), width: right(SLOT) + 24 - (tile(RIGHT).x - 24) }, 0.96));
// Bar 10: the zone's header and its four agents, so three pills turning green read at once. A phone
// follows the wave instead, one agent per beat.
const AGENT_ROW_GROWN = around({ ...grownRuntime, height: agentsBottom - grownRuntime.y }, 0.96);
const WAVE = (id: string) => pick(AGENT_ROW_GROWN, around(columns(id, id, runtimeTop, agentsBottom), 0.96));

// ---- copy ----------------------------------------------------------------------------------------
// One line per beat of the story, never two on screen at once, never over UI (brief: Beat sheet).
const COPY = {
  hook: 'An agent needs you.',
  which: 'Which one? You can see.',
  tile: 'Every agent runs in a tile.',
  touches: 'What it touches sits next to it.',
  zones: 'Zones hold a project.',
  launch: '⌘K launches anything.',
  amber: 'Amber needs you.',
  green: 'Green is done.',
  promise: 'Keep every agent in view.',
  where: 'arrayapp.dev · Free during alpha · macOS 14+',
};

const advance = (id: string, status: AgentStatus): DemoAction => ({ type: 'ADVANCE_AGENT', id, status, operation: OP });
/** Each agent's running tool row is its last transcript entry (`inProgress` in scene.json). */
const runningRow = (id: string) => scene.state.agents[id].transcript.at(-1)!.id;
const rowDone = (id: string): DemoAction => ({ type: 'SET_ENTRY_STATUS', id, entryId: runningRow(id), status: 'completed' });

// The ShellTile's own `swift test` run, as the hero loop scene holds it.
const SWIFT_TEST = [
  { id: 'w-1', type: 'output', text: 'Building for debugging...' },
  { id: 'w-2', type: 'output', text: '[418/418] Linking ArrayPackageTests' },
  { id: 'w-3', type: 'output', text: 'Build complete! (6.84s)' },
  { id: 'w-4', type: 'output', text: '◇ Test run started.' },
] as const;
const SWIFT_PASS = { id: 'w-5', type: 'success', text: '✔ Test run with 18 tests in 4 suites passed after 2.412 seconds.' } as const;

export const timeline = (c: Clock): CueSheet => {
  const { b, sec, fps } = c;
  const key = (at: number, focus: LensKey['focus'], s: Spring, dur: number): LensKey => ({ at, focus, pad: 0, dur: sec(dur), ease: springEase(s, dur) });
  const CUE = {
    hook: b(1),
    ping: b(1, 0, 2),
    reveal: b(2),            // heavy spring pull-back: the pill is one of three agents
    pushIn: b(3),            // to Release notes: approval card, `git push` In progress
    browser: b(4),           // what it touches: Browser reloads localhost
    reload: b(4, 0, 2), reloaded: b(4, 1, 2),
    diff: b(4, 2),           // Diff Review switches source
    diffSource: b(4, 2, 2),
    shell: b(5),             // Terminal: `swift test` typed and run
    shellTypeFrom: b(5, 0, 1), swiftTest: b(5, 1),
    stream: [b(5, 1, 2), b(5, 2), b(5, 2, 2), b(5, 3)],
    testsPass: b(5, 3, 2),
    zones: b(6),             // pull back: the zone header and the release zone beside it
    commandK: b(7),          // ⌘K, Command Center opens
    typeFrom: b(7, 1), typeTo: b(7, 2),
    agentRow: b(7, 2, 2),    // Return on Create › Agent: the Choose Model step
    model: b(8, 1),          // Return on Quick Start › Default: the fourth agent lands, the release zone moves over
    regrow: b(8, 2),
    amber: b(9),             // push in on the amber tile
    cursorIn: b(9, 0, 2),
    allow: b(9, 2),          // Allow once: amber to blue
    green: b(10),            // pull back to the whole window; tiles turn green left to right
    lockup: b(11),
    where: b(12),
    end: b(13),
  };
  const ACT = {
    hook: { name: '1 · Hook', from: CUE.hook, dur: CUE.reveal - CUE.hook },
    reveal: { name: '2 · Which one', from: CUE.reveal, dur: CUE.pushIn - CUE.reveal },
    tile: { name: '3 · A tile', from: CUE.pushIn, dur: CUE.browser - CUE.pushIn },
    touches: { name: '4-5 · Next to it', from: CUE.browser, dur: CUE.zones - CUE.browser },
    zones: { name: '6 · Zones', from: CUE.zones, dur: CUE.commandK - CUE.zones },
    launch: { name: '7-8 · ⌘K', from: CUE.commandK, dur: CUE.amber - CUE.commandK },
    amber: { name: '9 · Amber', from: CUE.amber, dur: CUE.green - CUE.amber },
    green: { name: '10 · Green', from: CUE.green, dur: CUE.lockup - CUE.green },
    lockup: { name: '11-12 · Lockup', from: CUE.lockup, dur: CUE.end - CUE.lockup },
  };

  const lines: Line[] = [
    { id: 'hook', from: CUE.ping, to: CUE.reveal, text: COPY.hook, size: 'hook', words: true },
    { id: 'which', from: CUE.reveal + 6, to: CUE.pushIn, text: COPY.which },
    { id: 'tile', from: CUE.pushIn + 6, to: CUE.browser, text: COPY.tile },
    { id: 'touches', from: CUE.browser + 6, to: CUE.zones, text: COPY.touches },
    { id: 'zones', from: CUE.zones + 6, to: CUE.commandK, text: COPY.zones },
    { id: 'launch', from: CUE.commandK + 6, to: CUE.amber, text: COPY.launch },
    { id: 'amber', from: CUE.amber + 6, to: CUE.green, text: COPY.amber },
    { id: 'green', from: CUE.green + 6, to: CUE.lockup, text: COPY.green },
    { id: 'promise', from: b(11, 1, 2), to: CUE.end, text: COPY.promise, place: 'lockup', size: 'hook' },
    { id: 'where', from: CUE.where, to: CUE.end, text: COPY.where, place: 'lockup' },
  ];

  const approve = { x: 0.28, y: 0.68 }; // "Allow once" in the inline approval card, as a fraction of the 330 x 420 tile
  const agentModel = { model: 'GPT-5.6 Sol', provider: 'Codex' }; // Quick Start › Default — GPT-5.6 Sol (commandModel.ts)

  const cues: Cue[] = [
    { id: 'ping', at: CUE.ping, sfx: 'ping' }, // Release notes starts the film already waiting: no transition to derive the ping from
    { id: 'whooshReveal', at: CUE.reveal, sfx: 'whoosh' },
    // Bars 4-5: the tools beside the agents, one per beat landing.
    { id: 'reload', at: CUE.reload, action: { type: 'BROWSER_RELOAD', loading: true }, sfx: 'click' },
    { id: 'reloaded', at: CUE.reloaded, action: { type: 'BROWSER_RELOAD', loading: false } },
    { id: 'diffSource', at: CUE.diffSource, action: { type: 'DIFF_SOURCE', source: 'Branch agent/tiles-jump-by-their-zone-origin-4b1e9c07 vs main' }, sfx: 'click' },
    { id: 'swiftTest', at: CUE.swiftTest, action: { type: 'SHELL_EXECUTE', command: 'swift test', operation: OP }, sfx: 'key' },
    ...SWIFT_TEST.map((line, i): Cue => ({ id: `stream${i + 1}`, at: CUE.stream[i], action: { type: 'SHELL_OUTPUT', lines: [line], operation: OP } })),
    { id: 'testsPass', at: CUE.testsPass, action: { type: 'SHELL_COMPLETE', lines: [SWIFT_PASS], operation: OP }, sfx: 'tick' },
    // Bars 7-8: ⌘K › "agent" › Agent › Choose Model › Default. The same actions CommandCenter.run dispatches.
    { id: 'commandK', at: CUE.commandK, action: { type: 'OPEN_COMMAND', open: true }, sfx: 'key' },
    { id: 'agentStep', at: CUE.agentRow, action: { type: 'SET_COMMAND_STEP', step: 'model' }, sfx: 'key' },
    { id: 'agentStepQuery', at: CUE.agentRow, action: { type: 'SET_COMMAND_QUERY', query: '' } },
    { id: 'spawn', at: CUE.model, action: { type: 'SPAWN_AGENT', effort: 'Medium', ...agentModel }, sfx: 'thud' },
    { id: 'spawnRecent', at: CUE.model, action: { type: 'RECORD_COMMAND_RECENT', id: 'action:new-agent' } },
    // It lands in the fourth column; the zone grows to hold it (sizes land at once, Tidy-style) and
    // the release zone moves over on the native 110 ms reflow (the track below).
    { id: 'land', at: CUE.model, action: { type: 'MOVE_TILE', id: NEW, frame: SLOT, zoneId: 'runtime' } },
    { id: 'grow', at: CUE.model, action: { type: 'UPDATE_ZONE', id: 'runtime', patch: { frame: grownRuntime } } },
    { id: 'spawnToast', at: CUE.model, action: { type: 'SET_TOAST', message: null } }, // the website's "New agent added" toast; the app shows none
    { id: 'deselect', at: CUE.model, action: { type: 'SELECT_ENTITY', id: null } },
    // Bar 9: Allow once. A click on the tile selects it, as MacWorkspace's pointerdown does.
    { id: 'allowStart', at: CUE.allow, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'start' }, sfx: 'click' },
    { id: 'resolve', at: CUE.allow + 2, sfx: 'resolve' },
    { id: 'allowed', at: CUE.allow + 2, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'complete' } },
    { id: 'allowToast', at: CUE.allow + 2, action: { type: 'SET_TOAST', message: null } }, // the reducer's copy says "Approved on Companion"
    // Bar 10: done, left to right, on beats 1, 2, 3. The chimes are derived from these (export-cues).
    ...[LEFT, MIDDLE, RIGHT].flatMap((id, i): Cue[] => [
      { id: `done-${id}`, at: b(10, i), action: advance(id, 'done') },
      { id: `doneRow-${id}`, at: b(10, i), action: rowDone(id) },
    ]),
    { id: 'lockup', at: CUE.lockup, sfx: 'whoosh' },
    { id: 'mark', at: b(11, 0, 1), sfx: 'bell' },
  ];

  const tracks = [
    typeTrack('query', CUE.typeFrom, CUE.typeTo, 'agent', (query) => ({ type: 'SET_COMMAND_QUERY', query })),
    typeTrack('shellDraft', CUE.shellTypeFrom, CUE.swiftTest - 1, 'swift test', (value) => ({ type: 'SHELL_DRAFT', value })),
    {
      id: 'companionShift', from: CUE.model, to: CUE.model + Math.max(1, Math.round(fps * TIDY_SECONDS)), ease: TIDY_EASE,
      action: (t: number, s: DemoState): DemoAction => ({
        type: 'MOVE_ZONE', id: 'companion',
        frame: { ...zone('companion'), x: zone('companion').x + companionShift * t },
        tileFrames: { note: { ...tile('note'), x: tile('note').x + companionShift * t } },
      }),
    },
  ];
  const keys = [...keyFrames(CUE.typeFrom, CUE.typeTo, 'agent'), ...keyFrames(CUE.shellTypeFrom, CUE.swiftTest - 1, 'swift test')];
  cues.push(...keys.map((at, i): Cue => ({ id: `key${i}`, at, sfx: 'key' })));

  return {
    slug: 'what-is-array',
    title: 'What Array is',
    clock: c,
    durationInFrames: CUE.end,
    acts: ACT,
    cues,
    tracks,
    lens: [
      { at: CUE.hook, focus: HOOK(0.52), pad: 0 },
      // A slow push for the whole hook bar: the cold open is never a still frame.
      { at: CUE.hook + 1, focus: HOOK(0.6), pad: 0, dur: b(2) - CUE.hook - 2, ease: E.smooth },
      key(CUE.reveal, AGENTS_ROW, SPRING.heavy, 1.5),
      key(CUE.pushIn, TILE(RIGHT, 0.92), SPRING.soft, 0.9),
      key(CUE.browser, TILE('browser', 0.86), SPRING.soft, 0.8),
      key(CUE.diff, TILE('diff', 0.86), SPRING.soft, 0.8),
      key(CUE.shell, TILE('shell', 0.86), SPRING.soft, 0.8),
      key(CUE.zones, ZONE, SPRING.heavy, 1.5),
      key(CUE.regrow, GROWN, SPRING.soft, 1.0),
      key(CUE.amber, TILE(RIGHT, 0.92), SPRING.soft, 0.9),
      key(CUE.green, WAVE(LEFT), SPRING.soft, 0.9),
      // Landscape holds the row (these keys frame what it already frames); portrait steps along it.
      key(b(10, 1), WAVE(MIDDLE), SPRING.snappy, 0.5),
      key(b(10, 2), WAVE(RIGHT), SPRING.snappy, 0.5),
    ],
    lines,
    chapters: [],
    overlays: [
      { kind: 'cursor', path: [
        { at: CUE.cursorIn, x: 1.1, y: 1.05, anchor: { tile: RIGHT } },
        { at: CUE.allow - 6, ...approve, anchor: { tile: RIGHT } },
        { at: CUE.allow, ...approve, press: true, anchor: { tile: RIGHT } },
        { at: b(9, 3), x: approve.x + 0.05, y: approve.y + 0.05, anchor: { tile: RIGHT } },
      ] },
      { kind: 'key', from: CUE.commandK, to: CUE.typeFrom, keys: ['⌘', 'K'], place: 'band' },
      { kind: 'key', from: CUE.agentRow, to: CUE.agentRow + c.beat, keys: ['↵'], place: 'band' },
      { kind: 'key', from: CUE.model, to: CUE.model + c.beat, keys: ['↵'], place: 'band' },
    ],
  };
};

/**
 * The silent website cut (brief: Formats): bars 2 to 10 of the master, no captions, no hook, then a
 * 1.5 s hold on the last frame. The page around it carries the words.
 */
export const siteCut = (c: Clock) => ({ from: c.b(2), to: c.b(11), hold: c.sec(1.5) });

/**
 * The website cut's lens: no hook (it opens on the agent row), and it ends on both zones, since an
 * uncaptioned 16:9 frame has no band to fill and the page's own copy names the green.
 */
export const siteLens = (c: Clock, lens: LensKey[]): LensKey[] => [
  { ...lens[2], at: 0, dur: undefined, ease: undefined },
  ...lens.slice(3).filter((k) => k.at < c.b(10)),
  { at: c.b(10), focus: GROWN, pad: 0, dur: c.sec(1.2), ease: springEase(SPRING.heavy, 1.2) },
];

/**
 * The subject dim: bars 3 to 5 and 9 dim everything but the tile the caption is about, and the cutout
 * glides between subjects with the lens (track(), one spring per change). Off for the pull-backs, so
 * the whole zone lights up on "Zones hold a project."
 */
export const subjects = (c: Clock) => ({
  rect: [
    { at: c.b(4), to: tile('browser') }, { at: c.b(4, 2), to: tile('diff') }, { at: c.b(5), to: tile('shell') }, { at: c.b(9), to: tile(RIGHT) },
  ],
  first: tile(RIGHT),
  amount: [{ at: c.b(3), to: 0.5 }, { at: c.b(6), to: 0 }, { at: c.b(9), to: 0.5 }, { at: c.b(10), to: 0 }],
});

/** The pill in world px, for the hook's spotlight. */
export { pillWorld };
