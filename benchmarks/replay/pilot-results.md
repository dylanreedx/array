# Live pilot: first real runs

Four live runs on Claude Code 2.1.321, every agent `anthropic/claude-sonnet-5-5`
at effort `medium`, cap 20 minutes of wall time. This proves the rig runs live.
It is not a finding about Managed mode: two tasks, one run per arm, and no
Managed run delegated.

## Result

All four runs passed the host's grading. No Managed lead fanned out: both did
the edit themselves through the shell, which is gap B5 in the plan 116 handoff
(a Managed lead loses Edit and Write but keeps Bash). So the comparison
compared no pairs: 0 of 4 expected, "managed did not fan out" twice.

| Task | Arm | Host grade | Wall s | Active s | Uncached in | Cache read | Cache write | Output | Helpers |
|---|---|---|---|---|---|---|---|---|---|
| prepass-deleted-once | solo | pass | 9.5 | 9.2 | 8 | 58,294 | 29,634 | 856 | 0 |
| prepass-deleted-once | managed | pass | 9.6 | 8.3 | 8 | 55,071 | 7,978 | 696 | 0 (not fanned out) |
| prepass-targeted-only | solo | pass | 25.0 | 24.8 | 12 | 116,154 | 23,450 | 3,238 | 0 |
| prepass-targeted-only | managed | pass | 61.4 | 60.1 | 32 | 406,328 | 26,582 | 5,088 | 0 (not fanned out) |

Every run has one agent, the lead, so the per-agent figures are the totals.
Usage is complete on all four: every token type known, ledger task closed, no
row flags. Wall and active seconds are the usage page's figures from each
run's own ledger. Solo delegation attempts: 0.

## Tasks

Two small real fixes to `scripts/gate-prepass.py` (`pilot_tasks.py`). The
manifest has no tasks, and the synthetic one only tests the machinery:

- `prepass-deleted-once`: from `ac055cd2`. A deleted file was listed twice in
  the coverage report.
- `prepass-targeted-only`: from `2f96d775`. Declare hand-run checks as
  `targetedOnly` with a reason.

Each fixture repository holds the three real pre-pass files at the fix's
parent, plus one neighbouring check. The hidden checks are written by the
host, because the real commits carry no check that runs in the grading
sandbox. `replay.validate` showed each one failing by assertion on the parent
and passing on the real fix.

## Rig

- `live_claude.py` stands in for `claude` on PATH, so the production runner
  and its argv run unchanged inside a deny-default sandbox. Login is the CLI's
  own Keychain item, which the CLI reads itself. `CLAUDE_CONFIG_DIR` points at
  the run root, and `CLAUDE_SECURESTORAGE_CONFIG_DIR=""` keeps the default
  Keychain name. Nothing is copied and nothing is written under `~/.claude`.
- The sandbox profile, as it is now (after the review; the pilot ran on a
  wider one, below):
  - Run programs: the toolchain (system folders, Xcode, the command line
    tools), the run root, the CLI binary, the MCP server binary.
  - Read: those, plus the Keychain files, `/private/etc`, this run's MCP
    config and token files, and Core's resource bundle beside the MCP server
    (its tool catalogue). The server's own folder may be listed (names only,
    because `Bundle.main` needs it), but no other file in it can be read.
  - Write: the run root, `/dev/fd`, and `/dev/null`, `/dev/zero`,
    `/dev/random`, `/dev/urandom`, `/dev/dtracehelper`. Never a terminal.
    The hook probe's launch, and only that one, may also write its own probe
    folder.
  - Stat (file metadata) works on any path. Directory listings and file
    contents outside the lists above are refused.
  - Mach services: the Keychain's, directory lookups, notifications and
    logging.
- The pilot's four runs had a wider profile. It allowed writes and ioctl on
  every `/dev/ttysN`, which could reach the owner's other terminals. It also
  allowed reads on all of `/dev`, and reading and running anything in the
  SwiftPM debug build folder. It allowed writes to any `array-hook-probe-*`
  folder in the shared user temp folder, and listing every ancestor folder of
  an allowed path (names, never contents). It allowed the trustd, ocspd and
  coreservicesd services. A review found these, and the profile above removes
  them. Nothing in the pilot's output shows any of them was used.
- `egress_proxy.py` is a host CONNECT proxy that lets only `api.anthropic.com`
  through. The sandbox allows only loopback, to the proxy and this run's MCP
  port. The proxy refused `mcp-proxy.anthropic.com` (claude.ai connectors) 20
  times.
- The built-in subagent tool (`Agent`, `Task`) is switched off for every agent
  in both arms. The CLI's init event confirmed this, and the run logs record
  it.
- A live solo lead gets no workspace MCP server. Production gives every Claude
  agent the server and refuses a Free agent's delegation on each call.
- `--replay-live-run` in the app, and `run_pilot.py` to drive it.

## Rig failures and the one rerun each

- Task 1 solo, attempt 1: the CLI could not read its MCP config (`/var` is a
  link to `/private/var`). This was before any model turn. Rerun once.
- Task 1 managed, attempt 1: the agent's shell could not read `/dev/null` or
  write a here-document file. The lead could not edit and stopped (a fail).
  Rerun once after the fix.
- Task 2 managed, attempt 1: stopped by hand at its start, with the same
  defect. Rerun once.
