import CoreGraphics
import Foundation
import ContinuumRevivedCore

// .plans/107-auto-layout-fanout: a replay probe, not a witness. It drives the
// production Core solvers (`TileSpawnPlacement.automatic`,
// `CanvasAutoLayoutEngine.solve`) through a faithful copy of the app glue that
// calls them (`spawnPlacementBesideParent`, `arrangeAutoLayoutAfterSpawn`,
// `expandZoneToContainMembers`, the live-drag latch feedback and
// `settleAutoLayoutAfterMove`), records every frame, and counts what moved.
// Candidate layout models run the same scripted scenarios for comparison.
//
// Usage: ContinuumRevivedCoreChecks --fanout-layout-probe [<out dir>]

enum FanoutGeometry {
    static let gap = 8.0
    static let padding = 24.0
    static let header = 34.0
    static let screen = CGSize(width: 1512, height: 945)
    static let zoom = 0.55
}

struct FanoutTile {
    var id: UUID
    var name: String
    var kind: TileKind
    var frame: TileFrame
    var parent: UUID?
    /// Model-owned slot bookkeeping (lead-cluster template index, grid cell).
    var slot: Int? = nil
    var cell: [Int]? = nil
}

struct FanoutState {
    var tiles: [FanoutTile]
    var zone: ZonePlacement
    var view: TileFrame

    func frame(_ id: UUID) -> TileFrame? { tiles.first { $0.id == id }?.frame }
    mutating func setFrame(_ id: UUID, _ frame: TileFrame) {
        if let index = tiles.firstIndex(where: { $0.id == id }) { tiles[index].frame = frame }
    }
    func tile(named name: String) -> FanoutTile? { tiles.first { $0.name == name } }
    func excluding(_ ids: Set<UUID>) -> FanoutState {
        var copy = self
        copy.tiles.removeAll { ids.contains($0.id) }
        return copy
    }

    var scene: CanvasAutoLayoutEngine.Scene {
        CanvasAutoLayoutEngine.Scene(
            tiles: tiles.map { CanvasAutoLayoutEngine.LayoutTile(id: $0.id, frame: $0.frame, zoneId: zone.zoneId,
                                                                 minimumSize: CanvasEngine.minimumFrame(for: $0.kind)) },
            zones: [zone])
    }

    mutating func apply(_ transaction: CanvasLayoutTransaction) {
        for (id, frame) in transaction.tileFrames { setFrame(id, frame) }
        if let placement = transaction.zonePlacements[zone.zoneId] { zone = placement }
    }

    /// `expandZoneToContainMembers`: grow to the padded member envelope, never shrink.
    mutating func expandZone() {
        guard !tiles.isEmpty else { return }
        let minX = tiles.map(\.frame.x).min()!, minY = tiles.map(\.frame.y).min()!
        let maxX = tiles.map { $0.frame.x + $0.frame.width }.max()!
        let maxY = tiles.map { $0.frame.y + $0.frame.height }.max()!
        let left = min(zone.origin.x, minX - FanoutGeometry.padding)
        let top = min(zone.origin.y, minY - FanoutGeometry.header - FanoutGeometry.padding)
        let right = max(zone.origin.x + zone.size.width, maxX + FanoutGeometry.padding)
        let bottom = max(zone.origin.y + zone.size.height, maxY + FanoutGeometry.padding)
        zone.origin = ZonePoint(x: left, y: top)
        zone.size = ZoneSize(width: right - left, height: bottom - top)
    }

    /// Camera centred on a world point at the probe zoom.
    static func view(centredOn point: CGPoint) -> TileFrame {
        let w = Double(FanoutGeometry.screen.width) / FanoutGeometry.zoom
        let h = Double(FanoutGeometry.screen.height) / FanoutGeometry.zoom
        return TileFrame(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
    }
}

/// One frame of a recorded run.
struct FanoutFrame: Codable {
    struct T: Codable { var id: String; var name: String; var kind: String; var x, y, w, h: Double; var parent: String? }
    var label: String
    var tiles: [T]
    var zone: [Double]
    var view: [Double]
    var active: String?
    var latch: String?
    var slot: [Double]?
    var pointer: [Double]?
}

struct FanoutRun: Codable {
    var model: String
    var scenario: String
    var frames: [FanoutFrame]
    var metrics: [String: Double]
    var notes: [String]
}

/// A drag script: cumulative pointer displacement per frame from the grab point.
struct FanoutDrag {
    var tileName: String
    var steps: [CGVector]
}

protocol FanoutLayoutModel {
    var name: String { get }
    /// Dragging a lead carries its helpers (lead-cluster model).
    var carriesHelpers: Bool { get }
    /// Spawn `tile` (its frame carries only the size); `parent` is the lead it pops out beside.
    func spawn(_ state: inout FanoutState, _ tile: FanoutTile)
    /// Replay a drag; returns one state per pointer frame plus the post-drop state.
    func drag(_ state: FanoutState, active: UUID, grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)]
}

// MARK: - The shipped model (array/release-0735)

struct ShippedLayoutModel: FanoutLayoutModel {
    /// The production path: the shipped Core solvers through the app glue.
    var name = "production"
    /// Drag snapping, on by default in production (`DragMagnetizeConfig`).
    var magnetOn = true
    /// Model B: a lead's drag carries its helpers (CanvasTileSelection carry).
    var carriesHelpers: Bool { true }

