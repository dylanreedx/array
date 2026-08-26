export type AssemblyPhase = 'glimpse' | 'opening' | 'assembly' | 'mac' | 'companion' | 'ready';

export interface AssemblySnapshot {
  progress: number;
  phase: AssemblyPhase;
  phaseProgress: number;
  reducedMotion: boolean;
}

const ranges: ReadonlyArray<readonly [AssemblyPhase, number, number]> = [
  ['glimpse', 0, .18],
  ['opening', .18, .36],
  ['assembly', .36, .72],
  ['mac', .72, .84],
  ['companion', .84, .94],
  ['ready', .94, 1],
];

// The visual sequence completes before the sticky track ends. The remaining
// distance is an intentional settled shelf where visitors can comfortably
// notice and enter the live workspace without balancing on the page boundary.
export const ASSEMBLY_TIMELINE_END = .78;
export const READY_LANDING_POINT = .84;

const clamp = (value: number) => Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
const clampPointer = (value: number) => Math.max(-1, Math.min(1, Number.isFinite(value) ? value : 0));

export function assemblyProgressForScroll(value: number) {
  return clamp(clamp(value) / ASSEMBLY_TIMELINE_END);
}

export function presentationFor(value: number, reducedMotion = false): AssemblySnapshot {
  const progress = reducedMotion ? 1 : clamp(value);
  const range = ranges.find(([, start, end]) => progress >= start && (progress < end || end === 1)) ?? ranges.at(-1)!;
  const [phase, start, end] = range;
  return { progress, phase, phaseProgress: clamp((progress - start) / Math.max(.0001, end - start)), reducedMotion };
}

