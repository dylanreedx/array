import type { Agent, TranscriptEntry } from '../../../features/demo/types';
import styles from './companion.module.css';
import { AgentGyro } from '../agent';
import { Glyph } from '../Glyph';
import { ProviderMark } from '../ProviderMark';

interface Props {
  agent: Agent;
  onBack: () => void;
  onShowOnCanvas: (agent: Agent) => void;
}

function TranscriptItem({ entry }: { entry: TranscriptEntry }) {
  if (entry.kind === 'tool' || entry.kind === 'output') {
    return (
      <li className={styles.transcriptTool}>
        <span aria-hidden="true"><Glyph name="tool" /></span>
        <div><small>{entry.kind === 'tool' ? 'Tool call' : 'Output'}</small><p>{entry.text}</p></div>
      </li>
    );
  }
  return (
    <li className={`${styles.transcriptMessage} ${styles[`transcript_${entry.kind}`]}`}>
      <small>{entry.kind === 'user' ? 'You' : entry.kind === 'notice' ? 'Notice' : 'Agent'}</small>
      <p>{entry.text}</p>
    </li>
  );
}

export function AgentDetail({ agent, onBack, onShowOnCanvas }: Props) {
  return (
    <article className={styles.agentDetail} aria-labelledby={`companion-agent-title-${agent.id}`}>
      <div className={styles.detailNav}>
        <button type="button" data-interaction-id="companion-agent-back" onClick={onBack}><span aria-hidden="true"><Glyph name="back" /></span> Agents</button>
        <span>{agent.status === 'needsAttention' ? 'Needs attention' : agent.status}</span>
      </div>
      <header className={styles.detailHeader}>
        {agent.status === 'working' || agent.status === 'starting'
          ? <span className={styles.statusGyro} aria-hidden="true"><AgentGyro active /></span>
          : <span className={`${styles.detailOrb} ${styles[`status_${agent.status}`]}`} aria-hidden="true"><i></i></span>}
        <div><h3 id={`companion-agent-title-${agent.id}`}>{agent.name}</h3><p>{agent.branch}</p></div>
      </header>
      <dl className={styles.agentMeta}>
        <div><dt>Model</dt><dd>{agent.model}</dd></div>
        <div><dt>Effort</dt><dd>{agent.effort}</dd></div>
        <div><dt>Provider</dt><dd className={styles.providerLine}><ProviderMark provider={agent.provider} />{agent.provider}</dd></div>
      </dl>
      <div className={styles.detailSummary}><small>Current work</small><p>{agent.summary}</p></div>
      <section className={styles.transcript} aria-label={`${agent.name} transcript`}>
        <h4>Transcript</h4>
        {agent.transcript.length ? <ol>{agent.transcript.map((entry) => <TranscriptItem entry={entry} key={entry.id} />)}</ol> : <p className={styles.emptyCopy}>No messages yet.</p>}
      </section>
      <button className={styles.showCanvas} type="button" data-testid="companion-show-on-canvas" data-interaction-id="companion-show-on-canvas" onClick={() => onShowOnCanvas(agent)}>
        <span aria-hidden="true"><Glyph name="fit" /></span><span><strong>Show on Companion canvas</strong><small>Find the matching Mac tile</small></span><b aria-hidden="true"><Glyph name="forward" /></b>
      </button>
    </article>
  );
}
