# 45 — Handoff prompt: agent tile transcript program

Paste the block below to the next agent. Written 2026-08-22, repo at `09de0b0`
(Release 0.5.10).

---

You are picking up an investigation-complete, implementation-not-started program
on Array's managed agent tile transcript. Your job is to turn it into an
implementation plan. **Do not start editing production code until you have read
the two documents below and confirmed their claims against HEAD.**

## Read first, in this order

1. `.plans/43-agent-tile-transcript-ux-proposal.md` — the proposal. Sequenced
   slices, decisions already taken, open questions. **This is the working
   document; keep editing it.**
2. `.plans/42-agent-tile-transcript-ux-brainstorm.md` — the evidence behind 43,
   including empirical CLI probe results.
3. `~/.claude/plans/we-had-a-codex-mighty-hinton.md` — the earlier renovation
   plan. Still correct; 43 adds the CLI/command/compaction dimensions it lacked.
4. `docs/38-tickets/99-transcript-subagents-renovation-handoff.md` — the
   post-mortem of the session that was commissioned to do this and did not.
5. `docs/38-tickets/91-agent-tile-ux/_DESIGN.md` — the binding visual charter.
6. `docs/internals/performance.md` — binding, not advisory.

Not yours, do not duplicate: `.plans/41` (zone lifecycle, another agent) and
`.plans/44` (performance audit, another agent). 43 §5e records what `ecf3bf3`
fixed and inverted in 41's findings — pass that along rather than re-deriving it.

## State of the world

- **Zero code has been written.** Nothing in the app has changed. The whole
  program is two planning documents.
- Another agent may hold uncommitted work in `AgentSupervisor.swift`,
  `AgentComposerFooterView.swift`, `ManagedAgentTileNSView.swift` (harness-pick
  atomicity). Check `git status` before touching those.
- The repo moved from 0.5.8 to 0.5.10 during the investigation. Re-verify any
  line citation before relying on it — 43's citations were accurate at `09de0b0`.

## Decisions already made by Dylan — do not relitigate

- **Ship order: (1) UI overhaul including tool rows, (2) dead air / feel,
  (3) commands and what commands do — compaction, agents.** Slices 4 (steering /
  interrupt) and 5 (note/file linkage) were added later and are unsequenced.
- **User messages stay full-measure.** Not right-aligned chat bubbles. This
  resolves the contradiction between `_DESIGN.md` §11 and the renovation
  handoff in favour of the charter.

## The one pattern that explains this whole program

**Repeatedly, the renderer was built and the supply was never built.** Verified
instances:

- Subagent chips: renderer registered in the frozen registry;
  `observeSpawnRequests` is an empty body in both the claude and codex runners
  whose own comment says *"never fires"*; pi's extension is not installed and
  Array never passes `-e`. **No chip can ever appear.**
- Tool detail: `AgentToolDetailStore` models arguments/output/exitCode/duration
  and `AgentToolDetailPresenter.expanded(_:)` produces a full presentation.
  Production `recordEnd` always passes `output: nil, exitCode: nil, endedAt: nil`.
  **Duration and exit code are structurally unrenderable.**
- `CommandOutputView`: a complete scrollable output pane with a copy button. No
  translator emits `contentDelta(.commandOutput)`. **Dead code.**
- Edit diffs: no production hit anywhere for `old_string`/`new_string`. All three
  translators discard tool inputs at parse time under I5.
- `AgentCapabilities`, `TurnOutcome.interrupted`/`.cancelled`,
  `AgentTileOperationalState.queued`, `automaticCompaction`,
  `AgentDiffPayload.canOpenReview`, `canSteer`/`canQueue`: all modelled, all
  consumed, **none produced.**
- The companion: an E2EE transport with no cargo, and a write-only transcript
  store (production writes `sessionID = "managed-<tileId>"`, the sole reader
  hardcodes `"thread-main"`).

**Design consequence:** for every slice, name the producer before the renderer.
A slice that ends "the new row is beautiful and still shows no diff" has repeated
the mistake. This is why 43 splits slice 1 into 1a/1b (fixtures + data capture,
invisible to the user) before 1c-1h (the visible overhaul).

## The second pattern: witnesses blind in exactly the failing axis

Every defect found had a green check next to it, because each check drove a real
path while being blind on the one axis that mattered:

