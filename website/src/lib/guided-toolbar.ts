import type { GuidedInsert } from './guided-timeline';

// A port of the app's in-canvas creation toolbar (FloatingToolbar.swift): one
// capsule resting centred on a canvas edge, icon-only buttons in three groups,
// a label pill beside the hovered button, a choices menu beside the bar. The
// bar is drawn from a PIVOT (the point the hand holds) and an ANGLE (0 lying on
// the bottom edge, 90° standing on a side), exactly as the app draws it, so the
// capsule and its icons cannot disagree while it swings.
export type ToolbarItemId = 'zone' | 'agent' | 'terminal' | 'note' | 'board' | 'browser' | 'editor' | 'fileTree' | 'diff';
export const TOOLBAR_ITEMS: ReadonlyArray<{ id: ToolbarItemId; title: string; shortcut?: string; group: number; choices?: boolean }> = [
  { id: 'zone', title: 'Zone', group: 0 },
  { id: 'agent', title: 'Agent', shortcut: '⌘N', group: 1, choices: true },
  { id: 'terminal', title: 'Terminal', shortcut: '⌘T', group: 1, choices: true },
  { id: 'note', title: 'Note', shortcut: '⇧⌘N', group: 2 },
  { id: 'board', title: 'Board', group: 2 },
  { id: 'browser', title: 'Browser', group: 2 },
  { id: 'editor', title: 'Editor', group: 2 },
  { id: 'fileTree', title: 'File Tree', group: 2 },
  { id: 'diff', title: 'Diff', group: 2 },
];
export const TOOLBAR_MENUS = {
  agent: { title: 'Start an agent', rows: ['Claude Code', 'Codex', 'Pi', 'Fan Out Selected Tickets…'] },
  terminal: { title: 'New terminal', rows: ['Shell', 'Claude CLI', 'Codex CLI', 'Neovim'] },
} as const;
export const TOOLBAR = { thickness: 44, button: 36, inset: 4, spacing: 2, divider: 13, margin: 12, beside: 8, turnBand: 140 } as const;

/** Each button's centre along the bar, from its leading end, and the bar's length. */
export const TOOLBAR_LAYOUT = (() => {
  const centers = {} as Record<ToolbarItemId, number>;
  let cursor = TOOLBAR.inset, last: number | null = null, first = true;
  for (const item of TOOLBAR_ITEMS) {
    if (last !== null && last !== item.group) { cursor += TOOLBAR.spacing + TOOLBAR.divider; }
    if (!first) cursor += TOOLBAR.spacing;
    centers[item.id] = cursor + TOOLBAR.button / 2;
    cursor += TOOLBAR.button;
    last = item.group; first = false;
  }
  return { centers, length: cursor + TOOLBAR.inset };
})();

type Point = { x: number; y: number };
export type ToolbarEdge = 'bottom' | 'left';
export interface ToolbarSnapshot {
  /** The capsule's centre in canvas pixels, its angle in degrees, its scale. */
  x: number; y: number; angle: number; scale: number;
  edge: ToolbarEdge;
  hovered: ToolbarItemId | null;
  active: ToolbarItemId | null;
  pill: ToolbarItemId | null;
  menu: { kind: keyof typeof TOOLBAR_MENUS; open: boolean; highlighted: string | null } | null;
  dragging: boolean;
  /** How much the bar sits on the bottom edge (1) rather than a side (0). */
  bottomness: number;
}

const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));
const between = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
const smooth = (p: number) => p * p * (3 - 2 * p);
const mix = (a: number, b: number, p: number) => a + (b - a) * p;

/** The app's damped springs, solved in closed form so any scroll seek lands on the same frame. */
export function spring(elapsed: number, response: number, damping: number) {
  if (elapsed <= 0) return 0;
  const omega = 2 * Math.PI / response, decay = damping * omega, wd = omega * Math.sqrt(1 - damping * damping);
  return 1 - Math.exp(-decay * elapsed) * (Math.cos(wd * elapsed) + decay / wd * Math.sin(wd * elapsed));
}
const LANDING = { response: .38, damping: .74 }, SWING = { response: .34, damping: .86 };
/** Seconds of spring motion per unit of the beat's own clock. */
const SECONDS = 3.2;

export const toolbarScale = (width: number) => width < 700 ? .8 : 1;

function restCenter(edge: ToolbarEdge, width: number, height: number, scale: number): Point {
  const half = TOOLBAR.thickness * scale / 2;
  return edge === 'bottom' ? { x: width / 2, y: height - TOOLBAR.margin - half } : { x: TOOLBAR.margin + half, y: height / 2 };
}
/** A point on the bar's centre line `along` pixels from its leading end. */
function pointOnBar(center: Point, angle: number, scale: number, along: number): Point {
  const r = angle * Math.PI / 180, offset = (along - TOOLBAR_LAYOUT.length / 2) * scale;
  return { x: center.x + Math.cos(r) * offset, y: center.y + Math.sin(r) * offset };
}
function centerHolding(pivot: Point, angle: number, scale: number, along: number): Point {
  const r = angle * Math.PI / 180, offset = (along - TOOLBAR_LAYOUT.length / 2) * scale;
  return { x: pivot.x - Math.cos(r) * offset, y: pivot.y - Math.sin(r) * offset };
}

