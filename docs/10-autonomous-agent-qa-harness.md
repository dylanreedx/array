# Autonomous Agent QA Harness Plan

**Status:** Proposed
**Date:** 2026-06-05
**Scope:** Pi-agent orchestration + Continuum native macOS QA harness. No implementation in this document.

## Goal

Make Continuum safe for autonomous and parallel agent development by giving agents a repeatable way to build, launch, inspect, interact with, and review the app with structured evidence.

The target is not just “run tests.” The target is: every coding agent can prove what changed, what it tested, what failed, and where artifacts live, without relying on vague visual claims.

## Current Project State

Conductor currently reports the original task queue complete (`35/35 passed`), but the repository contains uncommitted UX work around tile deletion, close buttons, focus/z-order, and canvas gesture routing. Before further feature work, the project needs a stronger autonomous QA layer so future agents can validate native AppKit behavior themselves.

## Principles

1. **False-positive resistance over safety theater.** The main risk is not that an agent deletes the machine; it is that an agent confidently claims something works when it does not.
2. **Evidence over vibes.** Every autonomous run writes artifacts: logs, screenshots, accessibility trees, crash diffs, command outputs, and a final verdict.
3. **Assertions over descriptions.** A screenshot plus “looks good” is not enough. Each flow needs explicit pass/fail assertions against state, UI hierarchy, logs, or persisted files.
4. **Layered testing.** Core/unit checks, native UI checks, visual/screenshot checks, browser checks, and review checks are separate gates.
5. **Native macOS first.** Playwright is useful for web/browser content, but AppKit canvas testing should use XCTest, Accessibility API, or Appium-style automation.
6. **Agent-readable output.** Reports must be concise markdown/JSON that Pi agents can consume and compare.
7. **Project-local harness, global Pi orchestration.** Continuum owns its QA scripts. Pi owns agent coordination, dashboards, and cross-project patterns.
8. **No hidden success.** Passing means explicit assertions passed and no new crash reports appeared.
9. **Parallel where safe.** Research, design, code review, and independent check suites can run in parallel. Mutating code in parallel requires branches/worktrees or strict task isolation.

## Anti-False-Positive Contract

The harness should be designed primarily to prevent persuasive but wrong agent reports.

### Completion is forbidden without evidence

An agent may not call a task complete unless it supplies:

1. the exact verification command it ran,
2. the exit code,
3. the QA run directory,
4. the specific assertions that passed,
5. any skipped checks,
6. screenshots/AX trees for native UI work,
7. crash-diff result.

Bad completion statement:

```text
I tested it and it works.
```

Acceptable completion statement:

```text
Ran qa/run-autonomous.sh --flow delete-tile-close-button.
Exit: 0.
Run: qa-runs/20260605T120000Z.
Assertions passed: close button visible, click removed tile from CanvasState, NoteState entry removed, relaunch did not resurrect tile, no new crash reports.
Skipped: none.
```

### Every UI flow needs an oracle

A UI test must define what observable fact proves success. Examples:

- Palette opened: AX tree contains palette role/name and screenshot includes palette bounds.
- Note spawned: CanvasState contains a `.note` tile and AX tree contains note text view.
- Tile deleted: CanvasState no longer contains tile ID, related note/browser/file-tree state no longer references it, and relaunch does not restore it.
- Focus changed: `lastActiveTileId` changed and z-order changed.
- Pan/zoom worked: canvas transform changed by expected range.

### Negative checks are required

For each important flow, add at least one check proving the old/broken behavior is absent:

- deleted tile does not reappear after relaunch,
- Cmd-Backspace inside note text does not delete the tile,
- mouse wheel over file tree still scrolls file tree rather than panning canvas,
- trackpad gesture over tile pans canvas only when expected,
- failed browser/terminal runtime does not leave a live stale descriptor.

### Reviewer agents must be adversarial

A reviewer should ask:

- What would make this appear to pass while still being broken?
- Did the agent assert the actual user-visible behavior or just internal state?
- Did it test persistence/relaunch if persistence changed?
- Did it test focus/first-responder behavior if keyboard or click handling changed?
- Did it accidentally weaken smoke checks or expectations?
- Are screenshots from after the action, or just launch screenshots?

### Artifact quality gates

A QA artifact bundle is invalid if:

- `manifest.json` is missing,
- command exit codes are missing,
- screenshot timestamps do not align with the flow,
- AX tree was captured before but not after,
- crash diff was not run,
- the verdict says passed while any gate failed,
- skipped checks are not listed explicitly.

## Testing Layers

### Layer 0: Static and build gates

Purpose: catch cheap failures before launching the app.

