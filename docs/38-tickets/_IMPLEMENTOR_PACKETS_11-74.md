# Implementor packets — tickets 11–74 dry run

These packets are read-only scout output for unattended agents. They supplement the original ticket files; they do not remove, weaken, or replace the original directives. The original `docs/38-tickets/<NN>.md` remains authoritative, with `_CONFLICT_LOG.md` and `_PROGRESS.md` providing rulings/attempt history.


---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-8a018c/final.md -->

# Implementor packets: tickets 11–20

Read-only packetization of `docs/38-tickets/11-activity-tree-snapshot.md` through `20-project-release-detach.md`. Original directives preserved: do not edit docs; implement in code only when assigned.

## 11 — Activity tree snapshot type

**Contract**
- Add `ActivityTreeSnapshot` data model wrapping `SidebarTree`, `capturedAt`, `replicaId`, derived rollup.
- Add optional `AgentSnapshot.Evidence?` to `SidebarTileRow`.
- Make sidebar tree structs `Codable`.
- Add `SidebarTreeBuilder.build(... agentSnapshots:)` overload.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/SidebarTree.swift`
- Tests: `Tests/ContinuumRevivedCoreTests/ActivityTreeSnapshotTests.swift`

**Dependencies**
- Depends on agent-state-reader protocol ticket for `AgentSnapshot` / `AgentSnapshot.Evidence`.
- If absent, doc permits temporary local forward declaration.

**Acceptance gates**
- `swift build --target ContinuumRevivedCore`
- `swift test --filter ActivityTreeSnapshotTests`
- Round-trip, rollup derivation, evidence threading, I5 taint scan.

**Common failure modes**
- Accidentally tying `Evidence` dependency to sync/observation split.
- Using `Date.now()` for `capturedAt`.
- Forgetting tree collection mutability for evidence threading.
- Leaving duplicate forward declaration after real `Evidence` lands.

**Risk / suitability**
- **Medium**. Pure model work, autonomous-suitable if `AgentSnapshot` state is verified first.
- **Blockers/conflicts:** Unsuitable if ticket 35 / agent-state-reader protocol has not landed and team does not want temporary forward declarations.

---

## 12 — Injectable substrates

**Contract**
- Add seams/fakes: `TmuxControl`, `Clock`, `Host`, `SyncTransport`.
- Add minimal transport envelope, but **use existing ticket-02 `OpId`; name opaque envelope `TransportLoggedOp`**, not `LoggedOp`, per ruling in doc.
- Add `ProcessTmuxControl` real implementation and deterministic fake checks.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/Substrates/*.swift`
- `Sources/ContinuumRevivedCore/TmuxSession.swift` should remain pure / mostly unchanged.
- `Sources/ContinuumRevivedCoreChecks/main.swift`

**Dependencies**
- Intended standalone, but doc notes ticket 02 already landed `OpId` / `LoggedOp`.
- Later tickets depend heavily on this.

**Acceptance gates**
- Core checks for fake tmux, fake clock, fake host, fake transport.
- Real-path tmux check skips explicitly if tmux absent.
- No new bare `Date()` in new topology/observer/transport code.

**Common failure modes**
- Re-declaring `OpId` or naming opaque envelope `LoggedOp` causing collision.
- Putting fake-only `deliver()` on `SyncTransport` protocol.
- Fake tmux not modeling pane death accurately.
- Coupling transport to spatial `Op`.

**Risk / suitability**
- **High**. Broad foundational seam; many API shape decisions.
- **Autonomous-suitable only if ticket 02 current types are inspected first.**
- **Blockers/conflicts:** Existing `SpatialOp.swift` names conflict with older prose; must follow ruling.

---

## 13 — Invariant spine harness

**Contract**
- Add `InvariantManifest`, `JSONValue`, `InvariantOutcome`, writer.
- Append I1–I8 blocks to `ContinuumRevivedCoreChecks`.
- I6 and I7 full assertions; I1/I2/I3/I4/I5/I8 non-vacuous stubs with manifests.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/InvariantManifest.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`

**Dependencies**
- Depends on injectable substrates for real fake types.
- Names topology/activity snapshots by ticket; not necessarily by code in stubs.
- Uses existing `AgentStatusEngine`, descriptor/canvas/workspace codable types.

**Acceptance gates**
- `swift build` no warnings.
- `.build/debug/ContinuumRevivedCoreChecks` exits 0.
- Every invariant writes and reads back manifest.
- No content-free `{"passed":true}` manifests.
- I4 stub includes tripwire comment.

**Common failure modes**
- Defining local stand-ins for not-yet-existing types.
- Hardcoding “measured” field counts.
- Wall-clock `Date()` in checks.
- Stub block with no domain-adjacent assertion.
- Naming wrapper `AnyCodable` instead of `JSONValue`.

**Risk / suitability**
- **Medium–High** because `main.swift` is large and no-warning bar matters.
- Autonomous-suitable for a careful agent after inspecting existing check patterns.
- **Blockers/conflicts:** Ticket 12 should land first if stubs refer to its real fake types.

---

## 14 — Project session naming & lifecycle ownership

**Contract**
- Add project/workspace session naming APIs.
- Add project kill argv helper.
- Add controller convenience methods and D16 lifecycle comment.
- Preserve legacy `sessionName(tileId:)`.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevivedCoreChecks` or existing controller self-checks.
- Component Lab settings/naming panel if present.

**Dependencies**
- Store-protocol seam / stable `projectId`.
- Does **not** require injectable `ProjectStore`.

**Acceptance gates**
- Exact string checks for:
  - `continuum-proj-<uuid>`
  - `continuum-ws-<uuid>`
  - legacy `continuum-<tileId>`
  - project kill-session argv.
- Controller temp-directory check.
- Component Lab “session naming” panel.

**Common failure modes**
- Deleting `sessionName(tileId:)` too early.
- Lowercasing/truncating UUID.
- Calling project kill from `close()`.
- Trying to prove via `tmux ls`; spawn path intentionally unchanged.

**Risk / suitability**
- **Low–Medium**. Mostly pure naming and comments.
- Autonomous-suitable.
- **Blockers/conflicts:** If Component Lab surface is absent, UI gate may need scoped alternative or be marked not completed.

---

## 15 — New terminal tile spawns a window in the project session

**Contract**
- Project-zone new terminal creates tmux window in `continuum-proj-<projectId>` via `TmuxControl`, captures `%pane_id`, persists `tmuxWindowTarget`, then ghostty attaches to pane.
- Ambient/nil-project tiles keep legacy per-tile session path.
- Add/read `TerminalSessionDescriptor.tmuxWindowTarget` schema v3 if not already landed.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
- `TmuxControl` substrate
- Existing TileSpawner self-checks around spawn argv.

**Dependencies**
- Ticket 12 `TmuxControl` + fake + real impl.
- Ticket 14 `projectSessionName`.
- Overlaps ticket 16 on `tmuxWindowTarget`; avoid duplicate schema work.

**Acceptance gates**
- In-memory spawn 3 project tiles: exactly 1 `newSession`, 2 `newWindow`, 3 distinct targets.
- Ambient spawn: no project-window calls, target nil, legacy argv.
- Descriptor schema v3 round-trip and v2 decode.
- Save failure triggers compensating `killWindow`.
- Real tmux: two panes in one project session or explicit skip.

**Common failure modes**
- Trying to capture `-P` output through ghostty instead of `TmuxControl`.
- Try/catch fallback instead of deterministic `sessionExists` branch for initial spawn.
- Saving descriptor before pane capture.
- Missing compensating kill on save failure.
- Breaking ambient delete lifecycle check.

**Risk / suitability**
- **High**. Core behavior change touching spawn/persistence/tmux.
- Autonomous-suitable only after ticket 12 and 14 are confirmed landed.
- **Blockers/conflicts:** Strong overlap/conflict with ticket 16 wording; assign only one agent to own schema/capture seam or require coordination.

---

## 16 — Capture `tmuxWindowTarget` at spawn

**Contract**
- Ensure `%pane_id` is captured synchronously at spawn and persisted as `TerminalSessionDescriptor.tmuxWindowTarget`.
- Add schema v3 + validation + new-window argv helper if not already delivered by ticket 15.
- Preserve captured target on flush.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `TmuxControl` real/fake

**Dependencies**
- Ticket 15 is explicitly predecessor in doc.
- Ticket 14 for `projectSessionName`.
- Ticket 12 for `TmuxControl`.

**Acceptance gates**
- Descriptor v3 round-trip and v2 decode.
- `TmuxSession.isValidPaneId` table.
- `newWindowArguments` shape check, if this approach still applies.
- Flush preserves `existing.tmuxWindowTarget`.
- Real tmux capture/liveness probe or explicit skip.
- Dogfood: two descriptors have distinct `%N`.

**Common failure modes**
- Duplicating or contradicting ticket 15’s create-then-attach implementation.
- Capturing lazily/asynchronously.
- Storing window index / `@N` instead of `%N`.
- Omitting flush preservation, silently zeroing targets.
- Compensating kill firing when no window was created.

**Risk / suitability**
- **High** due overlap with ticket 15.
- **Potentially unsuitable for unattended standalone run unless ticket 15 state is known.**
- **Blockers/conflicts:** If ticket 15 already added schema/capture, this ticket becomes hardening/check work; if not, docs disagree on exact API (`run(arguments:)` vs `newSession/newWindow`).

---

## 17 — Dead-target fallback

**Contract**
- On restart, probe stored `tmuxWindowTarget`.
- If live: reuse.
- If nil/dead: create replacement window in project session; if session missing, fall back to `newSession`; persist new target.
- Tmux-disabled/ambient paths unchanged.

**Likely files / seams**
- `Sources/ContinuumRevived/App/TileSpawner.swift`, `restartTerminalTile(tileId:)`
- `TerminalSessionDescriptor.tmuxWindowTarget`
- `TmuxControl.isAlive/newWindow/newSession`
- Existing TileSpawner self-check suite

