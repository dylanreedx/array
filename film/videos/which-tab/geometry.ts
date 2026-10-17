// UNSTACK's geometry, pure (no React): where every tab's card is at any film frame. Shared by the picture
// (index.tsx) and by the blank-face measurement (scripts that render frames and read each card's face).
import { E, prog } from '../../kit/anim';
import { lerp, lerpRect, type Rect as Frame } from '../../kit/rect';
import { GHOSTTY, K, LANDING, TABS, TAB_H, TITLE_H, WINDOW, tabIndex, type TabKey } from './constants';
import { PULLBACK, tileRadius } from './footage';
import { BAR_W, DOT, TAB_FONT, WINDOW_BAR, tabLayout, type Bar } from './Ghostty';
import type { Plan } from './timeline';

export { lerp, lerpRect };

/**
 * Round 4, jitter: the window no longer drifts. A 1.8 % scale creep (0.04 px/frame) was snapped to whole
 * pixels by layout (the chrome stepped 1 px every ~24 frames) and re-rasterised every glyph at a new scale
 * each frame (text shimmered ±0.4-0.9 px). Held things now hold still, on whole pixels.
 */
export const WIN: Frame = { x: WINDOW.x, y: WINDOW.y, width: WINDOW.width, height: WINDOW.height };

// ---- UNSTACK geometry ------------------------------------------------------------------------------
/** The front window steps back to FAN_SCALE about this centre; the others fan round a pivot below it. */
export const FAN_SCALE = 0.62;
const FAN_CENTRE = { x: 960, y: 640 };
const FAN_PIVOT = 1900; // px below the centre: a shallow hand of cards
const FAN_STEP = 3.4; // degrees per tab away from the front one
/**
 * Round 5: each window behind the front one sits FAN_RAISE px higher per tab of distance, so every title bar
 * clears the front window's top edge and every tab can be followed from bar to window to tile (in r4 Dark mode
 * and Subscriptions unfurled straight behind Cart total and vanished).
 */
const FAN_RAISE = 54;
const fanFront: Frame = { x: FAN_CENTRE.x - (WINDOW.width * FAN_SCALE) / 2, y: FAN_CENTRE.y - (WINDOW.height * FAN_SCALE) / 2, width: WINDOW.width * FAN_SCALE, height: WINDOW.height * FAN_SCALE };
const fanAngle = (key: TabKey) => (tabIndex(key) - tabIndex(LANDING)) * FAN_STEP;
const fanSlot = (key: TabKey): Frame => {
  const rad = (fanAngle(key) * Math.PI) / 180;
  return { ...fanFront, x: fanFront.x + FAN_PIVOT * Math.sin(rad), y: fanFront.y + FAN_PIVOT * (1 - Math.cos(rad)) - FAN_RAISE * Math.abs(tabIndex(key) - tabIndex(LANDING)) };
};
const PILL_LIFT = 14; // px a tab rises as it comes off the bar

/** The width a title's dot (or icon) slot takes at this font size: the dot plus its gap. */
export const iconBoxFor = (font: number) => DOT * (font / TAB_FONT) + font * 0.42;
const n0 = (v: number | undefined) => v ?? 0;
export const lerpBar = (a: Bar, b: Bar, t: number): Bar => ({ h: lerp(a.h, b.h, t), font: lerp(a.font, b.font, t), lights: lerp(a.lights, b.lights, t), radius: lerp(a.radius, b.radius, t),
  color: t <= 0 ? a.color : t >= 1 ? b.color : `color-mix(in srgb, ${a.color}, ${b.color} ${Math.round(t * 100)}%)`, bg: t <= 0 ? a.bg : t >= 1 ? b.bg : `color-mix(in srgb, ${a.bg}, ${b.bg} ${Math.round(t * 100)}%)`,
  anchor: lerp(n0(a.anchor), n0(b.anchor), t), padL: lerp(n0(a.padL), n0(b.padL), t), grow: lerp(n0(a.grow), n0(b.grow), t), iconAlpha: lerp(n0(a.iconAlpha), n0(b.iconAlpha), t),
  iconBox: lerp(a.iconBox ?? iconBoxFor(a.font), b.iconBox ?? iconBoxFor(b.font), t) });
const PILL_BAR: Bar = { h: TAB_H, font: TAB_FONT, lights: 0, color: GHOSTTY.tabText, bg: GHOSTTY.tabBar, radius: 0 };
const PILL_UP: Bar = { ...PILL_BAR, color: GHOSTTY.tabTextActive, bg: '#191919', radius: 9 };
export const FAN_BAR: Bar = { h: TITLE_H * FAN_SCALE, font: 13 * K * FAN_SCALE, lights: 1, color: GHOSTTY.tabTextActive, bg: GHOSTTY.bg, radius: 10 * K * FAN_SCALE };

/**
 * The tile's own header, measured off the take (01-pullback frame 30, Cart total at 2266x2000 take px):
 * 79 px tall on #1B212A, the provider mark from x 27, "Agent · Name" from x 87 in 41 px semibold, corner 23.
 * As fractions of the tile, so it fits the tile at any zoom.
 */
