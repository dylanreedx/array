# Managed run ledger

Recording only: no agent snapshot, workspace operation, UI or policy reads this
store. It never gates a submission or applies a budget.

The file is `run-ledger/ledger.jsonl` under `AgentStore.layout`'s channel-specific
Application Support directory (or the explicit `CONTINUUM_APP_SUPPORT` override).
Agent identities belong to that channel. Project `.array/` is shared across
installations and must not hold these records.

Each v1 row carries `v`, `at` (Foundation reference-date seconds), `kind`, `task`,
`agent`, `source`, and `origin` (`host`). Optional fields are `part`,
`previousTask`, `project`, `outcome`, `checks`, `findings`, and `openParts`.
Task, agent, part and project identities are UUIDs. The initial part identity is
the delegated child UUID. Checks and findings contain counts by declared enum
value, never claims of host verification. No text, absolute filesystem paths,
diffs, credentials or report bodies are serialized; the one path a row may
carry is a checkout-relative file name in `leadCheckoutChanged` (gap 20). Report check/finding arrays are
handed off unchanged for background aggregation; only their enum counts persist.

Kinds: `taskOpened`, `submission`, `delegated`, `working`, `reported`,
`turnEnded`, `taskClosed`, `taskInterrupted`. The opening row identifies the lead
and project; delegation rows associate helpers and parts. A human send or queued
submission accepted for any top-level agent, Managed or not, opens or joins its
active task; `taskOpened` records the agent's `mode` (`managed` or `free`), so
solo and fanned-out work can be told apart.
A lead turn ending with no open helper parts closes it. Once the lead has
ended, the last helper report or terminal event also closes it without a wake. Helper wakes do not
open tasks. The next submission links a new task to the prior one. Restart marks
active tasks interrupted without manufacturing terminal helper events.

`ManagedRunLedger.append(_:)` is the single append path. Source event identities
suppress replayed delegation, report and turn facts. Typed report and turn
hand-offs defer aggregation and source formatting to the utility queue. A serial utility queue owns reduction,
recovery and writes. Request paths enqueue metadata and never wait for disk.
Recovery reads complete rows and preserves all previous bytes. If the last
append was torn, the sole append path adds a newline before the recovery fact. Buffered facts
may be lost on process death before their write; this is not a transactional audit
log. Unknown schema versions are not interpreted.

Later parts must extend this schema and append path for observed evidence and
integration object IDs. Typed usage counters are recorded (below). No verified
stage, release stage or acceptance is inferred here. Export, retention, deletion,
compaction snapshots, takeover and usage UI remain later work.

## Review witnesses and timing

The extended `--managed-run-ledger-check` observed RED for each original defect:
restart changed earlier bytes; the last helper report did not close a task with
wakes disabled; a non-temporary storage override was accepted. All three are
GREEN after the fixes. Restart now appends exactly one interrupted fact after
preserving the original byte prefix, including a deliberately torn final row.
Runtime attribution is established only by live submission/delegation, so
transcript replay during restore cannot manufacture new historical outcomes.

Timing uses the production supervisor `accept` and `fileReport` calls over the
fake CLI fixture, with eight warm-up pairs and 100 samples per on/off condition.
Order alternates between pairs; readiness waits are outside the measured calls.
These are whole-call timings, including the pre-existing persistence work.

| Call | Recording | Median (µs) | p95 (µs) |
| --- | --- | ---: | ---: |
| Submission | off | 9493.96 | 35112.08 |
| Submission | on | 9979.21 | 39793.75 |
| Helper report | off | 2617.92 | 32237.29 |
| Helper report | on | 2621.46 | 24481.12 |

The distributions are noisy. This run does not establish zero added latency;
submission median and p95 were higher with recording enabled. Aggregation,
formatting, encoding and ledger disk access are off the request path; the caller
still pays for an asynchronous hand-off.

All twelve previously reported regression arms passed on the final build.
Cross-harness delegation initially failed its selected-mode assertion, then
passed on rerun; no adjacent policy code was changed. Full matrix was not run.

