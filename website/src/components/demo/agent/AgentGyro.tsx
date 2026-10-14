import { useEffect, useRef } from 'react';
import styles from './AgentGyro.module.css';
import { GYRO, gyroNodeStatesAtPhase, installAgentGyro } from './AgentGyroModel';

export { GYRO, GYRO_NODE_KEYFRAMES, gyroNodeStatesAtPhase, installGuidedGyros } from './AgentGyroModel';

interface AgentGyroProps { active: boolean }

export function AgentGyro({ active }: AgentGyroProps) {
  const rootRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const root = rootRef.current;
    return root ? installAgentGyro(root) : undefined;
  }, [active]);

  const initial = gyroNodeStatesAtPhase(0);
  return <span ref={rootRef} className={styles.gyro} data-agent-gyro="true" data-active={active || undefined} data-status={active ? 'working' : 'idle'} data-noninteractive="true" role={active ? 'img' : undefined} aria-label={active ? 'Agent thinking' : undefined} aria-hidden={active ? undefined : true}>
    <svg className={styles.guides} viewBox="0 0 18 18" aria-hidden="true">
      <ellipse className={styles.primaryGuide} cx="9" cy="9" rx={GYRO.majorRadius} ry={GYRO.minorRadius} transform="rotate(28 9 9)" />
      <ellipse className={styles.secondaryGuide} cx="9" cy="9" rx={GYRO.majorRadius} ry={GYRO.minorRadius} transform="rotate(-28 9 9)" />
    </svg>
    {initial.map((state, index) => {
      const diameter = GYRO.nodeDiameters[index];
      const transform = `translate3d(${state.x - diameter / 2}px, ${state.y - diameter / 2}px, ${state.z}px) scale(${state.scale})`;
      return <span key={index} className={styles.node} data-node={index} style={{ width: diameter, height: diameter, opacity: state.opacity, transform, zIndex: Math.round(state.z * 100) }} />;
    })}
  </span>;
}
