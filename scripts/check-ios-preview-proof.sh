#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${IOS_PREVIEW_PROOF_OUT:-$(mktemp -d /tmp/array-ios-preview-proof.XXXXXX)}
mkdir -p "$OUT/cache"
OUT=$(cd "$OUT" && pwd)
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
swiftc -module-cache-path "$OUT/cache" "$ROOT_DIR/Tools/IOSPreviewProof/PreviewProof.swift" -o "$OUT/PreviewProof"
"$OUT/PreviewProof" --fixtures "$OUT"
rm -f "$OUT/origin.txt"
python3 "$ROOT_DIR/Tools/IOSPreviewProof/fixture.py" "$OUT" > "$OUT/fixture.log" 2>&1 &
fixture_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -f "$OUT/origin.txt" ]] && break
  sleep 0.05
done
[[ -f "$OUT/origin.txt" ]] || { cat "$OUT/fixture.log"; exit 1; }
origin=$(cat "$OUT/origin.txt")
"$OUT/PreviewProof" --check "$origin" "$OUT"
# Compile a deliberately wrong coordinate mapping; the same behavioral witness
# must reject it. This binary never connects to a real simulator.
swiftc -DPROOF_WRONG_ROTATION -module-cache-path "$OUT/cache" \
  "$ROOT_DIR/Tools/IOSPreviewProof/PreviewProof.swift" -o "$OUT/WrongRotation"
if "$OUT/WrongRotation" --check "$origin" "$OUT" > "$OUT/negative-control.log" 2>&1; then
  echo "FAIL: wrong rotation unexpectedly passed" >&2
  exit 1
fi
if ! grep -F 'FAIL: rotation 1 maps to expected raw coordinates' "$OUT/negative-control.log" >/dev/null; then
  cat "$OUT/negative-control.log"
  echo "FAIL: negative control failed for an unrelated reason" >&2
  exit 1
fi
echo 'PASS: wrong rotation negative control rejected by behavior witness'
echo "Artifacts: $OUT"
echo 'MATRIX-NOTE: this leg uses labeled fixture frames; it does not exercise live simulator, paste or production canvas integration.'
