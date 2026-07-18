# 85 — Phone live-state truth + managed agent launch UX

## Goal
Make the paired iPhone show *real desktop agent state* instead of a false "Live" empty board, and turn the Mac's default agent-launch UX into the managed-agent experience rather than a plain shell tile running a CLI by default.

This ticket is intentionally a plan ticket: it documents the current architecture, the target product shape, and the implementation split. The first implementation should land the live-state truth/publish fixes before changing the agent launch UX, so dogfood can distinguish transport problems from product-surface debt.

## Implementation status

Landed in the first implementation slice:

- iOS activity/spatial receivers no longer emit local empty bootstrap snapshots to subscribers before a remote desktop item arrives.
- Real remote empty desktop snapshots still propagate, so `Live + no agents observed` remains possible after the Mac actually publishes an empty desktop.
- Successful LAN pairing fires a post-pair hook on the Mac and schedules a companion publish.
- Observed-terminal agent status writes schedule a debounced companion publish.
- Mac companion sync logs now include registered observed-agent, live observed-agent, and managed-agent session counts.
- iOS Settings now shows pairing/transport/freshness diagnostics, including whether current live state is remote-backed and the latest remote activity/spatial watermarks.

Also landed in the second implementation slice:

- Cmd-K has a `New Agent…` action that spawns a `.managedAgent` tile instead of a terminal tile.
- Raw Claude/Codex launch profiles are relabeled as explicit `Claude CLI Terminal` / `Codex CLI Terminal` fallbacks.
- Managed-agent tile spawn persists a local `ManagedAgentSessionRecord` without tmux/runtime payload and schedules a companion publish.
- Desktop activity snapshots can include sanitized managed-agent status rows without transcript text, paths, pane ids, pids, or runtime payloads.
- Tmux lazy-recovery skips provider-managed records so focusing a managed tile does not try to resurrect a tmux pane.

Still pending from this plan:

- Real provider adapter wiring for `New Agent…` beyond the initial managed tile shell.
- Managed runtime event persistence/replay and publish-on-event updates after adapter wiring lands.

## Original facts from the codebase

These were the facts at planning time; the implementation-status section above records which parts have since landed.

### Phone "Live" could be synthetic

Relevant files:

- `ios/Continuum/Sources/ContinuumApp.swift`
  - `AgentsBoardModel.start()` creates `CloudKitSyncTransport`, `SyncMessageDemux`, `ActivityProjectionReceiver`, and `SpatialOpReceiver` after a paired session is loaded.
  - `AgentsBoardModel.consume(_:)` sets `state = .live` and creates a synthetic freshness sample for every consumed activity item.
- `Sources/ContinuumRevivedSync/ActivityProjectionReceiver.swift`
  - `subscribe()` immediately yields the receiver's current local `ActivityLogSnapshot`, which starts as `.empty`.
- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift`
  - `ActivityLogSnapshot.empty` has `snapshotSequence == 0`, zero replica id, and no tile activity.

Consequence: after pairing, the phone could consume the receiver's initial local empty snapshot and show freshness as `Live` even if no Mac-published CloudKit activity snapshot had arrived.

### Desktop publishing was not live-continuous

Relevant files:

- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - `startDesktopCompanionSyncService()` starts/fetches/publishes at app startup.
  - Debug menu has manual `Companion Sync > Publish Now` and `Fetch Now`.
  - `ensureDesktopCompanionSyncService()` builds the activity snapshot through `DegradedDesktopActivitySnapshotSource.snapshot(...)` from session descriptors and observed statuses.
- `Sources/ContinuumRevivedSync/DesktopCompanionSyncService.swift`
  - `publishCurrentDesktopSnapshot(reason:)` writes spatial + activity snapshots and then logs freshness through `DesktopCompanionLogFreshnessPublisher`.

Consequence: the phone could be paired and CloudKit-capable, but the Mac might not publish a fresh snapshot when pairing completed or when `SessionObserver` detected an agent status change.

### Cmd-K agent rows were terminal-backed CLI profiles

Relevant files:

- `Sources/ContinuumRevivedCore/LaunchProfileRegistry.swift`
  - Built-ins include `claude` and `codex` as `.tool(...)` profiles with display names `New Claude Agent` and `New Codex Agent`.
- `Sources/ContinuumRevived/App/TileSpawner.swift`
  - `spawnTerminal(profileId:)` always creates a `.terminal` tile.
  - Agent profiles receive an `AgentDescriptor.configuring(agentKind: ...)` descriptor, then run through tmux/Ghostty.
- `Sources/ContinuumRevived/App/SessionObserver.swift`
  - Observes terminal panes, detects `claude`/`codex`/`pi`, links their local state stores, and writes derived statuses back onto `TerminalSessionDescriptor.agentDescriptor`.

Consequence: the default "agent" UX was "open a terminal running a CLI". It was observed and could publish sanitized status, but it was not the managed-agent tile experience.

### Managed-agent substrate existed, but was not the default launch path

Relevant files:

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
  - `AgentKind.managed` exists.
- `Sources/ContinuumRevivedCore/ManagedAgentSessionRecord.swift`
  - Private runtime binding for managed sessions; holds tmux target/cwd payload locally.
- `Sources/ContinuumRevivedCore/ManagedAgentTranscriptModel.swift`
  - Folds `AgentRuntimeEvent` into transcript cards and status.
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
  - Renders the managed agent transcript/cards/approval/user-input UI.
- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`
  - Defines `AgentAdapter`, `AgentRuntimeEvent`, approval/user-input events, and status derivation.
