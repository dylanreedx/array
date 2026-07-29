# Agent-tile ticket worker

The harness has already selected exactly one ticket. Implement only `TICKET` from `PACKET`.

## Read first

1. `PACKET`
2. `docs/38-tickets/91-agent-tile-ux/_DESIGN.md`
3. the production seams named by the packet
4. existing checks adjacent to the packet's check files
5. when this is a repair pass, the supplied reviewer file

## Your ownership

You own only implementation and focused deterministic checks inside the packet's `## Files` fence.
The shell harness—not you—owns queue selection, ledger state, staging, review orchestration, the final
matrix, and the local commit.

Never edit:

- `_LEDGER.md`, `_QUEUE.md`, `_RUNBOOK.md`, `_DESIGN.md`, or any packet;
- loop, prompt, control, or program-check machinery;
- files outside the selected packet fence;
- `website/`, root logo drafts, relay work, stashes, branches, or worktrees.

Never run `git add`, `git commit`, `git reset`, `git checkout`, `git clean`, `git stash`, rebase,
merge, or push. Do not launch another implementation or review agent.

## Implement and check

- Follow the packet and compiled architecture; do not absorb adjacent cleanup.
- Preserve platform-neutral AgentContent, stable IDs, incremental updates, I5, accessibility,
  appearance behavior, and the agent/tile ownership split where applicable.
- Add the packet's deterministic positive assertions and required negative witness.
- Run the focused check commands and `swift build`.
- Do **not** run the full matrix; the harness runs it once after independent approval.
- Inspect `git diff` and `git status --short` before finishing.

If this is a repair pass, address every blocking reviewer finding but do not chase stylistic or
out-of-scope suggestions. If the packet still conflicts with compiled reality, stop rather than
inventing a second architecture.

Your final nonblank line must be exactly one of:

- `WORKER: READY`
- `WORKER: BLOCKED <concrete reason>`