**Dependencies**
- Ticket 15 must be merged.
- Ticket 14 naming.
- Ticket 12 substrates.

**Acceptance gates**
- Logic with fake tmux:
  - live target reused, no create call.
  - dead target → `newWindow`.
  - nil target → `newWindow` without probe.
  - `newWindow` throws → `newSession`.
  - tmux disabled → no calls, stored target untouched.
- Real tmux:
  - kill pane then restart stores new live target.
  - live restart does not create extra window.
  - nil target upgrades to live target.
- Dogfood visual prompt after external pane kill.

**Common failure modes**
- Inventing `activeProjectId()` instead of using `terminalProjectContextProvider?()?.id`.
- Shelling out directly instead of using injected `TmuxControl`.
- Crashing on nil target.
- Removing tile on fallback failure.
- Double restart race creating two windows.

**Risk / suitability**
- **High** and doc says **Supervised** due Ghostty/canvas visual gate.
- **Unsuitable for fully unattended completion** unless scope is limited to logic/backend checks and final clearly marks visual dogfood unverified.
- **Blockers/conflicts:** Requires ticket 15 fully landed.

---

## 18 — CWD inheritance policy

**Contract**
- Add `NewTileCwdConfig` with policies `inheritFocus`, `projectRoot`, `lastUsed`.
- Fresh terminal spawns use policy-resolved cwd; restart/restore path unchanged.
- Wire focused terminal cwd from last-active terminal runtime.
- Add Settings choice field.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/NewTileCwdConfig.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- Existing terminal self-check area in `TileSpawner.swift`

**Dependencies**
- Existing `canvasState.lastActiveTileId`
- `GhosttyTerminalRuntime.capturedCwd`
- No dependency on topology tickets.

**Acceptance gates**
- Pure policy tests with scratch `UserDefaults`.
- `runNewTileCwdSelfCheck`: descriptor cwd equals injected focused path / project root per cases.
- Settings row visible, persists.
- Dogfood: second shell opens in focused terminal’s cwd; non-terminal focus falls back.

**Common failure modes**
- Applying policy to `restartTerminalTile`; persisted cwd must win on restore.
- Overriding cwd after tmux wrapping, causing argv/descriptor mismatch.
- Routing harness-role spawns through policy.
- Inventing nonexistent `LaunchProfile.environment` or `with(cwd:)`.
- Persisting `lastUsed` despite doc pinning it in-memory only.

**Risk / suitability**
- **Medium**. Some UI/settings wiring.
- Doc says **Supervised** due Settings/Ghostty dogfood.
- **Unattended suitability:** good for code + self-checks, but final must mark visual UX gate unverified unless run under app UI.

---

## 19 — Close tile = kill-window

**Contract**
- Add `TmuxSession.killWindowCommand(target:tmuxPath:)`.
- On terminal tile close, if descriptor has `tmuxWindowTarget`, issue `kill-window -t <target>`.
- If target nil, legacy fallback `kill-session -t continuum-<tileId>`.
- Teardown/project release remains no-kill/detach.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `TerminalSessionDescriptor.tmuxWindowTarget`
- Existing delete lifecycle self-check around `ContinuumApp.swift:11082`

**Dependencies**
- Ticket 16 / target capture hard prerequisite.
- Ticket 15/14 conceptual prerequisites.

**Acceptance gates**
- Pure argv shape check.
- Production delete self-check:
  - non-nil target emits exactly `kill-window -t %N`.
  - nil target emits legacy `kill-session`.
  - teardown emits zero kill commands.
- Real tmux: close one of three windows leaves two; close last ends session.

**Common failure modes**
- Dropping nil-target fallback, leaking legacy sessions.
- Killing project session directly.
- Targeting window index instead of pane id.
- Weakening self-check to non-strict command count.
- Confusing app teardown/release with user tile close.

**Risk / suitability**
- **Medium–High**. Behavioral lifecycle change but well-scoped.
- Autonomous-suitable if target field exists and real-tmux check can skip explicitly.
- **Blockers/conflicts:** Requires ticket 16/15 state; if close-tile ticket changes function names, ticket 20 must account for rename.

---

## 20 — Project release = detach, never kill

**Contract**
- Prove `ZoneRuntimeRegistry.release(projectId:)` → `ZoneRuntimeController.close()` detaches/flushes but never issues tmux kill.
- Add structural registry assertions 10–11 and manifest count 11.
- Add substrate positive-control sentinel for fake kill logging.
- Add backend release scenario to lifecycle self-check with command capture empty.
- Add lifecycle comments.

**Likely files / seams**
- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `InMemoryTmuxControl` from substrates

**Dependencies**
- Ticket 19 close-tile lifecycle.
- Ticket 12 substrates for sentinel.
- Existing `CommandCapture` in delete lifecycle self-check.

**Acceptance gates**
- Registry refcount self-check manifest: `assertions: 11`, release no-kill booleans true.
- Sentinel records `InMemoryTmuxControl.TmuxCall.killSession`.
- Backend release scenario: after `registry.release`, `capture.commands == []` and lastExit stamped.
- Existing delete and teardown lifecycle checks still pass.

**Common failure modes**
- Trying to inject tmux fake into `ZoneRuntimeController`, creating a seam that should not exist.
- Claiming command-log proof at controller level where no command log exists.
- Adding explicit tmux detach call to `close()`.
- Forgetting sentinel, making no-kill proof unfalsifiable.
- Assuming kill-site function name before ticket 19 rename; assert “no kill command of any kind.”

**Risk / suitability**
- **Medium**. Mostly checks/comments around existing behavior.
- Autonomous-suitable after ticket 19 and 12 land.
- **Blockers/conflicts:** If `ZoneRuntimeController.close()` actually grows tmux dependency in parallel, this ticket must stop; structural invariant invalidated.

---

# Cross-ticket conflicts / sequencing

1. **12 before 13/15/17/20** — substrates are foundational.
2. **14 before 15/16/17** — project session naming is required.
3. **15 and 16 overlap heavily** — both touch `tmuxWindowTarget`, descriptor schema v3, capture timing. Do not run unattended in parallel without a merge plan.
4. **17 after 15/16** — restart fallback needs target field and project-window spawn.
5. **19 after 16** — close by window requires persisted target.
6. **20 after 19** — release detach proof assumes close path is window-scoped.
7. **18 is relatively independent** — can run earlier, but supervised UX gate remains.

# Unsuitable / partially unsuitable for unattended runs

- **17 Dead-target fallback:** marked supervised; requires visual Ghostty/canvas dogfood for full completion.
- **18 CWD inheritance:** marked supervised for Settings/Ghostty confirmation; unattended agent can complete code/self-checks but should not claim visual gate.
- **15/16:** high-risk unattended if run independently because of overlap and dependency state. Suitable only after inspecting current landed code and assigning one owner for capture/schema seam.

---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-dc2446/final.md -->

## Map

Read-only packetization for tickets `21`–`30` in `/Users/dylan/Documents/personal/continuum-overnight/docs/38-tickets/`. No files edited.

---

## Implementor packets

### 21 — Idle reaper: detach stale no-active-turn sessions

**Contract**
- Add `SessionPruner` actor that periodically detaches stale sessions, never kills.
- Idle gate: `clock.now() - lastSeenAt >= inactivityThreshold`.
- Active-turn guard: skip if any bound tile is `.working`.
- Blind to disconnects/client lifecycle.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/SessionPruner.swift`
- `Sources/ContinuumRevivedCore/IdleReaperConfig.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`

**Dependencies**
- Hard blocked on injectable substrates: `Clock`, `FakeClock`, `TmuxControl`, `InMemoryTmuxControl`, `ProcessTmuxControl`.
- Hard blocked on `ActivityTreeSnapshot`.
- Uses `project.createdAt` as temporary `lastSeenAt`; does **not** depend on managed session record.

**Acceptance gates**
- Pure checks: idle gate, active-turn guard, disconnect blindness, never-kill, configurable thresholds.
- Real tmux check: `detachSession` leaves session listed as detached, not absent.
- Settings fields persist and drive config.

**Common failure modes**
- Accidentally calling `kill-session`.
- Starting reaper in `init` before tmux control exists.
- Polling tmux for active work instead of using `ActivityTreeSnapshot`.
- Enumerating all `continuum-*` sessions instead of controller-owned bindings.

**Effort**
- Medium, but blocked.

**Blockers / conflicts**
- Cannot start until substrate + activity snapshot tickets land.

---

### 22 — Per-workspace session for ambient tiles

**Contract**
- Ambient/group-zone terminal tiles share `continuum-ws-<workspaceId>` session.
- First tile creates session; later tiles create new windows.
- Captured `%pane_id` stored as `tmuxWindowTarget`.
- Runtime setting keeps per-tile fallback default initially.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevivedCore/TmuxSession.swift` / `TmuxPersistenceConfig`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCore/AmbientZoneHome.swift` read-only seam

**Dependencies**
- Project/session naming work provides `TmuxSession.ambientSessionName(workspaceId:)`.
- New-tile-as-window work provides `TmuxControl.sessionExists`, `newSession`, `newWindow`, `attachWindowProfile`, `tmuxWindowTarget`.
- Close-tile kill-window work.
- Membership-as-tile-register work.

**Acceptance gates**
- Two ambient tiles → one `newSession`, one `newWindow`, two distinct targets.
- Setting off → old per-tile path unchanged.
- Close one ambient tile → `kill-window`, not session kill.
- Workspace delete → `killSession("continuum-ws-<id>")`.
- Real tmux check: one workspace session with two windows; closing last tile ends session.

**Common failure modes**
- Using `new-session -A` for second tile, causing mirrors.
- Capturing `-P -F '#{pane_id}'` from Ghostty argv instead of `TmuxControl`.
- Try/catch fallback instead of deterministic `sessionExists`.
- Flipping default to true before real checks pass.

**Effort**
- Medium-large.

**Blockers / conflicts**
- Hard blocked on upstream topology and kill-window work.

---

### 23 — Private managed-agent session record

**Contract**
- Add private host-local `ManagedAgentSessionRecord` per tile under `.continuum-revived/managed-sessions/`.
- Stores `AgentKind`, narrow runtime status, `lastSeenAt`, opaque `resumeCursor`, opaque `runtimePayload`.
- Must not sync or appear in spatial/projected types.
- Writes initial record at spawn; updates `.stopped` on controller close.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/ManagedAgentSessionRecord.swift`
- `Sources/ContinuumRevivedCore/ManagedAgentSessionStore.swift`
- `Sources/ContinuumRevivedCore/ProjectStore.swift` / `ProjectStoreLayout`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- Taint scan / core checks

