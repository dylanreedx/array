/** Source port: CanvasAutoLayoutEngine.swift move/settle geometry. String IDs
 * stand in for native UUIDs and retain the same lexicographic tie ordering. */
export interface Frame { x: number; y: number; width: number; height: number }
export type Frames = Record<string, Frame>;
export type ContentRect = Frame;
const copy = (frames: Frames): Frames => Object.fromEntries(Object.entries(frames).map(([id, f]) => [id, { ...f }]));
const ids = (frames: Frames) => Object.keys(frames).sort();
const right = (f: Frame) => f.x + f.width;
const bottom = (f: Frame) => f.y + f.height;
export function overlapsOrUnderGap(a: Frame, b: Frame, gap: number): boolean {
  return a.x < right(b) + gap && right(a) + gap > b.x && a.y < bottom(b) + gap && bottom(a) + gap > b.y;
}
export function gapClear(frames: Frames, gap: number): boolean {
  const ordered = ids(frames);
  return ordered.every((id, i) => ordered.slice(i + 1).every(other => !overlapsOrUnderGap(frames[id], frames[other], gap)));
}
export function valid(frame: Frame, content: ContentRect, others: readonly Frame[], gap: number): boolean {
  return frame.x >= content.x - .001 && frame.y >= content.y - .001
    && right(frame) <= right(content) + .001 && bottom(frame) <= bottom(content) + .001
    && !others.some(other => overlapsOrUnderGap(frame, other, gap));
}
export function isGapAdjacent(a: Frame, b: Frame, gap: number, tolerance = .26): boolean {
  const sepX = Math.max(a.x - right(b), b.x - right(a));
  const sepY = Math.max(a.y - bottom(b), b.y - bottom(a));
  return Math.abs(sepX - gap) <= tolerance && sepY < 0 || Math.abs(sepY - gap) <= tolerance && sepX < 0;
}
export function squaredDistance(a: Frame, b: Frame): number { return (a.x - b.x) ** 2 + (a.y - b.y) ** 2; }
export function clampIntoContent(frame: Frame, content: ContentRect): Frame {
  return { ...frame, x: Math.min(Math.max(frame.x, content.x), Math.max(content.x, right(content) - frame.width)),
    y: Math.min(Math.max(frame.y, content.y), Math.max(content.y, bottom(content) - frame.height)) };
}
export function pushAxis(baselineA: Frame, baselineB: Frame, a: Frame, b: Frame, gap: number): 'horizontal' | 'vertical' {
  const xSeparated = right(baselineA) <= baselineB.x + .5 || right(baselineB) <= baselineA.x + .5;
  const ySeparated = bottom(baselineA) <= baselineB.y + .5 || bottom(baselineB) <= baselineA.y + .5;
  if (xSeparated !== ySeparated) return xSeparated ? 'horizontal' : 'vertical';
  const penX = b.x + b.width / 2 >= a.x + a.width / 2 ? right(a) + gap - b.x : right(b) + gap - a.x;
  const penY = b.y + b.height / 2 >= a.y + a.height / 2 ? bottom(a) + gap - b.y : bottom(b) + gap - a.y;
  return penX <= penY ? 'horizontal' : 'vertical';
}
/** Mutates frames, like Swift's inout parameter; baseline is never mutated. */
export function propagatePushes(sourceId: string, frames: Frames, baseline: Frames, exclude: ReadonlySet<string>, content: ContentRect, gap: number): void {
  const ordered = ids(frames), queue = [sourceId];
  let visits = 0;
  while (queue.length && visits < Math.max(64, ordered.length * ordered.length * 4)) {
    visits++;
    const pusher = queue.shift()!, a = frames[pusher];
    if (!a) continue;
    for (const id of ordered) {
      if (id === pusher || id === sourceId || exclude.has(id)) continue;
      const b = frames[id];
      if (!overlapsOrUnderGap(a, b, gap)) continue;
      const moved = { ...b };
      if (pushAxis(baseline[pusher] ?? a, baseline[id] ?? b, a, b, gap) === 'horizontal') {
        moved.x = b.x + b.width / 2 >= a.x + a.width / 2 ? right(a) + gap : a.x - gap - b.width;
        moved.x = Math.min(Math.max(moved.x, content.x), Math.max(content.x, right(content) - b.width));
      } else {
        moved.y = b.y + b.height / 2 >= a.y + a.height / 2 ? bottom(a) + gap : a.y - gap - b.height;
        moved.y = Math.min(Math.max(moved.y, content.y), Math.max(content.y, bottom(content) - b.height));
      }
      if (moved.x !== b.x || moved.y !== b.y) { frames[id] = moved; queue.push(id); }
    }
  }
}
export interface Point { x: number; y: number }
/** Source MoveLatch: a sibling id is `.swap(id)`; `{ row, index }` is `.insert`. */
export type MoveLatch = string | { row: number; index: number } | null;
/** Source memberRows: members whose vertical spans overlap (transitively),
 * rows top to bottom, each row left to right. */
