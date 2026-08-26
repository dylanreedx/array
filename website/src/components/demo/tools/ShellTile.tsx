import { useEffect, useRef } from 'react';
import type { DemoAction, DemoState, ShellLine } from '../../../features/demo/types';
import styles from './Tools.module.css';

const outputFor = (command: string, operation: number): ShellLine[] => {
  const id = (suffix: string) => `${operation}-${suffix}`;
  switch (command) {
    case 'help': return [{ id: id('help'), type: 'output', text: 'help · swift build · swift test · git status · clear' }];
    case 'swift build': return [{ id: id('build'), type: 'success', text: 'Build complete! (2.4s)' }];
    case 'swift test': return [{ id: id('test'), type: 'success', text: '18 checks passed · 0 failures' }];
    case 'git status': return [{ id: id('git'), type: 'output', text: 'On branch array/integration\nworking tree contains website redesign' }];
    default: return [{ id: id('error'), type: 'error', text: 'command not available in this demo' }];
  }
};

export function ShellTile({ state, dispatch, nextOperation }: { state: DemoState; dispatch: React.Dispatch<DemoAction>; nextOperation: () => number }) {
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  const run = () => {
    const command = state.shell.draft.trim();
    if (!command || state.shell.running) return;
    const operation = nextOperation();
    dispatch({ type: 'SHELL_EXECUTE', command, operation });
    if (command === 'clear') return;
    timers.current.push(window.setTimeout(() => dispatch({ type: 'SHELL_COMPLETE', operation, lines: outputFor(command, operation) }), 520));
  };
  return <div className={styles.shell} data-testid="shell-shell">
    <div className={styles.shellTranscript} aria-live="polite">{state.shell.lines.map((line) => <code key={line.id} data-type={line.type}>{line.type === 'prompt' ? '$ ' : ''}{line.text}</code>)}</div>
    <div className={styles.shellInput}><span>$</span><input aria-label="Demo shell command" data-interaction-id="shell-input" value={state.shell.draft} disabled={state.shell.running} onChange={(event) => dispatch({ type: 'SHELL_DRAFT', value: event.target.value })} onKeyDown={(event) => {
      if (event.key === 'Enter') { event.preventDefault(); run(); }
      if (event.key === 'ArrowUp') { event.preventDefault(); dispatch({ type: 'SHELL_HISTORY', direction: -1 }); }
      if (event.key === 'ArrowDown') { event.preventDefault(); dispatch({ type: 'SHELL_HISTORY', direction: 1 }); }
      if (event.key.toLowerCase() === 'l' && event.ctrlKey) { event.preventDefault(); dispatch({ type: 'SHELL_EXECUTE', command: 'clear', operation: nextOperation() }); }
    }}/></div>
  </div>;
}
