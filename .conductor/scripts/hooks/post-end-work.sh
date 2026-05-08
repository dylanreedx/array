#!/usr/bin/env bash
#
# PostToolUse hook for end_work
# Writes rotation signal when tasks remain, telling the wrapper to restart.
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

# Parse end_work response to check remaining tasks (stdin to node)
RESULT=$(echo "$INPUT" | node -e '
let chunks = [];
process.stdin.on("data", d => chunks.push(d));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(Buffer.concat(chunks).toString());
  } catch (e) {
    process.exit(0);
  }

  const text = (input.tool_response &&
    input.tool_response.content &&
    input.tool_response.content[0] &&
    input.tool_response.content[0].text) || "";

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    process.exit(0);
  }

  const progress = parsed.progress;
  if (!progress) {
    process.exit(0);
  }

  const remaining = (progress.pending || 0) + (progress.inProgress || 0);
  console.log(remaining > 0 ? "rotate" : "done");
});
')

if [ "$RESULT" = "rotate" ]; then
  # Write rotation signal for the wrapper
  echo '{"reason":"tasks_remaining","timestamp":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' > "$ROTATE_SIGNAL"
  # Tell Claude to stop
  echo '{"continue":false}'
fi

# If "done" or anything else — no-op (wrapper exits naturally)