**Dependencies**
- Hard prerequisite: `AgentKind` enum from ticket 31/D14.
- Window-target capture seam.
- Sync/observation split for taint checks.

**Acceptance gates**
- Store round-trip, upsert, delete, missing-file nil, `loadAll`.
- `tmuxWindowTarget()` extraction from payload.
- Sync-boundary Mirror / raw JSON checks.
- Backend: real spawned tile writes managed-session JSON; close updates status.
- Component Lab field-readout card.

**Common failure modes**
- Adding `tmuxWindowTarget` / cursor / payload to `TerminalSessionDescriptor`.
- Using `String` instead of `AgentKind`.
- Failing to create `managed-sessions` directory before write.
- Aborting `loadAll` on one corrupt file.

**Effort**
- Medium.

**Blockers / conflicts**
- Stop if `AgentKind` has not landed.

---

### 24 — Lazy resume on tile focus

**Contract**
- Add `ZoneRuntimeController.routableSession(forTile:allowRecovery:tmux:)`.
- Branch order:
  1. Adopt existing live target.
  2. If dead and `allowRecovery == false`, return `.inactive`.
  3. If dead and no cursor, throw `.noResumeState`.
  4. If dead with cursor, create new window and persist fresh target.
- Trigger only on focus reasons `.userClick` and `.appActivated`.

**Likely files / seams**
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevived/App/FocusBroker.swift` callback seam only
- `Sources/ContinuumRevived/App/TileSpawner.swift` read-only seam
- Managed session store from ticket 23
- `TmuxControl`

**Dependencies**
- Managed session record/store.
- Injectable `TmuxControl`.
- New-window project-session path.

**Acceptance gates**
- Table-driven logic check for live, dead+cursor, dead+no cursor, allowRecovery false, nil payload, absent record.
- Focus callback: `.noBinding` silent; `.noResumeState` surfaces tile error.
- Grep/manifest proves no eager recovery at init/launch/close.
- Component Lab lazy-resume states.

**Common failure modes**
- Calling `TileSpawner.spawnTerminal` in resume path.
- Treating `.noBinding` as user-visible error.
- Denylist focus filtering instead of explicit allowlist.
- Not bumping `lastSeenAt` on adopt-existing.

**Effort**
- Medium-large.

**Blockers / conflicts**
- Cannot implement meaningfully before ticket 23 and `TmuxControl`.

---

### 25 — Reattach by target + replay scrollback

**Contract**
- Consume ticket 17’s existing alive/dead branch; do not add a new probe.
- Alive target: native tmux scrollback wins; never replay persisted snapshot.
- Dead/nil target: after new surface installed, replay persisted scrollback in chunks.
- `replayScrollback` is async, chunked at 4096 bytes, uses `await Task.yield()`, appends `\r\n`.

**Likely files / seams**
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
- `Sources/ContinuumRevivedCore/SessionResumeConfig.swift`
- `GhosttyTerminalRuntime.sendInput`

**Dependencies**
- Ticket 15 target capture.
- Ticket 17 dead-target fallback and async `restartTerminalTile`.
- Ticket 12 `TmuxControl`.
- Private managed-agent record.

**Acceptance gates**
- Logic: alive suppresses replay, dead replays, chunking, setting guard.
- Real tmux/Ghostty check: `pidBefore == pidAfter`, `targetBefore == targetAfter`, `cwdBefore == cwdAfter`, sentinel visible.
- Dogfood: quit/reopen preserves process and scrollback.

**Common failure modes**
- Adding a second liveness probe.
- Replaying stale scrollback on live target.
- Using `RunLoop.current.run` inside async path.
- Assuming nonexistent shared tmux helper functions.

**Effort**
- Medium, but needs real substrate.

**Blockers / conflicts**
- Blocked until ticket 17’s branch exists.

---

### 26 — Upgrade migration

**Contract**
- On first post-upgrade launch, detect legacy project-zone descriptors and delete them so normal spawn creates fresh project-session windows.
- Show one-time alert before spawning.
- Leave old `continuum-<tileId>` tmux sessions alive; never auto-kill.
- Ambient legacy descriptors are untouched.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/DefaultWorkspaceMigration.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `ProjectStore`
- `TerminalSessionDescriptor`

**Dependencies**
- Project-session naming.
- `tmuxWindowTarget` field/schema.
- Dylan decision required on visual-gate waiver vs substitute.

**Acceptance gates**
- Pure detection checks: legacy project zone fires; identical ambient shape does not; new shape ignored; missing tile ignored.
- Backend store check: write-first alert flag, descriptors deleted, ambient survives, idempotent once flag set.
- Dogfood alert appears once and before canvas interaction.

**Common failure modes**
- Descriptor-only detection that restarts ambient tiles.
- Writing `migrationNoteShown` after alert.
- Killing old tmux sessions.
- Keying on brittle argv positions like `args[1]`.

**Effort**
- Medium.

**Blockers / conflicts**
- Visual-gate waiver unresolved.
- Depends on naming + target capture.

---

### 27 — Grouped view session per tile

**Contract**
- Project tile surfaces attach via grouped view sessions `continuum-view-<tileId>`.
- Attach argv: `new-session -t <projectSession> -s <viewSession> -A ; select-window -t <tmuxWindowTarget>`.
- Separator token in argv is literal `";"`, never `"\\;"`.
- Ambient tiles remain on per-tile fallback.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `GhosttyTerminalView.swift` read-only consumer

**Dependencies**
- Project-session naming + new-window spawn + session-target provider.
- Capture-window-target.
- Close-tile kill-window work.

**Acceptance gates**
- Pure checks for view session name, `wrapViewSession` argv, kill command, distinct names.
- Real tmux check: two grouped view sessions have different active window IDs; view kill does not kill project session.
- Component Lab/affordance inspector shows distinct `select-window` targets.
- Dogfood no mirroring between two project tiles.

**Common failure modes**
- Using `"\\;"` in Process/argv context.
- Resolving project ID from global active project instead of session-target provider.
- Omitting `-A`, breaking reattach.
- Observer code using `select-window`.

**Effort**
- Large.

**Blockers / conflicts**
- Hard blocked on three upstream topology pieces.

---

### 28 — View-session cleanup on tile close

**Contract**
- On terminal tile close, kill project window first, then kill `continuum-view-<tileId>` session.
- Missing view session is non-fatal.
- App teardown still issues zero tmux kills.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- Existing terminal close self-checks

**Dependencies**
- Grouped-view-session spawn.
- Close-tile kill-window.
- `SessionTopologySnapshot` only for deferred real-tmux snapshot integration.

**Acceptance gates**
- Pure checks: `viewSessionName`, `killViewSessionCommand`, namespace distinctness.
- Fake runner self-check: exactly two commands, ordered: window teardown then kill-view-session.
- Throwing second call does not abort tile removal/canvas save.
- Teardown and tmux-disabled sub-checks remain zero commands.
- Optional gated real tmux snapshot check.

**Common failure modes**
- Killing view session before project window.
- Propagating missing-view-session error.
- Adding kill during app teardown.
- Relaxing command count to `>= 1`.

**Effort**
- Small-medium once dependencies landed.

**Blockers / conflicts**
- Must not be layered onto old close path that still uses `kill-session` for tile content.

---

### 29 — No-mirror real-path check (I2)

**Contract**
- Add real-tmux I2 check proving two grouped view sessions pinned to different windows report different active `window_id`s.
- Add/verify pure verdict logic distinguishing distinct, deliberate shared, accidental mirror.
- Structured skip when tmux absent; skip manifest is not a pass.

**Likely files / seams**
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `ProcessTmuxControl`, `TmuxLocator`

**Dependencies**
- D19 grouped view helpers.
- D25 target capture / pane IDs.
- D26 substrates.
- May add `isValidWindowId`, `activeWindowTargetArguments`, `i2Verdict` if absent.

**Acceptance gates**
- Pure checks: verdict truth table, pane/window validators, grouped attach argv, active-window query uses `#{window_id}`.
- Real tmux check writes measured manifest: pane IDs, active window IDs, `i2Distinct: true`, `sharedViewExemptionCorrect: true`.
- Skip path writes partial manifest and `break i2Check`, not `exit`.

**Common failure modes**
- Confusing `%pane_id`, `@window_id`, and window index.
- Treating equal observed windows as exemption without declared intent.
- Always skipping in CI and calling it coverage.
- Using fake tmux instead of `ProcessTmuxControl`.

**Effort**
- Medium-large; needs substrate.

**Blockers / conflicts**
- Blocked on grouped view mechanism and substrate.

---

### 30 — Deliberate shared-view exemption

**Contract**
- Add `TerminalSessionDescriptor.isSharedView: Bool = false` beside `tmuxWindowTarget`.
- Same-window pair is exempt only when both descriptors opt in.
- One-sided opt-in is its own violation category.
- No production spawn path sets it true.

**Likely files / seams**
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- Ticket 29’s `NoMirrorCheckManifest` / I2 block

**Dependencies**
- Ticket 16 `tmuxWindowTarget`.
- Ticket 29 I2 check block / manifest.

**Acceptance gates**
- Decode missing key → false; `true` round-trips; `null` → false.
- `restoredForBoot()` preserves true.
- Classifier checks: deliberate pair, one-sided flag, default accidental mirror.
- Manifest uses Codable-safe fields only.
- Grep confirms no production `isSharedView: true`.

