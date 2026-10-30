# Shared geometry implementation

Implementation in the `collaboration-finish` bench. Native verification and hover
teeth results are recorded below. The parent's final batched gate and paired
Array/local-relay harness own the broader end-to-end result.

The shared canvas supports pointer movement, Shift/Command-click group selection,
and lower-right group resizing. A drag previews portable area frames without
changing the authoritative document. Mouse release submits one atomic placement
command at the gesture’s captured revision. A new authoritative revision during
a preview cancels the complete preview; a stale command is refused and reloaded,
never rebased or mixed with a teammate’s coordinate components. Escape cancels.
View-only participants can select and navigate but cannot start a mutation.

Undo and Redo submit conditional inverse/forward placement commands. They never
restore a document snapshot or alter a private camera/source project. A reducer-
owned `PlacementWrite` records operation ID and revision for each placement write.
An inverse requires the exact frame and causal stamp it intends to replace;
moving away and back to the same frame cannot revive an older Undo. Unrelated
discussion changes remain intact. Compensation updates only a proven local
history lineage, allowing successive own Undo/Redo without accepting remote ABA.
History is bounded and persisted per person/device/area in an atomic geometry
ledger beside the data outbox. The full inverse mutation is retained before the
outbox can send. A crash after remote success but before local acknowledgement
reconciles the exact operation receipt and restores Undo; a crash during an Undo
similarly restores Redo. A prepared ledger intent whose outbox write never began
can exact-submit only after fresh online admission. Neither recovery path infers
success from frame equality or dispatches provider work.

Old v1 snapshots may omit `placementWrites`; absent provenance remains unknown.
New stamps require a matching retained operation receipt and a live placement.
Every new geometry command produces reducer-owned provenance, and duplicate
delivery keeps the original stamp. Clients never submit a stamp as a grant.

`SharedAreaSceneView` exposes:

- `beginGeometry(placements:kind:)`, `updateGeometry(frames:)`, `finishGeometry()`
- `cancelGeometry()`, `undoSharedGeometry()`, `redoSharedGeometry()`
- `canUndoSharedGeometry`, `canRedoSharedGeometry`, `isGeometryGestureActive`
- `hasPendingGeometry`, `geometryLedgerFile` for private recovery diagnostics
- `checkPendingDelivery()` using the controller’s exact-operation outbox
- `areaCanvasView`, `localViewCamera`, scene-relative `screenPoint(forAreaPoint:)`
  and `areaPoint(forScreenPoint:)`
- `onRequestHandoff`, `onLocalCameraNavigation` and `onCanvasTransformChange`
  integration callbacks; the last reprojects a stationary local pointer and
  rechecks hover inspection as the camera or canvas size changes

The Workspace choice menu includes Undo/Redo and pending-delivery recovery. The
canvas implements the real Edit Undo/Redo responder actions and Command-Z /
Shift-Command-Z. Text editors retain their native text Undo path. Geometry status
does not rebuild controls for presence-only changes, and previews create no native
view per tile or pointer packet.

Core witness entry: `runSharedAreaGeometryChecks()`. Native witness entry:
`SharedAreaGeometrySceneChecks.run(mount:executorCount:)`, supplied the shipping
mount. They cover atomic groups, strict provenance/legacy decoding, causal ABA,
multiple local compensation steps, atomic durable inverse retention/cold receipt
recovery, real pointer group move/resize, dual cameras,
responder Undo/keyboard Redo, remote-during-drag cancellation, read-only denial and
source-byte/executor preservation. The native cold-controller witness holds a
reply after authority commit, tears down the old controller, opens a new one,
and proves Undo works before the original reply is released. The parent’s paired
process test supplies the actual kill/relaunch counterpart. The parent must
register both entries in its gate.

Suggested teeth test: remove the causal-stamp comparison from
`SharedAreaGeometryHistory.validate`. The equal-frame teammate ABA witness must
turn RED. Moving/removing the geometry-ledger prepare write until after network
acceptance must make the remote-success/local-ack cold recovery witness RED. A
second useful counterexample is allowing release after a new remote
revision without cancelling/refusing its captured gesture; the native remote
conflict witness must show an extra attempted stale operation.

Initial static validation used Swift frontend parsing and scoped whitespace.
The parent subsequently ran the geometry Core/native witnesses in its batched
gate. This agent then ran the known `--collaboration-native-check` against fresh
Array builds: baseline GREEN, a compile-valid always-visible usage-card mutant
RED at the resting-no-overlay assertion, then exact-byte source restoration in
`finally`, a fresh restored Array build and native GREEN. These runs included all
native geometry, hover/lifecycle, provider usage adapter and handoff UI cases.
Evidence is under `validation/finish-20261030/teeth/08-*`, `09-*` and `10-*`.
The three native runs captured 50, 45 and 52 actual frontmost-app samples with no
focus theft. Each used disposable project/support roots and its own physically
resolved `TMUX_TMPDIR`; its real socket was verified inside that namespace and
only that disposable server was cleaned up. Light/dark hover renders were also
inspected. No full matrix, production state, live tmux server, provider process,
deployment or Git mutation was performed by this agent.

The accompanying App lifecycle review also found and fixed persistent hover after
window exit or a moving teammate cursor, stopped usage collectors being reused
after a host-session restart, and equal sequence numbers suppressing the first
report from a replacement host. The overlay now uses native exit tracking,
rechecks its actual stationary pointer when peers/camera move, clears expired
inspection without requiring another mouse event, and validates reported counters
before rendering sums. Accessibility inspection uses the same transient card.
`SharedAreaPresenceChecks.run()` includes these behavioral cases and calls
`SharedAreaHostSessionChecks.run()` for equal-sequence host changes, restored
supervisor event delivery after stop/start, accounting after view closure and
replay deduplication with zero executor construction. These checks were added for
the parent's batched verification and passed in both baseline and restored native
runs. The first batched native run exposed a card-clamping defect: an offscreen
cursor's newly clamped card could cover a stationary pointer and retain hover.
Card retention now requires the pointer inside both the already-rendered and
current card, and offscreen cursors cannot display a card. A rendered witness also
covers a cursor moving up/left so its new card would otherwise appear under the
stationary pointer.