    func spawn(_ state: inout FanoutState, _ tile: FanoutTile) {
        var size = CGSize(width: tile.frame.width, height: tile.frame.height)
        // spawnPlacementBesideParent under auto layout: a helper is its lead's
        // width and half its height (never below an agent's minimum).
        if let parent = tile.parent, let lead = state.frame(parent) {
            let minimum = CanvasEngine.minimumFrame(for: .managedAgent)
            size = CGSize(width: max(Double(minimum.width), lead.width),
                          height: max(Double(minimum.height), (lead.height - FanoutGeometry.gap) / 2))
        }
        var placed: TileFrame
        if state.tiles.isEmpty {
            placed = TileFrame(x: state.zone.origin.x + FanoutGeometry.padding,
                               y: state.zone.origin.y + FanoutGeometry.header + FanoutGeometry.padding,
                               width: size.width, height: size.height)
        } else if let parent = tile.parent, let slot = fannedBesideParent(state, parent: parent, size: size) {
            // makeProjectTilePlacement(worldPoint:) centres the size on the slot's centre.
            placed = TileFrame(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                               width: size.width, height: size.height)
        } else {
            placed = automatic(state, size: size)
        }
        var new = tile
        new.frame = placed
        state.tiles.append(new)
        guard state.tiles.count > 1 else { state.expandZone(); return }
        // arrangeAutoLayoutAfterSpawn: settle(grow) with the spawned tile as anchor,
        // then expand(rounding) around wherever it settled.
        let transaction = CanvasAutoLayoutEngine.solve(
            scene: state.scene,
            mutation: .settle(zoneId: state.zone.zoneId, anchor: tile.id, pin: false, grow: true, view: state.view),
            gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding, headerHeight: FanoutGeometry.header)
        state.apply(transaction)
        state.expandZone()
    }

