import type { AssemblySnapshot } from './assembly-controller';
import { installGuidedGyros } from '../components/demo/agent/AgentGyroModel';
import { guidedSnapshot, type DemoTile, type DemoAgent } from './guided-demo';
const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));
const between = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
const smooth = (p: number) => p * p * (3 - 2 * p);

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
    // Resize the screen itself before measuring its canvas. Camera, native UI,
    // focus border and cursor therefore share one coordinate system throughout
    // the preview → full-screen → preview transition.
    const frame = reduced.matches ? 0 : smooth(between(p, .10, .18)) * (1 - smooth(between(p, .18, .26))) + smooth(between(p, .985, 1));
    root.style.setProperty('--demo-frame', String(frame));
    root.dataset.demoFramed = String(frame > .001);
    const snapshot = guidedSnapshot(p, { width: pin.clientWidth || innerWidth, height: pin.clientHeight || innerHeight, reducedMotion: reduced.matches });
    root.dataset.demoProgress = String(snapshot.progress);
    root.dataset.demoStep = snapshot.step;
    root.dataset.demoReducedMotion = String(snapshot.reducedMotion);
    root.style.setProperty('--demo-hero-opacity', String(snapshot.heroOpacity));
    root.style.setProperty('--demo-chrome-opacity', String(snapshot.chromeOpacity));
    root.style.setProperty('--demo-takeover', String(snapshot.takeover));
    root.style.setProperty('--demo-board-progress', String(snapshot.boardProgress));
    root.style.setProperty('--demo-editor-progress', String(snapshot.editorProgress));
    root.dataset.demoCreationStage = snapshot.creation.stage;
    root.dataset.demoFocusedTile = snapshot.focusedTile ?? '';
    root.dataset.demoSelectedTile = snapshot.selectedTile ?? '';
    for (const row of rows) {
      row.dataset.demoSelected = String(row.dataset.demoAgentRow === snapshot.focusedTile);
      if (row.hasAttribute('data-demo-main-row')) row.hidden = !snapshot.mainCreated;
    }
    const count = root.querySelector<HTMLElement>('[data-demo-agent-count]');
    if (count) text(count, snapshot.mainCreated ? '3' : '2');
    const rollup = root.querySelector<HTMLElement>('[data-demo-zone-rollup]');
    if (rollup) { const done = Object.values(snapshot.status).filter(value => value === 'Complete' || value === 'Passed').length; const waiting = Object.values(snapshot.status).filter(value => value === 'Needs approval').length; const working = Object.values(snapshot.status).filter(value => value === 'Working' || value === 'Reviewing').length; text(rollup, [working ? `${working} working` : '', waiting ? `${waiting} needs you` : '', done ? `${done} done` : ''].filter(Boolean).join(' · ')); }
    const mainTitle = snapshot.progress < .435 ? snapshot.creation.model : 'Stabilize zone placement';
    for (const title of nodes<HTMLElement>('[data-demo-tile-title="stabilize"], [data-agent-id="stabilize"] header strong, [data-demo-agent-row="stabilize"]>strong')) text(title, mainTitle);
    for (const tile of tiles) {
      const motion = snapshot.tiles[tile.dataset.assemblySurface as DemoTile];
      const frame = snapshot.tileFrames[tile.dataset.assemblySurface as DemoTile];
      if (!motion || !frame) continue;
      tile.style.left = `${frame.x}px`;
      tile.style.top = `${frame.y}px`;
      tile.style.width = `${frame.width}px`;
      tile.style.height = `${frame.height}px`;
      tile.style.zIndex = String(frame.zIndex);
      tile.dataset.demoCreated = String(tile.dataset.assemblySurface !== 'stabilize' || snapshot.mainCreated);
      tile.dataset.demoVisible = String(frame.visible);
      tile.dataset.demoDragging = String(frame.drag.active);
      tile.dataset.demoResizing = String(tile.dataset.assemblySurface === snapshot.resizeReadout?.tile);
      tile.dataset.demoFocused = String(snapshot.focusedTile === tile.dataset.assemblySurface);
      tile.style.setProperty('--demo-tile-x', `${motion.x}px`);
      tile.style.setProperty('--demo-tile-y', `${motion.y}px`);
      tile.style.setProperty('--demo-tile-r', `${motion.rotation}deg`);
      tile.style.setProperty('--demo-tile-scale', String(motion.scale));
      tile.style.setProperty('--demo-tile-opacity', String(motion.opacity));
      tile.style.setProperty('--demo-tile-emphasis', String(motion.emphasis));
      tile.dataset.demoEmphasis = String(motion.emphasis);
    }
    const zone = root.querySelector<HTMLElement>('[data-assembly-chrome="zone-runtime"]');
    if (zone) {
      const frames = Object.values(snapshot.tileFrames).filter(frame => frame.visible);
      zone.style.width = `${Math.max(1664, ...frames.map(frame => frame.x + frame.width + 24 - 42))}px`;
      zone.style.height = `${Math.max(1081, ...frames.map(frame => frame.y + frame.height + 24 - 45))}px`;
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
      line.dataset.demoSelectedCode = String(number >= 14 && number <= 17 && snapshot.progress >= .795 && snapshot.progress < .82);
      line.style.setProperty('--demo-line-reveal', '1');
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
      // A narrow editor keeps its native titlebar in frame, scrolls within the source,
      // and follows the selected line inside the document, like the real editor.
      const lineOffset = (changedLine.getBoundingClientRect().top - editorScroll.getBoundingClientRect().top) / (snapshot.reducedMotion ? 1 : snapshot.camera.scale) + editorScroll.scrollTop;
      const destination = Math.max(0, lineOffset - editorScroll.clientHeight * .48);
      editorScroll.scrollTop = !snapshot.reducedMotion && pin.clientWidth < 700
        ? destination * smooth(between(snapshot.progress, .775, .795)) : 0;
    }
    for (const node of typings) {
      const textarea = node.querySelector<HTMLTextAreaElement>('textarea');
      const agent = node.dataset.demoTyping as DemoAgent;
      if (textarea) {
        const value = snapshot.status[agent] === 'Ready' ? snapshot.typing[agent] ?? '' : '';
        if (textarea.value !== value) {
          textarea.value = value;
          textarea.style.height = 'auto';
          textarea.style.height = `${Math.min(136, Math.max(35, textarea.scrollHeight))}px`;
        }
      }
    }
    for (const node of statuses) {
      const value = snapshot.status[node.dataset.demoStatus as DemoAgent] ?? 'Ready';
      const nativeState = value === 'Needs approval' ? 'needsAttention' : ['Complete', 'Passed'].includes(value) ? 'done' : value === 'Ready' ? 'idle' : 'working';
      const outer = root.querySelector<HTMLElement>(`[data-demo-outer-state="${node.dataset.demoStatus}"]`);
      if (outer) { outer.dataset.status = nativeState; const label = outer.querySelector<HTMLElement>('span'); if (label) text(label, nativeState === 'idle' ? 'Idle' : nativeState === 'done' ? 'Done' : nativeState === 'needsAttention' ? 'Needs attention' : 'Working'); }
      for (const status of node.querySelectorAll<HTMLElement>('[data-status]')) status.dataset.status = nativeState;
      const nativeLabel = nativeState === 'needsAttention' ? 'Needs attention' : nativeState === 'done' ? 'Done' : nativeState === 'working' ? 'Working' : 'Ready';
      for (const label of node.querySelectorAll<HTMLElement>('[data-demo-agent-label], header span[data-status]')) text(label, nativeLabel);
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
      const nativeLabel = value === 'Needs approval' ? 'Needs attention' : ['Complete', 'Passed'].includes(value) ? 'Done' : value === 'Ready' ? 'Ready' : 'Working';
      if (label) label.textContent = nativeLabel;
      else node.append(document.createTextNode(nativeLabel));
    }
    for (const node of tools) {
      const paragraph = node.querySelector<HTMLElement>('[data-demo-tool-title]');
      if (paragraph) text(paragraph, snapshot.tool);
    }
    for (const node of transcripts) {
      const agent = node.dataset.demoTranscript as DemoAgent;
      const prompt = node.querySelector<HTMLElement>('[data-kind="user"] p');
      if (prompt) { text(prompt, snapshot.typing[agent]); prompt.closest<HTMLElement>('[data-kind="user"]')!.hidden = snapshot.status[agent] === 'Ready'; }
      const response = node.querySelector<HTMLElement>('[data-kind="assistant"] p');
      if (response) text(response, snapshot.status[agent] === 'Ready' ? `Ready. Type a prompt below to run ${agent === 'verify' ? 'Opus 5.5' : 'GPT-5.6 Sol'} in this tile.` :
        snapshot.status[agent] === 'Needs approval' ? 'The next tool action needs your approval.' :
        ['Complete', 'Passed'].includes(snapshot.status[agent]) ? 'Verified. Canvas checks pass and tile positions stay aligned.' : 'Following the task and checking the linked workspace.');
    }
    for (const node of transcripts) {
      const ready = snapshot.status[node.dataset.demoTranscript as DemoAgent] === 'Ready';
      for (const entry of node.querySelectorAll<HTMLElement>('[data-kind="tool"], [data-kind="output"]')) entry.hidden = ready;
      const value = snapshot.status[node.dataset.demoTranscript as DemoAgent];
      for (const state of node.querySelectorAll<HTMLElement>('[data-tool-state]')) text(state,
        ['Complete', 'Passed'].includes(value) ? '✓ Completed' : ready ? '○ Pending' : '◐ In progress');
    }
    const outline = root.querySelector<SVGSVGElement>('[data-demo-focus-outline]');
    const moving = Object.values(snapshot.tileFrames).some(frame => frame.drag.active);
    const focusId = snapshot.approval === 'waiting' ? 'verify' : snapshot.focusedTile;
    const focusTile = focusId ? tiles.find(tile => tile.dataset.assemblySurface === focusId) : null;
    if (outline) {
      const frame = focusTile?.getBoundingClientRect();
      const canvasRect = pin.getBoundingClientRect();
      // During a move the destination ghost is the placement cue. Marching ants
      // belong to ordinary focus/attention, never to the dragged tile's body.
      const visible = !moving && !snapshot.reducedMotion && snapshot.progress >= .34 && !!frame && frame.right > canvasRect.left && frame.left < canvasRect.right && frame.bottom > canvasRect.top && frame.top < canvasRect.bottom;
      outline.style.display = visible ? 'block' : 'none';
      outline.dataset.demoFocusTarget = focusId ?? '';
      outline.dataset.attention = String(snapshot.approval === 'waiting');
      if (visible && frame) {
        outline.style.left = `${frame.left - canvasRect.left - 8}px`;
        outline.style.top = `${frame.top - canvasRect.top - 8}px`;
        outline.style.width = `${frame.width + 16}px`;
        outline.style.height = `${frame.height + 16}px`;
        const path = outline.querySelector('rect')!;
        path.setAttribute('x', '.75'); path.setAttribute('y', '.75');
        path.setAttribute('width', String(frame.width + 14.5)); path.setAttribute('height', String(frame.height + 14.5));
        path.setAttribute('rx', String(6 * snapshot.camera.scale + 8));
      }
    }
    const ghost = root.querySelector<HTMLElement>('[data-demo-snap-preview]');
    if (ghost) {
      ghost.hidden = !snapshot.snapPreview;
      if (snapshot.snapPreview) {
        const f = snapshot.snapPreview;
        ghost.style.left = `${snapshot.camera.x + f.x * snapshot.camera.scale}px`;
        ghost.style.top = `${snapshot.camera.y + f.y * snapshot.camera.scale}px`;
        ghost.style.width = `${f.width * snapshot.camera.scale}px`; ghost.style.height = `${f.height * snapshot.camera.scale}px`;
        ghost.style.opacity = String(f.opacity); ghost.style.transform = `scale(${f.scale})`;
      }
    }
    const readout = root.querySelector<HTMLElement>('[data-demo-resize-readout]');
    if (readout) {
      readout.hidden = !snapshot.resizeReadout;
      readout.dataset.demoResizeTile = snapshot.resizeReadout?.tile ?? '';
      if (snapshot.resizeReadout) {
        const frame = snapshot.tileFrames[snapshot.resizeReadout.tile];
        text(readout, `${snapshot.resizeReadout.width} × ${snapshot.resizeReadout.height}`);
        readout.style.left = `${Math.min(pin.clientWidth - 100, snapshot.camera.x + (frame.x + frame.width) * snapshot.camera.scale + 12)}px`;
        readout.style.top = `${Math.min(pin.clientHeight - 65, snapshot.camera.y + (frame.y + frame.height) * snapshot.camera.scale + 12)}px`;
      }
    }
    const terminal = root.querySelector<HTMLElement>('[data-demo-terminal]');
    if (terminal) {
      for (const line of terminal.querySelectorAll<HTMLElement>('[data-term-line]')) line.hidden = Number(line.dataset.termLine) >= snapshot.terminal.lines;
      const typed = terminal.querySelector<HTMLElement>('[data-term-typed]');
      if (typed) text(typed, snapshot.terminal.typed);
      const live = terminal.querySelector<HTMLElement>('[data-term-cursor="live"]');
      if (live) live.hidden = snapshot.terminal.phase === 'running' || snapshot.terminal.phase === 'done';
      const final = terminal.querySelector<HTMLElement>('[data-term-final]');
      if (final) final.hidden = snapshot.terminal.phase !== 'done';
      terminal.scrollTop = terminal.scrollHeight; // A terminal keeps its newest line in view.
    }
    for (const node of captions) text(node, snapshot.caption);
    for (const node of menus) {
      const command = node.dataset.demoMenu === 'toolbar';
      const provider = node.dataset.demoMenu === 'provider';
      node.hidden = command ? !['toolbar', 'models'].includes(snapshot.menu ?? '')
        : provider ? snapshot.menu !== 'provider' || node.closest('[data-agent-id]')?.getAttribute('data-agent-id') !== 'verify' : true;
      node.setAttribute('aria-hidden', String(node.hidden));
      if (provider) node.parentElement?.querySelector('[aria-haspopup="listbox"]')?.setAttribute('aria-expanded', String(!node.hidden));
    }
    const rootCommands = root.querySelector<HTMLElement>('[data-demo-command-root]');
    const modelCommands = root.querySelector<HTMLElement>('[data-demo-command-models]');
    if (rootCommands) rootCommands.hidden = snapshot.creation.stage !== 'command';
    if (modelCommands) modelCommands.hidden = snapshot.creation.stage !== 'models';
    const query = root.querySelector<HTMLElement>('[data-demo-command-query]');
    if (query) text(query, snapshot.creation.stage === 'models' ? 'Choose a model…' : snapshot.creation.query || 'Search Array…');
    for (const node of approvals) {
      const aside = node.querySelector<HTMLElement>('aside[aria-label="Pending approval"]');
      if (aside) {
        aside.hidden = snapshot.approval === 'hidden' || (snapshot.approval === 'approved' && snapshot.progress >= .695);
        aside.setAttribute('aria-hidden', String(aside.hidden));
        const approve = aside.querySelector<HTMLButtonElement>('[data-interaction-id="approval-approve"]');
        const sending = snapshot.approval === 'approved';
        if (approve) { text(approve, sending ? 'Sending…' : 'Allow once'); approve.disabled = sending; }
        const decline = aside.querySelector<HTMLButtonElement>('[data-interaction-id="approval-deny"]');
        if (decline) { text(decline, 'Decline'); decline.disabled = sending; }
        const state = aside.querySelector<HTMLElement>('[data-approval-state]');
        if (state) { state.dataset.approvalState = sending ? 'resolving' : 'pending'; text(state, sending ? '→ Sending' : '◷ Pending'); }
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
      const targetSelectors = {
        'command-trigger': '[data-demo-menu-trigger="toolbar"]', 'command-agent': '[data-demo-command-agent]',
        'creation-model': '[data-demo-command-model]',
        'stabilize-composer': '[data-interaction-id="agent-composer-stabilize"]', 'stabilize-send': '[data-interaction-id="agent-send-stabilize"]',
        'verify-provider': '[data-agent-id="verify"] [data-demo-menu="provider"] [data-selected="true"]',
        'verify-composer': '[data-interaction-id="agent-composer-verify"]', 'verify-send': '[data-interaction-id="agent-send-verify"]',
        'audit-composer': '[data-interaction-id="agent-composer-audit"]', 'audit-send': '[data-interaction-id="agent-send-audit"]',
        'verify-allow': '[data-interaction-id="approval-approve"]', 'board-placement': '[data-demo-board-card="placement"]',
        'editor-line': '[data-demo-editor-line="14"]', 'shell-input': '[data-interaction-id="shell-input"]',
        'stabilize-header': '[data-demo-drag-handle="stabilize"]', 'editor-header': '[data-demo-drag-handle="browser"]',
        'editor-resize': '[data-demo-resize-handle="browser"]',
        'stabilize-resize': '[data-demo-resize-handle="stabilize"]',
        'shell-resize': '[data-demo-resize-handle="shell"]',
      };
      const targetSelector = snapshot.cursorTarget ? targetSelectors[snapshot.cursorTarget] : null;
      const target = targetSelector ? root.querySelector<HTMLElement>(targetSelector)?.getBoundingClientRect() : null;
      if (target?.width) {
        // Geometry comes from the actual control, including the moving titlebar
        // and the live resize corner. Direct seeks do not retain stale targets.
        const targetX = target.left + (snapshot.cursorTarget?.endsWith('header') ? Math.min(100, target.width * .3) : target.width / 2) - (origin?.left ?? 0);
        const targetY = target.top + target.height / 2 - (origin?.top ?? 0);
        const from = snapshot.cursor.fromTarget ? root.querySelector<HTMLElement>(targetSelectors[snapshot.cursor.fromTarget])?.getBoundingClientRect() : null;
        if (from?.width) {
          x = from.left + (snapshot.cursor.fromTarget?.endsWith('header') ? Math.min(100, from.width * .3) : from.width / 2) - (origin?.left ?? 0);
          y = from.top + from.height / 2 - (origin?.top ?? 0);
        }
        x += (targetX - x) * snapshot.cursor.approach;
        y += (targetY - y) * snapshot.cursor.approach;
      }
      node.style.transform = `translate(${x}px, ${y}px)`;
      node.dataset.pressed = String(snapshot.cursor.pressed);
      node.dataset.gesture = snapshot.cursorTarget?.endsWith('resize') && snapshot.cursor.approach > .99 ? 'resize' : 'pointer';
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
  const focusPath = root.querySelector<SVGElement>('[data-demo-focus-path]');
  let visible = true;
  const pauseFocus = () => { if (focusPath) focusPath.style.animationPlayState = document.hidden || !visible ? 'paused' : 'running'; };
  const visibility = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; pauseFocus(); });
  visibility.observe(pin);
  document.addEventListener('visibilitychange', pauseFocus);
  const dispose = () => { disposeGyros(); visibility.disconnect(); document.removeEventListener('visibilitychange', pauseFocus); };
  addEventListener('pagehide', dispose, { once: true });
  document.addEventListener('astro:before-swap', dispose, { once: true });
}
