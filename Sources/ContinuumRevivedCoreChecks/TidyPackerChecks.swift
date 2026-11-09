import CoreGraphics
import Foundation
import ImageIO
import ContinuumRevivedCore

/// `--tidy-packer-check [picture dir]`: the explicit Tidy, driven through
/// `CanvasAutoLayoutEngine.solve(.tidy)` exactly as `CanvasNSView.tidyAutoLayout`
/// calls it (`.plans/auto-layout-night`). Seeded messy zones of 2, 3, 5, 8 and 13
/// mixed tiles, a lead with three helpers, a cramped zone and a roomy one.
/// Writes a before/after PNG per zone when a directory is given.
func runTidyPackerChecks() {
    let args = CommandLine.arguments
    let pictureDir = args.firstIndex(of: "--tidy-packer-check").flatMap { i in
        args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
    }
    var failures: [String] = []
    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }
    let gap = 16.0, padding = 16.0, header = 32.0
    let fillFloor = 0.80

    func solve(_ scene: CanvasAutoLayoutEngine.Scene, _ zoneId: UUID) -> CanvasLayoutTransaction {
        CanvasAutoLayoutEngine.solve(scene: scene, mutation: .tidy(zoneId: zoneId), gap: gap, zonePadding: padding, headerHeight: header)
    }
    func applied(_ scene: CanvasAutoLayoutEngine.Scene, _ t: CanvasLayoutTransaction) -> CanvasAutoLayoutEngine.Scene {
        var next = scene
        for i in next.tiles.indices { if let f = t.tileFrames[next.tiles[i].id] { next.tiles[i].frame = f } }
        for i in next.zones.indices { if let z = t.zonePlacements[next.zones[i].zoneId] { next.zones[i] = z } }
        return next
    }
    func content(_ zone: ZonePlacement) -> CGRect {
        CGRect(x: zone.origin.x + padding, y: zone.origin.y + header + padding,
               width: zone.size.width - 2 * padding, height: zone.size.height - header - 2 * padding)
    }
    func fill(_ scene: CanvasAutoLayoutEngine.Scene) -> Double {
        let c = content(scene.zones[0])
        let area = scene.tiles.filter { $0.zoneId == scene.zones[0].zoneId }.reduce(0.0) { $0 + $1.frame.width * $1.frame.height }
        return area / Double(c.width * c.height)
    }

    // Deterministic generator.
    var seed: UInt64 = 0x7E1D_9ACC_E5ED_0001
    func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func uuid(_ zone: Int, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "71D70000-0000-4000-8000-%06d%06d", zone, index))!
    }

    struct Case { var name: String; var scene: CanvasAutoLayoutEngine.Scene; var zoneId: UUID; var lead: UUID?; var helpers: [UUID] }
    let palette: [TileKind] = [.terminal, .browser, .managedAgent, .note, .file, .terminal, .browser, .managedAgent, .diffReview, .terminal, .fileTree, .managedAgent, .iosPreview]

    /// Tiles at their preset sizes (jittered ±25%) scattered over a loose grid
    /// with holes; the zone is the members' envelope plus `slack`.
    func makeCase(_ name: String, number: Int, kinds: [TileKind], columns: Int, slack: CGSize, cluster: Bool = false, helperCount: Int = 3) -> Case {
        let zoneId = uuid(number, 999)
        var tiles: [CanvasAutoLayoutEngine.LayoutTile] = []
        var lead: UUID?
        var helpers: [UUID] = []
        for (index, kind) in kinds.enumerated() {
            let preset = TileGeometry.preset(for: kind).defaultSize
            let jitter = 0.75 + 0.5 * random()
            let w = kind == .iosPreview ? Double(preset.width) : (Double(preset.width) * jitter).rounded()
            let h = kind == .iosPreview ? Double(preset.height) : (Double(preset.height) * (0.75 + 0.5 * random())).rounded()
            let column = index % columns, row = index / columns
            let x = 1000 + Double(column) * 1150 + (random() * 120).rounded()
            let y = 600 + Double(row) * 1000 + (random() * 140).rounded()
            tiles.append(.init(id: uuid(number, index), frame: TileFrame(x: x, y: y, width: w, height: h), zoneId: zoneId,
                               minimumSize: TileGeometry.minimumSize(for: kind), kind: kind))
        }
        if cluster {
            let agents = tiles.indices.filter { tiles[$0].kind == .managedAgent }
            if agents.count >= helperCount + 1 {
                lead = tiles[agents[0]].id
                helpers = agents[1...helperCount].map { tiles[$0].id }
                for i in agents.prefix(helperCount + 1) { tiles[i].clusterLead = lead }
                // Helpers as spawn makes them: the lead's width, half its height.
                let leadFrame = tiles[agents[0]].frame
                for i in agents[1...helperCount] {
                    tiles[i].frame.width = leadFrame.width
                    tiles[i].frame.height = ((leadFrame.height - gap) / 2).rounded()
                }
            }
        }
        let minX = tiles.map(\.frame.x).min()!, minY = tiles.map(\.frame.y).min()!
        let maxX = tiles.map { $0.frame.x + $0.frame.width }.max()!, maxY = tiles.map { $0.frame.y + $0.frame.height }.max()!
        let zone = ZonePlacement(zoneId: zoneId, projectId: nil,
            origin: ZonePoint(x: minX - padding, y: minY - header - padding),
            size: ZoneSize(width: maxX - minX + 2 * padding + Double(slack.width),
                           height: maxY - minY + header + 2 * padding + Double(slack.height)),
            color: "teal", collapsed: false, hydrationPolicy: .automatic)
        return Case(name: name, scene: .init(tiles: tiles, zones: [zone]), zoneId: zoneId, lead: lead, helpers: helpers)
    }

    var cases = [
        makeCase("two", number: 2, kinds: [.terminal, .browser], columns: 2, slack: CGSize(width: 0, height: 0)),
        makeCase("three", number: 3, kinds: [.managedAgent, .terminal, .browser], columns: 3, slack: CGSize(width: 0, height: 0)),
        makeCase("five", number: 5, kinds: Array(palette.prefix(5)), columns: 3, slack: CGSize(width: 0, height: 0)),
        makeCase("eight", number: 8, kinds: Array(palette.prefix(8)), columns: 3, slack: CGSize(width: 0, height: 0)),
        makeCase("thirteen", number: 13, kinds: palette, columns: 4, slack: CGSize(width: 0, height: 0)),
        makeCase("lead-three-helpers", number: 20,
                 kinds: [.browser, .managedAgent, .terminal, .managedAgent, .note, .managedAgent, .managedAgent, .terminal],
                 columns: 3, slack: CGSize(width: 0, height: 0), cluster: true),
        makeCase("lead-five-helpers", number: 21,
                 kinds: [.terminal, .managedAgent, .managedAgent, .managedAgent, .browser, .managedAgent, .managedAgent, .managedAgent, .note],
                 columns: 3, slack: CGSize(width: 0, height: 0), cluster: true, helperCount: 5),
    ]
    // Cramped: the eight tiles' zone squeezed to a third of its height (members
    // overlap a hand-shrunk zone), so tidy must grow it.
    var cramped = makeCase("cramped", number: 30, kinds: Array(palette.prefix(8)), columns: 8, slack: .zero)
    cramped.scene.zones[0].size.width = 2400
    cramped.scene.zones[0].size.height = 700
    for i in cramped.scene.tiles.indices {
        cramped.scene.tiles[i].frame.x = cramped.scene.zones[0].origin.x + padding + Double(i) * 280
        cramped.scene.tiles[i].frame.y = cramped.scene.zones[0].origin.y + header + padding
    }
    cases.append(cramped)
    // Roomy: three tiles in a big zone; they grow to at most 1.6× and the zone
    // shrinks to them.
    var roomy = makeCase("roomy", number: 40, kinds: [.terminal, .note, .managedAgent], columns: 3, slack: CGSize(width: 0, height: 1800))
    roomy.scene.zones[0].size.width += 1200
    cases.append(roomy)

    // Float dust far from the origin, as pointer drags leave it: the zone and
    // every tile shifted by an awkward fraction in a coarse binade.
    var dust = makeCase("dust", number: 45, kinds: Array(palette.prefix(8)), columns: 3, slack: .zero)
    let dustShift = 81_234.567_891_234_5
    dust.scene.zones[0].origin.x += dustShift
    dust.scene.zones[0].origin.y -= dustShift / 3
    for i in dust.scene.tiles.indices { dust.scene.tiles[i].frame.x += dustShift; dust.scene.tiles[i].frame.y -= dustShift / 3 }
    cases.append(dust)

    let caseNames = cases.map(\.name)
    var report: [String] = []
    for c in cases {
        let before = c.scene
        let zoneBefore = before.zones[0]
        let fillBefore = fill(before)
        let start = DispatchTime.now().uptimeNanoseconds
        let t = solve(before, c.zoneId)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let after = applied(before, t)
        let zone = after.zones[0]
        let rect = content(zone)
        let members = after.tiles.filter { $0.zoneId == c.zoneId }
        let fillAfter = fill(after)
        report.append(String(format: "  %@: tiles %d fill %.3f -> %.3f zone %.0fx%.0f -> %.0fx%.0f solve %.2fms",
                             c.name, members.count, fillBefore, fillAfter, zoneBefore.size.width, zoneBefore.size.height,
                             zone.size.width, zone.size.height, elapsed))

        check(abs(zone.origin.x - zoneBefore.origin.x) <= CanvasTidyPacker.grid / 2
              && abs(zone.origin.y - zoneBefore.origin.y) <= CanvasTidyPacker.grid / 2,
              "\(c.name): tidy keeps the zone's origin (to its 1/64 pt grid)")
        check(fillAfter >= fillFloor, "\(c.name): fill \(fillAfter) below \(fillFloor)")
        let eps = 0.05
        for tile in members {
            let f = tile.frame
            check(f.width >= Double(tile.minimumSize.width) - eps && f.height >= Double(tile.minimumSize.height) - eps,
                  "\(c.name): \(tile.kind!) below its minimum: \(f)")
            check(f.x >= Double(rect.minX) - eps && f.y >= Double(rect.minY) - eps
                  && f.x + f.width <= Double(rect.maxX) + eps && f.y + f.height <= Double(rect.maxY) + eps,
                  "\(c.name): \(tile.kind!) outside the content rect: \(f) vs \(rect)")
            switch tile.kind! {
            case .browser:
                // 16:9 to the 1/64 pt grid every tidy edge lands on.
                check(abs(f.width - f.height * 16 / 9) <= 2 * CanvasTidyPacker.grid, "\(c.name): browser not 16:9: \(f)")
            case .terminal:
                check(f.height > f.width, "\(c.name): terminal not taller than wide: \(f)")
            case .iosPreview:
                let original = before.tiles.first { $0.id == tile.id }!.frame
                check(f.width == original.width && f.height == original.height, "\(c.name): iOS preview was resized")
            default: break
            }
            // Edge to edge: every right edge meets the content edge or a
            // neighbour exactly one gap away; every bottom edge likewise
            // (a fixed-size tile may be shorter than its row).
            let right = f.x + f.width, bottom = f.y + f.height
            let meetsRight = abs(right - Double(rect.maxX)) <= eps || members.contains { o in
                o.id != tile.id && abs(o.frame.x - right - gap) <= eps && o.frame.y < bottom && o.frame.y + o.frame.height > f.y
            }
            check(meetsRight, "\(c.name): \(tile.kind!) right edge leaves a hole: \(f)")
            if tile.kind != .iosPreview {
                let meetsBottom = abs(bottom - Double(rect.maxY)) <= eps || members.contains { o in
                    o.id != tile.id && abs(o.frame.y - bottom - gap) <= eps && o.frame.x < right && o.frame.x + o.frame.width > f.x
                }
                check(meetsBottom, "\(c.name): \(tile.kind!) bottom edge leaves a hole: \(f)")
            }
        }
        for (i, a) in members.enumerated() {
            for b in members.dropFirst(i + 1) {
                let sepX = max(a.frame.x - (b.frame.x + b.frame.width), b.frame.x - (a.frame.x + a.frame.width))
                let sepY = max(a.frame.y - (b.frame.y + b.frame.height), b.frame.y - (a.frame.y + a.frame.height))
                check(max(sepX, sepY) >= gap - eps, "\(c.name): tiles closer than the gap: \(a.frame) \(b.frame)")
            }
        }
        // Reading order survives (tiles outside the cluster).
        func readingOrder(_ scene: CanvasAutoLayoutEngine.Scene) -> [UUID] {
            let outside = Set([c.lead].compactMap { $0 } + c.helpers)
            return scene.tiles.filter { !outside.contains($0.id) }.sorted { a, b in
                let ay = a.frame.y + a.frame.height / 2, by = b.frame.y + b.frame.height / 2
                let sameLine = abs(a.frame.y - b.frame.y) < min(a.frame.height, b.frame.height) / 2
                return sameLine ? a.frame.x < b.frame.x : ay < by
            }.map(\.id)
        }
        if c.name != "cramped" {
            check(readingOrder(before) == readingOrder(after), "\(c.name): tidy shuffled the reading order")
        }
        // The lead and its helpers are one block: the lead on the left, the
        // helpers in columns beside it, each column's heights (with gaps)
        // summing to the lead's height, and no other tile inside the block.
        if let lead = c.lead {
            let leadFrame = members.first { $0.id == lead }!.frame
            let helperFrames = members.filter { c.helpers.contains($0.id) }.map(\.frame)
            let columns = Dictionary(grouping: helperFrames, by: \.x).sorted { $0.key < $1.key }
            // The lead's rule, pinned here rather than read from the packer: more than four helpers take two columns.
            let expectedColumns = c.helpers.count > 4 ? 2 : 1
            check(columns.count == expectedColumns,
                  "\(c.name): \(c.helpers.count) helpers make \(columns.count) columns, expected \(expectedColumns)")
            check(abs(columns.first!.key - (leadFrame.x + leadFrame.width + gap)) <= eps,
                  "\(c.name): helpers do not start one gap right of the lead: \(leadFrame) \(helperFrames)")
            let grid = CanvasTidyPacker.grid
            for (_, column) in columns {
                let stacked = column.sorted { $0.y < $1.y }
                check(abs(stacked.first!.y - leadFrame.y) <= grid
                      && abs(stacked.last!.y + stacked.last!.height - (leadFrame.y + leadFrame.height)) <= grid,
                      "\(c.name): the helper column's top and bottom do not match the lead's: \(stacked) vs \(leadFrame)")
                let heights = stacked.map(\.height)
                check(heights.max()! - heights.min()! <= 2 * grid, "\(c.name): helpers in a column differ in height: \(heights)")
                check(Set(stacked.map(\.width)).count == 1, "\(c.name): helpers in a column differ in width: \(stacked)")
                // About the helper band: exact without the gaps between helpers.
                let ratio = stacked[0].width / ((leadFrame.height) / Double(stacked.count))
                check(ratio >= CanvasTidyPacker.helperRatioBand.min - 1e-3 && ratio <= CanvasTidyPacker.helperRatioBand.max + 1e-3,
                      "\(c.name): helpers outside their band: \(ratio)")
                for (upper, lower) in zip(stacked, stacked.dropFirst()) {
                    check(abs(lower.y - (upper.y + upper.height) - gap) <= eps, "\(c.name): helpers are not one gap apart: \(stacked)")
                }
            }
            let blockRight = helperFrames.map { $0.x + $0.width }.max()!
            check(!members.contains { m in
                m.id != lead && !c.helpers.contains(m.id)
                    && m.frame.x < blockRight && m.frame.x + m.frame.width > leadFrame.x
                    && m.frame.y < leadFrame.y + leadFrame.height && m.frame.y + m.frame.height > leadFrame.y
            }, "\(c.name): another tile sits inside the lead's block")
            let leadRatio = leadFrame.width / leadFrame.height
            check(leadRatio >= 0.6 - 1e-3 && leadRatio <= 1.0 + 1e-3, "\(c.name): the lead is outside the agent band: \(leadFrame)")
        }
        // A lone agent (no lead with it) takes the agent band.
        for tile in members where tile.kind == .managedAgent && tile.id != c.lead && !c.helpers.contains(tile.id) {
            let ratio = tile.frame.width / tile.frame.height
            check(ratio >= 0.6 - 1e-3 && ratio <= 1.0 + 1e-3, "\(c.name): a lone agent is outside the agent band: \(tile.frame)")
        }
        // Every frame converts to zone-local and back exactly: the canvas
        // rejects a layered commit that cannot.
        for tile in members {
            check(CanvasEngine.worldToZoneLocalPreservingWorld(tile.frame, zoneOrigin: zone.origin) != nil,
                  "\(c.name): \(tile.kind!) frame has no exact zone-local: \(tile.frame) in \(zone.origin)")
        }
        // Idempotent.
        let again = solve(after, c.zoneId)
        check(again.tileFrames.isEmpty && again.zonePlacements.isEmpty,
              "\(c.name): tidy is not idempotent: \(again.tileFrames.count) tiles, zone \(again.zonePlacements.values.map(\.size)); largest move \(again.tileFrames.map { id, f in let o = after.tiles.first { $0.id == id }!.frame; return max(abs(f.x - o.x), abs(f.y - o.y), abs(f.width - o.width), abs(f.height - o.height)) }.max() ?? 0)")
        // Deterministic across input order.
        var shuffled = before
        for i in stride(from: shuffled.tiles.count - 1, to: 0, by: -1) {
            shuffled.tiles.swapAt(i, Int(random() * Double(i + 1)))
        }
        let shuffledResult = solve(shuffled, c.zoneId)
        check(shuffledResult.tileFrames == t.tileFrames && shuffledResult.zonePlacements == t.zonePlacements,
              "\(c.name): result depends on input order")

        if let pictureDir {
            writeTidyPicture(before: before, after: after, zoneId: c.zoneId,
                             path: "\(pictureDir)/\(caseNames.firstIndex(of: c.name)!)-\(c.name).png")
        }
    }

    // The zone grows only when it must: the eight-tile case keeps its width and
    // does not grow; the cramped zone grows taller; the roomy zone shrinks.
    func zoneAfter(_ name: String) -> (ZoneSize, ZoneSize) {
        let c = cases.first { $0.name == name }!
        return (c.scene.zones[0].size, applied(c.scene, solve(c.scene, c.zoneId)).zones[0].size)
    }
    // A wide zone of two or three tiles cannot be filled by shape alone, so its
    // height may give a little; it never widens and never grows by more than 15%.
    for name in ["two", "three", "five", "eight", "thirteen", "lead-three-helpers", "lead-five-helpers"] {
        let (b, a) = zoneAfter(name)
        check(a.width <= b.width + 0.01 && a.height <= b.height * 1.15, "\(name): zone grew more than needed: \(b) -> \(a)")
    }
    // Tiles that already fit the zone exactly at their own sizes, scattered and
    // out of order: the zone keeps its size and every tile its size.
    let fitsId = uuid(50, 999)
    let fitsZone = ZonePlacement(zoneId: fitsId, projectId: nil, origin: ZonePoint(x: 0, y: 0),
        size: ZoneSize(width: 4 * 600 + 3 * gap + 2 * padding, height: 800 + header + 2 * padding),
        color: "teal", collapsed: false, hydrationPolicy: .automatic)
    let fitsTiles = (0..<4).map { i in
        CanvasAutoLayoutEngine.LayoutTile(id: uuid(50, i), frame: TileFrame(x: 40 + Double(3 - i) * 590, y: 60 + Double(i) * 3, width: 600, height: 800),
            zoneId: fitsId, minimumSize: TileGeometry.minimumSize(for: .terminal), kind: .terminal)
    }
    let fitsResult = solve(.init(tiles: fitsTiles, zones: [fitsZone]), fitsId)
    check(fitsResult.zonePlacements[fitsId] == nil, "fits: a zone the tiles already fill keeps its size: \(String(describing: fitsResult.zonePlacements[fitsId]?.size))")
    check(fitsTiles.allSatisfy { t in fitsResult.tileFrames[t.id].map { $0.width == 600 && $0.height == 800 } ?? true },
          "fits: tiles that already fit keep their sizes: \(fitsResult.tileFrames.values.map { ($0.width, $0.height) })")
    let (crampedBefore, crampedAfter) = zoneAfter("cramped")
    check(crampedAfter.height > crampedBefore.height && crampedAfter.width == crampedBefore.width,
          "cramped: the zone must grow taller, not wider: \(crampedBefore) -> \(crampedAfter)")
    let (roomyBefore, roomyAfter) = zoneAfter("roomy")
    check(roomyAfter.height < roomyBefore.height, "roomy: a zone too big for 1.6x tiles shrinks: \(roomyBefore) -> \(roomyAfter)")
    let roomy0 = cases.first { $0.name == "roomy" }!
    let roomyResult = solve(roomy0.scene, roomy0.zoneId)
    for tile in roomy0.scene.tiles {
        let f = roomyResult.tileFrames[tile.id] ?? tile.frame
        let ratio = f.width * f.height / (tile.frame.width * tile.frame.height)
        check(ratio <= CanvasTidyPacker.tileAreaCap + 0.01, "roomy: \(tile.kind!) stretched \(ratio)x")
    }

    // Cost on the main thread: 30, 60 and 89 tiles in one zone (89 is the
    // largest real canvas measured), the whole explicit tidy, best of five
    // (other work on the Mac only ever adds time). Budgets are debug builds.
    let budgets: [(Int, Double)] = [(30, 8), (60, 18), (89, 25)]
    var costCases: [Case] = []
    for (count, budget) in budgets {
        let c = makeCase("cost-\(count)", number: 100 + count, kinds: (0..<count).map { palette[$0 % (palette.count - 1)] },
                         columns: count >= 60 ? 9 : 6, slack: .zero)
        costCases.append(c)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = solve(c.scene, c.zoneId)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let best = samples.min()!
        report.append("  \(c.name): 5 solves " + samples.map { String(format: "%.1fms", $0) }.joined(separator: " "))
        check(best <= budget, "a \(count)-tile tidy took \(best)ms at best (budget \(budget)ms, debug build)")
    }

    // The output is pinned: a digest of every frame and the zone, per seed.
    // A speed-up must not move a single tile.
    func digest(_ t: CanvasLayoutTransaction) -> String {
        var text = ""
        for (id, f) in t.tileFrames.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            text += "\(id.uuidString) \(f.x) \(f.y) \(f.width) \(f.height)\n"
        }
        for (id, z) in t.zonePlacements.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            text += "\(id.uuidString) \(z.origin.x) \(z.origin.y) \(z.size.width) \(z.size.height)\n"
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
    var digests: [String: String] = [:]
    for c in cases + costCases { digests[c.name] = digest(solve(c.scene, c.zoneId)) }
    // A deliberate change to tidy's output re-pins these: run with
    // TIDY_PACKER_PRINT_DIGESTS=1 and paste the printed lines below.
    if ProcessInfo.processInfo.environment["TIDY_PACKER_PRINT_DIGESTS"] != nil {
        for (name, value) in digests.sorted(by: { $0.key < $1.key }) { print("        \"\(name)\": \"\(value)\",") }
    }
    let pinned: [String: String] = [
        "cost-30": "69cb9552480e5530",
        "cost-60": "5690a4e2571787d5",
        "cost-89": "b737c4647b92cfc0",
        "cramped": "6d016e18ecc400ca",
        "dust": "7763d41b85cd424c",
        "eight": "571b25d8afec5baf",
        "five": "03ea3c771b6ef0ce",
        "lead-five-helpers": "8a8d4d415d673daa",
        "lead-three-helpers": "1860f52c39abcb2e",
        "roomy": "65e14404e5d8d5a8",
        "thirteen": "0bb09afd9c385746",
        "three": "03de6e777b49137b",
        "two": "43ad3d17d96b1b3e",
    ]
    for (name, value) in pinned where digests[name] != value {
        check(false, "\(name): tidy output changed (digest \(digests[name] ?? "none"), pinned \(value))")
    }

    print("tidy packer:")
    report.forEach { print($0) }
    if failures.isEmpty {
        print("tidy packer check passed")
    } else {
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        Foundation.exit(1)
    }
}

