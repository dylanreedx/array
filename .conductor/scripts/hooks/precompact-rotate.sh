#!/usr/bin/env bash
#
# PreCompact hook (matcher: "auto" only — manual /compact proceeds normally)
# Intercepts auto-compaction and forces context rotation instead.
#
# Task state is safe in both modes:
#   - Classic: task is still pending (classic never sets in_progress)
#   - Maestro: _getNextMaestroTask resumes in_progress tasks with current_phase set
#
# Dormant when .conductor/.autonomous does not exist.
#

set -euo pipefail

AUTONOMOUS_FLAG=".conductor/.autonomous"
ROTATE_SIGNAL=".conductor/.rotate"

# Read stdin (hook input JSON)
INPUT=$(cat)

# No-op if not in autonomous mode
if [ ! -f "$AUTONOMOUS_FLAG" ]; then
  exit 0
fi

# Write rotation signal for the wrapper
echo '{"reason":"precompact_rotation","timestamp":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' > "$ROTATE_SIGNAL"

# Tell Claude to stop (prevents compaction from proceeding)
echo '{"continue":false}'