**Common failure modes**
- Adding field before `tmuxWindowTarget` exists.
- Schema bump conflict with ticket 16.
- Tuple fields in Codable manifest.
- Setting flag in spawn code.
- Folding one-sided into accidental mirror.

**Effort**
- Small-medium after prerequisites.

**Blockers / conflicts**
- Stop if ticket 16 or 29 has not landed.

---

## Signals

- Tickets 21, 23, 24, 27, 29, 30 have explicit “stop if prerequisite absent” language.
- Tickets 27 and 28 overlap on `viewSessionName` / `killViewSessionCommand`; sequencing or shared ownership must be resolved to avoid duplicate definitions.
- Ticket 23 conflicts philosophically with earlier topology tickets if `tmuxWindowTarget` lives on `TerminalSessionDescriptor`; ticket text says the private record should become its permanent home and descriptor must not gain private fields.

## Risks / anti-patterns

- **Dependency inversion risk:** Several tickets describe surfaces “that do not exist yet.” Implementors must verify before coding, not stub locally.
- **Generated/check drift risk:** Many acceptance gates rely on manifests and self-check updates; missing strict measured manifests would create false “done.”
- **Naming collision risk:** `continuum-view-` helpers appear in both 27 and 28.
- **UX waiver risk:** Ticket 26 has an explicit unresolved Dylan decision.

## Suggested delegation

- Assign a project-local auditor to review topology tickets 27–30 together for duplicate helper ownership and sequencing conflicts.
- Assign a substrate auditor to verify actual availability of `TmuxControl`, `ProcessTmuxControl`, `ActivityTreeSnapshot`, and descriptor fields before implementation wave.

## Next action

Start with a dependency readiness matrix for tickets 21–30 against the current `Sources/` tree, then schedule only unblocked packets; do not hand blocked tickets to unattended implementors without prerequisite verification.

---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-e00f21/final.md -->

## Map

Read-only packetization of `docs/38-tickets/31-agentkind-closed-enum.md` through `43-replace-mock-rollup.md`.

This span forms the agent-awareness pipeline:

1. **Types/status foundation:** 31–33
2. **Detection/classification:** 34
3. **Reader protocol + concrete readers:** 35–39
4. **Observer + push/watch + attention hook:** 40–42
5. **UI consumption of observer signal:** 43

Primary invariant across the span: **I6 status soundness** — never emit `working` / `done` / `needsAttention` without fresh, specific evidence; under-claim to `idle`, `unknown`, or no badge when evidence is absent/ambiguous.

---

## Signals

### Dependency order / unattended batches

**Batch A — status/type foundation**
- `31-agentkind-closed-enum.md`
- `32-derive-agent-status-fn.md`
- `33-status-derivation-golden.md`

**Batch B — detection + reader seam**
- `34-kind-classifier-tmux.md`
- `35-agent-state-reader-protocol.md`

**Batch C — concrete readers**
- `36-pi-reader.md`
- `37-claude-reader.md`
- `38-codex-reader.md`

**Batch D — reader fixture proof**
- `39-reader-golden-fixtures.md`

**Batch E — observer + push + attention**
- `40-session-observer.md`
- `41-fsevents-push-watch.md`
- `42-claude-hook-consent.md`

**Batch F — UI rollup**
- `43-replace-mock-rollup.md`

---

## Implementor packets

### Packet 31 — `agentKind closed enum`

**Directive to preserve:** migrate `AgentDescriptor.agentKind` from free `String` to closed `AgentKind`, with graceful unknown decode and no schema bump.

**Implement:**
- Add `AgentKind` near `AgentStatus` in `TerminalSessionDescriptor.swift`.
- Cases: `shell`, `claude`, `codex`, `pi`, `managed`, `unknown`.
- Custom decode: unknown raw strings → `.unknown`.
- Update `AgentDescriptor`, `LaunchProfileSpec`, registry literals, CoreChecks, app literals.

**Critical false-positive risks:**
- Do **not** convert raw JSON fixture `"agentKind": "qa-reviewer"` in `ContinuumRevivedCoreChecks/main.swift`; it must remain invalid input to prove graceful decode.
- `TileSpawner.spawnHarnessRoleRun`: role ids like `explorer` / `code-reviewer` must map to `.pi`, not `.unknown`.
- `ContinuumApp.swift` synthetic `"qa"` fixture maps to `.unknown`.

**Checks:**
- Six-case JSON round-trip.
- Unknown raw decode → `.unknown`.
- Registry specs `.claude` / `.codex`.
- Harness role descriptor `.pi`.
- `swift build`.

---

### Packet 32 — pure status derivation

**Directive to preserve:** add pure `deriveAgentStatus(signals:)`, no I/O, no clock, no hysteresis.

**Implement:**
- `StatusSignals` in `AgentStatusEngine.swift`.
- `deriveAgentStatus(signals:)` priority ladder:
  1. pending approval
  2. pending user input
  3. fresh hook breadcrumb
  4. error → `.idle`
  5. starting
  6. running
  7. completed
  8. engine stale
  9. fallback idle

**Critical false-positive risks:**
- Hook breadcrumb must only be set by callers for Claude/hook-installed cases; otherwise `.pi` / `.unknown` can falsely become `.needsAttention`.
- No `.failed` status case.
- No `Date()` or stale recomputation in this function.
- Unknown kind with no evidence → `.idle`, not fabricated attention/done.

**Checks:**
- Table rows for every rung.
- Fresh vs stale hook breadcrumb.
- Unknown-kind idle and running.
- Real-file smoke: minimal Claude JSONL parsed to `StatusSignals` → `.working`.

---

### Packet 33 — I6 golden table

**Directive to preserve:** append exhaustive pure-derivation I6 table; do not replace existing engine-facing I6 block.

**Implement:**
- New block in `ContinuumRevivedCoreChecks/main.swift`.
- At least 19 `GoldenRow`s across A–D.
- Manifest with `via: "pure_derivation_golden_table"`.

**Critical false-positive risks:**
- `AgentStatus` has no `.unknown`; no row should expect it.
- `.stale` only comes from `engineStatus == .stale`.
- Managed rows are not stubs; they assert boolean rung behavior even before managed tier exists.
- Do not use wall-clock `Date()`.

**Checks:**
- Manifest read-back.
- `attention_beats_running_all_pass == true`.
- `fabrication_rows_all_pass == true`.
- `.build/debug/ContinuumRevivedCoreChecks` exits 0.

---

### Packet 34 — tmux kind classifier

**Directive to preserve:** classify foreground command to `AgentKind` through `TmuxControl.paneCurrentCommand`.

**Implement:**
- Add `paneCurrentCommand(paneTarget:)` to `TmuxControl`.
- Add `TmuxControlError.paneNotFound(target:)`.
- Add `KindClassifier` + `AgentKind.from(processName:)`.

**Critical false-positive risks:**
- `"node"` maps to `.unknown`, not `.codex`.
- `"login"` maps to `.unknown`, not shell.
- Shell aliases are exactly `zsh`, `bash`, `fish`, `sh`.
- Classifier must propagate pane errors, not default to `.unknown`.

**Checks:**
- Full mapping table.
- Case/whitespace normalization.
- Fake tmux live/dead pane behavior with exact error.
- Optional real tmux shell check, skip if tmux absent.

---

### Packet 35 — reader protocol + snapshot

**Directive to preserve:** define typed body-free reader contract and `AgentSnapshot`.

**Implement:**
- `AgentStateReader`.
- `AgentSnapshot` + nested `Evidence`.
- Reuse `AgentKind`; do not define twice.
- Title truncation to 80 chars.

**Critical false-positive risks:**
- Do not add body/raw JSON fields to `AgentSnapshot`.
- No `Date()` or `FileManager` calls in protocol/type file.
- `asOf` is supplied by observer/read caller, not measured by reader protocol.
- Tests must follow project harness reality; ticket mentions XCTest-style paths, but current docs elsewhere emphasize CoreChecks executable. Verify actual repo pattern before adding test target.

**Checks:**
- Snapshot Codable round-trip.
- Title truncation.
- Mirror taint field-name check.
- `AgentKind.allCases.count == 6`.
- Mock reader conformance.

---

### Packet 36 — Pi reader

**Directive to preserve:** locate Pi run by `runId`, project-local first, return I5-clean `AgentSnapshot`.

**Implement:**
- `PiAgentStateReader`.
- `detect("pi") == true`; `detect("node") == false`.
- Locate `<projectRoot>/.pi/agent-runs/<runId>` before global `~/.pi/agent-runs/<runId>`.
- Status mapping from `run.json` + `events.jsonl`.

**Critical false-positive risks:**
- Missing/unreadable `run.json` → `.idle`, `asOf == config.now`, evidence `pi:run.json:absent`; do not use `.distantPast`.
- Stale running events must not emit `.working`.
- Do not read `output.json`, `final.md`, `summary.md` for status.
- Project-local/global collision must prefer project-local.

**Checks:**
- Fixtures: done, working, stale-not-working, configuring, missing run.
- Locate priority tests.
- I5 taint across fixtures.
- Real temp run directory with done → working transition using injected `now`.

---

### Packet 37 — Claude reader

**Directive to preserve:** pid-file only for locating JSONL; status from JSONL tail + mtime age; no file-derived `needsAttention`.

**Implement:**
- `ClaudeAgentStateReader`.
- `detect("claude")`.
- `encodeCwd`: `/` and `.` → `-`, including double-dash `/.`.
- `locate(pid:)` via `~/.claude/sessions/<pid>.json` to JSONL.
- Tail-read bounded bytes, not whole file.

**Critical false-positive risks:**
- Do not emit `.needsAttention` from JSONL.
- Do not read pid file for status after locate.
- Missing pid file → `locate == nil`; observer owns done/shell fallback.
- Stale/live old JSONL → `.idle`, not `.working`.
- Use pid file `cwd`, not tmux pane cwd.

