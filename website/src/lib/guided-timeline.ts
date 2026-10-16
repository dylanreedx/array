// The guided demo is authored on one progress scale (0…1). Beats added later
// are INSERTED into the scroll rather than squeezed into it: while one plays,
// authored progress holds at `at` and the beat runs on its own 0…1 clock. Every
// authored beat therefore keeps its original scroll distance.
export type GuidedInsertId = 'toolbar' | 'terminal';
export interface GuidedInsert { id: GuidedInsertId; t: number }

export const GUIDED_INSERTS: ReadonlyArray<{ id: GuidedInsertId; at: number; length: number }> = [
  // Tour the creation toolbar, then drag it from the bottom edge to the left.
  { id: 'toolbar', at: .27, length: .1 },
  // Open the build terminal from the toolbar before running the tests.
  { id: 'terminal', at: .815, length: .06 },
];
const INSERTED = GUIDED_INSERTS.reduce((sum, insert) => sum + insert.length, 0);
/** Authored scroll height (970svh) grown by the inserted beats. */
export const GUIDED_TRACK_SVH = Math.round(970 * (1 + INSERTED));

const clamp = (n: number) => Math.max(0, Math.min(1, Number.isFinite(n) ? n : 0));

/** Scroll fraction → authored progress, plus the inserted beat playing, if any. */
export function guidedTimeline(scroll: number): { progress: number; insert: GuidedInsert | null } {
  if (clamp(scroll) >= 1) return { progress: 1, insert: null };
  const position = clamp(scroll) * (1 + INSERTED);
  let consumed = 0;
  for (const insert of GUIDED_INSERTS) {
    const start = insert.at + consumed;
    if (position < start) break;
    if (position < start + insert.length) return { progress: insert.at, insert: { id: insert.id, t: (position - start) / insert.length } };
    consumed += insert.length;
  }
  return { progress: clamp(position - consumed), insert: null };
}

/** Authored progress → scroll fraction. An insert's own point lands on its first frame. */
export function scrollForProgress(progress: number, insertT?: number): number {
  const q = clamp(progress);
  let position = q;
  for (const insert of GUIDED_INSERTS) {
    if (insert.at < q) position += insert.length;
    else if (insert.at === q && insertT !== undefined) position += insert.length * clamp(insertT);
  }
  return position / (1 + INSERTED);
}
