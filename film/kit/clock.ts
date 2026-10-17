// The musical clock every video is written against. A video picks fps and BPM once; every
// frame number in its timeline comes from b(bar, beat, sub), so the picture, the captions
// and the soundtrack all read one grid. Generalises Tessel's hard-coded
// `b = ((bar-1)*4 + beat)*30 + sub*7.5` (60 fps, 120 BPM).
export interface Clock {
  fps: number;
  bpm: number;
  beatsPerBar: number;
  /** frames per beat (may be fractional, b() rounds) */
  beat: number;
  bar: number;
  /** 1-indexed bar, 0-indexed beat, sub = quarter-beats */
  b: (bar: number, beat?: number, sub?: number) => number;
  sec: (s: number) => number;
  ms: (frame: number) => number;
}

export const makeClock = ({ fps, bpm, beatsPerBar = 4, subdivisions = 4 }: { fps: number; bpm: number; beatsPerBar?: number; subdivisions?: number }): Clock => {
  const beat = (60 / bpm) * fps;
  return {
    fps, bpm, beatsPerBar, beat, bar: beat * beatsPerBar,
    b: (bar, beatN = 0, sub = 0) => Math.round(((bar - 1) * beatsPerBar + beatN) * beat + (sub * beat) / subdivisions),
    sec: (s) => Math.round(s * fps),
    ms: (frame) => Math.round((frame / fps) * 1000),
  };
};
