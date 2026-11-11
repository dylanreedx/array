# Offline replay machinery

No live CLI runner is enabled. No usage budget is requested or enforced.
The version 1 manifest contains zero historical tasks; curation is step 4.
One synthetic two-commit repository tests the machinery, not model quality.
No session transcripts, memory or other projects supply prompts.

Run offline Python checks, including a real sandboxed fake subprocess:

```
REPLAY_CHECKS_ONLY=1 PYTHONDONTWRITEBYTECODE=1 scripts/run-matrix.sh
python3 benchmarks/replay/mutation_checks.py
```

The matrix subset reports grader, isolation, scoring and containment as four
separate legs. Mutation checks change disposable copies of the implementation,
run the same witnesses, restore the implementation and rerun. Both outputs
are retained in `mutation-results.txt`. They test invalid graders accepted,
future git objects imported, outside writes permitted and incomplete matched
pairs reported. Missing-module failures are not counted as behavioral RED.

The validator exports parent and fix trees, checks the immutable grader hash,
rejects syntax/tool errors as RED, and requires an assertion failure on the
parent and pass on the fix. It currently supports Python grader source, not
extracted Swift patches with separate compilation receipts.

`Workspace` exports only a base tree and reconstructs its exact commit object
without ancestors, remotes or future objects. Each run has separate project,
support, build and tmux directories. Links and special files are rejected.
`ContainedRun` creates its own temporary root and uses macOS sandbox-exec to
deny network and all writes except those owned directories. It refuses replaced
storage before launching. The witness permits an in-project write, denies an
outside sentinel write and confirms the sentinel unchanged. Real sleeping
fake processes are killed/reaped on deadline or interruption, with process-group
cleanup. No real tmux server is used. Disposable tmux socket verification remains
required before a terminal-enabled adapter can launch.

`run_contained` appends one fsynced JSONL record per returned subprocess outcome,
including condition, fixture ID, hashes, wall/active time, hidden result and
failure/timeout/interruption. It grades a fresh tree only after termination.
Its usage counters remain null and incomplete until typed telemetry is joined.
The scripted scoring fixture independently proves message deduplication, typed
input/output sums, interval union, hidden/neighbor failures and failed-record
preservation. Cached input is a subset of input; unknown cache values stay null.
Comparisons show run/pair counts and coverage and suppress differences for
missing harnesses, missing/duplicate pairs or incomplete observations. These
are simulated records, never evidence of a model efficiency improvement.

## Production supervisor seam

`ReplaySupervisorDriver` in `ReplayDriverChecks.swift` exercises
`AgentSupervisor.spawn` → `send` with `ScriptedAgentRunner` injection, for Claude
and Codex, solo and forced Managed fan-out. Fan-out uses `handleSpawnRequest`,
the same child-creation funnel called by `WorkspaceAPIService.delegate`. It does
not exercise that service's approval, dispatch or canvas presentation layer.
It verifies exact lead prompt delivery, the selected condition's child count,
helper execution and completed runner cleanup. Its store is isolated; storage
must belong to the driver's in-memory set of roots created by `createRoot`,
resolve under temporary storage, and contain the project. Caller-created marker
files cannot confer ownership. The headless entry uses dispatchMain, no window.

After preparing GhosttyKit and a successful debug build, the targeted entry is:

```
.build/debug/Array --replay-driver-check
```

The supervisor injects `ReplayContainedScriptedRunner`: before delivering its
scripted stream it starts kernel-contained fake subprocesses and checks an
allowed write plus outside-write denial. Python separately covers real deadline
and interruption cleanup. A real CLI adapter is deliberately absent; do not
substitute a CLI for these fakes without witnessing its full lifecycle.

## Ledger seam and remaining pilot work

`task` is a UUID. A live adapter must consume the host ledger's task identity,
not infer it from prompts. Fake fixtures use deterministic UUIDs for matching;
`run` identifies a condition/repeat. Benchmark artifacts are separate from ledger
rows; never append this record format to `ManagedRunLedger`. Its reviewed v1
metadata append seam has no published typed usage schema yet. Bind counters via
part 14's typed observation seam when available; cumulative reset/gap/fork
handling must mark usage incomplete, not manufacture totals.

There is no live pilot command. Remaining prerequisites: extend containment to the real CLI runner lifecycle; join typed telemetry and ledger IDs; preserve
raw event/build/grader receipts; validate extracted Swift graders; verify an
isolated tmux socket if used; pin host/CLI/model versions; curate 9–12 public-history
tasks and actual assertion RED/GREEN receipts. Three eligible tasks × two
harnesses × three modes form the later pilot. Chooser requires part 1. Report all
usage, including failures, with no spend cap. No quality or efficiency claim is
supported by offline witnesses.

The production-driver witness additionally records input/output counters from
`addDeliveredEventObserver`, deduplicated by agent plus observation identity,
and union active intervals measured at each contained runner. Its held fake
turns are stopped deliberately, so their receipts say interrupted and never
pass the task. Missing cache counters remain null, with usage incomplete. A
startup failure writes a failed receipt with unavailable measurements unknown.
These witness receipts are not eligible pilot results: host ledger task IDs,
typed cache observations and hidden task grading still need their published
production seams. `TokenUsageSnapshot` on this base has input/output accounting
fields but no typed cache counters; the separately revised run-ledger branch
is not a dependency of this bench.

The targeted driver matrix, after GhosttyKit preparation, is:

```
REPLAY_DRIVER_ONLY=1 scripts/run-matrix.sh
python3 benchmarks/replay/mutation_driver.py
```

The second command builds a deliberate delegation bypass, observes the child
count assertion fail, restores the source, rebuilds, and observes GREEN. It
never substitutes a real provider for the contained scripted runners. Build
logs remain local and ignored; check output is retained in
`driver-mutation-results.txt`.

## Observed verification

`mutation-results.txt` contains behavioral RED and restored GREEN for grader,
isolation, scoring and containment. `driver-mutation-results.txt` contains
`--replay-driver-check` RED (`condition produced wrong child count` after bypassing
delegation) and GREEN for all four harness/mode conditions after restoration.
Both mutation scripts test build/check exit status directly.

During development, the first Swift build failed because the driver source was
edited during compilation. Later successful debug builds superseded it. The
first driver executions failed because a Foundation-resolved `/var` path was
not canonical enough for sandbox subpath matching; POSIX `realpath` fixed this.
The next run exposed a witness race that stopped Codex before queued usage
observations arrived; waiting for the expected observations fixed it. These
failures are resolved, not excluded from the verification history.

Still blocked for eligible pilot records: the base branch has no host run-ledger
task identity ingress and `TokenUsageSnapshot` lacks typed cache counters. The
separate ledger branch is under revision and was read only through its documented
seam. Until parts 12/14 publish these joins, production-driver receipts cannot be
promoted to complete benchmark records. Extracted historical hidden graders and
a live CLI adapter also remain prerequisites for the later pilot. The full matrix
was not run under the targeted-only instruction; no installed app or tmux server
was accessed, and no provider process was started.