- `Sources/ContinuumRevivedCore/AgentMessageBus.swift`
  - `NullAgentMessageBus` is the only live wiring today.

Consequence: the refactor's UI/data model was present, but there was no production "New Agent" command that created `.managedAgent`, started a provider adapter, and fed runtime events into the tile/sync path.

## Product target

### Agent launch menu

Default Cmd-K should become product-first:

1. `New Agent…`
   - Creates a `.managedAgent` tile.
   - Starts a managed adapter session.
   - Shows transcript cards, tool cards, approval/user-input cards, and status in `ManagedAgentTileNSView`.
   - Publishes only sanitized activity/status summaries to the phone.

2. Provider-specific managed options may appear after the generic row:
   - `New Codex Agent…` — managed adapter path, not raw shell tile.
   - Other providers are behind the same adapter contract and should not require changing the phone sync contract.

3. Raw CLI terminal rows become explicit/debug:
   - `Claude CLI Terminal` / `Codex CLI Terminal`, or hidden under a debug/terminal section.
   - These remain useful for diagnostics and for the existing `SessionObserver` path, but they must not be presented as the default agent UX.

### Phone live-state semantics

`Live` on iPhone should mean:

- the phone is paired to this explicit Continuum instance;
- the CloudKit transport/account is available;
- the phone has received a remote desktop heartbeat or snapshot for that paired instance within the live freshness window;
- the activity/canvas data shown is derived from a Mac-published payload, not the receiver's local empty bootstrap state.

The phone should show `Syncing…` / `Waiting for your Mac` until that condition is true.

### Agent registration semantics

There are two supported registration paths, with different product meanings:

```text
Mac agent surfaces
├─ Observed terminal agent (compat/debug)
│  ├─ Tile kind: .terminal
│  ├─ Registration: TerminalSessionDescriptor.agentDescriptor
│  ├─ Status source: SessionObserver + AgentStateReader
│  └─ Phone sync: degraded status summary only
└─ Managed agent (primary product path)
   ├─ Tile kind: .managedAgent
   ├─ Registration: ManagedAgentSessionRecord + adapter session
   ├─ Status source: AgentRuntimeEvent stream folded by ManagedAgentTranscriptModel
   └─ Phone sync: sanitized AgentActivityEvent summaries + approval ids when allowed
```

Do not sync local runtime bindings, transcript bodies, pane ids, cwd paths, process ids, provider secrets, signing keys, APNS tokens, or raw session stores.

## Implementation split

### Phase 1 — Make phone live-state honest

Scope:

- Stop treating the initial local `.empty` activity snapshot from `ActivityProjectionReceiver.subscribe()` as proof of desktop liveness.
- Add an explicit notion of remote desktop data arrival on iOS. Minimum viable fix: ignore `.empty` / zero-sequence bootstrap snapshots for freshness unless they are known to have come from CloudKit. Better fix: add source metadata or a real freshness record.
- Update `AgentsBoardModel.consume(_:)` and `consumeSpatial(_:)` so freshness is based on remote snapshots/events/heartbeats from the paired instance.
- Keep the UI able to show a genuinely empty but fresh desktop: after a real Mac-published empty snapshot, show `Live` + `No agents observed`.

Acceptance:

- Paired phone with no Mac-published snapshot shows `Syncing…` / waiting, not `Live`.
- A real Mac-published empty activity snapshot can still show `Live` + empty board.
- Existing stale/offline/freshness copy continues to work.
- Core/iOS checks cover bootstrap-empty vs real-empty distinction.

### Phase 2 — Publish after pairing and on desktop changes

Scope:

- After `LocalPairingEndpoint` successfully exchanges a token and records a paired device, the Mac should start/update `DesktopCompanionSyncService` and publish a fresh snapshot.
- When `SessionObserver` writes an agent status, schedule a debounced `publishCurrentDesktopSnapshot(reason: .timer)` or a new `.statusChanged` reason.
- When canvas/spatial state changes, schedule a debounced publish or ensure the existing publish path is called from the saved-canvas path.
- Keep manual Debug > Companion Sync > Publish Now as a dogfood escape hatch.

Acceptance:

- Pairing a phone triggers a Mac publish without requiring app restart.
- Spawning a Cmd-K observed agent and changing its status produces a phone-visible row after CloudKit delivery/fetch.
- Manual Publish Now remains available and logs diagnostics.
- Publish debounce prevents per-keystroke or per-file-watch spam.

### Phase 3 — Add diagnostics before the UX refactor

Scope:

- Add a Mac diagnostic panel/log line that reports:
  - paired/unpaired;
  - signed CloudKit entitlement;
  - last activity publish;
  - last spatial publish;
  - last fetch;
  - last publish error;
  - number of registered observed agents;
  - number of managed-agent sessions.
- Add iOS Settings diagnostics showing:
  - paired instance id/device id;
  - granted scope;
  - transport availability;
  - latest remote activity/spatial/heartbeat metadata;
  - current row count/canvas tile count;
  - whether the current `Live` state is remote-backed.

Acceptance:

- Dylan can distinguish: not paired, not entitled, no Mac publish, CloudKit fetch lag, no registered agents, and iOS false-live prevention.

### Phase 4 — Managed-agent launch MVP

Scope:

- Add a new palette action, e.g. `LaunchPaletteAction.newManagedAgent` or provider-specific managed action.
- Implement a `TileSpawner.spawnManagedAgent(...)` path that creates a `.managedAgent` tile and persists a local `ManagedAgentSessionRecord`.
- Wire the spawned tile to `ManagedAgentTileNSView` and a provider adapter facade.
- The first adapter may be minimal: start session, send initial user turn, stream `AgentRuntimeEvent`s, stop/interruption hooks. It does not need full multi-provider polish on day one.
- Publish sanitized `AgentActivityEvent`s from managed events:
  - turn started/completed;
  - working/idle/done/needsAttention status;
  - short tool/action summaries;
  - approval request id only when an approval is actually pending.

Acceptance:

- Cmd-K `New Agent…` creates a `.managedAgent` tile, not `.terminal`.
- Managed agent cards update from runtime events.
- Phone sees the managed agent as a row through the same activity projection path.
- No transcript body crosses the sync boundary.

### Phase 5 — Relabel or move raw CLI terminal profiles

Scope:

- Rename existing LaunchProfileRegistry rows so raw CLI launches are explicit terminal/debug actions, not the default agent UX.
- Update palette checks that currently expect `Claude Code` / agent CLI rows.
- Keep current terminal-observer dogfood path available until managed adapters are proven.

Acceptance:

- The default palette search for "agent" points to managed-agent UX.
- Searching for "terminal" or "CLI" can still find raw CLI profiles if enabled.
- Existing observed-terminal checks remain green or are intentionally updated with new labels.

## Dogfood triage sequence before implementing Phase 4

Use the current build to separate transport/publish issues from managed-UX debt:

1. Launch a signed/provisioned Mac app with CloudKit entitlement.
2. Pair the phone with a fresh QR.
3. On Mac, spawn an observed agent through Cmd-K `New Codex Agent` / current CLI profile.
4. Use Debug > Companion Sync > Publish Now.
5. Watch Mac companion logs for `paired=true`, `lastActivity=...`, and no `lastError`.
6. On iPhone, verify whether a row arrives.

Interpretation:

- If manual publish makes rows appear: transport and session descriptors are usable; missing pieces are auto-publish/live semantics.
- If manual publish does not make rows appear: debug CloudKit fetch/subscription/record availability before changing Cmd-K UX.
- If rows appear but statuses do not update after agent activity: debug `SessionObserver` reader/watch path and the status-write-to-publish bridge.
- If iPhone says `Live` with no remote metadata: fix Phase 1 first.

## Checks to add

No XCTest. Keep checks hermetic/additive.

Suggested checks:

- Core/iOS model check: bootstrap empty snapshot does not set live freshness.
- Core/iOS model check: remote empty snapshot does set live freshness and empty-board copy.
- App self-check: status write schedules exactly one debounced companion publish for N rapid observer updates.
- Sync check: activity snapshot published after pairing exchange hook is called.
- Palette check: default agent row maps to managed-agent action, CLI rows are explicitly terminal/debug.
- Managed-agent check: runtime events fold into managed tile status and sanitized activity events without body/path/pid/pane leakage.

Required validation for any iOS change:

```bash
cd ios && xcodegen generate
xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS Simulator' build
```

Required baseline validation before commit:

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
git diff --check
```

## Non-goals for the first implementation

- Do not make same-iCloud identity count as pairing.
- Do not require managed agents before proving phone live-state truth.
- Do not remove observed terminal support until managed agents are dogfood-proven.
- Do not send transcript bodies, local paths, pane ids, pids, runtime refs, secrets, APNS tokens, or host-local store paths over CloudKit.
- Do not claim CloudKit proof from an unentitled SwiftPM/ad-hoc Mac app.

## Open questions / recommended defaults

1. **Should the first managed adapter be provider-specific or generic?**
   - Recommended: generic `New Agent…` UX with a provider field under the hood; implement Codex first, keep the adapter protocol provider-neutral.

2. **Should `Pair Phone…` grant observer or operator scope by default?**
   - Recommended: keep observer default. Add an explicit debug/operator pairing path later for canvas edits and approvals.

3. **Should raw CLI profiles be hidden or relabeled?**
   - Recommended: relabel first (`Codex CLI Terminal`, `Claude CLI Terminal`) so existing dogfood/debug remains available while the managed path matures.
