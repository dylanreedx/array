import { useEffect, useMemo, useRef, useState, type Dispatch, type KeyboardEvent } from 'react';
import { Dialog } from '@base-ui/react/dialog';
import type { DemoAction, DemoState } from '../../../features/demo/types';
import styles from './CommandCenter.module.css';
import { Glyph, type GlyphName } from '../Glyph';

export type CommandEvent =
  | { type: 'command-executed'; command: string }
  | { type: 'command-step-changed'; step: DemoState['commandStep']; value?: string }
  | { type: 'agent-spawned'; model: string; effort: string }
  | { type: 'command-closed'; reason: 'escape' | 'action' | 'backdrop' };

export interface CommandCenterProps {
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
  onEvent?: (event: CommandEvent) => void;
  className?: string;
}

interface CommandItem {
  id: string;
  label: string;
  detail: string;
  glyph: GlyphName;
  keywords: string;
  run: () => void;
}

const models = [
  { id: 'gpt-5', label: 'GPT-5', detail: 'Codex · strongest general coding model', glyph: 'agent' as GlyphName },
  { id: 'claude-opus', label: 'Claude Opus', detail: 'Claude Code · deep repository work', glyph: 'tool' as GlyphName },
  { id: 'auto', label: 'Auto', detail: 'Pi · route the task automatically', glyph: 'shuffle' as GlyphName },
];
const efforts = [
  { id: 'low', label: 'Low', detail: 'Fast iteration and narrow changes', glyph: 'collapse' as GlyphName },
  { id: 'medium', label: 'Medium', detail: 'Balanced reasoning and speed', glyph: 'agent' as GlyphName },
  { id: 'high', label: 'High', detail: 'Thorough reasoning for complex work', glyph: 'expand' as GlyphName },
];

