# 90-agent-ux — Operating contract

## What this program is
Build a full agent UX on the Continuum **desktop**: an agent-first sidebar inbox, a real chat
command surface, an agent entity decoupled from its tile, per-agent git worktrees, and an
orchestrator that can spawn sub-agents. iOS stays **observe-only** this run.

## Locked decisions (do not re-litigate; if a ticket seems to contradict one, mark it blocked)
- **The agent is the entity; a tile is one view of it.** Closing a tile must not kill an agent.
- **Per-agent git worktrees**, opt-in per spawn.
- **Orchestrator** via a Pi extension tool `spawn_agent`, detected in the event stream we already
  translate.
- **Real light + dark theming.** Tokens carry both; contrast is gated in both.
- **Full settle / snooze / archive lifecycle**, with blockers outranking an explicit settle.
- **Frozen list order** on desktop (status travels in place); iOS glance surfaces sort
  attention-first.
- **The sidebar IS the inbox, by default — not a mode you toggle.**
- **Pi `--mode rpc`** is the provider transport (strict superset of `--mode json`).
- **Deterministic gates block; vision is advisory and may never certify "done".**

## Per-ticket contract
1. Read the packet in full. It is authored zero-guessing — if something is genuinely ambiguous or
   contradicts a locked decision, mark the ticket `blocked` with the reason and stop. Do not
   improvise scope.
2. Implement only what the packet asks.
3. `./scripts/run-matrix.sh` must be green. **Never weaken the matrix** — do not delete, skip,
   comment out, or loosen a check to get green, and never bless PNG baselines to pass.
   `CONTINUUM_SKIP_SURFACE_CHECKS=1` is expected headless (no terminal surface); that is the
   documented honest-green convention, not a weakening.
4. Reviews must clear (Claude + Codex cross-review of the diff).
5. Commit: one ticket per commit, `type(scope): summary`, **no AI-attribution trailer**,
   **local only — never push**. Stay on branch `overnight/agent-ux`.
6. Update `_LEDGER.md` (state, commit sha, timestamp, note) and the heartbeat.

## Never
- Push, force-push, rebase shared history, or touch `main`.
- Modify `scripts/agent-ux-loop.sh`, `_LEDGER.md` semantics, `_QUEUE.md` ordering, or anything in
  `docs/38-tickets/_archive/`.
- Touch `scripts/overnight-*` (the previous program's harness) or remove a `STOP` file.
- Certify a visual outcome by eye. Assert it, or leave it to the human.
- Fake green. If it cannot be honestly verified, mark `blocked` and explain.

## Verification substrate (why Phase 0 comes first)
Before this run, the entire visual gate was `distinctSampledColors <= 1` — "more than one colour."
It passed black-on-dark text, half-width cards, and a completely blank transcript. Phase 0 replaces
that with geometry, per-appearance contrast, pixel, and baseline gates plus an iOS build leg. Later
phases depend on those gates being real.

## Stop conditions
Queue drained · usage exhausted · too many consecutive failures · `touch STOP` in the repo root.
On stop, write `docs/38-tickets/90-agent-ux/_MORNING_REPORT.md`: done / blocked / commits / what
needs the owner's decision.

## Supervisor rules (learned the hard way, 2026-07-25 ~06:30)

The supervising session shares the working tree with a live worker. Two collisions happened:

1. **Never edit `_LEDGER.md` while a worker is running.** The worker owns it. (Near-miss at 05:10.)
2. **`git add <paths>` does NOT scope a commit.** A bare `git commit` commits the *entire index*,
   including files the worker had already staged. This swept an in-progress ticket's implementation
   into a docs commit twice (`6ccad1e` took P0.8's files, `4bda832` took P0.3's 408-line
   implementation mid-flight), corrupting commit attribution and destroying the worker's index.

   **Required procedure for the supervisor:**
   - Run `git diff --cached --name-only` FIRST. If anything you do not own is staged, stop —
     a worker is mid-commit. Wait for the next wake.
   - Commit with an explicit pathspec: `git commit -- <paths>` (or `git commit --only <paths>`),
     never a bare `git commit`.
   - Prefer committing supervisor work when no `claude -p` child is alive.

Consequence when it happens: the worker's index vanishes underneath it, so it can neither commit nor
report. Recovery = terminate that child, verify the swept code against its packet, re-run the matrix,
record the ticket honestly with an ATTRIBUTION ERROR note, and relaunch the driver.