/// Before (left) and after (right), each zone scaled into a 900 pt panel.
private func writeTidyPicture(before: CanvasAutoLayoutEngine.Scene, after: CanvasAutoLayoutEngine.Scene, zoneId: UUID, path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let panel = 900.0, margin = 40.0
    func bounds(_ scene: CanvasAutoLayoutEngine.Scene) -> CGRect {
        var r = scene.zones.first { $0.zoneId == zoneId }.map {
            CGRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
        } ?? .null
        for t in scene.tiles where t.zoneId == zoneId {
            r = r.union(CGRect(x: t.frame.x, y: t.frame.y, width: t.frame.width, height: t.frame.height))
        }
        return r
    }
    let b0 = bounds(before), b1 = bounds(after)
    let scale = panel / Double(max(b0.width, b0.height, b1.width, b1.height))
    let height = Int(Double(max(b0.height, b1.height)) * scale + 2 * margin)
    let width = Int(2 * panel + 3 * margin)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func color(_ kind: TileKind?) -> CGColor {
        switch kind {
        case .browser: return CGColor(red: 0.30, green: 0.56, blue: 0.86, alpha: 1)
        case .terminal: return CGColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1)
        case .managedAgent: return CGColor(red: 0.55, green: 0.40, blue: 0.80, alpha: 1)
        case .iosPreview: return CGColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1)
        default: return CGColor(red: 0.45, green: 0.70, blue: 0.55, alpha: 1)
        }
    }
    for (index, scene) in [before, after].enumerated() {
        let origin = index == 0 ? b0.origin : b1.origin
        let left = margin + Double(index) * (panel + margin)
        func map(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            // CoreGraphics is y-up; flip so the picture reads like the canvas.
            let top = margin + (y - Double(origin.y)) * scale
            return CGRect(x: left + (x - Double(origin.x)) * scale, y: Double(height) - top - h * scale,
                          width: w * scale, height: h * scale)
        }
        if let zone = scene.zones.first(where: { $0.zoneId == zoneId }) {
            let r = map(zone.origin.x, zone.origin.y, zone.size.width, zone.size.height)
            ctx.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 0.93, alpha: 1))
            ctx.fill(r)
            ctx.setStrokeColor(CGColor(red: 0.35, green: 0.60, blue: 0.65, alpha: 1))
            ctx.setLineWidth(2)
            ctx.stroke(r)
        }
        for tile in scene.tiles where tile.zoneId == zoneId {
            let r = map(tile.frame.x, tile.frame.y, tile.frame.width, tile.frame.height)
            ctx.setFillColor(color(tile.kind))
            ctx.fill(r)
            if tile.clusterLead != nil {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
                ctx.setLineWidth(tile.clusterLead == tile.id ? 5 : 2)
                ctx.stroke(r.insetBy(dx: 2, dy: 2))
            }
        }
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
