import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/06-oplog-apply-compaction.md
//
// `materialize` is the deterministic fold that turns a multiset of `LoggedOp`
// values (in ANY delivery order, from ANY number of replicas) into a
// `MaterializedState`. It is the engine the I4 convergence fuzz drives.

/// The pure output of folding a `[LoggedOp]` log in total order.
///
/// **Canonical encoding contract (I4).** For the convergence fuzz's
/// byte-identity assertion to be meaningful, `MaterializedState` must encode
/// to the SAME bytes on every replica given the same multiset of ops. This
/// requires:
///   - Encoding with `JSONCodec.makeOpLogEncoder()` (`.sortedKeys`, fixed
///     ISO8601 date strategy) — never a plain `JSONEncoder()`.
///   - `tiles` and `zones` sorted by id (UUID string ascending, ties broken
///     the same way) BEFORE they reach this struct. `resolve(_:)` in
///     `OpLog.swift` is the only place that constructs a `MaterializedState`
///     from a fold, and it always emits pre-sorted arrays — do not hand-build
///     one elsewhere from unsorted/insertion-order collections.
/// If a future change adds a field to this struct, it must be deterministic
/// across replicas (no wall-clock, no hash-order dictionary, no random UUID)
/// or the I4 fuzz will produce false positives.
public struct MaterializedState: Codable, Equatable, Sendable {
    public var canvasState: CanvasState
    public var workspaceDocument: WorkspaceDocument

    public init(canvasState: CanvasState, workspaceDocument: WorkspaceDocument) {
        self.canvasState = canvasState
        self.workspaceDocument = workspaceDocument
    }

    /// The canonical byte encoding the I4 fuzz and the dogfood manifest
    /// compare — see the type-level doc above.
    public func canonicalEncoded() throws -> Data {
        try JSONCodec.makeOpLogEncoder().encode(self)
    }
}

/// Tracks the winning `(OpId, Value)` for one LWW register. A later `offer`
/// only takes effect if its `OpId` is strictly greater than the current
/// winner — this is what makes every scalar field independently
/// last-writer-wins, per D3.
private struct FieldTracker<Value> {
    var opId: OpId
    var value: Value

    mutating func offer(_ candidateOpId: OpId, _ candidateValue: Value) {
        if candidateOpId > opId {
            opId = candidateOpId
            value = candidateValue
        }
    }
}

/// Per-tile accumulator. Every scalar field is tracked independently (its own
/// `FieldTracker`), NOT as one shared "latest op wins for the whole tile"
/// register — a field-set for one field must not be shadowed by a later
/// op that only touched a different field.
private struct TileAccum {
    let id: UUID
    var frame: FieldTracker<TileFrame>
    var zPosition: FieldTracker<FracIndex>
    var title: FieldTracker<String>
    var kind: FieldTracker<TileKind>
    var zoneId: FieldTracker<UUID?>

    func build() -> Tile {
        Tile(
            id: id,
            kind: kind.value,
            title: title.value,
            frame: frame.value,
            zPosition: zPosition.value,
            zoneId: zoneId.value,
            // I5: the materialized tile never carries a host-local runtime
            // handle — the runtime layer rebinds it locally after load.
            runtimeRef: nil,
            metadata: TileMetadata()
        )
    }
}

/// Per-zone accumulator; same per-field LWW discipline as `TileAccum`.
private struct ZoneAccum {
    let id: UUID
    /// One LWW register for project + Home. They are an indivisible creation
    /// scope, never independently converging scalar fields.
    var scope: FieldTracker<ZoneScope>
    var origin: FieldTracker<ZonePoint>
    var size: FieldTracker<ZoneSize>
    var name: FieldTracker<String>
    var color: FieldTracker<String>
    var collapsed: FieldTracker<Bool>
    var autoLayoutMode: FieldTracker<ZoneAutoLayoutMode>
    var zPosition: FieldTracker<FracIndex>

    func build() -> ZonePlacement {
        ZonePlacement(
            zoneId: id,
            projectId: scope.value.projectId,
            homeRelativePath: scope.value.homeRelativePath,
            origin: origin.value,
            size: size.value,
            color: color.value,
            collapsed: collapsed.value,
            hydrationPolicy: .automatic,
            autoLayoutMode: autoLayoutMode.value,
            name: name.value,
            navKey: nil,
            zPosition: zPosition.value
        )
    }
}

/// State accumulated during the fold — internal to `materialize`.
private struct FoldState {
    // Tombstones: tile/zone ids for which a deleteTile/deleteZone was seen.
    // Populated in `apply`, consulted ONLY in `resolve` — see "Watch out" in
    // the ticket: removing the accumulator entry eagerly would let a
    // higher-Lamport concurrent field-set resurrect a deleted entity.
    var tombstonedTiles: Set<UUID> = []
    var tombstonedZones: Set<UUID> = []
    var tiles: [UUID: TileAccum] = [:]
    var zones: [UUID: ZoneAccum] = [:]
    var lastActiveTile: FieldTracker<UUID?>?
    var lastActiveZone: FieldTracker<UUID?>?
}

