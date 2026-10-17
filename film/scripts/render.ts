// One render round of one video, into renders/<video>/r<N>/ (gitignored):
//   preview.mp4  stills/  contact-sheet.png  notes.md  cues.json  soundtrack.wav  render.log
//
// Usage: scripts/render <video> [options]
//   (none)              review cut: 1920x1080, 60 fps, with sound
//   --proxy             blocking cut: 960x540, every other frame (30 fps), fast encode, with sound
//   --4k                master: 3840x2160 (the 1080p layout at scale 2), with sound
//   --stills <list>     render ONLY these frames, as PNGs in stills/ (no preview.mp4). Each entry is
//                       seconds (7.4), a frame (f444) or an act name (s4); comma separated
//   --range <a-b>       only seconds a..b of the film (a proto of one beat), e.g. --range 6-9
//   --sequence          lossless PNG frames (of --range) in frames/, for the probes; no preview.mp4
//   --blur              real motion blur by accumulation (slow; masters only)
//   --silent            no soundtrack
//   --no-sheet          skip contact-sheet.png
//   --round <N>         write into r<N> (e.g. --round 5.3) instead of the next free round
//   --concurrency <n>   Chrome tabs rendering at once (default: Remotion's, min(8, cores / 2))
//   --format <id>       a format other than landscape (kit/formats.ts)
//
// Bundles once, with the public dir symlinked (never copies the takes), and reuses one server.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { bundle } from '@remotion/bundler';
import { renderFrames, renderMedia, renderStill, selectComposition } from '@remotion/renderer';
import { makeClock } from '../kit/clock';
import { bundlerOverride } from '../legacy/lib/bundler';
import { FORMATS, type FormatId } from '../kit/formats';
import type { VideoDefinition } from '../kit/sheet';
import { VIDEOS } from '../videos';

const FILM = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const argv = process.argv.slice(2);
const slug = argv[0];
const has = (k: string) => argv.includes(k);
const opt = (k: string) => { const i = argv.indexOf(k); return i > 0 ? argv[i + 1] : undefined; };
if (!slug || slug.startsWith('-')) { console.error('usage: scripts/render <video> [--proxy|--4k] [--stills 1.2,f444,s4] [--range 6-9] [--blur] [--silent] [--no-sheet] [--round N] [--format id]'); process.exit(2); }
const video = VIDEOS.find((v) => v.slug === slug) as VideoDefinition | undefined;
if (!video) { console.error(`no video "${slug}" in videos/index.ts (have: ${VIDEOS.map((v) => v.slug).join(', ')})`); process.exit(2); }

const format = (opt('--format') ?? 'landscape') as FormatId;
const F = FORMATS[format];
const mode = has('--proxy') ? 'proxy' : has('--4k') ? '4k' : 'review';
const scale = mode === 'proxy' ? 0.5 : mode === '4k' ? 2 : 1;
const nth = mode === 'proxy' ? 2 : 1;
const sheet = video.build(makeClock({ fps: F.fps, bpm: video.bpm }));
const fps = F.fps;

// ---- the round folder ----------------------------------------------------------------------------------
const videoDir = path.join(FILM, 'renders', slug);
mkdirSync(videoDir, { recursive: true });
const rounds = readdirSync(videoDir).filter((d) => /^r\d+(\.\d+)?$/.test(d)).map((d) => Number(d.slice(1)));
const round = opt('--round') ?? String(rounds.length ? Math.floor(Math.max(...rounds)) + 1 : 1);
const out = path.join(videoDir, `r${round}`);
mkdirSync(out, { recursive: true });
const log = (line: string) => { console.log(line); appendFileSync(path.join(out, 'render.log'), line + '\n'); };
const timed = async <T>(label: string, fn: () => Promise<T> | T): Promise<T> => {
  const t0 = performance.now();
  const r = await fn();
  log(`  ${label}: ${((performance.now() - t0) / 1000).toFixed(1)} s`);
  return r;
};
const t00 = performance.now();
log(`\n${new Date().toISOString()}  scripts/render ${argv.join(' ')}`);
log(`${slug} r${round}: ${mode}, ${format} ${Math.round(F.width * scale)}x${Math.round(F.height * scale)} @ ${fps / nth} fps, ${sheet.durationInFrames} frames`);

// ---- which frames --------------------------------------------------------------------------------------
const frameOf = (s: string) => {
  if (/^f\d+$/.test(s)) return Number(s.slice(1));
  const act = sheet.acts[s];
  if (act) return act.from + Math.floor(act.dur / 2);
  const t = Number(s.replace(/s$/, ''));
  if (Number.isNaN(t)) throw new Error(`--stills: "${s}" is not seconds, f<frame> or an act (${Object.keys(sheet.acts).join(', ')})`);
  return Math.round(t * fps);
};
const stills = opt('--stills')?.split(',').filter(Boolean).map((s) => ({ label: s, frame: Math.min(sheet.durationInFrames - 1, frameOf(s)) }));
const range = opt('--range')?.split('-').map(Number);
const frameRange: [number, number] | null = range ? [Math.round(range[0] * fps), Math.min(sheet.durationInFrames - 1, Math.round(range[1] * fps) - 1)] : null;

