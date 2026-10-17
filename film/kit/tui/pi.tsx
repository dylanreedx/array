// pi (pi 0.85), drawn on the terminal grid. Read off a live capture of pi's own renderer: user turns on a
// full-width block, each tool call on a full-width block (verb bold, path teal, output grey, diff lines
// red/olive), replies as plain text with a one-cell margin, then the editor between two rules and the
// status line (cwd · model · effort · session % · tokens · cost).
import { gridSize, Screen, wrap, type Grid, type Line } from './grid';
import type { PiTheme } from './themes';
import type { PiRow, PiSession } from './types';

const layout = (P: PiTheme, rows: PiRow[], cols: number): Line[] => {
  const out: Line[] = [];
  for (const r of rows) {
    switch (r.t) {
      case 'user':
        out.push({ segs: [], fill: P.userBg });
        wrap(r.text, cols - 2).forEach((l) => out.push({ segs: [{ text: ' ' + l, style: { color: P.text } }], fill: P.userBg }));
        out.push({ segs: [], fill: P.userBg });
        out.push({ segs: [] });
        break;
      case 'say':
        wrap(r.text, cols - 2).forEach((l) => out.push({ segs: [{ text: ' ' + l, style: { color: P.reply } }] }));
        out.push({ segs: [] });
        break;
      case 'tool': {
        const fill = P.toolBg;
        out.push({ segs: [], fill });
        out.push({ fill, segs: r.verb === '$'
          ? [{ text: ` $ ${r.arg}`, style: { color: P.text, fontWeight: 700 } }]
          : [{ text: ` ${r.verb}`, style: { color: P.text, fontWeight: 700 } }, { text: ' ' }, { text: r.arg, style: { color: P.path } }] });
        if (r.out || r.diff) out.push({ segs: [], fill });
        for (const l of r.out ?? []) out.push({ fill, segs: [{ text: ' ' + l, style: { color: P.muted } }] });
        for (const [n, sign, text] of r.diff ?? []) {
          const c = sign === '+' ? P.added : sign === '-' ? P.removed : P.muted;
          out.push({ fill, segs: [{ text: ` ${sign}${String(n).padStart(2)} ${text}`, style: { color: c } }] });
        }
        out.push({ segs: [], fill });
        out.push({ segs: [] });
        break;
      }
    }
  }
  return out;
};

/** Every line pi's screen holds; the editor and status line are tagged 'prompt' for a row morph. */
export const piLines = (grid: Grid, P: PiTheme, session: PiSession, cwd: string, width: number, height: number): Line[] => {
  const { cols } = gridSize(grid, width, height);
  const lines = layout(P, session.rows, cols);
  const rule = { text: '─'.repeat(cols), style: { color: P.rule } };
  const st = session.status;
  lines.push({ tag: 'prompt', segs: [rule] });
  lines.push({ tag: 'prompt', segs: [{ text: ' ', style: { background: 'rgba(255,255,255,0.86)' } }] });
  lines.push({ tag: 'prompt', segs: [rule] });
  lines.push({ tag: 'prompt', segs: [
    { text: cwd, style: { color: P.path, fontWeight: 700 } },
    { text: ` · ${st.model} · effort `, style: { color: P.status } }, { text: st.effort, style: { color: P.path } },
    { text: ' · session ', style: { color: P.status } }, { text: `${st.session}%`, style: { color: P.added } },
    { text: ` · ↑${st.up} ↓${st.down} · ${st.cost}`, style: { color: P.status } },
  ] });
  return lines;
};

export const Pi: React.FC<{ grid: Grid; theme: PiTheme; session: PiSession; cwd: string; width: number; height: number }> = ({ grid, theme, session, cwd, width, height }) =>
  <Screen grid={grid} lines={piLines(grid, theme, session, cwd, width, height)} width={width} height={height} fg={theme.reply} />;
