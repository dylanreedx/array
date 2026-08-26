import { useCallback, useEffect, useReducer, useRef, useState } from 'react';
import { AgentTile } from './agent';
import { CommandCenter } from './command';
import { Companion } from './companion';
import MacWorkspace, { type MacTileRenderContext } from './mac/MacWorkspace';
import { BrowserTile } from './tools/BrowserTile';
import { NoteTile } from './tools/NoteTile';
import { ShellTile } from './tools/ShellTile';
import { Glyph } from './Glyph';
import { makeInitialState } from '../../features/demo/fixture';
import { demoReducer } from '../../features/demo/reducer';
import type { DeviceFocus } from '../../features/demo/types';
import styles from './DemoIsland.module.css';

type AssemblyPhase = 'glimpse' | 'opening' | 'assembly' | 'mac' | 'companion' | 'ready';

function ReadyCue({ onEnter, onContinue }: { onEnter: () => void; onContinue: () => void }) {
  return (
    <div className={`${styles.readyCue} ${styles.portalReadyCue}`} data-testid="interaction-ready-cue" role="region" aria-label="Live workspace ready">
      <svg className={styles.readyCueBorder} focusable="false">
        <rect className={styles.readyCueImpact} />
        <rect className={styles.readyCueMarch} />
      </svg>
      <span className={styles.readyCueScrim} aria-hidden="true" />
      <div className={styles.readyCueLabel}>
        <span className={styles.readyCuePointer} aria-hidden="true"><Glyph name="cursor" /><i /></span>
        <strong>Take control.</strong>
        <p>Move a tile. Tidy the canvas. Open Command Center. Approve work from Companion.</p>
        <div className={styles.readyCueActions}>
          <button type="button" data-interaction-id="ready-enter" onClick={onEnter}>Use the workspace</button>
          <button type="button" data-interaction-id="ready-continue" onClick={onContinue}>Keep scrolling</button>
        </div>
      </div>
    </div>
  );
}

