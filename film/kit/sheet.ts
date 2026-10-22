// A video as data. A video's timeline.ts returns a CueSheet from a Clock, so one timeline lays out at
// 60 fps (masters) or 30 fps (loops). The picture, the soundtrack (scripts/cues -> kit/soundtrack.py),
// the captions (.srt) and the chapters all read this one object.
import type { Clock } from './clock';
import type { FormatId } from './formats';

export interface Act { from: number; dur: number; name: string }

/** A sound at a frame. `sfx` names a sound in the video's score (kit/soundtrack.py, its `music` mode). */
export interface Cue { id: string; at: number; sfx?: string; pan?: number }

/** A line of text on screen (also the .srt). */
export interface Line { id: string; from: number; to: number; text: string; words?: boolean; size?: 'hook'; place?: string }

export interface Chapter { id: string; at: number; title: string }

export interface CueSheet {
  slug: string;
  title: string;
  clock: Clock;
  durationInFrames: number;
  acts: Record<string, Act>;
  cues: Cue[];
  lines: Line[];
  chapters: Chapter[];
  /** the score mode kit/soundtrack.py plays under the cues; none = silent */
  music?: string;
}

export interface VideoProps {
  sheet: CueSheet;
  /** viewport overrides the composition size (contact-sheet cells render the film small) */
  viewport?: { width: number; height: number };
  format?: FormatId;
}

export interface VideoVersion {
  Component?: React.FC<VideoProps>;
  /** Optional separate edit: its own duration, captions, cues and soundtrack timing. */
  build?: (clock: Clock) => CueSheet;
}

export interface VideoDefinition {
  slug: string;
  title: string;
  bpm: number;
  formats: readonly FormatId[];
  build: (clock: Clock) => CueSheet;
  Component: React.FC<VideoProps>;
  /** Shared story/look by default; override the framing or the edit per output when needed. */
  versions?: Partial<Record<FormatId, VideoVersion>>;
}

export const defineVideo = (v: VideoDefinition) => v;

export const versionOf = (v: VideoDefinition, format: FormatId) => ({
  Component: v.versions?.[format]?.Component ?? v.Component,
  build: v.versions?.[format]?.build ?? v.build,
});