Commands:

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run ContinuumRevivedPaletteChecks
swift run ContinuumRevivedFileTreeChecks
node scripts/check-package-targets.js
node scripts/check-qa-flows.js
git diff --check
```

Artifacts:

```text
qa-runs/<run-id>/build/stdout.log
qa-runs/<run-id>/build/stderr.log
qa-runs/<run-id>/build/verdict.json
```

### Layer 1: Existing smoke harness

Purpose: verify deterministic boot seams already built into the app.

Use existing environment-driven smoke support such as:

```bash
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived
```

Expected checks:

- app launches
- deterministic terminal/browser/note/file/file-tree fixtures appear
- no crash reports are created during run
- existing smoke gates still pass

Artifacts:

```text
qa-runs/<run-id>/smoke/stdout.log
qa-runs/<run-id>/smoke/stderr.log
qa-runs/<run-id>/smoke/crash-diff.txt
qa-runs/<run-id>/smoke/manifest.json
```

### Layer 2: Native UI automation

Purpose: let agents perform and verify real macOS interactions.

Preferred stack:

1. **XCTest UI tests** for first-party app workflows.
2. **Accessibility API probe** for external black-box inspection and Pi tool integration.
3. **Appium Mac2** only if we need cross-language/client compatibility later.

Required flows for v0:

- `cmdk-opens-palette`: launch app, send Cmd-K, assert palette appears.
- `spawn-note`: use palette to spawn note tile, assert note tile exists in AX tree and canvas state.
- `spawn-file-tree`: spawn file tree, assert rows render and app remains responsive.
- `delete-tile-close-button`: click tile close affordance, confirm policy if needed, assert tile removed and persistence updated.
- `delete-tile-cmd-backspace`: focus canvas, send Cmd-Backspace, assert active tile removed.
- `pan-zoom-canvas`: send trackpad-like scroll/magnify or test seam equivalent, assert canvas transform changes.
- `focus-z-order`: click inside tile body, assert last-active tile and z-order update.

Artifacts:

```text
qa-runs/<run-id>/ui/<flow>/events.jsonl
qa-runs/<run-id>/ui/<flow>/ax-before.json
qa-runs/<run-id>/ui/<flow>/ax-after.json
qa-runs/<run-id>/ui/<flow>/screenshot-before.png
qa-runs/<run-id>/ui/<flow>/screenshot-after.png
qa-runs/<run-id>/ui/<flow>/verdict.json
```

### Layer 3: Browser / web automation

Purpose: test BrowserTile web content and external browser workflows.

Use Playwright for:

- local fixture pages loaded in BrowserTile
- navigation states
- JavaScript execution
- screenshot comparison of web content
- external docs/research pages when needed

Do not use Playwright as the main AppKit canvas driver. It cannot reliably test NSView layout, Cmd-K palette behavior, terminal tiles, or native focus.

Potential approaches:

1. Expose a debug URL or local fixture route for BrowserTile.
2. Add a test seam that loads deterministic HTML into a browser tile.
3. Use Playwright to validate the page itself, while native UI automation validates that the BrowserTile is embedded and visible.

### Layer 4: Visual and UX review

Purpose: catch layout regressions that compile/tests miss.

Inputs:

- screenshots from each flow
- accessibility tree summaries
- canvas state before/after
- app logs

Review checks:

- close buttons visible but not noisy
- focused tile visually distinct
- palette placement sane
- note/file/file-tree surfaces readable
- no accidental black/blank tiles
- z-order matches user action
- panning/zooming does not steal normal tile scrolling unexpectedly

This layer can be done by a Pi reviewer agent using screenshots/artifacts, not by mutating code.

## Harness Directory Layout

```text
qa/
  run-autonomous.sh              # one command for agents
  flows/
    cmdk-opens-palette.sh
    spawn-note.sh
    spawn-file-tree.sh
    delete-tile-close-button.sh
    delete-tile-cmd-backspace.sh
    pan-zoom-canvas.sh
    focus-z-order.sh
  macos/
    ax-dump.swift                # dump AX tree as JSON
    ax-action.swift              # click/type/key/drag helper, if needed
    screenshot.swift             # deterministic screenshot helper
    crash-diff.sh
  playwright/
    package.json
    browser-tile.spec.ts
  expectations/
    cmdk-opens-palette.md
    spawn-note.md
    spawn-file-tree.md
    delete-tile.md
  reviewer-prompt.md
qa-runs/
  <run-id>/
    manifest.json
    verdict.md
    build/
    smoke/
    ui/
    browser/
    review/
