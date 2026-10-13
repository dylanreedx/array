import type { AssemblySnapshot } from './assembly-controller';
import { gyroNodeStatesAtPhase, GYRO } from '../components/demo/agent/AgentGyro';

export const WORLD_WIDTH = 1280;
export const WORLD_HEIGHT = 800;
export type DemoStep = 'landing' | 'task' | 'providers' | 'approval' | 'verification' | 'overview';
export type DemoAgent = 'stabilize' | 'verify' | 'audit';
type Point = { x: number; y: number };
export const STEPS = [
  { id: 'landing', start: 0, end: .28, focus: { x: 640, y: 400 }, caption: 'Your work lands together, in one workspace.' },
  { id: 'task', start: .28, end: .43, focus: { x: 250, y: 285 }, caption: 'Give an agent a task, with the context already beside it.' },
  { id: 'providers', start: .43, end: .59, focus: { x: 620, y: 285 }, caption: 'Let Claude, Codex, and Pi work in parallel.' },
  { id: 'approval', start: .59, end: .73, focus: { x: 620, y: 285 }, caption: 'Review the next action before it runs.' },
  { id: 'verification', start: .73, end: .86, focus: { x: 990, y: 620 }, caption: 'Follow the tools and tests without losing the thread.' },
  { id: 'overview', start: .86, end: 1, focus: { x: 640, y: 400 }, caption: 'Keep the whole project in view, and pick up anywhere.' },
] as const;

export const DEMO_TEXT = {
  stabilize: 'Fix zone placement. Keep tiles aligned while zooming.',
  verify: 'Check the zone placement fix and run the canvas tests.',
  audit: 'Review the native spacing, colors, and canvas controls.',
} as const;

export interface GuidedSnapshot {
  progress: number;
  step: DemoStep;
  caption: string;
  heroOpacity: number;
  chromeOpacity: number;
  camera: Point & { scale: number; center: Point };
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
  [.28, 250, 430], [.31, 250, 430], [.38, 385, 435], [.43, 640, 45],
  [.46, 640, 45], [.49, 755, 112], [.51, 620, 430], [.56, 755, 435],
  [.59, 620, 355], [.66, 710, 390], [.69, 710, 390], [.73, 990, 570],
  [.79, 1000, 660], [.86, 1140, 700], [.96, 1140, 700],
];
function cursorAt(p: number): Point {
  const index = cursorFrames.findIndex(([time]) => time > p);
  if (index === 0) return { x: cursorFrames[0][1], y: cursorFrames[0][2] };
  if (index < 0) return { x: cursorFrames.at(-1)![1], y: cursorFrames.at(-1)![2] };
  const [a, ax, ay] = cursorFrames[index - 1];
  const [b, bx, by] = cursorFrames[index];
  const t = smooth(between(p, a, b));
  return { x: mix(ax, bx, t), y: mix(ay, by, t) };
}

/** Every visible value comes from progress alone: no timers, accumulated
 * typing, or forward-only mutations. A reverse or direct seek is identical. */
