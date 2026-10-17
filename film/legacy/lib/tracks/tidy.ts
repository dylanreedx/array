// Re-creates the website's Tidy motion by frame. On the site, TIDY commits the final layout and a
// CSS transition animates it: `left`/`top` only, 110ms cubic-bezier(0,0,.58,1) (MacWorkspace.module.css
// --mac-reflow), which is the native reflow (CanvasNSView: 0.11s CAMediaTimingFunction(.easeOut)).
// Sizes land at once, and the active tile and the armed zone's members snap.
// The film disables transitions, so this track interpolates the same geometry from the same pure
// helper (tidyLayout) and commits it through website actions (MOVE_ZONE); a TIDY cue at the end can
// land the reducer's own toast and undo snapshot.
import { tidyLayout } from '@website/features/demo/canvasGeometry';
import type { DemoAction, Frame } from '@website/features/demo/types';
import { E, mix } from '../anim';
import type { Track } from '../sheet';

/** The native layout reflow: 110 ms on CSS `ease-out`. Size a tidy cue with `fps * TIDY_SECONDS`. */
export const TIDY_SECONDS = 0.11;
export const TIDY_EASE = E.cssOut;

const lerp = (a: Frame, b: Frame, t: number): Frame => ({ x: mix(a.x, b.x, t), y: mix(a.y, b.y, t), width: mix(a.width, b.width, t), height: mix(a.height, b.height, t) });

// positionsOnly (the native default): sizes land at once and only x/y travel. Pass false only for a
// deliberate film liberty that grows sizes too.
export const tidyTrack = (id: string, from: number, to: number, { ease = TIDY_EASE, positionsOnly = true }: { ease?: Track['ease']; positionsOnly?: boolean } = {}): Track => ({
  id, from, to, ease,
  action: (t, s) => {
    const target = tidyLayout(s.tiles, s.zones);
    const move = (a: Frame, b: Frame) => positionsOnly ? { ...b, x: mix(a.x, b.x, t), y: mix(a.y, b.y, t) } : lerp(a, b, t);
    return Object.values(s.zones).map((z): DemoAction => ({
      type: 'MOVE_ZONE', id: z.id,
      frame: move(z.frame, target.zones[z.id].frame),
      tileFrames: Object.fromEntries(Object.values(s.tiles).filter((tile) => tile.zoneId === z.id).map((tile) => [tile.id, move(tile.frame, target.tiles[tile.id].frame)])),
    }));
  },
});
