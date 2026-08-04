#!/usr/bin/env bash
# Refuse to commit while the queue-94 loop is running.
#
# The loop captures HEAD before handing a ticket to a worker and stops with
# `worker-committed:<ticket>` if HEAD moved underneath it — correctly, because
# _RUNBOOK.md makes the loop the exclusive writer to this checkout. On 2026-08-04 a
# harness-side commit (a watchdog fix, nothing to do with the ticket) landed mid-pass
# and killed a P2.5 worker run that had already finished its implementation, before it
# could be reviewed. The work survived in the tree, but the review did not happen and
# the whole point of the loop is the review.
#
# So: mechanical prevention rather than a note to self. Use this instead of
# `git commit` for any harness-side commit.
#
#   ./scripts/sidebar-native-ux-safe-commit.sh -m "message" [paths...]
#
# Override only when you have deliberately stopped the loop first:
#   ALLOW_LOOP_RUNNING=1 ./scripts/sidebar-native-ux-safe-commit.sh ...
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${ALLOW_LOOP_RUNNING:-0}" != "1" ]; then
  status="$(./scripts/sidebar-native-ux-loopctl.sh status 2>/dev/null || true)"
  if printf '%s' "$status" | grep -qE '^loop: +running'; then
    cat >&2 <<'MSG'
REFUSED: the queue-94 loop is running, and it is the exclusive writer to this
checkout. Committing now moves HEAD under an in-flight worker, which stops the loop
with `worker-committed:<ticket>` and throws away that ticket's review.

Do one of these instead:
  1. Wait for the ticket to land, then commit.
  2. ./scripts/sidebar-native-ux-loopctl.sh stop   # then commit, then restart
  3. ALLOW_LOOP_RUNNING=1 ...                      # only if you already stopped it
MSG
    exit 2
  fi
fi

exec git commit "$@"
