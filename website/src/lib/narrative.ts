/** A seekable scene: every visible state comes from scroll progress alone. */
export const STEPS = [
  { id: 'canvas', title: 'A little room to think.', caption: 'Start with one open canvas. Your projects, agents and tools live here.', x: 650, y: 340, zoom: .88, cursor: [135, 595], action: 'none' },
  { id: 'zone', title: 'Give the work a home.', caption: 'Create a zone and choose the project it works in.', x: 580, y: 300, zoom: 1.25, cursor: [115, 595], action: 'zone' },
  { id: 'agent', title: 'Meet your first agent.', caption: 'Add Claude Code from the floating toolbar. It runs through your own CLI and account.', x: 425, y: 285, zoom: 1.5, cursor: [170, 595], action: 'agent' },
  { id: 'task', title: 'Tell it what you need.', caption: '“Build a settings page.” Give the agent a task, then keep the work in view.', x: 390, y: 290, zoom: 1.55, cursor: [525, 425], action: 'task' },
  { id: 'parallel', title: 'Different agents. One view.', caption: 'Run Claude Code, Codex and Pi side by side, each in its own tile.', x: 620, y: 310, zoom: 1.02, cursor: [715, 350], action: 'parallel' },
  { id: 'approval', title: 'Know when it needs you.', caption: 'An approval stays visible beside the work. Read it and decide what happens next.', x: 665, y: 325, zoom: 1.62, cursor: [642, 367], action: 'approval' },
  { id: 'tools', title: 'The tools come along.', caption: 'Keep the terminal and browser next to your agents. See the change, then run the tests.', x: 720, y: 480, zoom: 1.1, cursor: [225, 595], action: 'tools' },
  { id: 'overview', title: 'Keep every agent in view.', caption: 'More work. Less hidden state. One native workspace for your Mac.', x: 640, y: 350, zoom: .82, cursor: [1020, 570], action: 'overview' },
] as const;
export const clampProgress = (value: number) => Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
export function narrativeAt(value: number) {
  const progress = clampProgress(value);
  const position = progress * STEPS.length;
  const index = Math.min(STEPS.length - 1, Math.floor(position));
  const local = index === STEPS.length - 1 && progress === 1 ? 1 : position - index;
  const previous = STEPS[Math.max(0, index - 1)];
  const step = STEPS[index];
  // Exponential camera approach mirrors the film's 100ms camera glide, with exact endpoints.
  const t = Math.min(1, local / .48);
  const glide = t === 1 ? 1 : (1 - Math.exp(-6 * t)) / (1 - Math.exp(-6));
  const mix = (a: number, b: number) => a + (b - a) * glide;
  return { progress, index, local, step, camera: { x: mix(previous.x, step.x), y: mix(previous.y, step.y), zoom: mix(previous.zoom, step.zoom) }, cursor: { x: mix(previous.cursor[0], step.cursor[0]), y: mix(previous.cursor[1], step.cursor[1]), press: local > .48 && local < .61 && (index > 0 && index < 4 || index === 6) ? Math.sin((local - .48) / .13 * Math.PI) : 0 } };
}
export function installNarrative() {
  const root = document.querySelector<HTMLElement>('[data-narrative]');
  const viewport = root?.querySelector<HTMLElement>('[data-story-viewport]');
  const world = root?.querySelector<HTMLElement>('[data-story-world]');
  if (!root || !viewport || !world || root.dataset.installed) return;
  root.dataset.installed = 'true';
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const pointer = root.querySelector<HTMLElement>('[data-story-cursor]');
  const labels = Array.from(root.querySelectorAll<HTMLElement>('[data-story-caption]'));
  const fills = Array.from(root.querySelectorAll<HTMLElement>('[data-story-fill]'));
  let queued = false;
  const update = () => {
    queued = false;
    const rect = root.getBoundingClientRect();
    const story = narrativeAt(reduced.matches ? 1 : -rect.top / Math.max(1, root.offsetHeight - innerHeight));
    root.dataset.step = story.step.id;
    root.dataset.transitioning = String(!reduced.matches && story.index > 0 && story.local < .18);
    root.dataset.stepIndex = String(story.index);
    const menu = story.index === 1 && story.local < .65 ? 'project' : story.index === 2 && story.local < .65 ? 'provider' : 'none';
    root.dataset.menu = menu;
    root.style.setProperty('--story-progress', String(story.progress));
    root.style.setProperty('--beat-progress', String(story.local));
    root.style.setProperty('--transition-blur', `${(1 - Math.min(1, story.local / .18)) * .7}px`);
    const mobile = innerWidth < 720;
    const fit = Math.min(viewport.clientWidth / 1200, viewport.clientHeight / 680);
    const zoom = reduced.matches ? fit * .90 : mobile ? Math.max(fit * 1.6, .53) * story.camera.zoom : fit * story.camera.zoom;
    const x = viewport.clientWidth / 2 - story.camera.x * zoom;
    const y = viewport.clientHeight / 2 - story.camera.y * zoom;
    world.style.transform = `translate3d(${x}px, ${y}px, 0) scale(${zoom})`;
    if (pointer) {
      let px = x + story.cursor.x * zoom;
      let py = y + story.cursor.y * zoom;
      const target = story.index === 1 && story.local < .65 ? (story.local < .32 ? '[data-toolbar-zone]' : '.project-choice') : story.index === 2 && story.local < .65 ? (story.local < .32 ? '[data-toolbar-agent]' : '.story-provider-picker .selected') : story.index === 6 ? (story.local < .6 ? '[data-toolbar-terminal]' : '[data-toolbar-browser]') : null;
      if (story.index === 1 && story.local >= .65) { px = x + 260 * zoom; py = y + 100 * zoom; }
      if (story.index === 2 && story.local >= .65) { px = x + 370 * zoom; py = y + 195 * zoom; }
      if (target) {
        const element = root.querySelector<HTMLElement>(target);
        if (element) {
          const r = element.getBoundingClientRect();
          const v = viewport.getBoundingClientRect();
          px = r.left + r.width / 2 - v.left;
          py = r.top + r.height / 2 - v.top;
        }
      }
      pointer.style.transform = `translate3d(${px}px, ${py}px, 0) scale(${1 - story.cursor.press * .12})`;
      pointer.style.setProperty('--press', String(story.cursor.press));
    }
    labels.forEach((label, i) => { label.hidden = i !== story.index; });
    const task = root.querySelector<HTMLElement>('[data-typed-task]');
    if (task) {
      const text = 'Build a settings page with a theme picker.';
      task.textContent = story.index === 3 && story.local < .56 ? text.slice(0, Math.floor(Math.min(1, story.local / .42) * text.length)) || 'Ask this agent to do something…' : 'Ask this agent to do something…';
    }
    const status = root.querySelector<HTMLElement>('[data-first-status]');
    if (status) status.textContent = story.index < 3 ? 'Ready' : 'Working';
    fills.forEach((fill, i) => { fill.style.transform = `scaleX(${i < story.index ? 1 : i === story.index ? story.local : 0})`; });
    for (const el of root.querySelectorAll<HTMLElement>('[data-reveal]')) {
      const threshold = Number(el.dataset.reveal);
      el.dataset.visible = String(story.index > threshold || story.index === threshold && (threshold === 1 || threshold === 2 ? story.local >= .65 : threshold === 3 ? story.local >= .56 : threshold === 5 ? story.local >= .25 : story.local >= Number(el.dataset.revealLocal ?? '0')));
    }
  };
  const request = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  addEventListener('scroll', request, { passive: true });
  addEventListener('resize', request, { passive: true });
  reduced.addEventListener('change', request);
  new ResizeObserver(request).observe(viewport);
  update();
}
