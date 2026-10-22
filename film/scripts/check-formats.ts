// Behaviour witness for output selection, independent edits/crops, scaffolding and real rendering.
// node_modules/.bin/tsx scripts/check-formats.ts [--render]
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';
import { makeClock } from '../kit/clock';
import { FORMATS, outputFormats } from '../kit/formats';
import { cropAround, mobileSafeArea } from '../kit/framing';
import { defineVideo, versionOf, type CueSheet } from '../kit/sheet';

assert.deepEqual(outputFormats(['portrait']), ['portrait']);
assert.deepEqual(outputFormats(['landscape', 'portrait']), ['landscape']);
assert.deepEqual(outputFormats(['landscape', 'portrait'], 'both'), ['landscape', 'portrait']);
assert.deepEqual(outputFormats(['portrait'], 'vertical'), ['portrait']);
assert.throws(() => outputFormats(['landscape'], 'both'), /no authored portrait/);
assert.throws(() => outputFormats(['portrait'], 'landscape'), /no authored landscape/);
assert.throws(() => outputFormats(['portrait'], 'toString'), /Unknown output/);
assert.throws(() => outputFormats([]), /at least one/);
const build = (clock: ReturnType<typeof makeClock>): CueSheet => ({ slug: 'probe', title: 'Probe', clock, durationInFrames: 2, acts: {}, cues: [], lines: [], chapters: [] });
const wide = () => null, tall = () => null;
const video = defineVideo({ slug: 'probe', title: 'Probe', bpm: 120, formats: ['landscape', 'portrait'], build, Component: wide,
  versions: { portrait: { Component: tall, build: c => ({ ...build(c), durationInFrames: 4 }) } } });
assert.equal(versionOf(video, 'landscape').Component, wide);
assert.equal(versionOf(video, 'portrait').Component, tall);
assert.equal(versionOf(video, 'portrait').build(makeClock({ fps: 60, bpm: 120 })).durationInFrames, 4);
const source = { width: 3840, height: 2160 };
for (const subject of [{ x: 1600, y: 700, width: 400, height: 700 }, { x: 0, y: 0, width: 200, height: 300 }, { x: 3640, y: 1860, width: 200, height: 300 }]) {
  const crop = cropAround(source, subject, FORMATS.portrait);
  assert.ok(Math.abs(crop.width / crop.height - 9 / 16) < 1e-10);
  assert.ok(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= source.width && crop.y + crop.height <= source.height);
  assert.ok(subject.x >= crop.x && subject.y >= crop.y && subject.x + subject.width <= crop.x + crop.width && subject.y + subject.height <= crop.y + crop.height);
}
assert.throws(() => cropAround(source, { x: -1, y: 0, width: 1, height: 1 }, FORMATS.portrait), /visible subject/);
const safe = mobileSafeArea(FORMATS.portrait);
assert.ok(safe.x > 0 && safe.y > 0 && safe.x + safe.width < 1080 && safe.y + safe.height < 1920);
console.log('PASS: selection, missing-version errors, independent timeline/component, bounded subject crops');

