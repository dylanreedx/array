# WS3 dispatch — measured performance and power-user soak

## Shared workstream target

This packet defines **WS3: performance health, zoom, and the realistic power-user workload** in Array. Begin only from the I1 checkpoint supplied as `<BASE_SHA>`. The rendered `<ROLE>` controls authority: a lead profiles and implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, `docs/internals/performance.md`, `.plans/44-performance-audit-2026-08-21.md`, the master plan, and `00-agent-protocol.md`. Work in `<WORKTREE>` and write every raw artifact under `<EVIDENCE_DIR>`.

### Outcome

Find and fix measured causes of sustained CPU, zoom judder, excessive layout, memory growth, and disk churn under the reported workload. Do not promise a generic “optimization pass”: leave structural witnesses that make the expensive work countable.

The required corpus is:

- three isolated projects;
- four active managed agents per project (exercise Claude/Codex/Pi semantics without requiring paid/network calls in the deterministic fixture); in each project one agent owns a 10,000-row long transcript and the other three own 2,000 rows each, for 48,000 rows total;
- two local deterministic browser tiles per project;
- a 100,000-entry synthetic file tree with batched change bursts;
- deterministic relay polling at 4 polls/second with 10 event updates/second during active windows;
- pan, scroll, magnify `0.50 → 2.00 → 0.50`, and concurrent transcript/browser/file activity.

### Evidence-led starting points

- `/Library/Logs/DiagnosticReports/Array_2026-08-28-095904*.cpu_resource.diag` attributes sustained CPU chiefly to the file-tree outline reload/layout path.
- `FileTreeScanner` emits growing full snapshots during scanning; the MainActor can queue all of them and `FileTreeTileNSView` reloads the whole outline.
- A separate disk-write diagnostic is dominated by CFURLCache SQLite work. Relay polling currently uses shared/default URLSession behavior and is a code-grounded hypothesis, not yet a proven cause.
- Existing measurements have reproduced red `--perf-budget-zoom-check` and `--perf-budget-magnify-slope-check`. Current scenarios do not cover active agents + browsers + long transcript + zoom together.

Treat these as investigation leads. Re-profile before and after. Do not change unrelated code merely because it looks expensive.

### Inspect first

