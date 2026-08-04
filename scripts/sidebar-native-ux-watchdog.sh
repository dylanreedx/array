#!/usr/bin/env bash
# Keep the queue-94 loop running across RECOVERABLE stops, without hiding the ones
# that need a human.
#
# The loop exits on several stop reasons. Some are transient — a worker that broke
# the result protocol, a crashed child, a supervisor that died — and re-running the
# ticket is the correct response. Others mean a decision is owed: a supervised gate,
# a ticket that failed review three times, a final matrix that went red, a dirty
# tree, a drained queue. This restarts only the first kind, and only while the tree
# is clean and the branch is right.
#
# It deliberately does NOT restart:
#   review-rework-limit  — three REWORKs is a real finding; a human reads the evidence
#   final-check-failed   — the matrix is red; re-running would just re-fail
#   supervised           — the owner's gate; approval is never inferred from silence
#   queue-drained        — nothing left to do
#   dirty tree           — restarting would discard or commingle uncommitted work
#
# Backoff is per consecutive restart, so a ticket that keeps dying protocol-wise
# stops thrashing and eventually parks for a human.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
CTL="./scripts/sidebar-native-ux-loopctl.sh"
LOG="$HOME/.pi/sidebar-native-ux-loop-control/continuum-overnight/supervisor.log"
WATCHDOG_LOG="$HOME/.pi/sidebar-native-ux-loop-control/continuum-overnight/watchdog.log"
POLL="${POLL:-60}"
MAX_CONSECUTIVE="${MAX_CONSECUTIVE:-6}"
EXPECTED_BRANCH="overnight/agent-ux"

say() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$WATCHDOG_LOG"; }

consecutive=0
say "watchdog up (poll ${POLL}s, max ${MAX_CONSECUTIVE} consecutive restarts)"

while true; do
  sleep "$POLL"

  # Alive? Nothing to do, and reset the streak — progress happened.
  # The liveness line is `loop:   running pid=NNN`. An earlier version of this
  # matched `pid:`/`child:`, which never appears, so it read a healthy loop as dead
  # and restarted it four times before parking. Match the real format, and prove it
  # by asserting the field exists at all — a status output that stops carrying
  # `loop:` means loopctl changed shape and the watchdog must park, not guess.
  status="$($CTL status 2>/dev/null)"
  if ! printf '%s' "$status" | grep -q '^loop:'; then
    say "PARKED — loopctl status has no 'loop:' line; format changed, refusing to guess"
    exit 0
  fi
  if printf '%s' "$status" | grep -qE '^loop: +running'; then
    consecutive=0
    continue
  fi

  reason="$(grep -oE 'stopped: [a-z-]+(:[^ ]+)?' "$LOG" 2>/dev/null | tail -1)"
  case "$reason" in
    *review-rework-limit*|*final-check-failed*|*supervised*|*queue-drained*|*worker-blocked*)
      say "PARKED for a human — $reason"
      exit 0
      ;;
  esac

  # A provider that cannot be reached is not a transient stop. On 2026-08-04 `pi`
  # started failing with `fetch failed` after three retries, each worker pass dying in
  # ~24s instead of the usual ~25min, and this watchdog restarted seven times before
  # its consecutive-restart bound parked it. The bound worked, but seven restarts of
  # something no restart can fix is pure churn — so detect it directly and park at
  # once. The timing is the tell: a pass that dies in seconds did no work.
  # Recency matters: a stderr from an earlier failure stays on disk forever, and
  # matching it would park a perfectly healthy start. Only a file touched in the last
  # few minutes describes the run that just died.
  if find "$HOME/.pi/sidebar-native-ux-runs/continuum-overnight" -name 'worker-*.stderr' \
       -mmin -5 2>/dev/null | xargs -r grep -lq 'fetch failed' 2>/dev/null; then
    say "PARKED — the model provider is unreachable (fetch failed); no restart can fix this"
    exit 0
  fi

  # A clean tree is the precondition for a safe restart: uncommitted work means a
  # candidate is in flight and re-running the ticket would commingle or discard it.
  if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
    say "PARKED — tracked changes present, a candidate is in flight ($reason)"
    exit 0
  fi

  [ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { say "PARKED — wrong branch"; exit 0; }

  consecutive=$((consecutive + 1))
  if [ "$consecutive" -gt "$MAX_CONSECUTIVE" ]; then
    say "PARKED — $consecutive consecutive restarts without progress ($reason)"
    exit 0
  fi

  backoff=$((consecutive * 30))
  say "restart $consecutive/$MAX_CONSECUTIVE after ${backoff}s — $reason"
  sleep "$backoff"
  $CTL arm >/dev/null 2>&1
  if $CTL start >>"$WATCHDOG_LOG" 2>&1; then
    say "restarted"
  else
    say "PARKED — start refused, see the log"
    exit 0
  fi
done