export function CommandCenter({ state, dispatch, onEvent, className = '' }: CommandCenterProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  const emit = (event: CommandEvent) => onEvent?.(event);

  const close = (reason: CommandEvent extends infer _ ? 'escape' | 'action' | 'backdrop' : never) => {
    dispatch({ type: 'OPEN_COMMAND', open: false });
    emit({ type: 'command-closed', reason });
  };

  const execute = (command: string, action: DemoAction, closes = true) => {
    dispatch(action);
    emit({ type: 'command-executed', command });
    if (closes) close('action');
  };

  const rootItems: CommandItem[] = [
    { id: 'new-agent', label: 'New Agent', detail: 'Choose a model and reasoning effort', glyph: 'agent', keywords: 'create spawn model', run: () => { dispatch({ type: 'SET_COMMAND_STEP', step: 'model' }); dispatch({ type: 'SET_COMMAND_QUERY', query: '' }); emit({ type: 'command-step-changed', step: 'model' }); } },
    { id: 'new-note', label: 'New Note', detail: 'Open the release note and start editing', glyph: 'note', keywords: 'create note edit', run: () => { dispatch({ type: 'REOPEN_TILE', id: 'note' }); dispatch({ type: 'NOTE_MODE', mode: 'edit' }); close('action'); } },
    { id: 'open-browser', label: 'Open Browser', detail: 'Open the local Canvas interaction spec', glyph: 'browser', keywords: 'create browser local', run: () => { dispatch({ type: 'REOPEN_TILE', id: 'browser' }); close('action'); } },
    { id: 'new-zone', label: 'New Zone', detail: 'Create a zone at the center of the workspace', glyph: 'zone', keywords: 'create group zone', run: () => execute('new-zone', { type: 'CREATE_ZONE', zone: { id: `zone-${Date.now()}`, name: 'New zone', color: 'blue', frame: { x: 420, y: 260, width: 440, height: 300 }, collapsed: false } }) },
    { id: 'tidy', label: 'Tidy Workspace', detail: 'Arrange every open surface', glyph: 'shuffle', keywords: 'layout organize arrange', run: () => execute('tidy', { type: 'TIDY' }) },
    { id: 'fit', label: 'Fit All', detail: 'Center every open zone and tile', glyph: 'fit', keywords: 'camera zoom center', run: () => execute('fit', { type: 'SET_CAMERA', device: 'mac', camera: { x: 32, y: 26, zoom: .76 } }) },
    { id: 'shuffle', label: 'Shuffle', detail: 'Apply the deterministic session layout', glyph: 'shuffle', keywords: 'random layout', run: () => execute('shuffle', { type: 'SHUFFLE' }) },
    { id: 'reset', label: 'Reset Demo', detail: 'Restore the canonical workspace', glyph: 'reset', keywords: 'restore restart', run: () => execute('reset', { type: 'RESET' }) },
    ...Object.values(state.tiles).filter((tile) => !tile.open).map((tile): CommandItem => ({ id: `reopen-${tile.id}`, label: `Reopen ${tile.title}`, detail: `${tile.kind} tile`, glyph: 'forward', keywords: `reopen closed ${tile.kind}`, run: () => execute(`reopen-${tile.id}`, { type: 'REOPEN_TILE', id: tile.id }) })),
    ...Object.values(state.tiles).filter((tile) => tile.open).map((tile): CommandItem => ({ id: `jump-${tile.id}`, label: `Jump to ${tile.title}`, detail: `${tile.kind} tile`, glyph: 'forward', keywords: `jump focus ${tile.kind}`, run: () => execute(`jump-${tile.id}`, { type: 'SELECT_ENTITY', id: tile.id }) })),
    ...Object.values(state.zones).map((zone): CommandItem => ({ id: `zone-${zone.id}`, label: `Jump to ${zone.name}`, detail: 'Workspace zone', glyph: 'zone', keywords: 'jump focus zone', run: () => execute(`zone-${zone.id}`, { type: 'SELECT_ENTITY', id: zone.id }) })),
  ];

  const stepItems: CommandItem[] = state.commandStep === 'model'
    ? models.map((model) => ({ ...model, keywords: `${model.label} ${model.detail}`, run: () => { dispatch({ type: 'SET_COMMAND_STEP', step: 'effort', value: model.label }); dispatch({ type: 'SET_COMMAND_QUERY', query: '' }); emit({ type: 'command-step-changed', step: 'effort', value: model.label }); } }))
    : efforts.map((effort) => ({ ...effort, keywords: `${effort.label} ${effort.detail}`, run: () => { const model = state.pendingAgentModel ?? 'GPT-5'; dispatch({ type: 'SPAWN_AGENT', model, effort: effort.label }); emit({ type: 'agent-spawned', model, effort: effort.label }); emit({ type: 'command-closed', reason: 'action' }); } }));

  const items = state.commandStep === 'root' ? rootItems : stepItems;
  const filtered = useMemo(() => {
    const query = state.commandQuery.trim().toLowerCase();
    return query ? items.filter((item) => `${item.label} ${item.detail} ${item.keywords}`.toLowerCase().includes(query)) : items;
  }, [state.commandQuery, state.commandStep, state.pendingAgentModel]);

  useEffect(() => { if (state.commandOpen) window.requestAnimationFrame(() => inputRef.current?.focus()); }, [state.commandOpen, state.commandStep]);
  useEffect(() => setActiveIndex(0), [state.commandQuery, state.commandStep]);

  if (!state.commandOpen) return null;

  const back = () => {
    if (state.commandStep === 'effort') {
      dispatch({ type: 'SET_COMMAND_STEP', step: 'model' });
      emit({ type: 'command-step-changed', step: 'model' });
    } else {
      dispatch({ type: 'SET_COMMAND_STEP', step: 'root' });
      emit({ type: 'command-step-changed', step: 'root' });
    }
    dispatch({ type: 'SET_COMMAND_QUERY', query: '' });
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'ArrowDown') { event.preventDefault(); setActiveIndex((index) => filtered.length ? (index + 1) % filtered.length : 0); }
    if (event.key === 'ArrowUp') { event.preventDefault(); setActiveIndex((index) => filtered.length ? (index - 1 + filtered.length) % filtered.length : 0); }
    if (event.key === 'Enter' && filtered[activeIndex]) { event.preventDefault(); filtered[activeIndex].run(); }
    if (event.key === 'Escape') { event.preventDefault(); close('escape'); }
    if (event.key === 'Backspace' && !state.commandQuery && state.commandStep !== 'root') { event.preventDefault(); back(); }
  };

  const title = state.commandStep === 'root' ? 'Command Center' : state.commandStep === 'model' ? 'Choose a model' : `Choose effort · ${state.pendingAgentModel ?? 'Agent'}`;

  return (
    <Dialog.Root open={state.commandOpen} onOpenChange={(open) => { if (!open) close('backdrop'); }}>
      <Dialog.Portal>
      <Dialog.Backdrop className={`${styles.backdrop} ${className}`} data-interaction-id="command-backdrop" />
      <Dialog.Popup className={styles.panel} aria-label={title}>
        <Dialog.Title className={styles.visuallyHidden}>{title}</Dialog.Title>
        <header className={styles.searchRow}>
          {state.commandStep !== 'root' ? <button type="button" data-interaction-id="command-back" aria-label="Go back" onClick={back}><Glyph name="back" /></button> : <span className={styles.commandGlyph} data-noninteractive="true"><Glyph name="command" /></span>}
          <input
            ref={inputRef}
            data-interaction-id="command-search"
            value={state.commandQuery}
            aria-label={title}
            aria-controls="command-results"
            aria-activedescendant={filtered[activeIndex] ? `command-item-${filtered[activeIndex].id}` : undefined}
            placeholder={state.commandStep === 'root' ? 'Search Array…' : state.commandStep === 'model' ? 'Search models…' : 'Choose an effort…'}
            onChange={(event) => dispatch({ type: 'SET_COMMAND_QUERY', query: event.target.value })}
            onKeyDown={onKeyDown}
          />
          <button type="button" className={styles.escape} data-interaction-id="command-close" aria-label="Close Command Center" onClick={() => close('action')}>esc</button>
        </header>

        <div className={styles.context} data-noninteractive="true">
          <span>{state.commandStep === 'root' ? 'CREATE & NAVIGATE' : state.commandStep === 'model' ? 'MODEL' : 'REASONING EFFORT'}</span>
          {state.commandStep !== 'root' && <strong>{state.commandStep === 'model' ? '1 of 2' : '2 of 2'}</strong>}
        </div>

        <div id="command-results" className={styles.results} role="listbox" aria-label={title}>
          {filtered.map((item, index) => (
            <button
              id={`command-item-${item.id}`}
              key={item.id}
              type="button"
              role="option"
              aria-selected={index === activeIndex}
              className={styles.item}
              data-active={index === activeIndex || undefined}
              data-interaction-id={`command-item-${item.id}`}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={item.run}
            >
              <span className={styles.itemGlyph}><Glyph name={item.glyph} /></span>
              <span><strong>{item.label}</strong><small>{item.detail}</small></span>
              {index === activeIndex && <kbd data-noninteractive="true">↵</kbd>}
            </button>
          ))}
          {!filtered.length && <div className={styles.empty} data-noninteractive="true"><strong>No matching command</strong><span>Try a model, surface, or workspace action.</span></div>}
        </div>

        <footer data-noninteractive="true"><span><kbd>↑↓</kbd> Navigate</span><span><kbd>↵</kbd> Select</span><span><kbd>esc</kbd> Close</span></footer>
      </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
