import { useEffect, useMemo, useRef, useState, type Dispatch, type KeyboardEvent } from 'react';
import { Dialog } from '@base-ui/react/dialog';
import type { DemoAction, DemoState } from '../../../features/demo/types';
import { Glyph, type GlyphName } from '../Glyph';
import { ProviderMark } from '../ProviderMark';
import styles from './CommandCenter.module.css';

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

type CommandSection = 'Needs You' | 'Recent' | 'Create' | 'Agents & Tiles' | 'Actions' | 'Quick Start' | 'OpenAI Codex' | 'Anthropic' | 'Pi' | 'Reasoning Effort';

interface CommandItem {
  id: string;
  label: string;
  detail?: string;
  section: CommandSection;
  glyph?: GlyphName;
  provider?: string;
  accessory?: string;
  attention?: boolean;
  keywords: string;
  run: () => void;
}

const sectionOrder: CommandSection[] = ['Needs You', 'Recent', 'Create', 'Agents & Tiles', 'Actions'];

const models = [
  { id: 'default', label: 'Default · GPT-5.6 Sol', detail: 'Your configured default', section: 'Quick Start' as const, provider: 'Codex', value: 'GPT-5.6 Sol' },
  { id: 'gpt-sol', label: 'GPT-5.6 Sol', detail: 'openai-codex/gpt-5.6-sol', section: 'OpenAI Codex' as const, provider: 'Codex', value: 'GPT-5.6 Sol' },
  { id: 'gpt-terra', label: 'GPT-5.6 Terra', detail: 'openai-codex/gpt-5.6-terra', section: 'OpenAI Codex' as const, provider: 'Codex', value: 'GPT-5.6 Terra' },
  { id: 'gpt-luna', label: 'GPT-5.6 Luna', detail: 'openai-codex/gpt-5.6-luna', section: 'OpenAI Codex' as const, provider: 'Codex', value: 'GPT-5.6 Luna' },
  { id: 'claude-opus', label: 'Claude Opus 5', detail: 'anthropic/claude-opus-5', section: 'Anthropic' as const, provider: 'Claude Code', value: 'Claude Opus 5' },
  { id: 'claude-sonnet', label: 'Claude Sonnet 5', detail: 'anthropic/claude-sonnet-5', section: 'Anthropic' as const, provider: 'Claude Code', value: 'Claude Sonnet 5' },
  { id: 'pi-auto', label: 'Auto', detail: 'Pi chooses the best available model', section: 'Pi' as const, provider: 'Pi', value: 'Auto' },
];

const efforts = [
  { id: 'low', label: 'Low', detail: 'Fast iteration for narrow changes', glyph: 'collapse' as GlyphName },
  { id: 'medium', label: 'Medium', detail: 'Balanced reasoning and speed', glyph: 'agent' as GlyphName, accessory: 'Default' },
  { id: 'high', label: 'High', detail: 'Thorough reasoning for complex work', glyph: 'expand' as GlyphName },
];

