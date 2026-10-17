// The standard film frame: replayed website state, seen through the lens, with overlays and
// captions on top. Most videos are just <Film/> plus a timeline; narrated videos add `band` (the
// caption band each format reserves, lib/formats.ts) and acts above or below it.
//
// Layers, bottom to top: the website stage (through the lens), `under` (e.g. the hook's spotlight),
// the caption band, cursor and key chips, `over` (e.g. the lockup). `under` and `over` render inside
// the lens context, so they can anchor to subjects with useLens().outRect.
import { useRef } from 'react';
import { AbsoluteFill, useVideoConfig } from 'remotion';
import { CaptionBand } from '../acts/edu/Caption';
import { CaptionBar } from '../acts/edu/CaptionBar';
import { bandOf } from './formats';
import { makeGyroPhase } from './gyro';
import { Lens } from './Lens';
import { useStageMetrics } from './metrics';
import { Overlays } from './Overlays';
import { useReplay, type Scene } from './replay';
import type { CueSheet } from './sheet';
import { WebsiteStage } from './WebsiteStage';
import './fonts';

export interface FilmProps {
  sheet: CueSheet; scene: Scene; captions?: boolean; viewport?: { width: number; height: number };
  commandCenter?: 'window' | 'frame'; ringScale?: number;
  /** reserve the caption band and narrate in it (CaptionBand) instead of the floating CaptionBar */
  band?: boolean;
  under?: React.ReactNode; over?: React.ReactNode;
  /** band opacity, 1 = hidden (the lockup takes the frame) */
  bandFade?: number;
}

export const Film: React.FC<FilmProps> = ({ sheet, scene, captions = true, viewport, commandCenter, ringScale, band: banded, under, over, bandFade }) => {
  const root = useRef<HTMLDivElement>(null);
  const config = useVideoConfig();
  const output = viewport ?? { width: config.width, height: config.height };
  const band = banded ? bandOf(output) : null;
  const metrics = useStageMetrics(root);
  const { state, dispatch, frame } = useReplay(sheet, scene, metrics?.size ?? null);
  return (
    <AbsoluteFill ref={root} style={{ background: '#0b0d10' }}>
      <Lens keys={sheet.lens} state={state} metrics={metrics} viewport={viewport} band={band} overlay={<>
        {under}
        {captions && (band ? <CaptionBand lines={sheet.lines} band={band} output={output} fade={bandFade} /> : <CaptionBar lines={sheet.lines} />)}
        <Overlays overlays={sheet.overlays} />
        {over}
      </>}>
        {/* remount once measured, so no component state from the unclamped pass survives */}
        <WebsiteStage key={metrics ? 'measured' : 'measuring'} state={state} dispatch={dispatch} gyroPhase={makeGyroPhase(sheet, frame, state)} commandCenter={commandCenter} ringScale={ringScale} />
      </Lens>
    </AbsoluteFill>
  );
};
