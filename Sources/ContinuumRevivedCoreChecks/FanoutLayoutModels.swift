import CoreGraphics
import Foundation
import ContinuumRevivedCore

// Candidate layout models for .plans/107. Prototype only: each one runs the
// probe's scripted scenarios so its trajectories can be counted and filmed
// beside the shipped engine. None of this is wired into the app.

func fanoutCandidateModels() -> [FanoutLayoutModel] {
    [LocalJellyModel(), LeadClusterModel(), CellGridModel(), CellGridModel(growth: .down)]
}

enum FanoutGrowth: String { case fan, right, down }

// MARK: - Shared geometry

private let fg = FanoutGeometry.gap
private let targetAspect = Double(FanoutGeometry.screen.width / FanoutGeometry.screen.height)

private func overlapsUnderGap(_ a: TileFrame, _ b: TileFrame, gap: Double = fg) -> Bool {
    let g = gap - 0.26
    return a.x < b.x + b.width + g && a.x + a.width + g > b.x && a.y < b.y + b.height + g && a.y + a.height + g > b.y
}

private func contains(_ f: TileFrame, _ p: CGPoint, inset: Double = 0) -> Bool {
    p.x >= f.x - inset && p.x <= f.x + f.width + inset && p.y >= f.y - inset && p.y <= f.y + f.height + inset
}

private func centre(_ f: TileFrame) -> CGPoint { CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2) }

