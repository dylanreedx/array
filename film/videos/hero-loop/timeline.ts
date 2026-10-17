// Hero loop "In view": 6 bars at 120 BPM = 12.0 s = 720 frames at 60 fps (360 at 30). Silent.
// Reads like a score: bar 1 working, 2 needs you, 3 approve + ⌘K, 4 Terminal, 5 done, 6 again.
//
// The loop is seam-tight by construction: scene.json is the state one round of this timeline
// leaves behind. Nothing is appended to a transcript (status, approval and composer carry every
// beat), the shell already holds the previous run, the approval is already accepted, the zone is
// back to its three-tile width and the lens returns to its first framing. scripts/check-loop.ts asserts it, on state (frame N against frame 0) and on pixels
// (first rendered frame against the last).
//
// Every move is a LENS move: the Mac camera holds still at 60% (scene.json), which leaves the lens
// room inside the canvas to drift right and to pull back to the grown zone. Lens keys are rects in
// canvas world coordinates, so the two camera re-centres (when the zone grows and when it shrinks
// back) happen under a lens that does not move.
import type { AgentStatus, DemoAction, DemoState, Frame, ShellLine } from '@website/features/demo/types';
import type { Clock } from '../../legacy/lib/clock';
import type { Cue, CueSheet, FocusTarget } from '../../legacy/lib/sheet';
import { centreOn, glide } from '../../legacy/lib/tracks/camera';
import { MAC_CANVAS } from '../../legacy/lib/formats';
import { TIDY_SECONDS, tidyTrack } from '../../legacy/lib/tracks/tidy';
import { typeTrack } from '../../legacy/lib/tracks/type';
import sceneJson from './scene.json';

export const BPM = 120;

const scene = sceneJson as unknown as { state: Pick<DemoState, 'agents' | 'approval' | 'shell' | 'macCamera' | 'tiles' | 'zones'> };
const LEFT = 'stabilize', MIDDLE = 'audit', RIGHT = 'verify';
const AGENTS = [LEFT, MIDDLE, RIGHT];
const OP = 1; // every operation this round runs as generation 1, scene.json's operationGeneration

/** The next round's prompt, typed into all three composers in bar 5 and sent in bar 6. */
const prompt = 'Rebase on main and run the checks again.';
// The website Shell's own `swift test` output (ShellTile's script), as the previous run left it.
const [run, ...output] = scene.state.shell.lines;
const streamed: ShellLine[] = output.slice(0, -1), passed: ShellLine[] = output.slice(-1);

/** A status change with no transcript entry: the pill, the gyro tail and Stop/Send carry it. */
const advance = (id: string, status: AgentStatus): DemoAction => ({ type: 'ADVANCE_AGENT', id, status, operation: OP });
/** Each agent's running tool row: the last transcript entry, `inProgress` in scene.json. */
const runningRow = (id: string) => scene.state.agents[id].transcript.at(-1)!.id;
const row = (id: string, status: 'inProgress' | 'completed'): DemoAction => ({ type: 'SET_ENTRY_STATUS', id, entryId: runningRow(id), status });

// ---- geometry (world px) -------------------------------------------------------------------------
const tile = (id: string) => scene.state.tiles[id].frame;
const zone = scene.state.zones.runtime.frame;             // three tiles wide
const slot = tile('shell');                                // the fourth slot Tidy gives the Terminal
const grown: Frame = { ...zone, width: slot.x + slot.width + 24 - zone.x };  // tidyLayout's 24 px horizontal padding
const zoom = scene.state.macCamera.zoom;
const midY = zone.y + zone.height / 2;
const centreX = (f: Frame) => f.x + f.width / 2;
/** A world rect `w` wide at the output's aspect, centred on (cx, cy). */
const view = (cx: number, cy: number, w: number, aspect: number): Frame => ({ x: cx - w / 2, y: cy - w / aspect / 2, width: w, height: w / aspect });
/** A lens focus that frames `wide` in a landscape output and `square` otherwise, at the output's aspect. */
const framing = (wide: { cx: number; w: number }, square: { cx: number; w: number }) => ({ width, height }: { width: number; height: number }): FocusTarget =>
  ({ world: width > height ? view(wide.cx, midY, wide.w, width / height) : view(square.cx, midY, square.w, width / height) });
