# 61b — iOS canvas view + editor (night3 B4)

> **RULING BANNER — C-20260705-025 (night3 B4, orchestrator pre-flight 2026-07-05). Binding
> contract for this item. Parent spec: `_COMPANION_SPEC.md` §1, §2.2, §6.3, §6.6. Sibling
> record: ticket 61's C-024 banner (B3 agents board — its package surgery and app wiring are
> the base this builds on). Where this banner and the companion spec conflict, this banner
> wins; it reconciles the spec against verified code facts.**

> **REV.2 — continuation adjudication (orchestrator, 2026-07-05, B2/B3 precedent).** Round-3
> state: all three gates green, Claude reviewer CLEAR, Codex rejected with 3 concerns.
> Adjudication:
>
> 1. **BOUND (valid, the continuation fix):** `commitMove` (ios ContinuumApp.swift ~:733)
>    emits the membership op even when the preceding `setTileFrame` send failed —
>    `emitCanvasOp` swallows the failure, so a failed move still yields a `setTileZone`
>    computed from the failed destination frame (partial mutation; violates this ticket's
>    snap-back / never-silently-lost contract). Fix shape (shared logic stays out of `ios/`):
>    (a) `CanvasEditIntent.moveDropOps(tile:currentZoneId:to:zones:) -> [Op]` — pure ordered
>    op list for a drop (the `setTileFrame`, then `setTileZone` ONLY if the resolved target
>    differs), table-checked in CoreChecks (no-change → 1 op; change → 2 ops in order);
>    (b) `SpatialOpReceiver.emitAll(_ ops: [Op])` — sequential emit that STOPS at the first
>    failure (the failed op's optimistic apply reverts as today; ops after the failure are
>    never sent; earlier successes stand — a completed move without the membership change is
>    a valid state, a membership change after a failed move is not); (c) `commitMove` calls
>    `emitAll(moveDropOps(...))`; the single-op gesture paths may keep `emit`. Sync check:
>    drive the REAL receiver over a transport whose send fails on the first op → store
>    receives nothing, the second op is never sent (count sends), phone state reverted;
>    and a success-path batch → both ops land in order.
> 2. **OUT OF SCOPE (already owed, now named explicitly):** "no production path calls
>    `CloudKitSyncTransport.fetchChanges()`/`ensureSubscription()`" is the live-CK tail pump.
>    Verified: the ACTIVITY path shipped by 61a has the identical gap — it is the accepted
>    `device-gate-owed` state of the whole track (B2's catch-up honesty ruling; no transport
>    consumer pumps fetchChanges in production yet). The pump belongs to the desktop-publisher
>    /live-leg follow-up plus ticket 63's silent-push nudge. The diff's cold-snapshot answer
>    to `.spatialSubscribe` in CloudKitSyncTransport (mirroring `.activitySubscribe`) is
>    RATIFIED. Owed tags on this item now read: `visual-gate-owed`, `device-gate-owed`,
>    `publisher-owed` **incl. the fetchChanges/ensureSubscription tail pump**. No code change.
> 3. **PROCEDURAL (no diff change):** the `_PROGRESS.md` ledger row is appended by the
>    ORCHESTRATOR in the post-commit docs commit, per the harness contract used by every
>    prior item tonight; the row will document the DEBUG `CONTINUUM_SCOPE_OVERRIDE=operator`
>    escape hatch and all owed tags. A missing ledger row in the implementation diff is not
>    a defect.
>
> Continuation contract: implement exactly rev.2 §1, re-run all three gates, dual re-review
> the FULL diff (both reviewers read this rev.2 as part of the contract), commit only on
> both-clear.

## Verified pre-flight facts (orchestrator probe, 2026-07-05 — do not re-litigate)

- `SyncMessage` (Sources/ContinuumRevivedSync/SyncTransport.swift:45) ALREADY carries
  `case op(LoggedOp)` and `case snapshot(CompactedSnapshot)`. Its Codable is synthesized on
  purpose — it is an in-flight envelope, NOT a frozen format. The frozen thing is `Op`'s
  hand-written wire coding (SpatialOp.swift:112-155) — do not touch that.
- There is NO production spatial sender/receiver anywhere. `.op(`/`.snapshot(` are constructed
  only in checks. `materialize(` has ZERO call sites in the desktop app target. Activity
  projection is the only production traffic on the transport. **This item builds the first
  spatial wire path.**
- `materialize(ops:)` (OpLog.swift:129) and `materialize(onto:baseOpId:ledger:tail:)`
  (OpLog.swift:402) are the proven folds; ticket 07's I4 fuzz proves byte-identical convergence
  for ANY multiset of well-formed `LoggedOp`s regardless of origin replica. An iOS-emitted op
  needs no new convergence proof — it needs a distinct replica UUID and a lamport that slots
  into the `OpId` total order.
- `SyncMessageDemux` (SyncMessageDemux.swift) already gives independent inbound copies to a
  spatial consumer alongside the activity consumer; `subscribe()`-before-send ordering is
  load-bearing and already handled.