private func union(_ frames: [TileFrame]) -> TileFrame? {
    guard let minX = frames.map(\.x).min(), let minY = frames.map(\.y).min(),
          let maxX = frames.map({ $0.x + $0.width }).max(), let maxY = frames.map({ $0.y + $0.height }).max()
    else { return nil }
    return TileFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// How far an envelope is from the screen's shape (0 = same aspect). Fanning
/// toward the screen aspect is what keeps a zone fittable in one view.
private func aspectPenalty(_ frames: [TileFrame]) -> Double {
    guard let u = union(frames), u.width > 0, u.height > 0 else { return 0 }
    return abs(log(u.width / u.height) - log(targetAspect))
}

private func growthPenalty(_ candidate: TileFrame, from host: TileFrame, _ growth: FanoutGrowth) -> Double {
    switch growth {
    case .fan: return 0
    case .right: return candidate.x >= host.x + host.width ? 0 : 1
    case .down: return candidate.y >= host.y + host.height ? 0 : 1
    }
}

/// Edge-aligned (never centre-aligned) slots around `host`: aligned edges are
/// what keep rows and columns readable, and what stop mixed heights chaining.
private func edgeSlots(around host: TileFrame, size: CGSize) -> [TileFrame] {
    let w = Double(size.width), h = Double(size.height)
    return [
        TileFrame(x: host.x + host.width + fg, y: host.y, width: w, height: h),
        TileFrame(x: host.x + host.width + fg, y: host.y + host.height - h, width: w, height: h),
        TileFrame(x: host.x, y: host.y + host.height + fg, width: w, height: h),
        TileFrame(x: host.x + host.width - w, y: host.y + host.height + fg, width: w, height: h),
        TileFrame(x: host.x - fg - w, y: host.y, width: w, height: h),
        TileFrame(x: host.x, y: host.y - fg - h, width: w, height: h),
    ]
}

private func firstTileOrigin(_ zone: ZonePlacement) -> CGPoint {
    CGPoint(x: zone.origin.x + FanoutGeometry.padding, y: zone.origin.y + FanoutGeometry.header + FanoutGeometry.padding)
}

/// The tile under the camera centre, else the one nearest it.
private func cameraAnchor(_ state: FanoutState) -> TileFrame? {
    let c = centre(state.view)
    if let hit = state.tiles.last(where: { contains($0.frame, c) }) { return hit.frame }
    return state.tiles.min { hypot(centre($0.frame).x - c.x, centre($0.frame).y - c.y)
        < hypot(centre($1.frame).x - c.x, centre($1.frame).y - c.y) }?.frame
}

/// Best free edge slot around any of `hosts`, scored for shape, then nearness.
private func bestEdgeSlot(hosts: [TileFrame], size: CGSize, avoid: [TileFrame], all: [TileFrame],
                          near: CGPoint, growth: FanoutGrowth) -> TileFrame? {
    var best: (TileFrame, Double)?
    for host in hosts {
        for slot in edgeSlots(around: host, size: size) where !avoid.contains(where: { overlapsUnderGap(slot, $0) }) {
            let c = centre(slot)
            let score = aspectPenalty(all + [slot]) + growthPenalty(slot, from: host, growth) * 2
                + hypot(c.x - near.x, c.y - near.y) / 4000
            if best == nil || score < best!.1 - 1e-9 { best = (slot, score) }
        }
    }
    return best?.0
}

/// Nearest free gap-contact slot for a tile dropped at `frame` (used only
/// when a drop overlaps something; a free drop stays exactly where it is).
private func nearestFreeContact(_ frame: TileFrame, others: [TileFrame]) -> TileFrame {
    guard others.contains(where: { overlapsUnderGap(frame, $0) }) else { return frame }
    var best: (TileFrame, Double)?
    for other in others {
        let size = CGSize(width: frame.width, height: frame.height)
        var slots = edgeSlots(around: other, size: size)
        // Also keep the drop's own alignment on each side.
        slots += [TileFrame(x: other.x + other.width + fg, y: frame.y, width: frame.width, height: frame.height),
                  TileFrame(x: other.x - fg - frame.width, y: frame.y, width: frame.width, height: frame.height),
                  TileFrame(x: frame.x, y: other.y + other.height + fg, width: frame.width, height: frame.height),
                  TileFrame(x: frame.x, y: other.y - fg - frame.height, width: frame.width, height: frame.height)]
        for slot in slots where !others.contains(where: { overlapsUnderGap(slot, $0) }) {
            let d = hypot(slot.x - frame.x, slot.y - frame.y)
            if best == nil || d < best!.1 { best = (slot, d) }
        }
    }
    return best?.0 ?? frame
}

// MARK: - A · Local jelly (the shipped engine, made local)

/// Keep the jelly vocabulary Dylan approved (pointer-owned tile, single-axis
/// push, latched swap) but bound every effect to the tiles the pointer touches.
/// Spawns dock edge-aligned onto the lead's family, choosing the side that keeps
/// the envelope closest to the screen's shape. No slide-in rows, no push chains,
/// no rest-time re-clustering: a drop resolves only the dropped tile.
struct LocalJellyModel: FanoutLayoutModel {
    var name = "a-local-jelly"
    var growth: FanoutGrowth = .fan
    var carriesHelpers: Bool { false }

    func spawn(_ state: inout FanoutState, _ tile: FanoutTile) {
        let size = CGSize(width: tile.frame.width, height: tile.frame.height)
        var new = tile
        if state.tiles.isEmpty {
            let o = firstTileOrigin(state.zone)
            new.frame = TileFrame(x: o.x, y: o.y, width: tile.frame.width, height: tile.frame.height)
        } else {
            let all = state.tiles.map(\.frame)
            let hosts: [TileFrame]
            let near: CGPoint
            if let parent = tile.parent, let lead = state.frame(parent) {
                hosts = [lead] + state.tiles.filter { $0.parent == parent }.map(\.frame)
                near = centre(lead)
            } else {
                let anchor = cameraAnchor(state) ?? all[0]
                hosts = all
                near = centre(anchor)
            }
            new.frame = bestEdgeSlot(hosts: hosts, size: size, avoid: all, all: all, near: near, growth: growth)
                ?? TileFrame(x: (union(all)?.x ?? 0) + (union(all)?.width ?? 0) + fg, y: all[0].y,
                             width: tile.frame.width, height: tile.frame.height)
        }
        state.tiles.append(new)
        state.expandZone()
    }

    func drag(_ state: FanoutState, active: UUID, grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)] {
        guard let home = state.frame(active) else { return [] }
        var out: [(FanoutState, String?, TileFrame?)] = []
        var displayed = state
        var latch: UUID?
        let band = 24.0
        for step in steps {
            let p = CGPoint(x: grab.x + step.dx, y: grab.y + step.dy)
            let requested = TileFrame(x: home.x + step.dx, y: home.y + step.dy, width: home.width, height: home.height)
            // Latch against what the user SEES: a latched swap holds while the
            // pointer stays over the slot it will take (the target's old place),
            // a new one needs the pointer over a displayed tile's middle half.
            if let id = latch, let slot = state.frame(id), contains(slot, p, inset: band) {
                // hold
            } else {
                latch = displayed.tiles.first { t in
                    guard t.id != active else { return false }
                    let f = t.frame
                    let middle = TileFrame(x: f.x + f.width / 4, y: f.y + f.height / 4, width: f.width / 2, height: f.height / 2)
                    return contains(middle, p)
                }?.id
            }
            var live = state
            live.setFrame(active, requested)
            if let id = latch, let target = state.frame(id) {
                live.setFrame(id, TileFrame(x: home.x, y: home.y, width: target.width, height: target.height))
            } else {
                // Depth-one push: only tiles the dragged one presses on move, along
                // one axis, and only if that frees them without touching a third.
                for t in state.tiles where t.id != active && overlapsUnderGap(requested, t.frame) {
                    let b = t.frame, a = requested
                    // The pair's own axis, from where they sat before the drag;
                    // never the other axis, and never through a third tile.
                    let xSeparated = home.x + home.width <= b.x + 0.5 || b.x + b.width <= home.x + 0.5
                    let ySeparated = home.y + home.height <= b.y + 0.5 || b.y + b.height <= home.y + 0.5
                    let horizontal = xSeparated != ySeparated ? xSeparated
                        : min(a.x + a.width + fg - b.x, b.x + b.width + fg - a.x) <= min(a.y + a.height + fg - b.y, b.y + b.height + fg - a.y)
                    let o: (Double, Double) = horizontal
                        ? (centre(b).x >= centre(home).x ? a.x + a.width + fg - b.x : -(b.x + b.width + fg - a.x), 0)
                        : (0, centre(b).y >= centre(home).y ? a.y + a.height + fg - b.y : -(b.y + b.height + fg - a.y))
                    let moved = TileFrame(x: b.x + o.0, y: b.y + o.1, width: b.width, height: b.height)
                    let blocked = live.tiles.contains { $0.id != t.id && $0.id != active && overlapsUnderGap(moved, $0.frame) }
                    let ok: (Double, Double)? = blocked ? nil : o
                    if let o = ok { live.setFrame(t.id, TileFrame(x: b.x + o.0, y: b.y + o.1, width: b.width, height: b.height)) }
                }
            }
            displayed = live
            let latchLabel: String? = latch.map { id in "swap " + (state.tiles.first { $0.id == id }?.name ?? "?") }
            out.append((live, latchLabel, latch.flatMap { state.frame($0) }))
        }
        var dropped = displayed
        if let id = latch, let target = state.frame(id) {
            dropped.setFrame(active, TileFrame(x: target.x, y: target.y, width: home.width, height: home.height))
            // A swapped tile larger than the slot it inherits resolves itself only.
            if let moved = dropped.frame(id) {
                let others = dropped.tiles.filter { $0.id != id }.map(\.frame)
                dropped.setFrame(id, nearestFreeContact(moved, others: others))
            }
        } else if let f = dropped.frame(active) {
            let others = dropped.tiles.filter { $0.id != active }.map(\.frame)
            dropped.setFrame(active, nearestFreeContact(f, others: others))
        }
        dropped.expandZone()
        out.append((dropped, "drop", nil))
        return out
    }
}

