// codex (codex-cli 0.159), drawn on the terminal grid. codex has no welcome box once a session has scrolled:
// its transcript is bullet cells (•), each tool cell with a └ tree under it, a turn's end marked
// "─ Worked for … ─", "• Working (… • esc to interrupt)" while busy, and the › composer with its footer.
// It draws in the terminal's ANSI palette, so the theme is the terminal's (themes.ts CODEX_VESPER).
import { gridSize, Screen, wrap, type Grid, type Line } from './grid';
import type { CodexTheme } from './themes';
import type { CodexRow, CodexSession } from './types';

const bold: React.CSSProperties = { fontWeight: 700 };
const mmss = (secs: number) => (secs >= 3600 ? `${Math.floor(secs / 3600)}h ${String(Math.floor((secs % 3600) / 60)).padStart(2, '0')}m` : `${Math.floor(secs / 60)}m ${String(secs % 60).padStart(2, '0')}s`);

const layout = (X: CodexTheme, rows: CodexRow[], cols: number): Line[] => {
  const dim: React.CSSProperties = { color: X.dim };
  const out: Line[] = [];
  const gap = () => out.push({ segs: [] });
  for (const r of rows) {
    switch (r.t) {
      case 'user':
        out.push({ segs: [], fill: X.userBand });
        wrap(r.text, cols - 2).forEach((l, i) => out.push({ segs: [{ text: i ? '  ' : '› ', style: { ...dim, ...bold } }, { text: l }], fill: X.userBand }));
        out.push({ segs: [], fill: X.userBand });
        gap();
        break;
      case 'say':
        wrap(r.text, cols - 2).forEach((l, i) => out.push({ segs: [{ text: i ? '  ' : '• ', style: dim }, { text: l }] }));
        gap();
        break;
      case 'explored':
        out.push({ segs: [{ text: '• ', style: dim }, { text: 'Explored', style: bold }] });
        r.items.forEach(([verb, arg], i) => out.push({ segs: [{ text: i ? '    ' : '  └ ', style: dim }, { text: `${verb} `, style: { color: X.cyan } }, { text: arg }] }));
        gap();
        break;
      case 'ran':
        out.push({ segs: [{ text: '• ', style: { color: r.ok ? X.green : X.red } }, { text: 'Ran ', style: bold }, { text: r.cmd }] });
        r.out.forEach((l, i) => out.push({ segs: [{ text: i ? '    ' : '  └ ', style: dim }, { text: l, style: r.ok ? dim : { color: l.startsWith('FAIL') || l.startsWith('Tests') ? X.red : X.dim } }] }));
        gap();
        break;
      case 'edited':
        out.push({ segs: [{ text: '• ', style: { color: X.green } }, { text: 'Edited ', style: bold }, { text: r.path }, { text: ' (' }, { text: `+${r.add}`, style: { color: X.green } }, { text: ' ' }, { text: `-${r.del}`, style: { color: X.red } }, { text: ')' }] });
        for (const [n, sign, text] of r.diff) {
          const c = sign === '+' ? X.green : sign === '-' ? X.red : undefined;
          out.push({ segs: [{ text: `    ${String(n).padStart(3)} `, style: dim }, { text: `${sign}${text}`, style: c ? { color: c } : undefined }] });
        }
        gap();
        break;
      case 'failed':
        wrap(r.text, cols - 2).forEach((l, i) => out.push({ segs: [{ text: i ? '  ' : '■ ', style: { color: X.red } }, { text: l, style: { color: X.red } }] }));
        gap();
        break;
      case 'worked': {
        const label = `─ Worked for ${mmss(r.secs)} `;
        out.push({ segs: [{ text: label + '─'.repeat(Math.max(0, cols - [...label].length)), style: dim }] });
        gap();
        break;
      }
    }
  }
  return out;
};

/** Every line codex's screen holds; the composer and its footer are tagged 'prompt' for a row morph. */
export const codexLines = (grid: Grid, X: CodexTheme, session: CodexSession, width: number, height: number, f: number, fps: number): Line[] => {
  const dim: React.CSSProperties = { color: X.dim };
  const { cols } = gridSize(grid, width, height);
  const lines = layout(X, session.rows, cols);
  if (session.working) {
    // "Working" shimmers in codex: a bright band sweeps across the word; the bullet breathes • ◦.
    const secs = session.working.secs + Math.floor(f / fps);
    const word = 'Working';
    const sweep = ((f / fps) * 1.6) % 2.4 - 0.4; // band position across the word, 0..1 and beyond
    lines.push({ segs: [
      { text: Math.floor(f / (fps * 0.6)) % 2 ? '◦ ' : '• ', style: dim },
      ...[...word].map((ch, i) => ({ text: ch, style: { fontWeight: 700, color: `rgba(255,255,255,${0.45 + 0.55 * Math.max(0, 1 - Math.abs(i / word.length - sweep) * 4)})` } })),
      { text: ` (${mmss(secs)} • esc to interrupt)`, style: dim },
    ] });
    lines.push({ segs: [] });
  }
  const right = `${session.context}% context left`;
  lines.push({ tag: 'prompt', segs: [{ text: '› ', style: bold }, { text: 'Ask Codex to do anything', style: dim }] });
  lines.push({ tag: 'prompt', blank: false, segs: [] });
  lines.push({ tag: 'prompt', segs: [{ text: '  ? for shortcuts', style: dim }, { text: ' '.repeat(Math.max(1, cols - 17 - right.length)) }, { text: right, style: dim }] });
  return lines;
};

export const Codex: React.FC<{ grid: Grid; theme: CodexTheme; session: CodexSession; width: number; height: number; f: number; fps: number }> = ({ grid, theme, session, width, height, f, fps }) =>
  <Screen grid={grid} lines={codexLines(grid, theme, session, width, height, f, fps)} width={width} height={height} fg={theme.text} />;
