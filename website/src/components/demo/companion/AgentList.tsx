import type { Agent } from '../../../features/demo/types';
import styles from './companion.module.css';
import { AgentGyro } from '../agent';
import { Glyph } from '../Glyph';
import { ProviderMark } from '../ProviderMark';

interface Props {
  agents: Agent[];
  selectedId: string | null;
  onOpen: (id: string) => void;
}

const statusLabel: Record<Agent['status'], string> = {
  idle: 'Ready', starting: 'Starting', working: 'Working', needsAttention: 'Needs attention', stopped: 'Stopped', done: 'Done'
};

export function AgentList({ agents, selectedId, onOpen }: Props) {
  return (
    <div className={styles.agentList} aria-label="Paired agents">
      <div className={styles.agentRows}>
        {agents.map((agent) => (
          <button
            className={`${styles.agentRow} ${selectedId === agent.id ? styles.agentRowSelected : ''}`}
            key={agent.id}
            type="button"
            data-testid={`companion-agent-${agent.id}`}
            data-interaction-id={`companion-agent-open-${agent.id}`}
            onClick={() => onOpen(agent.id)}
          >
            {agent.status === 'working' || agent.status === 'starting'
              ? <span className={styles.statusGyro} aria-hidden="true"><AgentGyro active /></span>
              : <span className={`${styles.statusOrb} ${styles[`status_${agent.status}`]}`} aria-hidden="true"><i></i></span>}
            <span className={styles.agentRowCopy}>
              <span><strong>{agent.name}</strong><small>{statusLabel[agent.status]}</small></span>
              <em>{agent.summary}</em>
              <small className={styles.providerLine}><ProviderMark provider={agent.provider} />{agent.model} · {agent.effort}</small>
            </span>
            <span className={styles.chevron} aria-hidden="true"><Glyph name="forward" /></span>
          </button>
        ))}
      </div>
    </div>
  );
}
