import { guidedLayout } from './guided-layout';
import type { GuidedInsert } from './guided-timeline';
import { TOOLBAR, toolbarReleasePoint, toolbarScale, toolbarSnapshot, TOOLBAR_TOUR, type ToolbarSnapshot } from './guided-toolbar';
import { DICTATION_BEAT, IDLE_DICTATION, dictationSnapshot, type DictationSnapshot } from './guided-dictation';

export const WORLD_WIDTH = 2060;
export const WORLD_HEIGHT = 1320;
export type DemoStep = 'landing' | 'toolbar' | 'creation' | 'task' | 'providers' | 'dictation' | 'approval' | 'verification' | 'layout' | 'overview';
export type DemoAgent = 'stabilize' | 'verify' | 'audit';
export type DemoTile = DemoAgent | 'browser' | 'shell' | 'note';
type Point = { x: number; y: number };
export const STEPS = [
  { id: 'landing', start: 0, end: .27, focus: { x: 900, y: 575 }, caption: 'Your project and its supporting tiles land together.' },
  { id: 'creation', start: .27, end: .38, focus: { x: 285, y: 365 }, caption: 'Press ⌘K to add or jump. Choose a model and create an agent.' },
  { id: 'task', start: .38, end: .445, focus: { x: 285, y: 365 }, caption: 'Focus the new agent, then give it a task.' },
  { id: 'providers', start: .445, end: .595, focus: { x: 740, y: 325 }, caption: 'Let Claude and Codex work in parallel.' },
  { id: 'approval', start: .595, end: .73, focus: { x: 740, y: 350 }, caption: 'Review the next action before it runs.' },
  { id: 'verification', start: .73, end: .86, focus: { x: 470, y: 895 }, caption: 'Move from the board to the code, and follow the checks.' },
  { id: 'layout', start: .86, end: .985, focus: { x: 1250, y: 905 }, caption: 'Rearrange the canvas. Give each tile the space its work needs.' },
  { id: 'overview', start: .985, end: 1, focus: { x: 900, y: 575 }, caption: 'Keep the whole project in view, and pick up anywhere.' },
] as const;
/** Captions for the beats inserted into the authored scroll (see guided-timeline). */
export const INSERT_CAPTIONS = {
  toolbar: 'Add anything from the toolbar. Drag it to any edge of the canvas.',
  dictation: 'Talk instead of typing. Your words land in the prompt as you speak.',
  terminal: 'Open a terminal from the toolbar, right beside the work.',
} as const;
/** The audit agent's prompt is dictated, not typed (see guided-dictation). */
export const DICTATED_AT = .565;
/** When the toolbar's terminal arrives, in authored progress. */
export const SHELL_AT = .815;
export const DEMO_TEXT = {
  stabilize: 'Fix zone placement. Keep tiles aligned while zooming.',
  verify: 'Check the zone placement fix and run the canvas tests.',
  audit: 'Review the native spacing, colors, and canvas controls.',
} as const;
export type CreationStage = 'absent' | 'command' | 'models' | 'spawning' | 'focused' | 'sent';
export type CursorTarget = 'toolbar-zone' | 'toolbar-agent' | 'toolbar-terminal' | 'toolbar-menu-shell' | 'command-trigger' | 'command-agent' | 'creation-model' | 'stabilize-composer' | 'stabilize-send' | 'verify-provider' | 'verify-composer' | 'verify-send' | 'audit-composer' | 'audit-mic' | 'audit-send' | 'verify-allow' | 'board-placement' | 'editor-line' | 'shell-input' | 'stabilize-header' | 'editor-header' | 'editor-resize' | 'stabilize-resize' | 'shell-resize' | null;
export interface TileFrameSnapshot {
  x: number; y: number; width: number; height: number; visible: boolean; selected: boolean; zIndex: number;
  drag: { active: boolean; lift: number; rotation: number; scaleX: number; scaleY: number };
}
export interface TileMotion { x: number; y: number; scale: number; rotation: number; opacity: number; emphasis: number }
export interface GuidedSnapshot {
  progress: number;
  step: DemoStep;
  caption: string;
  heroOpacity: number;
  chromeOpacity: number;
  takeover: number;
  camera: Point & { scale: number; center: Point };
  tiles: Record<DemoTile, TileMotion>;
  tileFrames: Record<DemoTile, TileFrameSnapshot>;
  mainCreated: boolean;
  creation: { stage: CreationStage; query: string; provider: string; model: string };
  selectedTile: DemoTile | null;
  focusedTile: DemoTile | null;
  cursorTarget: CursorTarget;
  menuTarget: 'creation-agent' | 'creation-model' | 'verify-provider' | null;
  snapPreview: { tile: DemoTile; x: number; y: number; width: number; height: number; opacity: number; scale: number } | null;
  resizeReadout: { tile: DemoTile; width: number; height: number } | null;
  boardProgress: number;
  boardDetail: boolean;
  editorProgress: number;
  /** `screen` pins the hand in canvas pixels; `fromScreen` starts an approach from there. */
  cursor: Point & { visible: boolean; pressed: boolean; approach: number; fromTarget: CursorTarget; screen: Point | null; fromScreen: Point | null };
  toolbar: ToolbarSnapshot;
  /** The keystroke readout (⌘K, or ↩ finishing dictation), 0 hidden … 1 shown. */
  keyHud: number;
  keyHudKeys: readonly string[];
  /** The audit agent's composer dictation; idle outside its beat. */
  dictation: DictationSnapshot & { agent: DemoAgent };
  terminal: { lines: number; typed: string; phase: 'idle' | 'typing' | 'running' | 'done' };
  typing: Record<DemoAgent, string>;
  status: Record<DemoAgent, string>;
  menu: 'provider' | 'toolbar' | 'models' | null;
  approval: 'hidden' | 'waiting' | 'approved';
  tool: string;
  reducedMotion: boolean;
}
const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));
const between = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
const smooth = (p: number) => p * p * (3 - 2 * p);
const mix = (a: number, b: number, p: number) => a + (b - a) * p;
const type = (text: string, p: number, a: number, b: number) => text.slice(0, Math.floor(text.length * between(p, a, b)));
type TerminalLine = { at: number; kind: 'prompt' | 'out' | 'dim' | 'ok' | 'suite' | 'pass'; text: string; time?: string };
const passLine = (at: number, name: string, time: string): TerminalLine => ({ at, kind: 'pass', text: name, time });
/** The build terminal, opened fresh from the toolbar: a believable `swift test`, revealed line by line with scroll. */
export const TERMINAL_LINES: readonly TerminalLine[] = [
  { at: .8355, kind: 'out', text: 'Building for debugging...' },
  { at: .8365, kind: 'dim', text: '[14/14] Linking ContinuumRevivedTests' },
  { at: .8375, kind: 'ok', text: 'Build complete!', time: '3.84s' },
  { at: .8385, kind: 'suite', text: 'CanvasSceneEditTests' },
  passLine(.8393, 'worldFrameRoundTrip', '0.004s'),
  passLine(.8400, 'zoneLocalPreservesWorld', '0.003s'),
  passLine(.8406, 'dragKeepsGapContact', '0.012s'),
  passLine(.8413, 'latchedSwapIsExact', '0.007s'),
  passLine(.8419, 'neighboursYieldOnPush', '0.009s'),
  passLine(.8426, 'resizeKeepsEightPointGap', '0.006s'),
  passLine(.8433, 'settleAlignsRowTops', '0.005s'),
  passLine(.8439, 'previewTracksCandidate', '0.008s'),
  passLine(.8446, 'releaseLandsOnPreview', '0.004s'),
  passLine(.8452, 'zoomKeepsTilesAligned', '0.011s'),
  passLine(.8459, 'hydrationKeepsFrames', '0.010s'),
  passLine(.8466, 'persistCoversThenReplaces', '0.006s'),
  { at: .8472, kind: 'ok', text: '12 passed', time: '0.085s' },
  { at: .8480, kind: 'suite', text: 'ZoneLayerFrameTests' },
  passLine(.8487, 'worldToZoneLocalIsExact', '0.002s'),
  passLine(.8492, 'movedZoneKeepsMembers', '0.005s'),
  passLine(.8497, 'membershipNeverCrosses', '0.004s'),
  passLine(.8502, 'departedZoneSettles', '0.007s'),
  passLine(.8507, 'layerOwnsTilesOnly', '0.003s'),
  passLine(.8512, 'chromeFollowsZoneMove', '0.010s'),
  { at: .8517, kind: 'ok', text: '6 passed', time: '0.031s' },
  { at: .8525, kind: 'ok', text: 'Executed 18 tests, with 0 failures' },
];
const TERMINAL_COMMAND = { start: .82, typed: .835, done: .8525 } as const;
const cursorFrames: ReadonlyArray<readonly [number, number, number]> = [
  [.28, 260, 480], [.31, 260, 480], [.38, 410, 500], [.43, 700, 45],
  [.46, 700, 45], [.49, 830, 160], [.51, 690, 480], [.56, 850, 500],
  [.59, 690, 390], [.66, 785, 445], [.69, 785, 445], [.73, 210, 760],
  [.76, 210, 760], [.79, 1160, 790], [.81, 1210, 800], [.83, 1500, 460], [.93, 1500, 460],
];
function cursorAt(p: number): Point {
  const index = cursorFrames.findIndex(([time]) => time > p);
  if (index === 0) return { x: cursorFrames[0][1], y: cursorFrames[0][2] };
  if (index < 0) return { x: cursorFrames.at(-1)![1], y: cursorFrames.at(-1)![2] };
  const [a, ax, ay] = cursorFrames[index - 1], [b, bx, by] = cursorFrames[index];
  const t = smooth(between(p, a, b));
  return { x: mix(ax, bx, t), y: mix(ay, by, t) };
}
type CameraKind = 'overview' | 'agent' | 'parallel' | 'board' | 'editor' | 'terminal';
type CameraFrame = { p: number; x: number; y: number; kind: CameraKind; span?: number; vertical?: number; zoom?: number; mobileX?: number; mobileY?: number };
// The camera keeps moving within a beat, with gentle arcs across long moves.
// Readable action moments use smaller paths; they do not become static holds.
const CAMERA: readonly CameraFrame[] = [
  { p: 0, x: 900, y: 575, kind: 'overview' },
  { p: .335, x: 900, y: 575, kind: 'overview' },
  { p: .38, x: 285, y: 365, kind: 'agent' },
  { p: .425, x: 285, y: 365, kind: 'agent' },
  { p: .46, x: 690, y: 325, kind: 'parallel', mobileX: 740 },
  { p: .505, x: 740, y: 325, kind: 'agent' },
  { p: .55, x: 740, y: 325, kind: 'agent' },
  { p: .56, x: 1150, y: 315, kind: 'agent' },
  { p: .595, x: 1150, y: 315, kind: 'agent' },
  { p: .625, x: 735, y: 350, kind: 'agent' },
  { p: .69, x: 755, y: 345, kind: 'agent', mobileX: 746 },
  { p: .75, x: 470, y: 895, kind: 'board', mobileX: 210, mobileY: 860 },
  { p: .765, x: 485, y: 885, kind: 'board', mobileX: 218, mobileY: 855 },
  { p: .795, x: 1190, y: 895, kind: 'editor', mobileX: 1085 },
  { p: .812, x: 1220, y: 875, kind: 'editor', mobileX: 1090 },
  { p: .84, x: 1520, y: 325, kind: 'terminal' },
  { p: .855, x: 1520, y: 325, kind: 'terminal' },

];
function makeLayoutCamera(mobile: boolean): CameraFrame[] {
  const focus = (at: number, id: DemoTile, kind: CameraKind, span?: number): CameraFrame => {
    const frame = guidedLayout(at, mobile).frames[id];
    return { p: at, x: frame.x + frame.width / 2, y: frame.y + frame.height / 2, kind, span, vertical: 740 };
  };
  const pair = (at: number, ids: DemoTile[], span: number): CameraFrame => {
    const layout = guidedLayout(at, mobile), frames = ids.map(id => layout.frames[id]);
    if (layout.preview) frames.push(layout.preview);
    const left = Math.min(...frames.map(f => f.x)), right = Math.max(...frames.map(f => f.x + f.width));
    const top = Math.min(...frames.map(f => f.y)), bottom = Math.max(...frames.map(f => f.y + f.height));
    return { p: at, x: (left + right) / 2, y: (top + bottom) / 2, kind: 'parallel', span, vertical: 740 };
  };
  return [...CAMERA,
    pair(.873, ['stabilize', 'verify'], 1040), pair(.902, ['stabilize', 'verify'], 1040),
    pair(.909, ['browser', 'note'], 1500), pair(.923, ['browser', 'note'], 1500),
    focus(.93, 'browser', 'editor', mobile ? 550 : 900), focus(.95, 'browser', 'editor', mobile ? 550 : 900),
    focus(.957, 'stabilize', 'agent', mobile ? 620 : 680), focus(.970, 'stabilize', 'agent', mobile ? 620 : 680),
    focus(.976, 'shell', 'terminal', mobile ? 560 : 680), focus(.985, 'shell', 'terminal', mobile ? 560 : 680),
    { p: 1, x: WORLD_WIDTH / 2, y: WORLD_HEIGHT / 2, kind: 'overview' as const }];
}
const layoutCameras = [makeLayoutCamera(false), makeLayoutCamera(true)];
function cameraAt(p: number, width: number, height: number) {
  const mobile = width < 700;
  const fit = Math.min(width / WORLD_WIDTH, height / WORLD_HEIGHT) * .96;
  const camera = layoutCameras[mobile ? 1 : 0];
  const scaleFor = (frame: CameraFrame) => {
    if (frame.kind === 'overview') return fit;
    const span = frame.span ?? (mobile ? frame.kind === 'board' ? 330 : frame.kind === 'editor' ? 390 : frame.p <= .46 ? 470 : 410
      : frame.kind === 'parallel' ? 1300 : frame.kind === 'board' ? 850 : frame.kind === 'editor' ? 650 : 680);
    const vertical = frame.vertical ?? (mobile ? frame.p <= .46 ? 650 : 540 : ['agent', 'parallel'].includes(frame.kind) ? 660 : 540);
    return Math.min(width / span, height / vertical) * (frame.zoom ?? 1);
  };
  const end = camera.findIndex(frame => frame.p > p);
  const a = camera[Math.max(0, end < 0 ? camera.length - 1 : end - 1)];
  const b = end < 0 ? a : camera[end];
  const raw = between(p, a.p, Math.max(a.p + .00001, b.p));
  const t = smooth(raw);
  const ax = mobile ? a.mobileX ?? a.x : a.x, ay = mobile ? a.mobileY ?? a.y : a.y;
  const bx = mobile ? b.mobileX ?? b.x : b.x, by = mobile ? b.mobileY ?? b.y : b.y;
  const distance = Math.hypot(bx - ax, by - ay);
  const arc = distance > 80 ? Math.sin(Math.PI * raw) * (mobile ? 6 : 28) : 0;
  const center = { x: mix(ax, bx, t) - (distance ? (by - ay) / distance * arc : 0),
    y: mix(ay, by, t) + (distance ? (bx - ax) / distance * arc : 0) };
  let scale = mix(scaleFor(a), scaleFor(b), t);
  if (mobile) {
    const detail = smooth(between(p, .751, .755)) * (1 - smooth(between(p, .775, .779)));
    center.x = mix(center.x, 285, detail);
    center.y = mix(center.y, 860, detail);
    scale = mix(scale, Math.min(width / 460, height / 580), detail);
  }
  return { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center };
}
/**
 * The toolbar's terminal is revealed the way the app reveals a new tile: the
 * camera leaves the editor as the tile arrives, and is already on the terminal
 * when the authored story resumes.
 */