    /// CanvasTileSelection's carry: the lead and its helpers move as one group
    /// through TileSelectionPlacement, and settle as one at the drop.
    private func carry(_ state: FanoutState, ids: [UUID], grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)] {
        let baseline = state.scene
        var latch: CanvasAutoLayoutEngine.MoveLatch?
        var out: [(FanoutState, String?, TileFrame?)] = []
        var live = state
        var previousStep = CGVector(dx: 0, dy: 0)
        for step in steps {
            let speed = hypot(step.dx - previousStep.dx, step.dy - previousStep.dy) * FanoutGeometry.zoom * 60
            previousStep = step
            var frames: [UUID: TileFrame] = [:]
            for id in ids {
                if let f = state.frame(id) { frames[id] = TileFrame(x: f.x + step.dx, y: f.y + step.dy, width: f.width, height: f.height) }
            }
            let t = TileSelectionPlacement.solve(
                scene: baseline, frames: frames, gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding,
                headerHeight: FanoutGeometry.header, latched: latch, pointer: CGPoint(x: grab.x + step.dx, y: grab.y + step.dy),
                pointerSpeed: speed, previousFrames: Dictionary(uniqueKeysWithValues: live.tiles.map { ($0.id, $0.frame) }),
                latching: false)
            latch = t.moveLatch
            live = state
            live.apply(t)
            out.append((live, latch.map { "\($0)" }, t.latchedSlot))
        }
        var dropped = live
        // settleSelectionAfterMove: an unlatched group drop relaxes the pushes.
        if latch == nil {
            for tile in state.tiles where !ids.contains(tile.id) { dropped.setFrame(tile.id, tile.frame) }
        }
        dropped.expandZone()
        let frames = Dictionary(uniqueKeysWithValues: ids.compactMap { id in dropped.frame(id).map { (id, $0) } })
        dropped.apply(TileSelectionPlacement.solve(
            scene: dropped.scene, frames: frames, gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding,
            headerHeight: FanoutGeometry.header, settle: true))
        out.append((dropped, "drop", nil))
        return out
    }

    /// AppDelegate.spawnPlacementBesideParent under auto layout (.plans/107):
    /// fan out around the lead and its other helpers, in WORLD frames.
    private func fannedBesideParent(_ state: FanoutState, parent: UUID, size: CGSize) -> CGRect? {
        guard let lead = state.frame(parent) else { return nil }
        let hosts = [lead] + state.tiles.filter { $0.parent == parent }.map(\.frame)
        let placed = TileSpawnPlacement.automatic(TileSpawnPlacement.Context(
            newSize: size,
            viewport: CanvasViewport(x: state.view.x, y: state.view.y, zoom: FanoutGeometry.zoom),
            visibleSize: FanoutGeometry.screen,
            siblings: state.tiles.map { Tile(id: $0.id, kind: $0.kind, title: $0.name, frame: $0.frame,
                                             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata()) },
            gap: FanoutGeometry.gap,
            fanOut: TileSpawnPlacement.FanOut(
                hosts: hosts, targetAspect: Double(FanoutGeometry.screen.width / FanoutGeometry.screen.height),
                focus: CGPoint(x: lead.x + lead.width / 2, y: lead.y + lead.height / 2))))
        return CGRect(x: placed.x, y: placed.y, width: placed.width, height: placed.height)
    }

    /// The pre-.plans/107 column scan, kept for reference.
    private func besideParent(_ state: FanoutState, parent: UUID, size: CGSize) -> CGRect? {
        guard let p = state.frame(parent) else { return nil }
        let gap = FanoutGeometry.gap
        let zoneRect = CGRect(x: state.zone.origin.x, y: state.zone.origin.y,
                              width: state.zone.size.width, height: state.zone.size.height)
        let occupied = state.tiles.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
        var column = CGRect(x: p.x + p.width + gap, y: p.y, width: size.width, height: size.height)
        while zoneRect.contains(column) {
            var slot = column
            while zoneRect.contains(slot) {
                if !occupied.contains(where: { $0.intersects(slot) }) { return slot }
                slot.origin.y += size.height + gap
            }
            column.origin.x += size.width + gap
        }
        return nil
    }

    /// TileSpawner.makeProjectTilePlacement, layer branch, auto layout on.
    private func automatic(_ state: FanoutState, size: CGSize) -> TileFrame {
        let zone = state.zone
        var localX = state.view.x - zone.origin.x, localY = state.view.y - zone.origin.y
        let overlaps = localX < zone.size.width && localX + state.view.width > 0
            && localY < zone.size.height && localY + state.view.height > 0
        if !overlaps { localX = 0; localY = 0 }
        let siblings = state.tiles.map {
            Tile(id: $0.id, kind: $0.kind, title: $0.name,
                 frame: TileFrame(x: $0.frame.x - zone.origin.x, y: $0.frame.y - zone.origin.y,
                                  width: $0.frame.width, height: $0.frame.height),
                 zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        }
        let local = TileSpawnPlacement.automatic(TileSpawnPlacement.Context(
            newSize: size,
            viewport: CanvasViewport(x: localX, y: localY, zoom: FanoutGeometry.zoom),
            visibleSize: FanoutGeometry.screen,
            siblings: siblings, gap: FanoutGeometry.gap, bounds: nil,
            fanOut: TileSpawnPlacement.FanOut(
                hosts: siblings.map(\.frame),
                targetAspect: Double(FanoutGeometry.screen.width / FanoutGeometry.screen.height))))
        return TileFrame(x: local.x + zone.origin.x, y: local.y + zone.origin.y, width: local.width, height: local.height)
    }

    func drag(_ state: FanoutState, active: UUID, grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)] {
        guard let start = state.frame(active) else { return [] }
        let helpers = state.tiles.filter { $0.parent == active }.map(\.id)
        if !helpers.isEmpty { return carry(state, ids: [active] + helpers, grab: grab, steps: steps) }
        // A helper is scoped to its lead's cluster (CanvasNSView.applyAutoLayout).
        let scope: Set<UUID>? = state.tiles.first { $0.id == active }?.parent.map { lead in
            Set(state.tiles.filter { $0.parent == lead }.map(\.id))
        }
        let baseline = state.scene
        var latch: CanvasAutoLayoutEngine.MoveLatch?
        var slot: TileFrame?
        var out: [(FanoutState, String?, TileFrame?)] = []
        var live = state
        var previous = CGVector(dx: 0, dy: 0)
        var lastRequested = start
        var magnet: MagneticPlacement.Target?
        let others = state.tiles.filter { $0.id != active }.map { MagneticPlacement.Neighbor(id: $0.id, frame: $0.frame) }
        for step in steps {
            let free = TileFrame(x: start.x + step.dx, y: start.y + step.dy, width: start.width, height: start.height)
            // TileNSView: unlatched, the magnet places the tile; latched, the latch owns it.
            var requested = free
            if slot == nil, magnetOn {
                let placed = MagneticPlacement.resolve(free: free, neighbors: others, previous: magnet,
                                                       gap: FanoutGeometry.gap, zoom: FanoutGeometry.zoom)
                // TileNSView: the magnet pulls only within the release distance.
                let pull = max(abs(placed.frame.x - free.x), abs(placed.frame.y - free.y))
                requested = pull <= DragMagnetizeConfig.snapReleaseScreenPoints / FanoutGeometry.zoom ? placed.frame : free
                magnet = placed.target
            } else {
                magnet = nil
            }
            lastRequested = requested
            // CanvasNSView.setAutoLayoutMovePointer: screen points per second at 60 fps.
            let speed = hypot(step.dx - previous.dx, step.dy - previous.dy) * FanoutGeometry.zoom * 60
            previous = step
            let transaction = CanvasAutoLayoutEngine.solve(
                scene: baseline, mutation: .tile(id: active, frame: requested),
                gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding, headerHeight: FanoutGeometry.header,
                latched: latch, pointer: CGPoint(x: grab.x + step.dx, y: grab.y + step.dy), pointerSpeed: speed,
                previousFrames: Dictionary(uniqueKeysWithValues: live.tiles.map { ($0.id, $0.frame) }),
                interactive: scope)
            latch = transaction.moveLatch
            slot = transaction.latchedSlot
            // applyAutoLayout applies absolutely: unlisted means "at baseline".
            live = state
            live.apply(transaction)
            out.append((live, latchName(latch, state), slot))
        }
        // TileNSView.mouseUp commits the previewed magnet target (honorSnap);
        // otherwise settleAutoLayoutAfterMove re-solves the release at rest.
        let snapTarget = slot == nil ? magnet?.frame : nil
        if snapTarget == nil, let last = steps.last {
            let transaction = CanvasAutoLayoutEngine.solve(
                scene: baseline, mutation: .tile(id: active, frame: lastRequested),
                gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding, headerHeight: FanoutGeometry.header,
                latched: latch, pointer: CGPoint(x: grab.x + last.dx, y: grab.y + last.dy), interactive: scope)
            latch = transaction.moveLatch
            slot = transaction.latchedSlot
            live = state
            live.apply(transaction)
        }
        var dropped = live
        // An unlatched drop relaxes the drag's pushes.
        if latch == nil {
            for tile in state.tiles where tile.id != active { dropped.setFrame(tile.id, tile.frame) }
        }
        var pinned = false
        if let snapTarget {
            dropped.setFrame(active, snapTarget)
            pinned = true
        } else if latch != nil, let slot {
            dropped.setFrame(active, TileFrame(x: slot.x, y: slot.y, width: start.width, height: start.height))
            pinned = true
        }
        if let frame = dropped.frame(active), dropped.tiles.contains(where: {
            $0.id != active && CanvasAutoLayoutEngine.isGapAdjacent(frame, $0.frame, gap: FanoutGeometry.gap, tolerance: 6)
        }) {
            dropped.expandZone()
        }
        let settle = CanvasAutoLayoutEngine.solve(
            scene: dropped.scene, mutation: .settle(zoneId: dropped.zone.zoneId, anchor: active, pin: pinned),
            gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding, headerHeight: FanoutGeometry.header)
        dropped.apply(settle)
        out.append((dropped, "drop", nil))
        return out
    }

    private func latchName(_ latch: CanvasAutoLayoutEngine.MoveLatch?, _ state: FanoutState) -> String? {
        switch latch {
        case let .swap(id)?: return "swap " + (state.tiles.first { $0.id == id }?.name ?? "?")
        case let .insert(row, index)?: return "insert r\(row) i\(index)"
        case nil: return nil
        }
    }
}

