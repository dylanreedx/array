// The output shapes a video can ship in. One composition per (video, format). 4K is the 1080p composition
// rendered at --scale=2, and the proxy is the same composition at scale 0.5, every other frame
// (scripts/render --proxy): the layout never changes between them, only the pixel count.
export const FORMATS = {
  landscape: { width: 1920, height: 1080, fps: 60, label: '16:9' },
  square: { width: 1080, height: 1080, fps: 60, label: '1:1' },
  portrait: { width: 1080, height: 1920, fps: 60, label: '9:16' },
  loop: { width: 1920, height: 1080, fps: 30, label: 'loop, silent, 30 fps' },
  og: { width: 1200, height: 630, fps: 30, label: 'OG still' },
} as const;

export type FormatId = keyof typeof FORMATS;

/** Public CLI spelling; composition ids keep `portrait` for compatibility. */
export const formatId = (value: string): FormatId => {
  const id = value === 'vertical' ? 'portrait' : value;
  if (!Object.hasOwn(FORMATS, id)) throw new Error(`Unknown output "${value}". Use ${Object.keys(FORMATS).join(', ')}, vertical, or both.`);
  return id as FormatId;
};

/** Only offer shapes the film has deliberately authored. A vertical-only film needs no landscape. */
export const outputFormats = (available: readonly FormatId[], requested?: string): FormatId[] => {
  if (!available.length) throw new Error('A video must declare at least one output format.');
  const selected: FormatId[] = requested === 'both' ? ['landscape', 'portrait']
    : requested ? [formatId(requested)] : [available.includes('landscape') ? 'landscape' : available[0]];
  for (const id of selected) if (!available.includes(id)) {
    throw new Error(`This video has no authored ${id} version (available: ${available.join(', ')}). Add its framing/composition and declare it in formats before rendering.`);
  }
  return selected;
};

/** A caption band, if a video reserves one: portrait at the top, the rest at the bottom. */
export interface Band { edge: 'top' | 'bottom'; size: number }
export const bandOf = ({ width, height }: { width: number; height: number }, share = height > width ? 0.2 : height === width ? 0.2 : 0.18): Band =>
  ({ edge: height > width ? 'top' : 'bottom', size: Math.round(height * share) });
