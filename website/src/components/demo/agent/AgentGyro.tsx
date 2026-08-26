import { useEffect, useRef } from 'react';
import styles from './AgentGyro.module.css';

interface AgentGyroProps { active: boolean }

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

export function AgentGyro({ active }: AgentGyroProps) {
  const rootRef = useRef<HTMLSpanElement>(null);
  const nodeRefs = useRef<(HTMLSpanElement | null)[]>([]);

  useEffect(() => {
    const root = rootRef.current;
    const elements = nodeRefs.current;
    if (!root || elements.some((element) => !element)) return;
    let animations: Animation[] = [];
    let phase = 0;
    let intersecting = false;
    const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const applyStatic = (value: number) => elements.forEach((element, index) => {
      if (!element) return;
      const state = gyroNodeState(nodes[index], value);
      element.style.transform = transformFor(state, nodes[index].diameter);
      element.style.opacity = String(state.opacity);
      element.style.zIndex = String(Math.round(state.z * 100));
    });
    const capturePhase = () => {
      const time = animations[0]?.currentTime;
      if (typeof time === 'number') phase = normalize(time / GYRO.duration);
    };
    const cancel = () => { capturePhase(); animations.forEach((animation) => animation.cancel()); animations = []; };
    const shouldAnimate = () => active && intersecting && document.visibilityState === 'visible' && !motion.matches;
    const start = () => {
      if (animations.length) { animations.forEach((animation) => animation.play()); return; }
      const timelineTime = document.timeline.currentTime;
      const sharedStart = typeof timelineTime === 'number' ? timelineTime : null;
      animations = elements.map((element, index) => element!.animate(GYRO_NODE_KEYFRAMES[index], { duration: GYRO.duration, iterations: Infinity, easing: 'linear' }));
      animations.forEach((animation) => {
        animation.currentTime = phase * GYRO.duration;
        if (sharedStart !== null) animation.startTime = sharedStart - phase * GYRO.duration;
      });
    };
    const reconcile = () => {
      if (motion.matches) { cancel(); phase = GYRO.reducedMotionPhase; applyStatic(phase); return; }
      if (!active) { cancel(); applyStatic(phase); return; }
      if (shouldAnimate()) start();
      else { capturePhase(); animations.forEach((animation) => animation.pause()); applyStatic(phase); }
    };
    applyStatic(motion.matches ? GYRO.reducedMotionPhase : phase);
    const observer = new IntersectionObserver(([entry]) => { intersecting = entry?.isIntersecting ?? false; reconcile(); }, { threshold: 0 });
    const visibilityChanged = () => reconcile();
    const motionChanged = () => reconcile();
    observer.observe(root);
    document.addEventListener('visibilitychange', visibilityChanged);
    motion.addEventListener('change', motionChanged);
    reconcile();
    return () => {
      observer.disconnect();
      document.removeEventListener('visibilitychange', visibilityChanged);
      motion.removeEventListener('change', motionChanged);
      animations.forEach((animation) => animation.cancel());
    };
  }, [active]);

  const initial = gyroNodeStatesAtPhase(0);
  return <span ref={rootRef} className={styles.gyro} data-active={active || undefined} data-noninteractive="true" role={active ? 'img' : undefined} aria-label={active ? 'Agent thinking' : undefined} aria-hidden={active ? undefined : true}>
    <svg className={styles.guides} viewBox="0 0 18 18" aria-hidden="true">
      <ellipse className={styles.primaryGuide} cx="9" cy="9" rx={GYRO.majorRadius} ry={GYRO.minorRadius} transform="rotate(28 9 9)" />
      <ellipse className={styles.secondaryGuide} cx="9" cy="9" rx={GYRO.majorRadius} ry={GYRO.minorRadius} transform="rotate(-28 9 9)" />
    </svg>
    {nodes.map((spec, index) => <span key={index} ref={(element) => { nodeRefs.current[index] = element; }} className={styles.node} data-node={index} style={{ width: spec.diameter, height: spec.diameter, opacity: initial[index].opacity, transform: transformFor(initial[index], spec.diameter), zIndex: Math.round(initial[index].z * 100) }} />)}
  </span>;
}