- `AgentFirstPaintChecks` — three cases, all building
  `AgentTileTurnSnapshot(state: .starting, …)` **by hand**. Nothing drives the
  real `[.ready, .running, .turnStarted]` sequence through `updateTurnFacts`.
- The document-connector pixel witness — real render, real accent-pixel
  assertion, **at viewport `(0,0,zoom 1)`**, the one camera at which the
  pan-offset bug is invisible.
- `--agent-local-file-link-check` — real Markdown, real `activateLink`, real
  tile, but it **wires its own `onOpenLocalFile` closure** (so
  `AppDelegate.openAgentLocalFile` never runs), passes the **project root**
  where production passes `record.cwd`, and never asserts the tile is
  **on-screen**.
- Every stop check drives a `ScriptedAgentRunner` whose `stop()` never throws, so
  none reproduces `terminationStatus != 0 → throw → .runtimeError`. **Nothing
  anywhere asserts a deliberate stop is not a failure.**

**Rule for this program: for every fix, first write the witness that fails, and
make sure it fails for the real reason.** Then fix. Assert counts and ordering,
never wall-clock.

## Highest-value, smallest-diff opportunities

Consider proposing these to Dylan for promotion — he has been asked and has not
yet answered:

1. **§5e — a workspace switch turns every tile into a dead placeholder.**
   `WorkspaceRuntime.install`/`switchWorkspace` build `DescriptorTileNSView` for
   every member tile ("real hydration is T08");
   `installInitialManagedAgentTile` has one production call site, the boot walk.
   Before `ecf3bf3` the flat views survived a switch and `tileView(for:)` found
   them; `retireFlatCompatibilityScene()` empties that table, so the latent
   defect is now live. **`openDocument` itself calls `switchWorkspace`**, so one
   cross-workspace link click can kill the tiles the next link lived in. This
   actively loses work and outranks an ugly tool row.
2. **Make subagents appear at all, on claude.** Pass
   `--forward-subagent-text`, stop dropping `parent_tool_use_id` frames
   (`ClaudeEventTranslator.isSubagentFrame`), key the child on the `Task`
   tool_use id. Lights up the chip, the sidebar child row and the lineage
   overlay simultaneously, because all three are already built. Largest visible
   product per line of diff in the whole program.
3. **A stop must not be a failure.** Give pi a `stopRequested` flag, check it
   **before** the non-zero-exit throw in all three runners, and emit
   `turnCompleted(outcome: .interrupted)`. Eleven consumers already handle that
   outcome, including an unreachable "don't push a failure notification" branch.
   Measured: `SIGINT` → 130, `SIGTERM` → 143, so **no signal change fixes this**
   and the flag is mandatory. Also measured: a signalled pi writes **no session
   file at all**, so an interrupted turn silently loses conversation continuity —
   a worse bug than the reported error row, and currently invisible.
4. **§5a/§5c — visual linkage.** Two independent causes: the overlay draws
   world-space segments in a view whose bounds origin is never set to the pan (so
   connectors are displaced, and clipped away entirely beyond one viewport), and
   `refreshDocumentRelationships()` has four call sites, **none after the boot
   tile walk** (so connectors and "N references" chips are invisible on every
   cold launch).

## Open questions to resolve with Dylan

From 43, plus what the investigation added:

1. Split slice 1 into invisible (1a fixtures + 1b data capture) and visible
   (1c-1h), shipping separately?
2. The live-work row spans slices 1 and 2 by construction. Pull the
   `submittedAt` two-liner forward into slice 1 so the row is honest on arrival?
3. Tool-call clustering interacts with turn folding — together or separate?
4. Inline diff only, or also a "reveal in diff tile" affordance?
   (`AgentDiffPayload.canOpenReview` exists; the projection never sets it true.)
5. Companion stays paused until the write-only key bug is fixed?
6. Promote §5e and/or the claude-subagent slice ahead of the UI overhaul?

## One genuinely unresolved empirical question

**Is mid-turn steering real or merely queued?** If claude's
`--input-format stream-json` lets a second stdin message reach the model *during*
a turn, that is genuine steering. If the harness only accepts it as the next
turn, it is a queue with a nicer label. **These justify different UI, so settle
it before designing.** Also unprobed: pi's `--mode rpc` method list, and codex's
`app-server` / `exec-server` / `mcp-server` / `remote-control`.