- Both solo runs ran with that broken shell too. They passed using Read and
  Edit, so they were not rerun. The solo and managed arms did not have the same
  shell.

## Delegation run (kept out of the table)

One Managed run to prove the delegation path works live. Its prompt asked the
lead outright to give each part to its own helper, so it tests the path, not
whether a lead chooses to delegate. It has no solo partner and is not in the
table above. Task `prepass-two-parts` is the two pilot fixes together: the
parent of `ac055cd2` up to `2f96d775` (plus one unrelated one-line commit
between them). They touch different functions. Both hidden checks were
validated as before. Run `3a0a2245`; Sonnet 5.5 for every agent, effort
medium.

- The lead called `array_delegate` three times. The first call had empty
  arguments and the host refused it (`invalid_request`). Then it made one
  valid call per part.
- The host launched both helpers. Part 1's helper worked in the lead's
  checkout. Part 2's got its own worktree (`.worktrees/part-2-...`). Each
  was a sandboxed `claude` with the workspace tools.
- Both results came back. The lead's transcript holds two "finished:
  succeeded" messages, one per helper, and each started a new lead turn.
- Host grade: passed. Both hidden checks and the neighbour check passed. The
  only changed path is `scripts/gate-prepass.py`.
- The ledger shows 2 helpers (`delegated` rows), equal to the production
  records. Fanned out: yes.
- Time to answer 47.1 s. Active time 61.0 s, which is longer because the
  lead's turns after the task closed still count (gap 8). The process ran
  69 s.
- Usage complete, every type known:

| Agent | Uncached in | Cache read | Cache write | Output |
|---|---|---|---|---|
| lead (3 turns) | 20 | 136,879 | 13,437 | 2,553 |
| helper, part 1 | 16 | 109,619 | 20,620 | 2,110 |
| helper, part 2 | 26 | 302,308 | 19,243 | 4,038 |
| total | 62 | 548,806 | 53,300 | 8,701 |

- The lead wrote no code itself. It changed files through the shell only to
  bring part 2 in: `git diff` in the helper's worktree, then `git apply` in
  its own checkout.
- Part 1's helper sharing the lead's checkout is current production
  behaviour, not a rig defect. The first helper gets the lead's checkout and
  a concurrent second one gets a worktree. That lets two agents write one
  checkout. Here they did not overlap: the lead applied part 2 only after both
  helpers had finished. Nothing prevents an overlap, and that is a design
  risk to decide on.
- Neither helper could run the fixture test, `scripts/check-gate-prepass.py`.
  It creates its folders in `/tmp`, which the sandbox does not allow. Each
  said so in its report.
- Attempt 1 of this run (`8d134d72`) failed for a rig reason. Narrowing the
  sandbox had cut off the MCP server's tool catalogue (Core's resource
  bundle), so the CLI offered no `array_*` tools. The lead's ToolSearch for
  `array_delegate` found nothing, so it did both parts itself (host grade:
  passed). The fix was to read only that bundle and list the server's folder.
  Before the rerun, a test showed a tool call from inside the sandbox reaching
  a loopback host and getting its answer back. Rerun once.

## How fair the table is

- The solo baseline is low by about 680 input tokens per request. The solo
  lead has no MCP server, so it gets no MCP instructions and no Managed brief.
  First requests: 14,393 solo against 15,077 managed on task 1, and 14,565
  against 15,243 on task 2. On managed task 2's 16 requests, that is about
  11,000 of its 406,328 cache-read tokens.
- The cache columns depend on run order. Solo task 1 ran first and wrote the
  cold cache (14,391 tokens); later runs read it. Compare cache read and cache
  write across rows only with that in mind.
- Neither Managed lead loaded any `array_*` workspace tool, or ToolSearch,
  which is how a deferred tool is loaded (runs 750e2a66 and 935d2f76). The MCP
  server connected and offered 39 deferred tools, including `array_delegate`.
  The brief told each lead to post a plan and to delegate. Both did the work in
  Bash instead (3 and 15 Bash calls). Without Edit and Write, managed task 2
  edited by shell here-documents and made 16 requests, against 6 for solo.

## Not verified

- Delegation is proven for one run only, with a prompt that asks for it. The
  pilot's own Managed leads never chose to delegate.
- Hooks: verified in the CLI sessions, recorded nowhere durable. In both
  managed reruns, Array's hooks ran: a SessionStart hook succeeded (exit 0)
  and delivered the Managed lead brief, and the stop hook reported no errors.
  The ledger has no hook rows because Array never writes any. Hook receipts
  go to an in-memory ring (`AgentSupervisor.recordHookReceipt`), and nothing
  reads them (`WorkspaceAPIService.swift`, near line 366). This is a gap, and
  is not fixed here. The first managed attempt for task 1 launched with no
  hooks, so its lead had no brief.
- `mktemp` in the agent's shell still uses the system temp folder (refused),
  though the wrapper sets `TMPDIR`. The cause is unknown. Scripts that write in
  `/tmp` also fail.
- Inside the sandbox, the agent can read the CLI's Keychain login through
  `/usr/bin/security`, as it can in production. The proxy means it can send
  it only to `api.anthropic.com`.
- WebSearch runs on the provider's side, so the proxy cannot stop it.

Raw output is in `~/array-scratch/orchestration-handoff/pilot/`:
`records.jsonl` (including the failed attempt), `records-final.jsonl`,
`runs/`, and `logs/`.
