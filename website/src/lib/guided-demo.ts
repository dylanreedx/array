import type { AssemblySnapshot } from './assembly-controller';
import { installGuidedGyros } from '../components/demo/agent/AgentGyroModel';

export const WORLD_WIDTH = 1800;
export const WORLD_HEIGHT = 1150;
export type DemoStep = 'landing' | 'task' | 'providers' | 'approval' | 'verification' | 'overview';
export type DemoAgent = 'stabilize' | 'verify' | 'audit';
export type DemoTile = DemoAgent | 'browser' | 'shell' | 'note';
type Point = { x: number; y: number };
export const STEPS = [
  { id: 'landing', start: 0, end: .28, focus: { x: 900, y: 575 }, caption: 'Your work lands together, in one workspace.' },
  { id: 'task', start: .28, end: .43, focus: { x: 260, y: 325 }, caption: 'Give an agent a task, with the context already beside it.' },
  { id: 'providers', start: .43, end: .59, focus: { x: 690, y: 325 }, caption: 'Let Claude, Codex, and Pi work in parallel.' },
  { id: 'approval', start: .59, end: .73, focus: { x: 690, y: 350 }, caption: 'Review the next action before it runs.' },
  { id: 'verification', start: .73, end: .86, focus: { x: 470, y: 835 }, caption: 'Move from the board to the code, and follow the checks.' },
  { id: 'overview', start: .86, end: 1, focus: { x: 900, y: 575 }, caption: 'Keep the whole project in view, and pick up anywhere.' },
] as const;
export const DEMO_TEXT = {
  stabilize: 'Fix zone placement. Keep tiles aligned while zooming.',
  verify: 'Check the zone placement fix and run the canvas tests.',
  audit: 'Review the native spacing, colors, and canvas controls.',
} as const;
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
  boardProgress: number;
  boardDetail: boolean;
  editorProgress: number;
  cursor: Point & { visible: boolean; pressed: boolean };
  typing: Record<DemoAgent, string>;
  status: Record<DemoAgent, string>;
  menu: 'provider' | 'toolbar' | null;
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
  { p: .26, x: 900, y: 575, kind: 'overview' },
  { p: .31, x: 245, y: 350, kind: 'agent', mobileX: 260, mobileY: 340 },
  { p: .38, x: 290, y: 310, kind: 'agent', zoom: 1.04, mobileX: 268, mobileY: 325 },
  { p: .43, x: 680, y: 325, kind: 'parallel', mobileX: 690 },
  { p: .49, x: 755, y: 340, kind: 'parallel', mobileX: 690, mobileY: 335 },
  { p: .55, x: 830, y: 315, kind: 'parallel', mobileX: 1120 },
  { p: .59, x: 675, y: 370, kind: 'agent', mobileX: 685, mobileY: 360 },
  { p: .625, x: 680, y: 355, kind: 'agent', mobileX: 686, mobileY: 350 },
  { p: .69, x: 705, y: 340, kind: 'agent', zoom: 1.02, mobileX: 696, mobileY: 340 },
  { p: .75, x: 460, y: 840, kind: 'board', mobileX: 210, mobileY: 800 },
  { p: .765, x: 485, y: 825, kind: 'board', mobileX: 218, mobileY: 795 },
  { p: .795, x: 1190, y: 835, kind: 'editor', mobileX: 1085, mobileY: 835 },
  { p: .812, x: 1220, y: 815, kind: 'editor', zoom: 1.03, mobileX: 1090, mobileY: 830 },
  { p: .84, x: 1510, y: 325, kind: 'terminal', mobileX: 1510, mobileY: 325 },
  { p: .86, x: 1490, y: 345, kind: 'terminal', mobileX: 1500, mobileY: 335 },
  { p: .96, x: 900, y: 575, kind: 'overview' },
  { p: 1, x: 900, y: 575, kind: 'overview' },
];
function cameraAt(p: number, width: number, height: number) {
  const mobile = width < 700;
  const fit = Math.min(width / WORLD_WIDTH, height / WORLD_HEIGHT) * .96;
  const scaleFor = (frame: CameraFrame) => {
    if (frame.kind === 'overview') return fit;
    const span = mobile ? frame.kind === 'board' ? 330 : frame.kind === 'editor' ? 350 : 410
      : frame.kind === 'parallel' ? 1300 : frame.kind === 'board' ? 850 : frame.kind === 'editor' ? 650 : 680;
    const vertical = mobile ? 540 : frame.kind === 'parallel' ? 590 : 540;
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
    const detail = smooth(between(p, .751, .755)) * (1 - smooth(between(p, .775, .779)));
    center.x = mix(center.x, 285, detail);
    center.y = mix(center.y, 800, detail);
    scale = mix(scale, Math.min(width / 460, height / 580), detail);
  }
  return { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center };
}
function tileMotions(p: number, reduced: boolean): Record<DemoTile, TileMotion> {
  const ids: DemoTile[] = ['stabilize', 'verify', 'audit', 'note', 'browser', 'shell'];
  return Object.fromEntries(ids.map((id, index) => {
    const ranges: Record<DemoTile, [number, number]> = { stabilize: [.28, .43], verify: [.59, .73], audit: [.49, .59], note: [.735, .775], browser: [.775, .82], shell: [.82, .86] };
    const [start, end] = ranges[id];
    const emphasis = reduced ? 0 : Math.sin(Math.PI * between(p, start, end));
    const alive = reduced ? 0 : Math.sin(Math.PI * between(p, .26, .96));
    const phase = p * Math.PI * 3 + index * .9;
    if (reduced) return [id, { x: 0, y: 0, rotation: 0, scale: 1, opacity: 1, emphasis: 0 }];
    return [id, { x: alive * Math.sin(phase) * 12, y: alive * Math.cos(phase) * 10 - emphasis * 10,
      rotation: alive * Math.sin(phase) * .35, scale: 1 + emphasis * .025, opacity: 1, emphasis }];
  })) as Record<DemoTile, TileMotion>;
}
/** A complete seekable state: reverse/direct jumps never accumulate animation. */
export function guidedSnapshot(value: number, options: { width: number; height: number; reducedMotion?: boolean }): GuidedSnapshot {
  const reducedMotion = options.reducedMotion ?? false;
  const p = reducedMotion ? 1 : clamp(value);
  const width = Math.max(1, options.width), height = Math.max(1, options.height);
  const step = STEPS.find(s => p >= s.start && p < s.end) ?? STEPS.at(-1)!;
  return {
    progress: p, step: step.id, caption: step.caption,
    heroOpacity: 1 - between(p, 0, .18), chromeOpacity: between(p, .10, .26), takeover: smooth(between(p, .08, .26)),
    camera: cameraAt(p, width, height), tiles: tileMotions(p, reducedMotion),
    boardProgress: between(p, .735, .845), boardDetail: !reducedMotion && p >= .755 && p < .775, editorProgress: between(p, .775, .82),
    cursor: { ...cursorAt(p), visible: !reducedMotion && p >= .28 && p < .93,
      pressed: [.38, .46, .49, .56, .68, .755, .80, .835].some(time => p >= time && p < time + .009) },
    typing: { stabilize: type(DEMO_TEXT.stabilize, p, .315, .365), verify: type(DEMO_TEXT.verify, p, .515, .55), audit: type(DEMO_TEXT.audit, p, .565, .595) },
    status: { stabilize: p < .38 ? 'Ready' : p < .80 ? 'Working' : 'Complete',
      verify: p < .56 ? 'Ready' : p < .595 ? 'Working' : p < .68 ? 'Needs approval' : p < .855 ? 'Working' : 'Passed',
      audit: p < .595 ? 'Ready' : p < .84 ? 'Reviewing' : 'Complete' },
    menu: p >= .435 && p < .47 ? 'toolbar' : p >= .47 && p < .505 ? 'provider' : null,
    approval: p < .595 ? 'hidden' : p < .68 ? 'waiting' : 'approved',
    tool: p < .38 ? 'Tools appear here as the agent works.' : p < .82 ? 'Read CanvasNSView.swift · Inspect zone placement' : p < .855 ? 'Running canvas checks…' : 'Canvas checks passed · Tile positions preserved',
    reducedMotion,
  };
}

