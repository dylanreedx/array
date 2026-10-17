#!/usr/bin/env bash
# Video 2 ("A day in Array"): the transition sound design as a stem on the film's own transition
# positions (videos/full-day/stems/, mixed in by kit/soundtrack.py), then scripts/render full-day.
# usage: scripts/day-render.sh [render.sh flags...]
set -euo pipefail
cd "$(dirname "$0")/../.."  # film/
mkdir -p videos/full-day/stems
npx tsx -e "
import { layout } from './videos/full-day/timeline';
const ids = { sunrise: 't1', coffee: 't2', lunch: 't3', headsdown: 't4', sounds: 't6', sunset: 't5' } as Record<string, string>;
const { parts, end } = layout();
const out: Record<string, number> = { total: end + 300 };
for (const p of parts) if (p.kind === 'transition') out[ids[p.id]] = p.at;
require('node:fs').writeFileSync('videos/full-day/stems/layout.json', JSON.stringify(out));
console.log('layout', JSON.stringify(out));
"
uv run --no-project --python 3.13 --with numpy==2.5.3 --with soundfile==0.14.0 python legacy/previews/day/sfx.py \
  ../Resources/AgentSounds videos/full-day/stems/transitions.wav videos/full-day/stems/layout.json
scripts/render full-day "$@"
