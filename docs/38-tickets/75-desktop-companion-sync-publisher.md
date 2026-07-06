# Desktop companion sync publisher — signed CloudKit bridge for live iPhone dogfood

Status: **new / supervised + needs-substrate, 2026-07-06.** Created after physical-phone dogfood showed the iOS app can launch but does not receive the desktop app's live agents/canvas. This ticket captures the missing desktop-side publisher/inbound bridge left as `publisher-owed` by night-3 Track B.

## Problem statement

Dylan's expectation is correct at the product level: if the Mac and iPhone are signed into the same iCloud account, opening desktop Continuum with running agents should make the iPhone companion show those agents and the canvas. In the current checkout, that does **not** happen.

Verified gaps:

1. **No desktop runtime publisher is wired.** `CloudKitSyncTransport`, `ActivityProjectionSender`, and `SpatialOpSender` exist, and the iOS app constructs receivers, but the macOS app target does not start a companion sync service that pushes the live `CanvasState`/`WorkspaceDocument` or agent activity projection to CloudKit.
2. **Desktop canvas edits do not flow through the op-log in production.** Ticket 61b delivered the first spatial wire path for iOS, but explicitly left desktop app op-log store wiring as `publisher-owed`.
3. **Agent activity production is blocked on the observer path.** The iOS board can render an `ActivityLogSnapshot`, but the production desktop observer that turns live terminal/agent sessions into `ActivityStore` events is not built end-to-end yet. Ticket 40 (`SessionObserver`) is still the missing supervised foundation noted by `_PROGRESS.md`; ticket 41 and ticket 70 are blocked on it.
4. **CloudKit container identifiers conflict.** The iOS app currently uses `iCloud.dev.dylanreedx.continuum`, while the macOS entitlement/ticket-57 documentation uses `iCloud.io.bannockburn.continuum`. Same iCloud account cannot bridge two different CloudKit containers.
5. **SwiftPM launches are unentitled.** Running `.build/debug/continuum-revived` cannot prove real CloudKit sync because SwiftPM does not attach iCloud entitlements. The dogfood path must run a signed `.app` with the correct entitlements.

## What this delivers

After this ticket lands, a signed desktop Continuum app acts as the Mac-side companion publisher for the iPhone app:

- On desktop launch, it starts a `DesktopCompanionSyncService` when iCloud is available and companion sync is enabled.
- It writes an initial spatial snapshot for the active workspace/project to the same CloudKit container the iOS app reads.
- It publishes an initial activity snapshot for visible/known agent tiles, then tails updates as agent status changes.
- It registers/subscribes/fetches CloudKit changes so phone-originated canvas edits and approval responses are ingested by desktop code instead of timing out or disappearing.
- It exposes honest diagnostics in the desktop UI/log: container id, account availability, last publish time, last fetch time, last error, and whether the app is running signed with the required entitlements.
- A physical iPhone on the same iCloud account can show at least one real desktop agent row and the corresponding canvas tile within the documented CloudKit cadence (~1–3 s typical, honest fallback ≤10 s with manual foreground/fetch).

The user-visible outcome is simple: launch signed desktop Continuum, launch the iPhone app, spawn or focus an agent tile on desktop, and the phone's Agents and Canvas tabs update.

## How it fits

This is the missing integration ticket between the pieces that already landed:

- **57** delivered `CloudKitSyncTransport`, but explicitly descoped app-startup injection.
- **58** delivered `ActivityProjectionSender`/`Receiver` over the transport seam.
- **61a** delivered the iOS Agents board and the CloudKit receiver startup path, with live CloudKit proof marked `device-gate-owed`.
- **61b** delivered the iOS Canvas view/editor and `SpatialOpSender`/`Receiver`, but `_PROGRESS.md` says desktop app op-log store wiring and fetch/subscription pump are `publisher-owed`.
- **62** delivered approval response wire types and iOS buttons, but CloudKit approval send currently errors honestly because the desktop inbound pump/seam consumer is not built.
- **63** delivered push payloads and iOS notification registration, but production triggers and token-over-wire registration are `publisher-owed`.
- **40/41/70/69** remain the richer production observer/managed-agent path. This ticket must not fake that those are done; it may ship a degraded real-session snapshot path for existing terminal descriptors, but it must keep the path explicit and replaceable by ticket 40's observer.

## Scope

### In scope

