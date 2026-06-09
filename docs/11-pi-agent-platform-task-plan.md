# Pi Agent Platform Task Plan for Continuum QA

**Status:** Proposed
**Date:** 2026-06-05
**Purpose:** Turn the autonomous QA/orchestration idea into concrete build tasks without requiring Screen Recording or external UI-driver permissions immediately.

## Current Constraint

External screenshot-driven flows require macOS Screen Recording permission for the terminal/Pi runner. Enabling that may require restarting Ghostty, so do not depend on screenshots for the next implementation step.

Instead, start with platform tasks that work through deterministic in-process checks, persisted JSON state, logs, and Pi-visible artifacts. Add screenshot/AX flows later.

## Platform Direction

Build a Pi + Continuum agent platform around four layers:

1. **Continuum QA artifact producer** — scripts and app-side test seams produce `qa-runs/<id>` evidence.
2. **Pi QA extension** — `/qa`, `/qa-flow`, and tools that run/read QA artifacts.
3. **Pi job/orchestration extension** — jobs, worktrees, agent roles, status, review routing.
4. **Reviewer/tester agent roles** — fresh-context agents that validate evidence and catch false positives.

## Phase 1 — Permission-Free QA Artifact Foundation

Goal: make false-positive-resistant QA useful without screenshots.

### Task 1.1: Harden `qa/run-autonomous.sh`

Current script exists and passes. Improve it to:

- support `--flow smoke-delete` or `--flow default-smoke`,
- include per-gate command strings in `manifest.json`,
- include stdout/stderr tail summaries in `verdict.md`,
- record app exit codes explicitly,
- record skipped gates explicitly,
- create stable symlink or text pointer `qa-runs/latest.txt`.

Acceptance:

```bash
qa/run-autonomous.sh --scope changed
```

produces a complete `manifest.json` and `verdict.md` with no screenshot dependency.

### Task 1.2: Add crash-diff helper

Add:

```text
qa/macos/crash-diff.sh
```

It should snapshot likely DiagnosticReports before/after app runs and write:

```text
qa-runs/<id>/crash/before.txt
qa-runs/<id>/crash/after.txt
qa-runs/<id>/crash/new.txt
qa-runs/<id>/crash/verdict.json
```

Acceptance:

- no new crash reports => pass,
- new `continuum-revived` crash report => fail.

### Task 1.3: Add state assertion helper

Add a small script/tool:

```text
qa/state/assert-canvas.py
```

Capabilities:

- read `.continuum-revived/canvas.json`,
- assert tile kind counts,
- assert specific tile ID absent/present,
- assert viewport changed,
- assert metadata fields are present/absent.

Acceptance:

```bash
qa/state/assert-canvas.py --canvas <path> --absent-tile <uuid>
```

exits non-zero on failed assertion.

### Task 1.4: Add app-side in-process QA flow for tile deletion

Avoid external clicking for now. Add a new `CONTINUUM_QA_FLOW` value:

```text
delete-tile-state
```

It should use production app code paths as much as possible:

- seed known file/note/browser/file-tree tiles,
- call production `deleteTile(id:)` for a safe target,
- flush canvas/state saves,
- assert tile removed from view state and disk,
- optionally relaunch is deferred to script-level task,
- print explicit check details.

Acceptance:

```bash
CONTINUUM_SMOKE_TEST=1 CONTINUUM_QA_FLOW=delete-tile-state .build/debug/continuum-revived
```

exits 0 only when deletion state assertions pass.

Note: this does not prove the close button hit target yet. It proves the production deletion orchestrator is correct. External click proof comes later.

### Task 1.5: Add relaunch persistence check

Add a script flow that runs app twice with the same fixture project root:

1. first launch deletes a seeded tile,
2. second launch verifies it does not reappear.

Suggested script:

```text
qa/flows-inprocess/delete-persistence.sh
```

No screenshot required.

Acceptance:

- first run passes delete flow,
- second run passes absent-tile assertion,
- artifact bundle records project root and canvas JSON before/after.

## Phase 2 — Pi QA Extension v0

Goal: let Pi agents run/read QA without remembering shell details.

### Task 2.1: Project-local extension skeleton

Create:

```text
.pi/extensions/continuum-qa/index.ts
```

Register commands:

```text
/qa
/qa-full
/qa-flow <name>
/qa-runs
```

Register tools:

```text
continuum_qa_run
continuum_qa_list_runs
continuum_qa_read_verdict
```

Acceptance:

