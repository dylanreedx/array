// The narration, spoken by the pointer: a speech bubble attached to the hand (lines with
// place: 'cursor'), so the viewer reads where they are already looking instead of jumping to a band.
// It trails the cursor on a short lag, sits below-right of the tip like a multiplayer cursor's name
// tag and flips to the left or above near an edge (one side per line, sprung, so it never jitters).
// Between lines the bubble morphs: its width springs from one line's measure to the next while the old
// words lift away and the new ones pop in one by one. A line with a `tone` takes that state's colour.
// Rendering (tones, type, shadow, word pop) is shared with the tile-pinned Tag (Pill.tsx).
import { useVideoConfig } from 'remotion';
import { springAt, track, type Spring } from '../../lib/anim';
import { lagged, type PointerTrack } from '../../lib/pointer';
import type { Line } from '../../lib/sheet';
import { lineText } from './Icon';
import { measure, pillHighlight, pillMetrics, pillShadow, POP, TONES, WORD_DELAY, wordStagger, Words } from './Pill';

const MORPH: Spring = { hz: 3.4, zeta: 0.62 };

const hex = (h: string) => [1, 3, 5].map((k) => parseInt(h.slice(k, k + 2), 16));
const mixHex = (a: string, b: string, t: number) => `rgb(${hex(a).map((v, k) => Math.round(v + (hex(b)[k] - v) * t)).join(',')})`;

export const Bubble: React.FC<{
  t: PointerTrack; lines: Line[]; f: number; offset: number;
  map: (x: number, y: number) => { x: number; y: number }; unit: number; output: { width: number; height: number }; opacity?: number;
}> = ({ t, lines, f, offset, map, unit, output, opacity = 1 }) => {
  const { fps } = useVideoConfig();
  const said = lines.filter((l) => l.place === 'cursor').sort((a, b) => a.from - b.from);
  if (!said.length) return null;
  const { size, padX, padY, lineH, h } = pillMetrics(unit);
  const tip = (frame: number) => { const p = lagged(t, frame - offset, 7); return map(p.x, p.y); };

  // Per line: its width and the side it sits on, chosen from where the hand goes during the line.
  const meta = said.map((l) => {
    const w = measure(lineText(l), size) + padX * 2;
    let maxX = -Infinity, maxY = -Infinity;
    for (let k = l.from; k < l.to; k += 4) { const p = tip(k); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
    const left = maxX + 30 * unit + w > output.width - 24 * unit;
    const up = maxY + 46 * unit + lineH + padY * 2 > output.height - 24 * unit;
    return { l, w, left, up };
  });
  const cur = [...meta].reverse().find((m) => f >= m.l.from);
  const live = cur && f < cur.l.to;
  // Open on each line; close only where no line follows within a beat.
  const openKeys = meta.flatMap((m, k) => {
    const next = meta[k + 1];
    const keys = [{ at: m.l.from, to: 1 }];
    if (!next || next.l.from - m.l.to > fps / 2) keys.push({ at: m.l.to, to: 0 });
    return keys;
  });
  const open = track(f, fps, 0, openKeys, POP);
  if (open < 0.002 && !live) return null;

  // The bubble grows word by word with the reveal (each word's arrival retargets the width), so it
  // morphs from the last line's measure through the new line's prefixes instead of jumping to full.
  const stagger = wordStagger(fps);
  const widthKeys = meta.flatMap((m) => {
    const ws = lineText(m.l).split(' ');
    return ws.map((_, k) => ({ at: m.l.from + WORD_DELAY + k * stagger, to: measure(ws.slice(0, k + 1).join(' '), size) + padX * 2 }));
  });
  const width = track(f, fps, widthKeys[0]?.to ?? 0, widthKeys, MORPH);
  const leftness = track(f, fps, meta[0].left ? 1 : 0, meta.map((m) => ({ at: m.l.from - 6, to: m.left ? 1 : 0 })), MORPH);
  const upness = track(f, fps, meta[0].up ? 1 : 0, meta.map((m) => ({ at: m.l.from - 6, to: m.up ? 1 : 0 })), MORPH);
  const tone = (m?: (typeof meta)[number]) => TONES[m?.l.tone ?? 'persona'];
  const ci = cur ? meta.indexOf(cur) : 0;
  const prevTone = tone(meta[ci - 1] ?? meta[ci]), nowTone = tone(meta[ci]);
  const tt = cur ? Math.min(1, springAt((f - cur.l.from) / fps, { hz: 2.4, zeta: 1 })) : 1;
  const bg = mixHex(prevTone.bg, nowTone.bg, tt), ink = mixHex(prevTone.ink, nowTone.ink, tt);

  const p = tip(f);
  const right = { x: p.x + 30 * unit, y: p.y + 44 * unit };
  const leftP = { x: p.x - 16 * unit - width, y: p.y + 44 * unit };
  let x = right.x + (leftP.x - right.x) * leftness;
  let y = right.y + (p.y - 14 * unit - h - right.y) * upness;
  x = Math.max(20 * unit, Math.min(output.width - 20 * unit - width, x));
  y = Math.max(20 * unit, Math.min(output.height - 20 * unit - h, y));
  // The corner nearest the hand stays tight, like a name tag hanging off the cursor.
  const r = h / 2, tight = 7 * unit;
  const radius = `${leftness < 0.5 && upness < 0.5 ? tight : r}px ${leftness >= 0.5 && upness < 0.5 ? tight : r}px ${leftness >= 0.5 && upness >= 0.5 ? tight : r}px ${leftness < 0.5 && upness >= 0.5 ? tight : r}px`;
  const scale = Math.max(0, open);

  return (
    <div style={{ position: 'absolute', left: x, top: y, width, height: h, opacity, transform: `scale(${scale})`, transformOrigin: `${leftness < 0.5 ? 0 : width}px ${upness < 0.5 ? 0 : h}px`, pointerEvents: 'none' }}>
      <div style={{ position: 'absolute', inset: 0, background: bg, borderRadius: radius, boxShadow: `${pillShadow(unit)}, ${pillHighlight(unit)}` }} />
      {live && (
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: radius }}>
          <Words text={lineText(cur!.l)} f={f} from={cur!.l.from} to={cur!.l.to} fps={fps} unit={unit} ink={ink} />
        </div>
      )}
    </div>
  );
};
