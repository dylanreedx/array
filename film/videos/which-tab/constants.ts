// "Which tab was that?": every name and number the picture shares with the real canvas, in one place.
// The tabs ARE the tiles (research/21-which-tab/brief.md): a tab's title must match its agent tile's
// title on the canvas exactly, so when the footage take lands, edit TABS here and nothing else.

import type { Grid } from '../../kit/tui/grid';
import { inkLime } from '../../looks/ink-lime/look';

/** Film palette: the ink-lime look (looks/ink-lime). ONE accent: lime means "finished" and nothing else. */
export const LOOK = inkLime;
export const INK = inkLime.color.ground;
export const PAPER = inkLime.color.text;
export const PAPER_DIM = inkLime.color.textDim;
export const LIME = inkLime.color.accent;

/**
 * Ghostty, Vesper theme (Dylan's own ~/.config/ghostty theme: background #101010, foreground #ffffff,
 * palette 2 #99ffe4, 3 #d6b36a). The tab bar is macOS's native one, tinted from that background.
 */
export const GHOSTTY = {
  bg: '#101010',
  fg: '#ffffff',
  tabBar: '#0a0a0a',
  tabSeparator: 'rgba(255,255,255,0.075)',
  tabText: 'rgba(255,255,255,0.46)',
  tabTextActive: 'rgba(255,255,255,0.92)',
  titleText: 'rgba(255,255,255,0.55)',
  border: 'rgba(255,255,255,0.13)',
} as const;

/**
 * Tab status dots (round 4; terminals don't do this, the film does): working is a quiet paper spinner,
 * needs-input amber, failed red, done lime. Lime still means finished and nothing else.
 */
export type Status = 'working' | 'input' | 'failed' | 'done';
export const STATUS_COLOR: Record<Status, string> = {
  working: 'rgba(242,240,233,0.62)',
  input: '#F0A53A',
  failed: '#EF5B4F',
  done: LIME,
};

/**
 * The six tabs, left to right: the six agent tiles on the footage take's canvas, in canvas order
 * (Storefront zone, then Roast API), titles verbatim (.plans/68-launch-film/which-tab-r0/footage/notes.md).
 * The hunt starts on tab 0, cycles right with ⌘⇧] (wrapping once) and lands on the LANDING tab, whose
 * window becomes that agent's tile in the take; that agent then finishes live on the canvas.
 */
export const TABS = [
  { key: 'picker', title: 'Plan picker', cwd: 'roast-web', cli: 'codex' },
  { key: 'dark', title: 'Dark mode', cwd: 'roast-web', cli: 'pi' },
  { key: 'cart', title: 'Cart total', cwd: 'roast-web', cli: 'claude' },
  { key: 'subs', title: 'Subscriptions', cwd: 'roast-api', cli: 'claude' },
  { key: 'emails', title: 'Renewal emails', cwd: 'roast-api', cli: 'pi' },
  { key: 'export', title: 'Order export', cwd: 'roast-api', cli: 'codex' },
] as const;
export type TabKey = (typeof TABS)[number]['key'];
export const LANDING: TabKey = 'cart';
export const tabIndex = (k: TabKey) => TABS.findIndex((t) => t.key === k);
/**
 * S5's finish mark. 'ring' draws a lime ring and a "Cart total · done" tag over the take; 'none' leaves the
 * app's own finish state to speak (the recapture shows Array's real marching-ants border at the finish:
 * set 'none' then, and never fake the ants).
 */
export const FINISH_MARK: 'ring' | 'none' = 'none';

/** Words on screen (also the SRT). */
export const COPY = {
  hook: 'Which tab was that?',
  beat: 'Your agents are hiding in tabs.',
  payoff: 'Keep every agent in view.',
  url: 'arrayapp.dev',
} as const;

/** Output layout at 1920x1080 (4K is the same layout at --scale=2). k = output px per macOS point. */
export const K = 1.4;
export const WINDOW = { x: 120, y: 232, width: 1680, height: 788 } as const;
export const TITLE_H = Math.round(28 * K);
export const TAB_H = Math.round(26 * K);
/** The terminal grid: JetBrains Mono (Ghostty's default face) at 18/22 px. */
export const GRID: Grid = { font: 18, line: 22, padX: Math.round(8 * K), padY: Math.round(6 * K), family: inkLime.type.mono, advance: 0.6 };
/** The body (terminal surface) inside the window: what shrinks onto the tile in S4. */
export const BODY = { x: WINDOW.x, y: WINDOW.y + TITLE_H + TAB_H, width: WINDOW.width, height: WINDOW.height - TITLE_H - TAB_H } as const;
/** The headline slot: left edge on the window's, baseline just above it, where the eye enters the frame. */
export const HEADLINE = { x: WINDOW.x - 4, baseline: 176, size: 84 } as const;