// MARK: - B · Lead clusters

/// A lead and its helpers are one rigid cluster laid out by a template:
/// helpers spawn at half the lead's height, two stacked to its right, then
/// below it, then a further column. Clusters (and lone tiles, clusters of one)
/// are placed edge-aligned against other clusters. Dragging a lead carries its
/// cluster; dragging a helper reorders slots inside its cluster; nothing outside
/// the gesture's cluster ever moves during a drag.
struct LeadClusterModel: FanoutLayoutModel {
    var name = "b-lead-clusters"
    var growth: FanoutGrowth = .fan
    var carriesHelpers: Bool { true }

    static func helperSize(lead: TileFrame) -> CGSize {
        CGSize(width: lead.width, height: (lead.height - fg) / 2)
    }

    /// Template slot `i` relative to the lead.
    static func slot(_ i: Int, lead: TileFrame) -> TileFrame {
        let s = helperSize(lead: lead)
        let w = Double(s.width), h = Double(s.height)
        let pattern: [(Double, Double)] = [(1, 0), (1, 1), (0, 2), (1, 2), (2, 0), (2, 1), (2, 2), (0, 3), (1, 3), (2, 3)]
        let (col, row) = pattern[min(i, pattern.count - 1)]
        let x = lead.x + col * (lead.width + fg)
        let y = row < 2 ? lead.y + row * (h + fg) : lead.y + lead.height + fg + (row - 2) * (h + fg)
        return TileFrame(x: x, y: y, width: w, height: h)
    }