## Request-path cost, measured

`--managed-run-ledger-timing-check` is targeted only, never a matrix leg. It
prints numbers and asserts nothing about time. It refuses to run unless
`CONTINUUM_APP_SUPPORT` is already a temporary directory, then creates and owns
its own temporary support directory. Run it the way the matrix runs an app check:
temporary `CONTINUUM_APP_SUPPORT`, an isolated `TMUX_TMPDIR`, and `TMUX` unset.

What the calling (main) thread does per path:

- Submission (`AgentSupervisor.accept(_:for:)`): a bool read, an enum compare,
  `effectiveMode(for:)` (dictionary reads of `records`, `runners`,
  `helperProviderRetryErrors`, `runningModes`), two more `records` reads, then
  `ManagedRunLedger.submission`: one `queue.async` whose closure captures two
  UUIDs. That is one heap block and one enqueue, which wakes the idle utility
  queue.
- Delegation (`WorkspaceAPIService+Delegation.swift`): one `queue.async`
  capturing two UUIDs and the existing request-id string (retained, not copied),
  behind the same `qaRunLedgerRecording` switch as submission and report.
- Helper report (`fileReport`): a bool read, then one `queue.async` capturing a
  UUID, a `Date` and the report's two arrays (retained, not copied).
- Turn start/end (`working`/`ended`, on the event path): one `queue.async` each.

No path formats strings or dates, encodes, takes a lock or waits on disk on the
calling thread. Source strings, counts, encoding and file I/O all run on the queue.

Part 1 times only those statements on the production supervisor and ledger,
with recording on. It takes 5,000 samples after 200 warm-up samples, each
preceded by a 2 ms pause so the queue is idle, as it is when a person submits.
Part 2 times the whole `accept` call, on and off alternating within each of
1,000 pairs (20 warm-up pairs). Debug build, on a machine running a live Array.

| Run | Submission med / p95 / max (µs) | Delegation med / p95 | Report med / p95 | Paired whole-call on−off median (95% CI) |
| --- | --- | --- | --- | --- |
| A | 8.62 / 19.96 / 116.83 | 3.29 / 9.25 | 3.33 / 9.21 | −19.75 µs (−69.33, 31.54) |
| B | 13.50 / 25.58 / 200.75 | 5.12 / 12.12 | 5.25 / 13.29 | 4.21 µs (−60.58, 64.25) |

Each whole call takes about 21 ms. The paired differences have an interquartile
range near ±0.6–0.9 ms. Both confidence intervals contain zero.

Machine load moves these numbers about 2–3×. Under heavier load, earlier runs
reached a submission median of 27–30 µs, while the enqueue alone, which did not
change, also tripled. A sample is also inflated by whatever ran just before it.
The first statement after an idle pause pays a cold-cache cost. In an in-process
A/B with alternating order, binding a whole `AgentRecord` copy and reading single
fields differed by about 0.5 µs, so nothing on the calling thread is worth
moving. The remaining cost is the main-actor reads and the enqueue itself.

## Constant cost per fact

Each fact costs the same however long the ledger is. One `reduce` keeps the
open parts per task, each part's tasks, delegation order and the owner's last
turn boundary in memory; live appends and the load-time rebuild both run it,
and `append` stays the only writer. Before this, closure scanned every row on
each report or turn end: at 50,001 rows a fact took 5,795 µs against 36 µs on
an empty ledger (161×), and the queue fell minutes behind.

`--managed-run-ledger-check` runs two arms for it (each alone through
`CONTINUUM_LEDGER_REVIEW_CASE=replay|scale`). `replay` drives one fixed call
sequence, with a torn row and a restart, and compares a digest of the rows (times
zeroed, ids renamed by first appearance, keys sorted, since the encoder's key
order differs per process) against the digest the scanning reducer produced.
`scale` preloads 50,001 rows and fails only if a fact costs five times more
than on an empty ledger; it measured 0.99–1.03×.