/** Width of a framing in which `span` world px fill `share` of the frame. */
const share = (left: Frame, right: Frame, s: number) => ({ cx: (left.x + right.x + right.width) / 2, w: (right.x + right.width - left.x) / s });
// The canvas's right edge in world px while the camera centres the three-tile zone: a drift may not pass it.
const canvasRight = centreX(zone) + MAC_CANVAS.width / 2 / zoom;
const SLACK = 16;

// Bar 1: the three agents span 92% of a 16:9 frame; a square frames the middle and right ones.
const homeWide = share(tile(LEFT), tile(RIGHT), 0.92), homeSquare = share(tile(MIDDLE), tile(RIGHT), 0.92);
const HOME = framing(homeWide, homeSquare);
// Bar 2: toward the needs-attention tile, at the same scale, as far as the canvas allows.
const NEEDS_YOU = framing(
  { cx: Math.min(centreX(tile(RIGHT)), canvasRight - homeWide.w / 2 - SLACK), w: homeWide.w },
  { cx: Math.min(centreX(tile(RIGHT)), canvasRight - homeSquare.w / 2 - SLACK), w: homeSquare.w },
);
// Bar 5: the whole grown zone in 16:9; the three agents in 1:1 (a square that holds the whole zone is taller than the canvas).
const PULL_BACK = framing({ cx: centreX(grown), w: grown.width / 0.94 }, share(tile(LEFT), tile(RIGHT), 0.95));

