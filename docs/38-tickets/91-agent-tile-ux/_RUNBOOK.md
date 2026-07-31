# 91-agent-tile-ux — operating and supervision contract

## Program boundary

This program has its own queue/ledger/fresh-worker loop. `90-agent-ux` remains the runtime/RPC/session capability owner: queue 91 does not mutate or restart it, but consumes the provider-neutral seams its compiled work established.

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
- The working tree and index have no changes except owner-authorized untracked `website/`, root `array-logo*.svg`, `docs/38-tickets/92-small-team-relay/`, `scripts/check-small-team-relay-program.sh`, and `scripts/small-team-relay-{loop,loopctl,prompt}.sh`; any other change is dirty and fatal.
- The relay/FileTree/document setup work has already been preserved separately.
- `docs/38-tickets/91-agent-tile-ux/STOP` is absent.
- `swift build` and the current headless matrix are green with the built-in Retina display as Main; display topology drift is an environment stop, never a reason to bless baselines.
- Pi exposes authenticated `openai-codex/gpt-5.6-sol` and `gpt-5.6-luna`; workers alternate at medium thinking and the opposite model performs read-only review.

Never set `ALLOW_DIRTY=1` for a real run. The loop is an exclusive writer to this checkout.

## Locked implementation rules

- Agent is the entity; tile is a detachable view. Closing a tile never stops the agent.
- `AgentSupervisor` remains the only owner/factory of runners.
- `AgentRuntimeEvent` remains the provider-neutral event boundary.
- Semantic content is platform-neutral. No AppKit or visual token in AgentContent.
- Markdown is parsed to Continuum's AST before rendering.
- Structured blocks are typed; they are not magic Markdown strings.
- Renderers register by semantic kind and receive actions through a narrow context.
- `NSTextView` supplies editing behavior; visible composer/control chrome is custom.
- No visible `NSPopUpButton`, rounded-bezel `NSTextField`, or stock dropdown in the v2 tile.
- Light/dark, keyboard accessibility, VoiceOver, Reduce Motion, and selection/copy are first-class.
- I5 remains absolute: no transcript/prompt/path/tool argument/PID/secret crosses phone sync.
- The canvas is the session switcher; one tile is one interactive session and detach never stops it.
- Provider todo/plan state is passive, explicit, bounded, read-only, and mirrored in tile/FileTree; never infer it from prose or create a second task manager.
- Continuum adds no approval gate; explicit provider-enforced requests are exceptional, compact, and nonmodal.
- Queue 91 advertises only compiled capabilities owned by queue 90; missing capability blocks rather than being simulated.
- No context tile.
- Deterministic gates block. Visual taste is decided only at supervised rows.

## Ticket selection

The shell harness selects the first `_QUEUE.md` row whose dependencies are all `done` and whose
ledger state is `pending`. The selected ticket is passed explicitly to a worker.

- `done` requires both ledger state and a matching local commit.
- `blocked` is never retried automatically.
- If the first eligible row is `supervised`, the harness stops without editing it.
- Do not skip a supervised row to work ahead: later density and integration decisions depend on it.
- Workers cannot select tickets or edit queue, ledger, packet, runbook, prompt, or loop machinery.

## Per-ticket workflow

1. The harness selects one eligible autonomous ticket and records it outside the repository.
2. One worker implements only fenced production/check files, runs focused checks plus `swift build`,
   and returns `WORKER: READY`; it cannot stage, commit, edit the ledger, or run the full matrix.
3. The harness rejects commits or out-of-fence paths immediately.
4. The opposite GPT-5.6 Sol/Luna model performs one bounded read-only review. Only correctness,
   architecture, privacy, scope, or unproved done-criteria findings block.
5. At most two focused repair passes are allowed. Each is followed by another independent review;
   a third `REWORK` stops and preserves the ticket instead of churning indefinitely.
6. After approval, the harness runs `swift build` and the headless matrix exactly once against the
   final candidate.
7. The harness alone updates exactly the selected ledger row, stages validated paths, and creates one
   local `feat(agent-tile): …` commit. It never pushes.
8. Any malformed result, failed final check, scope violation, worker commit, or exhausted review
   budget stops with the work preserved for direct inspection.

## Verification rules

This repository uses executable check targets, not XCTest. A worker may add a focused check target or
section when the packet names it, but may not create orphan tests that the matrix never invokes.

Required final commands unless the packet is narrower for a documented reason:

```bash
swift build
swift run ContinuumRevivedAgentContentChecks       # once target exists
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

For UI tickets also run the exact applicable app checks:

```bash
.build/debug/continuum-revived --component-lab-check
.build/debug/continuum-revived --ui-geometry-check
.build/debug/continuum-revived --ui-contrast-check
.build/debug/continuum-revived --ui-baseline-check
.build/debug/continuum-revived --agent-supervisor-check
```

Surface checks requiring a real terminal/display are supervised. Headless skipping of those known
surface legs is honest; skipping semantic, geometry, contrast, baseline, I5, or build legs is not.

### Never weaken a gate

- no removing matrix legs;
- no lowering counts/floors/time budgets merely to pass;
- no broad exemption/allowlist growth;
- no baseline blessing in autonomous tickets;
- no replacing a real-path check with a stand-in that cannot fail the production seam;
- no swallowing parser/reducer errors because provider input is inconvenient.

A visual ticket may produce candidate screenshots or uncommitted candidate baselines. Only a
supervised packet may approve and commit a visual baseline move, after both appearances and multiple
runs are inspected.

## Git discipline

- Local commits only; never push.
- No branch switching, rebase, merge, worktree creation, stash deletion, or shared-history rewrite.
- One ticket per harness-owned commit, including one mechanically targeted ledger update.
- Workers and reviewers never stage or commit. The harness refuses any worker-created commit.
- The harness stages only already validated packet paths plus `_LEDGER.md` after final checks pass.
- A supervisor never edits or commits while a worker/reviewer is alive.
- Existing unrelated tracked work is a hard preflight stop, not permission to absorb it. Authorized
  untracked website/logo drafts and the exact Queue 92 authoring paths listed in preflight remain
  ignored and unstaged; similarly named or relocated paths are not authorized.

## Loop control

Use the new control surface, not ad-hoc `nohup` commands:

```bash
./scripts/agent-tile-ux-loopctl.sh arm       # explicitly removes this program's STOP
./scripts/agent-tile-ux-loopctl.sh start
./scripts/agent-tile-ux-loopctl.sh status
./scripts/agent-tile-ux-loopctl.sh logs
./scripts/agent-tile-ux-loopctl.sh stop
```

`restart` is intentionally conservative: it works only when no iteration child exists and the tree
is clean. A dirty stopped run requires inspection/recovery, never blind reset.

Runtime artifacts live outside source control under:

```text
.pi/agent-tile-ux-runs/<repo>/run-<timestamp>/
  status.json
  events.log
  tasks/iteration-NNN-<ticket>/
    task.json
    worker-session-N/*.jsonl
    worker-N.md
    candidate-N.diff
    review-request-N.md
    reviewer-session-N/*.jsonl
    review-final-N.md
    swift-build.log
    matrix.log
    final.diff
    commit.log
```

A ticket is accepted only after a durable opposite-model `DECISION: APPROVE`, final build/matrix
success, harness-owned ledger update, and local commit. A provider failure stops; dirty work is
preserved rather than automatically recovered in another writer.

The control script records the loop PID and latest run path outside the repository under
`~/.pi/agent-tile-ux-loop-control/continuum-overnight/`, so observability never dirties the checkout.

## Direct supervisor protocol

While the loop is active, the supervising session runs:

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
./scripts/agent-tile-ux-loopctl.sh status
```

Inspect the actual loop/child PID, current ticket and phase, recent `events.log`, changed paths, and
latest worker/reviewer output. Do not launch monitoring agents or infer staleness from CPU alone.
Intervene only for a dead child, malformed result, out-of-fence edit, failed final check, exhausted
review budget, supervised gate, or explicit provider failure.

A stopped dirty run is never restarted. Preserve and inspect it directly; never use broad reset,
clean, stash, or a second recovery writer. A stopped clean provider failure may be restarted from the
same pending ticket after confirming no child remains.

## Restart procedure

A safe automatic restart requires all of:

- no live iteration or review child;
- clean worktree and index;
- current branch unchanged;
- ledger has no `in-progress` row (runtime state lives outside the repository);
- STOP absent;
- last stop reason is recoverable.

Then:

```bash
./scripts/agent-tile-ux-loopctl.sh restart
sleep 5
./scripts/agent-tile-ux-loopctl.sh status
```

## Supervised review procedure

At P3.12, P4.10, and P5.5:

1. Keep the loop stopped.
2. Run the packet with a supervised implementation/review agent or manually.
3. Build and install a verified-fresh app.
4. Review named states, widths, appearances, keyboard/VoiceOver/motion behavior.
5. Record explicit owner approval or correction tickets.
6. Commit the supervised ticket and ledger only after approval.
7. Confirm clean tree, then restart the loop.

## Stop conditions

- queue drained;
- supervised ticket ready;
- dependency chain blocked;
- worker/provider failure or malformed worker result;
- independent review remains `REWORK` after two repair passes;
- final build or matrix failure;
- dirty-tree or wrong-branch preflight;
- worker commit or out-of-fence change;
- explicit program STOP.

A stop is an observable state, not an invitation to silently respawn forever.