// The toolbar beat, on its own clock: hover three buttons, press Terminal,
// drag the bar to the left edge, let go.
export const TOOLBAR_TOUR = { zone: [.09, .20], agent: [.24, .34], terminal: [.38, .52], press: .50, drag: [.52, .80] } as const;
const GRAB: ToolbarItemId = 'terminal';

function dragPath(width: number, height: number, scale: number) {
  const from = pointOnBar(restCenter('bottom', width, height, scale), 0, scale, TOOLBAR_LAYOUT.centers[GRAB]);
  const rest = pointOnBar(restCenter('left', width, height, scale), 90, scale, TOOLBAR_LAYOUT.centers[GRAB]);
  // Let go a little short of the edge, so the landing spring visibly carries it home.
  const to = { x: rest.x + Math.min(64, width * .08), y: rest.y + 22 };
  const at = (u: number): Point => {
    const e = 1 - Math.pow(1 - u, 2.2), lift = Math.sin(Math.PI * u) * Math.min(90, height * .1);
    return { x: mix(from.x, to.x, e), y: mix(from.y, to.y, e) - lift };
  };
  return { from, to, rest, at };
}
/** The app's turn rule: the hand is on the left side of the canvas diagonals and within the turn band. */
function turnsLeft(point: Point, width: number, height: number) {
  const x = point.x / width, y = point.y / height;
  return x < Math.min(1 - y, y, 1 - x) && point.x < TOOLBAR.turnBand;
}

/** Where the hand let go of the bar: the cursor rests here after the toolbar beat. */
export function toolbarReleasePoint(width: number, height: number): Point {
  return dragPath(width, height, toolbarScale(width)).to;
}

export function toolbarSnapshot(progress: number, insert: GuidedInsert | null, width: number, height: number): ToolbarSnapshot {
  const scale = toolbarScale(width);
  const resting = (edge: ToolbarEdge): ToolbarSnapshot => ({ ...restCenter(edge, width, height, scale), angle: edge === 'bottom' ? 0 : 90, scale, edge,
    hovered: null, active: null, pill: null, menu: null, dragging: false, bottomness: edge === 'bottom' ? 1 : 0 });
  if (insert?.id === 'toolbar') {
    const t = insert.t, tour = TOOLBAR_TOUR;
    const hovered = (['zone', 'agent', 'terminal'] as const).find(id => t >= tour[id][0] && t < tour[id][1]) ?? null;
    if (t < tour.drag[0]) return { ...resting('bottom'), hovered, pill: hovered && t < tour.press ? hovered : null };
    const path = dragPath(width, height, scale);
    const along = (u: number) => path.at(smooth(u) * .15 + u * .85);
    // Find when the hand entered the turn band; the swing runs from there.
    let enter = -1;
    for (let i = 0; i <= 80; i++) { if (turnsLeft(along(i / 80), width, height)) { enter = i / 80; break; } }
    const enterT = enter < 0 ? 1 : mix(tour.drag[0], tour.drag[1], enter);
    const angle = 90 * spring((t - enterT) * SECONDS, SWING.response, SWING.damping);
    const pivot = t < tour.drag[1] ? along(between(t, tour.drag[0], tour.drag[1]))
      : { x: mix(path.to.x, path.rest.x, spring((t - tour.drag[1]) * SECONDS, LANDING.response, LANDING.damping)),
          y: mix(path.to.y, path.rest.y, spring((t - tour.drag[1]) * SECONDS, LANDING.response, LANDING.damping)) };
    const center = centerHolding(pivot, angle, scale, TOOLBAR_LAYOUT.centers[GRAB]);
    return { ...center, angle, scale, edge: angle > 45 ? 'left' : 'bottom', hovered: null, active: null, pill: null, menu: null,
      dragging: t < tour.drag[1], bottomness: clamp(1 - angle / 90) * (1 - between(t, tour.drag[0], tour.drag[0] + .08)) };
  }
  if (progress < .27) return resting('bottom');
  const settled = resting('left');
  if (insert?.id === 'terminal') {
    const t = insert.t;
    const open = t >= .27 && t < .62;
    return { ...settled, hovered: t >= .2 && t < .62 ? 'terminal' : null, active: open ? 'terminal' : null,
      pill: t >= .2 && t < .27 ? 'terminal' : null,
      menu: t >= .27 ? { kind: 'terminal', open, highlighted: t >= .48 && t < .62 ? 'Shell' : null } : null };
  }
  // The closed menu stays laid out (hidden) just after the beat, so the hand
  // can travel on from the row it chose.
  if (progress >= .815 && progress < .83) return { ...settled, menu: { kind: 'terminal', open: false, highlighted: null } };
  return settled;
}