- Scope map (ScopeAuthorization.swift:16-27): `.subscribeSpatial → .orchestrationRead`,
  `.moveTile`/`.resizeTile → .orchestrationOperate`. `authorize(_:grantedScopes:)` throws
  typed `AuthError`.
- `CanvasState`/`WorkspaceDocument`/`SpatialOp`/`Scope` are Foundation-only, cross-platform.
  `Tile` render order is the `(zPosition, id)` sort, never array order. `ZonePlacement.color`
  is a string tint token. `TileFrame` is world coordinates; viewport is per-device camera and
  is EXPLICITLY absent from the op vocabulary — never sync it.
- Bring-to-front has NO dedicated op: it is `setTileZIndex` with a `FracIndex.after(frontmost)`
  (tiles) / `setZonePosition` (zones). There is no clamping/snapping rule anywhere — do not
  invent one.
- The iOS app (ios/Continuum/Sources/ContinuumApp.swift) has a Canvas `PlaceholderScreen`
  (~:38) and a detail "Show on canvas" button that already switches to the canvas tab
  (~:195-201). `AgentsBoardModel.start()` wires `CloudKitSyncTransport` → `SyncMessageDemux` →
  `ActivityProjectionReceiver(scope: .observer)`. Scope is hard-coded `.observer`; there is no
  pairing plumbing on the phone yet.
- Package.swift already has `.iOS(.v17)` + both library products (61a). Naming hazard: a
  SECOND, unrelated `SyncTransport`/`FakeSyncTransport` pair lives in
  `Sources/ContinuumRevivedCore/Substrates/` (ticket 12). Use the **Sync module** seam. The
  Sync `FakeSyncTransport` does NOT conform to the seam — checks wrap it, per the
  `FakeReplicaSyncTransport` adapter precedent (ActivityProjectionTests.swift:96).

## Ruled scope — three layers, ONE commit

### (a) Sync module: first spatial-op wire path (`Sources/ContinuumRevivedSync/`)

1. Add `case spatialSubscribe(SpatialSubscribeRequest)` to `SyncMessage`.
   `SpatialSubscribeRequest` is an empty-for-now Codable struct (no cursor tonight — cold
   connect always serves the full snapshot, the B0b-analog v1 ruling; the envelope is
   synthesized-Codable so adding a cursor later is cheap and unfrozen).
2. `SpatialOpSender` actor (the desktop-role peer), mirroring `ActivityProjectionSender`'s
   shape: `init(store:demux:authorizedScope:)`.
   - Serves snapshot-then-tail on `.spatialSubscribe` after `authorize(.subscribeSpatial,
     grantedScopes:)`: one `.snapshot(CompactedSnapshot)` (compacted through the store's
     latest op via the existing `compact(log:through:)`), then `.op` tail as the store grows.
   - INGESTS inbound `.op` messages (phone edits): each op is authorized against the session
     scope — `setTileFrame` → `.moveTile`/`.resizeTile` class, all spatial mutations require
     `.orchestrationOperate` via a small explicit `capability(for: Op) -> ControlMessage`
     helper — before appending to the store and rebroadcasting to subscribers. An
     unauthorized op is dropped, never appended (the check proves it); there is no error
     channel in `SyncMessage` v1 and the phone UI independently disables editing below
     operator scope (defense in depth, both layers checked).
3. `SpatialOpLogStore` protocol (append, snapshot access, tail stream) + an in-memory
   `MemorySpatialOpLogStore`. **The desktop app's live canvas is NOT wired to a store
   tonight** — verified fact: desktop canvas mutations don't flow through the op-log in
   production at all; that bidirectional bridge is a separate follow-up ticket (B2
   injection-descope precedent). Do NOT touch desktop canvas mutation paths.
4. `SpatialOpReceiver` actor (the phone-role peer): `connect()` registers on the demux then
   sends `.spatialSubscribe`; folds `.snapshot` + `.op` via the EXISTING
   `applySnapshot`/`materialize(onto:baseOpId:ledger:tail:)` — it keeps (base snapshot, tail
   list) and re-folds; **no bespoke incremental apply tonight** (kills the
   incremental-vs-full divergence hazard by construction). Exposes
   `AsyncStream<MaterializedState>` + `emit(_ op: Op)`: allocates `OpId(lamport: maxSeen+1,
   replica: phoneReplicaId)`, applies locally (optimistic re-fold), sends `.op`; on send
   throw, reverts the local append and surfaces the error to the caller.

### (b) Shared render/edit logic in Core (`Sources/ContinuumRevivedCore/`)

5. `CanvasSceneProjection` — pure fold `MaterializedState → CanvasScene`: zones in
   `zPosition` order with tint tokens, tiles in `(zPosition, id)` render order with kind
   glyph tokens, membership resolved from `tile.zoneId`, world frames passed through.
   Color/glyph TOKENS are strings; token→SwiftUI Color mapping stays in the app layer
   (C-024 §4 precedent).
