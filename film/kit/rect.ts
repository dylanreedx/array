// Rects and linear interpolation. Every rect in the kit is { x, y, width, height } in some named space
// (take px, output px, terminal-body px); the name lives in the variable, never in the type.
export interface Rect { x: number; y: number; width: number; height: number }

/** a*(1-t) + b*t lands exactly on b at t=1 (a + (b-a)*t does not), so a move that returns lands bit for bit. */
export const lerp = (a: number, b: number, t: number) => a * (1 - t) + b * t;
export const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({ x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t) });
/** Smoothstep of x between a and b. */
export const smooth = (a: number, b: number, x: number) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
/** A region given as fractions of a rect (0..1 on each axis), resolved to the rect's own space. */
export const within = (t: Rect, r: Rect): Rect => ({ x: t.x + r.x * t.width, y: t.y + r.y * t.height, width: r.width * t.width, height: r.height * t.height });
