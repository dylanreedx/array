import type { Dispatch } from 'react';
import type { DemoAction, DemoState } from '../../features/demo/types';
import { makeInitialState } from '../../features/demo/fixture';
import { AgentTile } from './agent';
import { Glyph } from './Glyph';
import { ProviderMark } from './ProviderMark';
import islandStyles from './DemoIsland.module.css';
import { NativeBoardTile, NativeBoardDetails, NativeBoardChrome } from './board/NativeBoardTile';
import { NativeEditorTile, NativeEditorChrome } from './editor/NativeEditorTile';
import { GuidedTerminal } from './tools/GuidedTerminal';
import { CanvasToolbar } from './toolbar/CanvasToolbar';
import styles from './GuidedWorkspace.module.css';

const worldTiles = [
  { id: 'stabilize', kind: 'agent', title: 'Stabilize zone placement', x: 70, y: 90, width: 430, height: 550 },
  { id: 'verify', kind: 'agent', title: 'Verify approval handoff', x: 550, y: 90, width: 380, height: 470 },
  { id: 'audit', kind: 'agent', title: 'Audit native tokens', x: 980, y: 90, width: 340, height: 450 },
  { id: 'browser', kind: 'editor', title: 'Editor · CanvasNSView.swift', x: 920, y: 680, width: 560, height: 430 },
  { id: 'shell', kind: 'shell', title: 'Array build', x: 1370, y: 90, width: 300, height: 470 },
  { id: 'note', kind: 'board', title: 'Canvas polish', x: 70, y: 680, width: 800, height: 430 },
] as const;

const agentOrder = ['stabilize', 'verify', 'audit'] as const;
const noOpDispatch: Dispatch<DemoAction> = () => undefined;

