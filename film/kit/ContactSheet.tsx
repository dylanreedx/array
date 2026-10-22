// A contact sheet as a Remotion still: every Nth frame of a video, frozen, in a grid with frame / time / act
// labels. scripts/render writes one per round (renders/<video>/r<N>/contact-sheet.png).
import { Freeze, type CalculateMetadataFunction } from 'remotion';
import { makeClock } from './clock';
import { FORMATS, outputFormats, type FormatId } from './formats';
import { versionOf, type VideoDefinition } from './sheet';

/** `every` is in frames; `frames` lists exact frames instead (the changed beats). */
export type SheetProps = { slug: string; format?: FormatId; every?: number; frames?: number[]; from?: number; to?: number; cols?: number; cell?: number };

const CELL_LABEL = 28;
const layout = (v: VideoDefinition, p: SheetProps) => {
  const format = outputFormats(v.formats, p.format)[0];
  const f = FORMATS[format];
  const { Component, build } = versionOf(v, format);
  const sheet = build(makeClock({ fps: f.fps, bpm: v.bpm }));
  const every = p.every ?? f.fps / 2;
  const from = p.from ?? 0, to = Math.min(p.to ?? sheet.durationInFrames - 1, sheet.durationInFrames - 1);
  const frames: number[] = p.frames ?? [];
  if (!p.frames) for (let k = 0; from + k * every <= to; k++) frames.push(Math.round(from + k * every));
  const cols = p.cols ?? 4;
  const cw = p.cell ?? 480, ch = Math.round((cw * f.height) / f.width);
  return { f, format, Component, sheet, frames, cols, cw, ch, rows: Math.ceil(frames.length / cols) };
};

export const makeSheetMetadata = (videos: readonly VideoDefinition[]): CalculateMetadataFunction<SheetProps> => ({ props }) => {
  const v = videos.find((x) => x.slug === props.slug)!;
  const { cols, cw, ch, rows, sheet } = layout(v, props);
  // As long as the video, not a 1-frame Still: <Freeze> inside a 1-frame composition renders every cell at frame 0.
  return { width: cols * (cw + 4) + 4, height: rows * (ch + CELL_LABEL + 4) + 4, durationInFrames: sheet.durationInFrames, fps: sheet.clock.fps };
};

export const ContactSheet: React.FC<SheetProps & { videos: readonly VideoDefinition[] }> = ({ videos, ...p }) => {
  const v = videos.find((x) => x.slug === p.slug)!;
  const { f, format, Component, sheet, frames, cols, cw, ch } = layout(v, p);
  const actAt = (n: number) => Object.values(sheet.acts).find((a) => n >= a.from && n < a.from + a.dur)?.name ?? '';
  return (
    <div style={{ position: 'absolute', inset: 0, background: '#555', display: 'grid', gridTemplateColumns: `repeat(${cols}, ${cw}px)`, gap: 4, padding: 4, alignContent: 'start' }}>
      {frames.map((n) => (
        <div key={n} style={{ width: cw, height: ch + CELL_LABEL, background: '#000' }}>
          <div style={{ height: CELL_LABEL, display: 'flex', alignItems: 'center', gap: 10, padding: '0 8px', color: '#fff', font: '500 14px ui-monospace, monospace' }}>
            <b>f{n}</b><span>{(n / f.fps).toFixed(2)}s</span><span style={{ opacity: 0.7 }}>{actAt(n)}</span>
          </div>
          <div style={{ position: 'relative', width: cw, height: ch, overflow: 'hidden' }}>
            <div style={{ position: 'absolute', width: f.width, height: f.height, transform: `scale(${cw / f.width})`, transformOrigin: '0 0' }}>
              <Freeze frame={n}><Component sheet={sheet} format={format} viewport={{ width: f.width, height: f.height }} /></Freeze>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
};
