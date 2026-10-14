
export const WORLD_WIDTH = 2060;
export const WORLD_HEIGHT = 1320;
export type DemoStep = 'landing' | 'creation' | 'task' | 'providers' | 'approval' | 'verification' | 'layout' | 'overview';
export type DemoAgent = 'stabilize' | 'verify' | 'audit';
export type DemoTile = DemoAgent | 'browser' | 'shell' | 'note';
type Point = { x: number; y: number };
export const STEPS = [
  { id: 'landing', start: 0, end: .27, focus: { x: 900, y: 575 }, caption: 'Your project and its supporting tiles land together.' },
  { id: 'creation', start: .27, end: .38, focus: { x: 285, y: 365 }, caption: 'Choose a model. Create an agent beside the work.' },
  { id: 'task', start: .38, end: .445, focus: { x: 285, y: 365 }, caption: 'Focus the new agent, then give it a task.' },
  { id: 'providers', start: .445, end: .595, focus: { x: 740, y: 325 }, caption: 'Let Claude and Codex work in parallel.' },
  { id: 'approval', start: .595, end: .73, focus: { x: 740, y: 350 }, caption: 'Review the next action before it runs.' },
  { id: 'verification', start: .73, end: .86, focus: { x: 470, y: 895 }, caption: 'Move from the board to the code, and follow the checks.' },
  { id: 'layout', start: .86, end: .985, focus: { x: 1250, y: 905 }, caption: 'Rearrange the canvas. Give each tile the space its work needs.' },
  { id: 'overview', start: .985, end: 1, focus: { x: 900, y: 575 }, caption: 'Keep the whole project in view, and pick up anywhere.' },
] as const;
export const DEMO_TEXT = {
  stabilize: 'Fix zone placement. Keep tiles aligned while zooming.',
  verify: 'Check the zone placement fix and run the canvas tests.',
  audit: 'Review the native spacing, colors, and canvas controls.',
} as const;
export type CreationStage = 'absent' | 'command' | 'models' | 'spawning' | 'focused' | 'sent';
export type CursorTarget = 'command-trigger' | 'command-agent' | 'creation-model' | 'stabilize-composer' | 'stabilize-send' | 'verify-provider' | 'verify-composer' | 'verify-send' | 'audit-composer' | 'audit-send' | 'verify-allow' | 'board-placement' | 'editor-line' | 'shell-input' | 'stabilize-header' | 'editor-header' | 'editor-resize' | 'stabilize-resize' | 'shell-resize' | null;
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
  cursor: Point & { visible: boolean; pressed: boolean; approach: number; fromTarget: CursorTarget };
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
type CameraFrame = { p: number; x: number; y: number; kind: CameraKind; zoom?: number; mobileX?: number; mobileY?: number };
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
  { p: .873, x: 730, y: 400, kind: 'parallel', mobileX: 525, mobileY: 365 },
  { p: .902, x: 750, y: 410, kind: 'parallel', mobileX: 765, mobileY: 370 },
  { p: .923, x: 1250, y: 905, kind: 'editor', mobileX: 1135 },
  { p: .95, x: 1370, y: 970, kind: 'editor', mobileX: 1205, mobileY: 970 },
  { p: .957, x: 825, y: 305, kind: 'agent' },
  { p: .970, x: 825, y: 305, kind: 'agent' },
  { p: .976, x: 1696, y: 370, kind: 'terminal' },
  { p: .985, x: 1696, y: 370, kind: 'terminal' },
  { p: 1, x: 1030, y: 660, kind: 'overview' },
];
function cameraAt(p: number, width: number, height: number) {
  const mobile = width < 700;
  const fit = Math.min(width / WORLD_WIDTH, height / WORLD_HEIGHT) * .96;
  const scaleFor = (frame: CameraFrame) => {
    if (frame.kind === 'overview') return fit;
    const span = mobile ? frame.p >= .873 && frame.p <= .902 ? 1020 : frame.p >= .957 && frame.p <= .970 ? 620 : frame.p >= .976 ? 560 : frame.kind === 'board' ? 330 : frame.kind === 'editor' ? frame.p >= .923 ? 550 : 390 : frame.p <= .46 ? 470 : 410
      : frame.kind === 'parallel' ? 1300 : frame.kind === 'board' ? 850 : frame.kind === 'editor' ? frame.p >= .923 ? 900 : 650 : 680;
    const vertical = mobile ? frame.p >= .923 ? 740 : frame.p <= .46 ? 650 : 540 : frame.p >= .923 ? 740 : ['agent', 'parallel'].includes(frame.kind) ? 660 : 540;
    return Math.min(width / span, height / vertical) * (frame.zoom ?? 1);
  };
  const end = CAMERA.findIndex(frame => frame.p > p);
  const a = CAMERA[Math.max(0, end < 0 ? CAMERA.length - 1 : end - 1)];
  const b = end < 0 ? a : CAMERA[end];
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
    if (p >= .873 && p <= .902) {
      const drag = smooth(between(p, .873, .902));
      // Keep both the moving tile and its predicted destination in view.
      center.x = (mix(70, 550, drag) + 550 + 430) / 2;
      center.y = mix(90, 95, drag) + 275;
    }
    const detail = smooth(between(p, .751, .755)) * (1 - smooth(between(p, .775, .779)));
    center.x = mix(center.x, 285, detail);
    center.y = mix(center.y, 860, detail);
    scale = mix(scale, Math.min(width / 460, height / 580), detail);
  }
  return { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center };
}
function focusAt(p: number): DemoTile | null {
  if (p >= .34 && p < .445) return 'stabilize';
  if (p >= .47 && p <= .55) return 'verify';
  if (p >= .56 && p <= .595) return 'audit';
  if (p >= .615 && p < .70) return 'verify';
  if (p >= .735 && p < .775) return 'note';
  if (p >= .78 && p < .82) return 'browser';
  if (p >= .82 && p < .86) return 'shell';
  if (p >= .873 && p < .902) return 'stabilize';
  if (p >= .909 && p < .923 || p >= .93 && p < .95) return 'browser';
  if (p >= .957 && p < .970) return 'stabilize';
  if (p >= .976 && p < .985) return 'shell';
  return null;
}
function frameSnapshots(p: number, mobile: boolean, selected: DemoTile | null): Record<DemoTile, TileFrameSnapshot> {
  const neutral = { active: false, lift: 0, rotation: 0, scaleX: 1, scaleY: 1 };
  const base = (id: DemoTile, x: number, y: number, width: number, height: number): TileFrameSnapshot => ({ x, y, width, height,
    visible: id !== 'stabilize' || p >= .34, selected: id === selected, zIndex: id === selected ? 20 : 2, drag: { ...neutral } });
  const mainDrag = smooth(between(p, .873, .902));
  const mainX = mix(70, 550, mainDrag);
  // CanvasAutoLayoutEngine.solveMemberMove: baseline-relative minimal pushes,
  // then an origin exchange when the active center enters verify's old slot.
  // Invert the smooth pointer path to keep the latch seekable and continuous.
  const latchFraction = (550 - 430 / 2 - 70) / 480;
  const latchTime = .873 + .029 * (.5 - Math.sin(Math.asin(1 - 2 * latchFraction) / 3));
  const gap = 8; // TileGapResolver.defaultGap.
  const pushX = Math.min(mainX, 550 - 430 / 2);
  const pushedVerify = Math.max(550, pushX + 430 + gap);
  const pushedAudit = Math.max(980, pushedVerify + 380 + gap);
  const pushedShell = Math.max(1370, pushedAudit + 340 + gap);
  const swapRaw = between(p, latchTime, latchTime + .008);
  const swap = 1 - Math.pow(1 - swapRaw, 3); // Passive 110ms ease-out, projected onto scroll.

  const editorDrag = smooth(between(p, .909, .923));
  const resize = between(p, .93, .95);
  const mainResize = between(p, .957, .970);
  const shellResize = between(p, .976, .985);
  const mainWidth = mix(430, 550, mainResize);
  const auditX = Math.max(mix(pushedAudit, 988, swap), mainResize > 0 ? 550 + mainWidth + gap : 980);
  const shellX = Math.max(mix(pushedShell, 1370, swap), mainResize > 0 ? auditX + 340 + gap : 1370);
  const shellHeight = mix(470, 560, shellResize);
  const editorY = Math.max(mix(680, 690, editorDrag), shellResize > 0 ? 90 + shellHeight + gap : 680); // Pointer-owned live dimensions, no spring.
  const frames: Record<DemoTile, TileFrameSnapshot> = {
    stabilize: base('stabilize', mainX, mix(90, 95, mainDrag), mainWidth, mix(550, 420, mainResize)),
    verify: base('verify', mix(pushedVerify, 70, swap), 90, 380, 470),
    audit: base('audit', auditX, 90, 340, 450),
    shell: base('shell', shellX, 90, mix(300, 480, shellResize), shellHeight),
    note: base('note', 70, 680, 800, 430),
    browser: base('browser', mix(920, 970, editorDrag), editorY, mix(mobile ? 330 : 560, mobile ? 470 : 800, resize), mix(430, 560, resize)),
  };
  frames.stabilize.drag.active = p >= .873 && p < .902;
  frames.browser.drag.active = p >= .909 && p < .923;
  return frames;
}
function tileMotions(frames: Record<DemoTile, TileFrameSnapshot>): Record<DemoTile, TileMotion> {
  return Object.fromEntries(Object.entries(frames).map(([id, frame]) => [id,
    { x: 0, y: 0, scale: 1, rotation: 0, opacity: frame.visible ? 1 : 0, emphasis: frame.selected && !frame.drag.active ? 1 : 0 },
  ])) as Record<DemoTile, TileMotion>;
}
function targetAt(p: number): CursorTarget {
  if (p >= .27 && p < .285) return 'command-trigger';
  if (p >= .285 && p < .295) return 'command-agent';
  if (p >= .295 && p < .335) return 'creation-model';
  if (p >= .385 && p < .425) return 'stabilize-composer';
  if (p >= .425 && p < .445) return 'stabilize-send';
  if (p >= .47 && p < .505) return 'verify-provider';
  if (p >= .515 && p < .55) return 'verify-composer';
  if (p >= .55 && p < .56) return 'verify-send';
  if (p >= .565 && p < .595) return 'audit-composer';
  if (p >= .595 && p < .615) return 'audit-send';
  if (p >= .625 && p < .695) return 'verify-allow';
  if (p >= .735 && p < .775) return 'board-placement';
  if (p >= .775 && p < .82) return 'editor-line';
  if (p >= .82 && p < .86) return 'shell-input';
  if (p >= .86 && p < .903) return 'stabilize-header';
  if (p >= .903 && p < .923) return 'editor-header';
  if (p >= .923 && p < .95) return 'editor-resize';
  if (p >= .95 && p < .970) return 'stabilize-resize';
  if (p >= .970 && p < .985) return 'shell-resize';
  return null;
}
/** A complete seekable state: reverse/direct jumps never accumulate animation. */
export function guidedSnapshot(value: number, options: { width: number; height: number; reducedMotion?: boolean }): GuidedSnapshot {
  const reducedMotion = options.reducedMotion ?? false;
  const p = reducedMotion ? 1 : clamp(value);
  const width = Math.max(1, options.width), height = Math.max(1, options.height);
  const step = STEPS.find(s => p >= s.start && p < s.end) ?? STEPS.at(-1)!;
  const focusedTile = reducedMotion ? null : focusAt(p);
  const selectedTile = focusedTile ?? (p >= .34 && p < .38 ? 'stabilize' : null);
  const tileFrames = frameSnapshots(p, width < 700, selectedTile);
  const creationStage: CreationStage = p < .27 ? 'absent' : p < .295 ? 'command' : p < .335 ? 'models' : p < .38 ? 'spawning' : p < .435 ? 'focused' : 'sent';
  // Like showDragGhost(at:) in CanvasNSView, preview the resolved destination
  // independently of the pointer-owned tile. The story's layout solver supplies
  // these destinations; mouse-up commits the very same frame.
  const moving: DemoTile | null = tileFrames.stabilize.drag.active ? 'stabilize' : tileFrames.browser.drag.active ? 'browser' : null;
  const ghostFrame = moving ? tileFrames[moving] : null;
  const ghostStart = moving === 'stabilize' ? .873 : .909;
  const resizing: DemoTile | null = p >= .93 && p < .95 ? 'browser' : p >= .957 && p < .970 ? 'stabilize' : p >= .976 && p < .985 ? 'shell' : null;
  const approaches: ReadonlyArray<readonly [number, number, CursorTarget]> = [[.86, .873, 'shell-input'], [.903, .909, 'stabilize-header'], [.923, .93, 'editor-header'], [.95, .957, 'editor-resize'], [.970, .976, 'stabilize-resize']];
  const approach = approaches.find(([start, end]) => p >= start && p < end);
  const held = tileFrames.stabilize.drag.active || tileFrames.browser.drag.active || !!resizing;
  return {
    progress: p, step: step.id, caption: step.caption,
    heroOpacity: 1 - between(p, 0, .18), chromeOpacity: smooth(between(p, .10, .18)), takeover: smooth(between(p, .08, .26)),
    camera: cameraAt(p, width, height), tiles: tileMotions(tileFrames), tileFrames,
    mainCreated: p >= .34, selectedTile, focusedTile,
    creation: { stage: creationStage, query: creationStage === 'command' ? type('Agent', p, .272, .285) : '', provider: 'Codex', model: 'GPT-5.6 Sol' },
    cursorTarget: reducedMotion ? null : targetAt(p),
    menuTarget: creationStage === 'command' ? 'creation-agent' : creationStage === 'models' ? 'creation-model' : p >= .47 && p < .505 ? 'verify-provider' : null,
    snapPreview: !reducedMotion && moving && ghostFrame ? { tile: moving, x: moving === 'stabilize' ? 550 : 970, y: moving === 'stabilize' ? 95 : 690, width: ghostFrame.width, height: ghostFrame.height,
      opacity: smooth(between(p, ghostStart, ghostStart + .002)), scale: mix(.96, 1, smooth(between(p, ghostStart, ghostStart + .002))) } : null,
    resizeReadout: !reducedMotion && resizing ? { tile: resizing, width: Math.round(tileFrames[resizing].width), height: Math.round(tileFrames[resizing].height - 24) } : null,
    boardProgress: between(p, .735, .845), boardDetail: !reducedMotion && p >= .755 && p < .775, editorProgress: between(p, .775, .82),
    cursor: { ...cursorAt(p), visible: !reducedMotion && p >= .27 && p < .985, approach: approach ? smooth(between(p, approach[0], approach[1])) : 1, fromTarget: approach?.[2] ?? null,
      pressed: held || [.285, .332, .435, .49, .555, .605, .68, .755, .80, .835].some(time => p >= time && p < time + .009) },
    typing: { stabilize: type(DEMO_TEXT.stabilize, p, .385, .425), verify: type(DEMO_TEXT.verify, p, .515, .55), audit: type(DEMO_TEXT.audit, p, .565, .595) },
    status: { stabilize: p < .435 ? 'Ready' : p < .855 ? 'Working' : 'Complete',
      verify: p < .56 ? 'Ready' : p < .595 ? 'Working' : p < .68 ? 'Needs approval' : p < .855 ? 'Working' : 'Passed',
      audit: p < .605 ? 'Ready' : p < .855 ? 'Reviewing' : 'Complete' },
    menu: creationStage === 'command' ? 'toolbar' : creationStage === 'models' ? 'models' : p >= .47 && p < .505 ? 'provider' : null,
    approval: p < .595 ? 'hidden' : p < .68 ? 'waiting' : 'approved',
    tool: p < .435 ? 'Tools appear here as the agent works.' : p < .82 ? 'Read CanvasNSView.swift · Inspect zone placement' : p < .855 ? 'Running canvas checks…' : 'Canvas checks passed · Tile positions preserved',
    reducedMotion,
  };
}

export { installGuidedDemo } from './guided-demo-controller';