- `/qa` runs `qa/run-autonomous.sh --scope changed`,
- command output returns verdict and run path,
- tool result is concise and artifact-backed.

### Task 2.2: Artifact parser

Extension should parse:

```text
qa-runs/<id>/manifest.json
qa-runs/<id>/verdict.md
```

Return:

- verdict,
- gates passed/total,
- failed gates,
- dirty status summary,
- artifact path.

Acceptance:

A tester agent can call `continuum_qa_read_verdict` and know exactly what failed.

### Task 2.3: Anti-false-positive completion hint

Add extension behavior or command output that reminds agents:

```text
Do not claim success without citing this QA run path and passed assertions.
```

Acceptance:

Every `/qa` result includes artifact path and assertion contract text.

## Phase 3 — Pi Agent Roles

Goal: separate implementation, testing, and review.

### Task 3.1: Native tester agent

Create:

```text
.pi/agents/continuum-native-tester.md
```

Responsibilities:

- run `/qa` or `continuum_qa_run`,
- inspect failed logs,
- summarize exact failure and artifact paths,
- not edit production code unless asked.

### Task 3.2: Code reviewer agent

Create:

```text
.pi/agents/continuum-code-reviewer.md
```

Responsibilities:

- review diff against task,
- check persistence/focus/AppKit lifecycle issues,
- verify QA artifacts match changed behavior,
- flag false-positive risk.

### Task 3.3: UX reviewer agent

Create:

```text
.pi/agents/continuum-ux-reviewer.md
```

For now, without screenshots, it reviews:

- state assertions,
- expected user flows,
- missing visual evidence,
- whether a screenshot/AX flow is needed later.

Once Screen Recording is available, it reviews screenshots too.

## Phase 4 — Job/Orchestration Platform v0

Goal: coordinate work without mass parallel chaos.

### Task 4.1: Job registry format

Create job records under:

```text
.pi/jobs/<job-id>/
  TASK.md
  PLAN.md
  status.json
  qa-run-id.txt
  REVIEW.md
  HANDOFF.md
```

`status.json` shape:

```json
{
  "jobId": "job-...",
  "status": "planned|implementing|testing|reviewing|approved|needs-rework|blocked",
  "branch": null,
  "worktree": null,
  "qaRun": null,
  "agents": []
}
```

### Task 4.2: Job commands

Extension commands:

```text
/job-start <title>
/job-status [id]
/job-plan <id>
/job-review <id>
/job-handoff <id>
```

Acceptance:

A job can be created, updated with QA run path, reviewed, and handed off without Conductor.

### Task 4.3: One-writer/many-reviewers loop

Initial orchestration pattern:

```text
coder implements in current worktree
native tester runs QA
code reviewer reviews diff + QA
UX reviewer reviews behavior evidence
human decides next step
```

Acceptance:

One full task can move through implementing → testing → reviewing → approved/needs-rework.

## Phase 5 — Worktree Parallelism

Goal: scale to multiple coding agents only after the QA/job loop works.

### Task 5.1: Worktree creation command

Add:

```text
/job-worktree <id>
```

Creates:

```text
.pi/worktrees/<job-id>
```

with branch:

```text
agent/<job-id>
```

Acceptance:

A job can run in an isolated worktree with its own QA artifacts.

### Task 5.2: Parallel tester/reviewer pool

Allow multiple read-only agents to review different jobs/artifacts in parallel.

Acceptance:

Multiple jobs can be in review without sharing mutable output paths.

## Phase 6 — External UI Evidence Later

Only after Screen Recording/Accessibility permissions are comfortable.

### Task 6.1: Screenshot capture flow

Re-enable/use existing external flows with `screencapture`.

### Task 6.2: AX tree capture

Add native Accessibility tree dump helper.

### Task 6.3: Close button real-click test

External flow:

```text
qa/flows/delete-tile-close-button.sh
```

Proves actual close button hit target works, not just `deleteTile(id:)`.

Acceptance:

- screenshot before,
- click close affordance,
- screenshot after,
- state absent,
- relaunch absent.

## Recommended Immediate Next Task

Start with **Task 1.1 + 1.2**:

1. improve `qa/run-autonomous.sh`,
2. add crash-diff helper,
3. avoid screenshot/AX permissions entirely.

Then do **Task 2.1**:

4. add Pi `/qa` command.

This gets us a useful platform loop immediately:

```text
/qa → deterministic artifact-backed verdict → reviewer can inspect logs/state
```

without restarting Ghostty or relying on Screen Recording.
