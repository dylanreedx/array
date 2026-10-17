#!/usr/bin/env bash
# Frame references for a director's brief: three stills (10%, 45%, 80%) from a video URL or file.
# Usage: legacy/scripts/refs.sh <name> <url|file>   -> refs/<name>-{1,2,3}.png, the video in refs/raw/
# X posts: pass the mp4 URL from https://api.fxtwitter.com/<user>/status/<id> (media.videos[].url).
set -euo pipefail
cd "$(dirname "$0")/../.."  # film/
NAME=$1; SRC=$2
uv run --python 3.13 scripts/ffmpeg.py >/dev/null; export PATH="$PWD/node_modules/.cache/film-bin:$PATH"
mkdir -p refs/raw
if [[ -f $SRC ]]; then RAW=$SRC; else RAW=refs/raw/$NAME.mp4; curl -sSL -A 'Mozilla/5.0' -o "$RAW" "$SRC"; fi
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW")
for i in 1 2 3; do
  P=$(python3 -c "print(($DUR) * [0.10, 0.45, 0.80][$i - 1])")
  ffmpeg -loglevel error -y -ss "$P" -i "$RAW" -frames:v 1 "refs/$NAME-$i.png"
done
echo "refs/$NAME-{1,2,3}.png from $RAW (${DUR}s). Now write refs/notes.md: pacing, type size vs frame height, how text shares the frame."