export function installGuidedDemo() {
  const root = document.querySelector<HTMLElement>('[data-guided-demo]');
  const world = root?.querySelector<HTMLElement>('[data-guided-world]');
  if (!root || !world || root.dataset.demoInstalled) return;
  root.dataset.demoInstalled = 'true';
  const pin = root.querySelector<HTMLElement>('[data-assembly-chrome="canvas"]') ?? root.querySelector<HTMLElement>('[data-assembly-pin]') ?? root;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let progress = 0;
  const nodes = <T extends HTMLElement | SVGElement>(selector: string) => Array.from(root.querySelectorAll<T>(selector));
  const typings = nodes<HTMLElement>('[data-demo-typing]');
  const statuses = nodes<HTMLElement>('[data-demo-status]');
  const mirrors = nodes<HTMLElement>('[data-demo-statusmirror]');
  const rows = nodes<HTMLElement>('[data-demo-agent-row]');
  const tools = nodes<HTMLElement>('[data-demo-tool]');
  const captions = nodes<HTMLElement>('[data-demo-caption]');
  const menus = nodes<HTMLElement>('[data-demo-menu]');
  const approvals = nodes<HTMLElement>('[data-demo-approval]');
  const cursors = nodes<HTMLElement>('[data-demo-cursor]');
  const presses = nodes<SVGElement>('[data-demo-cursor-press]');
  const transcripts = nodes<HTMLElement>('[data-demo-transcript]');
  const tiles = nodes<HTMLElement>('[data-assembly-surface]');
  const boardCards = nodes<HTMLElement>('[data-demo-board-card]');
  const editorLines = nodes<HTMLElement>('[data-demo-editor-line]');
  const boardDetails = nodes<HTMLElement>('[data-demo-board-detail]');
  const text = (node: HTMLElement, value: string) => { if (node.textContent !== value) node.textContent = value; };
  const write = (p: number) => {
    const snapshot = guidedSnapshot(p, { width: pin.clientWidth || innerWidth, height: pin.clientHeight || innerHeight, reducedMotion: reduced.matches });
    root.dataset.demoProgress = String(snapshot.progress);
    root.dataset.demoStep = snapshot.step;
    root.dataset.demoReducedMotion = String(snapshot.reducedMotion);
    root.style.setProperty('--demo-hero-opacity', String(snapshot.heroOpacity));
    root.style.setProperty('--demo-chrome-opacity', String(snapshot.chromeOpacity));
    root.style.setProperty('--demo-takeover', String(snapshot.takeover));
    root.style.setProperty('--demo-board-progress', String(snapshot.boardProgress));
    root.style.setProperty('--demo-editor-progress', String(snapshot.editorProgress));
    const selectedAgent = snapshot.progress < .43 ? 'stabilize' : snapshot.progress < .52 ? 'verify' : snapshot.progress < .59 ? 'audit' : 'verify';
    for (const row of rows) row.dataset.demoSelected = String(row.dataset.demoAgentRow === selectedAgent);
    for (const tile of tiles) {
      const motion = snapshot.tiles[tile.dataset.assemblySurface as DemoTile];
      if (!motion) continue;
      tile.style.setProperty('--demo-tile-x', `${motion.x}px`);
      tile.style.setProperty('--demo-tile-y', `${motion.y}px`);
      tile.style.setProperty('--demo-tile-r', `${motion.rotation}deg`);
      tile.style.setProperty('--demo-tile-scale', String(motion.scale));
      tile.style.setProperty('--demo-tile-opacity', String(motion.opacity));
      tile.style.setProperty('--demo-tile-emphasis', String(motion.emphasis));
      tile.dataset.demoEmphasis = String(motion.emphasis);
    }
    for (const card of boardCards) {
      const range: Record<string, [number, number]> = { placement: [.74, .77], approval: [.755, .81], tests: [.78, .845] };
      const [start, end] = range[card.dataset.demoBoardCard ?? 'placement'] ?? range.placement;
      card.dataset.demoState = snapshot.progress < start ? 'queued' : snapshot.progress < end ? 'active' : 'done';
    }
    for (const detail of boardDetails) {
      detail.hidden = !snapshot.boardDetail;
      detail.setAttribute('aria-hidden', String(detail.hidden));
      const reveal = snapshot.reducedMotion ? 1 : smooth(Math.min(between(snapshot.progress, .755, .759), 1 - between(snapshot.progress, .771, .775)));
      detail.style.setProperty('--demo-detail-reveal', String(reveal));
    }
    for (const line of editorLines) {
      const number = Number(line.dataset.demoEditorLine);
      line.dataset.demoActive = String(number === 14 && snapshot.progress >= .775 && snapshot.progress < .815);
      line.dataset.demoEdited = String([14, 16, 17].includes(number) && snapshot.progress >= .795);
      line.style.setProperty('--demo-line-reveal', String([16, 17].includes(number) ? between(snapshot.progress, .775, .80) : 1));
    }
    world.dataset.cameraX = String(snapshot.camera.center.x);
    world.dataset.cameraY = String(snapshot.camera.center.y);
    world.dataset.cameraScale = String(snapshot.camera.scale);
    world.style.transformOrigin = '0 0';
    // The reduced-motion stylesheet provides normal flow and readable cards.
    world.style.transform = snapshot.reducedMotion ? 'none' : `translate(${snapshot.camera.x}px, ${snapshot.camera.y}px) scale(${snapshot.camera.scale})`;
    const editorScroll = root.querySelector<HTMLElement>('[data-demo-editor-scroll]');
    const changedLine = root.querySelector<HTMLElement>('[data-demo-editor-line="14"]');
    if (editorScroll && changedLine) {
      // A narrow editor keeps its native titlebar in frame, wraps the source,
      // and follows the edited line inside the document, like the real editor.
      const lineOffset = (changedLine.getBoundingClientRect().top - editorScroll.getBoundingClientRect().top) / (snapshot.reducedMotion ? 1 : snapshot.camera.scale) + editorScroll.scrollTop;
      const destination = Math.max(0, lineOffset - editorScroll.clientHeight * .48);
      editorScroll.scrollTop = !snapshot.reducedMotion && pin.clientWidth < 700
        ? destination * smooth(between(snapshot.progress, .775, .795)) : 0;
    }
    for (const node of typings) {
      const textarea = node.querySelector<HTMLTextAreaElement>('textarea');
      const agent = node.dataset.demoTyping as DemoAgent;
      if (textarea) textarea.value = snapshot.status[agent] === 'Ready' ? snapshot.typing[agent] ?? '' : '';
    }
    for (const node of statuses) {
      const value = snapshot.status[node.dataset.demoStatus as DemoAgent] ?? 'Ready';
      const nativeState = value === 'Needs approval' ? 'needsAttention' : ['Complete', 'Passed'].includes(value) ? 'done' : value === 'Ready' ? 'idle' : 'working';
      for (const status of node.querySelectorAll<HTMLElement>('[data-status]')) status.dataset.status = nativeState;
      for (const label of node.querySelectorAll<HTMLElement>('[data-demo-agent-label], header span[data-status]')) text(label, value);
      const button = node.querySelector<HTMLButtonElement>('[data-demo-agent-action]');
      if (button) {
        const busy = nativeState === 'working' || nativeState === 'needsAttention';
        const label = button.querySelector<HTMLElement>('[data-demo-agent-action-label]');
        if (label) text(label, busy ? 'Stop' : 'Send');
        button.dataset.action = busy ? 'stop' : 'send';
        button.title = busy ? 'Stop current turn' : 'Send message';
        button.setAttribute('aria-label', button.title);
        button.disabled = !busy && !node.querySelector<HTMLTextAreaElement>('textarea')?.value.trim();
      }
      const gyro = node.querySelector<HTMLElement>('[data-node]')?.parentElement;
      if (gyro) {
        gyro.toggleAttribute('data-active', nativeState === 'working');
      }
    }
    for (const node of mirrors) {
      const value = snapshot.status[node.dataset.demoStatusmirror as DemoAgent] ?? 'Ready';
      node.dataset.demoState = value === 'Needs approval' ? 'needsAttention' : ['Complete', 'Passed'].includes(value) ? 'done' : value === 'Ready' ? 'idle' : 'working';
      // Keep the native status dot mounted while replacing just the label.
      const label = Array.from(node.childNodes).find(child => child.nodeType === Node.TEXT_NODE);
      if (label) label.textContent = value;
      else node.append(document.createTextNode(value));
    }
    for (const node of tools) {
      const paragraph = node.querySelector<HTMLElement>('[data-kind="tool"] p');
      if (paragraph) text(paragraph, snapshot.tool);
    }
    for (const node of transcripts) {
      const agent = node.dataset.demoTranscript as DemoAgent;
      const prompt = node.querySelector<HTMLElement>('[data-kind="user"] p');
      if (prompt) text(prompt, snapshot.typing[agent] || 'Waiting for a task.');
      const response = node.querySelector<HTMLElement>('[data-kind="assistant"] p');
      if (response) text(response, snapshot.status[agent] === 'Ready' ? 'Ready when you are.' :
        snapshot.status[agent] === 'Needs approval' ? 'The next tool action needs your approval.' :
        ['Complete', 'Passed'].includes(snapshot.status[agent]) ? 'Verified. Canvas checks pass and tile positions stay aligned.' : 'Following the task and checking the linked workspace.');
    }
    const shell = root.querySelector<HTMLElement>('[data-assembly-surface="shell"]');
    if (shell) {
      const command = shell.querySelector<HTMLElement>('code[data-type="prompt"]');
      const result = shell.querySelector<HTMLElement>('code[data-type="success"]');
      const detail = shell.querySelector<HTMLElement>('code[data-type="output"]');
      const input = shell.querySelector<HTMLInputElement>('input');
      if (command) text(command, snapshot.progress < .835 ? '$ swift build' : '$ swift test');
      if (result) text(result, snapshot.progress < .835 ? 'Build complete!' : snapshot.progress < .855 ? 'Running CanvasSceneEditTests…' : '18 checks passed · 0 failures');
      if (detail) text(detail, snapshot.progress < .835 ? 'Ready for the next command.' : snapshot.progress < .855 ? 'Checking world and zone-local frames.' : 'Tile positions preserved.');
      if (input) input.value = snapshot.progress >= .82 && snapshot.progress < .835 ? type('swift test', snapshot.progress, .82, .835) : '';
    }
    for (const node of captions) text(node, snapshot.caption);
    for (const node of menus) { node.hidden = snapshot.menu !== node.dataset.demoMenu; node.setAttribute('aria-hidden', String(node.hidden)); }
    for (const node of approvals) {
      const aside = node.querySelector<HTMLElement>('aside[aria-label="Pending approval"]');
      if (aside) {
        aside.hidden = snapshot.approval === 'hidden' || (snapshot.approval === 'approved' && snapshot.progress >= .695);
        aside.setAttribute('aria-hidden', String(aside.hidden));
        const approve = aside.querySelector<HTMLButtonElement>('[data-interaction-id="approval-approve"]');
        if (approve) text(approve, snapshot.approval === 'approved' ? 'Approved' : 'Approve');
      }
      node.dataset.approvalState = snapshot.approval;
    }
    for (const node of cursors) {
      node.hidden = !snapshot.cursor.visible;
      node.style.top = '0';
      node.style.left = '0';
      const origin = node.offsetParent?.getBoundingClientRect();
      const viewport = pin.getBoundingClientRect();
      let x = viewport.left - (origin?.left ?? 0) + snapshot.camera.x + snapshot.cursor.x * snapshot.camera.scale;
      let y = viewport.top - (origin?.top ?? 0) + snapshot.camera.y + snapshot.cursor.y * snapshot.camera.scale;
      const targetSelector = snapshot.menu === 'toolbar'
        ? (snapshot.progress < .455 ? '[data-demo-menu-trigger="toolbar"]' : '[data-demo-command-agent]')
        : snapshot.menu === 'provider' ? '[data-demo-menu="provider"] [data-selected="true"]'
        : snapshot.progress >= .625 && snapshot.progress < .695 ? '[data-interaction-id="approval-approve"]'
        : snapshot.progress >= .735 && snapshot.progress < .775 ? '[data-demo-board-card="placement"]'
        : snapshot.progress >= .775 && snapshot.progress < .82 ? '[data-demo-editor-line="14"]'
        : snapshot.progress >= .82 && snapshot.progress < .86 ? '[data-interaction-id="shell-input"]' : null;
      const target = targetSelector ? root.querySelector<HTMLElement>(targetSelector)?.getBoundingClientRect() : null;
      if (target?.width) {
        const t = snapshot.menu ? 1 : smooth(between(snapshot.progress, snapshot.progress >= .82 ? .82 : snapshot.progress >= .775 ? .775 : snapshot.progress >= .735 ? .735 : .625, snapshot.progress >= .82 ? .835 : snapshot.progress >= .775 ? .79 : snapshot.progress >= .735 ? .75 : .65));
        x = mix(x, target.left + target.width / 2 - (origin?.left ?? 0), t);
        y = mix(y, target.top + target.height / 2 - (origin?.top ?? 0), t);
      }
      node.style.transform = `translate(${x}px, ${y}px)`;
      node.dataset.pressed = String(snapshot.cursor.pressed);
    }
    for (const node of presses) {
      node.style.animation = 'none';
      node.style.opacity = snapshot.cursor.pressed ? '1' : '0';
      node.style.transform = snapshot.cursor.pressed ? 'scale(1.4)' : 'scale(.45)';
      node.style.strokeDasharray = '80';
      node.style.strokeDashoffset = snapshot.cursor.pressed ? '0' : '80';
    }
  };
  // Assembly already coalesces scroll events into one rAF. Write in that event
  // rather than scheduling a second frame that leaves camera and tiles behind.
  root.addEventListener('array:assembly', event => {
    progress = (event as CustomEvent<AssemblySnapshot>).detail.progress;
    write(progress);
  });
  root.addEventListener('array:assembly-measure', event => {
    write((event as CustomEvent<boolean>).detail ? 0 : progress);
  });
  reduced.addEventListener('change', () => write(progress));
  write(0); // Establish the world camera before assembly measures float targets.
  const disposeGyros = installGuidedGyros(root);
  addEventListener('pagehide', disposeGyros, { once: true });
  document.addEventListener('astro:before-swap', disposeGyros, { once: true });
}
