#!/usr/bin/env bash
set -euo pipefail

# Capture one real, tool-free turn from each supported CLI. The raw CLI streams
# are scrubbed before they enter the repository; authentication remains owned
# by each CLI's existing login.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT/Sources/ContinuumRevivedCoreChecks/Fixtures/context-meter"
MODE="${1:-capture}"
PROMPT='Reply with exactly the word OK. Do not use tools.'
TIMEOUT_SECONDS="${ARRAY_CLI_FIXTURE_TIMEOUT_SECONDS:-150}"

usage() {
    echo "Usage: scripts/capture-cli-fixtures.sh [capture|check|check-offline|catalogs|capture-model <claude-model>]" >&2
}

if [[ "$MODE" != capture && "$MODE" != check && "$MODE" != check-offline && "$MODE" != catalogs && "$MODE" != capture-model ]]; then
    usage
    exit 2
fi
if [[ "$MODE" == capture-model && -z "${2:-}" ]]; then
    usage
    exit 2
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }
mkdir -p "$FIXTURE_DIR"

version_for() {
    case "$1" in
        claude) claude --version | head -n 1 | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/' ;;
        codex) codex --version | head -n 1 | sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' ;;
        pi) pi --version | head -n 1 | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/' ;;
    esac
}

bounded() {
    python3 - "$TIMEOUT_SECONDS" "$@" <<'PY'
import os, subprocess, sys
try:
    stdin_path = os.environ.get("ARRAY_CLI_STDIN_FILE")
    stdin = open(stdin_path, "rb") if stdin_path else None
    result = subprocess.run(sys.argv[2:], stdin=stdin, stdout=sys.stdout.buffer, stderr=sys.stderr.buffer,
                            timeout=float(sys.argv[1]), check=False)
except subprocess.TimeoutExpired:
    print(f"CLI command timed out after {sys.argv[1]} seconds", file=sys.stderr)
    raise SystemExit(124)
finally:
    if stdin_path and stdin:
        stdin.close()
raise SystemExit(result.returncode)
PY
}

check_capture() {
    local cli="$1" version="$2" file="$FIXTURE_DIR/$1-$2.jsonl" metadata="$FIXTURE_DIR/$1-$2.meta.json"
    [[ -s "$file" && -s "$metadata" ]] || {
        echo "missing context meter capture for $cli $version ($file)" >&2
        return 1
    }
    python3 - "$cli" "$version" "$file" "$metadata" <<'PY'
import json, pathlib, sys
cli, version, fixture, metadata = sys.argv[1:]
meta = json.loads(pathlib.Path(metadata).read_text())
if meta.get("cli") != cli or meta.get("version") != version:
    raise SystemExit(f"capture metadata mismatch for {cli} {version}")
records = [json.loads(line) for line in pathlib.Path(fixture).read_text().splitlines() if line.strip()]
if not records:
    raise SystemExit(f"empty capture for {cli} {version}")
def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)
objects = [obj for record in records for obj in walk(record)]
if cli == "claude":
    okay = any(isinstance(obj.get("contextWindow"), int) and obj["contextWindow"] > 0 for obj in objects)
    okay = okay and any(isinstance(obj.get("input_tokens"), int) and obj["input_tokens"] > 0 for obj in objects)
elif cli == "codex":
    # `codex exec --json` reports per-turn token usage but not the app-server
    # modelContextWindow field. The runner contract check exercises the default
    # app-server transport and requires that provider-stated window separately.
    okay = any(isinstance(obj.get("input_tokens"), int) and obj["input_tokens"] > 0 for obj in objects)
else:
    okay = any(isinstance(obj.get("totalTokens"), int) and obj["totalTokens"] > 0 for obj in objects)
if not okay:
    raise SystemExit(f"capture for {cli} {version} lacks provider context window and usage telemetry")
PY
}

if [[ "$MODE" == check ]]; then
    failed=0
    for cli in claude codex pi; do
        version="$(version_for "$cli")"
        echo "Checking $cli $version"
        check_capture "$cli" "$version" || failed=1
    done
    exit "$failed"
fi

if [[ "$MODE" == check-offline ]]; then
    failed=0
    for cli in claude codex pi; do
        shopt -s nullglob
        metadata_files=("$FIXTURE_DIR/$cli-"*.meta.json)
        shopt -u nullglob
        if [[ "${#metadata_files[@]}" -ne 1 ]]; then
            echo "expected one committed $cli metadata file in $FIXTURE_DIR" >&2
            failed=1
            continue
        fi
        metadata="${metadata_files[0]}"
        version="$(python3 - "$metadata" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("version", ""))
PY
)"
        if [[ -z "$version" ]]; then
            echo "missing committed version in $metadata" >&2
            failed=1
            continue
        fi
        echo "Checking committed $cli $version fixture (installed CLI not consulted)"
        check_capture "$cli" "$version" || failed=1
    done
    exit "$failed"