export function memberRows(members: readonly string[], frames: Frames): string[][] {
  const byTop = members.filter(id => frames[id]).sort((a, b) => frames[a].y - frames[b].y || (a < b ? -1 : a > b ? 1 : 0));
  const rows: string[][] = [];
  let rowBottom = -Infinity;
  for (const id of byTop) {
    const f = frames[id];
    if (!rows.length || f.y >= rowBottom - .5) { rows.push([id]); rowBottom = bottom(f); }
    else { rows[rows.length - 1].push(id); rowBottom = Math.max(rowBottom, bottom(f)); }
  }
  return rows.map(row => row.sort((a, b) => frames[a].x - frames[b].x || (a < b ? -1 : a > b ? 1 : 0)));
}
function rowExtent(row: readonly string[], frames: Frames): Frame {
  const members = row.map(id => frames[id]).filter(Boolean);
  if (!members.length) return { x: 0, y: 0, width: 0, height: 0 };
  const x = Math.min(...members.map(f => f.x)), y = Math.min(...members.map(f => f.y));
  return { x, y, width: Math.max(...members.map(right)) - x, height: Math.max(...members.map(bottom)) - y };
}
const rectContains = (f: Frame, p: Point, inset = 0) =>
  p.x >= f.x - inset && p.x <= right(f) + inset && p.y >= f.y - inset && p.y <= bottom(f) + inset;
/** Source swapOnlyLatch (⌥, or no pointer): enter a sibling to swap with it. */
function swapOnlyLatch(probe: Point, home: Frame, siblings: readonly string[], baseline: Frames, latched: MoveLatch, band: number): MoveLatch {
  let latch: string | null = null;
  if (typeof latched === 'string' && baseline[latched] && siblings.includes(latched) && rectContains(baseline[latched], probe, band)) latch = latched;
  if (rectContains(home, probe)) return null;
  return siblings.find(id => baseline[id] && rectContains(baseline[id], probe)) ?? latch;
}
/** Source slideOrSwapLatch: middle half swaps, outer quarters and gaps slide in. */
function slideOrSwapLatch(probe: Point, home: Frame, rows: readonly string[][], baseline: Frames, latched: MoveLatch, band: number): MoveLatch {
  if (rectContains(home, probe)) return null;
  const middleHalf = (id: string): Frame | null => baseline[id] ? { ...baseline[id], x: baseline[id].x + baseline[id].width / 4, width: baseline[id].width / 2 } : null;
  if (typeof latched === 'string' && rows.some(row => row.includes(latched))) {
    const half = middleHalf(latched);
    if (half && rectContains(half, probe, band)) return latched;
  }
  const entered = rows.flat().find(id => { const half = middleHalf(id); return half !== null && rectContains(half, probe); });
  if (entered) return entered;
  const held = latched !== null && typeof latched === 'object' && latched.row >= 0 && latched.row < rows.length ? latched : null;
  const heldRow = held && rectContains(rowExtent(rows[held.row], baseline), probe, band) ? held.row : null;
  const found = rows.findIndex(row => rectContains(rowExtent(row, baseline), probe));
  const rowIndex = heldRow ?? (found >= 0 ? found : null);
  if (rowIndex === null) return null;
  const row = rows[rowIndex];
  const mids = row.filter(id => baseline[id]).map(id => baseline[id].x + baseline[id].width / 2);
  let index = mids.filter(mid => mid < probe.x).length;
  if (held && held.row === rowIndex) {
    const surelyPast = mids.filter(mid => mid < probe.x - band).length;
    const maybePast = mids.filter(mid => mid < probe.x + band).length;
    index = Math.min(Math.max(held.index, surelyPast), maybePast);
  }
  const extent = rowExtent(row, baseline);
  const homeInRow = home.y < bottom(extent) && extent.y < bottom(home);
  if (homeInRow && index === mids.filter(mid => mid < home.x + home.width / 2).length) return null;
  return { row: rowIndex, index };
}
/** Source layoutInsertion: the row reflows around the dragged tile's empty slot. */
function layoutInsertion(row: readonly string[], index: number, active: Frame, home: Frame, baseline: Frames, frames: Frames, gap: number): Frame {
  const extent = rowExtent(row, baseline);
  const homeInRow = home.y < bottom(extent) && extent.y < bottom(home);
  let x = homeInRow ? Math.min(extent.x, home.x) : extent.x;
  const slot = { ...active, x, y: extent.y };
  row.forEach((id, position) => {
    if (position === index) { slot.x = x; x += active.width + gap; }
    const f = baseline[id];
    if (!f) return;
    frames[id] = { ...f, x, y: extent.y };
    x += f.width + gap;
  });
  if (index >= row.length) slot.x = x;
  return slot;
}
/** Source solveMemberMove. `pointer` (world) decides slide vs swap; without
 * one the tile's centre stands in and the move can only swap, as with ⌥. */
