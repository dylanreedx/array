// A tab's terminal: whichever CLI that tab runs, drawn in that CLI's own grammar by the kit (kit/tui).
import { Claude, claudeLines } from '../../kit/tui/claude';
import { Codex, codexLines } from '../../kit/tui/codex';
import { tagRects } from '../../kit/tui/grid';
import { Pi, piLines } from '../../kit/tui/pi';
import { CLAUDE_DARK, CODEX_VESPER, PI_DYLAN } from '../../kit/tui/themes';
import { BODY, GRID, TABS, tabIndex, type TabKey } from './constants';
import { SESSIONS } from './sessions';

/** Claude Code's welcome box shows the full working directory. */
const home = (cwd: string) => `/Users/ana/code/${cwd}`;

export const Terminal: React.FC<{ tab: TabKey; f: number; fps: number }> = ({ tab, f, fps }) => {
  const s = SESSIONS[tab];
  const cwd = TABS[tabIndex(tab)].cwd;
  if (s.cli === 'codex') return <Codex grid={GRID} theme={CODEX_VESPER} session={s} width={BODY.width} height={BODY.height} f={f} fps={fps} />;
  if (s.cli === 'pi') return <Pi grid={GRID} theme={PI_DYLAN} session={s} cwd={cwd} width={BODY.width} height={BODY.height} />;
  return <Claude grid={GRID} theme={CLAUDE_DARK} session={s} cwd={home(cwd)} width={BODY.width} height={BODY.height} f={f} fps={fps} />;
};

/** Where each tagged block of a tab's screen sits (terminal body px): the row morph's sources. */
export const terminalRects = (tab: TabKey, f: number, fps: number) => {
  const s = SESSIONS[tab];
  const cwd = TABS[tabIndex(tab)].cwd;
  const lines = s.cli === 'codex' ? codexLines(GRID, CODEX_VESPER, s, BODY.width, BODY.height, f, fps)
    : s.cli === 'pi' ? piLines(GRID, PI_DYLAN, s, cwd, BODY.width, BODY.height)
    : claudeLines(GRID, CLAUDE_DARK, s, home(cwd), BODY.width, BODY.height, f, fps);
  return tagRects(GRID, lines, BODY.width, BODY.height).rects;
};