```

## `qa/run-autonomous.sh` Contract

Agents should be able to run:

```bash
qa/run-autonomous.sh --scope changed
qa/run-autonomous.sh --scope full
qa/run-autonomous.sh --flow delete-tile-close-button
```

The script must:

1. create `qa-runs/<timestamp-or-id>/`
2. record git status and HEAD
3. run selected gates
4. capture stdout/stderr separately
5. collect screenshots and AX trees for UI flows
6. diff crash reports before/after
7. write `manifest.json`
8. write `verdict.md`
9. exit non-zero on failure

Example `manifest.json` shape:

```json
{
  "runId": "20260605T120000Z",
  "head": "abc1234",
  "dirty": true,
  "scope": "changed",
  "startedAt": "2026-06-05T12:00:00Z",
  "completedAt": "2026-06-05T12:03:00Z",
  "gates": [
    { "name": "swift-build", "status": "passed", "durationMs": 42000 },
    { "name": "cmdk-opens-palette", "status": "failed", "artifactDir": "ui/cmdk-opens-palette" }
  ],
  "crashes": [],
  "verdict": "failed"
}
```

## Pi Extension: `continuum-qa`

Create a project-local Pi extension first:

```text
.pi/extensions/continuum-qa/index.ts
```

Later, extract reusable pieces globally:

```text
~/.pi/agent/extensions/native-qa/
~/.pi/agent/extensions/harness-agents/
```

### Tools

Register tools callable by Pi agents:

- `continuum_qa_run`
  - args: `scope`, `flow`, `timeoutSeconds`
  - runs `qa/run-autonomous.sh`
  - returns concise verdict + artifact path

- `continuum_qa_artifacts`
  - args: `runId?`
  - lists recent QA runs and artifact paths

- `continuum_qa_read_verdict`
  - args: `runId`
  - returns `verdict.md` and manifest summary

- `continuum_qa_ax_tree`
  - args: `runId`, `flow`, `phase`
  - returns summarized AX tree, not massive raw JSON by default

- `continuum_qa_compare_screenshots`
  - args: `runId`, `flow`
  - optional future tool for visual diffs

### Commands

Register slash commands:

```text
/qa              run changed-scope QA
/qa-full         run full QA
/qa-flow <name>  run one native flow
/qa-runs         show recent QA runs
/qa-open <id>    open artifact directory or print path
```

### TUI view

A later custom component can show:

```text
┌ qa runs ───────────────────────────────────────────────┐
│ id              status   gates        artifact          │
│ 20260605-1200   failed   8/9          qa-runs/...       │
│ 20260605-1130   passed   9/9          qa-runs/...       │
├────────────────────────────────────────────────────────┤
│ j/k move • enter inspect • r rerun • o open • q close   │
└────────────────────────────────────────────────────────┘
```

This uses Pi extension custom TUI components. It is not needed for v0.

## Pi Agent Orchestration Model

Yes, mass parallel coordination is possible, but it needs boundaries.

### Safe parallelism

These can run in parallel immediately:

- research agents
- design/spec agents
- static review agents
- screenshot/UX review agents
- independent QA flows that only read state or use isolated fixture projects
- build/check agents if they use separate derived data or do not mutate shared files

### Risky parallelism

These need isolation:

- multiple agents editing the same working tree
- multiple app-launch UI tests using the same `.continuum-revived` state
- multiple agents writing to the same `qa-runs/latest` path
- multiple agents using the same simulator/app instance/window

### Required isolation for parallel coding

Use one of:

1. **Git worktrees** per agent.
2. **Dedicated project fixture directories** per QA flow.
3. **Unique QA run IDs** and no shared mutable output path.
4. **One writer, many reviewers**: only one coding agent mutates; many reviewer/test agents inspect artifacts.

Recommended initial model:

```text
orchestrator
  ├─ coder agent: implements one scoped change
  ├─ tester agent: runs qa/run-autonomous.sh --scope changed
  ├─ reviewer agent: reviews diff + QA artifacts
  └─ UX reviewer agent: reviews screenshots + AX tree
```

For true mass parallel implementation later:

```text
orchestrator
  ├─ worker A in .pi/worktrees/task-a
  ├─ worker B in .pi/worktrees/task-b
  ├─ worker C in .pi/worktrees/task-c
  ├─ tester pool runs QA in each worktree
  └─ integrator merges one approved branch at a time
```

## Agent Roles

Project-local Pi agents should live under:

```text
.pi/agents/
  continuum-coder.md
  continuum-native-tester.md
  continuum-ux-reviewer.md
  continuum-code-reviewer.md
  continuum-integrator.md
