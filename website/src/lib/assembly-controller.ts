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

type SurfacePointerProfile = {
  x: number;
  y: number;
  rotateX: number;
  rotateY: number;
};

const surfacePointerProfiles: Readonly<Record<string, SurfacePointerProfile>> = {
  stabilize: { x: 9, y: 6, rotateX: .62, rotateY: .8 },
  browser: { x: -6.5, y: 5, rotateX: .48, rotateY: -.58 },
  shell: { x: 4.5, y: -4, rotateX: -.34, rotateY: .42 },
  note: { x: -4, y: -5.5, rotateX: -.46, rotateY: -.38 },
  verify: { x: 7.5, y: -3.5, rotateX: -.36, rotateY: .68 },
};

export function surfacePointerPose(id: string, pointerX: number, pointerY: number, amount = 1) {
  const profile = surfacePointerProfiles[id];
  const strength = clamp(amount);
  if (!profile) return { x: 0, y: 0, rotateX: 0, rotateY: 0 };
  return {
    x: clampPointer(pointerX) * profile.x * strength,
    y: clampPointer(pointerY) * profile.y * strength,
    rotateX: clampPointer(pointerY) * profile.rotateX * strength,
    rotateY: clampPointer(pointerX) * profile.rotateY * strength,
  };
}

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
  const guided = track.matches('[data-guided-demo]') || !!track.querySelector('[data-guided-demo]');
  let queued = false;
  let pointerQueued = false;
  let trackTop = 0;
  let trackHeight = track.offsetHeight;
  let pointerX = 0;
  let pointerY = 0;
  let detachProgress = 1;
  const surfaces = Array.from(track.querySelectorAll<HTMLElement>('[data-assembly-surface]'));

  type SurfaceTarget = { x: number; y: number; scale: number };

  const targetsForViewport = (width: number, height: number): Record<string, SurfaceTarget> => {
    if (width < 700) {
      const floatHeight = Math.max(height, 800);
      return {
        stabilize: { x: width * .08, y: floatHeight * .91, scale: 1.08 },
        browser: { x: width * .91, y: floatHeight * .86, scale: 1.06 },
        shell: { x: width * .72, y: floatHeight * 1.09, scale: 1.08 },
        note: { x: width * .14, y: floatHeight * 1.13, scale: 1.1 },
        verify: { x: width * .98, y: floatHeight * 1.06, scale: 1.04 },
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
    if (!surfaces.length) return;
    track.dispatchEvent(new CustomEvent('array:assembly-measure', { detail: true }));
    const targets = targetsForViewport(innerWidth, innerHeight);
    const stageRect = track.querySelector<HTMLElement>('[data-assembly-pin]')?.getBoundingClientRect();
    const originX = stageRect?.left ?? 0;
    const originY = stageRect?.top ?? 0;
    const worldScale = guided ? Number(track.querySelector<HTMLElement>('[data-guided-world]')?.dataset.cameraScale) || 1 : 1;
    track.dataset.assemblyMeasuring = 'true';
    for (const surface of surfaces) {
      const id = surface.dataset.assemblySurface;
      const target = id ? targets[id] : undefined;
      if (!target) continue;
      const rect = surface.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;
      surface.style.setProperty('--float-x', `${(originX + target.x - centerX) / worldScale}px`);
      surface.style.setProperty('--float-y', `${(originY + target.y - centerY) / worldScale}px`);
      surface.style.setProperty('--float-scale', String(guided ? target.scale * .78 / worldScale : target.scale));
    }
    delete track.dataset.assemblyMeasuring;
    track.dispatchEvent(new CustomEvent('array:assembly-measure', { detail: false }));
  };

  const measure = () => {
    const rect = track.getBoundingClientRect();
    trackTop = scrollY + rect.top;
    trackHeight = rect.height;
    measureSurfaceTargets();
  };

  const writePointer = () => {
    pointerQueued = false;
    const amount = reduced.matches ? 0 : detachProgress;
    track.style.setProperty('--pointer-x', String(pointerX));
    track.style.setProperty('--pointer-y', String(pointerY));
    for (const surface of surfaces) {
      const pose = surfacePointerPose(surface.dataset.assemblySurface ?? '', pointerX, pointerY, amount);
      surface.style.setProperty('--surface-pointer-x', `${pose.x}px`);
      surface.style.setProperty('--surface-pointer-y', `${pose.y}px`);
      surface.style.setProperty('--surface-pointer-rx', `${pose.rotateX}deg`);
      surface.style.setProperty('--surface-pointer-ry', `${pose.rotateY}deg`);
    }
  };

  const landingTop = () => trackTop + (trackHeight - innerHeight) * (guided ? .26 : READY_LANDING_POINT);

  const update = () => {
    queued = false;
    const available = Math.max(1, trackHeight - innerHeight);
    const scrollProgress = clamp((scrollY - trackTop) / available);
    const snapshot = presentationFor(guided ? scrollProgress : assemblyProgressForScroll(scrollProgress), reduced.matches);
    detachProgress = 1 - Math.min(1, snapshot.progress / (guided ? .26 : .72));
    track.style.setProperty('--assembly-progress', String(snapshot.progress));
    track.style.setProperty('--phase-progress', String(snapshot.phaseProgress));
    track.style.setProperty('--detach-progress', String(detachProgress));
    document.documentElement.style.setProperty('--page-assembly-progress', String(snapshot.progress));
    track.dataset.assemblyPhase = snapshot.phase;
    const scene = track.querySelector<HTMLElement>('[data-guided-scene]');
    if (scene) scene.dataset.assemblyPhase = snapshot.progress >= .26 ? 'ready' : snapshot.phase;
    track.dispatchEvent(new CustomEvent<AssemblySnapshot>('array:assembly', { detail: snapshot }));
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
    if (event.pointerType && event.pointerType !== 'mouse' && event.pointerType !== 'pen') return;
    pointerX = clampPointer(event.clientX / Math.max(1, innerWidth) * 2 - 1);
    pointerY = clampPointer(event.clientY / Math.max(1, innerHeight) * 2 - 1);
    if (pointerQueued) return;
    pointerQueued = true;
    requestAnimationFrame(writePointer);
  };
  const onPointerLeave = () => {
    pointerX = 0;
    pointerY = 0;
    if (pointerQueued) return;
    pointerQueued = true;
    requestAnimationFrame(writePointer);
  };
  addEventListener('resize', onResize, { passive: true });
  track.addEventListener('pointermove', onPointerMove, { passive: true });
  track.addEventListener('pointerleave', onPointerLeave, { passive: true });
  reduced.addEventListener('change', request);
  new ResizeObserver(onResize).observe(track);
  track.querySelector('[data-see-all]')?.addEventListener('click', () => {
    scrollTo({ top: landingTop(), behavior: reduced.matches ? 'auto' : 'smooth' });
  });
  measure();
  update();
}
