import type { Dispatch } from 'react';
import type { DemoAction, DemoState } from '../../features/demo/types';
import { makeInitialState } from '../../features/demo/fixture';
import { AgentTile } from './agent';
import { Glyph } from './Glyph';
import { ProviderMark } from './ProviderMark';
import islandStyles from './DemoIsland.module.css';
import { BrowserTile } from './tools/BrowserTile';
import { NoteTile } from './tools/NoteTile';
import { ShellTile } from './tools/ShellTile';
import styles from './GuidedWorkspace.module.css';

const worldTiles = [
  { id: 'stabilize', kind: 'agent', title: 'Stabilize zone placement', x: 80, y: 90, width: 340, height: 390 },
  { id: 'verify', kind: 'agent', title: 'Verify approval handoff', x: 450, y: 90, width: 340, height: 390 },
  { id: 'audit', kind: 'agent', title: 'Audit native tokens', x: 820, y: 90, width: 340, height: 390 },
  { id: 'browser', kind: 'browser', title: 'Canvas interaction spec', x: 450, y: 510, width: 340, height: 220 },
  { id: 'shell', kind: 'shell', title: 'Array build', x: 820, y: 510, width: 340, height: 220 },
  { id: 'note', kind: 'note', title: '0.7.26 release checklist', x: 80, y: 510, width: 340, height: 220 },
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
      ...stateAgents[id], status: 'idle', summary: 'Ready for a task.',
      transcript: stateAgents[id].transcript.map(entry => ({ ...entry, text:
        entry.kind === 'user' ? 'Waiting for a task.' :
        entry.kind === 'assistant' ? 'Ready when you are.' :
        entry.kind === 'tool' ? 'Tools appear here as the agent works.' : entry.text })),
    };
  }
  const state: DemoState = {
    ...fixture,
    agents: stateAgents,
    approval: {
      ...fixture.approval,
      id: 'approval-placement',
      title: 'Run the canvas checks?',
      detail: 'swift test · CanvasSceneEditTests',
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
          <AgentTile state={state} dispatch={noOpDispatch} agentId={tileId} previewStatus="Ready" />
        </div>
      );
    }
    if (tileId === 'browser') return <BrowserTile state={state} dispatch={noOpDispatch} previewPage={{ title: 'Canvas interaction spec', copy: 'World frames stay aligned while zones move and the canvas zooms.', links: [] }} />;
    if (tileId === 'shell') return <ShellTile state={state} dispatch={noOpDispatch} nextOperation={() => 1} />;
    return <NoteTile state={state} dispatch={noOpDispatch} title="Placement checklist" checklist={['Verify zone placement', 'Review the tile positions', 'Run the canvas checks']} />;
  };

  return (
    <section className={styles.scene} aria-label="Illustrative Array workspace" data-guided-scene data-assembly-pin>
      <div className={`${styles.stage} ${islandStyles.stage}`} data-assembly-stage aria-hidden="true" inert>
        <div className={styles.window} data-guided-window data-mac-workspace>
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
            <aside className={styles.sidebar} data-assembly-chrome="sidebar" aria-label="Agents">
              <div className={styles.sidebarHeader}>
                <h2>Agents</h2>
                <span>3</span>
              </div>
              <div className={styles.searchBox}><svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.2" /><path d="m10.2 10.2 3.1 3.1" /></svg><span>Search agents</span><kbd>⌘F</kbd></div>
              <div className={styles.scopeRow}><span>All agents</span><Glyph name="chevronDown" /></div>
              <div className={styles.agentList} role="list">
                {agentOrder.map((id) => {
                  const agent = state.agents[id];
                  return (
                    <div className={`${styles.agentRow} ${id === 'stabilize' ? styles.agentRowSelected : ''}`} role="listitem" key={id}>
                      <div className={styles.agentRowTop}>
                        <ProviderMark provider={agent.provider} />
                        <span>Array</span>
                        <span className={styles.recency}>{id === 'stabilize' ? 'now' : id === 'verify' ? '2m' : '5m'}</span>
                      </div>
                      <strong>{agent.name}</strong>
                      <span className={styles.agentBranch}>{agent.branch}</span>
                      <span className={`${styles.agentState} ${styles[`state_${agent.status}`]}`} data-demo-statusmirror={id}>
                        <i aria-hidden="true" />{agent.status === 'needsAttention' ? 'Needs attention' : agent.status === 'done' ? 'Done' : 'Working'}
                      </span>
                    </div>
                  );
                })}
              </div>
              <div className={styles.sidebarFooter}>⌘K <span>Quick Jump</span></div>
            </aside>

            <div className={styles.canvasShell} data-assembly-chrome="canvas-shell" role="region" aria-label="Workspace canvas">
              <div className={styles.canvas} data-assembly-chrome="canvas">
                <div className={styles.world} data-guided-world data-assembly-chrome="world">
                  <section className={styles.zone} data-assembly-chrome="zone-runtime" aria-label="Array project zone">
                    <header className={styles.zoneHeader}>
                      <span className={styles.zoneDot} />
                      <strong>Array</strong>
                      <span className={styles.zonePath}>Project Root</span>
                      <span className={styles.zoneMeta}>3 agents · 6 tiles</span>
                      <Glyph name="more" />
                    </header>
                  </section>
                  {worldTiles.map((tile) => (
                      <article
                        key={tile.id}
                        className={styles.tile}
                        data-assembly-surface={tile.id}
                        data-tile-kind={tile.kind}
                        aria-label={`${tile.title}, ${tile.kind} tile`}
                        style={{ left: tile.x, top: tile.y, width: tile.width, height: tile.height }}
                      >
                        <header className={styles.tileHeader}>
                          <span className={styles.tileGlyph} aria-hidden="true">
                            <Glyph name={tile.kind === 'agent' ? 'agent' : tile.kind === 'browser' ? 'browser' : tile.kind === 'shell' ? 'terminal' : 'note'} />
                          </span>
                          <span className={styles.tileTitle}>{tile.title}</span>
                          <span className={styles.tileHeaderSpacer} />
                          <button type="button" className={styles.tileMenu} aria-label={`Actions for ${tile.title}`}><Glyph name="more" /></button>
                        </header>
                        <div className={styles.tileBody}>
                          {renderContent(tile.id)}
                          {tile.id === 'verify' && (
                            <div className={styles.providerMenu} data-demo-menu="provider" hidden aria-hidden="true">
                              <span>Choose a provider</span>
                              {['Codex', 'Claude Code', 'Pi'].map((provider) => (
                                <div className={styles.providerOption} key={provider} data-selected={provider === 'Claude Code' || undefined}>
                                  <ProviderMark provider={provider} />
                                  <strong>{provider}</strong>
                                  {provider === 'Claude Code' && <Glyph name="check" />}
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      </article>
                  ))}
                </div>

                <div className={styles.commandMenu} data-demo-menu="toolbar" hidden aria-hidden="true">
                  <div className={styles.commandSearch}><Glyph name="command" /><span>Search or create…</span><kbd>esc</kbd></div>
                  <p>CREATE</p>
                  <div className={styles.commandOption} data-demo-command-agent><Glyph name="agent" /><span><strong>Agent</strong><small>Start a focused coding session</small></span></div>
                  <div className={styles.commandOption}><Glyph name="terminal" /><span><strong>Terminal</strong><small>Open a local shell tile</small></span></div>
                </div>
              </div>
              <footer className={styles.canvasRail} data-assembly-chrome="status">
                <span><kbd>⌘K</kbd> Add</span><span><kbd>⌥</kbd> Quick Jump</span><span><kbd>^Space</kbd> Navigate</span><span className={styles.railSpacer} /><span>Settings <Glyph name="settings" /></span>
              </footer>
            </div>
          </div>
        </div>
        <div className={styles.scriptedCursor} data-demo-cursor aria-hidden="true">
          <Glyph name="cursor" />
          <span data-demo-cursor-press />
        </div>
      </div>
      <p className={styles.caption} data-demo-caption aria-live="polite">Your work lands together, in one workspace.</p>
    </section>
  );
}
