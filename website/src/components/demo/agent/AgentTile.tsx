import { useEffect, useMemo, useRef, useState, type Dispatch, type KeyboardEvent, type SyntheticEvent } from 'react';
import type { AgentStatus, DemoAction, DemoState, TranscriptEntry } from '../../../features/demo/types';
import { Glyph } from '../Glyph';
import { AgentGyro } from './AgentGyro';
import { ProviderMark } from '../ProviderMark';
import styles from './AgentTile.module.css';

export type AgentEvent =
  | { type: 'message-sent'; agentId: string; operation: number; message: string }
  | { type: 'agent-advanced'; agentId: string; operation: number; status: AgentStatus }
  | { type: 'approval-started'; agentId: string; decision: 'accept' | 'decline' }
  | { type: 'approval-completed'; agentId: string; decision: 'accept' | 'decline' }
  | { type: 'config-changed'; agentId: string; field: 'provider' | 'model' | 'effort'; value: string }
  | { type: 'agent-stopped' | 'agent-restarted'; agentId: string };

export interface AgentTileProps {
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
  agentId: string;
  onEvent?: (event: AgentEvent) => void;
  className?: string;
}

const providerModels: Record<string, string[]> = {
  Codex: ['GPT-5', 'GPT-5 mini'],
  'Claude Code': ['Claude Opus', 'Claude Sonnet'],
  Pi: ['Auto', 'Gemini Pro'],
};
const effortLevels = ['Low', 'Medium', 'High'];

const statusLabel: Record<AgentStatus, string> = {
  idle: 'Idle', starting: 'Starting', working: 'Working', needsAttention: 'Needs attention', stopped: 'Stopped', done: 'Done',
};

