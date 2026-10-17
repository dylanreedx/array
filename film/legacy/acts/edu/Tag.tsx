// The narration, pinned to what it is about: a tag on the edge of a tile (lines with place: 'tile'),
// so the eye lands on the tile the line names instead of chasing the cursor. One tag per beat, STATIC
// for its whole life: its anchor is read once from the tile's rect at the line's first frame and only
// carried by the video's map (so a punch-in moves it with the footage), never re-followed. The pill is
// the cursor bubble's (Pill.tsx) plus a small rounded notch on the side facing the tile.
import { useVideoConfig } from 'remotion';
import { E, prog, springAt } from '../../lib/anim';
import { rectAt, type PointerTrack } from '../../lib/pointer';
import type { Line, LinePin } from '../../lib/sheet';
import { lineText } from './Icon';
import { EXIT_S, measure, pillHighlight, pillMetrics, pillShadow, POP, RISE, TONES, Words } from './Pill';

/** How deep the tag hangs inside the tile for side 'inside-top' (window points below its top edge). */
const INSIDE = 6;

/**
 * The anchor on the tile's edge, in window points, for a rect [x, y, w, h]: the edge's start corner,
 * midpoint or end corner. A start/end tag sits flush with that corner; a centred one centres on it.
 */
const anchorOf = ([x, y, w, h]: [number, number, number, number], pin: LinePin) => {
  const side = pin.side ?? 'top', align = pin.align ?? 'start';
  const along = (a: number, len: number) => (align === 'start' ? a : align === 'end' ? a + len : a + len / 2);
  const p = side === 'left' ? { x, y: along(y, h) }
    : side === 'right' ? { x: x + w, y: along(y, h) }
    : side === 'bottom' ? { x: along(x, w), y: y + h }
    : side === 'inside-top' ? { x: along(x, w), y: y + INSIDE }
    : { x: along(x, w), y };
  return { x: p.x + (pin.dx ?? 0), y: p.y + (pin.dy ?? 0) };
};

/** Every tile line with its anchor, validated: a missing pin or rect is an authoring error, so it throws. */
const resolve = (t: PointerTrack, lines: Line[], offset: number) => lines.filter((l) => l.place === 'tile').map((l) => {
  if (!l.pin) throw new Error(`Tag: line "${l.id}" is place 'tile' but has no pin`);
  const r = rectAt(t, l.pin.rect, l.from - offset);
  if (!r) throw new Error(`Tag: line "${l.id}" pins to rect "${l.pin.rect}", which the track does not have at frame ${l.from - offset} (its from). Keys: ${Object.keys(t.rects).join(', ')}`);
  return { l, pin: l.pin, at: anchorOf(r, l.pin) };
});

export const Tag: React.FC<{
  t: PointerTrack; lines: Line[]; f: number; offset: number;
  map: (x: number, y: number) => { x: number; y: number }; unit: number; output: { width: number; height: number }; opacity?: number;
}> = ({ t, lines, f, offset, map, unit, output, opacity = 1 }) => {
  const { fps } = useVideoConfig();
  const tags = resolve(t, lines, offset);
  const { size, padX, h } = pillMetrics(unit);
  const notch = 13 * unit, half = 15 * unit, margin = 20 * unit, round = h / 2;

  return (
    <>
      {tags.filter(({ l }) => f >= l.from && f < l.to).map(({ l, pin, at }) => {
        const side = pin.side ?? 'top', align = pin.align ?? 'start';
        const a = map(at.x, at.y);
        const w = measure(lineText(l), size) + padX * 2;
        const vertical = side === 'left' || side === 'right';
        // Unclamped placement: flush with the anchor corner (start/end) or centred on it; the notch sits
        // just inside the rounded end (start/end) or in the middle, on the side facing the tile.
        const len = vertical ? h : w;
        const lead = align === 'start' ? 0 : align === 'end' ? len : len / 2;
        const notchAt = vertical ? h / 2 : align === 'start' ? round + 6 * unit : align === 'end' ? w - round - 6 * unit : w / 2;
        let x = vertical ? (side === 'left' ? a.x - notch - w : a.x + notch) : a.x - lead;
        let y = vertical ? a.y - lead : side === 'top' ? a.y - notch - h : a.y + notch;
        const x0 = x, y0 = y;
        x = Math.max(margin, Math.min(output.width - margin - w, x));
        y = Math.max(margin, Math.min(output.height - margin - h, y));
        // Clamping slides the pill back into frame; the notch keeps its place over the tile.
        const nx = vertical ? (side === 'left' ? w : 0) : Math.max(round * 0.8, Math.min(w - round * 0.8, notchAt + x0 - x));
        const ny = vertical ? Math.max(round * 0.8, Math.min(h - round * 0.8, notchAt + y0 - y)) : side === 'top' ? h : 0;
        const rot = side === 'top' ? 0 : side === 'left' ? -90 : side === 'right' ? 90 : 180;

        const open = springAt((f - l.from) / fps, POP);
        const fade = prog(f, l.from, l.from + RISE * fps, E.cssOut);
        const exit = prog(f, l.to - EXIT_S * fps, l.to, E.in);
        const scale = Math.max(0, open) * (1 - 0.1 * exit);
        const tone = TONES[l.tone ?? 'persona'];
        return (
          <div key={l.id} style={{ position: 'absolute', left: x, top: y, width: w, height: h, opacity: opacity * fade * (1 - exit), transform: `scale(${scale})`, transformOrigin: `${nx}px ${ny}px`, pointerEvents: 'none' }}>
            {/* Pill and notch share one shadow (the bubble's), so the notch reads as part of the pill. */}
            <div style={{ position: 'absolute', inset: 0, filter: `drop-shadow(${pillShadow(unit)})` }}>
              <div style={{ position: 'absolute', inset: 0, background: tone.bg, borderRadius: round, boxShadow: pillHighlight(unit) }} />
              {/* The notch: a rounded wedge pointing at the tile, its base tucked 1px into the pill. */}
              <svg width={1} height={1} style={{ position: 'absolute', left: nx, top: ny, overflow: 'visible' }}>
                <path transform={`rotate(${rot})`} fill={tone.bg}
                  d={`M${-half} ${-1} Q${-half * 0.45} ${-1} ${-3 * unit} ${notch - 3 * unit} Q0 ${notch + 0.5 * unit} ${3 * unit} ${notch - 3 * unit} Q${half * 0.45} ${-1} ${half} ${-1} Z`} />
              </svg>
            </div>
            <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: round }}>
              <Words text={lineText(l)} f={f} from={l.from} to={l.to} fps={fps} unit={unit} ink={tone.ink} />
            </div>
          </div>
        );
      })}
    </>
  );
};
