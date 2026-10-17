// Loop-seam witness for a video that declares `loop` in its cue sheet. Fails (exit 1) when:
//  1. state: the website state one past the last frame (the next loop's frame 0) differs from the
//     state at frame 0. Agent transcripts are append-only in the website reducer, so a transcript
//     passes when the entries this round appended repeat (kind, text) the scene's previous round,
//     which is what keeps the visible transcript identical.
//  2. pixels: the first and last rendered frames of <compositionId> differ by a mean absolute
//     difference of MAX_MEAN_DIFF or more (0..255 per channel, over every RGB sample), or more than
//     MAX_CHANGED of the samples differ by more than 16. The mean catches a frame-wide change (a
//     camera that did not return); the second catches a small one (a tile left open at the edge).
//     The last frame is one frame short of the seam, so only motion inside one frame (the gyro,
//     about 0.01% of samples) may show.
// Not witnessed here: gyro continuity across the seam. lib/gyro.ts guarantees it by rounding the
// cycle to a whole number per loop; it is too small for these thresholds.
// Usage: tsx scripts/check-loop.ts <slug>--<format>   e.g. hero-loop--loop
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';
import { enableTailwind } from '@remotion/tailwind-v4';
import type { DemoState } from '@website/features/demo/types';
import { bundlerOverride } from '../lib/bundler';
import { makeClock } from '../lib/clock';
import { FORMATS, MAC_CANVAS, type FormatId } from '../lib/formats';
import { compileSteps, initialState, settle, stateAt, type Scene } from '../lib/replay';
import type { CueSheet } from '../lib/sheet';

export const MAX_MEAN_DIFF = 2; // of 255
export const MAX_CHANGED = 0.001; // fraction of RGB samples off by more than 16

const id = process.argv[2] ?? 'hero-loop--loop';
const [slug, format] = id.split('--') as [string, FormatId];
const dir = path.resolve('videos', slug);
const { BPM, timeline } = (await import(path.join(dir, 'timeline.ts'))) as { BPM: number; timeline: (c: ReturnType<typeof makeClock>) => CueSheet };
const scene = JSON.parse(readFileSync(path.join(dir, 'scene.json'), 'utf8')) as Scene;
const sheet = timeline(makeClock({ fps: FORMATS[format].fps, bpm: BPM }));
if (!sheet.loop) { console.log(`${id}: no loop declared, nothing to witness`); process.exit(0); }
const problems: string[] = [];

// 1. State at the seam.
const steps = compileSteps(sheet);
const base = initialState(scene);
const at = (f: number) => settle(stateAt(steps, base, f), MAC_CANVAS);
const first = at(sheet.loop.from), next = at(sheet.loop.to);
const strip = (s: DemoState) => ({ ...s, agents: Object.fromEntries(Object.entries(s.agents).map(([k, a]) => [k, { ...a, transcript: [] }])) });
const diff = (a: unknown, b: unknown, p: string): string[] => {
  if (isDeepStrictEqual(a, b)) return [];
  if (a && b && typeof a === 'object' && typeof b === 'object') return [...new Set([...Object.keys(a), ...Object.keys(b)])].flatMap((k) => diff((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k], `${p}.${k}`));
  return [`${p}: ${JSON.stringify(a)} -> ${JSON.stringify(b)}`];
};
problems.push(...diff(strip(first), strip(next), 'state'));
for (const [k, a] of Object.entries(first.agents)) {
  const added = next.agents[k].transcript.slice(a.transcript.length);
  const said = (e: { kind: string; text: string }) => `${e.kind}:${e.text}`;
  if (added.map(said).join('\n') !== a.transcript.slice(a.transcript.length - added.length).map(said).join('\n'))
    problems.push(`state.agents.${k}.transcript: this round appended ${JSON.stringify(added.map(said))}, the scene's previous round ends ${JSON.stringify(a.transcript.slice(-added.length).map(said))}`);
}
console.log(`${id}: state at f${sheet.loop.to} vs f${sheet.loop.from}: ${problems.length ? `${problems.length} differences` : 'identical'}`);

// 2. Pixels across the seam.
const out = path.resolve('out', slug); mkdirSync(out, { recursive: true });
const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts'), bundlerOverride: (c) => enableTailwind(bundlerOverride(c)) });
const composition = await selectComposition({ serveUrl, id });
const last = sheet.loop.to - 1;
const rgb = async (frame: number) => {
  const output = path.join(out, `seam-${format}-f${frame}.png`);
  await renderStill({ serveUrl, composition, frame, output, imageFormat: 'png', overwrite: true });
  const ffmpeg = path.resolve('node_modules/.cache/film-bin/ffmpeg'); // scripts/ffmpeg.py: Remotion's build has no rawvideo muxer
  const r = spawnSync(ffmpeg, ['-loglevel', 'error', '-i', output, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`ffmpeg: ${r.stderr}`);
  return r.stdout;
};
const [a, b] = [await rgb(sheet.loop.from), await rgb(last)];
let sum = 0, changed = 0;
for (let i = 0; i < a.length; i++) { const d = Math.abs(a[i] - b[i]); sum += d; if (d > 16) changed++; }
const mean = sum / a.length;
const share = changed / a.length;
console.log(`${id}: f${sheet.loop.from} vs f${last}: mean abs diff ${mean.toFixed(3)}/255 (limit ${MAX_MEAN_DIFF}), ${(100 * share).toFixed(3)}% of samples off by >16 (limit ${100 * MAX_CHANGED}%)`);
if (a.length !== b.length || mean >= MAX_MEAN_DIFF || share > MAX_CHANGED) problems.push(`pixels: mean abs diff ${mean.toFixed(3)}, ${(100 * share).toFixed(3)}% of samples off by >16`);

for (const p of problems) console.log('  ' + p);
console.log(problems.length ? 'loop seam: RED' : 'loop seam: GREEN');
process.exit(problems.length ? 1 : 0);