- the diagnostic files above and any newer Array `.cpu_resource.diag`, `.hang`, `.ips`, or Jetsam reports, checking process/version/event time
- `Sources/ContinuumRevived/Canvas/FileTreeScanner.swift`
- `Sources/ContinuumRevived/Canvas/FileTreeTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `Sources/ContinuumRevived/Canvas/CanvasWorldPlaneView.swift`
- managed transcript virtualization/layout code
- browser runtime/snapshot/residency paths
- relay client transport/session/cache configuration
- `Sources/ContinuumRevived/App/PerfScenarios.swift`
- `Sources/ContinuumRevived/App/QAPerf.swift`
- `Sources/ContinuumRevivedCore/PerfBudget.swift`
- `Sources/ContinuumRevivedPerfChecks/`
- `scripts/run-perf-ceilings.sh`, `qa/perf-baseline.json`, and current perf matrix legs

### Owned scope

Own performance-specific changes in these paths plus focused checks/QA flows. Any semantic change to zone behavior, transcript hierarchy, awareness, or page zoom is outside scope and must be escalated to root. Changes to `qa/perf-baseline.json` require root approval backed by raw before/after runs; never raise a ceiling to create green.

This workstream owns remediation and evidence for all five current performance-related KNOWN-RED flags: `--perf-budget-zoom-check`, `--canvas-zoom-invalidation-probe-check`, `--perf-budget-magnify-slope-check`, `--perf-budget-gesture-transition-check`, and `--tile-surface-residency-check`. All five must be green and removed from the allowlist through a reviewed change before this workstream can pass.

### Required procedure and witnesses

1. Spend at most the first 90 minutes producing a fresh profile/counter ranking for the pinned build. If no reproducible hot path or structural counter can be established, stop and return `BLOCKED`; do not start speculative edits.
2. Capture the exact same-machine release-build matrix below at `<BASE_SHA>` and on the candidate:

| Case | Deterministic input | Process/reset rule | Repetitions and measurement | Required output |
|---|---|---|---|---|
| `camera-zoom` | 12 agent + 6 local browser tiles; 120 magnify steps 0.50→2.00→0.50 | fresh process/store per repetition; one unmeasured warm-up trajectory | 5 × one 30 s window | `camera-zoom-run-01..05.json` |
| `transcript-delta` | three 10k-row + nine 2k-row transcripts; seed `0x08030001`; 10 deltas/s | fresh process/store per repetition; anchor fixed before start | 5 × one 30 s window | `transcript-delta-run-01..05.json` |
| `file-tree-burst` | 100k paths; seed `0x08030002`; ten bursts of 512 changes | fresh scanner/view/store per repetition | 5 complete scans | `file-tree-run-01..05.json` |
| `relay-cache` | local deterministic server; 4 polls/s and 10 updates/s; seed `0x08030003` | fresh cache/store per repetition | 5 × one 30 s window | `relay-run-01..05.json` |
| `compound` | full three-project corpus above; seed `0x08030004`; all activities concurrent | fresh process/store per repetition; one unmeasured 60 s warm-up | 5 × one 60 s window | `compound-run-01..05.json` |

Every file records binary SHA/configuration, seed, sample count, p50/p95/p99/worst, structural counters, CPU/RSS/storage, and all failures. Never discard a bad repetition. Re-run a repetition only for a proven environment failure with unchanged code and retain both attempts.
3. Add signposts/counters around the suspected work:
   - file-tree snapshot production, coalescing, outline reload/update, and row layout;
   - canvas layout passes and installed tile subtree layouts per camera step;
   - transcript projection/measurement/layout work per delta and zoom;
   - browser surface/residency updates;
   - relay requests, cache writes, and persisted bytes.
4. Fix only causes confirmed by trace/counters. Likely acceptable shapes include bounded/coalesced file-tree deltas and a non-caching relay session, but the evidence chooses the implementation.
5. Required structural teeth:
   - camera/zoom work does not grow linearly with all installed content when nothing inside changed;
   - no repeated transcript measurement on a steady camera step;
   - a file-tree burst coalesces to a bounded number of UI applications/reloads rather than one per partial snapshot;
   - an unchanged relay poll performs zero response-cache database writes;
   - view/layer and resident working sets remain bounded after settle.
6. Run a 60-minute candidate soak with the compound corpus, sampling CPU/RSS/storage/view/layer/counter state every 10 seconds. Extend to 120 minutes if final-15-minute RSS exceeds the first stable 15-minute median by more than 10%, or final-15-minute steady CPU exceeds the first stable median by more than 25%, even if no hard blocker has fired. Write `soak-samples.jsonl`, `soak-summary.json`, and the DiagnosticReports before/after diff.

Blocking failures: crash/hang/new CPU exception or disk-write diagnostic, main-thread stall over 100 ms during scripted input, monotonic unbounded memory/view/layer growth, state corruption, a structural count regression, or any of the five assigned performance KNOWN-RED legs remaining red. A root waiver may end investigation, but it cannot turn this branch or release candidate into PASS/READY. CPU/RSS drift below hard limits and cross-machine absolute pixel/timing variation are advisory but must be reported.

Do not capture screenshots inside timed intervals. Capture before, zoom extrema, mid-stream, and final settled states afterward to prove visual integrity; collect an Instruments/Time Profiler trace or `sample`, signpost export, `vmmap`, perf JSON, and diagnostic diff.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build -c release
swift run -c release ContinuumRevivedPerfChecks
.build/release/Array --perf-budget-zoom-check
.build/release/Array --canvas-zoom-invalidation-probe-check
.build/release/Array --perf-budget-camera-slope-check
.build/release/Array --perf-budget-transcript-delta-check
.build/release/Array --perf-budget-gesture-transition-check
.build/release/Array --perf-budget-magnify-slope-check
.build/release/Array --tile-surface-residency-check
.build/release/Array --perf-budget-raster-check
.build/release/Array --perf-budget-geometry-hold-probe-check
.build/release/Array --perf-budget-surface-host-slope-check
.build/release/Array --perf-power-user-compound-check
CONTINUUM_PERF_CONFIGURATION=release \
CONTINUUM_PERF_APP="<WORKTREE>/.build/release/Array" \
CONTINUUM_PERF_OUT="<EVIDENCE_DIR>/perf-ceilings" \
CONTINUUM_PERF_RUN_ID="<RUN_ID>-ws3" \
scripts/run-perf-ceilings.sh
swift run -c release ContinuumRevivedFileTreeChecks
swift run -c release ContinuumRevivedRelayChecks
```

Confirm exact existing product/flag names from `Package.swift` and source before execution; enumerate current flags before first invoking the new compound flag. The promoted Wave-0 runner already honors `CONTINUUM_PERF_CONFIGURATION=release` and rejects a mismatched debug app—treat regression of that contract as a blocker, not WS3-owned setup. Add the deterministic compound scenario under the exact `--perf-power-user-compound-check` flag and register it in the durable matrix/inventory.

### Stop rules

Stop if the baseline cannot be reproduced, the diagnostic belongs to a different build/process than assumed, a proposed fix requires changing product semantics, or the only way to pass is rebaselining/allowlisting. Do not run paid/live providers; use deterministic local streams. Do not capture or expose user transcript/project data.

### Success

The measured hot paths are fixed with structural witnesses, all five assigned performance KNOWN-RED gates are honestly green and removed from the allowlist, the compound workload completes its soak without crash/hang/corruption, and root receives inspectable raw traces, metrics, and visual boundary captures.

## Independent reviewer overlay

Correlate every implementation claim to a before/after counter or profile. Inspect for content-proportional work in `layout()`, repeated unchanged frame assignment, full outline reloads, unbounded queues/caches, default HTTP caching, retain cycles, and measurement during camera gestures. Reject time-only tests without structural teeth and any budget weakening.

## Independent tester overlay

From a clean release build, reproduce the five-run matrix exactly and run an independent 30-minute compound soak sampled every 10 seconds; the lead's retained 60/120-minute soak remains the long-duration evidence. Do not edit or rebaseline. Collect signposts/trace, sample/spindump, vmmap, raw perf JSON, storage writes, screenshots outside timed regions, and new DiagnosticReports. FAIL on crashes, hangs, corrupt state, hard threshold breach, missing raw samples, or any of the five assigned performance legs remaining red.
