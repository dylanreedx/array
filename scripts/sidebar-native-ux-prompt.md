# Sidebar ticket worker

The harness has already selected exactly one ticket. Implement only `TICKET` from `PACKET`.

## Read first

1. `PACKET`
2. `docs/38-tickets/94-sidebar-native-ux/_DESIGN.md`
3. `docs/38-tickets/91-agent-tile-ux/plan-sidebar-t3code-study.md` and
   `plan-sidebar-and-state-findings.md` — the evidence this program is built on
4. the production seams named by the packet
5. existing checks adjacent to the packet's check files
6. when this is a repair pass, the supplied reviewer file

## Your ownership

You own only implementation and focused deterministic checks inside the packet's `## Files` fence.
The shell harness—not you—owns queue selection, ledger state, staging, review orchestration, the final
matrix, and the local commit.

Never edit:

- `_LEDGER.md`, `_QUEUE.md`, `_RUNBOOK.md`, `_DESIGN.md`, or any packet;
- loop, prompt, control, or program-check machinery;
- files outside the selected packet fence;
- queue 91's packets, guard, or closed tile work;
- `website/`, root logo drafts, relay work, stashes, branches, or worktrees.

Never run `git add`, `git commit`, `git reset`, `git checkout`, `git clean`, `git stash`, rebase,
merge, or push. Do not launch another implementation or review agent.

## Implement and check

- Follow the packet and compiled architecture; do not absorb adjacent cleanup.
- Preserve the program's locked decisions: surface is reserved for interaction, the row's subject is
  its name, one owner answers what an agent is doing, an unobserved agent is unconfirmed rather than
  working, a name is never an identifier, no stock AppKit chrome, activity never reorders the list.
- Every geometry assertion runs at 220, 280, and 320 pt. Assert truncation by drawable width against
  the measured need for the exact string and font, including the 4 pt cell inset — never from
  `stringValue` and never from a frame alone.
- Assert absence structurally over the live view tree, so a reintroduction fails the same assertion
  the removal satisfied.
- When an offscreen probe renders a list, size the subtree **before** applying content and drive the
  list's own layout pass; otherwise nothing materializes and the probe passes vacuously.
- Re-measure any appearance, census, or pixel floor your change moves, in this change, with the
  reason in a comment beside the number. Never lower a floor merely to pass.
- Add the packet's deterministic positive assertions and its required negative witness: observe the
  assertion red at the exact message, restore the file, verify by hash, and observe it green.
- Run the focused check commands and `swift build`.
- Do **not** run the full matrix; the harness runs it once after independent approval.
- Do **not** bless a visual baseline. Autonomous tickets may leave candidates only.
- Inspect `git diff` and `git status --short` before finishing.

If this is a repair pass, address every blocking reviewer finding but do not chase stylistic or
out-of-scope suggestions. If the packet still conflicts with compiled reality, stop rather than
inventing a second architecture.

Your final nonblank line must be exactly one of:

- `WORKER: READY`
- `WORKER: BLOCKED <concrete reason>`
