import { useState } from 'react';
import type { Dispatch } from 'react';
import type { Agent, DemoAction, DemoState } from '../../../features/demo/types';
import { AgentDetail } from './AgentDetail';
import { AgentList } from './AgentList';
import { Approvals } from './Approvals';
import { CompanionCanvas } from './CompanionCanvas';
import { CompanionTabs } from './CompanionTabs';
import { Settings } from './Settings';
import styles from './companion.module.css';

export interface CompanionProps {
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
  className?: string;
  pairedMacName?: string;
  freshnessLabel?: string;
  onResolveApproval?: (decision: 'accept' | 'decline') => void | Promise<void>;
}

export function Companion({
  state,
  dispatch,
  className = '',
  pairedMacName = 'Dylan’s Mac',
  freshnessLabel = 'updated now',
  onResolveApproval
}: CompanionProps) {
  const [focusTileId, setFocusTileId] = useState<string | null>(null);
  const activeAgent = state.companionAgentId ? state.agents[state.companionAgentId] : null;
  const agents = Object.values(state.agents);
  const pendingApprovals = state.approval.state === 'pending' || state.approval.state === 'resolving' || state.approval.state === 'error' ? 1 : 0;
  const title = state.companionTab === 'agents' ? 'Agents' : state.companionTab === 'canvas' ? 'Canvas' : state.companionTab === 'approvals' ? 'Approvals' : 'Settings';

  const setTab = (tab: DemoState['companionTab']) => dispatch({ type: 'SET_COMPANION_TAB', tab });
  const openAgent = (agentId: string) => {
    dispatch({ type: 'OPEN_COMPANION_AGENT', agentId });
  };
  const showOnCanvas = (agent: Agent) => {
    setFocusTileId(agent.tileId);
    dispatch({ type: 'SET_COMPANION_TAB', tab: 'canvas' });
  };
  const resolveApproval = async (decision: 'accept' | 'decline') => {
    if (state.approval.state === 'resolving') return;
    dispatch({ type: 'RESOLVE_APPROVAL', decision, phase: 'start' });
    try {
      await onResolveApproval?.(decision);
      dispatch({ type: 'RESOLVE_APPROVAL', decision, phase: 'complete' });
    } catch {
      dispatch({ type: 'RESOLVE_APPROVAL', decision, phase: 'error' });
    }
  };

  return (
    <section className={`${styles.phone} ${className}`} aria-label="Array Companion" data-testid="companion">
      <div className={styles.hardwareTop} aria-hidden="true">
        <span>9:41</span><i></i>
        <svg className={styles.hardwareStatus} viewBox="0 0 54 13"><path d="M1 11h3V8H1zm5 0h3V6H6zm5 0h3V4h-3zm5 0h3V2h-3"/><path d="M25 5.5c4-4 10-4 14 0M28 8.5c2.3-2.2 5.7-2.2 8 0M32 11h.1"/><rect x="42" y="2" width="10" height="8" rx="2"/><path d="M53 5v2"/><rect x="44" y="4" width="6" height="4" rx="1"/></svg>
      </div>
      {!activeAgent && <header className={styles.nativeNav}>
        <strong>{title}</strong>
        <span className={styles.liveStatus}><i aria-hidden="true"></i> Live</span>
      </header>}
      <div className={`${styles.content} ${activeAgent ? styles.contentDetail : ''}`}>
        <section id="companion-panel-agents" role="tabpanel" aria-labelledby="companion-tab-agents" hidden={state.companionTab !== 'agents'} data-testid="companion-screen-agents">
          {activeAgent
            ? <AgentDetail agent={activeAgent} onBack={() => dispatch({ type: 'OPEN_COMPANION_AGENT', agentId: null })} onShowOnCanvas={showOnCanvas} />
            : <AgentList agents={agents} selectedId={state.selectedEntityId} onOpen={openAgent} />}
        </section>
        <section id="companion-panel-canvas" role="tabpanel" aria-labelledby="companion-tab-canvas" hidden={state.companionTab !== 'canvas'} data-testid="companion-screen-canvas">
          <CompanionCanvas state={state} dispatch={dispatch} focusTileId={focusTileId} />
        </section>
        <section id="companion-panel-approvals" role="tabpanel" aria-labelledby="companion-tab-approvals" hidden={state.companionTab !== 'approvals'} data-testid="companion-screen-approvals">
          <Approvals approval={state.approval} onResolve={resolveApproval} />
        </section>
        <section id="companion-panel-settings" role="tabpanel" aria-labelledby="companion-tab-settings" hidden={state.companionTab !== 'settings'} data-testid="companion-screen-settings">
          <Settings pairedMacName={pairedMacName} freshnessLabel={freshnessLabel} />
        </section>
      </div>
      <CompanionTabs active={state.companionTab} pendingApprovals={pendingApprovals} onChange={setTab} />
      {!activeAgent && state.companionTab !== 'settings' && <div className={styles.freshnessFooter}><i aria-hidden="true"></i><span>Live from {pairedMacName}</span><time>{freshnessLabel}</time></div>}
      <div className={styles.homeIndicator} aria-hidden="true"><i></i></div>
    </section>
  );
}

export default Companion;
