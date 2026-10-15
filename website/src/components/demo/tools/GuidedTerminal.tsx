import { TERMINAL_LINES } from '../../../lib/guided-demo';
import styles from './GuidedTerminal.module.css';

// A Ghostty surface: one scrollback, the prompt inline after the output, and a
// block cursor at the end of the live line. The guided controller reveals lines
// and types the command as pure functions of scroll progress.
const Prompt = () => <><span className={styles.cwd}>~/Array</span> <span className={styles.branch}>main</span> <span className={styles.caret}>❯</span> </>;

export function GuidedTerminal() {
  const before = TERMINAL_LINES.filter(line => line.at === 0);
  const run = TERMINAL_LINES.filter(line => line.at > 0);
  const line = (entry: typeof TERMINAL_LINES[number], index: number) => (
    <div key={index} className={styles.line} data-term-line={index} data-kind={entry.kind} hidden={entry.at > 0}>
      {entry.kind === 'prompt' && <Prompt />}
      {entry.kind === 'suite' && <span className={styles.suite}>◇ </span>}
      {entry.kind === 'pass'
        ? <><span className={styles.pass}>  ✔ </span>{entry.text.padEnd(26)}<span className={styles.dim}>{entry.time}</span></>
        : entry.text}
      {entry.kind !== 'pass' && entry.time && <span className={styles.dim}> ({entry.time})</span>}
    </div>
  );
  return (
    <div className={styles.terminal} data-demo-terminal>
      {before.map((entry, index) => line(entry, index))}
      <div className={styles.line} data-kind="prompt">
        <Prompt />
        <span data-interaction-id="shell-input"><span data-term-typed /><span className={styles.cursor} data-term-cursor="live" /></span>
      </div>
      {run.map((entry, index) => line(entry, before.length + index))}
      <div className={styles.line} data-kind="prompt" data-term-final hidden><Prompt /><span className={styles.cursor} /></div>
    </div>
  );
}