export function AgentTile({ state, dispatch, agentId, onEvent, className = '' }: AgentTileProps) {
  const agent = state.agents[agentId];
  const approval = state.approval.agentId === agentId ? state.approval : null;
  const timers = useRef<number[]>([]);
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set(agent?.transcript.filter((entry) => entry.expanded).map((entry) => entry.id)));
  const [actionsOpen, setActionsOpen] = useState(false);

  useEffect(() => () => timers.current.forEach(window.clearTimeout), []);

  const active = agent?.status === 'working' || agent?.status === 'starting';
  const models = useMemo(() => providerModels[agent?.provider] ?? [agent?.model ?? 'Auto'], [agent?.provider, agent?.model]);

  if (!agent) {
    return <section className={`${styles.tile} ${className}`} data-noninteractive="true"><p className={styles.missing}>Agent unavailable</p></section>;
  }

  const emit = (event: AgentEvent) => onEvent?.(event);
  const schedule = (operation: number, delay: number, status: AgentStatus, entry?: TranscriptEntry) => {
    timers.current.push(window.setTimeout(() => {
      dispatch({ type: 'ADVANCE_AGENT', id: agent.id, status, entry, operation });
      emit({ type: 'agent-advanced', agentId: agent.id, operation, status });
    }, delay));
  };

  const submitMessage = (event?: SyntheticEvent<HTMLFormElement>) => {
    event?.preventDefault();
    const message = agent.draft.trim();
    if (!message || agent.status === 'stopped') return;
    const operation = state.operationGeneration + 1;
    dispatch({ type: 'SEND_AGENT_MESSAGE', id: agent.id, message, operation });
    emit({ type: 'message-sent', agentId: agent.id, operation, message });
    schedule(operation, 420, 'working', { id: `tool-${operation}`, kind: 'tool', text: 'Inspecting the active workspace and related files', expanded: true });
    schedule(operation, 980, 'working', { id: `output-${operation}`, kind: 'output', text: 'Context assembled · 4 surfaces linked', expanded: true });
    schedule(operation, 1540, 'done', { id: `assistant-${operation}`, kind: 'assistant', text: 'Done. The linked workspace now reflects the requested change.' });
  };

  const changeConfig = (field: 'provider' | 'model' | 'effort', value: string) => {
    dispatch({ type: 'SET_AGENT_CONFIG', id: agent.id, field, value });
    if (field === 'provider') dispatch({ type: 'SET_AGENT_CONFIG', id: agent.id, field: 'model', value: providerModels[value]?.[0] ?? 'Auto' });
    emit({ type: 'config-changed', agentId: agent.id, field, value });
  };

  const resolveApproval = (decision: 'accept' | 'decline') => {
    if (!approval || approval.state !== 'pending') return;
    dispatch({ type: 'RESOLVE_APPROVAL', decision, phase: 'start' });
    emit({ type: 'approval-started', agentId: agent.id, decision });
    timers.current.push(window.setTimeout(() => {
      dispatch({ type: 'RESOLVE_APPROVAL', decision, phase: 'complete' });
      emit({ type: 'approval-completed', agentId: agent.id, decision });
    }, 650));
  };

  return (
    <section className={`${styles.tile} ${className}`} data-agent-id={agent.id} data-status={agent.status} aria-label={`${agent.name}, ${statusLabel[agent.status]}`}>
      <header className={styles.header}>
        <AgentGyro active={active} />
        <div className={styles.identity}>
          <strong>{agent.name}</strong>
          <span>{agent.branch}</span>
        </div>
        <span className={styles.status} data-status={agent.status}>{statusLabel[agent.status]}</span>
        <ProviderMark provider={agent.provider} className={styles.providerMark} />
        <div className={styles.actions}>
          <button type="button" data-interaction-id={`agent-actions-${agent.id}`} aria-label="Agent actions" aria-expanded={actionsOpen} onClick={() => setActionsOpen((value) => !value)}><Glyph name="more" /></button>
          {actionsOpen && (
            <div className={styles.actionMenu} role="menu">
              {agent.status === 'stopped' ? (
                <button type="button" role="menuitem" data-interaction-id={`agent-restart-${agent.id}`} onClick={() => { dispatch({ type: 'RESTART_AGENT', id: agent.id }); setActionsOpen(false); emit({ type: 'agent-restarted', agentId: agent.id }); }}>Restart agent</button>
              ) : (
                <button type="button" role="menuitem" data-interaction-id={`agent-stop-${agent.id}`} onClick={() => { dispatch({ type: 'STOP_AGENT', id: agent.id }); setActionsOpen(false); emit({ type: 'agent-stopped', agentId: agent.id }); }}>Stop agent</button>
              )}
              <button type="button" role="menuitem" data-interaction-id={`agent-close-${agent.id}`} onClick={() => { dispatch({ type: 'CLOSE_TILE', id: agent.tileId }); setActionsOpen(false); }}>Close tile</button>
            </div>
          )}
        </div>
      </header>

      <div className={styles.config} aria-label="Agent configuration">
        <label>Provider<select data-interaction-id={`agent-provider-${agent.id}`} value={agent.provider} onChange={(event) => changeConfig('provider', event.target.value)}>{Object.keys(providerModels).map((provider) => <option key={provider}>{provider}</option>)}</select></label>
        <label>Model<select data-interaction-id={`agent-model-${agent.id}`} value={agent.model} onChange={(event) => changeConfig('model', event.target.value)}>{models.includes(agent.model) ? null : <option>{agent.model}</option>}{models.map((model) => <option key={model}>{model}</option>)}</select></label>
        <label>Effort<select data-interaction-id={`agent-effort-${agent.id}`} value={agent.effort} onChange={(event) => changeConfig('effort', event.target.value)}>{effortLevels.map((effort) => <option key={effort}>{effort}</option>)}</select></label>
      </div>

      <div className={styles.transcript} aria-label="Agent transcript" aria-live="polite" tabIndex={0}>
        {agent.transcript.length === 0 && <p className={styles.empty} data-noninteractive="true">Ready for a prompt.</p>}
        {agent.transcript.map((entry) => {
          const expandable = entry.kind === 'tool' || entry.kind === 'output';
          const open = expanded.has(entry.id);
          return (
            <article className={styles.entry} data-kind={entry.kind} key={entry.id} data-noninteractive={expandable ? undefined : 'true'}>
              {expandable ? (
                <button type="button" className={styles.entryToggle} data-interaction-id={`agent-transcript-${agent.id}-${entry.id}`} aria-expanded={open} onClick={() => setExpanded((current) => { const next = new Set(current); next.has(entry.id) ? next.delete(entry.id) : next.add(entry.id); return next; })}>
                  <span className={styles.entryTitle}><Glyph name={entry.kind === 'tool' ? 'tool' : 'terminal'} />{entry.kind === 'tool' ? 'Tool' : 'Output'}</span><Glyph name={open ? 'collapse' : 'expand'} />
                </button>
              ) : <small>{entry.kind === 'user' ? 'You' : entry.kind === 'notice' ? 'Notice' : 'Array agent'}</small>}
              {(!expandable || open) && <p>{entry.text}</p>}
            </article>
          );
        })}
        {active && <div className={styles.thinking} data-noninteractive="true"><AgentGyro active /><span>{agent.summary}</span></div>}
      </div>

      {approval && approval.state !== 'accepted' && approval.state !== 'declined' && (
        <aside className={styles.approval} aria-label="Pending approval" aria-live="polite">
          <div data-noninteractive="true"><strong>{approval.title}</strong><p>{approval.detail}</p></div>
          <div className={styles.approvalActions}>
            <button type="button" data-interaction-id="approval-approve" disabled={approval.state === 'resolving'} onClick={() => resolveApproval('accept')}>{approval.state === 'resolving' ? 'Resolving…' : 'Approve'}</button>
            <button type="button" data-interaction-id="approval-deny" disabled={approval.state === 'resolving'} onClick={() => resolveApproval('decline')}>Deny</button>
          </div>
          {approval.state === 'error' && <p className={styles.error}>Couldn’t send approval. Try again.</p>}
        </aside>
      )}

      <form className={styles.composer} onSubmit={submitMessage}>
        <textarea
          data-interaction-id={`agent-composer-${agent.id}`}
          value={agent.draft}
          disabled={agent.status === 'stopped'}
          aria-label={`Message ${agent.name}`}
          placeholder={agent.status === 'stopped' ? 'Restart this agent to continue' : 'Ask this agent to do something…'}
          rows={1}
          onChange={(event) => dispatch({ type: 'SET_AGENT_DRAFT', id: agent.id, draft: event.target.value })}
          onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); submitMessage(); } }}
        />
        <button type="submit" data-interaction-id={`agent-send-${agent.id}`} aria-label="Send message" disabled={!agent.draft.trim() || agent.status === 'stopped'}><Glyph name="send" /></button>
      </form>
    </section>
  );
}
