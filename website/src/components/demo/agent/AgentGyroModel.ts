export const GYRO = {
  side: 18, duration: 7_200, keyframeCount: 96,
  primaryTurns: -3, secondaryTurns: 2,
  primaryTilt: 28, secondaryTilt: -28,
  reducedMotionPhase: 0.185,
  nodeDiameters: [3.20, 2.88, 2.64] as const,
  majorRadius: Math.max(3.7, 18 * 0.296),
  minorRadius: Math.max(2.3, 18 * 0.166),
} as const;

type Plane = 'primary' | 'secondary';
interface NodeSpec { plane: Plane; baseAngle: number; turns: number; diameter: number; opacityBias: number; scaleBias: number }
interface NodeState { x: number; y: number; scale: number; opacity: number; z: number }

const nodes: readonly NodeSpec[] = [
  { plane: 'primary', baseAngle: -Math.PI / 2, turns: GYRO.primaryTurns, diameter: GYRO.nodeDiameters[0], opacityBias: 0, scaleBias: 0.02 },
  { plane: 'primary', baseAngle: Math.PI / 2, turns: GYRO.primaryTurns, diameter: GYRO.nodeDiameters[1], opacityBias: -0.05, scaleBias: -0.02 },
  { plane: 'secondary', baseAngle: Math.PI * 0.08, turns: GYRO.secondaryTurns, diameter: GYRO.nodeDiameters[2], opacityBias: -0.03, scaleBias: -0.01 },
];
const clamp = (value: number, lower: number, upper: number) => Math.min(upper, Math.max(lower, value));
const smoothstep = (value: number) => { const bounded = clamp(value, 0, 1); return bounded * bounded * (3 - 2 * bounded); };
const normalize = (phase: number) => Number.isFinite(phase) ? ((phase % 1) + 1) % 1 : 0;

function gyroNodeState(spec: NodeSpec, phase: number): NodeState {
  const angle = spec.baseAngle + normalize(phase) * 2 * Math.PI * spec.turns;
  const localX = Math.cos(angle) * GYRO.majorRadius;
  const localY = Math.sin(angle) * GYRO.minorRadius;
  const tilt = (spec.plane === 'primary' ? GYRO.primaryTilt : GYRO.secondaryTilt) * Math.PI / 180;
  const frontness = smoothstep((((spec.plane === 'primary' ? -1 : 1) * Math.sin(angle)) + 1) / 2);
  return {
    x: GYRO.side / 2 + localX * Math.cos(tilt) - localY * Math.sin(tilt),
    y: GYRO.side / 2 + localX * Math.sin(tilt) + localY * Math.cos(tilt),
    scale: clamp(0.84 + 0.28 * frontness + spec.scaleBias, 0.78, 1.15),
    opacity: clamp(0.48 + 0.44 * frontness + spec.opacityBias, 0.44, 0.95),
    z: -5 + 12 * frontness,
  };
}

const transformFor = (state: NodeState, diameter: number) =>
  `translate3d(${state.x - diameter / 2}px, ${state.y - diameter / 2}px, ${state.z}px) scale(${state.scale})`;
export const gyroNodeStatesAtPhase = (phase: number) => nodes.map((spec) => gyroNodeState(spec, phase));
export const GYRO_NODE_KEYFRAMES = nodes.map((spec) => Array.from({ length: GYRO.keyframeCount }, (_, index): Keyframe => {
  const offset = index / (GYRO.keyframeCount - 1);
  const state = gyroNodeState(spec, offset);
  return { offset, transform: transformFor(state, spec.diameter), opacity: state.opacity, easing: 'linear' };
}));

interface GyroInstallation { dispose: () => void; references: number }
const installations = new WeakMap<HTMLElement, GyroInstallation>();

export function installAgentGyro(element: HTMLElement) {
  const existing = installations.get(element);
  if (existing) {
    existing.references += 1;
    return () => releaseGyro(element);
  }

  const elements = Array.from(element.querySelectorAll<HTMLElement>('[data-node]'));
  if (elements.length !== nodes.length) return () => {};
  element.dataset.enhanced = 'true';
  let animations: Animation[] = [];
  let phase = 0;
  let intersecting = false;
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const applyStatic = (value: number) => elements.forEach((node, index) => {
    const state = gyroNodeState(nodes[index], value);
    node.style.transform = transformFor(state, nodes[index].diameter);
    node.style.opacity = String(state.opacity);
    node.style.zIndex = String(Math.round(state.z * 100));
  });
  const capturePhase = () => {
    const time = animations[0]?.currentTime;
    if (typeof time === 'number') phase = normalize(time / GYRO.duration);
  };
  const createAnimations = () => {
    if (animations.length) return;
    const timelineTime = document.timeline.currentTime;
    const sharedStart = typeof timelineTime === 'number' ? timelineTime : null;
    animations = elements.map((node, index) => node.animate(GYRO_NODE_KEYFRAMES[index], {
      duration: GYRO.duration, iterations: Infinity, easing: 'linear',
    }));
    animations.forEach((animation) => {
      animation.currentTime = phase * GYRO.duration;
      if (sharedStart !== null) animation.startTime = sharedStart - phase * GYRO.duration;
    });
  };
  const isActive = () => element.dataset.status === 'working' || element.dataset.status === 'starting';
  const reconcile = () => {
    if (motion.matches) {
      phase = GYRO.reducedMotionPhase;
      createAnimations();
      animations.forEach((animation) => { animation.currentTime = phase * GYRO.duration; animation.pause(); });
      applyStatic(phase);
      return;
    }
    if (!isActive() || !intersecting || document.visibilityState !== 'visible') {
      capturePhase();
      animations.forEach((animation) => animation.pause());
      applyStatic(phase);
      return;
    }
    createAnimations();
    animations.forEach((animation) => animation.play());
  };
  applyStatic(motion.matches ? GYRO.reducedMotionPhase : phase);
  const observer = new IntersectionObserver(([entry]) => {
    intersecting = entry?.isIntersecting ?? false;
    reconcile();
  }, { threshold: 0 });
  const statusObserver = new MutationObserver(reconcile);
  observer.observe(element);
  statusObserver.observe(element, { attributes: true, attributeFilter: ['data-status'] });
  const visibilityChanged = () => reconcile();
  document.addEventListener('visibilitychange', visibilityChanged);
  motion.addEventListener('change', visibilityChanged);
  const dispose = () => {
    observer.disconnect();
    statusObserver.disconnect();
    document.removeEventListener('visibilitychange', visibilityChanged);
    motion.removeEventListener('change', visibilityChanged);
    animations.forEach((animation) => animation.cancel());
    delete element.dataset.enhanced;
  };
  installations.set(element, { dispose, references: 1 });
  reconcile();
  return () => releaseGyro(element);
}

function releaseGyro(element: HTMLElement) {
  const installation = installations.get(element);
  if (!installation) return;
  installation.references -= 1;
  if (installation.references === 0) {
    installation.dispose();
    installations.delete(element);
  }
}

/** Enhances server-rendered guided glyphs without requiring React hydration. */
export function installGuidedGyros(root: ParentNode) {
  const glyphs = Array.from(root.querySelectorAll<HTMLElement>('[data-agent-gyro]'));
  const disposers = glyphs.map(installAgentGyro);
  return () => disposers.forEach((dispose) => dispose());
}