**Checks:**
- Pure derive-status table.
- `encodeCwd` table.
- Fixture scenarios: working, idle, done-locate-nil, stale, double-dash, unknown events.
- Taint check no body placeholder in snapshot.
- Round-trip snapshot.

---

### Packet 38 — Codex reader

**Directive to preserve:** locate rollout by newest mtime + exact cwd + timestamp after pane start; under-claim same-cwd ambiguity.

**Implement:**
- `CodexAgentStateReader`.
- `detect("codex")` and `detect("node")`.
- `locate(cwd:paneStartedAt:)` scans rollout files newest-first, reads only line 1.
- `read(at:processAlive:now:)` reads line 1 + bounded 50-line tail.

**Critical false-positive risks:**
- `node` detect only triggers probe; observer must not classify Codex unless locate succeeds.
- `session_index.jsonl` never used for linkage.
- Strict timestamp: rollout timestamp must be **after** pane start.
- Freshness required for `.working`; stalled function call past fresh window → `.idle`.
- Same-cwd collision handled by observer, not reader.
- No `idleWindow`; only freshWorkingWindow and staleWindow.
- Do not open `~/.codex/auth.json` or config.

**Checks:**
- Locate basic/mismatch/no-match/distantPast/equal timestamp rejection.
- Status table including stalled tool, task_started fresh/stale, stale alive/dead.
- Mode from tail only, nil when outside tail.
- Title index/fallback/truncation.
- Taint and round-trip.
- Real-path optional gated on existing `~/.codex/sessions`.

---

### Packet 39 — reader golden fixtures

**Directive to preserve:** replay redacted real stores through readers; prove reader I6 and taint.

**Implement:**
- Fixture tree under `Tests/Fixtures/agent-readers/`.
- New `// MARK: - Invariant I6: Reader status soundness` block.
- `AgentSnapshot.taintCheck()`.

**Critical false-positive risks:**
- Fixture mtimes from git checkout are unusable; set mtimes explicitly before reads.
- Claude `needsAttention` from file remains blocked.
- Codex pinned mappings must be comments with rationale, especially `turn_aborted → .idle`.
- Redaction placeholder must appear in body positions so taint check is non-vacuous.
- Ensure taint helper itself is tested with a deliberately tainted snapshot.

**Checks:**
- All non-blocked fixture scenarios.
- Manifest with scenario measurements.
- Symlink scenario for Pi latest.
- No live agent/tmux dependency.

---

### Packet 40 — SessionObserver

**Directive to preserve:** observer owns detection, reader dispatch, budgets, hysteresis integration, and status persistence via injected seams.

**Implement:**
- `SessionObserver`.
- Inject:
  - `WindowTargetLookup`
  - `StatusWriter`
  - pane command query/readers
- Per-tile `AgentStatusEngine`.
- 250 ms debounce, 10 changes/min/tile, 5 s slow detection poll.
- No tmux on FSEvents fast path.

**Critical false-positive risks:**
- Do not read `windowTarget` from `TerminalSessionDescriptor`; use runtime lookup.
- Observer must not import or own `ProjectStore`.
- Must mutate `AgentStatusEngine` in stored observation, not a copy.
- Codex no-rollout: do not attach wrong rollout; leave configuring/idle.
- Detection poll must not service reads; file changes schedule one-shot read.
- `node` with no rollout should not become `.codex`.

**Checks:**
- Budget: 15 events/60s → 10 writes.
- Debounce: rapid events collapse.
- Dispatch table: claude/pi/zsh/node-no-rollout.
- Hysteresis ownership: working→idle inside hysteresis remains working.
- Real tmux integration: JSONL append → `.working` within ~350 ms.
- Dogfood live Claude sidebar transition.

**Blocker:** supervised; requires live tmux / app dogfood.

---

### Packet 41 — FSEvents push watch

**Directive to preserve:** add event-driven local store watcher; polling remains fallback.

**Implement:**
- `AgentStoreWatcher`.
- File-level `DispatchSourceFileSystemObject` with `O_EVTONLY`.
- Wire observer watcher after successful locate.
- Remote URLs skip watcher and use poll fallback.
- RunArtifacts tile refresh subscription.

**Critical false-positive risks:**
- File descriptor is per-file; must re-arm on store URL rotation.
- Cancelled sources can fire; verify tile still active.
- Missing file at arm time: return; poll fallback covers.
- Rate cap must be enforced on FSEvents path, not assumed from poll.
- Beware ticket inconsistency: config says `maxReadsPerSecond: 10`, but D13 says 10 status changes/min/tile. Align with observer budget, not misleading name.

**Checks:**
- Debounce temp-file writes.
- Multi-file same tile.
- Unwatch stops delivery.
- Missing file no crash.
- Rate cap.
- Integration: Claude JSONL append and Pi run.json write update status within 500 ms.
- Remote path creates no DispatchSource.

---

### Packet 42 — Claude hook consent

**Directive to preserve:** consent-gated hook install writes breadcrumb for Claude attention; no consent, no hook.

**Implement:**
- `ClaudeHookInstaller`.
- `ClaudeHookConsentStore`.
- Breadcrumb path helper and parser.
- Consent prompt in app.
- Settings removal.

**Critical false-positive risks:**
- Do not install without explicit granted consent.
- Atomic write to `~/.claude/settings.json`; invalid existing JSON must be left unchanged.
- Preserve existing user hooks; uninstall only Continuum entries.
- `$CLAUDE_SESSION_ID` must remain literal in installed command.
- Breadcrumb freshness >300 s must not derive `.needsAttention`.
- Ticket currently says string `agentKind == "claude"` until enum lands, but in this packet sequence enum should have landed. Implement via helper and use enum if available.

**Checks:**
- Temp settings install/idempotency/merge/uninstall.
- Breadcrumb parse valid/missing/stale.
- End-to-end signals fresh breadcrumb + running → `.needsAttention`.
- Real dotfile opt-in with unconditional restore.
- Dogfood orange border/sidebar within debounce.

**Blocker:** supervised; NSAlert + live visual gate required.

---

### Packet 43 — replace mock rollup

**Directive to preserve:** canvas zone chrome and tile badges consume observer `[UUID: AgentStatus]`, not hardcoded rollup.

**Implement:**
- Observer subscription near canvas owner.
- `applyObserverStatuses(_:)`.
- Clear badges for absent tiles.
- `configuring` / `idle` show no tile badge and no canvas rollup bucket.
- Bridge `SidebarAgentStatusRollup` → `CanvasNSView.AgentStatusRollup`, dropping `unknown`.
- Cancel subscription on canvas replacement.

**Critical false-positive risks:**
- Do not leave hardcoded production `AgentStatusRollup(working: 1, needsAttention: 1, ...)`.
- Do not set absent plain shell tiles to `.stale`; set nil badge.
- Do not recompute rollup from disk on every zone render rebuild after observer is live.
- Tile-zone map must be fresh; use `WorkspaceDocument.groupZoneTiles` now, not future membership register.
- Subscription teardown is required to avoid stale canvas mutation.

**Checks:**
- Pure rollup bridge including `.configuring`/`.idle`.
- Badge helper table.
- Dominant kind attention beats working.
- Subscription teardown logic.
- Backend self-check: call `applyObserverStatuses`, read back `TileNSView` status and zone chrome text.
- Component Lab live-feed simulation.
- Dogfood real app: live Claude badge/zone header.

**Blocker:** supervised; visual/live observer verification required.

---

## Risks / anti-patterns

1. **Conflicting test harness assumptions**
   - Some tickets mention XCTest / `Tests/...`; others insist current repo uses executable CoreChecks and no test target.
   - Before implementation, inspect `Package.swift` and existing harness. Do not invent a test target if repo convention is CoreChecks.

2. **Protocol drift across reader tickets**
   - Ticket 35 protocol shape differs from later pseudo-code in 36–39 (`read(storeURL:asOf:)` vs `read(locator:)`, `locate(pid:cwd:runId:)` vs Codex-specific `locate(cwd:paneStartedAt:)`).
   - Implementor must reconcile via the actual protocol landed in Packet 35 before starting concrete readers.

3. **Duplicate `AgentKind` danger**
   - Packets 31, 32, 35 all discuss defining `AgentKind` if absent.
   - Once Packet 31 lands, every later packet must reuse it.

4. **False-positive `needsAttention` is the highest trust risk**
   - Only valid sources in this span:
     - managed pending booleans in pure table,
     - fresh Claude hook breadcrumb after consent,
     - Pi overnight needs-human fixture if implemented.
   - Claude/Codex file readers must not invent attention.

5. **`node` ambiguity split across classifier/reader/observer**
   - Classifier packet says `"node" → .unknown`.
   - Codex reader says `detect("node") == true` for probe.
   - Observer must handle this carefully: node is only upgraded to Codex if locate succeeds.

6. **Mtime false positives**
   - Reader status relies on file mtime; fixture tests must set mtimes explicitly.
   - Git checkout mtimes will make stale fixtures appear fresh.

7. **Observer can silently fail if seams are bypassed**
   - Reading window target from wrong model, persisting directly in observer, or mutating engine copies can all produce “looks wired” false positives with no real status integrity.

---

## Suggested delegation

- **Project auditor:** review final Packet 35 protocol against Packets 36–40 for signature consistency before concrete reader implementation.
- **I6/status auditor:** inspect Packets 32, 33, 39, 40, 42 for any path that can emit `.needsAttention` or `.working` without fresh evidence.
- **UI reviewer:** after Packet 43, verify no hardcoded production rollup remains and observer subscription teardown is correct.

---

## Next action

Start unattended work with **Packet 31 only**. It is the lowest-risk foundation and removes the biggest downstream ambiguity: `AgentKind` duplication and string/enum drift.

---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-5d9e20/final.md -->

## Map

Read-only packetization of `docs/38-tickets/44-feed-sidebar-tree.md` through `54-bootstrap-auth-every-path.md`. Original directives preserved by reference; these packets are supplements only.

## Global rules for implementors