fi

if [[ "$MODE" == catalogs ]]; then
    CATALOG_DIR="$ROOT/Sources/ContinuumRevivedCoreChecks/Fixtures/context-meter/catalogs"
    mkdir -p "$CATALOG_DIR"
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/array-context-cli-catalog.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT INT TERM
    mkdir -p "$SCRATCH/cwd" "$SCRATCH/tmp"
    claude_version="$(version_for claude)"
    codex_version="$(version_for codex)"
    pi_version="$(version_for pi)"
    printf '%s\n' '{"type":"control_request","request_id":"array-models","request":{"subtype":"initialize"}}' >"$SCRATCH/claude.stdin"
    (cd "$SCRATCH/cwd" && TMPDIR="$SCRATCH/tmp" ARRAY_CLI_STDIN_FILE="$SCRATCH/claude.stdin" bounded claude -p --input-format stream-json --output-format stream-json --verbose \
        --tools '' --strict-mcp-config --setting-sources '' --settings '{"disableAllHooks":true}') >"$SCRATCH/claude.stdout" 2>"$SCRATCH/claude.stderr"
    # --bundled avoids a network refresh. This command only prints model
    # metadata; it does not start an agent or launch configured MCP servers.
    bounded codex debug models --bundled >"$SCRATCH/codex.stdout" 2>"$SCRATCH/codex.stderr"
    (cd "$SCRATCH/cwd" && TMPDIR="$SCRATCH/tmp" bounded pi --list-models --no-tools --no-extensions --no-skills --no-context-files) >"$SCRATCH/pi.stdout" 2>"$SCRATCH/pi.stderr"
    python3 - "$CATALOG_DIR" "$claude_version" "$codex_version" "$pi_version" "$SCRATCH" <<'PY'
import datetime, json, pathlib, sys
dest, cv, xv, pv, scratch = sys.argv[1:]
dest, scratch = pathlib.Path(dest), pathlib.Path(scratch)
# Keep the raw provider catalogues as evidence. These contain model names and
# public context limits only; no prompts, credentials, or user paths.
claude_lines = []
for line in (scratch / "claude.stdout").read_text(errors="replace").splitlines():
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    if obj.get("type") == "control_response" and (obj.get("response") or {}).get("request_id") == "array-models":
        claude_lines.append(obj)
if not claude_lines:
    raise SystemExit("claude initialize catalog response was not captured")
claude_catalog = claude_lines[0]
envelope = claude_catalog.get("response", {})
payload = envelope.get("response", {})
models = payload.get("models", [])
safe_models = [{key: model[key] for key in ("value", "resolvedModel", "displayName") if key in model}
               for model in models if isinstance(model, dict)]
if not safe_models:
    raise SystemExit("claude initialize response contained no model entries")
safe_claude = {"type": "control_response", "response": {
    "subtype": envelope.get("subtype"), "request_id": "array-models",
    "response": {"models": safe_models}}}
(dest / f"claude-{cv}.json").write_text(json.dumps([safe_claude], indent=2) + "\n")
codex_catalog = json.loads((scratch / "codex.stdout").read_text())
codex_models = []
for model in codex_catalog.get("models", []):
    codex_models.append({key: model[key] for key in ("slug", "display_name", "context_window") if key in model})
(dest / f"codex-{xv}.json").write_text(json.dumps({"models": codex_models}, indent=2) + "\n")
(dest / f"pi-{pv}.txt").write_text((scratch / "pi.stdout").read_text())
manifest = {
    "captured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "sources": {
        "claude": {"version": cv, "command": "claude -p initialize control request", "window_fields": "No model window field is published by initialize."},
        "codex": {"version": xv, "command": "codex debug models", "format": "raw JSON output"},
        "pi": {"version": pv, "command": "pi --list-models", "format": "raw table output; context values are CLI-reported"},
    },
}
(dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
    echo "Captured CLI model catalogues in $CATALOG_DIR"
    exit 0
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/array-context-cli-capture.XXXXXX")"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT INT TERM
mkdir -p "$TEMP_ROOT/cwd" "$TEMP_ROOT/tmp"

capture() {
    local cli="$1" version="$2" model="$3" output="$4" status="$5" append="${6:-false}"
    local scratch="$TEMP_ROOT/cwd/$cli"
    mkdir -p "$scratch"
    case "$cli" in
        claude)
            (cd "$scratch" && TMPDIR="$TEMP_ROOT/tmp" bounded claude -p --output-format stream-json --verbose \
                --include-partial-messages --model "$model" --permission-mode bypassPermissions \
                --tools '' --strict-mcp-config --setting-sources '' --settings '{"disableAllHooks":true}' "$PROMPT") >"$output" 2>"$status"
            ;;
        codex)
            # Ignore the user's MCP/plugin config while retaining CLI-owned
            # authentication under CODEX_HOME. --ephemeral keeps the capture
            # out of the user's rollout/session store.
            (cd "$scratch" && TMPDIR="$TEMP_ROOT/tmp" bounded codex exec --ignore-user-config --ephemeral --json --skip-git-repo-check \
                -c approval_policy=never -c sandbox_mode=workspace-write -m "$model" -C "$scratch" "$PROMPT") >"$output" 2>"$status"
            ;;
        pi)
            (cd "$scratch" && TMPDIR="$TEMP_ROOT/tmp" bounded pi -p --mode json --model "$model" --thinking low \
                --no-session --no-tools --no-extensions --no-skills --no-context-files "$PROMPT") >"$output" 2>"$status"
            ;;
    esac
    python3 - "$cli" "$version" "$model" "$output" "$FIXTURE_DIR/$cli-$version.jsonl" "$FIXTURE_DIR/$cli-$version.meta.json" "$append" <<'PY'