export function CommandCenter({ state, dispatch, onEvent, className = '' }: CommandCenterProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  const emit = (event: CommandEvent) => onEvent?.(event);
  const close = (reason: 'escape' | 'action' | 'backdrop') => { dispatch({ type: 'OPEN_COMMAND', open: false }); emit({ type: 'command-closed', reason }); };
  const execute = (command: string, action: DemoAction, closes = true) => { dispatch(action); emit({ type: 'command-executed', command }); if (closes) close('action'); };
  const chooseModel = (model: string) => { dispatch({ type: 'SET_COMMAND_STEP', step: 'effort', value: model }); dispatch({ type: 'SET_COMMAND_QUERY', query: '' }); emit({ type: 'command-step-changed', step: 'effort', value: model }); };

  const rootItems: CommandItem[] = [
    { id: 'verify', label: 'Verify approval handoff', detail: 'Approval · Claude Opus 5 · Companion', section: 'Needs You', glyph: 'attention', attention: true, keywords: 'needs you approval attention verify companion', run: () => execute('jump-verify', { type: 'SELECT_ENTITY', id: 'verify' }) },
    { id: 'stabilize', label: 'Stabilize zone placement', detail: 'Working · GPT-5.6 Sol · Canvas Runtime', section: 'Recent', glyph: 'agent', keywords: 'agent working gpt sol recent stabilize zone placement', run: () => execute('jump-stabilize', { type: 'SELECT_ENTITY', id: 'stabilize' }) },
    { id: 'runtime', label: 'Canvas Runtime', detail: 'Zone · 4 open tiles', section: 'Recent', glyph: 'zone', keywords: 'zone canvas runtime recent jump', run: () => execute('zone-runtime', { type: 'SELECT_ENTITY', id: 'runtime' }) },
    { id: 'new-agent', label: 'Agent', detail: 'Start a focused coding session', section: 'Create', glyph: 'agent', accessory: '⌘N', keywords: 'new create spawn managed agent model', run: () => { dispatch({ type: 'SET_COMMAND_STEP', step: 'model' }); dispatch({ type: 'SET_COMMAND_QUERY', query: '' }); emit({ type: 'command-step-changed', step: 'model' }); } },
    { id: 'terminal', label: 'Terminal', detail: 'Open a local shell tile', section: 'Create', glyph: 'terminal', keywords: 'new create shell terminal', run: () => execute('terminal', { type: 'REOPEN_TILE', id: 'shell' }) },
    { id: 'open-browser', label: 'Browser', detail: 'Open a web tile', section: 'Create', glyph: 'browser', keywords: 'new create open browser web', run: () => execute('open-browser', { type: 'REOPEN_TILE', id: 'browser' }) },
    { id: 'new-note', label: 'Note', detail: 'Add a canvas note', section: 'Create', glyph: 'note', keywords: 'new create note edit', run: () => { dispatch({ type: 'REOPEN_TILE', id: 'note' }); dispatch({ type: 'NOTE_MODE', mode: 'edit' }); close('action'); } },
    { id: 'new-zone', label: 'Zone', detail: 'Group related canvas work', section: 'Create', glyph: 'zone', keywords: 'new create group zone', run: () => execute('new-zone', { type: 'CREATE_ZONE', zone: { id: `zone-${Date.now()}`, name: 'New zone', color: 'blue', frame: { x: 420, y: 260, width: 440, height: 300 }, collapsed: false } }) },
    { id: 'tidy', label: 'Tidy canvas', detail: 'Restore spacing without changing tile sizes', section: 'Actions', glyph: 'shuffle', accessory: '⇧⌘L', keywords: 'workspace layout organize arrange tidy', run: () => execute('tidy', { type: 'TIDY' }) },
    { id: 'fit', label: 'Show entire canvas', detail: 'Fit every tile and zone', section: 'Actions', glyph: 'fit', accessory: '0', keywords: 'fit camera zoom center entire canvas', run: () => execute('fit', { type: 'SET_CAMERA', device: 'mac', camera: { x: 32, y: 26, zoom: .76 } }) },
    { id: 'shuffle', label: 'Shuffle workspace', detail: 'Try a different collision-free layout', section: 'Actions', glyph: 'shuffle', keywords: 'random layout shuffle', run: () => execute('shuffle', { type: 'SHUFFLE' }) },
    { id: 'reset', label: 'Reset Demo', detail: 'Restore the canonical workspace', section: 'Actions', glyph: 'reset', keywords: 'restore restart reset demo', run: () => execute('reset', { type: 'RESET' }) },
    ...Object.values(state.tiles).filter((tile) => !tile.open).map((tile): CommandItem => ({ id: `reopen-${tile.id}`, label: `Reopen ${tile.title}`, detail: `${tile.kind} · Closed`, section: 'Agents & Tiles', glyph: 'forward', keywords: `reopen closed history ${tile.kind}`, run: () => execute(`reopen-${tile.id}`, { type: 'REOPEN_TILE', id: tile.id }) })),
    ...Object.values(state.tiles).filter((tile) => tile.open && !['stabilize', 'verify'].includes(tile.id)).map((tile): CommandItem => ({ id: `jump-${tile.id}`, label: tile.title, detail: `${tile.kind[0].toUpperCase()}${tile.kind.slice(1)} · ${state.zones[tile.zoneId ?? '']?.name ?? 'Canvas'}`, section: 'Agents & Tiles', glyph: tile.kind === 'shell' ? 'terminal' : tile.kind, keywords: `jump focus ${tile.kind} ${tile.title}`, run: () => execute(`jump-${tile.id}`, { type: 'SELECT_ENTITY', id: tile.id }) })),
    ...Object.values(state.zones).filter((zone) => zone.id !== 'runtime').map((zone): CommandItem => ({ id: `zone-${zone.id}`, label: zone.name, detail: 'Zone', section: 'Agents & Tiles', glyph: 'zone', keywords: 'jump focus zone', run: () => execute(`zone-${zone.id}`, { type: 'SELECT_ENTITY', id: zone.id }) })),
  ];

  const query = state.commandQuery.trim().toLowerCase();
  const items = useMemo(() => {
    let source: CommandItem[];
    if (state.commandStep === 'model') source = models.map((model) => ({ ...model, keywords: `${model.label} ${model.detail} ${model.provider}`, run: () => chooseModel(model.value) }));
    else if (state.commandStep === 'effort') source = efforts.map((effort) => ({ ...effort, section: 'Reasoning Effort' as const, keywords: `${effort.label} ${effort.detail}`, run: () => { const model = state.pendingAgentModel ?? 'GPT-5.6 Sol'; dispatch({ type: 'SPAWN_AGENT', model, effort: effort.label }); emit({ type: 'agent-spawned', model, effort: effort.label }); emit({ type: 'command-closed', reason: 'action' }); } }));
    else { const homeIDs = new Set(['verify', 'stabilize', 'runtime', 'new-agent', 'terminal', 'open-browser', 'new-note', 'new-zone', 'tidy', 'fit']); source = query ? rootItems : rootItems.filter((item) => homeIDs.has(item.id)); }
    if (!query) return source;
    const tokens = query.split(/\s+/);
    return source.filter((item) => { const haystack = `${item.label} ${item.detail ?? ''} ${item.keywords}`.toLowerCase(); return tokens.every((token) => haystack.includes(token)); });
  }, [query, state.commandStep, state.pendingAgentModel, state.tiles, state.zones]);

  const grouped = useMemo(() => {
    const order: CommandSection[] = state.commandStep === 'model' ? ['Quick Start', 'OpenAI Codex', 'Anthropic', 'Pi'] : state.commandStep === 'effort' ? ['Reasoning Effort'] : sectionOrder;
    return order.map((section) => ({ section, items: items.map((item, flatIndex) => ({ item, flatIndex })).filter(({ item }) => item.section === section) })).filter(({ items }) => items.length);
  }, [items, state.commandStep]);

  useEffect(() => { if (state.commandOpen) window.requestAnimationFrame(() => inputRef.current?.focus()); }, [state.commandOpen, state.commandStep]);
  useEffect(() => setActiveIndex(0), [state.commandQuery, state.commandStep]);
  if (!state.commandOpen) return null;

  const back = () => { if (state.commandStep === 'effort') { dispatch({ type: 'SET_COMMAND_STEP', step: 'model' }); emit({ type: 'command-step-changed', step: 'model' }); } else { dispatch({ type: 'SET_COMMAND_STEP', step: 'root' }); emit({ type: 'command-step-changed', step: 'root' }); } dispatch({ type: 'SET_COMMAND_QUERY', query: '' }); };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'ArrowDown') { event.preventDefault(); setActiveIndex((index) => items.length ? (index + 1) % items.length : 0); }
    if (event.key === 'ArrowUp') { event.preventDefault(); setActiveIndex((index) => items.length ? (index - 1 + items.length) % items.length : 0); }
    if (event.key === 'Enter' && items[activeIndex]) { event.preventDefault(); items[activeIndex].run(); }
    if (event.key === 'Backspace' && !state.commandQuery && state.commandStep !== 'root') { event.preventDefault(); back(); }
  };

  const title = state.commandStep === 'root' ? 'Command Center' : state.commandStep === 'model' ? 'Choose a model' : `Choose effort · ${state.pendingAgentModel ?? 'Agent'}`;
  const placeholder = state.commandStep === 'root' ? 'Search Array…' : state.commandStep === 'model' ? 'Search models…' : 'Choose reasoning effort…';

  return <Dialog.Root open={state.commandOpen} onOpenChange={(open, details) => {
    if (open) return;
    if (details.reason === 'escape-key' && state.commandStep !== 'root') { details.cancel(); back(); return; }
    close(details.reason === 'escape-key' ? 'escape' : 'backdrop');
  }}><Dialog.Portal>
    <Dialog.Backdrop className={`${styles.backdrop} ${className}`} data-interaction-id="command-backdrop" />
    <Dialog.Popup className={styles.panel} aria-label={title} data-command-step={state.commandStep}>
      <Dialog.Title className={styles.visuallyHidden}>{title}</Dialog.Title>
      <header className={styles.searchRow}>
        {state.commandStep !== 'root' ? <button type="button" className={styles.back} data-interaction-id="command-back" aria-label="Go back" onClick={back}><Glyph name="back" /></button> : <span className={styles.commandGlyph} data-noninteractive="true"><Glyph name="command" /></span>}
        <input ref={inputRef} data-interaction-id="command-search" value={state.commandQuery} aria-label={title} aria-controls="command-results" aria-activedescendant={items[activeIndex] ? `command-item-${items[activeIndex].id}` : undefined} placeholder={placeholder} onChange={(event) => dispatch({ type: 'SET_COMMAND_QUERY', query: event.target.value })} onKeyDown={onKeyDown} />
        {state.commandStep !== 'root' && <span className={styles.stepCount} data-noninteractive="true">{state.commandStep === 'model' ? '1 of 2' : '2 of 2'}</span>}
        <button type="button" className={styles.escape} data-interaction-id="command-close" aria-label="Close Command Center" onClick={() => close('action')}>esc</button>
      </header>
      <div id="command-results" className={styles.results} role="listbox" aria-label={title}>
        {grouped.map((group) => <section className={styles.section} key={group.section} role="group" aria-label={group.section}><h3 aria-hidden="true">{group.section}</h3>{group.items.map(({ item, flatIndex }) => <button id={`command-item-${item.id}`} key={item.id} type="button" role="option" aria-selected={flatIndex === activeIndex} className={styles.item} data-active={flatIndex === activeIndex || undefined} data-attention={item.attention || undefined} data-interaction-id={`command-item-${item.id}`} onMouseEnter={() => setActiveIndex(flatIndex)} onClick={item.run}>
          <span className={styles.itemGlyph}>{item.provider ? <ProviderMark provider={item.provider} /> : item.glyph ? <Glyph name={item.glyph} /> : null}</span><span className={styles.itemCopy}><strong>{item.label}</strong>{item.detail && <small>{item.detail}</small>}</span>{item.accessory && <kbd>{item.accessory}</kbd>}{flatIndex === activeIndex && !item.accessory && <Glyph className={styles.openGlyph} name="forward" />}
        </button>)}</section>)}
        {!items.length && <div className={styles.empty} data-noninteractive="true"><Glyph name="command" /><strong>No results</strong><span>Try an agent, tile, model, or canvas action.</span></div>}
      </div>
      <footer data-noninteractive="true"><span>Type to search</span><span><kbd>↑↓</kbd> Select</span><span><kbd>↵</kbd> Open</span><span><kbd>esc</kbd> {state.commandStep === 'root' ? 'Close' : 'Back'}</span></footer>
    </Dialog.Popup>
  </Dialog.Portal></Dialog.Root>;
}