- Worktree: `/Users/dylan/Documents/personal/continuum-overnight`
- One ticket per agent. Do not batch.
- Preserve the original ticket as the source of truth.
- Record commands, manifests, and artifact paths.
- Prefer executable `*Checks` / existing matrix conventions over unwired XCTest.
- Do not fake supervised/needs-substrate gates; report them as pending if not run.

---

# Autonomous packets

## 48 — Host / RemoteReach model

**Mode:** Autonomous  
**Packet:** Implement the pure remote reach model and argv construction base.

**Core contract:**
- Add `RemoteReach`, `SSHTarget`, `RemoteEnvironment`, `RemoteReachConfig`.
- Add `Project.remoteEnvironment: RemoteEnvironment?`, schema v2, decode v1 safely.
- Extend `TmuxSession.wrap(profile:tileId:tmuxPath:reach:defaults:)`.
- Wire `TileSpawner` to pass `project.remoteEnvironment?.reach ?? .localhost`.
- `.localhost` unchanged; `.sshForward` and `.tailscale` ssh-wrap; `.tunnel` fatal.

**Likely files:**
- `Sources/ContinuumRevivedCore/RemoteReach.swift`
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevivedCore/Project.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`

**Acceptance gates:**
- Codable round-trips, v1 project decode, config defaults/overrides.
- argv shape for localhost / sshForward / tailscale.
- shell escaping test.
- tunnel fatal-error captured in subprocess/available harness.
- `swift build` + relevant checks.

**Blockers:** depends on prior project-session naming / injectable substrate assumptions, but is otherwise self-contained.

---

## 54 — Bootstrap auth every path

**Mode:** Autonomous  
**Packet:** Add auth primitives and checks, no localhost bypass.

**Core contract:**
- Add `Scope` OptionSet with `.observer` and `.admin`.
- Add in-memory `BootstrapGrant`.
- Add GRDB-backed `PairingStore` with atomic single-use consume.
- Add `SessionStore` with HMAC-signed bearer tokens and constant-time verify.
- Add `ControlMessage` required-scope table and authorization.
- Wire launch bootstrap enough to prove local admin session path.

**Likely files:**
- `Sources/ContinuumRevivedCore/Auth/Scope.swift`
- `Sources/ContinuumRevivedCore/Auth/BootstrapGrant.swift`
- `Sources/ContinuumRevivedCore/Auth/PairingStore.swift`
- `Sources/ContinuumRevivedCore/Auth/SessionStore.swift`
- `Sources/ContinuumRevivedCore/Auth/AuthError.swift`
- `Sources/ContinuumRevivedCore/Auth/MessageScope.swift`
- Core checks / real-path auth check harness

**Acceptance gates:**
- Scope subset enforcement.
- Bootstrap unbounded re-exchange.
- Pairing unknown/expired/already-used/revoked all tested.
- Session invalid HMAC / expired / revoked tested.
- Manifest records measured values, no `{passed:true}`.
- No `if localhost skipAuth` equivalent.

**Blockers:** GRDB dependency must be present or added. Needs careful signing-key permissions (`0600`).

---

# Supervised packets

## 44 — Feed sidebar tree from observer

**Mode:** Supervised  
**Packet:** Wire live `SessionObserver` status snapshots into sidebar tree.

**Core contract:**
- Add private `observedAgentStatuses: [UUID: AgentStatus] = [:]` to `AppDelegate`.
- Subscribe to observer status emission on observer install.
- Dispatch callback to main, store snapshot, reload sidebar.
- Clear snapshot on observer teardown and reload once.
- Merge observer statuses over cold-start `workspaceSidebarAgentStatuses`.

**Likely files:**
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `ComponentLab.swift` only for visual fixture if not already covered

**Acceptance gates:**
- Core builder status-carry checks.
- Extended `--workspace-sidebar-live-status-check` with observer override + clear fallback.
- Manifest includes measured values.
- ComponentLab non-blank observer-fed sidebar.
- Human dogfood: glyph/color transition visible within ~1s.

**Blockers:** Requires landed `SessionObserver` with `[UUID: AgentStatus]` emission. If no observer handle/API exists, do not stub; report blocked.

---

## 45 — Render left dock

**Mode:** Supervised  
**Packet:** Add the missing default-visible real-path check and richer Lab card.

**Core contract:**
- Do not reimplement existing sidebar machinery.
- Add `--workspace-sidebar-default-visible-check`.
- Drive real `makeWorkspaceContentView`, not standalone `WorkspaceSidebarView`.
- Add second Lab card `chrome.sidebar.live` with richer two-workspace fixture.

**Likely files:**
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/ComponentLab.swift`

**Acceptance gates:**
- New check manifest: default visible true, hidden false, width/divider > 0, rows >= 1.
- Existing shell/actions/live-status checks stay green.
- ComponentLab card renders.
- Human dogfood: dock visible on fresh launch, toggle/persist/click behavior.

**Blockers:** None if existing sidebar machinery remains as described.

---

## 46 — Dock toggle keybind & width persistence

**Mode:** Supervised  
**Packet:** Add `⌘⇧S` shortcut, catalog/settings entries, and stronger persistence checks.

**Core contract:**
- Menu item uses `keyEquivalent: "S"` and `[.command, .shift]`.
- Add `global.toggleWorkspaceSidebar` to `ShortcutCatalog`.
- Add Settings Activity section for visibility + width.
- Extend conflict/config/schema checks.
- Extend real-path toggle/persistence manifest.

**Likely files:**
- `Sources/ContinuumRevivedCore/ShortcutCatalog.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`

**Acceptance gates:**
- Conflict audit covers `⌘⇧S`.
- Settings section exists.
- Width clamp round-trip checks.
- Backend check records visible/hidden/position/width measured values.
- Human dogfood: shortcut, drag persistence, Settings effects.

**Blockers:** Dock render should exist first.

---

## 47 — Jump-to-tile via sidebar row click

**Mode:** Supervised  
**Packet:** Strengthen existing sidebar-actions check and add selected-state Lab proof.

**Core contract:**
- Do not rewrite navigation resolver.
- Add viewport equality assertion after tile-row click.
- Add same assertion for cross-workspace tile click.
- Add named Lab fixture IDs and selected sidebar card.
- ComponentLab gate must prove color delta, not just non-blank.

**Likely files:**
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/ComponentLab.swift`

**Acceptance gates:**
- `--workspace-sidebar-actions-check` compares expected/measured tile viewports.
- Manifest records coordinate/zoom dictionaries.
- New `chrome.sidebar.selected` card registered.
- `runSelfCheck` records selected/unselected color counts and positive delta.
- Human dogfood: click pans canvas, focus border appears, row remains highlighted.

**Blockers:** Left dock rendered and populated.

---

## 49 — sshForward attach wrap

**Mode:** Supervised  
**Packet:** Implement real ssh attach argv + ssh-G resolution and run VPS dogfood.

**Core contract:**
- Extend/align `TmuxSession.wrap` with `.sshForward`.
- Add `resolveSSHTarget(alias:)` via `ssh -G` with timeout/fallback.
- Remote argv includes `-t`, keepalive/connect flags, no `-L`/`-N`.
- Remote tmux command uses remote `"tmux"`, not local absolute path.
- Tailscale folds into same branch if model exists.

**Likely files:**
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevivedCore/SSHHostResolver.swift` or equivalent
- Core checks

**Acceptance gates:**
- Pure argv/quoting/parse/fallback checks.
- `ssh -G localhost` and temp-config alias tests.
- No `-L`/`-N` permanent assertion.
- Human dogfood against real remote with tmux installed.

**Blockers:** Requires 48 (`RemoteReach`, `SSHTarget`) first.

**Conflict warning:** 49 overlaps heavily with 48. Reconcile before implementing: 48 specifies `RemoteReachConfig` and `defaults:` on `wrap`; 49 separately proposes resolver/helpers and has different `BatchMode` defaults. Prefer one canonical design before assigning.

---

# Needs-substrate packets

## 50 — Remote attach real path

**Mode:** Needs-substrate  
**Packet:** Add gated real SSH/tmux check and stale-on-drop proof.

**Core contract:**
- Gated by `CONTINUUM_REMOTE_CHECK_HOST`.
- Skip cleanly when unset.
- Resolve host via `ssh -G`.
- Spawn wrapped ssh/tmux attach.
- Assert remote session alive + window id.
- Kill local ssh process, wait real stale window, assert `.stale`.
- Confirm remote tmux session survives, then cleanup.

**Likely files:**
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `Sources/ContinuumRevivedCore/SSHHostResolver.swift`
- `Sources/ContinuumRevivedCore/SSHConstants.swift` if not already present

**Acceptance gates:**
- Logic sub-checks run without env: argv, resolver parse, stale derivation.
- With env: real remote session, window id `@…`, stale-on-drop, cleanup.
- `swift build` + checks.

**Blockers:** Requires 48/49, status derivation, injectable clock/substrate assumptions. Needs real SSH host with key auth and remote tmux.

---

## 51 — Observer over SSH

**Mode:** Needs-substrate  
**Packet:** Add remote store reader and observer polling for sshForward tiles.

**Core contract:**
- Add `RemoteStoreReader` with injected `remoteCat`, `remoteDisplay`, tail bytes, poll budget.
- Remote tiles use polling, not FSEvents.
- Enforce 5s floor at timer setup.
- Read remote agent stores and feed existing readers.
- After 3 consecutive failures, transition `.stale`.
- Reset failure count on success.
- Offset-track tails for Claude/Codex.

**Likely files:**
- `Sources/ContinuumRevivedCore/RemoteStoreReader.swift`
- `SessionObserver` file from observer ticket
- Reader protocol extensions if `readFromBytes` not present

**Acceptance gates:**
- Pure tests for 5s floor, stale-after-3-failures, byte-offset tracking.
- Gated integration with `CONTINUUM_TEST_SSH_HOST`.
- Dogfood remote Claude status transition within 10s.

**Blockers:** Requires landed `SessionObserver` with budgets, 48/49/50, reader protocols, real SSH host/agent store.

