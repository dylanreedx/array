// Ghostty on macOS, `macos-titlebar-style = transparent` (its default): the title bar takes the terminal's
// background, the native tab bar sits under it, each tab showing its title and its ⌘N key equivalent (and,
// in this film, a status dot). Drawn at K output px per point.
//
// Round 4, jitter: every tab edge, the selection and every card that is not in flight sit on WHOLE pixels.
// Fractional edges rounded independently made a centred label step backwards while its tab only shrank.
import { E, prog } from '../../kit/anim';
import { GHOSTTY, K, TABS, TAB_H, TITLE_H, WINDOW, type TabKey } from './constants';
import { staticFile } from 'remotion';
import { SYSTEM } from './fonts';

const lerpN = (a: number, b: number, t: number) => a * (1 - t) + b * t;

export interface TabState {
  /** 0..1 per tab: how far it has joined the bar (its share of the width) */
  weight: number[];
  /** fractional index of the selected tab (moves between tabs during a switch) */
  active: number;
}

/**
 * Tab rects (x, width) along the bar. Edges are rounded once each (neighbours share an edge) to EVEN
 * pixels: a centred label then always sits on the same sub-pixel phase, so as a tab narrows its label steps
 * by whole pixels instead of flickering between x.0 and x.5 antialiasing (measured: +1.1 px reversals).
 */
export const tabLayout = (weight: number[], barWidth: number) => {
  const total = weight.reduce((a, b) => a + b, 0) || 1;
  const edges = [0];
  let acc = 0;
  for (const w of weight) { acc += w; edges.push(2 * Math.round((barWidth * acc) / total / 2)); }
  return weight.map((_, i) => ({ x: edges[i], width: edges[i + 1] - edges[i] }));
};
export const PLUS_W = Math.round(28 * K);
export const BAR_W = WINDOW.width - PLUS_W;
export const TAB_FONT = 11.5 * K;
export const DOT = Math.round(7.5 * K);

/**
 * One tab's label: status dot, then the name. Shared by the bar, by a detached pill, and (round 5) by a card's
 * title bar on its way to becoming the tile's header: `icon` (the provider's mark) crossfades in over the dot
 * by `iconAlpha`, and `prefix` ("Agent · ") opens in front of the name by `grow`, so the title is one label
 * the whole way (the r2 lesson: never two texts at once).
 */
export const TabLabel: React.FC<{ title: string; dot: React.ReactNode; font: number; color: string; weight: number; icon?: React.ReactNode; iconAlpha?: number; iconBox?: number; prefix?: string; grow?: number }> =
  ({ title, dot, font, color, weight, icon, iconAlpha = 0, iconBox, prefix, grow = 0 }) => (
  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: iconBox === undefined ? font * 0.42 : 0, font: `${weight} ${font}px ${SYSTEM}`, color, whiteSpace: 'nowrap', letterSpacing: '-0.005em' }}>
    <span style={{ position: 'relative', display: 'inline-flex', alignItems: 'center', width: iconBox, flex: 'none' }}>
      <span style={{ display: 'inline-flex', opacity: 1 - iconAlpha }}>{dot}</span>
      {icon && iconAlpha > 0 && <span style={{ position: 'absolute', left: 0, top: '50%', transform: 'translateY(-50%)', display: 'inline-flex', opacity: iconAlpha }}>{icon}</span>}
    </span>
    {prefix && grow > 0 && <span style={{ display: 'inline-block', overflow: 'hidden', maxWidth: `${grow * 4.4}em`, opacity: grow, whiteSpace: 'pre' }}>{prefix}</span>}
    <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
  </div>
);

/** A provider's mark (website/public/provider-*.svg), drawn in the label's colour. */
export const ProviderMark: React.FC<{ provider: 'anthropic' | 'openai'; size: number; color: string }> = ({ provider, size, color }) => (
  <span style={{ display: 'inline-block', width: size, height: size, background: color, WebkitMaskImage: `url(${staticFile(`marks/provider-${provider}.svg`)})`, WebkitMaskSize: 'contain', WebkitMaskRepeat: 'no-repeat', WebkitMaskPosition: 'center' }} />
);