export default function GuidedWorkspace() {
  const fixture = makeInitialState();
  const releaseNote = '# Array 0.7.26 release checklist\n\n- Verify zone placement\n- Approve placement review\n- Run Safari motion pass';
  const stateAgents: DemoState['agents'] = {
    ...fixture.agents,
    verify: {
      ...fixture.agents.verify,
      branch: 'agent/placement-review',
      summary: 'Review requested tile positions before approval',
      transcript: [
        { id: 'v1', kind: 'user' as const, text: 'Review the updated tile positions in the Array zone.' },
        { id: 'v2', kind: 'assistant' as const, text: 'The zone placement is ready for approval.' },
      ],
    },
  };
  for (const id of agentOrder) {
    stateAgents[id] = {
      ...stateAgents[id],
      provider: id === 'verify' ? 'Claude Code' : 'Codex',
      model: id === 'verify' ? 'Opus 5.5' : 'GPT-5.6 Sol', status: 'idle', summary: 'Ready for a task.',
      transcript: (stateAgents[id].transcript.some(entry => entry.kind === 'user') ? stateAgents[id].transcript : [{ id: `${id}-prompt`, kind: 'user' as const, text: '' }, ...stateAgents[id].transcript]).map(entry => ({ ...entry, text:
        entry.kind === 'user' ? 'Waiting for a task.' :
        entry.kind === 'assistant' ? `Ready. Type a prompt below to run ${id === 'verify' ? 'Opus 5.5' : 'GPT-5.6 Sol'} in this tile.` :
        entry.kind === 'tool' ? 'Tools appear here as the agent works.' : entry.text })),
    };
  }
  const state: DemoState = {
    ...fixture,
    agents: stateAgents,
    approval: {
      ...fixture.approval,
      id: 'approval-placement',
      title: 'Approval requested',
      detail: 'Run the canvas checks?\nswift test · CanvasSceneEditTests',
    },
    note: { ...fixture.note, committed: releaseNote, draft: releaseNote },
  };

  const renderContent = (tileId: typeof worldTiles[number]['id']) => {
    if (tileId === 'stabilize' || tileId === 'verify' || tileId === 'audit') {
      return (
        <div
          className={styles.agentMount}
          data-demo-transcript={tileId}
          data-demo-status={tileId}
          data-demo-typing={tileId}
          data-demo-tool={tileId === 'stabilize' ? tileId : undefined}
          data-demo-approval={tileId === 'verify' ? tileId : undefined}
        >
          <AgentTile state={state} dispatch={noOpDispatch} agentId={tileId} previewStatus="Ready" availableProviders={['Codex', 'Claude Code']} />
        </div>
      );
    }
    if (tileId === 'browser') return <NativeEditorTile />;
    if (tileId === 'shell') return <GuidedTerminal />;
    return <NativeBoardTile />;
  };

  return (
    <section className={styles.scene} aria-label="Illustrative Array workspace" data-guided-scene data-assembly-pin>
      <div className={`${styles.stage} ${islandStyles.stage}`} data-assembly-stage aria-hidden="true" inert>
        <div className={styles.window} data-guided-window data-demo-viewport data-mac-workspace>
          <div className={styles.deviceChrome} data-demo-device-chrome aria-hidden="true">
            <span data-demo-window-control="close" />
            <span data-demo-window-control="minimize" />
            <span data-demo-window-control="maximize" />
            <span data-demo-window-notch />
          </div>
          <header className={styles.topbar} data-assembly-chrome="topbar">
            <span className={styles.brandMark} aria-hidden="true"><img src="/array-mark.svg" alt="" /></span>
            <strong className={styles.workspaceName}>Array</strong>
            <span className={styles.workspaceMeta}>1 project · 1 zone</span><span className={styles.workspaceMeta}>Saved</span>
            <span className={styles.topbarSpacer} />
            <button className={styles.commandButton} type="button" data-demo-menu-trigger="toolbar">
              Add or jump… <kbd>⌘K</kbd>
            </button>
            <button className={styles.iconButton} type="button" aria-label="Toggle sidebar"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4h11M2.5 8h11M2.5 12h11" /></svg></button>
            <button className={styles.workspacePicker} type="button" aria-label="Current workspace">
              Array <Glyph name="chevronDown" />
            </button>
          </header>

          <div className={styles.body} data-assembly-chrome="body">
            <aside className={styles.sidebar} data-demo-sidebar data-assembly-chrome="sidebar" aria-label="Agents">
              <div className={styles.sidebarHeader}>
                <h2>Agents</h2>
                <span data-demo-agent-count>2</span>
              </div>
              <div className={styles.searchBox}><svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.2" /><path d="m10.2 10.2 3.1 3.1" /></svg><span>Search agents</span><kbd>⌘F</kbd></div>
              <div className={styles.scopeRow}><span>All agents</span><Glyph name="chevronDown" /></div>
              <div className={styles.agentList} role="list">
                {agentOrder.map((id) => {
                  const agent = state.agents[id];
                  return (
                    <div className={styles.agentRow} data-demo-agent-row={id} data-demo-selected="false" data-demo-main-row={id === 'stabilize' ? '' : undefined} hidden={id === 'stabilize'} role="listitem" key={id}>
                      <div className={styles.agentRowTop}>
                        <ProviderMark provider={agent.provider} />
                        <span>Array</span>
                        <span className={styles.recency}>{id === 'stabilize' ? 'now' : id === 'verify' ? '2m' : '5m'}</span>
                      </div>
                      <strong>{agent.name}</strong>
                      <span className={styles.agentBranch}>{agent.branch}</span>
                      <span className={`${styles.agentState} ${styles[`state_${agent.status}`]}`} data-demo-statusmirror={id}>
                        <i aria-hidden="true" />Ready
                      </span>
                    </div>
                  );
                })}
              </div>
              <div className={styles.sidebarFooter}>⌘K <span>Quick Jump</span></div>
            </aside>

            <div className={styles.canvasShell} data-assembly-chrome="canvas-shell" role="region" aria-label="Workspace canvas">
              <div className={styles.canvas} data-demo-canvas data-assembly-chrome="canvas">
                <CanvasToolbar />
                <div className={styles.world} data-guided-world data-assembly-chrome="world">
                  <section className={styles.zone} data-assembly-chrome="zone-runtime" aria-label="Array project zone">
                    <header className={styles.zoneHeader}>
                      <span className={styles.zoneDot} />
                      <strong>Array</strong>
                      <span className={styles.zonePath}><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m2 7 6-5 6 5M4 6v7h3V9h2v4h3V6" /></svg>Array / Project Root</span>
                      <span className={styles.zoneMeta} data-demo-zone-rollup />
                      <Glyph name="more" /><Glyph name="close" />
                    </header>
                  </section>
                  {worldTiles.map((tile) => (
                      <article
                        key={tile.id}
                        className={styles.tile}
                        data-assembly-surface={tile.id}
                        data-tile-kind={tile.kind}
                        data-demo-visible={tile.id === 'stabilize' || tile.id === 'shell' ? 'false' : 'true'}
                        data-demo-created={tile.id === 'stabilize' || tile.id === 'shell' ? 'false' : 'true'}
                        aria-label={`${tile.title}, ${tile.kind} tile`}
                        style={{ left: tile.x, top: tile.y, width: tile.id === 'browser' ? 'var(--demo-editor-initial-width, 560px)' : tile.width, height: tile.height }}
                      >
                        <header className={styles.tileHeader} data-demo-drag-handle={tile.id}>
                          <span className={styles.tileGlyph} aria-hidden="true">
                            {tile.kind === 'agent' ? <ProviderMark provider={state.agents[tile.id as typeof agentOrder[number]].provider} /> : <Glyph name={tile.kind === 'editor' ? 'code' : tile.kind === 'shell' ? 'terminal' : 'board'} />}
                          </span>
                          <span className={styles.tileTitle} data-demo-tile-title={tile.id} data-demo-editor-tab={tile.kind === 'editor' ? '' : undefined}>{tile.title}</span>
                          <span className={styles.tileHeaderSpacer} />
                          {tile.kind === 'editor' && <NativeEditorChrome />}
                          {tile.kind === 'board' && <NativeBoardChrome />}
                          {tile.kind === 'agent' && <span className={styles.outerStatus} data-demo-outer-state={tile.id} data-status="idle"><i /><span>Idle</span></span>}
                          <button type="button" className={styles.tileMenu} aria-label={`Actions for ${tile.title}`}><Glyph name="more" /></button>
                          <button type="button" className={styles.tileMenu} aria-label={`Close ${tile.title}`}><Glyph name="close" /></button>
                        </header>
                        <div className={styles.tileBody}>
                          {renderContent(tile.id)}

                        </div>
                        <span
                          className={styles.resizeHandle}
                          data-demo-resize-handle={tile.id}
                          data-demo-target={tile.id === 'stabilize' ? 'stabilize-resize' : tile.id === 'shell' ? 'shell-resize' : undefined}
                          aria-hidden="true"
                        />
                      </article>
                  ))}
                </div>


                <svg className={styles.focusOutline} data-demo-focus-outline style={{ display: 'none' }} aria-hidden="true"><rect data-demo-focus-path fill="none" rx="14" /></svg>
                <div className={styles.snapPreview} data-demo-snap-preview hidden />
                <div className={styles.resizeReadout} data-demo-resize-readout hidden />
                <div className={styles.keyHud} data-demo-key-hud hidden aria-hidden="true"><kbd>⌘</kbd><kbd>K</kbd></div>
                <div className={styles.commandMenu} data-demo-menu="toolbar" hidden aria-hidden="true">
                  <div className={styles.commandSearch}><svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.2" /><path d="m10.2 10.2 3.1 3.1" /></svg><span data-demo-command-query>Agent</span><kbd>esc</kbd></div>
                  <div data-demo-command-root>
                    <p className={styles.commandSection}>CREATE</p>
                    <div className={styles.commandOption} data-demo-command-agent data-selected="true"><Glyph name="agent" /><span><strong>Agent</strong><small>Start a focused coding session · Array / Project Root</small></span><Glyph name="forward" /></div>
                  </div>
                  <div data-demo-command-models hidden>
                    <p className={styles.commandSection}>QUICK START</p>
                    <div className={styles.commandOption} data-demo-command-model data-selected="true"><ProviderMark provider="Codex" /><span><strong>Default — GPT-5.6 Sol</strong><small>Configured in Settings · openai-codex/gpt-5.6-sol</small></span></div>
                    <p className={styles.commandSection}>OPENAI CODEX</p>
                    <div className={styles.commandOption}><ProviderMark provider="Codex" /><span><strong>GPT-5.6 Sol</strong><small>OpenAI Codex · openai-codex/gpt-5.6-sol</small></span></div>
                    <p className={styles.commandSection}>ANTHROPIC</p>
                    <div className={styles.commandOption}><ProviderMark provider="Claude Code" /><span><strong>Opus 5.5</strong><small>Anthropic · claude-opus-5-5</small></span></div>
                  </div>
                  <div className={styles.commandFooter}>Type to search · ↑↓ Select · Return Open · Esc Close</div>
                </div>
              </div>
              <footer className={styles.canvasRail} data-assembly-chrome="status">
                <span><kbd>⌘K</kbd> Add</span><span><kbd>⌥</kbd> Quick Jump</span><span><kbd>^Space</kbd> Navigate</span><span className={styles.railSpacer} /><span>Settings <Glyph name="settings" /></span>
              </footer>
            </div>
          </div>
          <NativeBoardDetails />
        </div>
        <div className={styles.scriptedCursor} data-demo-cursor aria-hidden="true">
          <Glyph name="cursor" />
          <svg viewBox="0 0 20 20" data-demo-cursor-resize><path d="M2 2h7L6.8 4.2l9 9L18 11v7h-7l2.2-2.2-9-9L2 9Z" /></svg>
          <span data-demo-cursor-press />
        </div>
      </div>
      <p className={styles.caption} data-demo-caption aria-live="polite">Your work lands together, in one workspace.</p>
    </section>
  );
}
