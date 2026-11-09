#!/bin/bash
# Rebuild the film tools into /tmp/aln/tools, where film.sh expects them.
# Usage: .plans/auto-layout-night/tools/setup.sh
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=/tmp/aln/tools
mkdir -p "$OUT"
cp "$SRC/film.sh" "$SRC/film_seed.py" "$OUT/"
chmod +x "$OUT/film.sh"
for f in "$SRC"/*.swift; do
  name="$(basename "$f" .swift)"
  swiftc -O "$f" -o "$OUT/$name"
done
echo "film tools built in $OUT"
