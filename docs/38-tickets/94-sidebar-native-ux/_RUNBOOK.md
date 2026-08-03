# 94-sidebar-native-ux — operating and supervision contract

## Program boundary

This program has its own queue, ledger, guard, and fresh-worker loop. `90-agent-ux` remains the
runtime/RPC/session capability owner and is not restarted or mutated here. `91-agent-tile-ux` is
closed; its patterns are consumed, its packets are not reopened.
`docs/38-tickets/93-global-border-audit.md` owns every border outside this fence — the sidebar is
its first consumer and P0.5 defines the shared width token.

Read in order:

1. `_DESIGN.md`
2. `_RUNBOOK.md`
3. `_QUEUE.md`
4. `_LEDGER.md`
5. the selected packet

Exactly one ticket is implemented per iteration and per commit.

## Preconditions before any loop start

- Branch is `overnight/agent-ux`.
- No other implementation agent or loop is editing tracked files in this checkout.
- Dylan's own app instance is **not** running. It shares the store and tmux; the boot probe hangs
  against a live instance.
- The working tree and index have no changes except owner-authorized untracked `website/`, root
  `array-logo*.svg`, `docs/38-tickets/92-small-team-relay/`,
  `scripts/check-small-team-relay-program.sh`, `scripts/small-team-relay-{loop,loopctl}.sh`,
  `scripts/small-team-relay-prompt.md`, and this program's own authoring paths
  (`docs/38-tickets/94-sidebar-native-ux/`, `scripts/check-sidebar-native-ux-program.sh`,
  `scripts/sidebar-native-ux-{loop,loopctl}.sh`, `scripts/sidebar-native-ux-prompt.md`) until they
  are committed. Any other change is dirty and fatal.
- `docs/38-tickets/94-sidebar-native-ux/STOP` is absent.
- `swift build` and the current headless matrix are green with the built-in Retina display as Main.
  Display topology drift is an environment stop, never a reason to bless baselines.
- Pi exposes authenticated `openai-codex/gpt-5.6-sol` and `gpt-5.6-luna`; workers alternate at
  medium thinking and the opposite model performs read-only review.

Never set `ALLOW_DIRTY=1` for a real run. The loop is an exclusive writer to this checkout.

## Ticket selection

The shell harness selects the first `_QUEUE.md` row whose dependencies are all `done` and whose
ledger state is `pending`. The selected ticket is passed explicitly to a worker.

- `done` requires both ledger state and a matching local commit.
- `blocked` is never retried automatically.
- If the first eligible row is `supervised`, the harness stops without editing it.
- Do not skip a supervised row to work ahead: every later density, naming, and interaction decision
  depends on the review before it.
- Workers cannot select tickets or edit queue, ledger, packet, runbook, prompt, or loop machinery.

## Per-ticket workflow

1. The harness selects one eligible autonomous ticket and records it outside the repository.
2. One worker implements only fenced production/check files, runs focused checks plus `swift build`,
   and returns `WORKER: READY`; it cannot stage, commit, edit the ledger, or run the full matrix.
3. The harness rejects commits or out-of-fence paths immediately.
4. The opposite GPT-5.6 Sol/Luna model performs one bounded read-only review. Only correctness,
   architecture, privacy, scope, or unproved done-criteria findings block.
5. At most two focused repair passes are allowed, each followed by another independent review; a
   third `REWORK` stops and preserves the ticket instead of churning.
6. After approval the harness runs `swift build` and the headless matrix exactly once against the
   final candidate.
7. The harness alone updates exactly the selected ledger row, stages validated paths, and creates
   one local `feat(sidebar): …` commit. It never pushes.
8. Any malformed result, failed final check, scope violation, worker commit, or exhausted review
   budget stops with the work preserved for direct inspection.

## Verification rules

This repository uses executable check targets, not XCTest. A worker may add a focused check target
or section when the packet names it, but may not create orphan checks the matrix never invokes.

Required final commands unless the packet is narrower for a documented reason:

```bash
swift build
.build/debug/continuum-revived --agent-inbox-check
.build/debug/continuum-revived --sidebar-ux-check
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

For UI tickets also run the exact applicable app checks:

```bash
.build/debug/continuum-revived --component-lab-check
.build/debug/continuum-revived --ui-geometry-check
.build/debug/continuum-revived --ui-contrast-check
.build/debug/continuum-revived --ui-baseline-check
.build/debug/continuum-revived --agent-status-check
```

Surface checks requiring a real terminal or display are supervised. Headless skipping of those known
surface legs is honest; skipping semantic, geometry, contrast, baseline, I5, or build legs is not.

### Sidebar-specific verification rules

- **Every geometry assertion runs at 220, 280, and 320 pt.** A single-width assertion is not
  evidence about a surface whose minimum is 220.
- **Truncation is asserted by drawable width**, comparing the label's drawn width against the
  measured need for its exact string and font, with the 4 pt cell inset included. A frame
  assertion and a `stringValue` comparison are both vacuous.
- **Absence is asserted structurally** over the live view tree, so a reintroduction fails the same
  assertion the removal satisfied.
- **Appearance and pixel floors are re-measured in the same change** that alters what the sidebar
  renders, with the reason in a comment. Removing a row's border drops its outline slot from the
  owner census; a stale floor turns a correct change red for the wrong reason.
- **Offscreen renders need explicit materialization**: size the subtree before applying content and
  drive layout, prepare, and attribute re-application from the list's own layout pass.

### Never weaken a gate

- no removing matrix legs;
- no lowering counts, floors, or time budgets merely to pass;
- no broad exemption or allowlist growth;
- no baseline blessing in autonomous tickets;
- no replacing a real-path check with a stand-in that cannot fail the production seam;
- no fixture that cannot express the defect its packet exists to fix.

A visual ticket may produce candidate screenshots or uncommitted candidate baselines. Only a
supervised packet may approve and commit a visual baseline move, after both appearances and multiple
runs are inspected.

## Git discipline

- Local commits only; never push.
- No branch switching, rebase, merge, worktree creation, stash deletion, or shared-history rewrite.
- One ticket per harness-owned commit, including one mechanically targeted ledger update.
- Workers and reviewers never stage or commit. The harness refuses any worker-created commit.
- The harness stages only already validated packet paths plus `_LEDGER.md` after final checks pass.
- A supervisor never edits or commits while a worker or reviewer is alive.
- Commits use the owner's identity with no trailer of any kind.

## Loop control

```bash
./scripts/sidebar-native-ux-loopctl.sh arm       # explicitly removes this program's STOP
./scripts/sidebar-native-ux-loopctl.sh start
./scripts/sidebar-native-ux-loopctl.sh status
./scripts/sidebar-native-ux-loopctl.sh logs
./scripts/sidebar-native-ux-loopctl.sh stop
```

`restart` is intentionally conservative: it works only when no iteration child exists and the tree
is clean. A dirty stopped run requires inspection, never blind reset.

Runtime artifacts live outside source control under
`.pi/sidebar-native-ux-runs/<repo>/run-<timestamp>/`, with the same per-iteration task layout as
queue 91. The control script records the loop PID and latest run path under
`~/.pi/sidebar-native-ux-loop-control/continuum-overnight/`, so observability never dirties the
checkout.

A ticket is accepted only after a durable opposite-model `DECISION: APPROVE`, final build and matrix
success, harness-owned ledger update, and a local commit.

## Supervised review procedure

Four gates: **P1.5** (containment and surface), **P3.6** (status truthfulness), **P5.6** (native
interaction), **P7.1** (final acceptance).

1. Keep the loop stopped.
2. Quit the owner's running instance before any probe, build, or relaunch.
3. Run the packet with a supervised implementation/review agent or manually.
4. Build and install a verified-fresh app.
5. Review the named states at 220, 280, and 320 pt in both appearances, plus keyboard, VoiceOver,
   and Reduce Motion behaviour.
6. Record explicit owner approval or correction tickets. Do not infer approval from silence.
7. Bless baselines only with the built-in Retina display as Main and `check-retina-main.swift`
   passing.
8. Commit the supervised ticket and ledger only after approval, then confirm a clean tree and
   restart the loop.

## Stop conditions

- queue drained;
- supervised ticket ready;
- dependency chain blocked;
- worker or provider failure, or a malformed worker result;
- independent review remains `REWORK` after two repair passes;
- final build or matrix failure;
- dirty-tree or wrong-branch preflight;
- worker commit or out-of-fence change;
- the owner's app instance found running at preflight;
- explicit program STOP.

A stop is an observable state, not an invitation to silently respawn forever.