// MARK: - Scenarios and metrics

enum FanoutScenarios {
    static let zoneId = UUID(uuidString: "F0F00000-0000-4000-8000-000000000001")!

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "F0F00000-0000-4000-8000-%012d", 100 + n))! }

    static func size(_ kind: TileKind) -> TileFrame {
        let s = CanvasEngine.defaultFrame(for: kind)
        return TileFrame(x: 0, y: 0, width: Double(s.width), height: Double(s.height))
    }

    static func emptyState() -> FanoutState {
        let zone = ZonePlacement(
            zoneId: zoneId, projectId: nil, origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 640 + 2 * FanoutGeometry.padding,
                           height: 520 + FanoutGeometry.header + 2 * FanoutGeometry.padding),
            color: "teal", collapsed: false, hydrationPolicy: .automatic)
        let lead = TileFrame(x: FanoutGeometry.padding, y: FanoutGeometry.header + FanoutGeometry.padding, width: 640, height: 520)
        return FanoutState(tiles: [], zone: zone,
                           view: FanoutState.view(centredOn: CGPoint(x: lead.x + lead.width / 2, y: lead.y + lead.height / 2)))
    }

    /// Lead plus three helpers popping out beside it.
    static func leadAndHelpers() -> [FanoutTile] {
        let lead = FanoutTile(id: id(1), name: "Lead", kind: .managedAgent, frame: size(.managedAgent), parent: nil)
        return [lead] + (1...3).map {
            FanoutTile(id: id(1 + $0), name: "H\($0)", kind: .managedAgent, frame: size(.managedAgent), parent: lead.id)
        }
    }

    /// Six more ordinary spawns with the camera unchanged: what a working zone becomes.
    static func workingZoneExtras() -> [FanoutTile] {
        let kinds: [(String, TileKind)] = [("Term", .terminal), ("Note", .note), ("Web", .browser),
                                           ("Edit", .file), ("Tree", .fileTree), ("Diff", .diffReview)]
        return kinds.enumerated().map { FanoutTile(id: id(10 + $0.offset), name: $0.element.0, kind: $0.element.1,
                                                   frame: size($0.element.1), parent: nil) }
    }

    /// A human drag: eased ramp with a slow hover in the middle and hand jitter.
    static func ramp(dx: Double, dy: Double, frames: Int = 72, jitter: Double = 5) -> [CGVector] {
        (1...frames).map { i in
            let t = Double(i) / Double(frames)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let j = jitter * sin(Double(i) * 1.7) + jitter * 0.5 * sin(Double(i) * 0.43)
            return CGVector(dx: dx * eased + j * 0.4, dy: dy * eased + j)
        }
    }
}

