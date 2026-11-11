# Offline replay machinery

Replays one task two ways, a solo agent and a Managed lead that may delegate,
on Claude and Codex, and records tokens, time and whether the task's own
checks pass. Everything here runs fake agent processes. There is no live
runner, no usage budget, and nothing stops or caps a run because of spend.
The manifest has zero historical tasks; curation is step 4 of plan 15. The
synthetic two-commit repository tests the machinery, not model quality. No
session transcripts, memory or other projects supply any text.

## Run it

```
REPLAY_DRIVER_ONLY=1 PYTHONDONTWRITEBYTECODE=1 scripts/run-matrix.sh
python3 benchmarks/replay/mutation_checks.py
python3 benchmarks/replay/mutation_driver.py
```

The first runs the four Python legs and `--replay-driver-check` (it builds
`array-workspace-mcp` and `Array`, debug). The other two are the mutation
proofs; their output is kept in `mutation-results.txt` and
`driver-mutation-results.txt`.

## One record schema

`manifest.json` holds the only field list (`recordFields`, with types and
meanings). `replay.write_record` and `ReplayRecordSchema.write` are the one
writer per language; both refuse a record whose keys differ from the list,
and refuse a sink inside a run directory. `replay.compare` reads both.
The task id has one derivation, `replay.task_id(base, requestHash,
checksHash)`; Swift copies it from `task.json` and never derives one.
`ledgerTask` and `tokens.cacheRead`/`cacheWrite` are reserved and null
until the run ledger (branch `array/run-ledger`) and typed cache counters
are on this base.

A record is written before its run directory is cleaned, for every outcome,
including driver failures and refused storage.

## Conditions and delegation

The Swift driver submits the request to a lead through `AgentSupervisor.send`
and does nothing else to the run. It mounts one project through the
production boot mount so the workspace API has its scene.

- Managed: the lead's record is Managed with workspace tools on. The fake
  lead calls `tools/call array_delegate` through the production
  `array-workspace-mcp` server named in its own launch configuration, which
  reaches `WorkspaceAPIService.delegate` and `handleSpawnRequest`. Helper
  count and each helper's checkout come from the production records. The
  first helper shares the lead's checkout; the concurrent second gets its own
  worktree. A Managed lead that delegates nothing is recorded with
  `fannedOut: false`, kept, and never compared as fan-out.
- Solo: the lead's workspace tools are off, so its launch carries no MCP
  server and the workspace API refuses it (the driver probes this). The
  runner's own spawn channel is closed by `ReplaySpawnGate`: every request
  there is counted in `delegationAttempts` and never forwarded. Zero helpers
  is asserted on the production record. A solo run with an attempt or a
  helper is excluded from comparison.

The run ends when no agent is running and the production supervisor has no
helper result still on its way to the lead.

## Usage

Usage is read from production-delivered events. The fakes emit recorded
streams through the production translators: Claude
`claude-2.1.291-opus-turn.jsonl` (a new result uuid per turn, as the CLI
does), Codex `codex-appserver-single-agent.jsonl` (a persistent thread, so
later turns continue the running total). Every usage report is delivered
twice.

- Claude: de-duplicated by `accountingObservationID` per agent. A report
  without one makes usage incomplete.
- Codex: running totals differenced per session and per token type. A total
  that goes down (reset), a forked session, or a turn with no usage report
  (gap) makes usage incomplete and the totals null, never zero or negative.
- `TokenUsageSnapshot` has no typed cache counters, so cache is unknown and
  every Swift record is usage-incomplete today. The comparison therefore
  prints no difference for any driver record yet. That is the honest result.

## Grading

`replay.grade(task, tree)` grades a finished working copy on a pristine
export of the base. Hidden checks are the fix commit's added checks, held in
host memory; neighbouring checks come from the pristine export. Only the
agent's changes to unprotected paths are carried over, including new and
deleted files. Changing, adding or deleting a protected path, or leaving a
link or special file, is tampering: the verdict is `tampered` and the run is
not a pass. Nested checkouts (helper worktrees) and host-owned paths (`.git`,
`.array`) are not content.

Each check runs in its own sandboxed process under a host-owned harness
passed with `-c`. A pass requires the harness's own report for that check,
tagged with a per-check nonce, on a pipe only the harness was handed. An
exit status is never a result: an import-time `os._exit(0)` gives
`noResult`, `sys.exit(0)` gives `error:SystemExit`. `validate` requires every
hidden check to fail by assertion on the parent (an error is not RED) and the
fix to pass.

## Containment

`sandbox_profile` (Python) and `ReplaySandbox` (Swift) deny by default. They
allow reads of the run root and the toolchain only (system libraries, `/bin`,
`/usr/bin`, the interpreter's own prefix, `/dev`), writes only inside the run
root, signals only inside the sandbox, no mach services and no network. Each
run root holds the project export and its own support, build, tmux,
temporary and home directories; the environment is built fresh, with no
`TMUX`. The working copy is an export of the base tree with only the base
commit object, so no later object is reachable.

Ownership is a directory this process created, checked by path, device and
inode, and not a link; a caller-made or replaced directory is refused.

Sandbox experiment (`socket_experiment`, a socket the test owns in its own
temporary directory): a unix-socket connect is denied under the deny-default
profile, and connects once a `network-outbound` unix-socket rule names that
path. So the profile, not some other effect, is what blocks it. Before this
change the allow-default profile also blocked unix-socket and loopback TCP
connects (its `deny network*` covers both), but allowed reading the host
repository and `~/Library/Application Support`, listing `/private/tmp`, and
signalling processes outside the sandbox. All four are denied now. The
first, second and fourth are witnessed by `--replay-containment-check`;
`/private/tmp` was checked only in the one-off experiment.

## Mutation proofs

Each is shown RED for its named reason, then GREEN restored:
an exit(0) fools the grader; a tampered check file; a run reads the host
repository; a run writes outside its directories; a Managed run that did not
delegate is compared as fan-out; a comparison from a failed pair; from an
unmatched pair; a failed run's record vanishes (Python); a solo run that
delegates; a Codex stream with a reset; a failed run's record vanishes
(Swift). An import, syntax or build failure never counts as RED.

## Before a live pilot

- Typed cache counters on `TokenUsageSnapshot` (plan part 14). Until then no
  pair compares.
- The run ledger's task id joined into `ledgerTask`.
- A live adapter that runs the real CLI runner inside this sandbox. It needs
  provider egress, which `sandbox-exec` can only filter by address and port,
  not host name, so network isolation against answer leakage needs another
  mechanism or the run is invalid. It needs loopback to the workspace MCP
  host port, and the CLI's own login state without Array copying or storing
  credentials. None of this exists.
- Claude's built-in Agent tool and Codex's own subagents cannot be closed
  through any Array route. In a live solo run they arrive as observed
  children: counted as attempts, and the run excluded. Disabling them needs
  a launch option production does not have.
- Curated historical tasks with Swift graders and compile receipts; the
  chooser mode (needs part 1); a coding rubric for `humanSteps`; a
  disposable-socket check before any terminal-enabled adapter.

## Limits

Grading has to run agent-written code. It runs sandboxed, but a check and the
code it imports share a process, so an agent that knew the harness protocol
could read the nonce and forge a report. Plan 15 already treats grader
blindness as a validity constraint, not a security guarantee.