export function solveMemberMove(baseline: Frames, active: string, requested: Frame, content: ContentRect, gap: number, latched: MoveLatch = null, pointer: Point | null = null, preferSwap = false): { frames: Frames; latch: MoveLatch; slot: Frame | null } {
  const original = baseline[active];
  if (!original) return { frames: {}, latch: null, slot: null };
  const probe = pointer ?? { x: requested.x + requested.width / 2, y: requested.y + requested.height / 2 };
  const releaseBand = Math.max(24, gap * 1.5);
  const rows = memberRows(ids(baseline).filter(id => id !== active), baseline);
  const latch = preferSwap || pointer === null
    ? swapOnlyLatch(probe, original, rows.flat(), baseline, latched, releaseBand)
    : slideOrSwapLatch(probe, original, rows, baseline, latched, releaseBand);
  const frames = copy(baseline);
  frames[active] = { ...requested };
  let slot: Frame | null = null;
  if (typeof latch === 'string') {
    frames[latch] = clampIntoContent({ ...frames[latch], x: original.x, y: original.y }, content);
    propagatePushes(latch, frames, baseline, new Set([active]), content, gap);
    slot = { ...requested, x: baseline[latch].x, y: baseline[latch].y };
  } else if (latch) slot = layoutInsertion(rows[latch.row], latch.index, requested, original, baseline, frames, gap);
  else propagatePushes(active, frames, baseline, new Set(), content, gap);
  return { frames, latch, slot };
}
/** Source resizeMembers: outward pressure follows baseline order and never
 * clamps against the zone; the caller grows the zone around this transaction. */