struct FanoutMetrics {
    /// Counts per drag frame (excluding the dragged tile), then the drop.
    static func drag(_ before: FanoutState, _ frames: [(FanoutState, String?, TileFrame?)], active: UUID, carried: Set<UUID> = []) -> [String: Double] {
        // Tiles a model deliberately carries with the active one (a lead's
        // helpers) are part of the gesture, not bystanders.
        let before = before.excluding(carried)
        let frames = frames.map { ($0.0.excluding(carried), $0.1, $0.2) }
        var m: [String: Double] = [:]
        var previous = before
        var previousLatch: String?
        var movedPerFrame: [Int] = []
        var jumps = 0, latchFlips = 0, displacedMax = 0, unexplained = 0, teleports = 0
        let home = before.frame(active)
        let dragFrames = frames.dropLast()
        for (state, latch, _) in dragFrames {
            var moved = 0
            for tile in state.tiles where tile.id != active {
                guard let a = previous.frame(tile.id) else { continue }
                let d = max(abs(a.x - tile.frame.x), abs(a.y - tile.frame.y))
                if d > 0.5 { moved += 1 }
                if d > min(tile.frame.width, tile.frame.height) / 2 {
                    jumps += 1
                    // A swap or slide-in moves tiles in one step on purpose, in the
                    // frame its latch changes. Any other big step is a teleport.
                    if latch == previousLatch { unexplained += 1 }
                }
                // Even a swap may only bring a tile from (near) where it rests to
                // the dragged tile's home: a tile pushed far away and then swapped
                // back across the zone is the teleport Dylan saw.
                if let home, let rest = before.frame(tile.id) {
                    let allowed = hypot(rest.x - home.x, rest.y - home.y) + max(rest.width, rest.height) / 4 + 1
                    if d > allowed { teleports += 1 }
                }
            }
            displacedMax = max(displacedMax, state.tiles.filter { t in
                t.id != active && before.frame(t.id).map { $0 != t.frame } == true }.count)
            if latch != previousLatch { latchFlips += 1 }
            previousLatch = latch
            movedPerFrame.append(moved)
            previous = state
        }
        m["frames"] = Double(movedPerFrame.count)
        m["moved_per_frame_mean"] = movedPerFrame.isEmpty ? 0 : Double(movedPerFrame.reduce(0, +)) / Double(movedPerFrame.count)
        m["moved_per_frame_max"] = Double(movedPerFrame.max() ?? 0)
        m["frames_with_motion"] = Double(movedPerFrame.filter { $0 > 0 }.count)
        m["false_jumps"] = Double(jumps)
        m["unexplained_jumps"] = Double(unexplained)
        m["teleports"] = Double(teleports)
        m["latch_changes"] = Double(latchFlips)
        m["displaced_at_once_max"] = Double(displacedMax)
        if let last = dragFrames.last?.0, let drop = frames.last?.0 {
            var dropMoved = 0, dropJumps = 0, finalDisplaced = 0, laneChanges = 0, strays = 0
            let lastLatch = dragFrames.last?.1
            var maxShift = 0.0
            for tile in drop.tiles where tile.id != active {
                if let a = last.frame(tile.id) {
                    let d = max(abs(a.x - tile.frame.x), abs(a.y - tile.frame.y))
                    if d > 0.5 { dropMoved += 1 }
                    if d > min(tile.frame.width, tile.frame.height) / 2 { dropJumps += 1 }
                    // At the release a bystander stays, or returns to rest; only a
                    // latched swap partner or slide-in neighbour may land elsewhere.
                    // A nudge that keeps the gap from what was dropped is not a jump.
                    if let r = before.frame(tile.id), lastLatch == nil,
                       d > min(tile.frame.width, tile.frame.height) / 4,
                       max(abs(tile.frame.x - r.x), abs(tile.frame.y - r.y)) > min(r.width, r.height) / 4 { strays += 1 }
                }
                if let b = before.frame(tile.id) {
                    let d = hypot(b.x - tile.frame.x, b.y - tile.frame.y)
                    if d > 0.5 { finalDisplaced += 1 }
                    maxShift = max(maxShift, d)
                    if abs((b.y + b.height / 2) - (tile.frame.y + tile.frame.height / 2)) > b.height / 2 { laneChanges += 1 }
                }
            }
            m["drop_moved"] = Double(dropMoved)
            m["drop_strays"] = Double(strays)
            m["drop_jumps"] = Double(dropJumps)
            m["final_displaced"] = Double(finalDisplaced)
            m["final_lane_changes"] = Double(laneChanges)
            m["final_max_shift"] = maxShift.rounded()
            m["overlaps_after_drop"] = Double(overlaps(drop))
        }
        return m
    }