export const TILE = {
  header: 79 / 2000, font: 41 / 2000, iconX: 27 / 2266, textX: 87 / 2266,
  headerBg: '#1B212A', bodyBg: '#12151B', text: 'rgb(242,244,248)',
  /** the footer panel: the tile's "roast-web" row, composer and model bar */
  composer: { x: 0, y: 0.78, width: 1, height: 0.22 },
};
export const tileBar = (t: Frame): Bar => ({ h: TILE.header * t.height, font: TILE.font * t.height, lights: 0, color: TILE.text, bg: TILE.headerBg, radius: tileRadius(t),
  anchor: 1, padL: TILE.iconX * t.width, iconBox: (TILE.textX - TILE.iconX) * t.width, grow: 1, iconAlpha: 1 });

/**
 * Cart total's rows (round 5). Spinner -> the whole title block (so the top of the tile is never empty).: each tagged block of its claude screen and the region of the tile it becomes,
 * measured off the take (frame 30) as fractions of the tile. "Update(path) +a −d" -> its CHANGES card, prose
 * -> prose, "Bash(npm test -- cart)" -> "Run the cart tests", the spinner -> the "Working · 21m" status, the
 * prompt box -> the composer, the "? for shortcuts" hint -> the model bar (Claude Code · Opus 5.5 · Medium).
 */
export const CART_ROWS: { tag: string; to: Frame }[] = [
  { tag: 'say:rounded', to: { x: 0.0177, y: 0.064, width: 0.9647, height: 0.02 } },
  { tag: 'edit:total', to: { x: 0.0177, y: 0.1675, width: 0.9647, height: 0.112 } },
  { tag: 'edit:test', to: { x: 0.0177, y: 0.294, width: 0.9647, height: 0.112 } },
  { tag: 'say:summary', to: { x: 0.0177, y: 0.4065, width: 0.9647, height: 0.057 } },
  { tag: 'edit:summary', to: { x: 0.0177, y: 0.464, width: 0.9647, height: 0.112 } },
  { tag: 'edit:format', to: { x: 0.0177, y: 0.5905, width: 0.9647, height: 0.112 } },
  { tag: 'run:tests', to: { x: 0.0177, y: 0.703, width: 0.9647, height: 0.077 } },
  { tag: 'spinner', to: { x: 0, y: 0.0395, width: 1, height: 0.128 } }, // the tile's title block: name, "Working · 21m", branch
  { tag: 'prompt', to: { x: 0, y: 0.78, width: 1, height: 0.1385 } }, // the footer panel: "roast-web" row and the composer
  { tag: 'hint', to: { x: 0.0177, y: 0.9345, width: 0.9647, height: 0.052 } },
];

/** Where a tab's card is at film frame f: rect, rotation, title bar, body top, flight progress, and whether it is a pill above the front. */
export const cardAt = (P: Plan, key: TabKey, f: number, fps: number, toOut: (r: Frame) => Frame) => {
  const S = P.seam;
  const flight = S.flights.find((x) => x.key === key)!;
  let pre: Frame, rot = 0, bar: Bar, bodyTop: number, above = false;
  if (key === LANDING) {
    // the front window steps back, leaving its tabs hanging where they were
    const step = prog(f, S.fan, S.fan + S.fanDur, E.smooth);
    pre = lerpRect(WIN, fanFront, step);
    bar = lerpBar(WINDOW_BAR, FAN_BAR, step);
    bodyTop = lerp(TITLE_H + TAB_H, FAN_BAR.h, step);
  } else {
    // its tab lifts off the bar, then unfurls into its window, the pill becoming the title bar
    const rects = tabLayout(TABS.map(() => 1), BAR_W);
    const r = rects[tabIndex(key)];
    const lift = prog(f, S.pillLift, S.pillLift + S.pillLiftDur, E.smooth);
    const pill: Frame = { x: WIN.x + r.x, y: WIN.y + TITLE_H - PILL_LIFT * lift, width: r.width, height: TAB_H };
    const u = prog(f, S.unfurl + flight.order * S.unfurlStagger, S.unfurl + flight.order * S.unfurlStagger + S.unfurlDur, E.smooth);
    pre = lerpRect(pill, fanSlot(key), u);
    rot = fanAngle(key) * u;
    bar = u > 0 ? lerpBar(PILL_UP, FAN_BAR, u) : lerpBar(PILL_BAR, PILL_UP, lift);
    bodyTop = bar.h;
    above = u < 0.12;
  }
  // the flight: toward where its tile will be when it lands, then onto the tile itself as it arrives
  const e = prog(f, flight.start, flight.land, E.smooth);
  if (e <= 0) return { rect: pre, rot, e, bar, bodyTop, above };
  const landRect = toOut(PULLBACK.tileOf(key, P.takeAt(flight.land)));
  const nowRect = toOut(PULLBACK.tileOf(key, P.takeAt(f)));
  return { rect: lerpRect(pre, lerpRect(landRect, nowRect, e), e), rot: rot * (1 - e), e, bar, bodyTop, above: false };
};

