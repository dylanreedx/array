# Offline replay machinery

Status: partial steps 1–3. No live runner exists. Nothing launches Array or a
provider, touches app state, uses tmux, or enforces a usage budget.

Run the offline witnesses from the repository root:

```
python3 benchmarks/replay/check.py --replay-grader-check
python3 benchmarks/replay/check.py --replay-isolation-check
python3 benchmarks/replay/check.py --replay-scoring-check
```

The version 1 manifest deliberately has zero historical tasks. Historical
curation is step 4. The witness builds one synthetic two-commit repository,
using the repository's existing commit identity, solely to test validator
behavior; it is not a pilot task or evidence about model quality.

The validator exports parent and fix trees, checks the immutable grader hash,
rejects syntax/tool errors as RED, and requires an assertion failure on the
parent and pass on the fix. This small Python-only validator does not yet
extract/build Swift grader patches or retain their build logs.

The workspace exports a single base tree and reconstructs its exact commit
object without ancestors, remotes or future objects. Each run gets separate
project, support, build and tmux directories. Links and special files fail
closed. These are filesystem preparation primitives, not a sandbox. Live
launch always raises: process and network containment, disposable tmux server
verification, and a production supervisor/delegation adapter remain required.
No tmux process is started even in witnesses.

The fake runner terminates its scripted stream before applying its diff in a
fresh grading tree; hidden and neighboring outcomes stay separate. Records
include failures, interruption, timeout, union active time, terminal wall time,
human steps and hashes. Timeout here is a recorded fixture outcome, not a
witness of killing a hung process. Token fixtures are deduplicated message
deltas, not proof of Claude/Codex translator accounting. Unknown cache values
stay null. Every figure in comparison output has run/pair counts and coverage;
missing, duplicate or incomplete pairs suppress the difference. Output is
explicitly simulated and must never support an efficiency claim.

## Ledger and telemetry seam

`task` is a UUID: the live adapter must use the host ledger's task identity,
never infer it from prompts. Fake fixtures use a deterministic UUID only for
matching tests. `run` identifies a condition/repeat; base/request/grader hashes
identify matched input. Benchmark artifacts are separate from ledger rows;
do not append this format to `ManagedRunLedger`. That ledger currently accepts
v1 metadata rows through its single append path and has no typed usage schema.
The later adapter must consume its published task and typed observation seam.
Input includes cached input; cacheRead is a subset, never added again. CacheWrite
is unknown when absent. Cumulative resets/gaps/forks must mark usage incomplete;
no live counter translation is implemented here.

## Before the pilot

Implement and witness the production headless supervisor and real delegation
adapter, enforce process/network isolation, verify a unique disposable tmux
socket, record durable raw artifacts and interrupted-process cleanup, and bind
typed telemetry to ledger task IDs. Curate 9–12 public-history tasks with private
grader patches and actual compiled assertion RED/GREEN receipts. Pin models,
CLI/host versions, completion/timeout rules and repetitions. Then add an explicit
live command: none is available today. Pilot design is three tasks × two
harnesses × three modes; report all use, including failures, with no spend cap.
Chooser integration depends on part 1. This bench makes no live-readiness claim.

## Verification receipt

Initial execution of all three witness names failed before implementation with
`ModuleNotFoundError: replay`. That is an observed missing-implementation RED,
not a behavioral assertion RED. After implementation, all three passed through
`REPLAY_CHECKS_ONLY=1 scripts/run-matrix.sh`; its summary reported 3 legs run.
The first scoring attempt failed because its coverage expectation counted four
pairs instead of the two harness pairs; corrected the expectation to 2/2.
A concurrent second matrix invocation was refused by the existing matrix lock.
The full matrix and production supervisor/runner/token-meter checks were not run;
no Swift build, app launch, real tmux or provider execution occurred.

This does not fulfill the entire requested production driver or its required
behavioral RED-before proof. It is a reviewable offline subset, with those gaps
explicitly left open rather than presented as live-ready machinery.