1. **Container reconciliation**
   - Pick one CloudKit container for desktop + iOS dogfood. For the currently installed iOS app, the practical target is `iCloud.dev.dylanreedx.continuum` unless Dylan chooses to rebuild/reprovision the phone app under the spec's `dev.dylanreed.continuum` identity.
   - Update macOS entitlements, package/bundle scripts, and runtime constants so desktop and iOS use the same container.
   - Add a single shared source of truth for the container id, or add an explicit config flag with diagnostics that prints both sides' configured ids.

2. **Signed desktop app path**
   - Ensure `scripts/make-app-bundle.sh` / `scripts/check-app-bundle.sh` (or a new supervised script) can build and run a signed `.app` with iCloud entitlements.
   - Add a startup diagnostic that reports `entitled=true/false` for CloudKit capability where feasible, and shows an actionable message if the user launched the unentitled SwiftPM binary.

3. **Desktop spatial publisher**
   - On startup and after relevant desktop canvas mutations, publish a `CompactedSnapshot` representing the active desktop canvas/workspace to CloudKit via `CloudKitSyncTransport.send(.snapshot(...))`.
   - Use the production op-log vocabulary where possible. If the initial bridge synthesizes a snapshot from existing `CanvasState`/`WorkspaceDocument`, document that as a bootstrap snapshot and do not pretend historical ops exist.
   - Wire desktop-originating canvas mutations into a `SpatialOpLogStore` going forward, so future desktop moves/resizes can tail as `.op` records and phone edits can converge against the same materialized state.

4. **Desktop spatial inbound pump**
   - Start `ensureSubscription()` and call `fetchChanges()` on app foreground, silent push notification, and a manual debug action.
   - Route inbound `.op` messages from CloudKit through authorization and apply accepted phone edits to the live `CanvasNSView` + persisted stores.
   - Never silently drop failed inbound edits: log with tile/zone ids and error class, and surface a non-blocking sync error diagnostic.

5. **Desktop activity publisher**
   - Publish an initial `ActivityLogSnapshot` to CloudKit through `ActivityProjectionSender` or an equivalent production-owned `ActivityStore`.
   - Minimal acceptable v1 source: existing terminal session descriptors + `CanvasNSView.agentStatus(for:)` / project session files, producing sanitized metadata only (`tileId`, status, kind, summary, updatedAt; no transcript bodies, pids, pane targets, or host paths).
   - Preferred v1.1 source: ticket 40 `SessionObserver` feeding `ActivityStore.append` events; if ticket 40 is still absent, the bridge must be clearly named `DegradedDesktopActivitySnapshotSource` and tested as a temporary source.
   - Republish on agent status changes and on a bounded timer/foreground refresh so the phone is not stuck on boot-only data.

6. **Approval response inbound pump**
   - Wire `.approvalResponse` messages from CloudKit to `ApprovalResponder` and the real desktop approval seam where available.
   - Until ticket 70/69 provides the full managed-agent approval resolver, return honest `unknownRequest`/`unauthorized` acks rather than timing out.

7. **Diagnostics / dogfood controls**
   - Add a desktop menu/debug action: `Companion Sync: Publish Now`.
   - Add a desktop menu/debug action: `Companion Sync: Fetch Now`.
   - Add a concise status row or log block: container id, account status, last activity publish, last spatial publish, last fetch, last inbound op, last approval response, last error.

### Out of scope

- Designing a new sync protocol outside the existing `SyncTransport` seam.
- Streaming mid-drag frames; iOS and desktop still sync one op on gesture end.
- Syncing raw terminal transcripts or host-private process details across CloudKit.
- Solving all managed-agent adapter semantics; ticket 69/70 remain the production approval and managed-runtime source.
- APNS device-token registration over the sync channel unless kept as a small additive diagnostic after the core sync path is green.

## Proposed architecture

```swift
@MainActor
final class DesktopCompanionSyncService {
    let transport: CloudKitSyncTransport
    let demux: SyncMessageDemux
    let activityStore: ActivityStore
    let spatialStore: DesktopSpatialOpLogStore
    let activitySender: ActivityProjectionSender
    let spatialSender: SpatialOpSender
    let approvalResponder: ApprovalResponder

    func start() async
    func publishCurrentDesktopSnapshot(reason: PublishReason) async
    func fetchChanges(reason: FetchReason) async
    func stop()
}
```