/** The native tab bar, under the title bar. `hidden` tabs have detached (S4); `fade` clears the bar itself. */
export const TabBar: React.FC<{ tabs: TabState; dots: (k: TabKey) => React.ReactNode; fade: number; hidden?: (k: TabKey) => boolean; left?: number; top?: number }> = ({ tabs, dots, fade, hidden, left = 0, top = TITLE_H }) => {
  const rects = tabLayout(tabs.weight, BAR_W);
  const lo = Math.floor(tabs.active), hi = Math.min(TABS.length - 1, lo + 1), fr = tabs.active - lo;
  const sel = { x: Math.round(rects[lo].x * (1 - fr) + rects[hi].x * fr), width: Math.round(rects[lo].width * (1 - fr) + rects[hi].width * fr) };
  if (fade <= 0 && hidden) return null;
  return (
    <div style={{ position: 'absolute', left, top, width: WINDOW.width, height: TAB_H }}>
      <div style={{ position: 'absolute', inset: 0, background: GHOSTTY.tabBar, opacity: fade, boxShadow: 'inset 0 1px 0 rgba(0,0,0,0.6), inset 0 -1px 0 rgba(0,0,0,0.5)' }}>
        <div style={{ position: 'absolute', left: sel.x, width: sel.width, top: 0, height: TAB_H, background: GHOSTTY.bg }} />
        <div style={{ position: 'absolute', right: 0, top: 0, width: PLUS_W, height: TAB_H, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'rgba(255,255,255,0.4)', font: `300 ${16 * K}px ${SYSTEM}`, boxShadow: `inset 1px 0 0 ${GHOSTTY.tabSeparator}` }}>+</div>
      </div>
      {TABS.map((t, i) => {
        const r = rects[i];
        const w = tabs.weight[i];
        if (w <= 0.001 || hidden?.(t.key)) return null;
        const on = Math.max(0, 1 - Math.abs(tabs.active - i));
        const show = prog(w, 0.45, 1, E.linear);
        const nextOn = Math.max(0, 1 - Math.abs(tabs.active - (i + 1)));
        const sepAlpha = Math.max(0, 1 - on - nextOn);
        return (
          <div key={t.key} style={{ position: 'absolute', left: r.x, width: r.width, top: 0, height: TAB_H, overflow: 'hidden', opacity: hidden ? fade : 1 }}>
            {i < TABS.length - 1 && <div style={{ position: 'absolute', right: 0, top: 7 * K, bottom: 7 * K, width: 1, background: GHOSTTY.tabSeparator, opacity: sepAlpha * show }} />}
            <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: `0 ${30 * K}px`, opacity: show }}>
              <TabLabel title={t.title} dot={dots(t.key)} font={TAB_FONT} color={on > 0.5 ? GHOSTTY.tabTextActive : GHOSTTY.tabText} weight={on > 0.5 ? 500 : 400} />
            </div>
            <div style={{ position: 'absolute', right: 9 * K, top: 0, height: TAB_H, display: 'flex', alignItems: 'center', font: `400 ${10.5 * K}px ${SYSTEM}`, color: 'rgba(255,255,255,0.26)', opacity: show }}>⌘{i + 1}</div>
          </div>
        );
      })}
    </div>
  );
};

/**
 * A card's title bar, in output px: a tab pill at its smallest, a Ghostty title bar, and (round 5) the tile's
 * own header: `anchor` 0 centres the label, 1 sets it at `padL` from the left; `iconBox` reserves the icon's
 * width; `grow` opens the "Agent · " prefix; `iconAlpha` swaps the status dot for the provider's mark.
 */
export interface Bar { h: number; font: number; lights: number; color: string; bg: string; radius: number; anchor?: number; padL?: number; iconBox?: number; grow?: number; iconAlpha?: number }

/**
 * One Ghostty window as a card (UNSTACK). The body is laid out at the window's own size and scaled uniformly
 * into the rect (no reflow), starting `bodyTop` output px down; the title bar is drawn at output size so a
 * card can begin as a 36 px tab pill (its title bar IS the pill) and grow into a window. `face` is the real
 * tile it becomes; `blur` is directional motion blur in output px from its velocity relative to its tile;
 * `rest` 0 -> 1 trades window chrome for the tile's.
 */