    private func clusterIds(_ state: FanoutState, of id: UUID) -> [UUID] {
        guard let t = state.tiles.first(where: { $0.id == id }) else { return [] }
        let lead = t.slot == nil ? t.id : (t.parent.flatMap { p in state.tiles.contains { $0.id == p } ? p : nil } ?? t.id)
        return [lead] + state.tiles.filter { $0.parent == lead && $0.slot != nil }.map(\.id)
    }

    private func clusters(_ state: FanoutState) -> [[UUID]] {
        var seen = Set<UUID>(), out: [[UUID]] = []
        for t in state.tiles where !seen.contains(t.id) {
            let ids = t.slot == nil ? [t.id] + state.tiles.filter { $0.parent == t.id && $0.slot != nil }.map(\.id)
                                    : clusterIds(state, of: t.id)
            ids.forEach { seen.insert($0) }
            out.append(ids)
        }
        return out
    }

    private func rect(_ state: FanoutState, _ ids: [UUID]) -> TileFrame? { union(ids.compactMap { state.frame($0) }) }

    func spawn(_ state: inout FanoutState, _ tile: FanoutTile) {
        var new = tile
        if state.tiles.isEmpty {
            let o = firstTileOrigin(state.zone)
            new.frame = TileFrame(x: o.x, y: o.y, width: tile.frame.width, height: tile.frame.height)
            state.tiles.append(new)
            state.expandZone()
            return
        }
        if let parent = tile.parent, let lead = state.frame(parent) {
            let used = Set(state.tiles.filter { $0.parent == parent }.compactMap(\.slot))
            let index = (0...).first { !used.contains($0) }!
            new.slot = index
            new.frame = Self.slot(index, lead: lead)
            state.tiles.append(new)
            // The cluster grew: push whole clusters it now overlaps, rigidly,
            // along the axis the slot grew on.
            let mine = Set(clusterIds(state, of: parent))
            var queue = [new.frame]
            var guardCount = 0
            while let pusher = queue.popLast(), guardCount < 64 {
                guardCount += 1
                for ids in clusters(state) where !ids.contains(where: mine.contains) {
                    guard let r = rect(state, ids), overlapsUnderGap(pusher, r) else { continue }
                    let horizontal = new.frame.x >= lead.x + lead.width
                    let dx = horizontal ? pusher.x + pusher.width + fg - r.x : 0
                    let dy = horizontal ? 0 : pusher.y + pusher.height + fg - r.y
                    for id in ids { if let f = state.frame(id) { state.setFrame(id, TileFrame(x: f.x + dx, y: f.y + dy, width: f.width, height: f.height)) } }
                    if let moved = rect(state, ids) { queue.append(moved) }
                }
            }
            state.expandZone()
            return
        }
        // A lone tile or a new lead: edge-aligned beside a cluster, shaped for the screen.
        let all = state.tiles.map(\.frame)
        let hosts = clusters(state).compactMap { rect(state, $0) }
        let near = centre(cameraAnchor(state) ?? all[0])
        let size = CGSize(width: tile.frame.width, height: tile.frame.height)
        new.frame = bestEdgeSlot(hosts: hosts, size: size, avoid: all, all: all, near: near, growth: growth) ?? tile.frame
        state.tiles.append(new)
        state.expandZone()
    }