export default function DemoIsland() {
  const [state, dispatch] = useReducer(demoReducer, undefined, makeInitialState);
  const [phase, setPhase] = useState<AssemblyPhase>('glimpse');
  const [cueDismissed, setCueDismissed] = useState(false);
  const rootRef = useRef<HTMLElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const returnFocusRef = useRef<DeviceFocus>('mac');
  const operation = useRef(0);

  const nextOperation = useCallback(() => ++operation.current, []);
  const renderTile = useCallback(({ tile, state: current, dispatch: send }: MacTileRenderContext) => {
    if (tile.kind === 'agent') {
      const agent = Object.values(current.agents).find((item) => item.tileId === tile.id);
      return agent ? <AgentTile state={current} dispatch={send} agentId={agent.id} /> : null;
    }
    if (tile.kind === 'browser') return <BrowserTile state={current} dispatch={send} />;
    if (tile.kind === 'shell') return <ShellTile state={current} dispatch={send} nextOperation={nextOperation} />;
    if (tile.kind === 'note') return <NoteTile state={current} dispatch={send} />;
    return null;
  }, [nextOperation]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const assemblyRoot = root.closest<HTMLElement>('[data-assembly-root]');
    if (!assemblyRoot) return;
    const initial = assemblyRoot.dataset.assemblyPhase as AssemblyPhase | undefined;
    if (initial) setPhase(initial);
    const onAssembly = (event: Event) => {
      const next = (event as CustomEvent<{ phase?: AssemblyPhase }>).detail?.phase
        ?? (assemblyRoot.dataset.assemblyPhase as AssemblyPhase | undefined)
        ?? 'glimpse';
      setPhase(next);
      if (next !== 'ready') dispatch({ type: 'SET_INPUT_MODE', mode: 'page' });
    };
    assemblyRoot.addEventListener('array:assembly', onAssembly);
    return () => assemblyRoot.removeEventListener('array:assembly', onAssembly);
  }, []);

  useEffect(() => {
    if (matchMedia('(max-width: 800px)').matches) dispatch({ type: 'SET_DEVICE_FOCUS', focus: 'companion' });
  }, []);

  useEffect(() => {
    if (state.inputMode !== 'workspace') return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || state.commandOpen) return;
      dispatch({ type: 'SET_INPUT_MODE', mode: 'page' });
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const id = returnFocusRef.current === 'companion' ? 'device-focus-companion' : 'explore-workspace';
        rootRef.current?.querySelector<HTMLButtonElement>(`[data-interaction-id="${id}"]`)?.focus();
      }));
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [state.commandOpen, state.inputMode]);

  const enterWorkspace = (focus: DeviceFocus) => {
    rootRef.current?.closest<HTMLElement>('[data-assembly-root]')?.dispatchEvent(new CustomEvent('array:release-ready-gate'));
    returnFocusRef.current = focus;
    dispatch({ type: 'SET_DEVICE_FOCUS', focus });
    dispatch({ type: 'SET_INPUT_MODE', mode: 'workspace' });
    requestAnimationFrame(() => stageRef.current?.focus());
  };

  const continuePage = () => {
    setCueDismissed(true);
    rootRef.current?.closest<HTMLElement>('[data-assembly-root]')?.dispatchEvent(new CustomEvent('array:release-ready-gate'));
    requestAnimationFrame(() => scrollBy({ top: innerHeight * .65, behavior: 'smooth' }));
  };

  const leaveWorkspace = () => {
    dispatch({ type: 'SET_INPUT_MODE', mode: 'page' });
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const id = returnFocusRef.current === 'companion' ? 'device-focus-companion' : 'explore-workspace';
      rootRef.current?.querySelector<HTMLButtonElement>(`[data-interaction-id="${id}"]`)?.focus();
    }));
  };

  const workspaceMode = state.inputMode === 'workspace';
  const canEnter = phase === 'ready' && !workspaceMode;

  return (
    <section ref={rootRef} className={styles.assembly} data-demo-root data-assembly-phase={phase} data-input-mode={state.inputMode} data-device-focus={state.deviceFocus} aria-label="Interactive Array workspace">
      <div ref={stageRef} className={styles.stage} data-assembly-stage data-assembly-pin tabIndex={workspaceMode ? -1 : undefined}>
        <div className={styles.portal} aria-hidden="true"><span /><span /></div>
        <div className={`${styles.device} ${styles.macSurface}`} data-device-surface="mac" data-focused={state.deviceFocus === 'mac'} inert={!workspaceMode || state.deviceFocus !== 'mac' ? true : undefined}>
          <MacWorkspace state={state} dispatch={dispatch} renderTileContent={renderTile} workspaceName="Array 0.5" />
        </div>
        <div className={`${styles.device} ${styles.companionSurface}`} data-device-surface="companion" data-focused={state.deviceFocus === 'companion'} inert={!workspaceMode || state.deviceFocus !== 'companion' ? true : undefined}>
          <Companion state={state} dispatch={dispatch} />
        </div>

        {canEnter && !cueDismissed && <ReadyCue onEnter={() => enterWorkspace(state.deviceFocus)} onContinue={continuePage} />}

        {(canEnter || (workspaceMode && state.deviceFocus !== 'mac')) && <button type="button" className={`${styles.capture} ${styles.captureMac}`} data-interaction-id={canEnter ? 'explore-workspace' : 'device-focus-mac'} onClick={() => enterWorkspace('mac')} aria-label={canEnter ? 'Explore Array workspace' : 'Focus Mac workspace'}><span className="sr-only">{canEnter ? 'Explore Array workspace' : 'Focus Mac workspace'}</span></button>}
        {(canEnter || (workspaceMode && state.deviceFocus !== 'companion')) && <button type="button" className={`${styles.capture} ${styles.captureCompanion}`} data-interaction-id="device-focus-companion" onClick={() => enterWorkspace('companion')} aria-label={canEnter ? 'Explore Array Companion' : 'Focus Companion'}><span className="sr-only">{canEnter ? 'Explore Array Companion' : 'Focus Companion'}</span></button>}

        {workspaceMode && state.deviceFocus === 'companion' && <button type="button" className={styles.done} data-interaction-id="done-exploring" onClick={leaveWorkspace}>Done</button>}
        {state.toast && <div className={styles.toast} role="status"><span>{state.toast}</span>{state.undo && <button type="button" data-interaction-id="toast-undo" onClick={() => dispatch({ type: 'UNDO' })}>Undo</button>}</div>}
        <CommandCenter state={state} dispatch={dispatch} />
        <p className={styles.live} aria-live="polite">{state.toast}</p>
      </div>
    </section>
  );
}