    static func shape(_ state: FanoutState) -> [String: Double] {
        let f = state.tiles.map(\.frame)
        guard let minX = f.map(\.x).min(), let maxX = f.map({ $0.x + $0.width }).max(),
              let minY = f.map(\.y).min(), let maxY = f.map({ $0.y + $0.height }).max() else { return [:] }
        var m: [String: Double] = [:]
        m["envelope_w"] = (maxX - minX).rounded()
        m["envelope_h"] = (maxY - minY).rounded()
        m["aspect_w_over_h"] = ((maxX - minX) / max(1, maxY - minY) * 100).rounded() / 100
        // How much of a 16:10 screen the envelope fills when fitted: 1 = perfect.
        let fit = min(Double(FanoutGeometry.screen.width) / (maxX - minX), Double(FanoutGeometry.screen.height) / (maxY - minY))
        m["screen_fill"] = (((maxX - minX) * (maxY - minY) * fit * fit)
                            / Double(FanoutGeometry.screen.width * FanoutGeometry.screen.height) * 100).rounded() / 100
        m["rows"] = Double(rowCount(f))
        if let lead = state.tiles.first {
            let helpers = state.tiles.filter { $0.parent == lead.id }
            let touching = helpers.filter { CanvasAutoLayoutEngine.isGapAdjacent($0.frame, lead.frame, gap: FanoutGeometry.gap, tolerance: 1) }
            m["helpers_touching_lead"] = Double(touching.count)
            let c = { (t: TileFrame) in CGPoint(x: t.x + t.width / 2, y: t.y + t.height / 2) }
            let lc = c(lead.frame)
            let d = helpers.map { hypot(c($0.frame).x - lc.x, c($0.frame).y - lc.y) }
            m["helper_to_lead_mean"] = d.isEmpty ? 0 : (d.reduce(0, +) / Double(d.count)).rounded()
        }
        m["overlaps"] = Double(overlaps(state))
        return m
    }

    static func rowCount(_ frames: [TileFrame]) -> Int {
        var rows = 0, bottom = -Double.infinity
        for f in frames.sorted(by: { $0.y < $1.y }) {
            if f.y >= bottom - 0.5 { rows += 1; bottom = f.y + f.height } else { bottom = max(bottom, f.y + f.height) }
        }
        return rows
    }

    static func overlaps(_ state: FanoutState) -> Int {
        var n = 0
        for (i, a) in state.tiles.enumerated() {
            for b in state.tiles.dropFirst(i + 1) {
                let fa = a.frame, fb = b.frame
                if fa.x < fb.x + fb.width - 0.5 && fb.x < fa.x + fa.width - 0.5
                    && fa.y < fb.y + fb.height - 0.5 && fb.y < fa.y + fa.height - 0.5 { n += 1 }
            }
        }
        return n
    }
}

// MARK: - Recording

func fanoutFrame(_ state: FanoutState, label: String, active: UUID? = nil, latch: String? = nil,
                 slot: TileFrame? = nil, pointer: CGPoint? = nil) -> FanoutFrame {
    FanoutFrame(
        label: label,
        tiles: state.tiles.map { FanoutFrame.T(id: $0.id.uuidString, name: $0.name, kind: $0.kind.rawValue,
                                              x: $0.frame.x, y: $0.frame.y, w: $0.frame.width, h: $0.frame.height,
                                              parent: $0.parent?.uuidString) },
        zone: [state.zone.origin.x, state.zone.origin.y, state.zone.size.width, state.zone.size.height],
        view: [state.view.x, state.view.y, state.view.width, state.view.height],
        active: active?.uuidString, latch: latch,
        slot: slot.map { [$0.x, $0.y, $0.width, $0.height] },
        pointer: pointer.map { [$0.x, $0.y] })
}

/// Spawn `tiles` one by one, then run `drag`. One run per model per scenario.
func fanoutRun(model: FanoutLayoutModel, scenario: String, spawns: [FanoutTile], drag: FanoutDrag?,
               cameraFollows: Bool = false) -> FanoutRun {
    var state = FanoutScenarios.emptyState()
    var frames: [FanoutFrame] = []
    var notes: [String] = []
    frames.append(fanoutFrame(state, label: "empty"))
    for tile in spawns {
        model.spawn(&state, tile)
        if cameraFollows, let f = state.frame(tile.id) {
            state.view = FanoutState.view(centredOn: CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2))
        }
        frames.append(fanoutFrame(state, label: "spawn \(tile.name)", active: tile.id))
        if let f = state.frame(tile.id) { notes.append(String(format: "spawn %@ at (%.0f, %.0f)", tile.name, f.x, f.y)) }
    }
    var metrics = FanoutMetrics.shape(state).mapKeys { "spawn." + $0 }
    if let drag, let tile = state.tile(named: drag.tileName) {
        let grab = CGPoint(x: tile.frame.x + tile.frame.width / 2, y: tile.frame.y + 18)
        let replay = model.drag(state, active: tile.id, grab: grab, steps: drag.steps)
        for (index, (s, latch, slot)) in replay.enumerated() {
            let step = index < drag.steps.count ? drag.steps[index] : drag.steps.last!
            frames.append(fanoutFrame(s, label: index < drag.steps.count ? "drag \(index)" : "drop",
                                      active: tile.id, latch: latch, slot: slot,
                                      pointer: CGPoint(x: grab.x + step.dx, y: grab.y + step.dy)))
        }
        let carried = model.carriesHelpers ? Set(state.tiles.filter { $0.parent == tile.id }.map(\.id)) : []
        for (k, v) in FanoutMetrics.drag(state, replay, active: tile.id, carried: carried) { metrics["drag." + k] = v }
        // How far the dragged tile itself sits from where the pointer puts it.
        var lag = 0.0
        for (index, step) in drag.steps.enumerated() where index < replay.count - 1 {
            guard let f = replay[index].0.frame(tile.id) else { continue }
            lag = max(lag, abs(f.x - (tile.frame.x + step.dx)), abs(f.y - (tile.frame.y + step.dy)))
        }
        metrics["drag.active_lag_max"] = lag.rounded()
        if let final = replay.last?.0 {
            for (k, v) in FanoutMetrics.shape(final) { metrics["after." + k] = v }
        }
    }
    return FanoutRun(model: model.name, scenario: scenario, frames: frames, metrics: metrics, notes: notes)
}