---

## 52 — SSH reconnect degradation

**Mode:** Needs-substrate  
**Packet:** Add connection supervisor, stale pause/resume, backoff, and reconnect UX.

**Core contract:**
- Add pure Core `ConnectionSupervisor` actor.
- Backoff `[1,2,4,8,16]`, stability reset 30s, establish/probe timeouts.
- Two-gate connected rule: ssh open + readiness probe.
- On drop: mark stale immediately, pause observer, cancel in-flight reads.
- On recovery: resume observer and derive fresh status.
- Add remote connection states Lab fixture.

**Likely files:**
- `Sources/ContinuumRevivedCore/ConnectionSupervisor.swift`
- `Sources/ContinuumRevivedCore/RemoteReachConfig.swift` / `ReconnectConfig`
- `Sources/ContinuumRevivedCore/TmuxSession.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`

**Acceptance gates:**
- Pure fake-driver checks for backoff, blocked, offline, probe timeout, generation, immediate stale.
- Real SSH loopback/VPS checks for keepalive drop/reconnect.
- ComponentLab connection-state fixture.
- Dogfood firewall-drop scenario.

**Blockers:** Requires 50/51-level remote substrate and observer pause/resume API. Needs controllable SSH daemon/VPS.

---

## 53 — Tailscale discovery

**Mode:** Needs-substrate  
**Packet:** Add Tailscale peer discovery actor and reach-menu integration.

**Core contract:**
- Add `TailscaleDiscovery` actor.
- Spawn `tailscale status --json` only on menu demand, never launch.
- 1.5s timeout, 60s cache.
- Resolve binary from App Store path + `$PATH`.
- Parse online CGNAT peers, strip MagicDNS trailing dot.
- Return `SSHTarget`s and menu wraps them as `.tailscale`.
- Do not touch `TmuxSession.wrap` except to confirm tailscale already shares sshForward branch.

**Likely files:**
- `Sources/ContinuumRevivedCore/TailscaleDiscovery.swift`
- Reach-path menu / HostReachProvider app-layer call site
- Core tests/checks for parsing

**Acceptance gates:**
- Boundary tests for `100.64.0.0/10`.
- Fixture parsing tests, offline peers filtered.
- No installed binary → empty array, no user-visible error.
- Real tailnet integration: non-empty peers, cache hit under 5ms.
- Dogfood menu section and attach through discovered peer.

**Blockers:** Requires 48/49 and actual Tailscale install + tailnet peer for full verification.

---

# Blockers / anti-patterns to resolve before dispatch

## Major overlap: tickets 48, 49, 50, 52 all modify SSH wrapping

There are competing designs:
- 48: `TmuxSession.wrap(... reach:defaults:)`, `RemoteReachConfig`, no ssh-G resolution yet.
- 49: adds `resolveSSHTarget`, `sshExecutablePath`, hardcoded-ish flags, `BatchMode=yes`.
- 50: proposes `SSHConstants`, `SSHHostResolver`, separate overload.
- 52: proposes `TmuxSession.remoteWrap`.

**Risk:** parallel agents will create duplicate helpers and incompatible signatures.

**Recommendation:** Dispatch 48 first. Then reconcile 49/50/52 into the landed API before assigning implementation agents.

## Substrate blockers

- 44 needs real `SessionObserver` emission API.
- 50 needs reachable SSH host + tmux.
- 51 needs remote host + agent store fixtures and reader byte APIs.
- 52 needs observer pause/resume and controllable SSH failure.
- 53 needs Tailscale installed/enrolled.

## Suggested delegation

- Assign a **remote-API auditor** after 48 lands to reconcile `TmuxSession.wrap`, `SSHHostResolver`, `RemoteReachConfig`, `SSHConstants`, and `remoteWrap` before 49/50/52 proceed.
- Assign a **sidebar auditor** to verify 44–47 do not duplicate existing checks or Lab entries.

## Next action

Start with **48 (RemoteReach model)** and **54 (Auth)** as autonomous packets. Hold 49–53 until 48’s exact remote API is landed and audited.

---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-5858b0/final.md -->

## Map

Read-only scout in `/Users/dylan/Documents/personal/continuum-overnight`. I inspected `docs/38-tickets/55-synctransport-seam.md` through `65-notify-categories-setting.md`, plus `README.md` and runbook context. No files edited.

Phase 6 splits into:

| Ticket | Mode in doc / queue | Unattended status |
|---|---:|---|
| 55 SyncTransport seam | Autonomous / in README queue | **Runnable unattended** |
| 56 Transport fuzz & soak | Autonomous / in README queue | **Runnable unattended** after 55 |
| 57 CloudKit transport | Needs-substrate / not in queue | **Block unattended verification** |
| 58 Activity projection transport | Autonomous / in README queue | **Runnable unattended** if seam/types exist |
| 59 Scope OptionSet | Autonomous / in README queue | **Runnable unattended** |
| 60 Pairing token | Supervised / not in queue | **Partial only; Keychain/app entitlement + URL visual gate block completion** |
| 61 iOS observer app | Needs-substrate / not in queue | **Block unattended completion** |
| 62 iOS approve action | Needs-substrate / not in queue | **Block unattended completion** |
| 63 APNS push service | Needs-substrate / not in queue | **Block unattended completion** |
| 64 Deep-link validation | Needs-substrate / not in queue | **Logic-only unattended; end-to-end blocked** |
| 65 Notify categories setting | Supervised / not in queue | **Logic backend unattended; UI visual gate blocks completion** |

## Implementor packets

### Packet A — Unattended Core sync seam
**Tickets:** `55-synctransport-seam.md`, then `56-transport-fuzz-soak.md`  
**Can run unattended:** yes. Both explicitly require no CloudKit, real network, iOS device, or human visual gate (`55` lines 256–260; `56` lines 342–346).  
**Constraints to preserve:**
- Use seeded deterministic fake transport, explicit logical `tick()`, no wall-clock assumptions.
- No real CloudKit/network in tests.
- Manifest must record measured values, not just pass/fail: throughput, hold-queue footprint, reconnect drain ticks (`55` around lines 254–258).
**Blockers / risks:**
- Ticket docs disagree on protocol shape: `55` breadcrumbs use `send(_ message: SyncMessage)`, `inbound: AsyncStream`; `56` references `push`, `subscribe`, `TransportMode`. Implementer must reconcile to actual landed seam, not invent a second fake.

### Packet B — Unattended projection/auth vocabulary
**Tickets:** `58-activity-projection-transport.md`, `59-scope-optionset-model.md`  
**Can run unattended:** yes per docs and README queue.  
**Constraints to preserve:**
- Projection is snapshot-then-tail, gap detection + replay, fake transport only.
- I5 purity: no pid, tmux target, transcripts/body leaks across activity stream.
- `Scope` is pure Swift OptionSet; missing required-scope entries hard-fail.
**Blockers / risks:**
- Scope naming drift: `58` mentions `.observe`; `59` defines `.observer` bundle containing `.orchestrationRead`.
- Transport naming drift: `58` cites `SyncTransportProtocol`, `FakeTransport`, channel APIs; `55` defines `SyncTransport`, `FakeSyncTransport`, `SyncMessage`.
- Implementer should first inspect landed types and adapt packet to real symbols.

### Packet C — CloudKit substrate packet
**Ticket:** `57-cloudkit-transport-impl.md`  
**Can run unattended:** **not to completion**. Logic can be authored/compiled; backend/UX gates require provisioned CloudKit container, signed app entitlements, iCloud account (`57` lines 397–404).  
**Constraints:**
- Private database only; no CKShare/public/shared DB.
- Container `iCloud.io.bannockburn.continuum`.
- Entitlements must be real and signed.
- Tests must not instantiate real CloudKit; use fake seam.
**Blockers:**
- Apple Developer portal container + app entitlement.
- Signed build under Dylan’s team.
- iCloud account on test device/Mac.
- Silent push subscription cannot be proven headless.

### Packet D — Pairing/session auth packet
**Ticket:** `60-pairing-token-model.md`  
**Can run unattended:** partial only; doc marks **Supervised** (`60` lines 251–253).  
**Unattended slice:**
- Credential generation, HMAC sign/verify, atomic consume, down-scope checks, URL parsing can be logic-tested.
**Blocked gates:**
- macOS Keychain integration in real app process/entitlements.
- One-look URL fragment visual/dogfood check.
**Risks:**
- Uses GRDB/SQLite and CommonCrypto/Keychain; verify package already has dependencies before implementation.
- Potential conflict with `59`’s `AuthError` name; avoid duplicate incompatible `AuthError` definitions.

### Packet E — iOS observer / approval / deep-link packet
**Tickets:** `61`, `62`, `64`  
**Can run unattended:** no, except model/UI fake-data and pure parsing tests.  
**Blocked substrate:**
- iOS target/simulator or device.
- CloudKit subscription carrying live activity projection (`61` lines 221–223).
- Real APNS push + managed agent approval for tap-through (`62` lines 264–273; `64` lines 280–289).
**Risks / conflicts:**
- `61` says “no pairing needed for observation leg” via iCloud identity, but also depends on `.observe`/pairing model. Needs owner decision.
- `62` breadcrumb checks `.agentControl`, but `59` scope table has no `.agentControl`; it maps `respondToApproval` to `.orchestrationRead`. Must resolve before implementation.

### Packet F — APNS + notification preferences packet
**Tickets:** `63`, `65`  
**Can run unattended:** partial.  
- `63` is needs-substrate: fake HTTP/JWT/request-shape tests can run, but real APNS delivery needs `.p8`, Apple account, physical/simulator device (`63` lines 334–338).
- `65` is supervised: fake `UserDefaults` logic can run, but Settings UI visual gate blocks completion (`65` lines 251–255).
**Constraints:**
- APNS payload metadata only; no transcript/tool/body leakage.
- Deduplicate by state identity excluding `updatedAt`.
- Four preferences default true and gate push send site.

## Risks / anti-patterns

