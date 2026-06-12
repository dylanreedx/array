#!/usr/bin/env bash
# overnight-loop.sh — Ralph-style driver: fresh pi master session per ticket.
#
# State lives in Linear + git, so each iteration is disposable; compaction
# never happens because no session outlives one ticket.
#
# Usage (from repo root, before bed):
#   caffeinate -is ./scripts/overnight-loop.sh
#
# Stop it: touch STOP in the repo root (takes effect next iteration),
# or Ctrl-C. Tune with MAX_ITER=n.

set -uo pipefail
cd "$(dirname "$0")/.."

MAX_ITER="${MAX_ITER:-14}"
PROMPT_FILE="scripts/overnight-master-prompt.md"
STOP_FILE="STOP"
BACKUP_DIR="${BACKUP_DIR:-$HOME/continuum-backups}"
LOG_DIR=".pi/overnight-logs"
QUOTA_SLEEP="${QUOTA_SLEEP:-2700}"   # 45 min; Codex window is 300 min

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
STAMP="$(date +%Y%m%dT%H%M%S)"

echo "[loop] start $(date) — backing up all refs"
git bundle create "$BACKUP_DIR/continuum-$STAMP-start.bundle" --all 2>/dev/null \
  || echo "[loop] WARN: start bundle failed"

failures=0
for i in $(seq 1 "$MAX_ITER"); do
  if [ -f "$STOP_FILE" ]; then echo "[loop] STOP file present; halting."; break; fi
  echo "[loop] === iteration $i/$MAX_ITER $(date) ==="
  OUT="$LOG_DIR/iter-$STAMP-$i.log"

  # Stale watches from exited -p sessions hijack the next session's prompt
  # (redelivered notifications outrank the prompt). Masters run foreground
  # delegation only, so any watch present here is a stray — clear it.
  rm -f .pi/agent-runs/.scheduler/watches.json

  pi -p --approve --session-id "overnight-$STAMP-$i" -n "overnight-$i" \
     "$(cat "$PROMPT_FILE")" >"$OUT" 2>&1
  rc=$?

  token="$(grep -E '^LOOP: ' "$OUT" | tail -1 || true)"
  echo "[loop] rc=$rc token='${token:-none}' (log: $OUT)"
  tail -3 "$OUT" | sed 's/^/[master] /'

  if grep -qiE 'usage limit|has-credits: false|status code 429' "$OUT"; then
    failures=$((failures + 1))
    if [ "$failures" -ge 3 ]; then echo "[loop] 3 consecutive quota/provider failures; halting."; break; fi
    echo "[loop] quota/provider failure #$failures — sleeping ${QUOTA_SLEEP}s"
    sleep "$QUOTA_SLEEP"
    continue
  fi

  if [ -z "$token" ]; then
    failures=$((failures + 1))
    if [ "$failures" -ge 3 ]; then echo "[loop] 3 iterations without LOOP token; halting."; break; fi
    echo "[loop] no LOOP token (failure #$failures) — continuing"
    continue
  fi

  failures=0
  git bundle create "$BACKUP_DIR/continuum-rolling.bundle" --all 2>/dev/null \
    || echo "[loop] WARN: rolling bundle failed"

  case "$token" in
    "LOOP: STOP"*)    echo "[loop] master requested stop: $token"; break ;;
    "LOOP: CONTINUE"*) ;;
  esac
done

echo "[loop] finished $(date)."
echo "[loop] summary of iterations:"
grep -hE '^LOOP: ' "$LOG_DIR"/iter-"$STAMP"-*.log 2>/dev/null | sed 's/^/[loop]   /'
echo "[loop] commits since start:"
git log --oneline -15 | sed 's/^/[loop]   /'