function guidedCamera(p: number, insert: GuidedInsert | null, width: number, height: number) {
  const terminal = .84;
  if (insert?.id === 'terminal') {
    const from = cameraAt(SHELL_AT, width, height), to = cameraAt(terminal, width, height), t = smooth(between(insert.t, .62, 1));
    const scale = mix(from.scale, to.scale, t), center = { x: mix(from.center.x, to.center.x, t), y: mix(from.center.y, to.center.y, t) };
    return { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center };
  }
  if (insert?.id === 'dictation') {
    // A gentle push in on the composer while it listens, back out as the agent starts.
    const base = cameraAt(p, width, height), beat = DICTATION_BEAT.camera, mobile = width < 700;
    const k = smooth(between(insert.t, beat.in[0], beat.in[1])) * (1 - smooth(between(insert.t, beat.out[0], beat.out[1])));
    const scale = base.scale * (1 + (mobile ? 0 : .12) * k), center = { x: base.center.x, y: base.center.y + 40 * k };
    // A phone's tile is as wide as the screen: slide it clear of the toolbar on the left edge.
    const tile = guidedLayout(p, mobile).frames.audit;
    const clear = TOOLBAR.margin + TOOLBAR.thickness * toolbarScale(width) + 8;
    center.x = mix(center.x, Math.min(center.x, tile.x + (width / 2 - clear) / scale), k);
    return { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center };
  }
  return cameraAt(p >= SHELL_AT && p < terminal ? terminal : p, width, height);
}
function focusAt(p: number): DemoTile | null {
  if (p >= .34 && p < .445) return 'stabilize';
  if (p >= .47 && p <= .55) return 'verify';
  if (p >= .56 && p <= .595) return 'audit';
  if (p >= .615 && p < .70) return 'verify';
  if (p >= .735 && p < .775) return 'note';
  if (p >= .78 && p < SHELL_AT) return 'browser';
  if (p >= SHELL_AT && p < .86) return 'shell';
  if (p >= .873 && p < .902) return 'stabilize';
  if (p >= .909 && p < .923 || p >= .93 && p < .95) return 'browser';
  if (p >= .957 && p < .970) return 'stabilize';
  if (p >= .976 && p < .985) return 'shell';
  return null;
}
function frameSnapshots(p: number, mobile: boolean, selected: DemoTile | null, shell: number): Record<DemoTile, TileFrameSnapshot> {
  const layout = guidedLayout(p, mobile);
  return Object.fromEntries(Object.entries(layout.frames).map(([id, frame]) => [id, {
    ...frame, visible: id === 'stabilize' ? p >= .34 : id === 'shell' ? shell > 0 : true, selected: id === selected,
    zIndex: id === selected ? 20 : 2,
    drag: { active: layout.moving === id, lift: 0, rotation: 0, scaleX: 1, scaleY: 1 },
  }])) as Record<DemoTile, TileFrameSnapshot>;
}
function tileMotions(frames: Record<DemoTile, TileFrameSnapshot>, shell: number): Record<DemoTile, TileMotion> {
  return Object.fromEntries(Object.entries(frames).map(([id, frame]) => {
    // The new terminal grows into its slot, like a spawned tile in the app.
    const arrival = id === 'shell' ? shell : 1;
    return [id, { x: 0, y: 0, scale: frame.visible ? mix(.9, 1, 1 - Math.pow(1 - arrival, 3)) : 1, rotation: 0,
      opacity: frame.visible ? smooth(Math.min(1, arrival * 2.2)) : 0, emphasis: frame.selected && !frame.drag.active ? 1 : 0 }];
  })) as Record<DemoTile, TileMotion>;
}
/** How far the toolbar's terminal has arrived: 0 absent … 1 settled. */
function shellArrival(p: number, insert: GuidedInsert | null) {
  if (insert?.id === 'terminal') return between(insert.t, .62, 1) || (insert.t >= .62 ? .001 : 0);
  return p >= SHELL_AT ? 1 : 0;
}
function targetAt(p: number): CursorTarget {
  if (p >= .27 && p < .295) return 'command-agent';
  if (p >= .295 && p < .335) return 'creation-model';
  if (p >= .385 && p < .425) return 'stabilize-composer';
  if (p >= .425 && p < .445) return 'stabilize-send';
  if (p >= .47 && p < .505) return 'verify-provider';
  if (p >= .515 && p < .55) return 'verify-composer';
  if (p >= .55 && p < .56) return 'verify-send';
  if (p >= .625 && p < .695) return 'verify-allow';
  if (p >= .735 && p < .775) return 'board-placement';
  if (p >= .775 && p < SHELL_AT) return 'editor-line';
  if (p >= SHELL_AT && p < .86) return 'shell-input';
  if (p >= .86 && p < .903) return 'stabilize-header';
  if (p >= .903 && p < .923) return 'editor-header';
  if (p >= .923 && p < .95) return 'editor-resize';
  if (p >= .95 && p < .970) return 'stabilize-resize';
  if (p >= .970 && p < .985) return 'shell-resize';
  return null;
}
type InsertCursor = { target: CursorTarget; from: CursorTarget; fromScreen: Point | null; approach: number; screen: Point | null; pressed: boolean };
/** The hand during an inserted beat. Targets are the real toolbar buttons and menu rows. */
function insertCursor(insert: GuidedInsert, width: number, height: number): InsertCursor {
  const t = insert.t;
  if (insert.id === 'toolbar') {
    const tour = TOOLBAR_TOUR, none = { fromScreen: null, screen: null };
    if (t >= tour.drag[1]) return { ...none, target: null, from: null, approach: 1, screen: toolbarReleasePoint(width, height), pressed: false };
    const pressed = t >= tour.press;
    if (t < tour.zone[1]) return { ...none, target: 'toolbar-zone', from: null, fromScreen: { x: width * .52, y: height * .5 }, approach: smooth(between(t, 0, tour.zone[0])), pressed };
    if (t < tour.agent[1]) return { ...none, target: 'toolbar-agent', from: 'toolbar-zone', approach: smooth(between(t, tour.zone[1], tour.agent[0])), pressed };
    return { ...none, target: 'toolbar-terminal', from: 'toolbar-agent', approach: smooth(between(t, tour.agent[1], tour.terminal[0])), pressed };
  }
  if (insert.id === 'dictation') {
    const beat = DICTATION_BEAT, none = { fromScreen: null, screen: null };
    const pressed = (t >= beat.press[0] && t < beat.press[1]) || (t >= beat.sendPress[0] && t < beat.sendPress[1]);
    if (t < beat.toSend[0]) return { ...none, target: 'audit-mic', from: null, approach: smooth(between(t, beat.approach[0], beat.approach[1])), pressed };
    return { ...none, target: 'audit-send', from: 'audit-mic', approach: smooth(between(t, beat.toSend[0], beat.toSend[1])), pressed };
  }
  const pressed = (t >= .26 && t < .29) || (t >= .58 && t < .61);
  if (t < .3) return { target: 'toolbar-terminal', from: 'editor-line', fromScreen: null, approach: smooth(between(t, 0, .2)), screen: null, pressed };
  return { target: 'toolbar-menu-shell', from: 'toolbar-terminal', fromScreen: null, approach: smooth(between(t, .3, .48)), screen: null, pressed };
}
/** A complete seekable state: reverse/direct jumps never accumulate animation. */
export function guidedSnapshot(value: number, options: { width: number; height: number; reducedMotion?: boolean; insert?: GuidedInsert | null }): GuidedSnapshot {
  const reducedMotion = options.reducedMotion ?? false;
  const p = reducedMotion ? 1 : clamp(value);
  const insert = reducedMotion ? null : options.insert ?? null;
  const width = Math.max(1, options.width), height = Math.max(1, options.height);
  const step = STEPS.find(s => p >= s.start && p < s.end) ?? STEPS.at(-1)!;
  const focusedTile = reducedMotion ? null : focusAt(p);
  const selectedTile = focusedTile ?? (p >= .34 && p < .38 ? 'stabilize' : null);
  const shell = shellArrival(p, insert);
  const tileFrames = frameSnapshots(p, width < 700, selectedTile, shell);
  const creationStage: CreationStage = p < .27 || insert?.id === 'toolbar' ? 'absent' : p < .295 ? 'command' : p < .335 ? 'models' : p < .38 ? 'spawning' : p < .435 ? 'focused' : 'sent';
  const layout = guidedLayout(p, width < 700);
  const resizing: DemoTile | null = p >= .93 && p < .95 ? 'browser' : p >= .957 && p < .970 ? 'stabilize' : p >= .976 && p < .985 ? 'shell' : null;
  const approaches: ReadonlyArray<readonly [number, number, CursorTarget]> = [[DICTATED_AT, .58, 'audit-send'], [SHELL_AT, .83, 'toolbar-menu-shell'], [.86, .873, 'shell-input'], [.903, .909, 'stabilize-header'], [.923, .93, 'editor-header'], [.95, .957, 'editor-resize'], [.970, .976, 'stabilize-resize']];
  const approach = approaches.find(([start, end]) => p >= start && p < end);
  // After the toolbar beat the hand travels from where it let go of the bar to the palette.
  const fromRelease = p >= .27 && p < .283 && !insert;
  const inserted = insert && !reducedMotion ? insertCursor(insert, width, height) : null;
  const pressTimes = [.285, .332, .435, .49, .555, .68, .755, .80, .835];
  const held = tileFrames.stabilize.drag.active || tileFrames.browser.drag.active || !!resizing;
  const dictation = insert?.id === 'dictation' ? dictationSnapshot(insert.t) : IDLE_DICTATION;
  // The audit prompt is dictated: it is in the composer once the beat has run, and sent with it.
  const auditSent = insert?.id === 'dictation' ? insert.t >= DICTATION_BEAT.sent : p >= DICTATED_AT;
  const auditText = insert?.id === 'dictation' ? dictation.settled + dictation.provisional : p >= DICTATED_AT ? DEMO_TEXT.audit : '';
  const typed = p >= TERMINAL_COMMAND.typed ? 'swift test' : type('swift test', p, TERMINAL_COMMAND.start, TERMINAL_COMMAND.typed);
  return {
    progress: p, step: insert?.id === 'toolbar' || insert?.id === 'dictation' ? insert.id : step.id, caption: insert ? INSERT_CAPTIONS[insert.id] : step.caption,
    heroOpacity: 1 - between(p, 0, .18), chromeOpacity: smooth(between(p, .10, .18)), takeover: smooth(between(p, .08, .26)),
    camera: guidedCamera(p, insert, width, height), tiles: tileMotions(tileFrames, shell), tileFrames,
    mainCreated: p >= .34, selectedTile, focusedTile,
    creation: { stage: creationStage, query: creationStage === 'command' ? type('Agent', p, .272, .285) : '', provider: 'Codex', model: 'GPT-5.6 Sol' },
    cursorTarget: reducedMotion ? null : inserted ? inserted.target : targetAt(p),
    menuTarget: creationStage === 'command' ? 'creation-agent' : creationStage === 'models' ? 'creation-model' : p >= .47 && p < .505 ? 'verify-provider' : null,
    snapPreview: reducedMotion ? null : layout.preview,
    resizeReadout: !reducedMotion && resizing ? { tile: resizing, width: Math.round(tileFrames[resizing].width), height: Math.round(tileFrames[resizing].height - 24) } : null,
    boardProgress: between(p, .735, .845), boardDetail: !reducedMotion && p >= .755 && p < .775, editorProgress: between(p, .775, .82),
    cursor: inserted
      ? { ...cursorAt(p), visible: true, approach: inserted.approach, fromTarget: inserted.from, screen: inserted.screen, fromScreen: inserted.fromScreen, pressed: inserted.pressed }
      : { ...cursorAt(p), visible: !reducedMotion && p >= .27 && p < .985,
        approach: fromRelease ? smooth(between(p, .27, .283)) : approach ? smooth(between(p, approach[0], approach[1])) : 1,
        fromTarget: fromRelease ? null : approach?.[2] ?? null, screen: null, fromScreen: fromRelease ? toolbarReleasePoint(width, height) : null,
        pressed: held || pressTimes.some(time => p >= time && p < time + .009) },
    toolbar: toolbarSnapshot(p, insert, width, height),
    keyHud: insert?.id === 'dictation' ? dictation.keyHud : reducedMotion || insert ? 0 : smooth(between(p, .27, .273)) * (1 - smooth(between(p, .284, .288))),
    keyHudKeys: insert?.id === 'dictation' ? ['↩'] : ['⌘', 'K'],
    dictation: { ...dictation, agent: 'audit' },
    typing: { stabilize: type(DEMO_TEXT.stabilize, p, .385, .425), verify: type(DEMO_TEXT.verify, p, .515, .55), audit: auditText },
    status: { stabilize: p < .435 ? 'Ready' : p < .855 ? 'Working' : 'Complete',
      verify: p < .56 ? 'Ready' : p < .595 ? 'Working' : p < .68 ? 'Needs approval' : p < .855 ? 'Working' : 'Passed',
      audit: !auditSent ? 'Ready' : p < .855 ? 'Reviewing' : 'Complete' },
    menu: creationStage === 'command' ? 'toolbar' : creationStage === 'models' ? 'models' : p >= .47 && p < .505 ? 'provider' : null,
    approval: p < .595 ? 'hidden' : p < .68 ? 'waiting' : 'approved',
    terminal: { lines: TERMINAL_LINES.filter(line => p >= line.at).length, typed,
      phase: p >= TERMINAL_COMMAND.done ? 'done' : p >= TERMINAL_COMMAND.typed ? 'running' : p >= TERMINAL_COMMAND.start ? 'typing' : 'idle' },
    tool: p < .435 ? 'Tools appear here as the agent works.' : p < .82 ? 'Read CanvasNSView.swift · Inspect zone placement' : p < .855 ? 'Running canvas checks…' : 'Canvas checks passed · Tile positions preserved',
    reducedMotion,
  };
}

export { installGuidedDemo } from './guided-demo-controller';