/// The public entry point. Accepts `[LoggedOp]` in ANY order, from any number
/// of replicas, and returns a deterministic `MaterializedState`.
public func materialize(ops: [LoggedOp]) -> MaterializedState {
    // 1. Sort: primary Lamport ascending, tie-break replica UUID ascending
    //    (OpId's own `<`, per SpatialOp.swift).
    let sorted = ops.sorted { $0.opId < $1.opId }

    // 2. Fold in total order.
    var state = FoldState()
    for logged in sorted {
        apply(logged, into: &state)
    }

    // 3. Resolve: drop tombstoned ids, assemble sorted final structs.
    return resolve(state)
}

private func apply(_ logged: LoggedOp, into state: inout FoldState) {
    let opId = logged.opId
    switch logged.op {
    case .createTile(let id, let kind, let title, let frame, let zPosition):
        // Add-wins: a fresh id never collides; re-delivery of the same
        // create is a no-op because the accumulator already exists. The
        // `tombstonedTiles` check guards a case a plain full-log fold never
        // hits (the original create's accumulator always persists, so a
        // later duplicate create already finds `state.tiles[id] != nil`) but
        // that a compaction-seeded fold DOES hit: `resolve()` drops
        // tombstoned ids from the resolved snapshot entirely, so
        // `FoldState(seeding:at:ledger:)` seeds no accumulator for them —
        // without this guard, a stale/re-delivered create in the tail would
        // find `state.tiles[id] == nil` and wrongly resurrect it.
        if state.tiles[id] == nil && !state.tombstonedTiles.contains(id) {
            state.tiles[id] = TileAccum(
                id: id,
                frame: FieldTracker(opId: opId, value: frame),
                zPosition: FieldTracker(opId: opId, value: zPosition),
                title: FieldTracker(opId: opId, value: title),
                kind: FieldTracker(opId: opId, value: kind),
                zoneId: FieldTracker(opId: opId, value: nil)
            )
        }

    case .deleteTile(let id):
        // Delete-wins: record the tombstone; do NOT touch the accumulator.
        // `resolve` drops the tile regardless of any higher-Lamport field-set
        // folded above — this ordering is the single most load-bearing
        // subtlety in this file (see ticket "Watch out").
        state.tombstonedTiles.insert(id)

    case .createZone(let id, let projectId, let origin, let size, let name, let color):
        // Same add-wins-plus-tombstone-guard discipline as `createTile` above.
        if state.zones[id] == nil && !state.tombstonedZones.contains(id) {
            state.zones[id] = ZoneAccum(
                id: id,
                scope: FieldTracker(opId: opId, value: ZoneScope(projectId: projectId)),
                origin: FieldTracker(opId: opId, value: origin),
                size: FieldTracker(opId: opId, value: size),
                name: FieldTracker(opId: opId, value: name),
                color: FieldTracker(opId: opId, value: color),
                collapsed: FieldTracker(opId: opId, value: false),
                autoLayoutMode: FieldTracker(opId: opId, value: .inherit),
                // createZone carries no initial position; a zone with no
                // setZonePosition ever applied stays at the same default
                // ZonePlacement's own memberwise init uses.
                zPosition: FieldTracker(opId: opId, value: .first)
            )
        }

    case .deleteZone(let id):
        state.tombstonedZones.insert(id)

    case .setTileFrame(let id, let frame):
        state.tiles[id]?.frame.offer(opId, frame)

    case .setTileZIndex(let id, let z):
        state.tiles[id]?.zPosition.offer(opId, z)

    case .setTileTitle(let id, let title):
        state.tiles[id]?.title.offer(opId, title)

    case .setTileKind(let id, let kind):
        state.tiles[id]?.kind.offer(opId, kind)

    case .setTileCollapsed:
        // `Tile` (unlike `ZonePlacement`) carries no `collapsed` field to
        // fold into — the op is accepted (never a decode/apply error, so log
        // replay never fails on it) but has no observable effect on the
        // materialized output. Every replica discards it identically, so
        // this does not threaten I4.
        break

    case .setZoneOrigin(let id, let origin):
        state.zones[id]?.origin.offer(opId, origin)

    case .setZoneSize(let id, let size):
        state.zones[id]?.size.offer(opId, size)

    case .setZoneName(let id, let name):
        state.zones[id]?.name.offer(opId, name)

    case .setZoneColor(let id, let color):
        state.zones[id]?.color.offer(opId, color)

    case .setZoneCollapsed(let id, let collapsed):
        state.zones[id]?.collapsed.offer(opId, collapsed)

    case .setZoneScope(let id, let projectId, let homeRelativePath):
        state.zones[id]?.scope.offer(
            opId,
            ZoneScope(projectId: projectId, homeRelativePath: homeRelativePath)
        )

    case .setZoneProjectId(let id, let projectId):
        // Legacy logs did not know Home. Treat the old operation as an atomic
        // root-Home scope write; new producers exclusively emit setZoneScope.
        state.zones[id]?.scope.offer(opId, ZoneScope(projectId: projectId))

    case .setZoneAutoLayoutMode(let id, let mode):
        state.zones[id]?.autoLayoutMode.offer(opId, mode)

    case .setZonePosition(let id, let position):
        state.zones[id]?.zPosition.offer(opId, position)

    case .setTileZone(let tileId, let zoneId):
        // LWW register ON the tile — "at most one zone" is automatic by
        // construction, not a post-merge repair.
        state.tiles[tileId]?.zoneId.offer(opId, zoneId)

    case .setLastActiveTile(let id):
        if var tracker = state.lastActiveTile {
            tracker.offer(opId, id)
            state.lastActiveTile = tracker
        } else {
            state.lastActiveTile = FieldTracker(opId: opId, value: id)
        }

    case .setLastActiveZone(let id):
        if var tracker = state.lastActiveZone {
            tracker.offer(opId, id)
            state.lastActiveZone = tracker
        } else {
            state.lastActiveZone = FieldTracker(opId: opId, value: id)
        }
    }
}