    func drag(_ state: FanoutState, active: UUID, grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)] {
        guard let me = state.tiles.first(where: { $0.id == active }), let home = state.frame(active) else { return [] }
        var out: [(FanoutState, String?, TileFrame?)] = []
        let isHelper = me.slot != nil && me.parent != nil
        let carried = isHelper ? [active] : clusterIds(state, of: active)
        let homeRect = rect(state, carried)!
        var latchName: String?
        var final = state
        var slotGhost: TileFrame?
        for step in steps {
            let p = CGPoint(x: grab.x + step.dx, y: grab.y + step.dy)
            var live = state
            for id in carried {
                if let f = state.frame(id) { live.setFrame(id, TileFrame(x: f.x + step.dx, y: f.y + step.dy, width: f.width, height: f.height)) }
            }
            latchName = nil
            slotGhost = nil
            if isHelper, let lead = me.parent, let leadFrame = state.frame(lead) {
                // Reorder inside the cluster: the pointer picks a template slot.
                let count = state.tiles.filter { $0.parent == lead && $0.slot != nil }.count
                if let target = (0..<max(count, 1)).first(where: { contains(Self.slot($0, lead: leadFrame), p) }), target != me.slot {
                    if let occupant = state.tiles.first(where: { $0.parent == lead && $0.slot == target }) {
                        live.setFrame(occupant.id, Self.slot(me.slot!, lead: leadFrame))
                        latchName = "slot \(target) ⇄ " + occupant.name
                    } else { latchName = "slot \(target)" }
                    slotGhost = Self.slot(target, lead: leadFrame)
                }
            } else {
                // A cluster over another cluster's middle swaps the two clusters' places.
                for ids in clusters(state) where !ids.contains(active) {
                    guard let r = rect(state, ids) else { continue }
                    let middle = TileFrame(x: r.x + r.width / 4, y: r.y + r.height / 4, width: r.width / 2, height: r.height / 2)
                    if contains(middle, p) {
                        for id in ids { if let f = state.frame(id) {
                            live.setFrame(id, TileFrame(x: f.x - r.x + homeRect.x, y: f.y - r.y + homeRect.y, width: f.width, height: f.height)) } }
                        latchName = "swap cluster " + (state.tiles.first { $0.id == ids[0] }?.name ?? "?")
                        slotGhost = TileFrame(x: r.x, y: r.y, width: homeRect.width, height: homeRect.height)
                        break
                    }
                }
            }
            out.append((live, latchName, slotGhost))
            final = live
        }
        var dropped = final
        if isHelper, let lead = me.parent, let leadFrame = state.frame(lead) {
            if let name = latchName, name.hasPrefix("slot"),
               let target = Int(name.dropFirst(5).prefix { $0.isNumber }) {
                if let index = dropped.tiles.firstIndex(where: { $0.parent == lead && $0.slot == target }) {
                    dropped.tiles[index].slot = me.slot
                }
                if let index = dropped.tiles.firstIndex(where: { $0.id == active }) { dropped.tiles[index].slot = target }
                dropped.setFrame(active, Self.slot(target, lead: leadFrame))
            } else if !contains(rect(state, clusterIds(state, of: lead))!, p(steps.last!, grab), inset: 48) {
                // Pulled out of its cluster: it becomes a lone tile where it was dropped.
                if let index = dropped.tiles.firstIndex(where: { $0.id == active }) { dropped.tiles[index].slot = nil }
                let others = dropped.tiles.filter { $0.id != active }.map(\.frame)
                if let f = dropped.frame(active) { dropped.setFrame(active, nearestFreeContact(f, others: others)) }
            } else {
                dropped.setFrame(active, home)   // released inside its cluster: back to its slot
            }
        } else if let ghost = slotGhost {
            let dx = ghost.x - homeRect.x, dy = ghost.y - homeRect.y
            for id in carried { if let f = state.frame(id) { dropped.setFrame(id, TileFrame(x: f.x + dx, y: f.y + dy, width: f.width, height: f.height)) } }
        } else if let moved = rect(dropped, carried) {
            let others = dropped.tiles.filter { !carried.contains($0.id) }.map(\.frame)
            let placed = nearestFreeContact(moved, others: others)
            for id in carried { if let f = dropped.frame(id) {
                dropped.setFrame(id, TileFrame(x: f.x + placed.x - moved.x, y: f.y + placed.y - moved.y, width: f.width, height: f.height)) } }
        }
        dropped.expandZone()
        out.append((dropped, "drop", nil))
        return out
    }

    private func p(_ step: CGVector, _ grab: CGPoint) -> CGPoint { CGPoint(x: grab.x + step.dx, y: grab.y + step.dy) }
}

// MARK: - C · Cell grid, displacement only

/// The zone is a grid of quarter-agent cells (an agent tile is exactly 4x4).
/// Every tile owns a span of cells and its size snaps to that span. Empty cells
/// are legal: nothing compacts, nothing has gravity. Spawns take the free span
/// nearest the lead's family (ring distance first, then shape, then growth
/// direction). A drag displaces ONLY the tiles under the target span, into the
/// dragged tile's vacated span when they fit there, else to the nearest free
/// span; every other tile is untouched by construction.
struct CellGridModel: FanoutLayoutModel {
    var growth: FanoutGrowth = .fan
    var name: String { growth == .fan ? "c-cell-grid" : "c-cell-grid-\(growth.rawValue)" }
    var carriesHelpers: Bool { false }

