// A real Array menu, redrawn. A popped-up NSMenu is its own window on the real display, so the film
// harness never pops one: production builds the menu, `FilmMenuHost` records its items (frames.json
// `menus`) and fires the chosen item's own action. This draws that recorded menu as macOS draws a
// dark context menu, so the picture shows exactly the items, checkmarks and choice production had.
import { prog, E } from '../../lib/anim';

export type MenuItem = { title?: string; enabled?: boolean; on?: boolean; separator?: boolean; submenu?: MenuItem[] };

const ROW = 22, SEP = 11, PAD = 5, W_MENU = 230, FONT = '13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif';

const height = (items: MenuItem[]) => PAD * 2 + items.reduce((h, i) => h + (i.separator ? SEP : ROW), 0);
const rowTop = (items: MenuItem[], index: number) => PAD + items.slice(0, index).reduce((h, i) => h + (i.separator ? SEP : ROW), 0);

const Panel: React.FC<{ items: MenuItem[]; x: number; y: number; hover: number; flash: boolean }> = ({ items, x, y, hover, flash }) => (
  <div style={{ position: 'absolute', left: x, top: y, width: W_MENU, height: height(items), borderRadius: 10, background: 'rgba(38,38,42,0.94)', boxShadow: '0 0 0 0.5px rgba(255,255,255,0.16) inset, 0 0 0 0.5px rgba(0,0,0,0.6), 0 14px 38px rgba(0,0,0,0.5)', backdropFilter: 'blur(20px)' }}>
    {items.map((item, i) => {
      const top = rowTop(items, i);
      if (item.separator) return <div key={i} style={{ position: 'absolute', left: 14, right: 14, top: top + SEP / 2, height: 1, background: 'rgba(255,255,255,0.12)' }} />;
      const lit = i === hover && !flash;
      const ink = item.enabled === false ? 'rgba(255,255,255,0.32)' : 'rgba(255,255,255,0.92)';
      return (
        <div key={i} style={{ position: 'absolute', left: PAD, right: PAD, top, height: ROW, borderRadius: 5, background: lit ? '#2f6fd8' : 'transparent', color: lit ? '#fff' : ink, font: FONT, display: 'flex', alignItems: 'center' }}>
          <span style={{ width: 22, textAlign: 'center', fontSize: 12 }}>{item.on ? '✓' : ''}</span>
          <span style={{ flex: 1, whiteSpace: 'nowrap' }}>{item.title}</span>
          {item.submenu && <span style={{ paddingRight: 8, fontSize: 11, opacity: 0.8 }}>›</span>}
        </div>
      );
    })}
  </div>
);

/**
 * The recorded menu, opened at `open` (window points `anchor`, scaled by `k` into the frame), with
 * the pointer walking `path` (item titles) at the frames in `hoverAt`, chosen at `choose` (the row
 * flashes, as AppKit's does), gone 8 frames later. Returns the pointer position the glove should
 * take at frame `f` while the menu is up (null when it is not up).
 */
export const menuPointer = (items: MenuItem[], anchor: [number, number], k: number, path: string[], hoverAt: number[], f: number) => {
  let x = anchor[0] * k, y = anchor[1] * k, list = items, at: [number, number] | null = null;
  path.forEach((title, depth) => {
    const index = list.findIndex((i) => i.title === title);
    const target: [number, number] = [x + 90, y + rowTop(list, index) + ROW / 2];
    if (f >= hoverAt[depth]) at = target;
    const next = list[index]?.submenu;
    if (next) { x = x + W_MENU - 4; y = y + rowTop(list, index) - PAD; list = next; }
  });
  return at;
};

export const MacMenu: React.FC<{ items: MenuItem[]; anchor: [number, number]; k: number; f: number; open: number; path: string[]; hoverAt: number[]; choose: number }> = ({ items, anchor, k, f, open, path, hoverAt, choose }) => {
  if (f < open || f > choose + 8) return null;
  const fade = prog(f, open, open + 5, E.out) * (1 - prog(f, choose + 4, choose + 8, E.in));
  const flash = f >= choose && f < choose + 4 && (f - choose) % 4 < 2;
  const panels: React.ReactNode[] = [];
  let x = anchor[0] * k, y = anchor[1] * k, list = items;
  for (let depth = 0; ; depth++) {
    const title = path[depth];
    const hovering = depth < path.length && f >= hoverAt[depth];
    const index = hovering ? list.findIndex((i) => i.title === title) : -1;
    const last = depth === path.length - 1;
    panels.push(<Panel key={depth} items={list} x={x} y={y} hover={index} flash={last && flash} />);
    const next = index >= 0 ? list[index].submenu : undefined;
    if (!next) break;
    x = x + W_MENU - 4; y = y + rowTop(list, index) - PAD; list = next;
  }
  return <div style={{ position: 'absolute', inset: 0, opacity: fade }}>{panels}</div>;
};
