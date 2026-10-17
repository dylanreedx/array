// The terminal cell grid every CLI renders into: a monospace face on a fixed cell, one row per grid.line.
// Glyphs the face lacks (⏺ ⎿ ✻ › • ...) fall back to a system face the way Ghostty's do, but stay pinned to
// one cell so columns never drift. A screen fills from the top and scrolls once full: the oldest lines leave
// first. The grid (face, size, padding) is the caller's: a terminal's look, not the kit's.

export interface Grid {
  /** px */
  font: number;
  line: number;
  padX: number;
  padY: number;
  /** CSS font-family */
  family: string;
  /** the face's advance width per em (JetBrains Mono: 600 / 1000) */
  advance: number;
}

export const cellOf = (g: Grid) => g.font * g.advance;

const FALLBACK = /[⏺⎿✻✢✳✽∴⏵›•◦└⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏■✗]/u;

/** A run of text with one style; fallback glyphs are pinned to single cells. */
export const Run: React.FC<{ text: string; style?: React.CSSProperties; cell: number }> = ({ text, style, cell }) => {
  if (!FALLBACK.test(text)) return <span style={style}>{text}</span>;
  return (
    <span style={style}>
      {[...text].map((ch, i) => FALLBACK.test(ch)
        ? <span key={i} style={{ display: 'inline-block', width: cell, textAlign: 'center', fontSize: '0.92em', lineHeight: 1 }}>{ch}</span>
        : ch)}
    </span>
  );
};

export type Seg = { text: string; style?: React.CSSProperties };
/**
 * One terminal row. `bg` paints from cell `bgFrom` to the right edge (Claude's diff gutter); `fill` paints
 * the whole row edge to edge (pi's message and tool blocks). `box` is a row of a box-drawing frame
 * (╭─╮ │ │ ╰─╯) `cols` cells wide: Ghostty draws box characters as sprites that join across rows, and a
 * font's glyphs leave gaps at this line height, so the frame is drawn as borders through the edge cells.
 * `tag` names a block for a morph (tagRects); `blank` overrides whether the row counts as empty.
 */
export type Line = { segs: Seg[]; bg?: string; bgFrom?: number; fill?: string; box?: { edge: 'top' | 'mid' | 'bottom'; cols: number; color: string }; tag?: string; blank?: boolean };

/** Greedy word wrap to `cols`, continuation lines indented by `indent` cells. */
export const wrap = (text: string, cols: number, indent = 0): string[] => {
  const out: string[] = [];
  let line = '';
  for (const word of text.split(' ')) {
    const next = line ? `${line} ${word}` : word;
    if ([...next].length > cols - (out.length ? indent : 0) && line) { out.push(line); line = word; } else line = next;
  }
  out.push(line);
  return out;
};

const BoxRow: React.FC<{ edge: 'top' | 'mid' | 'bottom'; cols: number; color: string; grid: Grid }> = ({ edge, cols, color, grid }) => {
  const cell = cellOf(grid);
  const b = `1.5px solid ${color}`, r = cell * 0.75, half = grid.line / 2;
  return (
    <div style={{ position: 'absolute', left: cell / 2, width: (cols - 1) * cell, boxSizing: 'border-box', borderLeft: b, borderRight: b,
      ...(edge === 'top' ? { top: half, height: half, borderTop: b, borderTopLeftRadius: r, borderTopRightRadius: r }
        : edge === 'bottom' ? { top: 0, height: half, borderBottom: b, borderBottomLeftRadius: r, borderBottomRightRadius: r }
        : { top: 0, height: grid.line }) }} />
  );
};

export const gridSize = (grid: Grid, width: number, height: number) => ({
  cols: Math.floor((width - 2 * grid.padX) / cellOf(grid)),
  rows: Math.floor((height - 2 * grid.padY) / grid.line),
});

/**
 * Where each tagged block of a screen sits, in the terminal body's own px (a row morph reads these): only
 * rows still on screen count, and blank rows never stretch a block.
 */
export const tagRects = (grid: Grid, lines: Line[], width: number, height: number) => {
  const { rows, cols } = gridSize(grid, width, height);
  const shown = lines.slice(-rows);
  const out: Record<string, { x: number; y: number; width: number; height: number }> = {};
  shown.forEach((l, i) => {
    if (!l.tag || (l.blank ?? l.segs.length === 0)) return;
    const y = grid.padY + i * grid.line, r = out[l.tag];
    out[l.tag] = r ? { ...r, height: y + grid.line - r.y } : { x: grid.padX, y, width: cols * cellOf(grid), height: grid.line };
  });
  return { rects: out, shown: shown.length };
};

/** The screen: the last rows that fit, top-aligned, in the terminal's colours. */
export const Screen: React.FC<{ grid: Grid; lines: Line[]; width: number; height: number; fg: string }> = ({ grid, lines, width, height, fg }) => {
  const { rows } = gridSize(grid, width, height);
  const all = lines.slice(-rows);
  const cell = cellOf(grid);
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, width, height, overflow: 'hidden', padding: `${grid.padY}px ${grid.padX}px`, boxSizing: 'border-box',
      display: 'flex', flexDirection: 'column', justifyContent: 'flex-start', font: `400 ${grid.font}px/${grid.line}px ${grid.family}`, color: fg,
      fontVariantLigatures: 'none', fontFeatureSettings: '"calt" 0', whiteSpace: 'pre' }}>
      {all.map((l, i) => (
        <div key={i} style={{ height: grid.line, flex: 'none', position: 'relative' }}>
          {l.fill && <div style={{ position: 'absolute', left: -grid.padX, right: -grid.padX, top: 0, bottom: 0, background: l.fill }} />}
          {l.bg && <div style={{ position: 'absolute', left: (l.bgFrom ?? 0) * cell, right: 0, top: 0, bottom: 0, background: l.bg }} />}
          {l.box && <BoxRow {...l.box} grid={grid} />}
          <div style={{ position: 'relative' }}>{l.segs.map((s, k) => <Run key={k} text={s.text} style={s.style} cell={cell} />)}</div>
        </div>
      ))}
    </div>
  );
};