    static let pitchX = 162.0, pitchY = 132.0   // 154 x 124 cells + 8 gap

    struct Span: Equatable { var c, r, w, h: Int
        func intersects(_ o: Span) -> Bool { c < o.c + o.w && o.c < c + w && r < o.r + o.h && o.r < r + h }
        func ring(to o: Span) -> Int {
            max(max(o.c - (c + w), c - (o.c + o.w), 0), max(o.r - (r + h), r - (o.r + o.h), 0))
        }
    }

    private func origin(_ state: FanoutState) -> CGPoint {
        // Fixed at the first tile's origin; the grid never moves under the tiles.
        CGPoint(x: FanoutGeometry.padding, y: FanoutGeometry.header + FanoutGeometry.padding)
    }

    private func spanSize(_ w: Double, _ h: Double) -> (Int, Int) {
        (max(1, Int(((w + fg) / Self.pitchX).rounded())), max(1, Int(((h + fg) / Self.pitchY).rounded())))
    }

    private func frame(_ s: Span, _ o: CGPoint) -> TileFrame {
        TileFrame(x: o.x + Double(s.c) * Self.pitchX, y: o.y + Double(s.r) * Self.pitchY,
                  width: Double(s.w) * Self.pitchX - fg, height: Double(s.h) * Self.pitchY - fg)
    }

    private func span(_ t: FanoutTile) -> Span? { t.cell.map { Span(c: $0[0], r: $0[1], w: $0[2], h: $0[3]) } }

    func spawn(_ state: inout FanoutState, _ tile: FanoutTile) {
        let o = origin(state)
        let (w, h) = spanSize(tile.frame.width, tile.frame.height)
        var new = tile
        var chosen = Span(c: 0, r: 0, w: w, h: h)
        let spans = state.tiles.compactMap(span)
        if !spans.isEmpty {
            let family: [Span]
            if let parent = tile.parent, let lead = state.tiles.first(where: { $0.id == parent }).flatMap(span) {
                family = [lead] + state.tiles.filter { $0.parent == parent }.compactMap(span)
            } else {
                let c = centre(state.view)
                let anchor = state.tiles.min { hypot(centre($0.frame).x - c.x, centre($0.frame).y - c.y)
                    < hypot(centre($1.frame).x - c.x, centre($1.frame).y - c.y) }.flatMap(span)!
                family = [anchor]
            }
            let minC = spans.map(\.c).min()! - w - 1, maxC = spans.map { $0.c + $0.w }.max()! + 1
            let minR = spans.map(\.r).min()! - h - 1, maxR = spans.map { $0.r + $0.h }.max()! + 1
            var best: (Span, [Double])?
            for r in minR...maxR {
                for c in minC...maxC {
                    let s = Span(c: c, r: r, w: w, h: h)
                    guard !spans.contains(where: { $0.intersects(s) }) else { continue }
                    // Around the LEAD first (siblings only break ties), and an
                    // edge-sharing slot before a corner one.
                    let lead0 = family[0]
                    let ring = Double(s.ring(to: lead0)) * 10 + Double(family.map { s.ring(to: $0) }.min()!)
                    let sharesEdge = (s.c < lead0.c + lead0.w && lead0.c < s.c + s.w) || (s.r < lead0.r + lead0.h && lead0.r < s.r + s.h)
                    // Aligned to an edge of the lead or a sibling, so rows and columns read.
                    let aligned = family.contains { f in s.r == f.r || s.c == f.c || s.r + s.h == f.r + f.h || s.c + s.w == f.c + f.w }
                    let f = frame(s, o)
                    let grow: Double
                    switch growth {
                    case .fan: grow = 0
                    case .right: grow = Double(max(0, -(c - family[0].c)))  + (r < family[0].r ? 1 : 0)
                    case .down: grow = Double(max(0, -(r - family[0].r))) + (c < family[0].c ? 1 : 0)
                    }
                    let lead = frame(family[0], o)
                    let key = [ring, sharesEdge ? 0 : 1, aligned ? 0 : 1, grow, (aspectPenalty(state.tiles.map(\.frame) + [f]) * 20).rounded() / 20,
                               hypot(centre(f).x - centre(lead).x, centre(f).y - centre(lead).y)]
                    if best == nil || key.lexicographicallyPrecedes(best!.1) { best = (s, key) }
                }
            }
            chosen = best!.0
        }
        new.cell = [chosen.c, chosen.r, chosen.w, chosen.h]
        new.frame = frame(chosen, o)
        state.tiles.append(new)
        state.expandZone()
    }