export function guidedSnapshot(value: number, options: { width: number; height: number; reducedMotion?: boolean }): GuidedSnapshot {
  const reducedMotion = options.reducedMotion ?? false;
  const p = reducedMotion ? 1 : clamp(value);
  const width = Math.max(1, options.width);
  const height = Math.max(1, options.height);
  const fit = Math.min(width / WORLD_WIDTH, height / WORLD_HEIGHT) * .94;
  const mobile = width < 700;
  const focusScale = mobile ? Math.min(width / 365, height / 490) : Math.min(width / 780, height / 560);
  let center: Point = { x: 640, y: 400 };
  let scale = fit;
  // Hold the subject for most of each beat. Only its first scroll interval
  // moves the camera; desktop and mobile follow the same semantic subject.
  for (let i = 1; i < STEPS.length; i++) {
    const step = STEPS[i];
    if (p < step.start) break;
    const previous = STEPS[i - 1];
    const t = smooth(between(p, step.start, step.start + (mobile ? .035 : .045)));
    center = { x: mix(previous.focus.x, step.focus.x, t), y: mix(previous.focus.y, step.focus.y, t) };
    const stepScale = (id: DemoStep) => id === 'landing' || id === 'overview' ? fit
      : id === 'providers' && !mobile ? Math.min(width / 1160, height / 560) * .92 : focusScale;
    const fromScale = stepScale(previous.id);
    const toScale = stepScale(step.id);
    scale = mix(fromScale, toScale, t);
  }
  const step = STEPS.find(s => p >= s.start && p < s.end) ?? STEPS.at(-1)!;
  const press = [.38, .46, .49, .56, .68].some(time => p >= time && p < time + .009);
  return {
    progress: p,
    step: step.id,
    caption: step.caption,
    heroOpacity: 1 - between(p, 0, .18),
    chromeOpacity: between(p, .10, .28),
    camera: { x: width / 2 - center.x * scale, y: height / 2 - center.y * scale, scale, center },
    cursor: { ...cursorAt(p), visible: !reducedMotion && p >= .28 && p < .93, pressed: press },
    typing: {
      stabilize: type(DEMO_TEXT.stabilize, p, .315, .365),
      verify: type(DEMO_TEXT.verify, p, .515, .55),
      audit: type(DEMO_TEXT.audit, p, .565, .595),
    },
    status: {
      stabilize: p < .38 ? 'Ready' : p < .80 ? 'Working' : 'Complete',
      verify: p < .56 ? 'Ready' : p < .595 ? 'Working' : p < .68 ? 'Needs approval' : p < .83 ? 'Working' : 'Passed',
      audit: p < .595 ? 'Ready' : p < .84 ? 'Reviewing' : 'Complete',
    },
    menu: p >= .435 && p < .47 ? 'toolbar' : p >= .47 && p < .505 ? 'provider' : null,
    approval: p < .595 ? 'hidden' : p < .68 ? 'waiting' : 'approved',
    tool: p < .38 ? 'Tools appear here as the agent works.' : p < .73 ? 'Read CanvasView.swift · Inspect zone placement' : p < .83 ? 'Running canvas checks…' : 'Canvas checks passed · Tile positions preserved',
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
  const tools = nodes<HTMLElement>('[data-demo-tool]');
  const captions = nodes<HTMLElement>('[data-demo-caption]');
  const menus = nodes<HTMLElement>('[data-demo-menu]');
  const approvals = nodes<HTMLElement>('[data-demo-approval]');
  const cursors = nodes<HTMLElement>('[data-demo-cursor]');
  const presses = nodes<SVGElement>('[data-demo-cursor-press]');
  const transcripts = nodes<HTMLElement>('[data-demo-transcript]');
  const text = (node: HTMLElement, value: string) => { if (node.textContent !== value) node.textContent = value; };
  const write = (p: number) => {
    const snapshot = guidedSnapshot(p, { width: pin.clientWidth || innerWidth, height: pin.clientHeight || innerHeight, reducedMotion: reduced.matches });
    root.dataset.demoProgress = String(snapshot.progress);
    root.dataset.demoStep = snapshot.step;
    root.dataset.demoReducedMotion = String(snapshot.reducedMotion);
    root.style.setProperty('--demo-hero-opacity', String(snapshot.heroOpacity));
    root.style.setProperty('--demo-chrome-opacity', String(snapshot.chromeOpacity));
    world.dataset.cameraX = String(snapshot.camera.center.x);
    world.dataset.cameraY = String(snapshot.camera.center.y);
    world.dataset.cameraScale = String(snapshot.camera.scale);
    world.style.transformOrigin = '0 0';
    // The reduced-motion stylesheet provides normal flow and readable cards.
    world.style.transform = snapshot.reducedMotion ? 'none' : `translate(${snapshot.camera.x}px, ${snapshot.camera.y}px) scale(${snapshot.camera.scale})`;
    for (const node of typings) {
      const textarea = node.querySelector<HTMLTextAreaElement>('textarea');
      if (textarea) textarea.value = snapshot.typing[node.dataset.demoTyping as DemoAgent] ?? '';
    }
    for (const node of statuses) {
      const value = snapshot.status[node.dataset.demoStatus as DemoAgent] ?? 'Ready';
      const nativeState = value === 'Needs approval' ? 'needsAttention' : ['Complete', 'Passed'].includes(value) ? 'done' : value === 'Ready' ? 'idle' : 'working';
      for (const status of node.querySelectorAll<HTMLElement>('[data-status]')) status.dataset.status = nativeState;
      const label = node.querySelector<HTMLElement>('span[data-status]');
      if (label) text(label, value);
      const gyro = node.querySelector<HTMLElement>('[data-node]')?.parentElement;
      if (gyro) {
        gyro.toggleAttribute('data-active', nativeState === 'working');
        const pose = gyroNodeStatesAtPhase(nativeState === 'working' && !snapshot.reducedMotion ? snapshot.progress * 8 : GYRO.reducedMotionPhase);
        gyro.querySelectorAll<HTMLElement>('[data-node]').forEach((dot, index) => {
          const state = pose[index], diameter = GYRO.nodeDiameters[index];
          dot.style.transform = `translate3d(${state.x - diameter / 2}px, ${state.y - diameter / 2}px, ${state.z}px) scale(${state.scale})`;
          dot.style.opacity = String(state.opacity);
        });
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
      if (command) text(command, snapshot.progress < .76 ? '$ swift build' : '$ swift test');
      if (result) text(result, snapshot.progress < .76 ? 'Build complete!' : snapshot.progress < .83 ? 'Running CanvasSceneEditTests…' : '18 checks passed · 0 failures');
      if (detail) text(detail, snapshot.progress < .76 ? 'Ready for the next command.' : snapshot.progress < .83 ? 'Checking world and zone-local frames.' : 'Tile positions preserved.');
      if (input) input.value = snapshot.progress >= .73 && snapshot.progress < .76 ? type('swift test', snapshot.progress, .73, .755) : '';
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
        : snapshot.progress >= .73 && snapshot.progress < .83 ? '[data-interaction-id="shell-input"]' : null;
      const target = targetSelector ? root.querySelector<HTMLElement>(targetSelector)?.getBoundingClientRect() : null;
      if (target?.width) {
        const t = snapshot.menu ? 1 : smooth(between(snapshot.progress, snapshot.progress >= .73 ? .73 : .625, snapshot.progress >= .73 ? .76 : .65));
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
}
