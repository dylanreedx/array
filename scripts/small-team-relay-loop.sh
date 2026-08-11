#!/usr/bin/env bash
# Sequential worker/reviewer loop for docs/38-tickets/92-small-team-relay.
# The harness owns selection, scope validation, final checks, ledger, and commits.

set -uo pipefail
cd "$(dirname "$0")/.."

PROGRAM_DIR="${PROGRAM_DIR:-docs/38-tickets/92-small-team-relay}"
QUEUE_FILE="$PROGRAM_DIR/_QUEUE.md"
LEDGER_FILE="$PROGRAM_DIR/_LEDGER.md"
PROMPT_FILE="scripts/small-team-relay-prompt.md"
STOP_FILE="$PROGRAM_DIR/STOP"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-ux}"
MAX_ITER="${MAX_ITER:-60}"
MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-2}"
PI_WORKER_MODELS="${PI_WORKER_MODELS:-openai-codex/gpt-5.6-sol openai-codex/gpt-5.6-luna}"
PI_THINKING="${PI_THINKING:-medium}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
CONTROL_DIR="${CONTROL_DIR:-$ROOT_PI_DIR/small-team-relay-loop-control/$(basename "$(git rev-parse --show-toplevel)")}"
RUN_ROOT="${RUN_ROOT:-$ROOT_PI_DIR/small-team-relay-runs/$(basename "$(git rev-parse --show-toplevel)")}"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_DIR="$RUN_ROOT/run-$STAMP"
TASKS_DIR="$RUN_DIR/tasks"
STATUS_FILE="$RUN_DIR/status.json"
EVENTS_FILE="$RUN_DIR/events.log"
CURRENT_TICKET=""
CURRENT_CHILD=""
ITERATION=0
START_HEAD="$(git rev-parse HEAD)"
STOP_REASON="running"

mkdir -p "$CONTROL_DIR" "$TASKS_DIR"
printf '%s\n' "$RUN_DIR" > "$CONTROL_DIR/latest-run.txt"
printf '%s\n' "$$" > "$CONTROL_DIR/loop.pid"
ln -sfn "$RUN_DIR" "$RUN_ROOT/latest" 2>/dev/null || true

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'; }
log() { printf '[%s] %s\n' "$(now_utc)" "$*" | tee -a "$EVENTS_FILE"; }

unexpected_status() {
  git status --porcelain | awk '
    $1 == "??" && ($2 == "website/" || $2 ~ /^array-logo.*[.]svg$/) { next }
    { print }
  '
}

changed_paths() {
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | LC_ALL=C sort -u | awk '
    /^website\// { next }
    /^array-logo.*[.]svg$/ { next }
    NF { print }
  '
}

write_status() {
  local state="$1" detail="${2:-}"
  cat > "$STATUS_FILE.tmp" <<EOF
{
  "state": "$(json_escape "$state")",
  "detail": "$(json_escape "$detail")",
  "updatedAt": "$(now_utc)",
  "iteration": $ITERATION,
  "ticket": "$(json_escape "$CURRENT_TICKET")",
  "loopPid": "$$",
  "childPid": "$(json_escape "$CURRENT_CHILD")",
  "startHead": "$START_HEAD",
  "head": "$(git rev-parse HEAD)"
}
EOF
  mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

finish() {
  STOP_REASON="$1"
  write_status stopped "$STOP_REASON"
  log "stopped: $STOP_REASON"
}

cleanup() {
  rm -f "$CONTROL_DIR/loop.pid"
}
trap cleanup EXIT
trap 'touch "$STOP_FILE"; log "termination requested; STOP armed"' INT TERM

ledger_state() {
  local file="$1"
  grep -F "| \`$file\` |" "$LEDGER_FILE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}'
}

ledger_state_for_id() {
  local id="$1"
  grep -E "^\| \`$id-[^\`]+\.md\` \|" "$LEDGER_FILE" | head -1 |
    awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}'
}