6. `CanvasEditIntent` — pure gesture-end→Op helpers: `moveEnded(tile:to:) → setTileFrame`,
   `resizeEnded → setTileFrame`, `dropTarget(point:zones:) → UUID?` zone hit-test (topmost
   zone whose frame contains the point) feeding `setTileZone`, `bringToFront(tile:scene:) →
   setTileZIndex` with `FracIndex.after(frontmost)` (never lowers the frontmost — 04
   doctrine), and `isEditingPermitted(scope:) == scope.contains(.orchestrationOperate)`.

### (c) iOS Canvas tab (`ios/Continuum/Sources/`) — replaces the placeholder, spec §6.3

7. Pan/zoom canvas + fit-all button. Tiles = rounded rects (title, kind glyph, status dot
   joined from the existing `AgentsBoardModel` rows by tileId); zones = tinted regions with
   headers; z-order honored. Wire a `SpatialOpReceiver` over the SAME demux the activity
   receiver uses (one transport, one demux — do not build a second transport).
8. Editing iff `grantedScope.contains(.orchestrationOperate)`: drag → ghost outline → ONE
   `setTileFrame` on drop; pinch-handle resize → `setTileFrame` on gesture end; drag
   into/out of a zone → `setTileZone` on drop (membership highlight while hovering);
   long-press → bring to front. Send failure → snap back + non-blocking error surface
   (never silently lost). NO mid-drag ops. Observer scope: read-only + small lock badge.
   Tile/zone create/delete/spawn: NOT in v1 (spec defers to v1.1) — no such gestures.
9. Thread a single `grantedScope: Scope` value through the app (still `.observer` by
   default — pairing raises it later). DEBUG-only escape hatch for the morning visual gate:
   `ProcessInfo` env `CONTINUUM_SCOPE_OVERRIDE=operator` (DEBUG build only, documented in
   the ledger row) — without it the editor is unreachable for dogfooding.
10. Honest empty state: "No canvas synced yet" + note that the desktop publisher is the
    follow-up wiring ticket. "Show on canvas" from agent detail centers that tile when the
    canvas has it; otherwise plain tab switch.

## Checks (headless, wired into the existing `*Checks` mains + run-matrix — no XCTest)

- **Core** (`ContinuumRevivedCoreChecks`): table checks for `CanvasSceneProjection`
  (z-order incl. FracIndex ties broken by id, membership, tint/glyph tokens) and
  `CanvasEditIntent` (exact frame on drop; zone hit-test in/out/overlapping-zones-topmost;
  bring-to-front FracIndex sorts after prior frontmost; scope predicate both ways).
- **Sync** (`ContinuumRevivedSyncChecks`), real-path per the 61a adapter precedent: REAL
  `SpatialOpSender` + `SpatialOpReceiver` over wrapped `FakeSyncTransport` — connect, receive
  snapshot + tail; phone emits move + membership-change + bring-to-front at operator scope →
  ops land in the store → both sides' `MaterializedState.canonicalEncoded()` byte-identical.
  Observer-scope emission: op NOT appended to the store AND the phone-side optimistic state
  reverts on the (injected) failure path. Lamport allocation: after a snapshot whose max
  lamport is N, the emitted `OpId` sorts after every observed op. Order-independence spot
  check: `materialize(desktopOps + phoneOps)` == `materialize(phoneOps + desktopOps)` using
  ops produced by the PRODUCTION emit path. Measured values printed; no `{passed:true}`.
- **I5**: no new surface — `Op` carries no runtimeRef by construction and `SyncPayloadTaint`
  already traps the forbidden keys; do not add fields to `Op`.

## ComponentLab (Dylan's directive — same commit)

"Canvas Scene" card in the macOS lab (67 projection-rows pattern): fixture
`MaterializedState` (2 zones + 4 tiles, one membership, distinct z-orders) rendered through
the REAL `CanvasSceneProjection` as labeled rows (zone rows with tint token; tile rows with
glyph token + render index + zone membership), plus the `runSelfCheck()` assertion for the
card id and expected rows. iOS SwiftUI views themselves are lab-exempt (no macOS host).

## Gates

(a) `swift build` clean; (b) `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` green
including the new checks; (c) `cd ios && xcodegen generate && xcodebuild -project
Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS Simulator' build`
clean. Owed to morning: `visual-gate-owed` (simulator screenshots: canvas render, drag ghost,
snap-back toast, lock badge at observer scope); `device-gate-owed` (live CloudKit leg);
**publisher-owed**: the desktop-app op-log store wiring ticket — until it lands, the
production phone canvas honestly shows the empty state.

## Do NOT

Touch `Op`'s frozen Codable or add `Op` cases · touch `ConnectionSupervisor.swift` (B0
redesign pending) · add spatial cursor/replay · sync viewport/camera · emit mid-drag ops ·
add phone-side create/delete · duplicate shared logic into `ios/` · weaken `run-matrix.sh` ·
instantiate `CKContainer`/`CKDatabase` in any `*Checks` target (C-023 §4).