### Startup sequence

1. Resolve configured container id and check `CKContainer.accountStatus()`.
2. If unavailable, record `offline/sign-in-required` and do not blank existing local desktop state.
3. Create one `CloudKitSyncTransport` and one shared `SyncMessageDemux`.
4. Start `ActivityProjectionSender` over the desktop `ActivityStore` with `.observer`/read scope.
5. Start `SpatialOpSender` over the desktop spatial store with operator scope for the paired/local desktop session.
6. Start `ApprovalResponder` if an approval seam exists; otherwise start a responder that acks `unknownRequest` for safety.
7. `ensureSubscription()` then `fetchChanges()`.
8. Publish current spatial snapshot and activity snapshot.

### Spatial snapshot source

The bridge needs a deterministic mapping from the desktop's current stores to sync state:

- `CanvasState` comes from the active project's `ProjectStore`/live `CanvasNSView`.
- `WorkspaceDocument` comes from the active `WorkspaceRuntime`/`WorkspaceStore`.
- The initial publish may use a compacted snapshot directly if there is no historical op log. Subsequent desktop edits must append real `LoggedOp`s to `DesktopSpatialOpLogStore` so phone edits and desktop edits share one ordering model.

### Activity snapshot source

Temporary degraded source, until ticket 40 lands:

- Enumerate current terminal tiles in active/live project canvases.
- Join to `ProjectStore.listSessions()` and `CanvasNSView.agentStatus(for:)`.
- Build `ActivityLogSnapshot.byTile` with one `TileActivity` per known agent tile.
- `lastSummary` should be a sanitized short string such as `"Claude working"`, `"Pi needs attention"`, or `"Shell idle"`.
- Do not include cwd, process ids, tmux pane/window targets, transcript text, or local file paths.

When `SessionObserver` exists, replace this with event-fed `ActivityStore.append` so the phone timeline receives real sanitized events.

## Files likely touched