first_eligible_ticket() {
  local row file deps state dep eligible old_ifs
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]*`|`[ \t]*$/,"",$3); print $3}')"
    deps="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')"
    state="$(ledger_state "$file")"
    [ "$state" = pending ] || continue
    eligible=1
    if [ "$deps" != "—" ]; then
      old_ifs="$IFS"; IFS=','
      for dep in $deps; do
        dep="$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ "$(ledger_state_for_id "$dep")" = done ] || eligible=0
      done
      IFS="$old_ifs"
    fi
    [ "$eligible" = 1 ] && { printf '%s\n' "$file"; return 0; }
  done <<EOF
$(grep -E '^\| [0-9]+ \| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$QUEUE_FILE" || true)
EOF
  return 1
}

queue_execution() {
  local file="$1"
  grep -F "| \`$file\` |" "$QUEUE_FILE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}'
}

packet_files() {
  local ticket="$1"
  sed -n '/^## Files$/,/^The file fence/p' "$PROGRAM_DIR/$ticket" |
    sed -nE 's/^- `([^`]+)`.*/\1/p'
}

path_allowed() {
  local path="$1" ticket="$2" fence prefix suffix middle
  while IFS= read -r fence; do
    [ -n "$fence" ] || continue
    case "$fence" in
      *'*'*)
        prefix="${fence%%\**}"; suffix="${fence#*\*}"
        case "$suffix" in *'*'*) continue ;; esac
        case "$path" in
          "$prefix"*"$suffix")
            middle="${path#"$prefix"}"; middle="${middle%"$suffix"}"
            case "$middle" in */*) ;; *) return 0 ;; esac
            ;;
        esac
        ;;
      *) [ "$path" = "$fence" ] && return 0 ;;
    esac
  done <<EOF
$(packet_files "$ticket")
EOF
  return 1
}

validate_scope() {
  local ticket="$1" path count=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    path_allowed "$path" "$ticket" || {
      echo "out-of-fence path: $path" >&2
      return 1
    }
  done <<EOF
$(changed_paths)
EOF
  [ "$count" -gt 0 ] || { echo "worker produced no ticket changes" >&2; return 1; }
}

worker_model() {
  local models=($PI_WORKER_MODELS) index
  index=$(( (ITERATION - 1) % ${#models[@]} ))
  printf '%s\n' "${models[$index]}"
}

review_model() {
  case "$1" in
    *gpt-5.6-sol) printf '%s\n' openai-codex/gpt-5.6-luna ;;
    *) printf '%s\n' openai-codex/gpt-5.6-sol ;;
  esac
}

run_worker() {
  local ticket="$1" model="$2" task_dir="$3" pass="$4" review_file="${5:-}"
  local session_dir="$task_dir/worker-session-$pass" output="$task_dir/worker-$pass.md" rc token prompt
  mkdir -p "$session_dir"
  prompt="$(cat <<EOF
[small-team-relay harness]
TICKET=$ticket
PACKET=$PROGRAM_DIR/$ticket
TASK_DIR=$task_dir
PASS=$pass
EOF
)"
  if [ -n "$review_file" ]; then
    prompt="$prompt
This is a repair pass. Address only blocking findings in $review_file."
  fi
  prompt="$prompt

$(cat "$PROMPT_FILE")"

  log "$ticket worker pass $pass ($model)"
  pi --approve --model "$model" --thinking "$PI_THINKING" \
    --session-dir "$session_dir" --name "small-team-relay-$ITERATION-worker-$pass" --mode text -p "$prompt" \
    > "$output" 2> "$task_dir/worker-$pass.stderr" &
  CURRENT_CHILD=$!
  write_status running "worker-pass-$pass"
  wait "$CURRENT_CHILD"; rc=$?
  CURRENT_CHILD=""
  write_status running "worker-pass-$pass-finished"
  [ "$rc" -eq 0 ] || return "$rc"

  token="$(awk 'NF { line=$0 } END { print line }' "$output")"
  case "$token" in
    'WORKER: READY') return 0 ;;
    'WORKER: BLOCKED '*) echo "$token" >&2; return 20 ;;
    *) echo "malformed worker result: ${token:-empty}" >&2; return 21 ;;
  esac
}

run_review() {
  local ticket="$1" model="$2" task_dir="$3" round="$4"
  local diff="$task_dir/candidate-$round.diff" request="$task_dir/review-request-$round.md"
  local output="$task_dir/review-final-$round.md" session="$task_dir/reviewer-session-$round" rc
  git diff --binary > "$diff"
  cat > "$request" <<EOF
Review the candidate implementation for $ticket.

Read:
- $PROGRAM_DIR/$ticket
- $PROGRAM_DIR/_DESIGN.md
- $PROGRAM_DIR/_RUNBOOK.md
- $diff
- relevant production files needed to understand the changed seams

Be strict about correctness, packet architecture, privacy, file scope, deterministic proof, and gate
weakening. Report only blocking issues: behavior that can be wrong, architecture that violates a
locked decision, unsafe handling, or a named done criterion left unproved. Do not request stylistic
cleanup or unrelated hardening. Give at most five blocking findings. You are read-only.

End with exactly DECISION: APPROVE or DECISION: REWORK.
EOF
  mkdir -p "$session"
  log "$ticket review round $round ($model)"
  pi --no-approve --model "$model" --thinking "$PI_THINKING" --tools read,grep,find,ls \
    --session-dir "$session" --name "small-team-relay-$ITERATION-review-$round" --mode text -p "@$request" \
    > "$output" 2> "$task_dir/review-$round.stderr" &
  CURRENT_CHILD=$!
  write_status running "review-round-$round"
  wait "$CURRENT_CHILD"; rc=$?
  CURRENT_CHILD=""
  write_status running "review-round-$round-finished"
  [ "$rc" -eq 0 ] || return 30
  case "$(awk 'NF { line=$0 } END { print line }' "$output")" in
    'DECISION: APPROVE') return 0 ;;
    'DECISION: REWORK') return 10 ;;
    *) return 31 ;;
  esac
}

run_final_checks() {
  local task_dir="$1"
  log "$CURRENT_TICKET final swift build"
  swift build > "$task_dir/swift-build.log" 2>&1 || return 1
  log "$CURRENT_TICKET final matrix"
  CONTINUUM_SKIP_SURFACE_CHECKS=1 CONTINUUM_SKIP_UI_BASELINES=1 ./scripts/run-matrix.sh </dev/null > "$task_dir/matrix.log" 2>&1 || return 1
}

update_ledger_done() {
  local ticket="$1" task_dir="$2" timestamp tmp note
  timestamp="$(now_utc)"
  tmp="$LEDGER_FILE.tmp"
  note="Harness-owned completion: focused worker checks, independent opposite-model review, swift build, and final matrix passed. Evidence: $task_dir."
  awk -F'|' -v OFS='|' -v ticket="$ticket" -v timestamp="$timestamp" -v note="$note" '
    /^last-touch / {
      print "last-touch " timestamp " · ticket " ticket " · attempt 1 · pid — · status done"
      next
    }
    {
      key=$2
      gsub(/^[[:space:]]*`|`[[:space:]]*$/, "", key)
      if (key == ticket) {
        state=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", state)
        if (state != "pending") exit 42
        $3=" done "; $4=" this commit "; $5=" " timestamp " "; $6=" " note " "
        found++
      }
      print
    }
    END { if (found != 1) exit 43 }
  ' "$LEDGER_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LEDGER_FILE"
}

stage_and_commit() {
  local ticket="$1" task_dir="$2" path slug subject
  while IFS= read -r path; do
    [ -n "$path" ] && git add -A -- "$path"
  done <<EOF
$(changed_paths)
EOF
  git diff --cached --binary > "$task_dir/final.diff"
  slug="${ticket#*-}"; slug="${slug%.md}"; slug="${slug//-/ }"
  subject="feat(relay): $slug"
  git commit -m "$subject" > "$task_dir/commit.log" 2>&1
}

preflight() {
  [ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "wrong branch" >&2; return 1; }
  [ ! -f "$STOP_FILE" ] || { echo "STOP is present" >&2; return 1; }
  [ -z "$(unexpected_status)" ] || { echo "tracked/non-authorized changes present" >&2; unexpected_status >&2; return 1; }
  [ "$PI_WORKER_MODELS" = 'openai-codex/gpt-5.6-sol openai-codex/gpt-5.6-luna' ] || return 1
  [ "$PI_THINKING" = medium ] || return 1
  command -v pi >/dev/null 2>&1 || return 1
  ./scripts/check-small-team-relay-program.sh --check || return 1
}

if ! preflight; then finish preflight-failed; exit 1; fi
if [ "${SMALL_TEAM_RELAY_PREFLIGHT_ONLY:-0}" = 1 ]; then finish preflight-ok; exit 0; fi

log "started at $START_HEAD"
write_status running starting

for ITERATION in $(seq 1 "$MAX_ITER"); do
  [ ! -f "$STOP_FILE" ] || { finish stop-file; break; }
  [ -z "$(unexpected_status)" ] || { finish dirty-before-ticket; break; }

  CURRENT_TICKET="$(first_eligible_ticket || true)"
  if [ -z "$CURRENT_TICKET" ]; then
    if grep -q '| pending |' "$LEDGER_FILE"; then finish dependencies-blocked; else finish queue-drained; fi
    break
  fi
  if [ "$(queue_execution "$CURRENT_TICKET")" = supervised ]; then
    finish "supervised-required:$CURRENT_TICKET"
    break
  fi

  task_dir="$TASKS_DIR/iteration-$(printf '%03d' "$ITERATION")-$CURRENT_TICKET"
  mkdir -p "$task_dir"
  before_head="$(git rev-parse HEAD)"
  model="$(worker_model)"
  reviewer="$(review_model "$model")"
  printf '{"ticket":"%s","worker":"%s","reviewer":"%s","startedAt":"%s","beforeHead":"%s"}\n' \
    "$CURRENT_TICKET" "$model" "$reviewer" "$(now_utc)" "$before_head" > "$task_dir/task.json"

  if ! run_worker "$CURRENT_TICKET" "$model" "$task_dir" 1; then finish "worker-failed:$CURRENT_TICKET"; break; fi
  [ "$(git rev-parse HEAD)" = "$before_head" ] || { finish "worker-committed:$CURRENT_TICKET"; break; }
  if ! validate_scope "$CURRENT_TICKET"; then finish "scope-failed:$CURRENT_TICKET"; break; fi

  approved=0
  for round in $(seq 1 $((MAX_REPAIR_PASSES + 1))); do
    run_review "$CURRENT_TICKET" "$reviewer" "$task_dir" "$round"
    review_rc=$?
    if [ "$review_rc" -eq 0 ]; then approved=1; break; fi
    if [ "$review_rc" -ne 10 ]; then finish "reviewer-failed:$CURRENT_TICKET"; break 2; fi
    [ "$round" -le "$MAX_REPAIR_PASSES" ] || break
    if ! run_worker "$CURRENT_TICKET" "$model" "$task_dir" $((round + 1)) "$task_dir/review-final-$round.md"; then
      finish "repair-failed:$CURRENT_TICKET"; break 2
    fi
    [ "$(git rev-parse HEAD)" = "$before_head" ] || { finish "worker-committed:$CURRENT_TICKET"; break 2; }
    if ! validate_scope "$CURRENT_TICKET"; then finish "scope-failed:$CURRENT_TICKET"; break 2; fi
  done
  [ "$approved" = 1 ] || { finish "review-rework-limit:$CURRENT_TICKET"; break; }

  if ! run_final_checks "$task_dir"; then finish "final-check-failed:$CURRENT_TICKET"; break; fi
  [ "$(git rev-parse HEAD)" = "$before_head" ] || { finish "unexpected-commit:$CURRENT_TICKET"; break; }
  if ! validate_scope "$CURRENT_TICKET"; then finish "scope-failed-after-checks:$CURRENT_TICKET"; break; fi
  if ! update_ledger_done "$CURRENT_TICKET" "$task_dir"; then finish "ledger-update-failed:$CURRENT_TICKET"; break; fi
  if ! stage_and_commit "$CURRENT_TICKET" "$task_dir"; then finish "commit-failed:$CURRENT_TICKET"; break; fi
  if [ -n "$(unexpected_status)" ]; then finish "dirty-after-commit:$CURRENT_TICKET"; break; fi

  log "$CURRENT_TICKET committed as $(git rev-parse --short HEAD)"
  write_status running "ticket-complete"
done

if [ "$STOP_REASON" = running ]; then finish max-iterations; fi
printf '%s\n' "$STOP_REASON" > "$RUN_DIR/result.txt"