export function installAssembly() {
  const track = document.querySelector<HTMLElement>('[data-assembly-root]');
  if (!track || track.dataset.installed) return;
  track.dataset.installed = 'true';
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let queued = false;
  let pointerQueued = false;
  let trackTop = 0;
  let trackHeight = track.offsetHeight;
  let pointerX = 0;
  let pointerY = 0;
  let detachProgress = 1;
  let previousPhase: AssemblyPhase = 'glimpse';
  let readyGateHeld = false;
  let readyGateReleased = false;
  let touchY = 0;

  type SurfaceTarget = { x: number; y: number; scale: number };

  const targetsForViewport = (width: number, height: number): Record<string, SurfaceTarget> => {
    if (width < 700) {
      return {
        stabilize: { x: width * .08, y: height * .73, scale: 1.08 },
        browser: { x: width * .91, y: height * .68, scale: 1.06 },
        shell: { x: width * .72, y: height * .91, scale: 1.08 },
        note: { x: width * .14, y: height * .95, scale: 1.1 },
        verify: { x: width * .98, y: height * .88, scale: 1.04 },
      };
    }
    if (width < 1100) {
      return {
        stabilize: { x: width * .08, y: height * .66, scale: 1.1 },
        browser: { x: width * .91, y: height * .56, scale: 1.08 },
        shell: { x: width * .77, y: height * .82, scale: 1.1 },
        note: { x: width * .22, y: height * .88, scale: 1.1 },
        verify: { x: width * 1.01, y: height * .34, scale: 1.06 },
      };
    }
    return {
      stabilize: { x: width * .045, y: height * .62, scale: 1.14 },
      browser: { x: width * .9, y: height * .55, scale: 1.12 },
      shell: { x: width * .76, y: height * .82, scale: 1.15 },
      note: { x: width * .22, y: height * .87, scale: 1.16 },
      verify: { x: width * .96, y: height * .31, scale: 1.1 },
    };
  };

  const measureSurfaceTargets = () => {
    const surfaces = Array.from(track.querySelectorAll<HTMLElement>('[data-assembly-surface]'));
    if (!surfaces.length) return;
    const targets = targetsForViewport(innerWidth, innerHeight);
    const stageRect = track.querySelector<HTMLElement>('[data-assembly-pin]')?.getBoundingClientRect();
    const originX = stageRect?.left ?? 0;
    const originY = stageRect?.top ?? 0;
    track.dataset.assemblyMeasuring = 'true';
    for (const surface of surfaces) {
      const id = surface.dataset.assemblySurface;
      const target = id ? targets[id] : undefined;
      if (!target) continue;
      const rect = surface.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;
      surface.style.setProperty('--float-x', `${originX + target.x - centerX}px`);
      surface.style.setProperty('--float-y', `${originY + target.y - centerY}px`);
      surface.style.setProperty('--float-scale', String(target.scale));
    }
    delete track.dataset.assemblyMeasuring;
  };

  const measure = () => {
    const rect = track.getBoundingClientRect();
    trackTop = scrollY + rect.top;
    trackHeight = rect.height;
    measureSurfaceTargets();
  };

  const writePointer = () => {
    pointerQueued = false;
    const amount = reduced.matches ? 0 : detachProgress * .8;
    track.style.setProperty('--pointer-x', String(pointerX));
    track.style.setProperty('--pointer-y', String(pointerY));
    track.style.setProperty('--pointer-tilt-x', `${pointerX * amount}deg`);
    track.style.setProperty('--pointer-tilt-y', `${pointerY * -amount}deg`);
    track.style.setProperty('--pointer-shift-x', `${pointerX * amount * 7}px`);
    track.style.setProperty('--pointer-shift-y', `${pointerY * amount * 5}px`);
  };

  const landingTop = () => trackTop + (trackHeight - innerHeight) * READY_LANDING_POINT;

  const announceGate = () => {
    track.dataset.readyGate = readyGateHeld ? 'held' : 'released';
    track.dispatchEvent(new CustomEvent('array:ready-gate', { detail: { held: readyGateHeld } }));
  };

  const releaseReadyGate = () => {
    if (!readyGateHeld && readyGateReleased) return;
    readyGateHeld = false;
    readyGateReleased = true;
    announceGate();
  };

  const holdReadyGate = () => {
    if (readyGateReleased || reduced.matches) return;
    readyGateHeld = true;
    announceGate();
    requestAnimationFrame(() => scrollTo({ top: landingTop(), behavior: 'auto' }));
  };

  const update = () => {
    queued = false;
    const available = Math.max(1, trackHeight - innerHeight);
    const scrollProgress = clamp((scrollY - trackTop) / available);
    const snapshot = presentationFor(assemblyProgressForScroll(scrollProgress), reduced.matches);
    detachProgress = 1 - Math.min(1, snapshot.progress / .72);
    track.style.setProperty('--assembly-progress', String(snapshot.progress));
    track.style.setProperty('--phase-progress', String(snapshot.phaseProgress));
    track.style.setProperty('--detach-progress', String(detachProgress));
    document.documentElement.style.setProperty('--page-assembly-progress', String(snapshot.progress));
    track.dataset.assemblyPhase = snapshot.phase;
    track.dispatchEvent(new CustomEvent<AssemblySnapshot>('array:assembly', { detail: snapshot }));
    if (snapshot.phase !== 'ready' && readyGateHeld) releaseReadyGate();
    if (snapshot.phase === 'ready' && previousPhase !== 'ready') holdReadyGate();
    previousPhase = snapshot.phase;
    writePointer();
  };

  const request = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };

  addEventListener('scroll', request, { passive: true });
  const onResize = () => { measure(); request(); };
  const onPointerMove = (event: PointerEvent) => {
    pointerX = clampPointer(event.clientX / Math.max(1, innerWidth) * 2 - 1);
    pointerY = clampPointer(event.clientY / Math.max(1, innerHeight) * 2 - 1);
    if (pointerQueued) return;
    pointerQueued = true;
    requestAnimationFrame(writePointer);
  };
  addEventListener('resize', onResize, { passive: true });
  addEventListener('wheel', (event) => {
    if (!readyGateHeld) return;
    if (event.deltaY < 0) { releaseReadyGate(); return; }
    event.preventDefault();
    event.stopPropagation();
  }, { passive: false, capture: true });
  addEventListener('touchstart', (event) => { touchY = event.touches[0]?.clientY ?? 0; }, { passive: true });
  addEventListener('touchmove', (event) => {
    if (!readyGateHeld) return;
    const nextY = event.touches[0]?.clientY ?? touchY;
    if (nextY - touchY > 8) { releaseReadyGate(); touchY = nextY; return; }
    event.preventDefault();
    event.stopPropagation();
    touchY = nextY;
  }, { passive: false, capture: true });
  addEventListener('keydown', (event) => {
    if (!readyGateHeld) return;
    if (event.key === 'ArrowUp' || event.key === 'PageUp' || event.key === 'Escape') { releaseReadyGate(); return; }
    if (event.key === 'ArrowDown' || event.key === 'PageDown' || event.key === ' ' || event.key === 'End') event.preventDefault();
  }, { capture: true });
  track.addEventListener('pointermove', onPointerMove, { passive: true });
  track.addEventListener('array:release-ready-gate', releaseReadyGate);
  reduced.addEventListener('change', request);
  new ResizeObserver(onResize).observe(track);
  track.querySelector('[data-see-all]')?.addEventListener('click', () => {
    readyGateReleased = false;
    scrollTo({ top: landingTop(), behavior: reduced.matches ? 'auto' : 'smooth' });
  });
  measure();
  update();
}