export const Card: React.FC<{ id: string; rect: { x: number; y: number; width: number; height: number }; rot?: number; title: string; dot?: React.ReactNode; bar: Bar; bodyTop: number;
  content: React.ReactNode; children?: React.ReactNode; face?: React.ReactNode; faceAlpha?: number; blur?: { x: number; y: number }; rest?: number; tileRadius?: number; shadow?: number;
  bg?: string; contentAlpha?: number; icon?: React.ReactNode; prefix?: string }> =
  ({ id, rect, rot = 0, title, dot, bar, bodyTop, content, children, face, faceAlpha = 0, blur, rest = 0, tileRadius = 0, shadow = 1, bg = GHOSTTY.bg, contentAlpha = 1, icon, prefix }) => {
  const sc = rect.width / WINDOW.width;
  const radius = bar.radius * (1 - rest) + tileRadius * rest;
  const d = 12 * K * (bar.h / TITLE_H);
  const bx = blur?.x ?? 0, by = blur?.y ?? 0;
  const blurred = bx > 0.3 || by > 0.3;
  const sh = shadow * (1 - rest);
  return (
    <div style={{ position: 'absolute', left: rect.x, top: rect.y, width: rect.width, height: rect.height, transform: rot ? `rotate(${rot}deg)` : undefined,
      filter: blurred ? `url(#card-blur-${id})` : undefined }}>
      {blurred && <svg width="0" height="0" style={{ position: 'absolute' }}><filter id={`card-blur-${id}`} x="-20%" y="-20%" width="140%" height="140%" colorInterpolationFilters="sRGB"><feGaussianBlur stdDeviation={`${bx} ${by}`} /></filter></svg>}
      <div style={{ position: 'absolute', inset: 0, borderRadius: radius, overflow: 'hidden', background: bg,
        boxShadow: `0 0 0 1px rgba(0,0,0,${0.85 * sh}), 0 ${24 * K * sc}px ${60 * K * sc}px rgba(0,0,0,${0.55 * sh}), 0 ${6 * K * sc}px ${16 * K * sc}px rgba(0,0,0,${0.35 * sh})` }}>
        {faceAlpha < 1 && (
          <div style={{ position: 'absolute', inset: 0, opacity: 1 - faceAlpha }}>
            {contentAlpha > 0 && <div style={{ position: 'absolute', left: 0, top: bodyTop, width: WINDOW.width, height: WINDOW.height - TITLE_H - TAB_H, transform: `scale(${sc})`, transformOrigin: '0 0', overflow: 'hidden', opacity: contentAlpha }}>{content}</div>}
            <div style={{ position: 'absolute', left: 0, top: 0, width: '100%', height: bar.h, background: bar.bg }}>
              {bar.lights > 0 && (
                <div style={{ position: 'absolute', left: 14 * K * (bar.h / TITLE_H), top: (bar.h - d) / 2, display: 'flex', gap: 8 * K * (bar.h / TITLE_H), opacity: bar.lights }}>
                  {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => <div key={c} style={{ width: d, height: d, borderRadius: '50%', background: c, boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.28)' }} />)}
                </div>
              )}
              <div style={{ position: 'absolute', top: 0, height: bar.h, display: 'flex', alignItems: 'center',
                left: (bar.anchor ?? 0) > 0 ? lerpN(rect.width / 2, bar.padL ?? 0, bar.anchor ?? 0) : rect.width / 2, transform: `translateX(${-50 * (1 - (bar.anchor ?? 0))}%)` }}>
                <TabLabel title={title} dot={dot} font={bar.font} color={bar.color} weight={600} icon={icon} iconAlpha={bar.iconAlpha} iconBox={bar.iconBox} prefix={prefix} grow={bar.grow} />
              </div>
            </div>
            {children}
          </div>
        )}
        {faceAlpha > 0 && face && <div style={{ position: 'absolute', inset: 0, opacity: faceAlpha }}>{face}</div>}
        <div style={{ position: 'absolute', inset: 0, borderRadius: radius, boxShadow: `inset 0 0 0 1px ${GHOSTTY.border}`, opacity: 1 - rest, pointerEvents: 'none' }} />
      </div>
    </div>
  );
};

/** The window's own title bar look (S1-S3). */
export const WINDOW_BAR: Bar = { h: TITLE_H, font: 13 * K, lights: 1, color: GHOSTTY.titleText, bg: GHOSTTY.bg, radius: 10 * K };