## Helper evidence, shadow only (plan 8 step 1)

When a helper files a report, the ledger appends one `helperEvidence` row under
its task and part. Nothing reads it: no agent, wake, `wait_agents` result or
UI. It denies and delays nothing. Recording follows `qaRunLedgerRecording`.

**Source.** The runtime observations each translator already emits on the
host-local side channel, keyed by the provider's call id:
`.toolActivity(editing)` carries the absolute paths a call edited, and
`.toolDetail` carries a shell call's command (start) and outcome (end). The
supervisor hands only those two cases to the ledger queue for helpers; command
classification, manifest reading and the fold all run there. Codex sends
several paths in one `fileChange`; `AgentObservedActivity.otherTargets` now
carries the paths after the first (the location projector reads only the
first, as before). `FileChange.path` is reduced to a basename for display, so
it is not used.

**Check identity.** A shell command runs a check when it names a `--*-check`
flag, or a `.py`/`.sh` script the manifest names. The manifest is
`scripts/check-coverage-manifest.json` in the helper's checkout, owned by the
gate pre-pass and read, never copied. A check's identity is the flag in its
`invocation`, else the script.

**Per edited file**, relative to the helper's checkout: `after` (a covering
check completed after the last edit), `before` (only before it), `none` (no
covering run seen), `unmapped` (the manifest maps no check to it), or `unknown`
with a reason: `noManifest`, `checkIncomplete` (a covering run started and did
not finish, or was interrupted, timed out or backgrounded), or
`shellCommandNotObserved` (a shell call after the edit whose command the host
did not see, as when "Show shell commands in transcripts" is off), or
`backgroundJobBeforeCheck` (a shell call before the check left a job running:
a lone `&`, `nohup`, `disown` or `setsid`, or a call the harness reported
backgrounded; the job can write after the check). Each fact names the check,
the edit and check call ids and their order.

**Exit status.** Codex: the numeric `exitCode` the app-server transport
reports (recorded in `codex-appserver-single-agent.jsonl`), unless the command
was compound. Claude: always `unknown` (`notReportedByHarness`); no recorded
fixture shows the host a numeric exit, and a successful Bash result has none.

**What stays unobserved.** Files written by shell commands; edits made by a
Claude in-process subagent (its tool calls are not on the side channel); a
check run rewriting the file it covers, which still reads `after` (the host
sees the check as one call and has no per-file write times; witnessed as such);
a job started inside an unseen (hidden) shell command;
anything before this process started (`observed: notSinceDelegation`);
observations still in the runner's pipe when the report arrives. Counters live
in memory per helper, constant in size per file and check, with no 128-event
window.

**Stored.** Ids, checkout-relative paths, check names, sequence numbers and
fixed words. No command text, output, file contents, diffs or prompt text; an
edit outside the checkout is only counted.

`--helper-evidence-provider-check` drives a Managed Claude lead delegating one
Claude and one Codex helper through the production MCP binary into a temporary
git checkout with a manifest. CLI doubles replay frames in the recorded fixture
shapes through the production runners and translators (no recorded Claude
Edit frame exists; Edit and Write reuse the recorded `file_path` input). It
asserts each status for both harnesses, past 140 calls; that the lead receives
the same message content in the same order, and `array_report` replies the
same, with recording on and off; that no agent receives evidence words; and
that the ledger holds no prompt, content, diff, output, command or absolute
path. It prints the report path's cost with recording on and off.

## Tokens by type per task (plan 14 step 1)