    func drag(_ state: FanoutState, active: UUID, grab: CGPoint, steps: [CGVector]) -> [(FanoutState, String?, TileFrame?)] {
        guard let me = state.tiles.first(where: { $0.id == active }), let homeSpan = span(me) else { return [] }
        let o = origin(state)
        let home = me.frame
        var target = homeSpan
        var out: [(FanoutState, String?, TileFrame?)] = []
        var lastResolved = state
        for step in steps {
            let requested = TileFrame(x: home.x + step.dx, y: home.y + step.dy, width: home.width, height: home.height)
            // Hysteresis: the target cell moves only when the tile is 0.65 of a
            // pitch past the current target, so edge jitter cannot flip it.
            let fx = (requested.x - o.x) / Self.pitchX, fy = (requested.y - o.y) / Self.pitchY
            if abs(fx - Double(target.c)) > 0.65 { target.c = Int(fx.rounded()) }
            if abs(fy - Double(target.r)) > 0.65 { target.r = Int(fy.rounded()) }
            let resolved = resolve(state, active: active, home: homeSpan, target: target, origin: o, previous: lastResolved)
            var live = resolved.state
            live.setFrame(active, requested)
            lastResolved = resolved.state
            let label = resolved.displaced.isEmpty ? (target == homeSpan ? nil : "cell \(target.c),\(target.r)")
                : "displace " + resolved.displaced.joined(separator: ",")
            out.append((live, label, frame(target, o)))
        }
        var dropped = lastResolved
        dropped.expandZone()
        out.append((dropped, "drop", nil))
        return out
    }

    /// The whole drag outcome from the baseline: only tiles under `target` move.
    private func resolve(_ state: FanoutState, active: UUID, home: Span, target: Span, origin o: CGPoint,
                         previous: FanoutState? = nil)
        -> (state: FanoutState, displaced: [String]) {
        var s = state
        if let i = s.tiles.firstIndex(where: { $0.id == active }) {
            s.tiles[i].cell = [target.c, target.r, target.w, target.h]
            s.tiles[i].frame = frame(target, o)
        }
        guard target != home else { return (s, []) }
        let hit = state.tiles.filter { $0.id != active && span($0).map { $0.intersects(target) } == true }
        var names: [String] = []
        for t in hit {
            guard var sp = span(t) else { continue }
            let occupied = s.tiles.filter { $0.id != t.id }.compactMap(span)
            // Sticky: a tile already displaced last frame keeps that place while
            // it is still free, so a moving target cannot make it hop.
            if let prior = previous?.tiles.first(where: { $0.id == t.id }).flatMap(span), prior != sp,
               !prior.intersects(target), !occupied.contains(where: { $0.intersects(prior) }) {
                if let i = s.tiles.firstIndex(where: { $0.id == t.id }) {
                    s.tiles[i].cell = [prior.c, prior.r, prior.w, prior.h]
                    s.tiles[i].frame = frame(prior, o)
                }
                names.append(t.name)
                continue
            }
            // Prefer the vacated home span, keeping the tile's offset inside it.
            let homeFit = Span(c: home.c + max(0, min(sp.c - target.c, home.w - sp.w)),
                               r: home.r + max(0, min(sp.r - target.r, home.h - sp.h)), w: sp.w, h: sp.h)
            if !occupied.contains(where: { $0.intersects(homeFit) }) {
                sp = homeFit
            } else {
                var best: (Span, Int)?
                for radius in 1...24 {
                    for dr in -radius...radius { for dc in -radius...radius where max(abs(dr), abs(dc)) == radius {
                        let cand = Span(c: sp.c + dc, r: sp.r + dr, w: sp.w, h: sp.h)
                        if !occupied.contains(where: { $0.intersects(cand) }) {
                            let cost = dc * dc + dr * dr
                            if best == nil || cost < best!.1 { best = (cand, cost) }
                        }
                    } }
                    if best != nil { break }
                }
                sp = best?.0 ?? sp
            }
            if let i = s.tiles.firstIndex(where: { $0.id == t.id }) {
                s.tiles[i].cell = [sp.c, sp.r, sp.w, sp.h]
                s.tiles[i].frame = frame(sp, o)
            }
            names.append(t.name)
        }
        return (s, names)
    }
}