export function resizeMembers(baseline: Frames, active: string, requested: Frame, gap: number): Frames {
  const original = baseline[active];
  if (!original) return {};
  const frames = copy(baseline);
  frames[active] = { ...requested };
  const directions = [
    { horizontal: true, positive: true, enabled: right(requested) > right(original) },
    { horizontal: true, positive: false, enabled: requested.x < original.x },
    { horizontal: false, positive: true, enabled: bottom(requested) > bottom(original) },
    { horizontal: false, positive: false, enabled: requested.y < original.y },
  ];
  for (let wave = 0; wave < Math.max(1, Object.keys(baseline).length); wave++) {
    let changed = false;
    for (const { horizontal, positive, enabled } of directions) {
      if (!enabled) continue;
      const start = (f: Frame) => horizontal ? f.x : f.y;
      const length = (f: Frame) => horizontal ? f.width : f.height;
      const ordered = ids(baseline).sort((a, b) => {
        const difference = start(baseline[a]) - start(baseline[b]);
        return difference ? positive ? difference : -difference : a < b ? -1 : a > b ? 1 : 0;
      });
      for (const source of ordered) {
        const a = frames[source], oldA = baseline[source];
        if (source !== active && a.x === oldA.x && a.y === oldA.y && a.width === oldA.width && a.height === oldA.height) continue;
        for (const target of ordered) {
          if (target === active || target === source) continue;
          const b = frames[target], oldB = baseline[target];
          const beyond = positive ? start(oldB) >= start(oldA) + length(oldA) - .001 : start(oldB) + length(oldB) <= start(oldA) + .001;
          const overlap = horizontal ? Math.min(bottom(a), bottom(b)) > Math.max(a.y, b.y) : Math.min(right(a), right(b)) > Math.max(a.x, b.x);
          if (!beyond || !overlap) continue;
          const destination = positive ? start(a) + length(a) + gap : start(a) - gap - length(b);
          if (positive ? start(b) >= destination : start(b) <= destination) continue;
          frames[target] = { ...b, ...(horizontal ? { x: destination } : { y: destination }) };
          changed = true;
        }
      }
    }
    if (!changed) break;
  }
  return frames;
}
export function contactPlacement(frame: Frame, cluster: readonly Frame[], content: ContentRect, gap: number): Frame | null {
  const isValid = (candidate: Frame) => valid(candidate, content, cluster, gap - .26);
  if (cluster.some(other => isGapAdjacent(frame, other, gap)) && isValid(frame)) return { ...frame };
  const aligned = (value: number, edge: number, edgeLength: number, length: number) => {
    const far = edge + edgeLength - length;
    return [Math.min(Math.max(value, Math.min(edge, far)), Math.max(edge, far)), edge, far];
  };
  const candidates: Frame[] = [];
  for (const other of cluster) {
    for (const y of aligned(frame.y, other.y, other.height, frame.height)) {
      candidates.push({ ...frame, x: right(other) + gap, y }, { ...frame, x: other.x - frame.width - gap, y });
    }
    for (const x of aligned(frame.x, other.x, other.width, frame.width)) {
      candidates.push({ ...frame, x, y: bottom(other) + gap }, { ...frame, x, y: other.y - frame.height - gap });
    }
  }
  return candidates.filter(isValid).sort((a, b) => squaredDistance(a, frame) - squaredDistance(b, frame) || a.y - b.y || a.x - b.x)[0] ?? null;
}
function absorb(pending: string[], cluster: Frame[], result: Frames, mover: string | null, content: ContentRect, gap: number): void {
  while (pending.length) {
    const wave = pending.some(id => id !== mover) ? pending.filter(id => id !== mover) : pending;
    const touching = wave.find(id => cluster.some(f => isGapAdjacent(result[id], f, gap)) && valid(result[id], content, cluster, gap - .26));
    if (touching !== undefined) { cluster.push(result[touching]); pending.splice(pending.indexOf(touching), 1); continue; }
    let best: { id: string; frame: Frame; cost: number } | null = null;
    for (const id of wave) {
      const placement = contactPlacement(result[id], cluster, content, gap);
      if (!placement) continue;
      const cost = squaredDistance(placement, result[id]);
      if (!best || cost < best.cost || cost === best.cost && id < best.id) best = { id, frame: placement, cost };
    }
    const id = best?.id ?? wave[0];
    if (best) result[id] = best.frame;
    cluster.push(result[id]); pending.splice(pending.indexOf(id), 1);
  }
}
export function settleMembers(frames: Frames, content: ContentRect, gap: number, mover: string | null = null, pin = false): Frames {
  if (content.width <= 0 || content.height <= 0) return {};
  let result = Object.fromEntries(ids(frames).map(id => [id, clampIntoContent(frames[id], content)]));
  if (Object.keys(result).length <= 1) return result;
  const pending = ids(result);
  if (pin && mover && result[mover]) {
    propagatePushes(mover, result, copy(result), new Set(), content, gap);
    const cluster = [result[mover]];
    pending.splice(pending.indexOf(mover), 1);
    absorb(pending, cluster, result, null, content, gap);
    return result;
  }
  const anchorPool = pending.some(id => id !== mover) ? pending.filter(id => id !== mover) : pending;
  const anchor = [...anchorPool].sort((a, b) => result[a].y - result[b].y || result[a].x - result[b].x || (a < b ? -1 : a > b ? 1 : 0))[0];
  const cluster = [result[anchor]];
  pending.splice(pending.indexOf(anchor), 1);
  absorb(pending, cluster, result, mover, content, gap);
  if (mover && result[mover] && Object.entries(result).some(([id, f]) => id !== mover && overlapsOrUnderGap(result[mover], f, gap - .26))) {
    const pushed = copy(result);
    propagatePushes(mover, pushed, result, new Set(), content, gap);
    result = pushed;
  }
  return result;
}
/** Predicts a release using the same solved scene, including vacancy of passive
 * tiles. Magnetic target detection is a separate native subsystem. */
export function predictMove(baseline: Frames, active: string, requested: Frame, content: ContentRect, gap: number, latched: MoveLatch = null, snapped: Frame | null = null, pointer: Point | null = null, preferSwap = false) {
  const live = solveMemberMove(baseline, active, requested, content, gap, latched, pointer, preferSwap);
  // CanvasNSView.settleAutoLayoutAfterMove (honorSnap=false): a completed
  // swap or slide takes its latched slot before the pinned settle.
  // TileNSView.mouseUp commits the snapped tile through canvas.updateTile
  // before honorSnap settle; updateTile re-solves from the gesture baseline.
  // Reusing raw-pointer passive pushes here would predict a different scene.
  const committedLive = snapped ? solveMemberMove(baseline, active, snapped, content, gap, live.latch, pointer, preferSwap) : live;
  const releaseSource = copy(committedLive.frames);
  if (snapped && releaseSource[active]) releaseSource[active] = { ...snapped };
  else if (live.latch !== null && live.slot && releaseSource[active]) {
    // A latched move (swap or slide) drops into its slot, then settles pinned.
    releaseSource[active] = { ...releaseSource[active], x: live.slot.x, y: live.slot.y };
  }
  const releaseFrames = settleMembers(releaseSource, content, gap, active, snapped !== null || live.latch !== null);
  const destination = releaseFrames[active] ?? null;
  const passiveFrames = Object.fromEntries(Object.entries(releaseFrames).filter(([id]) => id !== active));
  return { live, releaseFrames, destination, passiveFrames,
    valid: destination !== null && valid(destination, content, Object.values(passiveFrames), gap - .26) };
}