Usage rows (`kind: usage`) carry `harness`, `model`, `modelSource` (`cli` when
the stream named the model, `record` when it came from the agent's record),
`effort`, `parent` (the agent's parent, when it has one), `turn`, `tokens`,
`incomplete` and, for a late row, `late: true`. `tokens` holds `uncachedInput`,
`cacheRead`, `cacheWrite` and `output`; their input sum is the whole prompt. A
key that is absent is unknown, never zero. An empty or blank model id is
recorded as no model.

**Whose row.** Every agent gets its own rows, never folded into another's: a
helper at any depth, and a provider-run child (a Codex child thread), name
their parent and are charged to the task their parent chain leads to. Claude's
in-process subagents have no usage stream of their own; the parent's result
reports them under their own model ids, so their turns write
`incomplete: ["reportedByParent"]`. Usage of an agent with no task in its chain
(a top-level agent no human prompted in this process) is recorded under the
all-zero task id with `noTask`, never dropped.

**Which turn.** A report names its turn (Claude: the translator's turn id;
Codex: the frame's `turnId`). Usage for the agent's open turn waits in memory
and becomes rows when that turn ends, before its `turnEnded`, so a task never
closes ahead of its lead's usage. A turn that reported nothing writes one row
with `incomplete: ["noUsage"]`. A report naming a turn whose rows are already
written becomes a late row at once, for that turn and the task that turn ran
in; it never lands on the running turn. A closing task writes what its agents'
open turns gathered so far (`usage-close` source); a turn that starts before
the previous one's end was seen writes the previous one's with
`turnEndNotSeen`. One turn can therefore have several rows: sum them.

**Claude.** The result's `modelUsage`, split by model (subagents and side
models included); a later numbered result in one process yields only its own
share. Without `modelUsage`, the result's own `usage` under the `system/init`
model. A result id counts once for the life of the process. The run's
main-conversation messages, counted once per message id (Claude re-sends one
message per content block), must equal the result's own `usage`; when they do
not, the row says `unreconciled`.

**Codex.** `thread/tokenUsage/updated` totals are cumulative per thread, so
the ledger differences them per thread in provider time (`emittedAtMs`).
`cachedInputTokens` is a subset of input; uncached is the rest. Codex reports
`cacheWriteInputTokens` as 0 while cached reads grow, so cache write is unknown.
A thread has a trusted baseline only if this process saw it start: a
`thread/start` here, or a child announced here. `CodexAgentRunner` marks the
`thread/started` it synthesizes after `thread/resume`, so a resumed thread is
never mistaken for a new one. Without a baseline (after a relaunch, or a fork)
the first total becomes the baseline, charges nothing and marks the turn
(`noBaseline`, `fork`). A report older than the newest is already inside it and
is ignored. A total that goes down is a `reset`: what ran before is unknown.
No figure is ever negative. The model id is the one `thread/started` named,
where it did.

Counters live in memory on the ledger queue (open turns, a bounded record of
each agent's last 16 turns' tasks, per-thread baselines and seen result ids);
the event path pays one enqueue. Buffered usage is lost if the process dies
before its turn ends or its task closes. The switch is Settings, Agents, Token
usage (`agents.tokenTelemetry.enabled`, on by default). Off records nothing
from that moment and deletes nothing; Codex baselines stay current, so turning
it back on never charges the off period to a task. Rows hold ids, model ids,
turn ids, fixed words and numbers; never prompt text, paths or diffs. They stay
on this Mac.

`--request-telemetry-check` (cases through `CONTINUUM_TELEMETRY_CASE`: `lead`,
`free`, `helpers`, `codex`, `codex-off`, `codex-relaunch`, `codex-late`,
`codex-child`, `empty-model`) drives the production composer `accept`,
`array_delegate` (including a helper's own helper) and `array_report` through
the MCP binary, with CLI doubles replaying committed captures through the
production runners and translators. `codex-relaunch` reopens the ledger
(`qaReopenRunLedger`) and resumes the thread; `empty-model` drives the ledger
seam directly; one duplicate case delivers events through `qaDeliver`. It
asserts exact totals worked by hand from the captures. Each behaviour was
observed RED by breaking it: per-message dedupe, result dedupe, provider-time
ordering, per-thread differencing, fork detection, the resume marker, baselines
while off, the off switch, free-agent tasks, nested attribution, a child folded
into its parent, late rows (lost, and charged to the running task), blank model
ids, and usage written after closure.

## A Managed lead's own checkout changes (gap 20)

A Managed lead cannot use the edit tools, but its shell can still write. When
one of the lead's OWN shell calls ends, the ledger appends one
`leadCheckoutChanged` row if files in the lead's checkout changed during that
call. Always on while recording is on (`qaRunLedgerRecording`); nothing blocks,
prompts or changes what any agent sees.

**Source.** The lead's runtime side channel: `.toolDetail` start for a shell
tool, and the end of the same call id. A delegated helper has its own record
and channel, and a Claude in-process subagent's calls are not on the side
channel, so a call seen here is the lead's. The supervisor hands one enqueue to
`LeadCheckoutWatch`, which works on its own serial queue; the ledger's queue
only appends the finished row.

**Which files count.** FSEvents, file by file, for each lead checkout, from
the lead's first turn. An event counts for a call when it arrives between
0.5 s before the host saw the call start and the host's flush of pending events
at its end (settled 0.25 s later, off every request path). So a call that wrote
nothing costs one flush and starts no process; a folder removed whole counts
each file in it; a file edited and committed inside the same call still
counts. Events under `.git/` and `.array/` never count. An event counts for
one call at most. A file created and removed inside one call is not counted.

**Git, lock-free.** The watch runs git only when a call changed files, and
only two read-only commands over those paths: `git check-ignore --stdin -z`
(ignored files, such as a build directory, never count) and, when a call
replaced files by rename (an editor's save, `sed -i`), `git ls-files` to tell
a modified tracked file from a new one. Both run with `--no-optional-locks`
and `GIT_OPTIONAL_LOCKS=0`, so neither takes `index.lock`; each has a 2 s
timeout and a 1 MB output cap. It never runs `git status`. Outside a git
repository nothing is ignored or tracked, so a file replaced by rename reads
as added.

**Bounds.** At most 20,000 events kept per checkout and 2,000 paths per call.
Past a bound, a timeout or a git failure, the row says `evidence.changes:
unknown` with the reason, never a count.

**Lead or the first helper.** The first helper shares the lead's checkout,
with no worktree. Never two writers on one checkout: a new helper gets its own
worktree when a helper there is still running or the lead changed the checkout
in its open task (a `leadCheckoutChanged` row of that task; a row still on the
watch's queue is not seen yet). A finished helper re-messaged while a sibling
writes the same checkout is refused until that sibling finishes. Outside git,
helpers share with a notice. Witnesses: `--helper-worktree-check`,
`--lead-checkout-ledger-check` (section `writers`).
The supervisor passes, at the call's start and end, whether any other agent on
the same checkout path is running. The watch also marks a call when another
agent on that checkout ended a turn within 0.5 s before the call started, or
starts or ends a turn while it is open. Any of these makes the row
`evidence.by: ambiguous` with `reason: sharedCheckoutBusy`. Otherwise
`by: lead`.

**Stored.** `changed` (counts by `modified`, `added`, `deleted`), `paths`
(checkout-relative, the first 64 alphabetically; `evidence.pathsTruncated`
when cut), and `evidence`. No command text, contents, diffs or absolute paths.

**Not seen, or seen wrongly.** A background command's writes after its call
ended. Writes during the call by a process that is not an Array agent,
including files a build or tool writes outside ignored folders (recorded as
the lead's). A helper's background process still writing after its turn ended
(recorded as the lead's if it lands inside a lead call). A new file added and
committed inside one call reads as modified.

`--lead-checkout-ledger-check` (section `seen`) drives a Managed Claude lead
through the production runner and translator over a CLI double that replays
Bash frames and really changes files. Asserted: modify (in place, by rename),
add and delete are the lead's with the right paths; a folder removed whole
(`rm -rf`) records each file; an edit committed inside its own call is
recorded; an ignored build and a read-only command record nothing; a write
while the shared first helper runs is `ambiguous`; a helper write followed by
the helper ending its turn just before a lead call is `ambiguous`, never the
lead's; twelve lead `git add` + `git commit` calls back to back, racing the
watch, all exit 0 and are all recorded; no command, prompt or absolute path is
stored. The watch's git commands do not write the index even without the
lock-free flags, so the race leg guards against a return to `git status`
rather than proving the flags themselves.

## Hook receipts (gap 21)

Hook receipts still go to the supervisor's in-memory ring. For a Managed lead
(top-level, effective mode Managed) each receipt also appends one `hook` row
under the lead's task (the all-zero task when it has none): `hook` (the event,
one of `WorkspaceAgentHook.claudeEvents`/`codexEvents`, else `other`),
`outcome` (what Array's reply did: `none`, `context`, `denied`, `blocked`,
`other`) and `harness`. No prompt, command, output, session id or reply text.
Helpers' and Free agents' hooks are not recorded. The hook path pays one
enqueue; the reply is unchanged. A Claude in-process subagent's hooks come
through the lead's token and are counted as the lead's.

`--lead-checkout-ledger-check` (section `hooks`, alone through
`CONTINUUM_LEAD_CHECKOUT_CASE=hooks`) posts five lead hooks and one helper hook
through the real `array-workspace-mcp hook` binary to the production handler
and reads the rows back. Observed RED with the handler's ledger call removed.

## Strict lead (switch, off by default; Claude only)

`agents.strictLead.enabled` (defaults) or `ARRAY_STRICT_LEAD` (environment,
`1`/`true`/`yes`/`on`; when set it wins either way; for the benchmark).
Decided once per launch in the supervisor's `accountLaunch`, for a top-level
Managed **Claude** lead only; helpers never. No Settings UI. A toggle while
the lead is idle applies at its next turn: the idle Claude process is replaced
rather than reused.

**Claude: proven on Claude Code 2.1.321, in a linked worktree.** The lead's
`--settings` carries `sandbox` with `enabled`, `failIfUnavailable`,
`allowUnsandboxedCommands: false`, and `filesystem.denyWrite` naming the
checkout and, when they sit outside it, the git directories it writes (a
linked worktree's own `.git/worktrees/<name>` and the shared `.git`; a project
in a repository subfolder, that repository's `.git`), each as given and with
links resolved. A live probe ran the real `claude` (haiku, one turn, config in
a temporary folder, login from the CLI's own Keychain item) with exactly the
argv Array builds, in a linked worktree. Refused: a shell write and a python
write in the checkout, a build directory inside it, `git commit`,
`git branch -f`, `git hash-object -w`, and a call that asked for
`dangerouslyDisableSandbox`; the host confirmed no file, HEAD, branch or object
changed. Allowed: reads, `git status`/`log`, and a write to `$TMPDIR`. Result:
`docs/internals/evidence/strict-lead-claude-probe.json`; rerun with
`CONTINUUM_LEAD_CHECKOUT_CASE=strict-probe` (a model turn, never in the
matrix). The offline sections `strict-claude` and `strict-layouts` assert that
Array still builds those exact settings for a repository root, a subfolder
project and a linked worktree. Only the linked-worktree layout was probed
live.

Because `denyWrite` beats `allowWrite`, a strict lead cannot build into
`.build` inside its checkout; its system prompt carries one line telling it to
build with a scratch path under `$TMPDIR`. `failIfUnavailable` means a Mac
without the sandbox fails the lead's launch while the switch is on.

**Codex leads are not covered**: with the switch on they launch exactly as with
it off. Codex 0.167.0's permission profiles enforce the same limit (probed with
`codex sandbox` and the app-server's `command/exec`), and win over
`sandbox_mode=danger-full-access`, but a pinned `dangerFullAccess` thread or
turn overrides them, and the app-server's sandbox policies cannot name a
profile. Nothing can pin the profile on `thread/resume` or `turn/start`, and
whether a thread first run with full access keeps it when resumed is unproven,
so a Codex strict mode that might not hold is not shipped.
