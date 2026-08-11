# Small-team relay ticket worker

The harness has selected exactly one ticket. Implement only `TICKET` from `PACKET`.

## Read first

1. `PACKET`
2. `docs/38-tickets/92-small-team-relay/_DESIGN.md`
3. `docs/38-tickets/92-small-team-relay/_DECISIONS.md`
4. the production seams and adjacent checks named by the packet
5. on a repair pass, the supplied reviewer file

`plan.mdx` is context only. Do not update or depend on the hosted visual plan.

## Ownership

You own implementation and focused deterministic checks only inside the packet's `## Files` fence. The shell harness—not you—owns queue selection, ledger state, staging, review orchestration, final matrix, and local commit.

Never edit:

- `_LEDGER.md`, `_QUEUE.md`, `_RUNBOOK.md`, `_DESIGN.md`, `_DECISIONS.md`, `_ACTION_ITEMS.md`, `plan.mdx`, or any packet;
- loop, prompt, control, or program-check machinery unless the selected packet explicitly fences that exact file;
- files outside the selected packet fence;
- queue-91 preserved candidate work, `website/`, root logo drafts, stashes, branches, or worktrees.

Never run `git add`, `git commit`, `git reset`, `git checkout`, `git clean`, `git stash`, branch, rebase, merge, or push. Do not launch another implementation/review agent.

## TDD workflow

1. Inspect compiled reality and current checks.
2. Capture the packet's approved behavior going RED against the pre-change production seam. Preserve the command/output under `TASK_DIR/pre-red/`; do not change an old expectation solely to manufacture RED.
3. Implement only the packet.
4. Add focused deterministic positive assertions.
5. Run a final-code mutation witness: temporarily reintroduce the named failure, observe the ordinary focused check red, restore exact bytes/hash, rerun green, and keep the witness log outside source control under `TASK_DIR`.
6. Run the packet's focused check commands and `swift build`.
7. Do **not** run the full matrix; the harness runs it once after independent approval.
8. Inspect `git diff` and `git status --short` before finishing.

Use injected clocks, entropy, filesystems, network scheduling, APNs, and faults. Prefer real temporary SQLite files and loopback port 0 over mocks where the packet is about persistence/process/socket behavior. Never use real credentials/transcripts in fixtures.

## Architecture that may not drift

- RelayProtocol is portable wire/domain vocabulary; RelayCore owns SQLite/auth/policy/hub; RelayNIO owns sockets; hosts own provider/runtime authority.
- Persist before broadcast.
- Typed RelayFrame handles privileged Class-B content; generic SyncMessage does not.
- Class C secrets/runtime never cross relay or observability.
- Workspace/capability authorization is deny-by-default.
- Commands are idempotent; ambiguous provider dispatch is `indeterminate`, never blindly replayed.
- Loopback/private networking is default; public bind is owner-supervised.
- Real Mac sleep suspends local work.
- No gate, denial, size/count/fault floor, or existing acceptance expectation is weakened to pass.

If a repair pass is supplied, address every blocking finding without chasing stylistic or out-of-scope work. If compiled reality conflicts with the packet or an owner decision is missing, stop rather than inventing another architecture.

Your final nonblank line must be exactly one of:

- `WORKER: READY`
- `WORKER: BLOCKED <concrete evidence>`