// ---- tools ---------------------------------------------------------------------------------------------
const FFMPEG = path.join(FILM, 'node_modules/.cache/film-bin/ffmpeg');
if (!existsSync(FFMPEG)) execFileSync('uv', ['run', '--python', '3.13', path.join(FILM, 'scripts/ffmpeg.py')], { stdio: 'ignore' });
process.env.PATH = `${path.dirname(FFMPEG)}:${process.env.PATH}`; // the Python helpers call plain `ffmpeg`
const ff = (...a: string[]) => execFileSync(FFMPEG, ['-loglevel', 'error', '-y', ...a], { stdio: 'inherit' });
const py = (deps: string[], ...a: string[]) => execFileSync('uv', ['run', '--no-project', '--python', '3.13', ...deps.flatMap((d) => ['--with', d]), 'python', ...a], { stdio: 'inherit' });
const tmp = path.join(os.tmpdir(), `film-render-${process.pid}`);
mkdirSync(tmp, { recursive: true });
process.on('exit', () => rmSync(tmp, { recursive: true, force: true }));

// ---- 1. cues and soundtrack ----------------------------------------------------------------------------
const silent = has('--silent') || !sheet.music || !!stills || has('--sequence');
const cuesPath = path.join(out, 'cues.json');
writeFileSync(cuesPath, JSON.stringify({
  slug, fps, bpm: video.bpm, total: sheet.durationInFrames, music: sheet.music ?? 'none', acts: sheet.acts,
  hits: sheet.cues.filter((c) => c.sfx).map((c) => ({ f: c.at, kind: c.sfx!, pan: c.pan ?? 0, src: 'cue', id: c.id })).sort((a, b) => a.f - b.f),
  working: new Array(sheet.durationInFrames).fill(0), lines: sheet.lines, chapters: sheet.chapters,
}, null, 1));
const wav = path.join(out, 'soundtrack.wav');
// Pre-made stems (videos/<video>/stems/*.wav, e.g. full-day's transition sound design) mix in as they are.
const stems = path.join(FILM, 'videos', slug, 'stems');
if (existsSync(stems) && !existsSync(path.join(out, 'stems'))) (await import('node:fs')).symlinkSync(stems, path.join(out, 'stems'));
if (!silent) await timed('soundtrack', () => py(['numpy==2.5.3', 'scipy==1.18.1', 'soundfile==0.14.0', 'pyloudnorm==0.1.1'], path.join(FILM, 'kit/soundtrack.py'), cuesPath, wav));

// ---- 2. bundle once ------------------------------------------------------------------------------------
const serveUrl = await timed('bundle', () => bundle({ entryPoint: path.join(FILM, 'src/index.ts'), symlinkPublicDir: true, webpackOverride: bundlerOverride }));
const port = 3482; // off 3000 (the harness browser tile) and 3480/3481 (Studio)
const concurrency = opt('--concurrency') ? Number(opt('--concurrency')) : null;
const common = { serveUrl, port, concurrency, chromiumOptions: { gl: 'angle' as const }, timeoutInMilliseconds: 120_000,
  onBrowserLog: (l: { type: string; text: string }) => { if (l.type === 'error') log(`  browser error: ${l.text.slice(0, 300)}`); } };

// ---- 3. stills only ------------------------------------------------------------------------------------
if (stills) {
  const composition = await selectComposition({ serveUrl, id: `${slug}--${format}`, port });
  const dir = path.join(out, 'stills');
  mkdirSync(dir, { recursive: true });
  const files: string[] = [];
  await timed(`${stills.length} stills`, async () => {
    for (const s of stills) {
      const file = path.join(dir, `${s.label.replace(/[^a-z0-9.]+/gi, '-')}-f${s.frame}.png`);
      await renderStill({ ...common, composition, frame: s.frame, output: file, imageFormat: 'png', overwrite: true, scale: mode === '4k' ? 2 : 1 });
      files.push(file);
    }
  });
  if (!has('--no-sheet')) await timed('contact sheet', () => py(['pillow'], path.join(FILM, 'scripts/lib/sheet.py'), path.join(out, 'contact-sheet.png'), cuesPath, String(fps), ...files));
  writeNotes();
  log(`r${round} stills: ${((performance.now() - t00) / 1000).toFixed(1)} s wall clock  ->  ${path.relative(FILM, out)}/`);
  process.exit(0);
}