```

### `continuum-coder`

- Implements one scoped task.
- Must not mark done without a QA artifact path.
- Does not hide skipped tests.

### `continuum-native-tester`

- Runs `continuum_qa_run` or shell fallback.
- Diagnoses failures.
- Produces artifact paths and reproduction commands.
- Does not edit production code unless explicitly asked.

### `continuum-ux-reviewer`

- Reads screenshots, AX trees, expectations docs.
- Flags visual regressions and interaction mismatches.
- Does not edit production code.

### `continuum-code-reviewer`

- Reviews diff, architecture, concurrency, persistence, and AppKit lifecycle.
- Checks for hidden focus/gesture regressions.

### `continuum-integrator`

- Combines approved work.
- Runs full QA.
- Writes handoff.
- Does not commit unless explicitly asked by the user.

## How This Connects to Conductor

Conductor can continue tracking tasks, but the quality gate should change:

A task is not “passed” unless it records:

1. changed files
2. commands run
3. QA run ID
4. artifact directory
5. known skipped gates
6. unresolved risks

The Pi `continuum-qa` extension can become the evidence producer. Conductor can remain the queue/task memory system.

## First Implementation Phases

### Phase A: Design and stabilize current dirty work

1. Review current uncommitted UX diff.
2. Decide whether it is one task or multiple tasks.
3. Run existing build/smoke commands manually.
4. Fix compile failures before adding new harness complexity.

### Phase B: QA script v0

1. Add `qa/run-autonomous.sh`.
2. Add crash-diff collection.
3. Add manifest/verdict writing.
4. Wrap existing build/core/smoke checks.
5. Ensure non-zero exit on failure.

### Phase C: Native inspection v0

1. Add `qa/macos/ax-dump.swift` or equivalent.
2. Add screenshot capture helper.
3. Add one flow: `cmdk-opens-palette`.
4. Add one flow: `delete-tile-close-button` after current UX work compiles.

### Phase D: Pi extension v0

1. Add `.pi/extensions/continuum-qa/index.ts`.
2. Register `continuum_qa_run`.
3. Register `/qa` and `/qa-flow`.
4. Return concise artifact summaries to agents.

### Phase E: Agent roles

1. Add `.pi/agents/continuum-native-tester.md`.
2. Add `.pi/agents/continuum-ux-reviewer.md`.
3. Add `.pi/agents/continuum-code-reviewer.md`.
4. Test one orchestrated loop manually.

### Phase F: Parallel orchestration

1. Add worktree-per-agent convention.
2. Add run registry under `.pi/agent-runs/` or `qa-runs/`.
3. Add `/agents` or `/qa-runs` dashboard integration.
4. Only then allow multiple coding agents to mutate in parallel.

## What To Defer

- Full Appium integration.
- Pixel-perfect visual diffing.
- Playwright MCP extension unless browser-tile work resumes.
- Multi-agent auto-merge.
- Automatic commits.
- Complex TUI dashboard before tool/command v0 works.
- tmux-backed agent process management until QA artifacts are reliable.

## Risks / Footguns

1. **False positives.** The primary risk is agents convincing themselves and the user that behavior works based on incomplete checks.
2. **Screenshot-only review.** Screenshots help review but must not replace state/assertion checks.
3. **Testing the seam, not the feature.** Debug seams can pass while real user interaction is broken. Every seam needs at least one real interaction flow.
4. **Persistence blind spots.** Many canvas bugs only appear after relaunch. Tile create/delete/state changes should include relaunch checks.
5. **Focus flakiness.** Native UI tests can fail if another app steals focus. Tests should launch isolated and record active app/window.
6. **Accessibility permissions.** AX tests require macOS Privacy & Security approval. The harness must detect and report missing permission clearly.
7. **Shared state contamination.** Use fixture project roots for UI tests, not the developer’s normal project state.
8. **Parallel app launches.** Multiple UI flows launching the same bundle can fight each other. Use serialized UI tests or isolated app instances where possible.
9. **Playwright mismatch.** Playwright is excellent for web content, not native AppKit canvas behavior.
10. **Agent overreach.** Reviewer/tester agents should not silently edit code; keep roles strict.
11. **Artifact bloat.** `qa-runs/` needs retention/pruning.
12. **Dirty worktree ambiguity.** Every run must record dirty files so reviewers know what was tested.

## Initial Definition of Done

Autonomous QA v0 is working when a Pi agent can run:

```text
/qa
```

…and receive:

```text
QA failed: 7/8 gates passed
Run: qa-runs/20260605T120000Z
Failed: delete-tile-close-button
Artifacts: screenshot-after.png, ax-after.json, stderr.log
Next: inspect qa-runs/20260605T120000Z/verdict.md
```

Then another reviewer agent can inspect that artifact directory and provide a useful review without re-running the whole app manually.
