#!/usr/bin/env bash
#
# PostToolUse hook for complete_work and complete_maestro_work
# Intercepts task completion to trigger context rotation in autonomous mode.
#
# Dormant when .conductor/.autonomous does not exist.
#

set -euo pipefail

AUTONOMOUS_FLAG=".conductor/.autonomous"

# Read stdin (hook input JSON)
INPUT=$(cat)

# No-op if not in autonomous mode
if [ ! -f "$AUTONOMOUS_FLAG" ]; then
  exit 0
fi

# Parse and decide using node (stdin avoids shell escaping issues)
echo "$INPUT" | node -e '
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

  // The tool response is JSON (pretty-printed) potentially followed by prompt text.
  // Extract the first top-level JSON object: find the closing } at depth 0.
  const lines = text.split("\n");
  let depth = 0;
  let endLine = -1;
  for (let i = 0; i < lines.length; i++) {
    for (const ch of lines[i]) {
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
    }
    if (depth === 0 && i > 0) {
      endLine = i;
      break;
    }
  }
  const jsonStr = endLine >= 0 ? lines.slice(0, endLine + 1).join("\n") : text;

  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    process.exit(0);
  }

  const toolName = input.tool_name || "";
  const block = JSON.stringify({
    decision: "block",
    reason: "AUTONOMOUS MODE: Task completed. Call end_work NOW to prepare handoff for context rotation. Do NOT start the next task."
  });

  // --- complete_maestro_work logic ---
  if (toolName.includes("complete_maestro_work")) {
    // Phase advance (not task completion): no completedTaskId
    if (!parsed.completedTaskId) {
      process.exit(0);
    }
    // All tasks done — let agent call end_work naturally
    if (parsed.complete === true) {
      process.exit(0);
    }
    // Task completed, more tasks remain
    if (parsed.nextTask) {
      console.log(block);
      process.exit(0);
    }
    process.exit(0);
  }

  // --- complete_work logic ---
  if (parsed.complete === true) {
    process.exit(0);
  }
  if (parsed.nextTask) {
    console.log(block);
    process.exit(0);
  }
  process.exit(0);
});
'