import datetime, json, pathlib, re, sys
cli, version, model, source, fixture, metadata, append = sys.argv[1:]
source_path = pathlib.Path(source)
lines = source_path.read_text(errors="replace").splitlines()
records = []
for line in lines:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    if cli == "claude":
        if value.get("type") == "system" and value.get("subtype") == "init":
            value = {key: value[key] for key in ("type", "subtype", "model", "claude_code_version") if key in value}
        elif value.get("type") == "stream_event" and (value.get("event") or {}).get("type") == "message_start":
            pass
        elif value.get("type") == "assistant":
            pass
        elif value.get("type") == "result":
            value = {key: value[key] for key in ("type", "subtype", "usage", "modelUsage", "is_error") if key in value}
        else:
            continue
    elif cli == "codex":
        if value.get("type") not in ("thread.started", "turn.completed"):
            continue
    else:
        if value.get("type") == "session":
            pass
        elif value.get("type") == "message_end" and (value.get("message") or {}).get("role") == "assistant":
            pass
        else:
            continue
    def scrub(value, key=""):
        if isinstance(value, dict):
            return {k: scrub(v, k) for k, v in value.items() if not re.search(r"(?i)(api.?key|authorization|access.?token|refresh.?token|secret|email|path|cwd)", k)}
        if isinstance(value, list):
            return [scrub(item, key) for item in value]
        if isinstance(value, str):
            if re.search(r"(?i)(text|content|result|signature|uuid|session.?id|thread.?id|request.?id|call.?id|item.?id|message.?id|api.?message.?id|^id$|prompt|output|stdout|stderr|command|arguments)$", key):
                return "<redacted>"
            value = re.sub(r"/(Users|private|var|tmp)/[^\s\"']+", "<redacted-path>", value)
            value = re.sub(r"(?i)(sk-[A-Za-z0-9_-]{12,}|[A-Za-z0-9_-]{32,})", "<redacted-secret>", value)
            return value
        return value
    records.append(scrub(value))
if not records:
    raise SystemExit(f"{cli} produced no JSON records; raw output retained only in temporary storage")
fixture_path = pathlib.Path(fixture)
metadata_path = pathlib.Path(metadata)
old_meta = json.loads(metadata_path.read_text()) if append == "true" and metadata_path.exists() else {}
models = list(dict.fromkeys(old_meta.get("models", [old_meta["model"]] if old_meta.get("model") else []) + [model]))
with fixture_path.open("a" if append == "true" else "w") as stream:
    stream.write("".join(json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n" for record in records))
metadata_path.write_text(json.dumps({"cli": cli, "version": version, "model": model, "models": models, "captured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "turn": "tool-free tiny prompt", "scrubbed": True}, indent=2) + "\n")
PY
    check_capture "$cli" "$version" || return 1
    echo "Captured $cli $version ($model)"
}

if [[ "$MODE" == capture-model ]]; then
    cli="claude"
    version="$(version_for "$cli")"
    model="$2"
    echo "Running real $cli $version tiny turn for $model in $TEMP_ROOT/cwd/$cli"
    if ! capture "$cli" "$version" "$model" "$TEMP_ROOT/$cli-$model.jsonl" "$TEMP_ROOT/$cli-$model.stderr" true; then
        echo "$cli capture failed; stderr was discarded with the temporary workspace" >&2
        exit 1
    fi
    echo "Appended $cli $version ($model)"
    exit 0
fi

for cli in claude codex pi; do
    version="$(version_for "$cli")"
    case "$cli" in
        claude) model="sonnet" ;;
        codex) model="gpt-5.6-sol" ;;
        pi) model="openai-codex/gpt-5.6-sol" ;;
    esac
    echo "Running one real $cli $version tiny turn in $TEMP_ROOT/cwd/$cli"
    if ! capture "$cli" "$version" "$model" "$TEMP_ROOT/$cli.jsonl" "$TEMP_ROOT/$cli.stderr"; then
        echo "$cli capture failed; stderr was discarded with the temporary workspace" >&2
        exit 1
    fi
done
