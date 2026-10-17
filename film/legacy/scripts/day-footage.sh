#!/usr/bin/env bash
# Video 2 ("A day in Array"): turn one full-day harness run into the footage the film imports.
# For every captured take: a 1920-wide H.264 proxy in public/footage/full-day/<take>.mp4 and a
# compact pointer/rect track in videos/full-day/tracks/<take>.json (scripts/track.py).
# usage: legacy/scripts/day-footage.sh <run dir, e.g. ~/array-scratch/film/full-day-v2-<run>>
set -euo pipefail
cd "$(dirname "$0")/../.."  # film/
RUN="${1:?usage: scripts/day-footage.sh <run dir>}"
FF=node_modules/.cache/film-bin/ffmpeg
mkdir -p public/footage/full-day videos/full-day/tracks
for dir in "$RUN"/out/*/; do
  take="$(basename "$dir")"
  [[ -f "$dir/frames.json" ]] || continue
  shopt -s nullglob; movies=("$dir"*.mov "$dir"*.mp4); shopt -u nullglob
  mov="${movies[0]}"
  "$FF" -loglevel error -y -i "$mov" -vf scale=1920:-2:flags=lanczos -c:v libx264 -preset medium -crf 14 -pix_fmt yuv420p -an "public/footage/full-day/$take.mp4" &
  keys=$(/usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
keys = set()
for f in d["frames"]:
    keys.update(f.get("rects", {}).keys())
print(" ".join(sorted(keys)))' "$dir/frames.json")
  /usr/bin/python3 legacy/scripts/track.py "$dir/frames.json" "videos/full-day/tracks/$take.json" $keys
done
wait
ls -la public/footage/full-day
