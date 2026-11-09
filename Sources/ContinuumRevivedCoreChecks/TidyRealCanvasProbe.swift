import CoreGraphics
import Foundation
import ContinuumRevivedCore

/// `--tidy-real-canvas-probe <dir> <out> [--gap N] [--padding N] [--header N]`.
/// A probe, not a check: it always exits 0 and writes artifacts.
///
/// `<dir>` is a COPY of an app-support directory laid out as the app lays it out
/// (`registry.json`, `workspaces/<id>/canvas.json`, `agents/*.json`) plus each
/// project's canvas at `projects/<project id>/.array/canvas.json`. Every file is
/// read through the production stores. For every zone with two or more tiles it
/// runs the production tidy (`CanvasAutoLayoutEngine.solve(.tidy)`), with tile
/// kinds and minimums as `CanvasNSView.autoLayoutScene()` builds them and lead
/// clusters as `sceneWithAgentClusters` stamps them from the agent records, and
/// writes a before/after PNG per zone, `table.md` and `zones.json`. Zones are
/// named z01, z02… in a stable order; no title, path or id is written.
func runTidyRealCanvasProbe() {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--tidy-real-canvas-probe"), args.count > flag + 2 else {
        print("usage: --tidy-real-canvas-probe <dir> <out> [--gap N] [--padding N] [--header N]")
        return
    }
    func option(_ name: String, _ fallback: Double) -> Double {
        args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? fallback
    }
    let base = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
    let out = URL(fileURLWithPath: args[flag + 2], isDirectory: true)
    // The app's defaults: tile gap 8, zone padding 24, zone header 34
    // (`ZoneChromeNSView.headerHeight`, which lives in the app target).
    let gap = option("--gap", TileGapResolver.defaultGap)
    let padding = option("--padding", ZoneBoundsConfig.defaultPadding)
    let header = option("--header", 34)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let registry: Registry
    let records: [AgentRecord]
    do {
        registry = try RegistryStore(applicationSupportDirectory: base).loadOrEmpty()
        records = try AgentStore(applicationSupportDirectory: base).loadAll()
    } catch {
        print("tidy real-canvas probe: could not read \(base.path): \(error)")
        return
    }

    // The app's cluster provider (`AppDelegate.autoLayoutCluster(forTile:)`).
    var recordsById: [AgentID: AgentRecord] = [:]
    for record in records { recordsById[record.id] = record }
    func cluster(forTile tileId: UUID) -> (lead: UUID, helpers: [UUID])? {
        guard let record = records.first(where: { $0.tileId == tileId }) else { return nil }
        let leadId = record.parentAgentID.flatMap { recordsById[$0]?.tileId != nil ? $0 : nil } ?? record.id
        guard let leadTile = recordsById[leadId]?.tileId else { return nil }
        let helpers = records.filter { $0.parentAgentID == leadId }.compactMap(\.tileId)
        return helpers.isEmpty ? nil : (leadTile, helpers)
    }

    struct ZoneRow: Codable {
        var name: String, tiles: Int, kinds: String, clusters: Int
        var fillBefore: Double, fillAfter: Double
        var zoneBefore: String, zoneAfter: String
        var atBandEdge: Int, atCap: Int, maxStretch: Double, minShrink: Double
        var belowMinimum: Int, solveMs: Double, idempotent: Bool
        /// Tiles at least twice the zone's median area before the tidy, and
        /// how many of them are still at least as large as every other tile.
        var bigTiles: Int = 0, bigStillLargest: Int = 0, bigMargin: Double = 0
        /// The zone's width after tidy, against before: tidy keeps it unless it must move.
        var widthKept: Bool = true
    }
    var rows: [ZoneRow] = []
    var index = 0
    let workspaces = registry.workspaces.sorted { $0.createdAt < $1.createdAt }
    for workspace in workspaces {
        guard let document = try? WorkspaceStore(workspaceId: workspace.id, applicationSupportDirectory: base).load() else { continue }
        let zoneIds = Set(document.zones.map(\.zoneId))
        var tiles: [Tile] = []
        for projectId in workspace.projectIds {
            let root = base.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectId.uuidString, isDirectory: true)
            guard let canvas = try? ProjectStore(projectRoot: root).tryLoadCanvas() else { continue }
            tiles += canvas.tiles.filter { $0.zoneId.map(zoneIds.contains) ?? false }
        }
        // `autoLayoutScene()`: kind and kind minimum per tile, zone membership.
        var layoutTiles = tiles.map {
            CanvasAutoLayoutEngine.LayoutTile(id: $0.id, frame: $0.frame, zoneId: $0.zoneId,
                                              minimumSize: TileGeometry.minimumSize(for: $0.kind), kind: $0.kind)
        }
        // `sceneWithAgentClusters`: lead and helpers sharing a zone.
        var position: [UUID: Int] = [:]
        for (i, tile) in layoutTiles.enumerated() where position[tile.id] == nil { position[tile.id] = i }
        var seen = Set<UUID>()
        for tile in layoutTiles where tile.kind == .managedAgent && !seen.contains(tile.id) {
            seen.insert(tile.id)
            guard let zone = tile.zoneId, let found = cluster(forTile: tile.id), let leadIndex = position[found.lead],
                  layoutTiles[leadIndex].zoneId == zone else { continue }
            let helpers = found.helpers.filter { id in position[id].map { layoutTiles[$0].zoneId == zone } ?? false }
            seen.formUnion(found.helpers + [found.lead])
            guard !helpers.isEmpty else { continue }
            for id in helpers + [found.lead] { layoutTiles[position[id]!].clusterLead = found.lead }
        }
        let scene = CanvasAutoLayoutEngine.Scene(tiles: layoutTiles, zones: document.zones)
        let zones = document.zones.sorted { a, b in
            a.origin.y != b.origin.y ? a.origin.y < b.origin.y : a.origin.x < b.origin.x
        }
        for zone in zones {
            let members = layoutTiles.filter { $0.zoneId == zone.zoneId }
            guard members.count >= 2, !zone.collapsed else { continue }
            index += 1
            let name = String(format: "z%02d", index)
            let start = DispatchTime.now().uptimeNanoseconds
            let transaction = CanvasAutoLayoutEngine.solve(scene: scene, mutation: .tidy(zoneId: zone.zoneId),
                                                           gap: gap, zonePadding: padding, headerHeight: header)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            var after = scene
            for i in after.tiles.indices { if let f = transaction.tileFrames[after.tiles[i].id] { after.tiles[i].frame = f } }
            for i in after.zones.indices { if let z = transaction.zonePlacements[after.zones[i].zoneId] { after.zones[i] = z } }
            let again = CanvasAutoLayoutEngine.solve(scene: after, mutation: .tidy(zoneId: zone.zoneId),
                                                     gap: gap, zonePadding: padding, headerHeight: header)
            let zoneAfter = after.zones.first { $0.zoneId == zone.zoneId }!
            func fill(_ z: ZonePlacement, _ s: CanvasAutoLayoutEngine.Scene) -> Double {
                let area = (z.size.width - 2 * padding) * (z.size.height - header - 2 * padding)
                return s.tiles.filter { $0.zoneId == z.zoneId }.reduce(0.0) { $0 + $1.frame.width * $1.frame.height } / max(area, 1)
            }
            var atEdge = 0, atCap = 0, below = 0, maxStretch = 0.0, minShrink = Double.infinity
            for tile in after.tiles where tile.zoneId == zone.zoneId {
                let original = members.first { $0.id == tile.id }!.frame
                let f = tile.frame, ratio = f.width / f.height
                let stretch = (f.width * f.height) / max(original.width * original.height, 1)
                maxStretch = max(maxStretch, stretch)
                minShrink = min(minShrink, stretch)
                if stretch >= CanvasTidyPacker.tileAreaCap * 0.99 { atCap += 1 }
                let minimum = TileGeometry.minimumSize(for: tile.kind!)
                if f.width < Double(minimum.width) - 0.05 || f.height < Double(minimum.height) - 0.05 { below += 1 }
                let isHelper = tile.clusterLead != nil && tile.clusterLead != tile.id
                if !isHelper, case let .band(lo, hi) = TileGeometry.shapeRule(for: tile.kind!),
                   abs(ratio - lo) < 1e-3 || abs(ratio - hi) < 1e-3 {
                    atEdge += 1
                }
            }
            let beforeAreas = members.map { $0.frame.width * $0.frame.height }.sorted()
            let median = beforeAreas[beforeAreas.count / 2]
            let big = Set(members.filter { $0.frame.width * $0.frame.height >= 2 * median }.map(\.id))
            let afterTiles = after.tiles.filter { $0.zoneId == zone.zoneId }
            let largestOther = afterTiles.filter { !big.contains($0.id) }.map { $0.frame.width * $0.frame.height }.max() ?? 0
            let smallestBig = afterTiles.filter { big.contains($0.id) }.map { $0.frame.width * $0.frame.height }.min() ?? 0
            let bigStill = afterTiles.filter { big.contains($0.id) && $0.frame.width * $0.frame.height >= largestOther - 1 }.count
            var kindCounts: [String: Int] = [:]
            for m in members { kindCounts[m.kind!.rawValue, default: 0] += 1 }
            let clusters = Set(members.compactMap(\.clusterLead)).count
            rows.append(ZoneRow(
                name: name, tiles: members.count,
                kinds: kindCounts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "),
                clusters: clusters,
                fillBefore: fill(zone, scene), fillAfter: fill(zoneAfter, after),
                zoneBefore: String(format: "%.0fx%.0f", zone.size.width, zone.size.height),
                zoneAfter: String(format: "%.0fx%.0f", zoneAfter.size.width, zoneAfter.size.height),
                atBandEdge: atEdge, atCap: atCap, maxStretch: maxStretch, minShrink: minShrink,
                belowMinimum: below, solveMs: ms, idempotent: again.tileFrames.isEmpty && again.zonePlacements.isEmpty,
                bigTiles: big.count, bigStillLargest: bigStill, bigMargin: largestOther > 0 ? smallestBig / largestOther : 0,
                widthKept: abs(zoneAfter.size.width - zone.size.width) <= CanvasTidyPacker.grid))
            writeTidyPicture(before: scene, after: after, zoneId: zone.zoneId, path: out.appendingPathComponent("\(name).png").path)
            // Anonymised shape for seeding: kinds, frames and clusters only.
            let ids = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.id, $0) })
            let shape: [String: Any] = [
                "zone": ["x": zone.origin.x, "y": zone.origin.y, "w": zone.size.width, "h": zone.size.height],
                "tiles": members.map { m -> [String: Any] in
                    var entry: [String: Any] = ["kind": m.kind!.rawValue, "x": m.frame.x, "y": m.frame.y, "w": m.frame.width, "h": m.frame.height]
                    if let lead = m.clusterLead, let leadIndex = ids[lead] { entry["lead"] = leadIndex }
                    return entry
                },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: shape, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("\(name).shape.json"))
            }
        }
    }

    var table = "| zone | tiles | kinds | clusters | fill before | fill after | zone before → after | at band edge | at 2.56x cap | max stretch | min shrink | below min | solve ms | 2nd tidy no-op | big tiles still largest | smallest big ÷ largest other | width kept |\n"
    table += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
    for r in rows {
        table += String(format: "| %@ | %d | %@ | %d | %.3f | %.3f | %@ → %@ | %d | %d | %.2f | %.2f | %d | %.1f | %@ | %d of %d | %.2f | %@ |\n",
                        r.name, r.tiles, r.kinds, r.clusters, r.fillBefore, r.fillAfter, r.zoneBefore, r.zoneAfter,
                        r.atBandEdge, r.atCap, r.maxStretch, r.minShrink, r.belowMinimum, r.solveMs, r.idempotent ? "yes" : "NO",
                        r.bigStillLargest, r.bigTiles, r.bigMargin, r.widthKept ? "yes" : "no")
    }
    try? table.write(to: out.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
    if let data = try? JSONEncoder().encode(rows) { try? data.write(to: out.appendingPathComponent("zones.json")) }
    print(table)
    print("tidy real-canvas probe: \(rows.count) zones (gap \(gap), padding \(padding), header \(header)) -> \(out.path)")
}
