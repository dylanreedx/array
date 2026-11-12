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
Schema v3 takes its usage fields from the run ledger (below): `ledgerTask`,
`tokens` by the ledger's four types (`uncachedInput`, `cacheRead`,
`cacheWrite`, `output`), `tokensNotReported`, `usageComplete`,
`usageProblems`, `usageRows`, `helperCount`, `fannedOut`, `wallSeconds` and
`activeSeconds`.

A record is written before its run directory is cleaned, for every outcome,
including driver failures and refused storage.

## Conditions and delegation

The Swift driver submits the request to a lead through the composer's human
submission, `AgentSupervisor.accept(.sendPrompt)`, the path that opens a run
ledger task, and does nothing else to the run. It mounts one project through the
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

Every usage field comes from the run's own run ledger,
`<run root>/support/run-ledger/ledger.jsonl`, the supervisor's Application
Support for that run and never the user's. After the run the driver drains
the ledger queue and reads the file with `RunLedgerUsageReader`, then derives
the task's figures with `UsageReport.make`, the usage page's own functions.
It has no usage arithmetic of its own.

| Field | Source |
| --- | --- |
| `ledgerTask` | the one task the lead's submission opened |
| mode check | the task's `mode` (`managed` or `free`) must match the condition |
| `helperCount`, `fannedOut` | the task's `delegated` rows; must equal the production records |
| `tokens` | the task's figure per type, lead and helpers together |
| `tokensNotReported` | types the harness never reports (Codex `cacheWrite`): null, and not incomplete |
| `usageComplete` | the page's "fully counted" (closed, every type known or not reported), and no row flag |
| `usageProblems` | unknown types, a task not closed, and the rows' flags (`noBaseline`, `reset`, `fork`, `noUsage`, ...) |
| `usageRows` | each usage row: agent, lead or helper, parent, harness, model, model source, turn, tokens, flags |
| `wallSeconds` | the page's time to answer: opening submission to close |
| `activeSeconds` | the page's active time: the union of every agent's turns in the task, up to its close |
| `leadTurnsAfterClose` | the lead's turns that started after its task closed and that no helper result woke: in no task, not in `tokens` (0 in a normal run) |
| `afterCloseProblems` | those turns' row flags, `noTask` left out (`reset`, `noUsage`, ...) |

Missing is never zero: an unknown type is null. A ledger that disagrees with
the production records (task count, mode, helper count) fails the run as
`driverFailed`.

The fakes emit recorded streams through the production translators: Claude
`claude-2.1.291-opus-turn.jsonl` (a new result uuid per turn, as the CLI
does), Codex `codex-appserver-single-agent.jsonl` on the agent's own thread
with a fresh turn id and later provider times per turn. Each turn after the
first resumes the thread with the marker `CodexAgentRunner` sets, so the
ledger keeps its baseline from the first. Every usage report is delivered
twice. The witness compares the record with the figures
`--request-telemetry-check` works by hand from the same captures: one Claude
turn is 2 / 10,695 / 11,239 / 124 (uncached / cache read / cache write /
output) and the Codex thread is 7,652 / 57,344 / not reported / 313, times
the turns the fakes ran. A Codex lead resuming a thread from an earlier
process (`codexResumed`) has no baseline and is incomplete; a reset is
incomplete; the comparison prints a difference per type for a matched
complete pair and refuses a pair with an incomplete record.

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
root, signals only inside the sandbox, no mach services and no network.
Grading may also run programs from inside the run root, because a task's
own check scripts write helpers there and run them, plus each single binary
the task declares in `tools` (the perf task declares `node`). Each
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
unmatched pair; from an incomplete pair; a type a harness never reports read
as missing; a failed run's record vanishes (Python); a solo run that
delegates; a Codex resume without a baseline read as complete; the ledger
rows' flags dropped; missing counted as zero; Codex cache writes counted as
incomplete; helpers' usage left out of the task; a failed run's record
vanishes (Swift). An import, syntax or build failure never counts as RED.

## Live runs

`run_pilot.py` runs real Claude Code agents through `Array
--replay-live-run`. The production runner launches each agent's CLI through
`live_claude.py`, which runs the real CLI in a deny-default sandbox. The CLI
signs in with its own Keychain login and keeps its config and sessions in the
run root. It can reach only a host proxy that forwards to `api.anthropic.com`,
and this run's workspace MCP port. `live-config.json` holds the model, effort,
deadline, allowed hosts and arms. `pilot-results.md` has the runs so far, and
the sandbox rules in full.

Arms:

- `solo`: Managed mode off. The lead has the workspace MCP server, as every
  production agent does, and the workspace API refuses its delegation call by
  call. `delegationAttempts` counts each refused `array_delegate` call, read
  from the lead's session file, plus anything on the runner's spawn channel.