Established: claude's `system/init` advertises
`capabilities: ["interrupt_receipt_v1","interrupt_cancel_queued_v1",
"msg_lifecycle_v1"]` plus a `messaging_socket_path`. Those names imply an
acknowledged interrupt, a real queue, and a message lifecycle.

**Run these probes in the FOREGROUND.** Two background subagents attempting this
were orphaned by host session restarts and produced nothing.

## Probe hygiene, learned the hard way

- `timeout` does not exist on this macOS. Use python3/perl or background+kill.
- Never probe inside `/Users/dylan/Documents/personal/Array` or any git repo
  there. Use a fresh `/tmp` dir.
- Never modify `~/.codex/config.toml`, `~/.claude/settings.json`,
  `~/.pi/agent/settings.json`. Use flags and `-c` overrides.
- Never touch tmux or the default tmux socket while Array may be running.
- In two codex probes the model reported file contents it had never read, having
  spawned nobody, and was accidentally right. **Render evidence, not claims.**

## Repo-specific traps for this work

- **`CLAUDE.md` hazard 9 is out of date and should be corrected in place**, since
  agents read it as ground truth. All four spawns it names (terminal, note,
  browser, agent) **are** migrated to `installProjectTile`. The one remaining
  production spawn on the stale path is **`spawnRunArtifacts`**
  (`TileSpawner.swift:2246, 2262`), unmentioned. Its citation of
  `TileSpawner.swift:1422` is wrong — that line is `configureBrowserRuntime` and
  the file contains no `Descriptor`; the real location is
  `WorkspaceRuntime.swift:229-234` and `:680-684`, and it applies to every tile
  kind.
- **I5 / sync-boundary purity is non-negotiable.** Never widen
  `AgentRuntimeEvent` with arguments or results. The host-local, non-`Codable`,
  TTL-scoped `AgentToolDetailStore` is the sanctioned channel and this is
  pre-authorized by `plan-managed-agent-tile-polish.md` §12.3.
- **Hazard 8.** Every transcript row view paints `layer.backgroundColor` and
  **none declares `TokenThemed`** — they are all invisible to the appearance
  census. New or touched views need conformance, a `tokenAdoptedOwners` entry
  with a ticket comment, paint in both an appearance-sweep and an adopted
  surface in both appearances, and `nil` at rest, never `.clear`.
- **`performance.md` traps live in this exact code.** The 0.4.16 hang was 725 of
  ~750 samples in `AssistantProseView.layout()`.
  `AgentDiffSummaryView.rebuildFileLabels()` destroys and recreates up to 8
  `NSTextField`s on every `apply` — do not copy it for diff lines.
  `ToolCallView.layout()` assigns all five frames unconditionally every pass.
  Any per-row indent must enter `AgentBlockMeasureKey` or a nested row reuses a
  top-level row's cached height at the wrong width.
- **Keep the transcript's virtualization.** `AgentTranscriptListView` is an
  `NSCollectionView` with a diffable source, a width-bucketed layout, a
  measurement cache and a 30 Hz scheduler, guarded by two matrix legs. Do not
  rebuild it.
- **`agent.transcript.review` is a `.reviewSurface`**, so every baseline sweep
  skips it. Converting it to `.staticCard` is the precondition for not working
  blind — which is how the previous session wrote 2,267 lines of transcript UI
  with two images in context, neither of them the desktop transcript.

## Verification doctrine

- Judge `scripts/run-matrix.sh` by its **end-of-run summary**, never the exit
  code. Confirm every new leg actually prints. Never add a KNOWN-RED silently.
  Two program checks pin that script's own text verbatim with `grep -Fxc`.
- Never guess a `--*-check` flag; an unknown one falls through the cascade and
  boots the full app. Enumerate:
  `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u`
- **Look at it.** Per slice: `scripts/dev-app.sh` against a root no other agent
  is using, screenshot the fixture gallery and the live tile, compare with the
  previous slice. A slice is not done until it has been seen.
- Commits under Dylan's identity only. No AI-attribution trailers.

## Your first deliverable

Not code. A ticket breakdown for the agreed first slice, with, per ticket: the
producer being added, the renderer consuming it, the witness that fails first and
why it fails for the real reason, and the fixture that makes it reviewable.
Append it to `.plans/43` rather than starting a new document.