extension Dictionary {
    func mapKeys<K: Hashable>(_ transform: (Key) -> K) -> [K: Value] {
        Dictionary<K, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

/// A row of six agents already in a zone (a canvas made before .plans/107):
/// pulling one out must not close its hole by sliding the rest along.
func fanoutSeededRow() -> FanoutState {
    var state = FanoutScenarios.emptyState()
    let y = FanoutGeometry.header + FanoutGeometry.padding
    for i in 0..<6 {
        let x = FanoutGeometry.padding + Double(i) * (640 + FanoutGeometry.gap)
        state.tiles.append(FanoutTile(id: FanoutScenarios.id(40 + i), name: "R\(i)", kind: .managedAgent,
                                      frame: TileFrame(x: x, y: y, width: 640, height: 520), parent: nil))
    }
    state.zone.size = ZoneSize(width: 6 * 648 - 8 + 2 * FanoutGeometry.padding,
                               height: 520 + 1200 + FanoutGeometry.header + 2 * FanoutGeometry.padding)
    return state
}

/// `--auto-layout-fanout-check` (.plans/107): the production path, scripted.
/// RED on array/release-0735 (8 tiles in one frame, 31 jumps, a 10.8:1 row).
func runFanoutLayoutCheck() {
    let model = ShippedLayoutModel()
    let scripts: [(String, [FanoutTile], FanoutDrag?, Bool)] = [
        ("lead+3", FanoutScenarios.leadAndHelpers(),
         FanoutDrag(tileName: "H1", steps: FanoutScenarios.ramp(dx: -720, dy: 560)), false),
        ("working-zone", FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
         FanoutDrag(tileName: "H2", steps: FanoutScenarios.ramp(dx: 1400, dy: 420, frames: 96)), false),
        ("camera-follows", FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
         FanoutDrag(tileName: "H1", steps: FanoutScenarios.ramp(dx: 1300, dy: 640)), true),
        ("lead-to-empty", FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
         FanoutDrag(tileName: "Lead", steps: FanoutScenarios.ramp(dx: 1300, dy: 1100)), false),
    ]
    var failures: [String] = []
    for (name, spawns, drag, follows) in scripts {
        let m = fanoutRun(model: model, scenario: name, spawns: spawns, drag: drag, cameraFollows: follows).metrics
        func need(_ key: String, _ ok: (Double) -> Bool, _ rule: String) {
            let value = m[key] ?? .nan
            if !ok(value) { failures.append("\(name): \(key) = \(value), must be \(rule)") }
        }
        need("drag.moved_per_frame_max", { $0 <= Double(CanvasAutoLayoutEngine.livePushBudget) }, "≤ 3 tiles per frame")
        need("drag.unexplained_jumps", { $0 == 0 }, "0 (a big step outside a swap or slide-in)")
        need("drag.teleports", { $0 == 0 }, "0 (a tile carried further than its rest-to-home distance)")
        need("drag.overlaps_after_drop", { $0 == 0 }, "0")
        need("drag.drop_strays", { $0 == 0 }, "0 (the release moved a bystander somewhere new)")
        let release = DragMagnetizeConfig.snapReleaseScreenPoints / FanoutGeometry.zoom + 1
        need("drag.active_lag_max", { $0 <= release }, "≤ \(Int(release)) pt (the pointer owns the dragged tile)")
        need("drag.final_lane_changes", { $0 <= 1 }, "≤ 1 (only a swap partner changes lane)")
        need("spawn.overlaps", { $0 == 0 }, "0")
        need("spawn.helpers_touching_lead", { $0 == 3 }, "3 (helpers fan out around their lead)")
        need("spawn.aspect_w_over_h", { $0 >= 0.8 && $0 <= 3.0 }, "between 0.8 and 3.0 (screen-shaped, never a row)")
    }
    // The seeded row: R1 pulled straight down into the empty band and dropped.
    let row = fanoutSeededRow()
    if let r1 = row.tile(named: "R1") {
        let grab = CGPoint(x: r1.frame.x + r1.frame.width / 2, y: r1.frame.y + 18)
        let replay = model.drag(row, active: r1.id, grab: grab, steps: FanoutScenarios.ramp(dx: 40, dy: 900))
        let m = FanoutMetrics.drag(row, replay, active: r1.id)
        if (m["drop_strays"] ?? 0) != 0 || (m["final_displaced"] ?? 0) != 0 {
            failures.append("seeded row: pulling R1 out moved \(m["final_displaced"] ?? .nan) other tile(s), "
                            + "\(m["drop_strays"] ?? .nan) at the release; the row must keep its hole")
        }
    }
    // Model B: a helper dragged into a bystander inside its cluster's scope
    // moves no bystander; the same drag unscoped does (the control).
    do {
        let zoneId = FanoutScenarios.zoneId
        let lead = FanoutScenarios.id(60), h1 = FanoutScenarios.id(61), h2 = FanoutScenarios.id(62)
        let note = FanoutScenarios.id(63)
        let zone = ZonePlacement(zoneId: zoneId, projectId: nil, origin: ZonePoint(x: 0, y: 0),
                                 size: ZoneSize(width: 2_400, height: 1_400), color: "teal", collapsed: false,
                                 hydrationPolicy: .automatic)
        let scene = CanvasAutoLayoutEngine.Scene(tiles: [
            .init(id: lead, frame: TileFrame(x: 24, y: 58, width: 640, height: 520), zoneId: zoneId),
            .init(id: h1, frame: TileFrame(x: 672, y: 58, width: 640, height: 256), zoneId: zoneId),
            .init(id: h2, frame: TileFrame(x: 672, y: 322, width: 640, height: 256), zoneId: zoneId),
            .init(id: note, frame: TileFrame(x: 1320, y: 58, width: 640, height: 400), zoneId: zoneId),
        ], zones: [zone])
        func noteMoves(scoped: Bool) -> Int {
            var previous = Dictionary(uniqueKeysWithValues: scene.tiles.map { ($0.id, $0.frame) })
            var latch: CanvasAutoLayoutEngine.MoveLatch?
            var moves = 0
            for i in 1...40 {
                let dx = Double(i) * 6
                let requested = TileFrame(x: 672 + dx, y: 58, width: 640, height: 256)
                let t = CanvasAutoLayoutEngine.solve(
                    scene: scene, mutation: .tile(id: h1, frame: requested),
                    gap: FanoutGeometry.gap, zonePadding: FanoutGeometry.padding, headerHeight: FanoutGeometry.header,
                    latched: latch, pointer: CGPoint(x: 992 + dx, y: 76), pointerSpeed: 100,
                    previousFrames: previous, interactive: scoped ? [h1, h2] : nil)
                latch = t.moveLatch
                var now = Dictionary(uniqueKeysWithValues: scene.tiles.map { ($0.id, $0.frame) })
                for (id, f) in t.tileFrames { now[id] = f }
                if now[note] != scene.tiles[3].frame { moves += 1 }
                previous = now
            }
            return moves
        }
        let scoped = noteMoves(scoped: true), unscoped = noteMoves(scoped: false)
        if scoped != 0 { failures.append("cluster: a helper drag scoped to its cluster moved the bystander in \(scoped) frame(s)") }
        if unscoped == 0 { failures.append("cluster control: the unscoped drag never pushed the bystander, so the scope is untested") }
    }
    if !failures.isEmpty {
        fputs("FAIL: auto-layout fan-out:\n  " + failures.joined(separator: "\n  ") + "\n", stderr)
        Foundation.exit(1)
    }
    print("auto-layout fan-out check passed: ≤3 tiles per drag frame, no teleports, screen-shaped zones, helpers around their lead")
}

func fanoutModels() -> [FanoutLayoutModel] {
    [ShippedLayoutModel()] + fanoutCandidateModels()
}

func runFanoutLayoutProbe() {
    let args = CommandLine.arguments
    let outDir: URL? = args.firstIndex(of: "--fanout-layout-probe").flatMap { index in
        index + 1 < args.count && !args[index + 1].hasPrefix("--") ? URL(fileURLWithPath: args[index + 1]) : nil
    }
    // Scenario A: the film script. Lead + 3 helpers, then drag H1 across to the far side.
    // Scenario B: a working zone (lead, 3 helpers, 6 ordinary spawns) and a drag of the
    // lead across it: the 6-12 tile measurement Dylan's report describes.
    // Scenario C: B again with the camera following each new tile (reveal on spawn).
    var runs: [FanoutRun] = []
    for model in fanoutModels() {
        let a = fanoutRun(model: model, scenario: "lead+3",
                          spawns: FanoutScenarios.leadAndHelpers(),
                          drag: FanoutDrag(tileName: "H1", steps: FanoutScenarios.ramp(dx: -720, dy: 560)))
        let b = fanoutRun(model: model, scenario: "working-zone",
                          spawns: FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
                          drag: FanoutDrag(tileName: "H2", steps: FanoutScenarios.ramp(dx: 1400, dy: 420, frames: 96)))
        let c = fanoutRun(model: model, scenario: "working-zone-camera-follows",
                          spawns: FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
                          drag: FanoutDrag(tileName: "H1", steps: FanoutScenarios.ramp(dx: 1300, dy: 640)),
                          cameraFollows: true)
        let e = fanoutRun(model: model, scenario: "working-zone-lead-to-empty",
                          spawns: FanoutScenarios.leadAndHelpers() + FanoutScenarios.workingZoneExtras(),
                          drag: FanoutDrag(tileName: "Lead", steps: FanoutScenarios.ramp(dx: 1300, dy: 1100)))
        runs += [a, b, c, e]
    }
    for run in runs {
        print("=== \(run.model) · \(run.scenario) ===")
        for note in run.notes { print("  " + note) }
        for key in run.metrics.keys.sorted() {
            print(String(format: "  %-34@ %g", key as NSString, run.metrics[key]!))
        }
    }
    if let outDir {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for run in runs {
            let url = outDir.appendingPathComponent("\(run.model)--\(run.scenario).json")
            try? encoder.encode(run).write(to: url)
        }
        print("wrote \(runs.count) runs to \(outDir.path)")
    }
    print("fanout layout probe complete")
}