private func resolve(_ state: FoldState) -> MaterializedState {
    // Tiles: drop tombstoned ids, sort by id for canonical (I4) encoding.
    let liveTiles = state.tiles
        .filter { !state.tombstonedTiles.contains($0.key) }
        .map { $0.value.build() }
        .sorted { $0.id.uuidString < $1.id.uuidString }

    // Zones: drop tombstoned; sort by (zPosition, zoneId) — the same
    // stacking-order sort `WorkspaceDocument.zonesInZOrder` uses — so
    // canonical encoding order matches render/hit-test order.
    let liveZones = state.zones
        .filter { !state.tombstonedZones.contains($0.key) }
        .map { $0.value.build() }
        .sorted { lhs, rhs in
            if lhs.zPosition != rhs.zPosition { return lhs.zPosition < rhs.zPosition }
            return lhs.zoneId.uuidString < rhs.zoneId.uuidString
        }

    // Viewport is camera state, excluded from sync (locked D3) — the
    // materialized output always carries the synthetic default.
    let viewport = CanvasViewport(x: 0, y: 0, zoom: 1.0)

    let liveTileIds = Set(liveTiles.map(\.id))
    let resolvedLastActiveTile = state.lastActiveTile?.value.flatMap { liveTileIds.contains($0) ? $0 : nil }

    let liveZoneIds = Set(liveZones.map(\.zoneId))
    let resolvedLastActiveZone = state.lastActiveZone?.value.flatMap { liveZoneIds.contains($0) ? $0 : nil }

    // `WorkspaceDocument.ambientTiles` is documented (WorkspaceDocument.swift)
    // as THE authoritative store for ambient tiles — disjoint from any
    // project `CanvasState`, never a second copy of tiles that also live in
    // `canvasState.tiles`. The op log this ticket materializes has no notion
    // of "this tile belongs to the project canvas vs. the workspace canvas"
    // at all: `Op.createTile` produces exactly one flat tile set, which
    // becomes `canvasState.tiles` above in full (that flat set is what the
    // backend fixture round-trips against). There is therefore no
    // information in the op stream this fold could partition on to move a
    // subset of `liveTiles` into `ambientTiles` without duplicating that
    // tile in both stores — which is exactly the shape ticket 06's review
    // rejected (a downstream consumer persisting both `canvasState` and
    // `workspaceDocument` from one `MaterializedState` would double-persist
    // the same tile). So `ambientTiles` is left empty here, matching the
    // ticket's own `resolve()` breadcrumb (`WorkspaceDocument( /* zones
    // assembled here */ )` — tiles were never part of that breadcrumb).
    // Deciding how the op stream maps tiles to the workspace-vs-project
    // scoping `ambientTiles` requires is out of this ticket's scope (see the
    // sync/observation type split ticket); `runMaterializeInvariantChecks`
    // pins this as an explicit invariant so a future change to this
    // decision is a deliberate, reviewed one rather than a silent drift.
    let ambientTiles: [Tile] = []

    return MaterializedState(
        canvasState: CanvasState(
            schemaVersion: CanvasState.currentSchemaVersion,
            viewport: viewport,
            tiles: liveTiles,
            // Groups are legacy list-membership (`TileGroup.tileIds`); the
            // op log carries no createGroup/setGroupScalar ops (membership is
            // the tile-level `zoneId` register per ticket 03), so this is
            // always empty in the materialized output.
            groups: [],
            lastActiveTileId: resolvedLastActiveTile
        ),
        workspaceDocument: WorkspaceDocument(
            schemaVersion: WorkspaceDocument.currentSchemaVersion,
            viewport: viewport,
            zones: liveZones,
            lastActiveZoneId: resolvedLastActiveZone,
            ambientTiles: ambientTiles
        )
    )
}

