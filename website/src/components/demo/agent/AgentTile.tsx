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
  previewStatus?: string;
}

const providerModels: Record<string, string[]> = {
  Codex: ['GPT-6 Astra', 'GPT-5.6 Sol', 'GPT-5.6 Terra', 'GPT-5.6 Luna'],
  'Claude Code': ['Opus 5.5', 'Fable 5.1', 'Sonnet 5.5', 'Haiku 4.5'],
  Pi: ['GPT-5.6 Sol', 'GPT-5.6 Luna', 'GPT-5.6 Terra'],
};
const effortLevels = ['Low', 'Medium', 'High'];

const statusLabel: Record<AgentStatus, string> = {
  idle: 'Idle', starting: 'Starting', working: 'Working', needsAttention: 'Needs attention', stopped: 'Stopped', done: 'Done',
};

const knownStatus = (value: string | null): value is AgentStatus =>
  value === 'idle' || value === 'starting' || value === 'working' || value === 'needsAttention' || value === 'stopped' || value === 'done';

function elapsedLabel(seconds: number) {
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  if (seconds < 3600) return remainder ? `${minutes}m ${remainder}s` : `${minutes}m`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export function AgentTile({ state, dispatch, agentId, onEvent, className = '', previewStatus }: AgentTileProps) {
  const agent = state.agents[agentId];
  const approval = state.approval.agentId === agentId ? state.approval : null;
  const rootRef = useRef<HTMLElement>(null);
  const timers = useRef<number[]>([]);
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set(agent?.transcript.filter((entry) => entry.expanded).map((entry) => entry.id)));
  const [actionsOpen, setActionsOpen] = useState(false);
  const [openConfig, setOpenConfig] = useState<'provider' | 'model' | 'effort' | null>(null);
  const [observedPresentation, setObservedPresentation] = useState<{ status: AgentStatus; label: string } | null>(null);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);

  useEffect(() => () => timers.current.forEach(window.clearTimeout), []);

  // The guided scroll controller changes data-status directly so it can seek
  // without accumulating React state. Mirror that one semantic attribute back
  // into React so the native activity glyph and action state follow the story.
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const sync = () => {
      const value = root.getAttribute('data-status');
      if (knownStatus(value)) {
        const label = root.querySelector<HTMLElement>('.' + styles.stateLabel)?.textContent?.trim() || statusLabel[value];
        setObservedPresentation({ status: value, label });
      }
    };
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(root, { attributes: true, attributeFilter: ['data-status'] });
    return () => observer.disconnect();
  }, [agentId]);

  useEffect(() => setObservedPresentation(null), [agent?.status]);

  const displayedStatus = observedPresentation?.status ?? agent?.status ?? 'idle';
  const displayedLabel = observedPresentation?.label ?? previewStatus ?? statusLabel[displayedStatus];
  const active = displayedStatus === 'working' || displayedStatus === 'starting';
  useEffect(() => {
    if (!active) {
      setElapsedSeconds(0);
      return;
    }
    const startedAt = Date.now();
    const tick = () => setElapsedSeconds(Math.floor((Date.now() - startedAt) / 1000));
    tick();
    const timer = window.setInterval(tick, 1000);
    return () => window.clearInterval(timer);
  }, [active, agentId]);
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

  const activatePrimaryAction = () => {
    if (active) {
      dispatch({ type: 'STOP_AGENT', id: agent.id });
      emit({ type: 'agent-stopped', agentId: agent.id });
      return;
    }
    if (displayedStatus === 'stopped') {
      dispatch({ type: 'RESTART_AGENT', id: agent.id });
      emit({ type: 'agent-restarted', agentId: agent.id });
      return;
    }
    submitMessage();
  };

  const changeConfig = (field: 'provider' | 'model' | 'effort', value: string) => {
    dispatch({ type: 'SET_AGENT_CONFIG', id: agent.id, field, value });
    if (field === 'provider') dispatch({ type: 'SET_AGENT_CONFIG', id: agent.id, field: 'model', value: providerModels[value]?.[0] ?? 'Auto' });
    emit({ type: 'config-changed', agentId: agent.id, field, value });
    setOpenConfig(null);
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
    <section ref={rootRef} className={`${styles.tile} ${className}`} data-agent-id={agent.id} data-status={displayedStatus} aria-label={`${agent.name}, ${displayedLabel}`}>
      <header className={styles.header}>
        <div className={styles.identity}>
          <strong>{agent.name}</strong>
          <span className={styles.stateLine}>
            <i className={styles.headerStatusDot} data-status={displayedStatus} aria-hidden="true" />
            <span className={styles.stateLabel} data-status={displayedStatus}>{displayedLabel}</span>
            {active && <time className={styles.elapsed}>· {elapsedLabel(elapsedSeconds)}</time>}
          </span>
        </div>
        <div className={styles.headerDetails}>
          <span className={styles.awarenessSlot} aria-hidden="true" />
          <span className={styles.branch} title={`Working branch ${agent.branch}`}><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 13V9.5A3.5 3.5 0 0 1 7.5 6h4"/><path d="m9.5 3.5 2.5 2.5-2.5 2.5"/><circle cx="4" cy="12.5" r="1.2"/><circle cx="4" cy="3.5" r="1.2"/><path d="M4 4.7v1.8A3.5 3.5 0 0 0 7.5 10H8"/></svg><span>{agent.branch}</span></span>
        </div>
        {previewStatus === undefined && <div className={styles.actions}>
          <button type="button" data-interaction-id={`agent-actions-${agent.id}`} aria-label="Agent actions" aria-expanded={actionsOpen} onClick={() => setActionsOpen((value) => !value)}><Glyph name="more" /></button>
          {actionsOpen && (
            <div className={styles.actionMenu} role="menu">
              {displayedStatus === 'stopped' ? (
                <button type="button" role="menuitem" data-interaction-id={`agent-restart-${agent.id}`} onClick={() => { dispatch({ type: 'RESTART_AGENT', id: agent.id }); setActionsOpen(false); emit({ type: 'agent-restarted', agentId: agent.id }); }}>Restart agent</button>
              ) : (
                <button type="button" role="menuitem" data-interaction-id={`agent-stop-${agent.id}`} onClick={() => { dispatch({ type: 'STOP_AGENT', id: agent.id }); setActionsOpen(false); emit({ type: 'agent-stopped', agentId: agent.id }); }}>Stop agent</button>
              )}
              <button type="button" role="menuitem" data-interaction-id={`agent-close-${agent.id}`} onClick={() => { dispatch({ type: 'CLOSE_TILE', id: agent.tileId }); setActionsOpen(false); }}>Close tile</button>
            </div>
          )}
        </div>}
      </header>

      <div className={styles.transcript} aria-label="Agent transcript" aria-live="polite" tabIndex={0}>
        {agent.transcript.length === 0 && <p className={styles.empty} data-noninteractive="true">Ready for a prompt.</p>}
        {agent.transcript.map((entry) => {
          const toolDetails = entry.kind === 'tool' && entry.text.includes('\n');
          const expandable = entry.kind === 'output' || toolDetails;
          const open = expanded.has(entry.id);
          const toolState = displayedStatus === 'working' || displayedStatus === 'starting' || displayedStatus === 'needsAttention'
            ? '◐ In progress' : displayedStatus === 'done' ? '✓ Completed' : displayedStatus === 'stopped' ? '– Cancelled' : '○ Pending';
          return (
            <article className={styles.entry} data-kind={entry.kind} key={entry.id} hidden={previewStatus === 'Ready' && entry.kind !== 'assistant'} aria-label={entry.kind === 'user' ? 'You' : undefined} data-noninteractive={expandable ? undefined : 'true'}>
              {expandable ? (
                <button type="button" className={styles.entryToggle} data-interaction-id={`agent-transcript-${agent.id}-${entry.id}`} aria-expanded={open} onClick={() => setExpanded((current) => { const next = new Set(current); next.has(entry.id) ? next.delete(entry.id) : next.add(entry.id); return next; })}>
                  <span className={styles.entryHeader}><span className={styles.entryTitle}><Glyph name={entry.kind === 'tool' ? 'tool' : 'terminal'} /><span data-demo-tool-title={entry.kind === 'tool' ? 'true' : undefined}>{entry.kind === 'tool' ? entry.text.split('\n')[0] : 'Command output'}</span></span><span className={styles.entryTrailing}><span data-tool-state="true">{toolState}</span><Glyph name={open ? 'collapse' : 'expand'} /></span></span>
                </button>
              ) : entry.kind === 'tool' ? (
                <div className={styles.entryHeader} data-noninteractive="true"><span className={styles.entryTitle}><Glyph name="tool" /><span data-demo-tool-title="true">{entry.text}</span></span><span className={styles.toolStatus} data-tool-state="true">{toolState}</span></div>
              ) : null}
              {(!expandable || open) && entry.kind === 'output' && <pre>{entry.text}</pre>}
              {toolDetails && open && <p>{entry.text.split('\n').slice(1).join('\n')}</p>}
              {(!expandable || open) && entry.kind !== 'tool' && entry.kind !== 'output' && <p>{entry.text}</p>}
            </article>
          );
        })}
        <div className={styles.thinking} data-status={displayedStatus} data-noninteractive="true"><AgentGyro active={active} /><span data-demo-agent-label="true">{agent.summary}</span></div>
        {approval && approval.state !== 'accepted' && approval.state !== 'declined' && (
          <aside className={styles.approval} aria-label="Pending approval" aria-live="polite">
            <div className={styles.approvalHeading} data-noninteractive="true"><strong>Approval requested</strong><span data-approval-state={approval.state} data-demo-approval-status="true">{approval.state === 'resolving' ? '→ Sending' : approval.state === 'error' ? '! Not sent' : '◷ Pending'}</span></div>
            <p className={styles.approvalPrompt} data-noninteractive="true">{approval.detail}</p>
            <div className={styles.approvalActions}>
              <button type="button" data-interaction-id="approval-approve" disabled={approval.state === 'resolving'} onClick={() => resolveApproval('accept')}>{approval.state === 'resolving' ? 'Sending…' : approval.state === 'error' ? 'Retry approval' : 'Approve'}</button>
              <button type="button" data-interaction-id="approval-deny" disabled={approval.state === 'resolving'} onClick={() => resolveApproval('decline')}>Deny</button>
            </div>
          </aside>
        )}
      </div>

      <div className={styles.statusBar}>
        <span className={styles.location} title="Project root · Array"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m2.1 7 5.9-4.6L13.9 7v6.1a.8.8 0 0 1-.8.8H2.9a.8.8 0 0 1-.8-.8Z"/><path d="M6.2 13.8V9.1h3.6v4.7"/></svg><span>Array</span></span>
        <span className={`${styles.activity} ${styles[`activity_${displayedStatus}`]}`} data-status={displayedStatus}>
          <span className={styles.statusIcons} aria-hidden="true">
            <span data-status-icon="working"><svg viewBox="0 0 16 16"><path d="M3 3.5h10v7H7l-3.5 2v-2H3Z" /><circle cx="6" cy="7" r=".5" /><circle cx="8" cy="7" r=".5" /><circle cx="10" cy="7" r=".5" /></svg></span>
            <span data-status-icon="starting">▶</span>
            <span data-status-icon="needsAttention">◆</span>
            <span data-status-icon="done"><Glyph name="check" /></span>
            <span data-status-icon="stopped">■</span>
          </span>
          <span data-demo-agent-label="true">{displayedLabel}{active ? ` · ${elapsedLabel(elapsedSeconds)}` : ''}</span>
        </span>
        <span className={styles.context} aria-label="Context window usage unknown">
          <span className={styles.contextRing} data-demo-context-ring="true" role="img" aria-label="Context usage unknown"><svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8.9"/><text x="10" y="13">?</text></svg></span>
          <span>unknown</span>
        </span>
      </div>

      <form className={styles.composer} onSubmit={submitMessage}>
        <textarea
          data-interaction-id={`agent-composer-${agent.id}`}
          value={agent.draft}
          disabled={displayedStatus === 'stopped'}
          aria-label={`Message ${agent.name}`}
          placeholder={displayedStatus === 'stopped' ? 'Restart this agent to continue' : 'Send a prompt to the agent…'}
          rows={1}
          onChange={(event) => dispatch({ type: 'SET_AGENT_DRAFT', id: agent.id, draft: event.target.value })}
          onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); submitMessage(); } }}
        />
      </form>

      <div className={styles.config} aria-label="Next turn settings">
        <div className={styles.configControl}>
          <button type="button" className={styles.configTrigger} aria-label="Provider" aria-haspopup="listbox" aria-expanded={openConfig === 'provider'} data-interaction-id={`agent-provider-${agent.id}`} onClick={() => setOpenConfig(openConfig === 'provider' ? null : 'provider')}><ProviderMark provider={agent.provider} /><span>{agent.provider}</span><Glyph name="chevronDown" /></button>
          <div className={`${styles.configMenu} ${styles.providerMenu}`} role="listbox" aria-label="Choose provider" data-demo-menu="provider" hidden={openConfig !== 'provider'} aria-hidden={openConfig !== 'provider'}>{Object.keys(providerModels).map((provider) => <button type="button" role="option" aria-selected={agent.provider === provider} data-selected={agent.provider === provider ? 'true' : undefined} data-demo-provider-option={provider} key={provider} onClick={() => changeConfig('provider', provider)}><ProviderMark provider={provider} /><span>{provider}</span>{agent.provider === provider && <Glyph name="check" />}</button>)}</div>
        </div>
        <div className={styles.configControl}>
          <button type="button" className={styles.configTrigger} aria-label="Model" aria-haspopup="listbox" aria-expanded={openConfig === 'model'} data-interaction-id={`agent-model-${agent.id}`} onClick={() => setOpenConfig(openConfig === 'model' ? null : 'model')}><span>{agent.model}</span><Glyph name="chevronDown" /></button>
          {openConfig === 'model' && <div className={styles.configMenu} role="listbox" aria-label="Choose model">{(models.includes(agent.model) ? models : [agent.model, ...models]).map((model) => <button type="button" role="option" aria-selected={agent.model === model} key={model} onClick={() => changeConfig('model', model)}><span>{model}</span>{agent.model === model && <Glyph name="check" />}</button>)}</div>}
        </div>
        <div className={styles.configControl}>
          <button type="button" className={styles.configTrigger} aria-label="Reasoning effort" aria-haspopup="listbox" aria-expanded={openConfig === 'effort'} data-interaction-id={`agent-effort-${agent.id}`} onClick={() => setOpenConfig(openConfig === 'effort' ? null : 'effort')}><span>{agent.effort}</span><Glyph name="chevronDown" /></button>
          {openConfig === 'effort' && <div className={styles.configMenu} role="listbox" aria-label="Choose reasoning effort">{effortLevels.map((effort) => <button type="button" role="option" aria-selected={agent.effort === effort} key={effort} onClick={() => changeConfig('effort', effort)}><span>{effort}</span>{agent.effort === effort && <Glyph name="check" />}</button>)}</div>}
        </div>
        <button type="button" className={styles.primaryAction} data-interaction-id={`agent-send-${agent.id}`} data-demo-agent-action="true" data-action={active ? 'stop' : displayedStatus === 'stopped' ? 'restart' : 'send'} aria-label={active ? 'Stop current turn' : displayedStatus === 'stopped' ? 'Restart agent' : 'Send message'} disabled={!active && displayedStatus !== 'stopped' && !agent.draft.trim()} onClick={activatePrimaryAction}>
          <span className={styles.actionIcons} aria-hidden="true">
            <span data-demo-agent-action-icon="send"><Glyph name="send" /></span>
            <span data-demo-agent-action-icon="stop"><Glyph name="close" /></span>
            <span data-demo-agent-action-icon="restart"><Glyph name="agent" /></span>
          </span>
          <span data-demo-agent-action-label="true">{active ? 'Stop' : displayedStatus === 'stopped' ? 'Restart' : 'Send'}</span>
        </button>
      </div>
    </section>
  );
}
