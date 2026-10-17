// Exports one video's sync points for the soundtrack: out/<slug>/cues.json.
//
// Two sources, both from the timeline the picture renders:
// 1. Authored sfx on cues (clicks, whooshes, keys).
// 2. The state motif, DERIVED from the website reducer by replaying every frame: whenever an
//    agent's status changes, the score answers in its colour. working (blue) holds a hum while
//    any agent works; needsAttention (amber) pings; done (green) chimes. Nobody has to remember
//    to add the sound when they script a status change, and it cannot fall out of sync.
// Usage: tsx scripts/export-cues.ts <slug> [fps]
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { makeClock } from '../lib/clock';
import { compileSteps, initialState, stateAt, type Scene } from '../lib/replay';
import type { CueSheet } from '../lib/sheet';

const slug = process.argv[2] ?? 'canvas-tour';
const fps = Number(process.argv[3] ?? 60);
const dir = path.resolve('videos', slug);
const { BPM, timeline } = (await import(path.join(dir, 'timeline.ts'))) as { BPM: number; timeline: (c: ReturnType<typeof makeClock>) => CueSheet };
const scene = JSON.parse(readFileSync(path.join(dir, 'scene.json'), 'utf8')) as Scene;
const sheet = timeline(makeClock({ fps, bpm: BPM }));

type Hit = { f: number; kind: string; pan: number; src: 'cue' | 'state'; id: string };
const hits: Hit[] = sheet.cues.filter((c) => c.sfx).map((c) => ({ f: c.at, kind: c.sfx!, pan: c.pan ?? 0, src: 'cue', id: c.id }));

// Replay every frame (the camera clamp is irrelevant to status, so no canvas size is needed).
const steps = compileSteps(sheet);
const base = initialState(scene);
let prev = stateAt(steps, base, 0);
const working = new Array<number>(sheet.durationInFrames).fill(0);
for (let f = 0; f < sheet.durationInFrames; f++) {
  const s = stateAt(steps, base, f);
  working[f] = Object.values(s.agents).filter((a) => a.status === 'working' || a.status === 'starting').length;
  for (const a of Object.values(s.agents)) {
    const was = prev.agents[a.id]?.status;
    if (f === 0 || was === a.status) continue;
    const kind = a.status === 'needsAttention' ? 'state.ping' : a.status === 'done' ? 'state.chime' : null;
    if (kind && !hits.some((h) => h.f === f && h.kind === kind.slice(6))) hits.push({ f, kind, pan: 0, src: 'state', id: `${a.id}:${was}->${a.status}` });
  }
  prev = s;
}

const out = {
  slug, fps, bpm: BPM, total: sheet.durationInFrames, music: sheet.music ?? 'bed',
  acts: sheet.acts,
  hits: hits.sort((a, b) => a.f - b.f),
  /** frames-per-sample count of working agents: the hum's level follows it */
  working,
  lines: sheet.lines,
  chapters: sheet.chapters,
};
mkdirSync(path.resolve('out', slug), { recursive: true });
writeFileSync(path.resolve('out', slug, 'cues.json'), JSON.stringify(out, null, 1));
console.log(`out/${slug}/cues.json: ${out.total} frames @ ${fps} fps, ${out.hits.length} hits (${out.hits.filter((h) => h.src === 'state').length} derived from state), peak working ${Math.max(...working)}`);
for (const h of out.hits) console.log(`  f${h.f}\t${h.kind}\t${h.src}\t${h.id}`);
