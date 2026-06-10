#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

severity=""
summary=""
expected=""
observed=""
screenshot=""
flow=""
step=""
project="continuum-revived"
db="$ROOT_DIR/.conductor/conductor.db"

usage() {
  cat >&2 <<'USAGE'
Usage: qa/file-finding.sh --severity <critical|major|minor|trivial> --summary <text> --expected <text> --observed <text> --screenshot <path> --flow <name> --step <name> [--project <name>] [--db <path>]
USAGE
}

option_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option" >&2
    usage
    exit 2
  fi
  printf "%s" "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --severity) severity="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --summary) summary="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --expected) expected="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --observed) observed="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --screenshot) screenshot="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --flow) flow="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --step) step="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --project) project="$(option_value "$1" "${2:-}")"; shift 2 ;;
    --db) db="$(option_value "$1" "${2:-}")"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

for required in severity summary expected observed screenshot flow step project db; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required value: $required" >&2
    usage
    exit 2
  fi
done

case "$severity" in
  critical|major|minor|trivial) ;;
  *) echo "Invalid severity: $severity" >&2; exit 2 ;;
esac

if [[ ! -f "$db" ]]; then
  echo "Conductor database not found: $db" >&2
  exit 2
fi

python3 - "$db" "$project" "$severity" "$summary" "$expected" "$observed" "$screenshot" "$flow" "$step" <<'PY'
import hashlib
import sqlite3
import sys
import time
import uuid

db, project, severity, summary, expected, observed, screenshot, flow, step = sys.argv[1:]
fingerprint_source = "\n".join([severity, summary, flow, step])
fingerprint = hashlib.sha256(fingerprint_source.encode("utf-8")).hexdigest()

description = f"""[qa-finding][{severity}] {summary}

severity: {severity}
summary: {summary}
expected: {expected}
observed: {observed}
screenshot: {screenshot}
flow: {flow}
step: {step}
fingerprint: {fingerprint}
"""

connection = sqlite3.connect(db)
try:
    project_row = connection.execute(
        "select id from projects where name = ?",
        (project,),
    ).fetchone()
    if project_row is None:
        print(f"Project not found: {project}", file=sys.stderr)
        sys.exit(2)

    duplicate = connection.execute(
        """
        select id from tasks
        where project_id = ?
          and status = 'pending'
          and description like ?
        limit 1
        """,
        (project_row[0], f"%fingerprint: {fingerprint}%"),
    ).fetchone()
    if duplicate is not None:
        print(f"skipped duplicate qa finding: {duplicate[0]} fingerprint: {fingerprint}")
        sys.exit(0)

    task_id = str(uuid.uuid4())
    now = int(time.time())
    connection.execute(
        """
        insert into tasks (
          id, project_id, category, phase, description, steps, depends_on,
          status, priority, attempt_count, updated_at, current_phase
        ) values (?, ?, 'bugfix', 7, ?, null, null, 'pending', 0, 0, ?, null)
        """,
        (task_id, project_row[0], description, now),
    )
    connection.commit()
    print(f"filed qa finding: {task_id} fingerprint: {fingerprint}")
finally:
    connection.close()
PY