- **Competing seam definitions:** `55`, `56`, `58`, and `57` refer to different module paths and APIs for sync transport (`ContinuumRevivedSync` vs `ContinuumRevivedCore/Substrates`, `send/inbound` vs `push/subscribe/channels`). This is the largest unattended implementation risk.
- **Scope vocabulary drift:** `.observer`, `.observe`, `.agentControl`, `.approveActions`, and `.orchestrationRead` are used inconsistently across tickets.
- **CloudKit/iOS/APNS cannot be “green” headless:** Tickets `57`, `61`, `62`, `63`, `64` need explicit skipped/substrate handoff rather than fake-green.
- **Supervised UI gates:** `60` and `65` include logic that can be checked, but their done criteria include human/app-process validation.

## Suggested delegation

- Send `55/56/58` to a code-audit specialist first to reconcile the actual landed `SyncTransport` symbols before implementation.
- Send `57/61/62/63/64` to a substrate-readiness reviewer to produce a concrete manual checklist: Apple Developer setup, entitlements, iCloud account, APNS `.p8`, simulator/device, managed-agent fixture.

## Next action

Run unattended only on `55 → 56 → 58 → 59` after verifying dependencies landed; mark `57`, `60–65` as substrate/supervised packets with explicit blockers instead of adding them to the overnight autonomous queue.

---

<!-- Source: ../.pi/agent-runs/explorer-20260702T021755Z-046526/final.md -->

## Map

Read-only packetization of `docs/38-tickets/66-connection-supervisor.md` through `74-agent-message-bus-seam.md`.

Overall sequence:

1. **66 ConnectionSupervisor** — substrate/control-channel reconnect owner.
2. **67 AgentAdapter protocol** — managed-agent runtime/event seam.
3. **68 Node sidecar bundling** — signed Node SEA substrate for TS drivers.
4. **69 ACP driver** — first real managed adapter over sidecar.
5. **70 Approvals → needsAttention** — data/status path for managed approvals.
6. **71 ManagedAgent tile/transcript** — visual managed tile consuming events.
7. **72 Approval dock/border** — visual approval affordance and attention ring.
8. **73 Waiting-for-input card** — sibling user-input affordance.
9. **74 Agent message bus seam** — future app-level structured bus, null impl only.

## Signals

### Substrate vs autonomous boundaries

| Ticket | Mode from doc | Packetization |
|---|---:|---|
| 66 | Autonomous | Safe for unattended implementor if dependencies exist. Fake driver/clock required. |
| 67 | Autonomous | Good first managed-tier packet. Pure Core types/tests. |
| 68 | Needs-substrate | **Do not assign unattended as “complete”** unless cert/notary/VPS substrate available. Split logic resolver from signing/notary. |
| 69 | Needs-substrate | Logic can be unattended; real ACP + UX cannot. Requires 67 + 68. |
| 70 | Autonomous | Good unattended data/status packet after 67/69 seam exists; real ACP dependency can be faked in-process. |
| 71 | Supervised | UI/card layout requires human visual pass; model/check parts can be unattended. |
| 72 | Supervised | Orange dock/border animation/design requires human pass. |
| 73 | Supervised | Field focus/layout/animation requires human pass. |
| 74 | Autonomous | Small seam packet, but has type/API risks below. |

## Implementor packets / blockers

### Packet A — Connection substrate supervisor
**Ticket:** `66-connection-supervisor.md`  
**Assign to:** autonomous implementor.  
**Directive:** Implement only supervisor/cache/session seam; do not alter `ProjectStore.swift`.  
**Core blockers:**
- Needs `SyncTransport.connectionState`, `Scope`, fake clock/process substrates.
- Stop if `RemoteSession` shape requires modifying `SyncTransport`.
**High-risk checks:**
- Connected only after socket open **and** `tmux list-sessions -F` readiness/topology probe.
- Scope rejection before `publishSession`.
- Fake socket must explicitly fire `closed`.
- Snapshot debounce must use injected fake clock in logic tests.

### Packet B — Managed protocol seam
**Ticket:** `67-agent-adapter-protocol.md`  
**Assign to:** autonomous implementor before 69/70/71.  
**Directive:** Define canonical adapter/event vocabulary in Core and tests.  
**Blockers/conflicts:**
- Conflicts with ticket 71, which also defines `AgentRuntimeEvent` in a different file with different shape.
- Resolve by treating **67 as canonical** for event/protocol definitions; 71 should consume, not redefine.
**Risk:** Body-carrying cases must be marked and excluded from sync/projection.

### Packet C — Node sidecar resolver vs signing split
**Ticket:** `68-node-sidecar-bundling.md`  
**Assign to:** two sub-packets:
1. **Autonomous:** `AgentAdapterRegistry` + locator tests + script skeleton.
2. **Substrate/manual:** codesign/notary/Gatekeeper/VPS smoke.
**Blockers:**
- Developer ID cert, notary credentials, Apple service, VPS access.
**Risk:** Do not let unattended agent claim full done without signing/notary evidence.

### Packet D — ACP driver logic shell
**Ticket:** `69-acp-driver.md`  
**Assign to:** unattended only for bridge enums, frame-to-event mapping, process lifecycle with fake spawner, I5 projection tests.  
**Blockers:**
- Requires 67 canonical protocol.
- Requires 68 sidecar binary for real path.
- Live `agent acp` auth/network is substrate.
**Risks:**
- Orphaned Node process on timeout/cancel.
- `contentDelta` must never enter synced projection.
- Request IDs/types must match 67/70.

### Packet E — Approval data/status path
**Ticket:** `70-approvals-needsattention.md`  
**Assign to:** autonomous after 67.  
**Directive:** Pending approval store, `respondToApproval`, status derivation integration.  
**Blockers/conflicts:**
- `ApprovalDecision` is also defined in 67 and 72 with differing cases:
  - 67: `approve`, `approveForSession`, `decline`
  - 70/72: `accept`, `acceptForSession`, `decline`, `cancel`
- Must choose one canonical enum before implementation. Prefer adapter-facing naming from 67 or explicitly map UI/store decisions to adapter decisions.
**Risk:** Store mutations must be serialized on controller actor/queue.

### Packet F — Managed tile model before AppKit
**Ticket:** `71-managed-tile-kind-transcript.md`  
**Assign to:** split:
1. **Autonomous:** transcript model, `TileKind.managedAgent` switch audit, Component Lab entry presence/nonblank.
2. **Supervised:** visual card layout/dogfood.
**Blockers/conflicts:**
- Do **not** redefine `AgentRuntimeEvent` if 67 exists.
- 71 says event type is “not Codable”; 67 requires `Codable`. Resolve before coding.
**Risk:** `contentDelta` and transcript bodies are local-only.

### Packet G — Approval dock + attention border
**Ticket:** `72-approval-dock-border.md`  
**Assign to:** supervised UI implementor; autonomous can prebuild logic/backend checks.  
**Blockers:**
- Requires 70 pending approval store.
- Requires 71 managed tile view.
**Risks:**
- Multiple attention tiles require one overlay per tile, not reuse of single focus overlay.
- Sanitization must happen at ingestion, not display.
- Dock must call canonical `respondToApproval`.

### Packet H — User input card
**Ticket:** `73-waiting-for-input-card.md`  
**Assign to:** supervised UI implementor after 71/72.  
**Blockers:**
- Requires managed tile event sink and attention border.
- Requires canonical `respondToUserInput` from 67 adapter protocol.
**Risks:**
- Pending approval and pending user input must coexist.
- Do not steal keyboard focus unless tile is focused.
- User answer must not cross sync/projection boundary.

### Packet I — Message bus seam
**Ticket:** `74-agent-message-bus-seam.md`  
**Assign to:** autonomous, but after Core compile surface is stable.  
**Blockers/risks:**
- `AgentBusMessage` tests require `Codable`/`Equatable`, but breadcrumbs only say `Sendable`.
- Uses `AnyCancellable`/Combine in Core; verify Core target can import Combine.
- `.progressNote(text:)` and `.delegateTask(description:)` are body-like strings; if I5 applies broadly, document as local-only and never sync.
- `ingestBusMessage` ignores tile matching despite doc saying “matching this engine’s tile”; needs engine tile identity or doc correction.

## Cross-ticket risks / anti-patterns

1. **Duplicate canonical types**
   - `AgentRuntimeEvent`: tickets 67 and 71 disagree on file, cases, `threadId`, and `Codable`.
   - `ApprovalDecision`: tickets 67, 70, 72 disagree on case names and `cancel`.
   - `ApprovalRequestKind`: tickets 70/72 overlap.
   **Recommendation:** implement a single Core vocabulary packet first, then update downstream tickets to consume it.

2. **Request ID type mismatch**
   - 67 uses `requestId: String`.
   - 70/72/73 use `UUID`.
   **Recommendation:** choose boundary rule: adapter/provider IDs are strings; app-local pending rows may wrap/map them to UUID only if mapping is explicit. Avoid silent conversion.

3. **Body/I5 boundary pressure**
   - 67/69/71/73 carry content deltas, questions, details, error messages.
   - 74 introduces message payload strings.
   **Recommendation:** require a shared taint/projection audit before any sync/activity projection integration.

4. **Substrate claims**
   - 68 and 69 cannot be fully verified unattended.
   **Recommendation:** mark their packets “partial autonomous” unless cert/notary/live ACP evidence is attached.

## Suggested delegation

- **Core API auditor:** Review 67/70/71/72/73 for one canonical event/approval/user-input type set before implementation.
- **Build/signing specialist:** Own 68 substrate path separately from logic.
- **UI reviewer:** Supervise 71–73 Component Lab/dogfood visual gates.
- **I5 taint auditor:** Inspect managed event projection paths after 67/69/70/71/73 land.

## Next action

Before coding tickets 67–73, create a one-page **managed-tier canonical types decision** resolving:
`AgentRuntimeEvent` location/shape/Codable, `requestId` type, `ApprovalDecision` cases, and local-only/body-carrying payload rules.