// MARK: - Composing a snapshot with a tail (compaction primitive)

extension FoldState {
    /// Seeds a fold from an already-materialized state (typically a
    /// `CompactedSnapshot.state`) instead of from ops. Every field is seeded
    /// at `baseOpId` — the highest `OpId` folded into `base` — which is
    /// always safe: `compact` guarantees every op in the tail that gets
    /// folded on top has a strictly greater `OpId` than `baseOpId` (its
    /// Lamport is, by construction, above the low-water mark `base` was
    /// taken through), so a tail write always outranks the seeded value
    /// without needing to know the *real* per-field winning `OpId` from
    /// before compaction.
    /// `ledger` is the `CompactionLedger` (ticket 05's data type, populated by
    /// `compact` — ticket 06's compactor) carried forward from the
    /// compaction that produced `base`. `resolve()` drops tombstoned ids from
    /// `base` entirely, so without seeding `tombstonedTiles`/`tombstonedZones`
    /// from the ledger here, a stale/re-delivered create for one of those ids
    /// arriving in the tail would find no accumulator and wrongly resurrect
    /// it — the exact "compaction discards tombstones" hazard ticket 05
    /// flagged for this ticket to close.
    init(seeding base: MaterializedState, at baseOpId: OpId, ledger: CompactionLedger) {
        self.init()
        for record in ledger.records {
            switch record.entityKind {
            case .tile: tombstonedTiles.insert(record.entityId)
            case .zone: tombstonedZones.insert(record.entityId)
            }
        }
        for tile in base.canvasState.tiles {
            tiles[tile.id] = TileAccum(
                id: tile.id,
                frame: FieldTracker(opId: baseOpId, value: tile.frame),
                zPosition: FieldTracker(opId: baseOpId, value: tile.zPosition),
                title: FieldTracker(opId: baseOpId, value: tile.title),
                kind: FieldTracker(opId: baseOpId, value: tile.kind),
                zoneId: FieldTracker(opId: baseOpId, value: tile.zoneId)
            )
        }
        for zone in base.workspaceDocument.zones {
            zones[zone.zoneId] = ZoneAccum(
                id: zone.zoneId,
                scope: FieldTracker(opId: baseOpId, value: zone.scope),
                origin: FieldTracker(opId: baseOpId, value: zone.origin),
                size: FieldTracker(opId: baseOpId, value: zone.size),
                name: FieldTracker(opId: baseOpId, value: zone.name),
                color: FieldTracker(opId: baseOpId, value: zone.color),
                collapsed: FieldTracker(opId: baseOpId, value: zone.collapsed),
                autoLayoutMode: FieldTracker(opId: baseOpId, value: zone.autoLayoutMode),
                zPosition: FieldTracker(opId: baseOpId, value: zone.zPosition)
            )
        }
        if let lastTile = base.canvasState.lastActiveTileId {
            lastActiveTile = FieldTracker(opId: baseOpId, value: lastTile)
        }
        if let lastZone = base.workspaceDocument.lastActiveZoneId {
            lastActiveZone = FieldTracker(opId: baseOpId, value: lastZone)
        }
    }
}

/// Folds `tail` on top of an already-materialized `base` state — the
/// primitive the ticket's merge-equivalence claim ("a replica ... replaces
/// its local state up to the mark and appends the tail ops it held above
/// it") actually requires. Without this, a snapshot's `state` cannot be
/// composed with a tail at all: `materialize` only accepts `[LoggedOp]`, and
/// `state` is already-folded structs, not ops. `base` should be a
/// `CompactedSnapshot.state`, `baseOpId` its `compactionOpId`, and `ledger`
/// its `CompactionLedger` — required, not defaulted, so a caller can never
/// silently drop the tombstone ledger a real snapshot always carries.
public func materialize(onto base: MaterializedState, baseOpId: OpId, ledger: CompactionLedger, tail: [LoggedOp]) -> MaterializedState {
    var state = FoldState(seeding: base, at: baseOpId, ledger: ledger)
    for logged in tail.sorted(by: { $0.opId < $1.opId }) {
        apply(logged, into: &state)
    }
    return resolve(state)
}
