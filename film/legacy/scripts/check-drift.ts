// Drift tripwires between film/ and website/. Fails (exit 1) when:
//  1. a dependency the website's demo code imports resolves to a different version in film/
//     than in the website's lockfile (two Reacts, two Base UIs, two Tailwinds = two looks);
//  2. a website source the film re-creates by hand changed since the film last acknowledged it.
//     The film renders DemoStage and poses AgentGyro through its `phase` seam, so no markup is
//     mirrored any more; what remains is motion: the film disables CSS transitions and
//     re-creates Tidy's (left/top 110ms cubic-bezier(0,0,.58,1)) as a Track in
//     lib/tracks/tidy.ts. Re-read the file, update the film's copy, then record the new hash in
//     scripts/drift-hashes.json with --accept.
// Type-level drift (a renamed export, a changed action shape) is caught by `tsc` already.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const WEBSITE = path.resolve(process.env.ARRAY_WEBSITE ?? '../website');
const film = JSON.parse(readFileSync('package.json', 'utf8'));
const lock = readFileSync(path.join(WEBSITE, 'pnpm-lock.yaml'), 'utf8');
const problems: string[] = [];

for (const dep of ['react', 'react-dom', '@base-ui/react', 'tailwindcss']) {
  const m = lock.match(new RegExp(`\\n      '?${dep.replace('/', '\\/')}'?:\\n        specifier: [^\\n]+\\n        version: ([0-9][^(\\n]*)`));
  const site = m?.[1]?.trim();
  const ours = film.dependencies?.[dep];
  if (!site) problems.push(`${dep}: not found in website lockfile`);
  else if (site !== ours) problems.push(`${dep}: website ${site}, film ${ours}`);
}

const MIRRORED = ['src/components/demo/mac/MacWorkspace.module.css'];
const hashFile = 'scripts/drift-hashes.json';
const known: Record<string, string> = existsSync(hashFile) ? JSON.parse(readFileSync(hashFile, 'utf8')) : {};
const now = Object.fromEntries(MIRRORED.map((f) => [f, createHash('sha256').update(readFileSync(path.join(WEBSITE, f))).digest('hex').slice(0, 16)]));
if (process.argv.includes('--accept')) writeFileSync(hashFile, JSON.stringify(now, null, 2) + '\n');
else for (const f of MIRRORED) if (known[f] !== now[f]) problems.push(`${f} changed (${known[f] ?? 'never recorded'} -> ${now[f]}): re-check the film's copy, then run with --accept`);

console.log(problems.length ? `drift:\n  ${problems.join('\n  ')}` : 'no drift');
process.exit(problems.length ? 1 : 0);
