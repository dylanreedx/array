// Determinism gate: renders a composition (every frame, at the delivered scale 1 by default: the
// website's layout differs at lower scales) and fails if any website
// component dispatched an action the film did not script. Each stray is a place where the
// live site would show something the film does not (or vice versa): a camera clamp, a timer.
// Usage: tsx scripts/gate.ts <compositionId> [scale]
import path from 'node:path';
import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { enableTailwind } from '@remotion/tailwind-v4';
import { bundlerOverride } from '../lib/bundler';

const id = process.argv[2] ?? 'canvas-tour--landscape';
const scale = Number(process.argv[3] ?? 1);
const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts'), bundlerOverride: (c) => enableTailwind(bundlerOverride(c)) });
const composition = await selectComposition({ serveUrl, id, port: 3482 });
const strays: string[] = [];
const errors: string[] = [];
await renderMedia({
  port: 3482, // off 3000: the film harness's browser tile serves there during captures
  serveUrl, composition, codec: 'h264', scale, muted: true,
  outputLocation: `out/gate-${id}.mp4`,
  onBrowserLog: (log) => {
    if (log.text.includes('[film]')) strays.push(log.text);
    else if (log.type === 'error') errors.push(log.text);
  },
});
const unique = [...new Set(strays.map((s) => s.replace(/ at f\d+/, '')))];
console.log(`${id}: ${composition.durationInFrames} frames, ${strays.length} stray dispatches (${unique.length} kinds), ${errors.length} console errors`);
for (const u of unique) console.log('  stray:', u, 'first at', strays.find((s) => s.replace(/ at f\d+/, '') === u)?.match(/f\d+/)?.[0]);
for (const e of [...new Set(errors)].slice(0, 5)) console.log('  error:', e.slice(0, 200));
process.exit(strays.length || errors.length ? 1 : 0);
