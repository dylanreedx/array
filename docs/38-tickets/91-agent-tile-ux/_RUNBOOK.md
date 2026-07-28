# 91-agent-tile-ux — operating and supervision contract

## Program boundary

This is a new program in its own folder. It borrows the durable queue/ledger/fresh-worker shape from
`90-agent-ux`, but it does not reuse that queue, mutate its ledger, or restart its loop.

Read in order:

1. `_DESIGN.md`
2. `_RUNBOOK.md`
3. `_QUEUE.md`
4. `_LEDGER.md`
5. the selected packet

Exactly one ticket is implemented per iteration and per commit.

## Preconditions before any loop start

- Branch is `overnight/agent-ux`.
- No other implementation agent or loop is editing this checkout.
- The working tree and index are clean.
- The relay/FileTree/document setup work has already been preserved separately.
- `docs/38-tickets/91-agent-tile-ux/STOP` is absent.
- `swift build` and the current headless matrix are green.
- `claude` and `codex` CLIs are authenticated; missing review provider fails closed for that ticket.

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
- Deterministic gates block. Visual taste is decided only at supervised rows.

## Ticket selection

The worker selects the first `_QUEUE.md` row whose dependencies are all `done` and whose ledger
state is `pending`.

- `done` requires both ledger state and a matching commit.
- `blocked` is never retried automatically.
- `in-progress` from a dead iteration is not automatically reset; the supervisor inspects it.
- If the first eligible row is `supervised`, emit
  `LOOP: STOP supervised-required:<ticket>` without editing it.
- Do not skip a supervised row to work ahead: later density and integration decisions depend on it.
- Queue, packet, runbook, prompt, and loop machinery are immutable to ticket workers.

## Per-ticket workflow

1. Mark the selected row `in-progress`; update the heartbeat using real UTC.
2. Read the packet fully and inspect every named production seam before editing.
3. Implement only the file-fenced behavior.
4. Add focused deterministic assertions and at least one named negative witness.
5. Run focused checks, `swift build`, then the headless matrix.
6. Run independent read-only diff review.
7. Resolve findings or record a concrete reason they do not apply.
8. Mark the ledger row `done` with `this commit`, real timestamp, verification summary, and known limits.
9. Commit exactly one ticket with `type(agent-tile): summary`; no AI attribution; never push. The
   harness ties the sole commit after the prior HEAD to the token and mechanically checks its paths,
   subject, and ledger state (a commit cannot contain its own final SHA).
10. Emit exactly one final `LOOP:` control line.

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
- One ticket per commit, including its ledger update.
- The worker may stage only its ticket paths plus ledger. Before commit it must inspect the entire
  staged set.
- A supervisor never commits while a worker is alive and never touches the index underneath it.
- The harness rejects zero/multiple commits, a non-`type(agent-tile):` subject, no ledger update,
  ledger state other than `done`/explicit `blocked`, or any changed path outside the packet file list.
- Existing unrelated work is a hard preflight stop, not permission to absorb it.

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
  telemetry.json
  events.jsonl
  report.md
  logs/iter-*.log
```

The control script records the active supervisor PID and latest run path outside the repository under
`~/.pi/agent-tile-ux-loop-control/continuum-overnight/`, so preflight observability never dirties the checkout.

## 15–20 minute supervisor protocol

The future supervising session should wake every 15–20 minutes while the loop is active and run:

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
./scripts/agent-tile-ux-loopctl.sh status
```

Then inspect, in this order:

1. **Control process:** loop PID alive? expected branch? one loop only?
2. **Iteration process:** current Claude PID/children alive? elapsed time below 2.5h watchdog?
3. **Durable state:** `status.json`, latest `events.jsonl`, ledger state, current ticket.
4. **Progress signals:** iteration-log mtime/size, tracked source mtime epoch, HEAD movement,
   build/test/edit subprocesses.
5. **Safety:** tree/index state and whether changed files fit the current packet.
6. **Provider:** quota/rate-limit/reset evidence versus malformed output or local failure.

### Classify before acting

**Progressing** — any strong signal: recent source/check write, active build/test, iteration output
movement, heartbeat phase change, or new commit. Leave it alone.

**Quiet but plausible** — worker is reading/planning/reviewing; under 35 minutes without writes and
inside timeout. Leave it alone. Low CPU alone is not stale.

**Stale candidate** — all of the following:

- ledger/telemetry/source/log progress older than 35 minutes;
- no `swift-build`, `swift-frontend`, `run-matrix`, `xcodebuild`, `codex`, editor/helper child, or
  active review subprocess;
- iteration output is not growing;
- no recent HEAD change;
- process is alive but effectively idle, or child disappeared while loop still claims running.

Only then may the supervisor terminate the iteration child. Terminate gracefully, capture artifacts,
and let the harness stop. Do not immediately launch a second writer.

**Failed/stopped cleanly** — status says stopped and tree is clean. Diagnose reason:

- provider quota: restart after reset;
- supervised-required: perform that review, do not restart past it;
- queue-drained: finish;
- malformed output or one-off environment failure: restart from same pending ticket;
- repeated failure: leave stopped and inspect logs.

**Stopped dirty** — never restart. Record `git status`, staged paths, diff summary, current ticket,
iteration log, and child exit. Preserve the work. Either resume/recover that ticket with one agent or
revert only after explicit human review. Never use `git reset --hard`/`git clean -fd` as generic
supervision.

**Wrong-file edits or gate weakening** — stop the loop, preserve evidence, and review before any
commit. The loop is not allowed to “finish and see.”

## Restart procedure

A safe automatic restart requires all of:

- no live iteration or review child;
- clean worktree and index;
- current branch unchanged;
- ledger has no unexplained `in-progress` row;
- STOP absent;
- last stop reason is recoverable.

Then:

```bash
./scripts/agent-tile-ux-loopctl.sh restart
sleep 5
./scripts/agent-tile-ux-loopctl.sh status
```

If the ledger says `in-progress` after a dead clean iteration, inspect the ticket and git log. Reset
that row to `pending` only when no matching work/commit exists, and record the recovery note. Do not
mark it `blocked`: supervisor termination is not an implementation failure.

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
- iteration watchdog elapsed;
- repeated provider failure window;
- malformed/missing LOOP token;
- dirty-tree preflight;
- wrong branch;
- explicit program STOP;
- supervisor identifies stale/wrong-scope/gate-weakening work.

A stop is an observable state, not an invitation to silently respawn forever.
