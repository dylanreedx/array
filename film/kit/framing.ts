import type { Rect } from './rect';

type Size = { width: number; height: number };

/**
 * Crop in TAKE pixels around a chosen subject, at the output's aspect ratio. Stays within captured
 * pixels, so Footage with fit="cover" fills the output. It preserves the whole subject when possible;
 * if that subject is too wide/tall, choose another shot/take rather than trusting an automatic crop.
 * Use in a FootageKey: rect: (box) => cropAround(take, trackRect(track, id, frame), box).
 */
export const cropAround = (source: Size, subject: Rect, output: Size, padding = 0.1): Rect => {
  if (![source.width, source.height, subject.width, subject.height, output.width, output.height].every(n => Number.isFinite(n) && n > 0)
    || ![subject.x, subject.y, padding].every(Number.isFinite) || padding < 0
    || subject.x < 0 || subject.y < 0 || subject.x + subject.width > source.width || subject.y + subject.height > source.height) {
    throw new Error('cropAround needs a visible subject within the take, positive dimensions and nonnegative padding.');
  }
  const aspect = output.width / output.height;
  const wantedWidth = Math.max(subject.width * (1 + 2 * padding), subject.height * (1 + 2 * padding) * aspect);
  const width = Math.min(wantedWidth, source.width, source.height * aspect);
  const height = width / aspect;
  return {
    x: Math.max(0, Math.min(source.width - width, subject.x + subject.width / 2 - width / 2)),
    y: Math.max(0, Math.min(source.height - height, subject.y + subject.height / 2 - height / 2)),
    width, height,
  };
};

/** Editorial starting point, NOT a platform guarantee. Background/footage should still fill the frame. */
export const mobileSafeArea = ({ width, height }: Size): Rect => ({
  x: width * 0.06, y: height * 0.1, width: width * 0.82, height: height * 0.7,
});