export const timeline = (c: Clock): CueSheet => {
  const { b, sec } = c;
  const CUE = {
    start: b(1),               // bar 1 beat 1: three agents working, framed on the zone
    needsYou: b(2),            // bar 2 beat 1: right agent needs attention, lens drifts right
    cursorIn: b(2, 2),         // the pointer heads for Allow once
    approve: b(3),             // bar 3 beat 1: Allow once, amber -> blue
    commandK: b(3, 2),         // bar 3 beat 3: ⌘K, Command Center opens
    typeFrom: b(3, 2, 1),      //   "shell" typed into the search, Create › Terminal highlighted
    typeTo: b(3, 3),
    returnKey: b(3, 3, 2),     //   Return
    shellLands: b(4),          // bar 4 beat 1: the Terminal lands beside the right agent
    shellTypeFrom: b(4, 0, 1), //   `swift test` typed at the prompt
    tidyFrom: b(4, 0, 2),      //   Tidy grows the zone and snaps the Terminal in: 110 ms, ease-out, positions only
    tidyTo: b(4, 0, 2) + Math.max(1, Math.round(c.fps * TIDY_SECONDS)),
    swiftTest: b(4, 1, 2),     //   Return: `swift test` runs and streams
    stream: [b(4, 2), b(4, 2, 1), b(4, 2, 2), b(4, 2, 3)],
    testsPass: b(4, 3),
    pullBack: b(5),            // bar 5 beat 1: lens pulls back to the zone; left agent done
    doneLeft: b(5),
    doneMiddle: b(5, 1),       // bar 5 beat 2
    doneRight: b(5, 2),        // bar 5 beat 3
    promptFrom: b(5, 3),       // bar 5 beat 4: the next prompt is typed into all three composers
    send: b(6),                // bar 6 beat 1: sent, green -> blue, lens eases home
    closeShell: b(6, 2),       // bar 6 beat 3: the Terminal closes once the lens has settled; the zone shrinks back
    end: b(7),                 // = frame 0 of the next loop
  };
  const ACT = {
    working: { name: '1 · Working', from: CUE.start, dur: CUE.needsYou - CUE.start },
    needsYou: { name: '2 · Needs you', from: CUE.needsYou, dur: CUE.approve - CUE.needsYou },
    approve: { name: '3 · Approve, ⌘K', from: CUE.approve, dur: CUE.shellLands - CUE.approve },
    shell: { name: '4 · Terminal', from: CUE.shellLands, dur: CUE.pullBack - CUE.shellLands },
    done: { name: '5 · Done', from: CUE.pullBack, dur: CUE.send - CUE.pullBack },
    again: { name: '6 · Again', from: CUE.send, dur: CUE.end - CUE.send },
  };
  const verify = tile(RIGHT);
  const landing = { ...slot, x: verify.x + verify.width + 40, y: verify.y + 40 };
  const approve = { x: 0.28, y: 0.68 }; // "Allow once" in the inline approval card, as a fraction of the right tile
  const terminalRow = { x: -35, y: 102 }; // Create › Terminal, in the panel's own px from its top centre (measured at bar 3 beat 4)

  const cues: Cue[] = [
    { id: 'needsYou', at: CUE.needsYou, action: advance(RIGHT, 'needsAttention') },
    { id: 'approvalCard', at: CUE.needsYou, action: { type: 'REQUEST_APPROVAL', approval: { ...scene.state.approval, state: 'pending' } } },
    // A click on the tile selects it, as MacWorkspace's pointerdown does.
    { id: 'approveSelect', at: CUE.approve, action: { type: 'SELECT_ENTITY', id: RIGHT } },
    { id: 'approveStart', at: CUE.approve, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'start' } },
    { id: 'approved', at: CUE.approve, action: { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'complete' } },
    // `git push` is the row the approval held: In progress (waiting) until Allow once, then Completed.
    { id: 'pushed', at: CUE.approve, action: row(RIGHT, 'completed') },
    { id: 'toastOff', at: CUE.approve, action: { type: 'SET_TOAST', message: null } }, // the reducer's copy says "Approved on Companion"
    { id: 'commandK', at: CUE.commandK, action: { type: 'OPEN_COMMAND', open: true } },
    { id: 'commandClose', at: CUE.shellLands, action: { type: 'OPEN_COMMAND', open: false } },
    { id: 'shellLands', at: CUE.shellLands, action: { type: 'OPEN_SHELL', frame: landing, zoneId: 'runtime' } },
    // Tidy grows the zone to hold the Terminal (sizes land at once), and the camera re-centres on
    // it so the whole zone stays inside the canvas. The lens is anchored in world space, so the
    // re-centre does not show.
    { id: 'zoneGrows', at: CUE.tidyFrom, action: { type: 'UPDATE_ZONE', id: 'runtime', patch: { frame: grown } } },
    { id: 'recentre', at: CUE.tidyFrom, action: { type: 'SET_CAMERA', device: 'mac', camera: centreOn(grown, zoom) } },
    { id: 'swiftTest', at: CUE.swiftTest, action: { type: 'SHELL_EXECUTE', command: run.text, operation: OP } },
    ...streamed.map((line, i): Cue => ({ id: `stream${i + 1}`, at: CUE.stream[i], action: { type: 'SHELL_OUTPUT', lines: [line], operation: OP } })),
    { id: 'testsPass', at: CUE.testsPass, action: { type: 'SHELL_COMPLETE', lines: passed, operation: OP } },
    { id: 'doneLeft', at: CUE.doneLeft, action: advance(LEFT, 'done') },
    { id: 'doneLeftRow', at: CUE.doneLeft, action: row(LEFT, 'completed') },
    { id: 'doneMiddle', at: CUE.doneMiddle, action: advance(MIDDLE, 'done') },
    { id: 'doneMiddleRow', at: CUE.doneMiddle, action: row(MIDDLE, 'completed') },
    { id: 'doneRight', at: CUE.doneRight, action: advance(RIGHT, 'done') },
    // Send: the composer clears and the agent is back at work, on the beat. The transcript does not
    // grow (SEND_AGENT_MESSAGE would append the user turn), so f0 and f360 hold the same DOM.
    ...AGENTS.map((id): Cue => ({ id: `send-${id}`, at: CUE.send, action: { type: 'SET_AGENT_DRAFT', id, draft: '' } })),
    ...AGENTS.map((id): Cue => ({ id: `working-${id}`, at: CUE.send, action: advance(id, 'working') })),
    // The next round starts each agent's running row again, as scene.json holds it.
    ...AGENTS.map((id): Cue => ({ id: `running-${id}`, at: CUE.send, action: row(id, 'inProgress') })),
    // The Terminal closes, the zone returns to its three-tile size at once, and the camera to the scene's.
    { id: 'closeShell', at: CUE.closeShell, action: { type: 'CLOSE_TILE', id: 'shell' } },
    { id: 'zoneShrinks', at: CUE.closeShell, action: { type: 'UPDATE_ZONE', id: 'runtime', patch: { frame: zone } } },
    { id: 'cameraHome', at: CUE.closeShell, action: { type: 'SET_CAMERA', device: 'mac', camera: scene.state.macCamera } },
  ];
  if (streamed.length !== CUE.stream.length) throw new Error('hero-loop: scene shell output does not match the stream cues');

  return {
    slug: 'hero-loop',
    title: 'Hero loop',
    clock: c,
    durationInFrames: CUE.end,
    loop: { from: CUE.start, to: CUE.end },
    acts: ACT,
    cues,
    tracks: [
      typeTrack('query', CUE.typeFrom, CUE.typeTo, 'shell', (query) => ({ type: 'SET_COMMAND_QUERY', query })),
      typeTrack('shellDraft', CUE.shellTypeFrom, CUE.swiftTest - 1, run.text, (value) => ({ type: 'SHELL_DRAFT', value })),
      tidyTrack('tidy', CUE.tidyFrom, CUE.tidyTo),
      ...AGENTS.map((id) => typeTrack(`prompt-${id}`, CUE.promptFrom, CUE.send - 1, prompt, (draft) => ({ type: 'SET_AGENT_DRAFT', id, draft }))),
    ],
    // Lens moves: the app cuts between framings; a film glides, on an exponential approach with
    // tau 100 ms (lib/tracks/camera.ts), landing exactly on the key at the end of `dur`.
    lens: [
      { at: CUE.start, focus: HOME, pad: 0 },
      { at: CUE.needsYou, focus: NEEDS_YOU, pad: 0, dur: sec(0.6), ease: glide(0.6) },
      { at: CUE.pullBack, focus: PULL_BACK, pad: 0, dur: sec(0.52), ease: glide(0.52) },
      { at: CUE.send, focus: HOME, pad: 0, dur: sec(0.52), ease: glide(0.52) },
    ],
    lines: [],
    chapters: [],
    overlays: [
      { kind: 'cursor', path: [
        { at: CUE.cursorIn, x: 1.12, y: 1.06, anchor: { tile: RIGHT } },
        { at: b(2, 3, 2), ...approve, anchor: { tile: RIGHT } },
        { at: CUE.approve, ...approve, press: true, anchor: { tile: RIGHT } },
        { at: b(3, 1), x: approve.x + 0.06, y: approve.y + 0.05, anchor: { tile: RIGHT } },
        { at: CUE.typeTo, ...terminalRow, anchor: 'frame' },
        { at: CUE.shellLands, ...terminalRow, anchor: 'frame' },
      ] },
      // Bottom right, clear of the Command Center in both formats; ↵ leaves as the Terminal lands.
      { kind: 'key', from: CUE.commandK, to: CUE.returnKey, keys: ['⌘', 'K'], place: { x: 0.89, y: 0.955 } },
      { kind: 'key', from: CUE.returnKey, to: CUE.shellLands, keys: ['↵'], place: { x: 0.89, y: 0.955 } },
    ],
  };
};
