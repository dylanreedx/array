# Harness bridge contract (CON-88)

Status: frozen consumer contract for Continuum canvas readers. Producer changes to these files/tables must update this document first.

## Agent run directory

Location: `.pi/agent-runs/<runId>/`. A run id is an opaque stable string, currently `<role>-<UTC timestamp>-<suffix>`.

Validated examples (2026-06-13):

- `.pi/agent-runs/code-reviewer-20260612T131634Z-742280/`
- `.pi/agent-runs/qa-reviewer-20260613T002237Z-4c5eea/`
- `.pi/agent-runs/code-scout-20260612T201740Z-f54e35/`

### `run.json`

Required fields for readers:

- `id` string: equals the directory name.
- `role` string: agent role name, for display only.
- `status` string: terminal/non-terminal state. Known terminal value is `done`; readers must tolerate unknown values and display them literally.
- `task` string: prompt/task text supplied to the run.
- `cwd` string: working directory used by the run.
- `createdAt` ISO-8601 string.
- `updatedAt` ISO-8601 string.
- `artifacts` object: relative paths to known artifacts. At minimum readers should understand `events`, `final`, `summary`, and `structured` when present.

Optional/version-tolerant fields observed: `startedAt`, `endedAt`, `model`, `reasoning`, `tools`, `tmux`, `parentRunId`, `chainStep`, and `pid`. Missing optional fields must not fail rendering; process termination details such as `exitCode` and `signal` are observed on `events.jsonl` `finished` events.

### `control.json`

Continuum-spawned runs MUST be launched in their own process group before execing the harness command and MUST write `.pi/agent-runs/<runId>/control.json` atomically before exec. This is the kill/cleanup handle; consumers must never infer a kill target by process search.

Required fields:

- `runId` string: equals the directory name and the descriptor binding; kill controls must reject mismatches.
- `processGroupId` integer: positive PGID used for `kill(-processGroupId, SIGTERM)` and, after the grace period, `SIGKILL` if the group still exists.

Optional fields:

- `pid` integer: process id of the group leader at wrapper startup, useful for diagnostics only.
- `createdAt` ISO-8601 string.

### `events.jsonl`

UTF-8 JSON Lines. Each line is an event object. Required common fields:

- `ts` ISO-8601 string.
- `type` string.

Observed lifecycle events:

- `started`: includes `pid`, `command`, and `args` (array of strings).
- `finished`: includes `status`, `exitCode`, and `signal`.

Readers must skip malformed lines, preserve order by file order, and treat unknown event types as displayable raw events rather than errors.

### `final.md` and `summary.md`

Markdown/plain-text final outputs. `final.md` is the authoritative human result. If `final.md` is missing or exactly `(no output)`, workflow agents treat the run as failed even if `run.json.status` says `done`; UI readers should show that as a warning. `summary.md` is optional supporting text.

### Other run files

`output.json`, `activity.json`, `system-prompt.md`, `system-prompt.resolved.md`, `stdout.log`, and `stderr.log` are optional diagnostic artifacts. Readers may link to them but must not require them.

## QA run manifests

Location: `qa-runs/**/manifest.json`. These are check-specific JSON manifests, not one global schema. Required reader contract:

- Parse as JSON object.
- If present, `verdict` is a string such as `passed`.
- If present, `check` names the producing check.
- Preserve unknown keys for an inspector view.

Observed examples include app-bundle manifests with `bundlePath`, `bundleIdentifier`, `bundleSelfChecks`, and `verdict`, and check manifests with keys such as `tempProjectRoot`, `tileId`, `frames`, or persistence-specific fields. Missing `verdict` is allowed; readers should display `unknown` rather than fail.

## Conductor SQLite database

Location: `.conductor/conductor.db`. Open read-only with a busy timeout. Missing DB means empty state, not an app error.

Tables consumed by canvas readers:

### `projects`

Required columns:

- `id` TEXT PRIMARY KEY
- `name` TEXT NOT NULL UNIQUE
- `project_type` TEXT NOT NULL
- `workspace_path` TEXT nullable
- `depends_on` TEXT nullable
- `ready_threshold` INTEGER NOT NULL DEFAULT 30
- `created_at` INTEGER unix epoch

### `tasks`

Required columns:

- `id` TEXT PRIMARY KEY
- `project_id` TEXT references `projects(id)`
- `category` TEXT NOT NULL
- `phase` INTEGER NOT NULL
- `description` TEXT NOT NULL
- `steps` TEXT nullable
- `depends_on` TEXT nullable
- `status` TEXT NOT NULL DEFAULT `pending`
- `priority` INTEGER NOT NULL DEFAULT 0
- `attempt_count` INTEGER NOT NULL DEFAULT 0
- `last_error` TEXT nullable
- `updated_at` INTEGER unix epoch
- `session_id` TEXT nullable
- `commit_hash` TEXT nullable
- `archive_reason` TEXT nullable
- `current_phase` TEXT nullable

Useful indexes observed: `idx_tasks_project`, `idx_tasks_status`, `idx_tasks_priority`.

`commits` and `completed_tasks` exist for history/linkage, but v1 queue readers should treat them as optional enrichment.

## CLI invocation contract

Existing conductor runner:

```sh
node .conductor/scripts/autonomous.js <project-name> [--max-budget=N] [--max-iterations=N] [--once] [--provider=codex|claude] [--model=MODEL]
```

Important environment knobs observed: `CONDUCTOR_DIR`, `CONDUCTOR_WORKSPACE`, `CONDUCTOR_AUTONOMOUS_PROVIDER`, `CONDUCTOR_AUTONOMOUS_MODEL`, and `CONDUCTOR_AUTONOMOUS_NODE_BIN`.

Pi role runs, as recorded in `events.jsonl`, invoke `pi --mode json -p --no-session --model <model> --thinking <level> --tools <csv> --system-prompt <path> <task>`. Consumers should not synthesize unreviewed command lines; spawn tickets must route through the documented harness entrypoint for the selected role/provider.

QA harness entrypoint:

```sh
qa/run-autonomous.sh --scope changed
```

`./scripts/run-matrix.sh` is the required repo verification matrix and may create `qa-runs/` artifacts.