- `Sources/ContinuumRevived/App/ContinuumApp.swift` — create/start/stop `DesktopCompanionSyncService`; add menu/debug actions.
- `Sources/ContinuumRevived/App/DesktopCompanionSyncService.swift` — new app-layer coordinator.
- `Sources/ContinuumRevived/App/DesktopActivitySnapshotSource.swift` — degraded snapshot source, later replaced by `SessionObserver`.
- `Sources/ContinuumRevived/App/DesktopSpatialOpLogStore.swift` — durable or semi-durable spatial op store for desktop-originating ops.
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift` / `CanvasNSView` callbacks — emit spatial ops on desktop move/resize/zone changes rather than only saving local JSON.
- `Sources/ContinuumRevived/ContinuumRevived.entitlements` — align container id with iOS.
- `ios/project.yml`, `ios/Continuum/Resources/Continuum.entitlements`, `ios/Continuum/Sources/ContinuumApp.swift` — only if Dylan chooses to switch the iOS bundle/container to the spec's non-`x` id.
- `scripts/make-app-bundle.sh`, `scripts/check-app-bundle.sh` — signed-entitled desktop build/run gate.
- `Sources/ContinuumRevivedSyncIntegrationChecks/main.swift` — extend gated real-CloudKit check for desktop publisher paths where possible.

## How we test it

### Logic checks — autonomous

Add checks in existing `*Checks` executables, not XCTest:

1. **Container config check**
   - Desktop and iOS config constants/entitlement fixtures agree on the same CloudKit container id for the selected dogfood build.
   - If the spec bundle id remains different from the installed bundle id, the check must print both and require an explicit compatibility flag/fixture.

2. **Activity snapshot taint check**
   - Build a degraded activity snapshot from fixture terminal descriptors containing hostile cwd/pid/pane/transcript-like values.
   - Assert the encoded `ActivityLogSnapshot` contains status/kind/summary only and no forbidden tokens.

3. **Spatial bootstrap determinism check**
   - Convert a fixture `CanvasState` + `WorkspaceDocument` to the bootstrap `CompactedSnapshot` twice and assert canonical bytes are identical.
   - Materialize the snapshot and assert tile frames, zone membership, z-order, viewport, and active ids match the source.

4. **Desktop edit op emission check**
   - Drive the pure edit hooks for move, resize, zone membership, bring-to-front.
   - Assert exactly the expected `Op` sequence is appended and persisted before publish.

5. **Inbound op apply check**
   - Feed a phone-originated `.setTileFrame` and `.setTileZone` through the desktop inbound handler against a fixture live canvas/store.
   - Assert live state and persisted state both update, and unauthorized ops are rejected without mutation.

### Backend checks — local fake transport

Use real `ActivityProjectionSender`/`SpatialOpSender`/receivers over `FakeSyncTransport` or wrapped fake replicas:

1. Desktop publishes initial spatial snapshot → phone receiver materializes the same `CanvasScene`.
2. Desktop publishes activity snapshot → phone receiver rows show the expected attention-first order.
3. Phone emits a move op → desktop inbound handler applies it → desktop sender rebroadcasts → phone converges without duplicate drift.
4. Approval response sent by phone → desktop responder acks `unknownRequest` when no managed approval seam exists, rather than timing out.

### Gated CloudKit check — needs substrate

Behind `CLOUDKIT_ENABLED=1` and a signed-entitled app/host:

1. Signed desktop publisher writes a spatial snapshot and activity snapshot to the selected container.
2. iOS app on physical iPhone or signed-in simulator cold-connects and receives both.
3. Desktop move → iPhone canvas updates within ≤10 s after foreground/fetch.
4. iPhone operator-mode move → desktop canvas updates or returns an honest rejection/toast.
5. Approval action returns a terminal ack (`unknownRequest` acceptable before ticket 70; timeout is not acceptable).

### Visual / dogfood gate — supervised

With Dylan's physical iPhone:

1. Launch signed desktop Continuum.
2. Launch iPhone Continuum.
3. Spawn or focus a real desktop agent tile.
4. Confirm iPhone Agents tab shows the row with status and updated timestamp.
5. Confirm iPhone Canvas tab shows the corresponding tile/zone geometry.
6. Move the tile on desktop; confirm the phone updates.
7. If operator override/scope is enabled, move the tile on phone; confirm desktop updates or shows a clear scope rejection.
8. Capture screenshots/logs into `qa-runs/<timestamp>/companion-sync/`.

## Done when

- Desktop and iOS use the same CloudKit container for the dogfood build, and this is asserted by a check.
- The desktop app has a signed-entitled launch path; SwiftPM unentitled launch prints an honest diagnostic and is not used for device proof.
- Desktop publishes current spatial and activity snapshots on startup/foreground/manual publish.
- Desktop tails/fetches CloudKit changes on foreground/manual fetch and handles inbound spatial ops and approval responses honestly.
- A real iPhone on the same iCloud account shows at least one desktop agent row and matching canvas tile from the signed desktop app.
- Moving a desktop tile updates the phone, or the failure is surfaced with a specific error.
- Phone approval action no longer spins until timeout; before ticket 70, `unknownRequest`/`unauthorized` is acceptable and visible.
- Matrix stays green; real CloudKit/device legs are recorded as supervised artifacts, not faked.

## Watch out for

- **Do not count SwiftPM as a CloudKit proof.** `.build/debug/continuum-revived` is unentitled.
- **Do not silently use two containers.** Same Apple ID does not bridge `iCloud.dev.dylanreedx.continuum` and `iCloud.io.bannockburn.continuum`.
- **Do not leak I5 data.** Session files contain cwd/runtime refs/pane-ish values; activity snapshots crossing CloudKit must stay metadata-only.
- **Do not bypass ticket 40 by inventing transcript sync.** The degraded source is for status rows only; real timeline events come from the observer.
- **Do not accept phone edits without authorization.** Client-side read-only UI is not a security boundary.
- **Do not overwrite phone-local optimistic ops with a stale desktop snapshot.** Snapshot application must preserve tail ops not absorbed by the incoming compaction, matching `SpatialOpReceiver`'s existing rule.
- **Do not fake APNS/silent-push delivery.** A manual `fetchChanges()` catch-up check is useful, but label it as catch-up unless a real push notification caused it.

## Execution mode

**Needs-substrate + supervised.** Logic and fake-transport checks are autonomous, but the actual value of this ticket is the signed desktop app + physical iPhone CloudKit round trip. It requires Dylan's Apple developer team, a provisioned CloudKit container, a signed macOS app with iCloud entitlements, and the physical iPhone or signed-in simulator. The final acceptance artifact is a real dogfood run, not only a matrix pass.