const film = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const temp = mkdtempSync(path.join(os.tmpdir(), 'array-film-formats-'));
try {
  for (const dir of ['kit', 'src', 'scripts', 'purposes', 'looks']) cpSync(path.join(film, dir), path.join(temp, dir), { recursive: true });
  for (const file of ['package.json', 'tsconfig.json', 'css.d.ts', 'legacy/lib/bundler.ts']) {
    mkdirSync(path.dirname(path.join(temp, file)), { recursive: true });
    cpSync(path.join(film, file), path.join(temp, file));
  }
  symlinkSync(realpathSync(path.join(film, 'node_modules')), path.join(temp, 'node_modules'));
  mkdirSync(path.join(temp, 'public'));
  mkdirSync(path.join(temp, 'videos/probe'), { recursive: true });
  writeFileSync(path.join(temp, 'videos/index.ts'), "import type { VideoDefinition } from '../kit/sheet';\nimport probe from './probe';\nexport const VIDEOS: readonly VideoDefinition[] = [probe];\n");
  writeFileSync(path.join(temp, 'videos/probe/index.tsx'), `
import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { defineVideo, type CueSheet } from '../../kit/sheet';
import type { Clock } from '../../kit/clock';
const build = (clock: Clock): CueSheet => ({ slug: 'probe', title: 'Probe', clock, durationInFrames: 2, acts: {}, cues: [], lines: [], chapters: [] });
const Portrait = () => { const f = useCurrentFrame(); return <AbsoluteFill style={{ background: '#0000ff' }}><div style={{ position: 'absolute', left: 100 + f * 30, top: 300, width: 160, height: 160, background: '#ffffff' }} /></AbsoluteFill>; };
export default defineVideo({ slug: 'probe', title: 'Probe', bpm: 120, formats: ['landscape', 'portrait'], build,
  Component: () => <AbsoluteFill style={{ background: '#00ff00' }} />,
  versions: { portrait: { Component: Portrait, build: c => ({ ...build(c), durationInFrames: 4 }) } } });
`);
  for (const outputs of ['landscape', 'vertical', 'both']) {
    execFileSync('python3', ['scripts/new-video', `probe-${outputs}`, '--purpose', 'social-clip', '--outputs', outputs], { cwd: temp });
    const v = (await import(pathToFileURL(path.join(temp, `videos/probe-${outputs}/index.tsx`)).href)).default;
    assert.deepEqual(v.formats, outputs === 'both' ? ['landscape', 'portrait'] : [outputs === 'vertical' ? 'portrait' : 'landscape']);
    if (outputs !== 'landscape') assert.ok(existsSync(path.join(temp, `videos/probe-${outputs}/portrait.tsx`)));
    if (outputs === 'both') assert.notEqual(versionOf(v, 'portrait').Component, versionOf(v, 'landscape').Component);
  }
  const invalid = spawnSync('python3', ['scripts/new-video', 'probe-invalid', '--purpose', 'social-clip', '--outputs', 'bad'], { cwd: temp, encoding: 'utf8' });
  assert.notEqual(invalid.status, 0);
  assert.ok(!existsSync(path.join(temp, 'videos/probe-invalid')));
  console.log('PASS: generated landscape-only, vertical-only and paired definitions import and select their own components');
  if (process.argv.includes('--render')) {
    const run = (slug: string, ...args: string[]) => execFileSync(path.join(temp, 'node_modules/.bin/tsx'), ['scripts/render.ts', slug, '--port', '3492', '--concurrency', '1', ...args], { cwd: temp, stdio: 'inherit' });
    const pngSize = (file: string) => { const b = readFileSync(file); return [b.readUInt32BE(16), b.readUInt32BE(20)]; };
    const rejected = spawnSync(path.join(temp, 'node_modules/.bin/tsx'), ['scripts/render.ts', 'probe-landscape', '--format', 'both'], { cwd: temp, encoding: 'utf8' });
    assert.equal(rejected.status, 2);
    assert.ok(rejected.stderr.includes('no authored portrait'));
    assert.ok(!existsSync(path.join(temp, 'renders/probe-landscape')));
    run('probe', '--format', 'both', '--sequence', '--round', '1');
    const round = path.join(temp, 'renders/probe/r1');
    for (const [dir, size, frames] of [['', [1920, 1080], 2], ['portrait', [1080, 1920], 4]] as const) {
      const files = readdirSync(path.join(round, dir, 'frames')).filter(f => f.endsWith('.png'));
      assert.equal(files.length, frames);
      assert.deepEqual(pngSize(path.join(round, dir, 'frames', files[0])), size);
      assert.equal(JSON.parse(readFileSync(path.join(round, dir, 'cues.json'), 'utf8')).total, frames);
      // Read an actual rendered pixel: proves the correct per-format component reached Chromium.
      const rgb = execFileSync(path.join(temp, 'node_modules/.cache/film-bin/ffmpeg'), ['-v', 'error', '-i', path.join(round, dir, 'frames', files[0]), '-vf', 'crop=1:1:0:0', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
      assert.deepEqual([...rgb], dir ? [0, 0, 255] : [0, 255, 0]);
    }
    run('probe', '--format', 'both', '--stills', 'f0', '--round', '2');
    assert.ok(existsSync(path.join(temp, 'renders/probe/r2/contact-sheet.png')));
    assert.ok(existsSync(path.join(temp, 'renders/probe/r2/portrait/contact-sheet.png')));
    run('probe-vertical', '--stills', 'f0', '--no-sheet', '--round', '1');
    assert.deepEqual(pngSize(path.join(temp, 'renders/probe-vertical/r1/portrait/stills/f0-f0.png')), [1080, 1920]);
    run('probe', '--format', 'both', '--proxy', '--silent', '--round', '3');
    assert.deepEqual(pngSize(path.join(temp, 'renders/probe/r3/portrait/contact-sheet.png')), [1940, 886]);
    run('probe', '--format', 'vertical', '--blur', '--silent', '--no-sheet', '--round', '4');
    assert.ok(JSON.parse(readFileSync(path.join(temp, 'renders/probe/r4/portrait/samples.json'), 'utf8')).groups.some((n: number) => n > 1));
    const ff = path.join(temp, 'node_modules/.cache/film-bin/ffmpeg');
    for (const [file, dimensions] of [['renders/probe/r3/preview.mp4', '960x540'], ['renders/probe/r3/portrait/preview.mp4', '540x960'], ['renders/probe/r4/portrait/preview.mp4', '1080x1920']]) {
      const result = spawnSync(ff, ['-i', path.join(temp, file), '-f', 'null', '-'], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      assert.ok(result.stderr.includes(dimensions), result.stderr);
    }
    // Exercise the Studio contact-sheet component too; the render CLI above uses the Python sheet.
    const serveUrl = await bundle({ entryPoint: path.join(temp, 'src/index.ts'), symlinkPublicDir: true });
    const inputProps = { slug: 'probe', format: 'portrait', frames: [0], cols: 1, cell: 108 };
    const composition = await selectComposition({ serveUrl, id: 'sheet', inputProps, port: 3492 });
    const output = path.join(temp, 'studio-sheet.png');
    await renderStill({ serveUrl, composition, inputProps, output, port: 3492 });
    assert.deepEqual(pngSize(output), [116, 228]);
    const pixel = execFileSync(ff, ['-v', 'error', '-i', output, '-vf', 'crop=1:1:20:50', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
    assert.deepEqual([...pixel], [0, 0, 255]);
    console.log('PASS: real paired PNGs/pixels/durations, both contact-sheet paths, vertical-only default, paired proxy mux and moving vertical accumulation blur');
  }
} finally {
  rmSync(temp, { recursive: true, force: true });
}
