// Every output a video can ship in. One composition per (video, format); 4K is the 1080p
// composition rendered with --scale=2 (deviceScaleFactor), so the website's layout and its
// media queries see the same 1920px viewport and nothing reflows.
export const FORMATS = {
  landscape: { width: 1920, height: 1080, fps: 60, label: '16:9' },
  square: { width: 1080, height: 1080, fps: 60, label: '1:1' },
  portrait: { width: 1080, height: 1920, fps: 60, label: '9:16' },
  loop: { width: 1920, height: 1080, fps: 30, label: 'hero loop, silent' },
  loop60: { width: 1920, height: 1080, fps: 60, label: 'hero loop, silent, 60 fps' },
  site: { width: 1920, height: 1080, fps: 30, label: 'website cut, silent, plays once' },
  og: { width: 1200, height: 630, fps: 30, label: 'OG still' },
} as const;

export type FormatId = keyof typeof FORMATS;

/**
 * The stage is the virtual 16:10 desk the Mac workspace is laid out on, in CSS px.
 * The website renders MacWorkspace at min(1380px, ...) x min(810px, ...); the film uses the
 * same 1380x810 window centred on a 1920x1200 stage, and the lens crops the stage to each
 * format by framing subjects (tiles, zones), never by fixed pixel offsets.
 */
export const STAGE = { width: 1920, height: 1200, window: { width: 1380, height: 810 } } as const;
/**
 * The Command Center in a frame (<Film commandCenter="frame"/>): its top sits this fraction of the
 * output height below the frame's top. The website places the panel COMMAND_PANEL_TOP px below its
 * container (CommandCenter.module.css `.panel`: top max(32px, min(10vh, 72px)), 72 at film sizes).
 */
export const FRAME_COMMAND_TOP = 0.06;
export const COMMAND_PANEL_TOP = 72;
/** The Mac window's top-left on the stage (centred). */
export const WINDOW_ORIGIN = { x: (STAGE.width - STAGE.window.width) / 2, y: (STAGE.height - STAGE.window.height) / 2 } as const;

/**
 * The website canvas inside that window (sidebar open), in CSS px, at --scale=1. lib/metrics.ts
 * measures it on every render and warns (the gate fails) if it ever differs; timelines use it to
 * frame the Mac camera on a subject without a browser. It follows MacWorkspace's chrome (the 32px
 * titlebar strip, the 280px sidebar). The layout depends on the render scale, which is why the gate
 * renders at scale 1.
 */
export const MAC_CANVAS = { width: 1098, height: 776 } as const;

/**
 * The caption band a captioned video reserves, in output px. The lens frames every subject in the
 * rest of the frame (Lens `band`), so no UI move ever crosses the caption. Landscape and square keep
 * it at the bottom; portrait puts it at the top, so the tile fills the middle of a phone screen and
 * the feed's own chrome (handle, actions) covers only canvas at the bottom.
 */
export interface Band { edge: 'top' | 'bottom'; size: number }
export const bandOf = ({ width, height }: { width: number; height: number }): Band =>
  height > width ? { edge: 'top', size: Math.round(height * 0.2) }
  : height === width ? { edge: 'bottom', size: Math.round(height * 0.2) }
  : { edge: 'bottom', size: Math.round(height * 0.18) };