// ---- 3b. a lossless frame sequence for the probes -------------------------------------------------------
if (has('--sequence')) {
  const composition = await selectComposition({ serveUrl, id: `${slug}--${format}`, port });
  const dir = path.join(out, 'frames');
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  await timed('sequence', () => renderFrames({ ...common, composition, outputDir: dir, imageFormat: 'png', scale, frameRange, imageSequencePattern: '[frame].[ext]',
    inputProps: {}, onStart: () => undefined, onFrameUpdate: () => undefined }));
  log(`r${round} sequence: ${((performance.now() - t00) / 1000).toFixed(1)} s wall clock  ->  ${path.relative(FILM, dir)}/`);
  process.exit(0);
}

// ---- 4. the picture ------------------------------------------------------------------------------------
const picture = path.join(tmp, 'picture.mp4');
const media = async (id: string, output: string, extra: Record<string, unknown> = {}) => {
  const composition = await selectComposition({ serveUrl, id, port, inputProps: (extra.inputProps as Record<string, unknown>) ?? {} });
  await renderMedia({ ...common, composition, codec: 'h264', outputLocation: output, muted: true, imageFormat: 'png', colorSpace: 'bt709', scale, everyNthFrame: nth,
    frameRange, crf: mode === 'proxy' ? 23 : mode === '4k' ? 16 : 14, x264Preset: mode === 'proxy' ? 'veryfast' : 'slow', ...extra } as Parameters<typeof renderMedia>[0]);
};
if (has('--blur')) {
  // Tessel's accumulation: a sharp render tells measure-speed how many sub-frames each frame needs.
  const sharp = path.join(tmp, 'sharp.mp4');
  await timed('sharp render (for speeds)', () => media(`${slug}--${format}`, sharp, { crf: 12, x264Preset: 'veryfast' }));
  const samples = path.join(out, 'samples.json');
  const cv = ['numpy==2.5.3', 'opencv-python-headless==5.0.0.93'];
  await timed('measure speed', () => py(cv, path.join(FILM, 'scripts/tessel/measure-speed.py'), sharp, samples));
  const groups = JSON.parse((await import('node:fs')).readFileSync(samples, 'utf8')).groups as number[];
  const sub = path.join(tmp, 'sub.mp4');
  await timed('sub-frames', () => media(`${slug}--sub`, sub, { inputProps: { slug, groups }, crf: 6, x264Preset: 'veryfast', pixelFormat: 'yuv444p', scale: 1, everyNthFrame: 1, frameRange: null }));
  await timed('accumulate', () => py(['numpy==2.5.3'], path.join(FILM, 'scripts/tessel/accumulate.py'), sub, samples, picture));
} else {
  await timed('picture', () => media(`${slug}--${format}`, picture));
}

// ---- 5. sound on, once, here ---------------------------------------------------------------------------
const preview = path.join(out, 'preview.mp4');
await timed('mux', () => {
  if (silent) ff('-i', picture, '-c', 'copy', '-movflags', '+faststart', preview);
  else ff('-i', picture, ...(frameRange ? ['-ss', String(frameRange[0] / fps)] : []), '-i', wav, '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '320k', '-movflags', '+faststart', '-shortest', preview);
});

// Sync witness: the muxed sound must line up with the soundtrack to the millisecond, at -1 dBTP or below.
if (!silent && mode !== 'proxy' && !frameRange) await timed('sync check', () => py(['numpy==2.5.3', 'scipy==1.18.1', 'soundfile==0.14.0'], path.join(FILM, 'scripts/check-sync.py'), preview, wav));

// ---- 6. contact sheet: frames of the preview every half second -----------------------------------------
if (!has('--no-sheet')) {
  await timed('contact sheet', () => {
    const dir = path.join(tmp, 'sheet');
    mkdirSync(dir, { recursive: true });
    const outFps = fps / nth, step = Math.round(outFps / 2);
    ff('-i', preview, '-vf', `select='not(mod(n\\,${step}))',scale=480:-2`, '-vsync', '0', path.join(dir, '%05d.png'));
    const first = frameRange ? frameRange[0] : 0;
    const files = readdirSync(dir).sort().map((f, k) => { const film = first + k * step * nth; const to = path.join(dir, `f${film}.png`); execFileSync('mv', [path.join(dir, f), to]); return to; });
    py(['pillow'], path.join(FILM, 'scripts/lib/sheet.py'), path.join(out, 'contact-sheet.png'), cuesPath, String(fps), ...files);
  });
}
writeNotes();
log(`r${round} ${mode}: ${((performance.now() - t00) / 1000).toFixed(1)} s wall clock  ->  ${path.relative(FILM, preview)}`);

/** A round's notes.md, the shape every round uses (PROCESS.md). Never overwritten once it exists. */
function writeNotes() {
  const p = path.join(out, 'notes.md');
  if (existsSync(p)) return;
  writeFileSync(p, `# ${video!.title} · r${round}

## Dylan's notes, verbatim

1.

## What changed

## Why (the cause of each fix, in plain words)

## Measurements (each fix backed by a number)

## Still weak

## Self-score (0-10)

- hook:
- readability:
- pacing:
- truth:
- craft:
`);
}
