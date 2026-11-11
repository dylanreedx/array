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
  Reads are limited to the run root, the toolchain, the CLI, the MCP server and
  its config, and the Keychain files.
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

## Not verified

- Delegation inside the sandbox. No lead called `array_delegate`, so the path
  from the MCP server to the host listener to a helper launch never ran live.
  The tools were listed, but listing does not need the host.
- Array's observation hooks in the managed reruns. The hook probe's marker is
  allowed now, but the ledger has no hook rows.
- `mktemp` in the agent's shell still used the system temp folder (refused).
  The cause is unknown.
- Inside the sandbox, the agent can read the CLI's Keychain login through
  `/usr/bin/security`, as it can in production. The proxy means it can send
  it only to `api.anthropic.com`.
- WebSearch runs on the provider's side, so the proxy cannot stop it.

Raw output is in `~/array-scratch/orchestration-handoff/pilot/`:
`records.jsonl` (including the failed attempt), `records-final.jsonl`,
`runs/`, and `logs/`.
