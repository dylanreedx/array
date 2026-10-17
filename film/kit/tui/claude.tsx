// Claude Code, drawn on the terminal grid: the welcome box, ⏺ messages and tool calls, ⎿ results, ∴ thought,
// line-numbered diffs, the ✻ spinner with its verb, the bordered prompt and the "? for shortcuts" hint.
import { gridSize, Screen, wrap, type Grid, type Line } from './grid';
import type { ClaudeTheme } from './themes';
import type { ClaudeRow, ClaudeSession } from './types';

const layoutRows = (C: ClaudeTheme, rows: ClaudeRow[], cols: number, toolDot: string): Line[] => {
  const dim: React.CSSProperties = { color: C.dim };
  const lines: Line[] = [];
  for (const r of rows) {
    const from = lines.length;
    switch (r.t) {
      case 'gap': lines.push({ segs: [] }); break;
      case 'user': wrap(r.text, cols - 2, 0).forEach((l, i) => lines.push({ segs: [{ text: (i ? '  ' : '> ') + l, style: dim }] })); break;
      case 'say': wrap(r.text, cols - 2, 0).forEach((l, i) => lines.push({ segs: i ? [{ text: '  ' + l }] : [{ text: '⏺ ' }, { text: l }] })); break;
      case 'thought': lines.push({ segs: [{ text: `∴ Thought for ${r.secs}s `, style: { ...dim, fontStyle: 'italic' } }, { text: '(ctrl+o to show thinking)', style: dim }] }); break;
      case 'tool': lines.push({ segs: [
        { text: '⏺ ', style: { color: r.pending ? C.dim : toolDot } },
        { text: r.name, style: { fontWeight: 700 } },
        ...(r.arg ? [{ text: `(${r.arg})` }] : []),
      ] }); break;
      case 'out': lines.push({ segs: [{ text: r.first ? '  ⎿  ' : '     ', style: dim }, { text: r.text, style: r.text.startsWith('✗') ? { color: C.error } : r.text.startsWith('✓') ? { color: C.success } : dim }] }); break;
      case 'diff': {
        // The changed text carries the highlight, not the whole row (which-tab round 2: the thumbnail's
        // headline must win over a full-width green block). Line number dim, sign in the diff colour.
        const n = String(r.n).padStart(4);
        const bg = r.sign === '+' ? C.addedBg : r.sign === '-' ? C.removedBg : undefined;
        const signColor = r.sign === '+' ? C.addedWord : r.sign === '-' ? C.removedWord : undefined;
        const indent = r.text.match(/^ */)![0];
        lines.push({ segs: [{ text: `     ${n} `, style: dim }, { text: r.sign, style: signColor ? { color: signColor, fontWeight: 700 } : dim }, { text: ` ${indent}` },
          { text: r.text.slice(indent.length), style: bg ? { background: `color-mix(in srgb, ${bg} 72%, transparent)` } : undefined }] });
        break;
      }
    }
    if (r.id) for (let k = from; k < lines.length; k++) lines[k].tag = r.id;
  }
  return lines;
};

/** Claude Code's welcome box: what a session's scrollback starts with. `cwd` is the full path it shows. */
const welcome = (C: ClaudeTheme, cwd: string): Line[] => {
  const dim: React.CSSProperties = { color: C.dim };
  const box = (edge: 'top' | 'mid' | 'bottom') => ({ edge, cols: 53, color: C.claude });
  return [
    { segs: [], box: box('top') },
    { segs: [{ text: '  ' }, { text: '✻', style: { color: C.claude } }, { text: ' Welcome to ' }, { text: 'Claude Code', style: { fontWeight: 700 } }, { text: '!' }], box: box('mid') },
    { segs: [], box: box('mid') },
    { segs: [{ text: '    /help for help, /status for your current setup', style: { ...dim, fontStyle: 'italic' } }], box: box('mid') },
    { segs: [], box: box('mid') },
    { segs: [{ text: `    cwd: ${cwd}`, style: dim }], box: box('mid') },
    { segs: [], box: box('bottom') },
    { segs: [] },
  ];
};

const SPIN = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];

/** Every line the session's screen holds (transcript, spinner, prompt box, hint), tagged for a row morph. */
export const claudeLines = (grid: Grid, C: ClaudeTheme, session: ClaudeSession, cwd: string, width: number, height: number, f: number, fps: number, cursor = true): Line[] => {
  const dim: React.CSSProperties = { color: C.dim };
  const { cols } = gridSize(grid, width, height);
  const lines = [...welcome(C, cwd), ...layoutRows(C, session.rows, cols, C.success)];
  const secs = session.spin.secs + Math.floor(f / fps);
  const glyph = SPIN[Math.floor(f / (fps * 0.12)) % SPIN.length];
  const time = secs >= 60 ? `${Math.floor(secs / 60)}m ${secs % 60}s` : `${secs}s`;
  const prompt = (edge: 'top' | 'mid' | 'bottom') => ({ edge, cols, color: C.border });
  return [
    ...lines,
    { segs: [] },
    { tag: 'spinner', segs: [{ text: glyph + ' ', style: { color: C.claude } }, { text: `${session.spin.verb}… `, style: { color: C.claude } }, { text: `(${time} · ↓ ${session.spin.tokens} tokens · esc to interrupt)`, style: dim }] },
    { segs: [] },
    { tag: 'prompt', blank: false, segs: [], box: prompt('top') },
    { tag: 'prompt', segs: [{ text: '  > ' }, { text: ' ', style: { background: cursor ? 'rgba(255,255,255,0.86)' : undefined } }], box: prompt('mid') },
    { tag: 'prompt', blank: false, segs: [], box: prompt('bottom') },
    { tag: 'hint', segs: [{ text: '  ? for shortcuts', style: dim }] },
  ];
};

export const Claude: React.FC<{ grid: Grid; theme: ClaudeTheme; session: ClaudeSession; cwd: string; width: number; height: number; f: number; fps: number; cursor?: boolean }> = ({ grid, theme, session, cwd, width, height, f, fps, cursor = true }) =>
  <Screen grid={grid} lines={claudeLines(grid, theme, session, cwd, width, height, f, fps, cursor)} width={width} height={height} fg={theme.text} />;