- `managed`: Managed mode as built. The lead loses Edit and Write but keeps
  its shell.
- `managed-strict`: Managed mode with the strict-lead switch on, so the lead's
  shell cannot write its checkout. The switch is an environment variable named
  in `live-config.json` (`strictLeadSwitch.env`). While that is null, the arm
  is reported as not runnable and skipped.

Every agent in every arm runs with the CLI's own subagent tool (`Agent`,
`Task`) switched off, so the only fan-out is delegation through Array.

`leadChanges` records what the lead changed itself, from its own session file.
`editToolCalls` and `delegateCalls` are exact counts. `shellWrites` lists the
Bash commands that look like writes: redirects, `sed -i`, `git apply`, Python
`open(..., 'w')` and the like. It is a heuristic, so the verdict names its
basis:

- `yes: edit tool`
- `likely: shell write (heuristic)`
- `none seen`
- `unknown`, when the session file is missing

How to read the cache columns: the provider's prompt cache is warm or cold
depending on what ran just before, so cache read and cache write in one run
depend on the run before it. The arms rotate per task, so each arm runs
first, second and third about equally often across tasks. Each record's
`runOrder` gives its position and the task's sequence. Compare cache columns
across arms only over the whole set, or at matching positions. Within a
single task, a difference in cache write between arms is mostly run order.
Uncached input and output do not depend on order.

The comparison (`replay.py compare`) prints every run as a row: grade, wall
and active time, tokens by type in total and per agent, helpers, what the
lead changed, delegation attempts and run order. A Managed run that did not
fan out is never compared as fan-out, but it is still shown beside solo as
"managed, did not fan out", with its differences.

Temp folders: macOS `mktemp` uses the per-user system temp folder even when
`TMPDIR` is set, so `mktemp -d` failed inside a run. `live-bin/mktemp` is
first on the agent's PATH and puts default and `-t` names in the run's own
`tmp`, which is `TMPDIR`. Python's `tempfile` already honours `TMPDIR`. A
script that hard-codes `/tmp`, or calls `/usr/bin/mktemp` by full path, still
cannot write there.

Tasks (`pilot_tasks.py`, each validated to fail on its base and pass on its
real fix):

| Task | Size | From | What |
|---|---|---|---|
| prepass-deleted-once | small | ac055cd2 | a deleted file listed twice in the pre-pass coverage report |
| prepass-targeted-only | small | 2f96d775 | let the coverage manifest declare hand-run checks, with validation |
| replay-ledger-schema | medium | 0421980d | move the replay record to the ledger's four token types (replay.py and manifest.json) |
| perf-runner-interrupt | medium | d7bdc709 | clean up the perf runner's temp folders and app on SIGINT/SIGTERM, and extend its contract test |
| three-independent-fixes | larger | 9f7fc19e, 02bb9f34, 7270328f | three parts in three files: the banner census, a cost line in the motion analyser, resolved MCP paths |

`prepass-two-parts` is a separate delegation test: its request asks for one
helper per part, so it is never paired with a solo run.

## Before a live pilot

Usage is now complete for fake runs. These remain for the owner to decide:

- Network and login inside containment. A real CLI needs provider egress and
  loopback to the workspace MCP port, and `sandbox-exec` filters by address
  and port, not host name, so it cannot stop answer leakage. The CLI also
  needs its own login state inside the run without Array copying or storing
  credentials. No mechanism exists for either.
- Claude's built-in Agent tool and Codex's own subagents cannot be switched
  off through any Array route, so a live solo run can still fan out. The
  driver counts what it sees as attempts and excludes the run; a Claude
  in-process subagent's usage is inside its parent's (`reportedByParent`).
  Disabling them needs launch options production does not have.
- A live adapter that runs the real runner inside this containment. None
  exists; `liveEnabled` is false.
- Real usage. A live run spends subscription usage and nothing caps it, by
  design. Which tasks, how many repeats per condition, and who starts a run.
- Time figures. Time to answer ends when the task closes; a Managed lead's
  wake turns after the close still count in active time, so on a fan-out run
  active time can exceed time to answer. Decide which figure is compared.
- Codex never reports cache writes, so Codex comparisons cover three types.
- The ledger writes `delegated` rows only for `array_delegate`. A helper a
  runner starts through its own spawn channel has none, so the ledger's
  helper count misses it; the driver then fails the run (the ledger and the
  production records disagree) and the solo witness reads the records.
- Curated historical tasks with graders and compile receipts (the manifest has
  none); the chooser mode; a coding rubric for `humanSteps`; a
  disposable-socket check before any terminal-enabled adapter.

## Limits

Grading has to run agent-written code. It runs sandboxed, but a check and the
code it imports share a process, so an agent that knew the harness protocol
could read the nonce and forge a report. Plan 15 already treats grader
blindness as a validity constraint, not a security guarantee.
