import CoreGraphics
import Foundation

/// The explicit Tidy: a pure, deterministic justified-row packer
/// (`.plans/auto-layout-night`). It fills a zone's content rect edge to edge at
/// the configured gap, shapes every tile by its kind (`TileGeometry.shapeRule`),
/// keeps the reading order, and packs a lead agent with its helpers as one block.
///
/// How it decides, in order:
/// 1. Reading order: lines of tiles by top edge (a tile joins a line when its top
///    sits within half the line's shortest tile of the line's top), then x. A
///    lead and its helpers become ONE item where the first of them reads: the
///    lead on the left at its agent shape, its helpers stacked top to bottom in
///    one column on its right (two columns past four helpers), each column's
///    heights (with gaps) summing to the lead's height, every helper in a
///    column the same height. Helpers are exempt from the agent band; the
///    column geometry shapes them (`.plans/auto-layout-night`).
/// 2. For a uniform area scale `s` on a grid over [`areaFloor`, `areaCeiling`],
///    a dynamic program picks the row breaks whose rows, each justified to the
///    content width, keep every tile closest to `s` × its current area at its
///    preferred ratio.
/// 3. Rows then trade height inside each tile's ratio band (and below the
///    per-tile cap, `tileAreaCap`) so the rows sum to the content height.
/// 4. The cheapest candidate wins: the change to the tiles (mean squared log
///    change of area and ratio, plus half the worst tile's) plus the change to
///    the zone height (`growWeight` / `shrinkWeight`). So the zone grows in
///    height when the tiles cannot fit without shrinking past the floor, and
///    width grows only for a tile that cannot fit across at its minimum.
/// 5. A zone too big for its tiles (mean stretch past the ceiling, or a fill
///    that would lose a tenth of its height) also tries uniform shrinks k < 1,
///    which keep the zone's proportions.
///
/// A tidy result is its own fixed point: at s = 1 the current breaks cost exactly
/// zero and fill exactly, so a second tidy changes nothing.
public enum CanvasTidyPacker {
    public struct Member: Equatable, Sendable {
        public var id: UUID
        public var frame: TileFrame
        public var kind: TileKind?
        public var minimumSize: CGSize
        /// The lead's tile id, on the lead itself and on each of its helpers.
        public var clusterLead: UUID?

        public init(id: UUID, frame: TileFrame, kind: TileKind?, minimumSize: CGSize, clusterLead: UUID? = nil) {
            self.id = id
            self.frame = frame
            self.kind = kind
            self.minimumSize = minimumSize
            self.clusterLead = clusterLead
        }
    }

    public struct Result: Equatable, Sendable {
        public var frames: [UUID: TileFrame]
        /// The content rect the tiles fill. Same origin as the input; its size is
        /// the zone's new content size.
        public var content: CGRect
        /// The area scale chosen (diagnostic).
        public var scale: Double
    }

    /// A tile may be shrunk to 60% of its area before the zone grows, and
    /// enlarged to 160% before the zone shrinks. Linear: 0.77× … 1.26×.
    public static let areaFloor = 0.6
    public static let areaCeiling = 1.6
    /// No single tile past 2.56× its area (1.6× each way), whatever the mean:
    /// a lone browser stretched across a wide zone is the case this stops.
    public static let tileAreaCap = 2.56

    private static func capPenalty(_ logChange: Double) -> Double {
        let excess = logChange - log(tileAreaCap)
        return excess > 0 ? 40 * excess * excess : 0
    }

    /// Every tidy edge lands on this grid (see the placement).
    public static let grid = 1.0 / 64

    /// What changing the zone's height costs against changing the tiles, per
    /// squared log of the change. Shrinking costs more: the point is to fill.
    public static let growWeight = 2.0
    public static let shrinkWeight = 4.0
    /// Shape of a tile with no kind (a scene from a caller that has none).
    public static let defaultRule = TileShapeRule.band(min: 0.6, max: 1.8)

    // MARK: - Items

    private struct Item {
        var id: UUID
        var area: Double
        /// Preferred ratio (w/h): the current ratio clamped into the rule.
        var ratio: Double
        var ratioMin: Double
        var ratioMax: Double
        var minW: Double
        var minH: Double
        /// `.keep`: never reshaped or resized, only moved.
        var fixed: CGSize?
        /// Width that does not scale with height: a block's inner gaps.
        var extraWidth: Double = 0
        var block: Block?
        /// The tile's (or a block lead's) top edge now, for size grouping.
        var top: Double = 0
    }

    /// A lead with its helpers. The item's flexible width is the lead's width ×
    /// (1 + q × columns): each helper column is q × the lead's width.
    private struct Block {
        var lead: UUID
        var columns: [[UUID]]
        var q: Double
    }

    /// The items' numbers as flat arrays: the row solver reads these, so a debug
    /// build pays no struct copies or closures per row (`.plans/auto-layout-night`).
    private struct Flat {
        let count: Int
        let ratio, ratioMin, ratioMax, minW, minH, area, extra, fixedW, fixedH: UnsafeMutablePointer<Double>
        let isFixed: UnsafeMutablePointer<Bool>

        init(_ items: [Item]) {
            count = items.count
            let capacity = max(count, 1)
            ratio = .allocate(capacity: capacity); ratioMin = .allocate(capacity: capacity); ratioMax = .allocate(capacity: capacity)
            minW = .allocate(capacity: capacity); minH = .allocate(capacity: capacity); area = .allocate(capacity: capacity)
            extra = .allocate(capacity: capacity); fixedW = .allocate(capacity: capacity); fixedH = .allocate(capacity: capacity)
            isFixed = .allocate(capacity: capacity)
            for (i, item) in items.enumerated() {
                ratio[i] = item.ratio; ratioMin[i] = item.ratioMin; ratioMax[i] = item.ratioMax
                minW[i] = item.minW; minH[i] = item.minH; area[i] = item.area; extra[i] = item.extraWidth
                fixedW[i] = Double(item.fixed?.width ?? 0); fixedH[i] = Double(item.fixed?.height ?? 0)
                isFixed[i] = item.fixed != nil
            }
        }

        func free() {
            for pointer in [ratio, ratioMin, ratioMax, minW, minH, area, extra, fixedW, fixedH] { pointer.deallocate() }
            isFixed.deallocate()
        }
    }

    /// Up to this many helpers stack in one column beside their lead; more
    /// take two columns.
    public static let helpersInOneColumn = 4
    /// A helper's own loose band (w/h). The column geometry decides its shape;
    /// this only bounds the column width.
    public static let helperRatioBand = (min: 0.9, max: 2.6)

    /// Featured bands (`.plans/auto-layout-night`): a tile much larger than its
    /// row mates spans two or three rows as a column at the left or right of a
    /// band, the rows beside it justified into the rest of the width. Every
    /// tile then keeps 0.5–2.0× its area: with that hard band a uniform grid is
    /// infeasible for a zone whose big tiles are 3–4× the rest, so the span is
    /// what fits. Off, tidy is the uniform justified-row packer.
    ///
    /// OFF (2026-11-09): on a real canvas the hard band has no layout at all
    /// for the two zones it was meant for (40 widths × 3 heights scanned): its
    /// rows follow reading order, and tiles of 333k–2.8M pt² sit side by side,
    /// so no row height keeps every tile in band. Bands work where the band is
    /// feasible (a 10-tile zone kept its kanban the largest, spanning two rows).
    /// See `.plans/auto-layout-night/reports/tidy-engine.md`, round 7.
    static let featuredBands = true
    /// Size-grouped rows (`.plans/auto-layout-night`, experiment): tiles are
    /// ordered by the height at which each keeps its own area at its preferred
    /// ratio, tallest first, instead of by reading order, and rows are stacked
    /// tallest first. A row's shared height can then keep every tile in its
    /// hard area band, and a tile made several times the rest keeps its size.
    /// Tiles within 2% of the same height keep reading order among themselves.
    public static let sizeGroupedRows = true
    /// No tile below this share of its area, or above `tileAreaHardCap`.
    public static let tileAreaFloor = 0.5
    public static let tileAreaHardCap = 2.0
    /// A tile at least this many times the median area may lead a band.
    static let featureThreshold = 2.0
    /// Most tiles a band's rows hold together.
    static let featureMaxTiles = 12

    /// A band: the big tile's column and the rows beside it.
    private struct Featured {
        var anchor: Int
        var anchorLeft: Bool
        var anchorWidth: Double
        var subRows: [(start: Int, end: Int, height: Double)]
    }

    /// A candidate row. Its geometry does not depend on the area scale; only
    /// its cost does: Σ (Lᵢ − ln s)² + shape, with Lᵢ = ln(areaᵢ / current areaᵢ).
    private struct Row {
        var start: Int
        var end: Int
        var height: Double
        var heightMin: Double
        var heightMax: Double
        var sumL: Double = 0
        var sumL2: Double = 0
        var flexCount: Double = 0
        var shapeCost: Double = 0
        var featured: Featured? = nil
        /// An area-fit row: its tiles' widths are fixed whatever its height
        /// (`areaFitWidths`).
        var areaFit = false

        func cost(logScale ls: Double) -> Double { sumL2 - 2 * ls * sumL + flexCount * ls * ls + shapeCost }
    }

    private struct Layout {
        var rows: [Row]
        var total: Double
        var scale: Double
        var cost: Double
        var exact: Bool
        /// Geometric mean of every flexible tile's area against its current area.
        var stretch: Double
        /// Every tile within `tileAreaFloor`…`tileAreaHardCap` of its area.
        var withinBand: Bool = true
    }

    public static func pack(members: [Member], content: CGRect, gap rawGap: Double) -> Result {
        let gap = max(0, rawGap.isFinite ? rawGap : 0)
        guard !members.isEmpty else { return Result(frames: [:], content: content, scale: 1) }
        let items = orderedItems(members, gap: gap)
        let plain = packItems(items, content: content, gap: gap)
        // Big tiles stacked in a column beside the rows, when that changes the
        // tiles and the zone less, by the same score for both.
        // A column a tidy already made: tiles flush with the content's left edge,
        // one width, stacked top to bottom over its whole height, nothing else
        // beside them in that strip. Keeping exactly those is what makes a
        // re-tidy stable when a tile sits near the size threshold.
        func existingColumn() -> [UUID]? {
            let left = Double(content.minX), top = Double(content.minY), bottom = Double(content.maxY)
            let flush = members.filter { abs($0.frame.x - left) <= 0.5 }.sorted { $0.frame.y < $1.frame.y }
            guard let first = flush.first, abs(first.frame.y - top) <= 0.5,
                  abs(flush.last!.frame.y + flush.last!.frame.height - bottom) <= 0.5,
                  flush.allSatisfy({ abs($0.frame.width - first.frame.width) <= 0.5 }) else { return nil }
            for (upper, lower) in zip(flush, flush.dropFirst())
                where abs(lower.frame.y - (upper.frame.y + upper.frame.height) - gap) > 0.5 { return nil }
            let ids = Set(flush.map(\.id))
            let strip = first.frame.x + first.frame.width
            guard !members.contains(where: { !ids.contains($0.id) && $0.frame.x < strip - 0.5 }) else { return nil }
            return ids.count < members.count ? flush.map(\.id) : nil
        }
        guard sizeGroupedRows,
              let column = packWithColumn(items, content: content, gap: gap, keep: existingColumn()) else { return plain }
        // Big tiles keep their size (the lead's decision, `.plans/auto-layout-night`):
        // an in-band column wins over rows that would trade a big tile's area
        // for its neighbours'. The score still chooses the column's height.
        if featuredBands { return column }
        return score(column, items: items, content: content) < score(plain, items: items, content: content) - 1e-9 ? column : plain
    }

    /// Tiles at least `columnThreshold` × the median area, stacked at the left
    /// at one shared width and their preferred ratios, the other tiles in
    /// size-grouped rows beside them. The column's width is set so its height
    /// equals the rows' height, so the zone fills edge to edge. Nil when there
    /// is no big tile, too few others, or a column tile would leave its band.
    static let columnThreshold = 2.0

    /// The column for each of a few heights around the big tiles' own, the rows'
    /// region shaped to keep the zone's proportions; the best by `score`.
    private static func packWithColumn(_ items: [Item], content: CGRect, gap: Double, keep: [UUID]?) -> Result? {
        // Heights 0.7…1.75 of the big tiles' own: start at 1, then walk toward
        // whichever neighbour scores better until neither does.
        let factors = [0.7, 0.85, 1.0, 1.2, 1.45, 1.75]
        var cache: [Int: (Result, Double)?] = [:]
        func value(_ k: Int) -> (Result, Double)? {
            if let known = cache[k] { return known }
            let result = packWithColumn(items, content: content, gap: gap, heightFactor: factors[k], keep: keep)
            let entry = result.map { ($0, score($0, items: items, content: content)) }
            cache[k] = entry
            return entry
        }
        var at = 2
        var best = value(at)
        while true {
            let down = at > 0 ? value(at - 1) : nil, up = at < factors.count - 1 ? value(at + 1) : nil
            let current = best?.1 ?? .infinity
            if let down, down.1 < current - 1e-9, down.1 <= (up?.1 ?? .infinity) { best = down; at -= 1; continue }
            if let up, up.1 < current - 1e-9 { best = up; at += 1; continue }
            if best == nil, let any = [down, up].compactMap({ $0 }).min(by: { $0.1 < $1.1 }) { best = any }
            break
        }
        return best?.0
    }

    private static func packWithColumn(_ items: [Item], content: CGRect, gap: Double, heightFactor: Double, keep: [UUID]?) -> Result? {
        let areas = items.map(\.area).sorted()
        let median = areas[areas.count / 2]
        let big = items.filter { item in
            // A browser's 16:9 cannot follow a shared column width.
            guard item.fixed == nil, item.extraWidth == 0, item.ratioMin < item.ratioMax else { return false }
            if let keep { return keep.contains(item.id) }
            return item.area >= columnThreshold * median
        }.sorted { a, b in
            // A kept column keeps its own top-to-bottom order; a new one goes
            // largest first.
            if let keep { return keep.firstIndex(of: a.id)! < keep.firstIndex(of: b.id)! }
            return a.area != b.area ? a.area > b.area : UUID.isOrderedBeforeByString(a.id, b.id)
        }
        guard !big.isEmpty else { return nil }
        let bigIds = Set(big.map(\.id))
        let rest = items.filter { !bigIds.contains($0.id) }
        guard rest.count >= 2 else { return nil }
        let inverse = big.reduce(0.0) { $0 + 1 / $1.ratio }
        let gaps = Double(big.count - 1) * gap
        let guessWidth = exp(big.reduce(0.0) { $0 + 0.5 * log($1.area * $1.ratio) } / Double(big.count))
        let guessHeight = (guessWidth * inverse + gaps) * heightFactor
        let columnGuess = (guessHeight - gaps) / inverse
        let aspect = Double(content.width) / max(Double(content.height), 1)
        let restContent = CGRect(x: content.minX + CGFloat(columnGuess + gap), y: content.minY,
                                 width: CGFloat(max(1, guessHeight * aspect - columnGuess - gap)), height: CGFloat(guessHeight))
        // The column is only worth having in band, so its rows are too.
        guard let rows = packPass(rest, content: restContent, gap: gap, hard: featuredBands),
              !rows.frames.isEmpty else { return nil }
        func snap(_ v: Double) -> Double { (v / grid).rounded() * grid }
        let left = snap(Double(content.minX)), top = snap(Double(content.minY)), gridGap = snap(gap)
        let total = Double(rows.content.height)
        let columnWidthRaw = (total - gaps) / inverse
        let restLeft = snap(left + columnWidthRaw + gridGap)
        let columnWidth = restLeft - gridGap - left
        guard columnWidth > 0 else { return nil }
        for tile in big {
            let h = columnWidth / tile.ratio
            guard columnWidth >= tile.minW - 1e-6, h >= tile.minH - 1e-6 else { return nil }
            if featuredBands {
                let change = columnWidth * h / tile.area
                guard change >= tileAreaFloor - 1e-6, change <= tileAreaHardCap + 1e-6 else { return nil }
            }
        }
        let dx = restLeft - snap(Double(rows.content.minX))
        var frames: [UUID: TileFrame] = [:]
        for (id, f) in rows.frames { frames[id] = TileFrame(x: f.x + dx, y: f.y, width: f.width, height: f.height) }
        let bottom = snap(top + total)
        var y = top
        for (k, tile) in big.enumerated() {
            let end = k == big.count - 1 ? bottom : snap(y + columnWidth / tile.ratio)
            frames[tile.id] = TileFrame(x: left, y: y, width: columnWidth, height: end - y)
            y = end + gridGap
        }
        let right = Double(rows.content.maxX) + dx
        return Result(frames: frames, content: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                      scale: rows.scale)
    }

    /// One score for any finished layout: every flexible tile's squared log
    /// change of area plus twice its ratio change (mean, plus half the worst),
    /// any tile outside its hard band ruled out, plus the zone's change in each
    /// dimension at the grow and shrink weights.
    private static func score(_ result: Result, items: [Item], content: CGRect) -> Double {
        var total = 0.0, worst = 0.0, counted = 0.0
        for item in items where item.fixed == nil && item.extraWidth == 0 {
            guard let f = result.frames[item.id], f.width > 0, f.height > 0 else { continue }
            let l = log(f.width * f.height / item.area)
            let shape = log((f.width / f.height) / item.ratio)
            let change = l * l + 2 * shape * shape + capPenalty(l)
            total += change; worst = max(worst, change); counted += 1
            if featuredBands, l < log(tileAreaFloor) - 0.01 || l > log(tileAreaHardCap) + 0.01 { total += 1e6 }
        }
        var zone = 0.0
        for (now, was) in [(Double(result.content.width), Double(content.width)), (Double(result.content.height), Double(content.height))] where was > 0 {
            let change = log(max(now, 1) / was)
            zone += (change > 0 ? growWeight : shrinkWeight) * change * change
        }
        return (counted > 0 ? total / counted + worst / 2 : 0) + zone
    }

    /// With the hard band on, first a pass that accepts only layouts keeping
    /// every tile inside its band; the soft pass only when none exists.
    private static func packItems(_ items: [Item], content: CGRect, gap: Double) -> Result {
        if featuredBands, let inBand = packPass(items, content: content, gap: gap, hard: true) { return inBand }
        return packPass(items, content: content, gap: gap, hard: false) ?? Result(frames: [:], content: content, scale: 1)
    }

    private static func packPass(_ items: [Item], content: CGRect, gap: Double, hard: Bool) -> Result? {
        var height = max(Double(content.height), 1)

        // Width grows only for a tile that cannot fit across at its minimum.
        var minimumWidth = 1.0
        for item in items {
            if let fixed = item.fixed { minimumWidth = max(minimumWidth, Double(fixed.width)) }
            else { minimumWidth = max(minimumWidth, max(item.minW, item.minH * item.ratioMin) + item.extraWidth) }
        }
        var width = max(Double(content.width), minimumWidth)
        let flat = Flat(items)
        defer { flat.free() }
        func solveOne(_ w: Double, _ h: Double) -> Layout? {
            guard let layout = solve(flat, width: w, height: h, gap: gap, hard: hard) else { return nil }
            return !hard || layout.withinBand ? layout : nil
        }
        var chosen = solveOne(width, height)
        var bestCost = chosen?.cost ?? .infinity
        // A zone too big for its tiles shrinks, keeping its proportions: try
        // uniform scales k < 1 (whole points), each charged the shrink weight
        // once per dimension, so for the same area a proportional shrink is
        // cheaper than a height-only one and the zone keeps its shape. Only
        // when the tiles would be stretched past the ceiling, the zone would
        // lose more than a tenth of its height, or (in band) nothing fit yet.
        let needsSearch = chosen.map { $0.stretch > areaCeiling || $0.total < 0.9 * height } ?? true
        if needsSearch {
            let originalWidth = width, originalHeight = height
            let kMin = max(minimumWidth / originalWidth, 0.25)
            if kMin < 1 {
                var bestStep: Double?
                func attempt(_ step: Double) {
                    let k = pow(kMin, step / 10)
                    let w = max(minimumWidth, (originalWidth * k).rounded(.down))
                    let h = max(1, (originalHeight * k).rounded(.down))
                    // A layout's own cost is never negative, so the shrink charge
                    // alone bounds this attempt: skip any that cannot win.
                    let charge = shrinkWeight * (pow(log(w / originalWidth), 2) + pow(log(h / originalHeight), 2))
                    guard charge < bestCost - 1e-12 else { return }
                    guard let layout = solveOne(w, h) else { return }
                    let cost = layout.cost + charge
                    if cost < bestCost - 1e-12 { bestCost = cost; chosen = layout; width = w; height = h; bestStep = step }
                }
                // Ten coarse steps, then seven between the best one's neighbours.
                // Each set is tried nearest first to where the best is likely
                // (areas scale with k², so k ≈ √(ceiling / stretch)), so the
                // shrink charge prunes the rest early. The minimum over the
                // set is the same in any order.
                func nearestFirst(_ steps: [Double], to centre: Double) -> [Double] {
                    steps.sorted { a, b in
                        let da = abs(a - centre), db = abs(b - centre)
                        return da < db || (da == db && a < b)
                    }
                }
                let stretch = chosen?.stretch ?? 0
                let guess: Double = stretch > areaCeiling ? 10 * log(sqrt(areaCeiling / stretch)) / log(kMin) : (chosen == nil ? 5 : 1)
                for step in nearestFirst((1...10).map { Double($0) }, to: guess) { attempt(step) }
                if let coarse = bestStep {
                    let fine: [Double] = [1, 2, 3, 5, 6, 7, 8].map { coarse - 1 + Double($0) / 4 }
                    for step in nearestFirst(fine, to: coarse) { attempt(step) }
                }
                // In-band layouts come and go with the width (a row must justify
                // exactly), so when the steps above found none, look evenly
                // between the smallest width and the zone's.
                if hard && chosen == nil {
                    for step in 0..<20 {
                        let w = (minimumWidth + (originalWidth - minimumWidth) * Double(step) / 19).rounded(.down)
                        let h = max(1, (originalHeight * w / originalWidth).rounded(.down))
                        guard let layout = solveOne(w, h) else { continue }
                        let cost = layout.cost + shrinkWeight * (pow(log(w / originalWidth), 2) + pow(log(h / originalHeight), 2))
                        if cost < bestCost - 1e-12 { bestCost = cost; chosen = layout; width = w; height = h }
                    }
                }
            }
        }
        guard var chosen else { return nil }

        // Place, every edge on the 1/64 pt grid: world and zone-local frames
        // then convert exactly both ways, which the canvas requires before it
        // commits a layered tile. The last tile of a justified row and the last
        // row end exactly on the content edge.
        func snap(_ v: Double) -> Double { (v / grid).rounded() * grid }
        let left = snap(Double(content.minX)), top = snap(Double(content.minY))
        let gridGap = snap(gap)
        let right = snap(left + width), bottom = snap(top + chosen.total)
        var frames: [UUID: TileFrame] = [:]
        var y = top
        if sizeGroupedRows {
            // Tallest row on top, so a re-tidy reads the rows back in order.
            chosen.rows = chosen.rows.enumerated().sorted { a, b in
                a.element.height != b.element.height ? a.element.height > b.element.height : a.offset < b.offset
            }.map(\.element)
        }
        for (rowIndex, row) in chosen.rows.enumerated() {
            let rowBottom = rowIndex == chosen.rows.count - 1 ? bottom : snap(y + row.height)
            if let band = row.featured {
                // The big tile's column, and the rows beside it justified into
                // the rest of the width, the last ending on the band's bottom.
                let anchorEdge = band.anchorLeft ? snap(left + band.anchorWidth) : snap(right - band.anchorWidth)
                let anchorFrame = band.anchorLeft
                    ? TileFrame(x: left, y: y, width: anchorEdge - left, height: rowBottom - y)
                    : TileFrame(x: anchorEdge, y: y, width: right - anchorEdge, height: rowBottom - y)
                frames[items[band.anchor].id] = anchorFrame
                let runLeft = band.anchorLeft ? anchorEdge + gridGap : left
                let runRight = band.anchorLeft ? right : anchorEdge - gridGap
                var subY = y
                for (subIndex, sub) in band.subRows.enumerated() {
                    let subBottom = subIndex == band.subRows.count - 1 ? rowBottom : snap(subY + sub.height)
                    let subRow = Row(start: sub.start, end: sub.end, height: sub.height, heightMin: sub.height, heightMax: sub.height)
                    let widths = rowWidths(flat, row: subRow, height: sub.height, width: runRight - runLeft, gap: gap)
                    var x = runLeft
                    for (offset, index) in (sub.start..<sub.end).enumerated() {
                        let edge = index == sub.end - 1 ? runRight : snap(x + widths.values[offset])
                        frames[items[index].id] = TileFrame(x: x, y: subY, width: edge - x, height: subBottom - subY)
                        x = edge + gridGap
                    }
                    subY = subBottom + gridGap
                }
                y = rowBottom + gridGap
                continue
            }
            let widths = rowWidths(flat, row: row, height: row.height, width: width, gap: gap)
            var x = left
            for (offset, index) in (row.start..<row.end).enumerated() {
                let item = items[index]
                let frame: TileFrame
                if let fixed = item.fixed {
                    frame = TileFrame(x: x, y: y, width: Double(fixed.width), height: Double(fixed.height))
                } else {
                    let edge = index == row.end - 1 && widths.justified ? right : snap(x + widths.values[offset])
                    frame = TileFrame(x: x, y: y, width: edge - x, height: rowBottom - y)
                }
                if let block = item.block {
                    placeBlock(block, in: frame, gap: gridGap, snap: snap, into: &frames)
                } else {
                    frames[item.id] = frame
                }
                x = snap(frame.x + frame.width) + gridGap
            }
            y = rowBottom + gridGap
        }
        return Result(
            frames: frames,
            content: CGRect(x: left, y: top, width: right - left, height: bottom - top),
            scale: chosen.scale)
    }

    // MARK: - Order and clusters

    /// The lead on the left at the block's full height; each helper column of
    /// q × the lead's width, its helpers splitting the height equally. Every
    /// column has the same snapped width and the lead takes the rounding, so a
    /// tidied block reads back to the same q; the last helper of a column ends
    /// exactly on the block's bottom.
    private static func placeBlock(_ block: Block, in frame: TileFrame, gap: Double,
                                   snap: (Double) -> Double, into frames: inout [UUID: TileFrame]) {
        let columns = Double(block.columns.count)
        let flexible = frame.width - columns * gap
        let columnWidth = snap(block.q * flexible / (1 + block.q * columns))
        let right = frame.x + frame.width, bottom = frame.y + frame.height
        let leadRight = right - columns * (columnWidth + gap)
        frames[block.lead] = TileFrame(x: frame.x, y: frame.y, width: leadRight - frame.x, height: frame.height)
        for (c, column) in block.columns.enumerated() {
            let left = leadRight + gap + Double(c) * (columnWidth + gap)
            let share = (frame.height - Double(column.count - 1) * gap) / Double(column.count)
            var y = frame.y
            for (r, id) in column.enumerated() {
                let end = r == column.count - 1 ? bottom : snap(y + share)
                frames[id] = TileFrame(x: left, y: y, width: columnWidth, height: end - y)
                y = end + gap
            }
        }
    }

    /// Members as packing items in reading order: lines of tiles by top edge,
    /// then x; a lead with helpers present becomes one block item where the first
    /// of them reads.
    private static func orderedItems(_ members: [Member], gap: Double) -> [Item] {
        let sorted = members.sorted {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return UUID.isOrderedBeforeByString($0.id, $1.id)
        }
        var lines: [[Member]] = []
        var lineTop = 0.0, lineShortest = 0.0
        for member in sorted {
            if lines.isEmpty || member.frame.y >= lineTop + lineShortest / 2 {
                lines.append([member])
                lineTop = member.frame.y
                lineShortest = member.frame.height
            } else {
                lines[lines.count - 1].append(member)
                lineShortest = min(lineShortest, member.frame.height)
            }
        }
        let flat = lines.flatMap { line in
            line.sorted {
                if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
                return UUID.isOrderedBeforeByString($0.id, $1.id)
            }
        }
        // Leads present with at least one helper present.
        let present = Set(flat.map(\.id))
        let leads = Set(flat.compactMap { m in m.clusterLead.flatMap { $0 != m.id && present.contains($0) ? $0 : nil } })
        func leadOf(_ m: Member) -> UUID? {
            if leads.contains(m.id) { return m.id }
            if let lead = m.clusterLead, leads.contains(lead) { return lead }
            return nil
        }
        var emitted = Set<UUID>()
        var items: [Item] = []
        for member in flat where !emitted.contains(member.id) {
            guard let leadId = leadOf(member), let lead = flat.first(where: { $0.id == leadId }) else {
                emitted.insert(member.id)
                items.append(item(for: member))
                continue
            }
            // Helpers column by column: by x, then y, so a tidied block reads
            // back into the same columns.
            let helpers = flat.filter { $0.id != leadId && $0.clusterLead == leadId }.sorted {
                if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
                if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
                return UUID.isOrderedBeforeByString($0.id, $1.id)
            }
            emitted.insert(leadId)
            helpers.forEach { emitted.insert($0.id) }
            items.append(blockItem(lead: lead, helpers: helpers, gap: gap))
        }
        return sizeGroupedRows ? groupedBySize(items) : items
    }

    /// Items tallest preferred height first; a run whose heights are each within
    /// 2% of the one before keeps reading order (a fixed-size tile sits in a
    /// row slightly taller than itself). After a tidy every tile's
    /// preferred height is its row's height, so the order comes back the same.
    private static func groupedBySize(_ items: [Item]) -> [Item] {
        func flexibleHeight(_ item: Item) -> Double { sqrt(item.area / item.ratio) }
        // A fixed-size tile sitting in a row (sharing a flexible tile's top)
        // groups with that row, whose height it does not set.
        var fixedHeight: [Int: Double] = [:]
        for (i, item) in items.enumerated() {
            guard let fixed = item.fixed else { continue }
            // Its row is the shortest flexible tile on its top that is at least
            // as tall as it (a big tile's column starts on the same top).
            let rowMates = items.filter { $0.fixed == nil && abs($0.top - item.top) < 0.5 }.map(flexibleHeight)
                .filter { $0 >= Double(fixed.height) - 0.5 }
            fixedHeight[i] = rowMates.min() ?? Double(fixed.height)
        }
        func preferredHeight(_ index: Int) -> Double { fixedHeight[index] ?? flexibleHeight(items[index]) }
        let byHeight = items.indices.sorted {
            let a = preferredHeight($0), b = preferredHeight($1)
            return a != b ? a > b : $0 < $1
        }
        var classes: [[Int]] = []
        var previous = Double.infinity
        for index in byHeight {
            let h = preferredHeight(index)
            if classes.isEmpty || previous / h > 1.005 { classes.append([index]) } else { classes[classes.count - 1].append(index) }
            previous = h
        }
        return classes.flatMap { $0.sorted() }.map { items[$0] }
    }

    private static func blockItem(lead: Member, helpers: [Member], gap: Double) -> Item {
        let leadItem = item(for: lead)
        let leadW = max(1, lead.frame.width), leadH = max(1, lead.frame.height)
        let firstColumn = helpers.count > helpersInOneColumn ? (helpers.count + 1) / 2 : helpers.count
        let columns = [Array(helpers.prefix(firstColumn)), Array(helpers.dropFirst(firstColumn))].filter { !$0.isEmpty }
        let cols = Double(columns.count)
        // Column width q × the lead's: the helpers' width as they are now (576
        // at creation), within 0.5–1.5. A helper in a column of m is about
        // q × (lead ratio) × m wide per unit height, so the helper band becomes
        // a limit on the lead's ratio inside the block. Every bound here is a
        // constant, q or a count, so a tidied block reads back the same block.
        let meanHelperWidth = helpers.reduce(0.0) { $0 + $1.frame.width } / Double(helpers.count)
        let mMin = Double(columns.map(\.count).min() ?? 1), mMax = Double(columns.map(\.count).max() ?? 1)
        var q = min(max(meanHelperWidth / leadW, 0.5), 1.5)
        q = min(q, helperRatioBand.max / (leadItem.ratioMin * mMax))
        q = max(q, helperRatioBand.min / (leadItem.ratioMax * mMin))
        var leadLo = max(leadItem.ratioMin, helperRatioBand.min / (q * mMin))
        var leadHi = min(leadItem.ratioMax, helperRatioBand.max / (q * mMax))
        if leadLo > leadHi { leadLo = leadItem.ratioMin; leadHi = leadItem.ratioMax }
        let factor = 1 + q * cols
        let helperMinimum = helpers.map { $0.kind.map { TileGeometry.minimumSize(for: $0) } ?? $0.minimumSize }
        let helperMinW = helperMinimum.map { Double($0.width) }.max() ?? 1
        let helperMinH = helperMinimum.map { Double($0.height) }.max() ?? 1
        let leadMinW = max(leadItem.minW, helperMinW / q)
        var minH = leadItem.minH
        for column in columns { minH = max(minH, Double(column.count) * helperMinH + Double(column.count - 1) * gap) }
        // Current area of the block's flexible part: every member, plus the
        // inner column gaps a tidied block holds (so a tidied block costs zero).
        var area = leadW * leadH + helpers.reduce(0.0) { $0 + $1.frame.width * $1.frame.height }
        for column in columns { area += q * leadW * Double(column.count - 1) * gap }
        let leadRatio = min(max(leadW / leadH, leadLo), leadHi)
        var made = Item(
            id: lead.id, area: area,
            ratio: leadRatio * factor, ratioMin: leadLo * factor, ratioMax: leadHi * factor,
            minW: leadMinW * factor, minH: minH, fixed: nil,
            extraWidth: cols * gap,
            block: Block(lead: lead.id, columns: columns.map { $0.map(\.id) }, q: q))
        made.top = lead.frame.y
        return made
    }

    private static func item(for member: Member) -> Item {
        var made = itemShape(for: member)
        made.top = member.frame.y
        return made
    }

    private static func itemShape(for member: Member) -> Item {
        let w = max(1, member.frame.width), h = max(1, member.frame.height)
        let rule = member.kind.map(TileGeometry.shapeRule(for:)) ?? defaultRule
        let minimum = member.kind.map { TileGeometry.minimumSize(for: $0) } ?? member.minimumSize
        let minW = max(1, Double(minimum.width)), minH = max(1, Double(minimum.height))
        switch rule {
        case let .aspect(ratio):
            return Item(id: member.id, area: w * h, ratio: ratio, ratioMin: ratio, ratioMax: ratio, minW: minW, minH: minH, fixed: nil)
        case let .band(lo, hi):
            let ratio = min(max(w / h, lo), hi)
            return Item(id: member.id, area: w * h, ratio: ratio, ratioMin: lo, ratioMax: hi, minW: minW, minH: minH, fixed: nil)
        case .keep:
            return Item(id: member.id, area: w * h, ratio: w / h, ratioMin: w / h, ratioMax: w / h, minW: w, minH: h,
                        fixed: CGSize(width: w, height: h))
        }
    }

    private static func scaleGrid() -> [Double] {
        let steps = 24
        var grid = (0...steps).map { exp(log(areaFloor) + (log(areaCeiling) - log(areaFloor)) * Double($0) / Double(steps)) }
        grid.append(1)
        return grid
    }

    // MARK: - Rows

    /// Longest row considered. Eight tiles side by side is already a strip.
    private static let maxRowLength = 8

    /// The best layout at one content width: every candidate row evaluated
    /// once, then for each scale on the grid the row breaks of least cost, the
    /// heights fitted to the content height, and the cheapest result kept: the
    /// change to the tiles plus the change to the zone height; ties go to the
    /// scale nearest 1.
    private static func solve(_ f: Flat, width: Double, height: Double, gap: Double, hard: Bool = false) -> Layout? {
        let n = f.count
        // Every candidate row, once: table[start * maxRowLength + length - 1].
        var table = [Row?](repeating: nil, count: n * maxRowLength)
        var start = 0
        while start < n {
            var length = 1
            while length <= maxRowLength && start + length <= n {
                table[start * maxRowLength + length - 1] = evaluateRow(f, start: start, end: start + length, width: width, gap: gap, hard: hard)
                length += 1
            }
            start += 1
        }
        // The dynamic program reads plain numbers: Row.cost's terms, per row.
        let cells = n * maxRowLength
        let valid = UnsafeMutablePointer<Bool>.allocate(capacity: cells)
        let sumL = UnsafeMutablePointer<Double>.allocate(capacity: cells), sumL2 = UnsafeMutablePointer<Double>.allocate(capacity: cells)
        let flexCount = UnsafeMutablePointer<Double>.allocate(capacity: cells), shapeCost = UnsafeMutablePointer<Double>.allocate(capacity: cells)
        let cost = UnsafeMutablePointer<Double>.allocate(capacity: n + 1), choice = UnsafeMutablePointer<Int>.allocate(capacity: n + 1)
        defer {
            valid.deallocate(); sumL.deallocate(); sumL2.deallocate(); flexCount.deallocate(); shapeCost.deallocate()
            cost.deallocate(); choice.deallocate()
        }
        var cell = 0
        while cell < cells {
            if let row = table[cell] {
                valid[cell] = true
                sumL[cell] = row.sumL; sumL2[cell] = row.sumL2; flexCount[cell] = row.flexCount; shapeCost[cell] = row.shapeCost
            } else {
                valid[cell] = false
            }
            cell += 1
        }
        // Featured bands, by the item they end at.
        var featuredByEnd = [[Row]](repeating: [], count: n + 1)
        if hard && !sizeGroupedRows {
            for band in featuredCandidates(f, width: width, gap: gap) { featuredByEnd[band.end].append(band) }
        }
        var featuredPool: [Row] = []
        var evaluated: [[Int]: Layout] = [:]
        var best: Layout?
        for scale in scaleGrid() {
            let ls = log(scale)
            var reset = 0
            while reset <= n { cost[reset] = .infinity; choice[reset] = -1; reset += 1 }
            cost[0] = 0
            var end = 1
            while end <= n {
                var start = max(0, end - maxRowLength)
                while start < end {
                    let index = start * maxRowLength + end - start - 1
                    if cost[start].isFinite && valid[index] {
                        let total = cost[start] + (sumL2[index] - 2 * ls * sumL[index] + flexCount[index] * ls * ls + shapeCost[index])
                        if total < cost[end] - 1e-12 { cost[end] = total; choice[end] = index }
                    }
                    start += 1
                }
                for band in featuredByEnd[end] where cost[band.start].isFinite {
                    let total = cost[band.start] + band.cost(logScale: ls)
                    if total < cost[end] - 1e-12 {
                        cost[end] = total
                        featuredPool.append(band)
                        choice[end] = -2 - (featuredPool.count - 1)
                    }
                }
                end += 1
            }
            guard cost[n].isFinite else { continue }
            var rows: [Row] = []
            end = n
            while end > 0 {
                let picked: Row?
                if choice[end] >= 0 { picked = table[choice[end]] }
                else if choice[end] <= -2 { picked = featuredPool[-2 - choice[end]] }
                else { picked = nil }
                guard let row = picked else { break }
                rows.append(row)
                end = row.start
            }
            rows.reverse()
            var layout: Layout
            let key = rows.map { $0.featured == nil ? $0.start : -1 - $0.start * 1_000 - ($0.featured!.anchorLeft ? 0 : 500) - $0.featured!.subRows.count * 100 - $0.featured!.subRows[0].end }
            if let known = evaluated[key] {
                layout = known
            } else {
                let fitted = fitHeightsUnderCap(f, rows: rows, target: height - Double(rows.count - 1) * gap,
                                                width: width, gap: gap)
                let total = fitted.reduce(0) { $0 + $1.height } + Double(rows.count - 1) * gap
                let exact = abs(total - height) < 0.5
                let measured = measure(f, rows: fitted, width: width, gap: gap)
                let zoneTerm = exact ? 0 : (total > height ? growWeight : shrinkWeight) * pow(log(total / height), 2)
                layout = Layout(rows: fitted, total: total, scale: scale, cost: measured.deviation + zoneTerm,
                                exact: exact, stretch: measured.stretch, withinBand: featuredBands ? measured.withinBand : true)
                evaluated[key] = layout
            }
            layout.scale = scale
            guard let current = best else { best = layout; continue }
            if layout.withinBand != current.withinBand { if layout.withinBand { best = layout }; continue }
            if layout.cost < current.cost - 1e-12
                || (abs(layout.cost - current.cost) <= 1e-12 && abs(ls) < abs(log(current.scale))) {
                best = layout
            }
        }
        return best
    }

    /// One candidate row. The common case, where no tile's ratio clamps, does
    /// the same arithmetic as `rowRatios` + `waterFill`, in the same order,
    /// without allocating; a row where a clamp binds goes through them.
    private static func evaluateRow(_ f: Flat, start: Int, end: Int, width: Double, gap: Double, hard: Bool = false) -> Row? {
        if hard {
            // Whatever the widths, a flexible tile's area at row height h lies in
            // [ratioMin·h², ratioMax·h²]; its band needs √(0.5A/ratioMax) ≤ h ≤
            // √(2A/ratioMin). No common h means no row: reject before any work.
            var lo = 0.0, hi = Double.infinity
            var i = start
            while i < end {
                if !f.isFixed[i] && f.extra[i] == 0 {
                    lo = max(lo, (tileAreaFloor * f.area[i] / f.ratioMax[i]).squareRoot())
                    hi = min(hi, (tileAreaHardCap * f.area[i] / f.ratioMin[i]).squareRoot())
                }
                i += 1
            }
            if lo > hi * (1 + 1e-9) { return nil }
        }
        let classic = evaluateClassicRow(f, start: start, end: end, width: width, gap: gap, hard: hard)
        guard sizeGroupedRows, let fitted = evaluateAreaFitRow(f, start: start, end: end, width: width, gap: gap, hard: hard)
        else { return classic }
        guard let classic else { return fitted }
        return fitted.cost(logScale: 0) < classic.cost(logScale: 0) - 1e-12 ? fitted : classic
    }

    /// A row whose tiles keep their widths in proportion to their own width at
    /// their current area and preferred ratio, √(ratio × area), scaled to fill
    /// the row; the row's height is the one that best keeps every tile's area
    /// (the geometric mean of area ÷ width). A tile made several times the rest
    /// stays wider than its row mates instead of matching them. Fixed tiles and
    /// blocks keep the classic row.
    private static func evaluateAreaFitRow(_ f: Flat, start: Int, end: Int, width: Double, gap: Double, hard: Bool) -> Row? {
        let available = width - Double(end - start - 1) * gap
        guard available > 0 else { return nil }
        var total = 0.0
        var i = start
        while i < end {
            guard !f.isFixed[i], f.extra[i] == 0 else { return nil }
            total += sqrt(f.ratio[i] * f.area[i])
            i += 1
        }
        let scale = available / total
        var lo = 0.0, hi = Double.infinity, logSum = 0.0
        i = start
        while i < end {
            let w = sqrt(f.ratio[i] * f.area[i]) * scale
            guard w >= f.minW[i] - 1e-6 else { return nil }
            lo = max(lo, w / f.ratioMax[i], f.minH[i])
            hi = min(hi, w / f.ratioMin[i])
            if hard {
                lo = max(lo, tileAreaFloor * f.area[i] / w)
                hi = min(hi, tileAreaHardCap * f.area[i] / w)
            }
            logSum += log(f.area[i] / w)
            i += 1
        }
        guard lo <= hi + 1e-6 else { return nil }
        let height = min(max(exp(logSum / Double(end - start)), lo), hi)
        var row = Row(start: start, end: end, height: height, heightMin: lo, heightMax: max(lo, hi))
        row.areaFit = true
        i = start
        while i < end {
            let w = sqrt(f.ratio[i] * f.area[i]) * scale
            let l = log(w * height / f.area[i])
            let shape = log((w / height) / f.ratio[i])
            row.sumL += l
            row.sumL2 += l * l
            row.flexCount += 1
            row.shapeCost += 2 * shape * shape + capPenalty(l)
            i += 1
        }
        return row
    }

    /// An area-fit row's widths: √(ratio × area) per tile, scaled to fill.
    private static func areaFitWidths(_ f: Flat, start: Int, end: Int, width: Double, gap: Double) -> [Double] {
        let available = width - Double(end - start - 1) * gap
        var total = 0.0
        for i in start..<end { total += sqrt(f.ratio[i] * f.area[i]) }
        return (start..<end).map { sqrt(f.ratio[$0] * f.area[$0]) * available / total }
    }

    private static func evaluateClassicRow(_ f: Flat, start: Int, end: Int, width: Double, gap: Double, hard: Bool = false) -> Row? {
        var fixedWidth = 0.0, fixedHeight = 0.0, flexCount = 0
        var i = start
        while i < end {
            fixedWidth += f.extra[i]
            if f.isFixed[i] { fixedWidth += f.fixedW[i]; fixedHeight = max(fixedHeight, f.fixedH[i]) } else { flexCount += 1 }
            i += 1
        }
        let available = width - Double(end - start - 1) * gap - fixedWidth
        if flexCount == 0 {
            // Only fixed-size tiles: the row cannot be justified, and the width
            // it leaves is a hole. Allowed, but dear.
            guard available >= -0.5 else { return nil }
            let unused = max(0, available) / width
            return Row(start: start, end: end, height: fixedHeight, heightMin: fixedHeight, heightMax: fixedHeight,
                       shapeCost: Double(end - start) * 40 * unused * unused)
        }
        guard available > 0 else { return nil }
        var ratioSum = 0.0
        i = start
        while i < end { if !f.isFixed[i] { ratioSum += f.ratio[i] }; i += 1 }
        guard let band = heightBand(f, start: start, end: end, fixedHeight: fixedHeight, available: available) else { return nil }
        let (lo, hi) = band
        let natural = min(max(available / ratioSum, lo), hi)

        // rowRatios(natural), inline.
        let target = available / natural
        var loSum = 0.0, hiSum = 0.0, baseSum = 0.0
        i = start
        while i < end {
            if !f.isFixed[i] {
                let l = max(f.ratioMin[i], f.minW[i] / natural)
                loSum += l; hiSum += max(l, f.ratioMax[i])
            }
            i += 1
        }
        let slack = 1e-6 * max(target, 1)
        guard loSum <= target + slack, hiSum >= target - slack else { return nil }
        i = start
        while i < end { if !f.isFixed[i] { baseSum += f.ratio[i] }; i += 1 }
        let plain = target / baseSum
        var plainSum = 0.0
        i = start
        while i < end {
            if !f.isFixed[i] {
                let l = max(f.ratioMin[i], f.minW[i] / natural)
                plainSum += min(max(f.ratio[i] * plain, l), max(l, f.ratioMax[i]))
            }
            i += 1
        }
        let clampFree = baseSum > 0 && abs(plainSum - target) <= 1e-9 * max(target, 1)
        let clamped: [Double] = clampFree ? [] : (rowRatios(f, flex: (start..<end).filter { !f.isFixed[$0] },
                                                            height: natural, available: available) ?? [])
        if !clampFree && clamped.isEmpty { return nil }
        func ratio(_ i: Int, _ k: Int) -> Double {
            guard clampFree else { return clamped[k] }
            let l = max(f.ratioMin[i], f.minW[i] / natural)
            return min(max(f.ratio[i] * plain, l), max(l, f.ratioMax[i]))
        }

        // Fitting the heights may not push any tile past the per-tile cap; a
        // tile's area grows about linearly with its row's height at fixed width.
        var capHeight = Double.infinity
        var k = 0
        i = start
        while i < end {
            if !f.isFixed[i] {
                capHeight = min(capHeight, natural * tileAreaCap * f.area[i] / (ratio(i, k) * natural * natural))
                k += 1
            }
            i += 1
        }
        var row = Row(start: start, end: end, height: natural, heightMin: lo,
                      heightMax: max(natural, min(hi, capHeight)))
        if hard {
            // Every tile inside its hard area band at the natural height, and
            // the fit kept to heights where that stays true (a tile's area
            // grows about linearly with its row's height at fixed width).
            var bandLo = row.heightMin, bandHi = row.heightMax
            k = 0
            i = start
            while i < end {
                if !f.isFixed[i] {
                    let w = ratio(i, k) * natural
                    bandLo = max(bandLo, tileAreaFloor * f.area[i] / w)
                    bandHi = min(bandHi, tileAreaHardCap * f.area[i] / w)
                    k += 1
                }
                i += 1
            }
            guard bandLo <= bandHi + 1e-6 else { return nil }
            if natural < bandLo - 1e-6 || natural > bandHi + 1e-6 {
                // Move the row to the nearest height where every tile is in
                // band, its ratios recomputed there, and check again exactly.
                let moved = min(max(natural, bandLo), bandHi)
                guard let shifted = rowAt(f, start: start, end: end, height: moved, available: available,
                                          fixedHeight: fixedHeight) else { return nil }
                return shifted
            }
            row.heightMin = min(natural, bandLo)
            row.heightMax = max(natural, bandHi)
        }
        k = 0
        i = start
        while i < end {
            if !f.isFixed[i] {
                let r = ratio(i, k)
                let l = log(r * natural * natural / f.area[i])
                let shape = log(r / f.ratio[i])
                row.sumL += l
                row.sumL2 += l * l
                row.flexCount += 1
                row.shapeCost += 2 * shape * shape + capPenalty(l)
                k += 1
            }
            i += 1
        }
        i = start
        while i < end {
            if f.isFixed[i] {
                let slack = log(max(natural, 1) / max(f.fixedH[i], 1))
                row.shapeCost += 0.5 * slack * slack
            }
            i += 1
        }
        return row
    }

    /// Every featured band worth trying at this width: a big tile (at least
    /// `featureThreshold` × the median area, flexible, not a block) with two or
    /// three rows beside it, on its left (it leads the band in reading order) or
    /// its right (it follows the band's first row, which shares its top).
    private static func featuredCandidates(_ f: Flat, width: Double, gap: Double) -> [Row] {
        let n = f.count
        guard n >= 3 else { return [] }
        var areas: [Double] = []
        for i in 0..<n { areas.append(f.area[i]) }
        areas.sort()
        let median = areas.count % 2 == 1 ? areas[n / 2] : (areas[n / 2 - 1] + areas[n / 2]) / 2
        func plainFlex(_ i: Int) -> Bool { !f.isFixed[i] && f.extra[i] == 0 }
        var bands: [Row] = []
        // Splits of [start, end) into `parts` runs of 1…maxRowLength tiles.
        func splits(_ start: Int, _ end: Int, _ parts: Int) -> [[(Int, Int)]] {
            if parts == 1 { return end - start >= 1 && end - start <= maxRowLength ? [[(start, end)]] : [] }
            var out: [[(Int, Int)]] = []
            var cut = start + 1
            while cut <= end - (parts - 1) && cut - start <= maxRowLength {
                for rest in splits(cut, end, parts - 1) { out.append([(start, cut)] + rest) }
                cut += 1
            }
            return out
        }
        for a in 0..<n where plainFlex(a) && f.area[a] >= featureThreshold * median {
            // Anchor on the left: it leads; the rows follow it.
            var end = a + 3
            while end <= min(n, a + 1 + featureMaxTiles) {
                if (a + 1..<end).allSatisfy(plainFlex) {
                    for parts in 2...3 {
                        for runs in splits(a + 1, end, parts) {
                            if let band = evaluateFeatured(f, anchor: a, left: true, runs: runs, width: width, gap: gap) { bands.append(band) }
                        }
                    }
                }
                end += 1
            }
            // Anchor on the right: the first row precedes it.
            var first = a - 1
            while first >= max(0, a - maxRowLength) {
                guard plainFlex(first) else { break }
                var end = a + 2
                while end <= min(n, first + featureMaxTiles + 1) {
                    if (a + 1..<end).allSatisfy(plainFlex) {
                        for parts in 1...2 {
                            for rest in splits(a + 1, end, parts) {
                                if let band = evaluateFeatured(f, anchor: a, left: false, runs: [(first, a)] + rest,
                                                               width: width, gap: gap) { bands.append(band) }
                            }
                        }
                    }
                    end += 1
                }
                first -= 1
            }
        }
        return bands
    }

    /// A band at the tiles' preferred ratios. The rows beside the column are
    /// justified into W' = width − gap − anchorWidth; each row's height is
    /// (W' − its gaps) / Σ ratios, and the column's height H is their sum plus
    /// the gaps between them, with anchorWidth = ratio × H. That is linear in
    /// H, so H is solved directly. Nil if any tile would leave its hard area
    /// band or fall below its minimum.
    private static func evaluateFeatured(_ f: Flat, anchor: Int, left: Bool, runs: [(Int, Int)],
                                         width: Double, gap: Double) -> Row? {
        var numerator = Double(runs.count - 1) * gap, inverse = 0.0
        var sums: [Double] = []
        for (start, end) in runs {
            var ratioSum = 0.0
            for i in start..<end { ratioSum += f.ratio[i] }
            let fixed = Double(end - start - 1) * gap
            sums.append(ratioSum)
            numerator += (width - gap - fixed) / ratioSum
            inverse += 1 / ratioSum
        }
        let height = numerator / (1 + f.ratio[anchor] * inverse)
        let anchorWidth = f.ratio[anchor] * height
        let rest = width - gap - anchorWidth
        guard height > 0, rest > 0, anchorWidth >= f.minW[anchor], height >= f.minH[anchor] else { return nil }
        let segmentStart = min(anchor, runs[0].0)
        let segmentEnd = runs.last!.1
        var row = Row(start: segmentStart, end: segmentEnd, height: height, heightMin: height, heightMax: height)
        func add(_ i: Int, _ w: Double, _ h: Double) -> Bool {
            let l = log(w * h / f.area[i])
            guard l >= log(tileAreaFloor) - 1e-9, l <= log(tileAreaHardCap) + 1e-9,
                  w >= f.minW[i] - 1e-6, h >= f.minH[i] - 1e-6 else { return false }
            row.sumL += l; row.sumL2 += l * l; row.flexCount += 1
            return true
        }
        guard add(anchor, anchorWidth, height) else { return nil }
        var subRows: [(start: Int, end: Int, height: Double)] = []
        for ((start, end), ratioSum) in zip(runs, sums) {
            let h = (rest - Double(end - start - 1) * gap) / ratioSum
            guard h > 0 else { return nil }
            for i in start..<end { guard add(i, f.ratio[i] * h, h) else { return nil } }
            subRows.append((start, end, h))
        }
        row.featured = Featured(anchor: anchor, anchorLeft: left, anchorWidth: anchorWidth, subRows: subRows)
        return row
    }

    /// A row of [start, end) held at `height`: its ratios fitted there, every
    /// tile checked against its hard area band with its real width, the fit
    /// pinned to that height. Nil when a tile would leave its band.
    private static func rowAt(_ f: Flat, start: Int, end: Int, height: Double, available: Double, fixedHeight: Double) -> Row? {
        let flex = (start..<end).filter { !f.isFixed[$0] }
        guard height >= fixedHeight, let ratios = rowRatios(f, flex: flex, height: height, available: available) else { return nil }
        var row = Row(start: start, end: end, height: height, heightMin: height, heightMax: height)
        for (k, i) in flex.enumerated() {
            let l = log(ratios[k] * height * height / f.area[i])
            guard l >= log(tileAreaFloor) - 1e-9, l <= log(tileAreaHardCap) + 1e-9, height >= f.minH[i] - 1e-6 else { return nil }
            let shape = log(ratios[k] / f.ratio[i])
            row.sumL += l
            row.sumL2 += l * l
            row.flexCount += 1
            row.shapeCost += 2 * shape * shape
        }
        for i in start..<end where f.isFixed[i] {
            let slack = log(max(height, 1) / max(f.fixedH[i], 1))
            row.shapeCost += 0.5 * slack * slack
        }
        return row
    }

    /// The heights at which the row's flexible tiles can fill `available`
    /// exactly: at least every fixed tile, minimum height, and the height at
    /// which the widest allowed ratios fill the width; at most the height at
    /// which the narrowest allowed ratios (or minimum widths) fill it.
    private static func heightBand(_ f: Flat, start: Int, end: Int, fixedHeight: Double, available: Double) -> (Double, Double)? {
        var ratioMaxSum = 0.0, ratioMinSum = 0.0
        var i = start
        while i < end { if !f.isFixed[i] { ratioMaxSum += f.ratioMax[i] }; i += 1 }
        i = start
        while i < end { if !f.isFixed[i] { ratioMinSum += f.ratioMin[i] }; i += 1 }
        var lo = max(fixedHeight, available / ratioMaxSum)
        i = start
        while i < end { if !f.isFixed[i] { lo = max(lo, f.minH[i], f.minW[i] / f.ratioMax[i]) }; i += 1 }
        func narrowest(_ h: Double) -> Double {
            var total = 0.0
            var i = start
            while i < end { if !f.isFixed[i] { total += max(f.ratioMin[i] * h, f.minW[i]) }; i += 1 }
            return total
        }
        var hi = available / ratioMinSum
        if narrowest(hi) > available + 1e-9 {
            guard narrowest(lo) <= available + 1e-9 else { return nil }
            // narrowest(h) = Σ max(ratioMinᵢ·h, minWᵢ) is piecewise linear and
            // increasing, with a corner at each minWᵢ / ratioMinᵢ: walk the
            // corners to the segment where it reaches `available`, solve there.
            var corners: [(at: Double, ratioMin: Double, minW: Double)] = []
            var constant = 0.0, slope = 0.0
            for i in start..<end where !f.isFixed[i] {
                corners.append((f.minW[i] / f.ratioMin[i], f.ratioMin[i], f.minW[i]))
                constant += f.minW[i]
            }
            corners.sort { $0.at < $1.at }
            var root = Double.nan
            for corner in corners {
                if slope * corner.at + constant >= available {
                    root = slope > 0 ? (available - constant) / slope : corner.at
                    break
                }
                slope += corner.ratioMin
                constant -= corner.minW
            }
            if root.isNaN { root = (available - constant) / slope }
            hi = min(max(root, lo), hi)
        }
        guard lo <= hi + 1e-9 else { return nil }
        return (lo, max(lo, hi))
    }

    /// Ratios for the flexible tiles of a row of `height` so they sum to
    /// `available / height`: each the preferred ratio × λ, clamped into its band
    /// and its minimum width.
    private static func rowRatios(_ f: Flat, flex: [Int], height: Double, available: Double) -> [Double]? {
        let target = available / height
        // Clamp-free first, as `waterFill` would find it, without its arrays.
        var quickLo = 0.0, quickHi = 0.0, quickBase = 0.0
        for i in flex {
            let l = max(f.ratioMin[i], f.minW[i] / height)
            quickLo += l; quickHi += max(l, f.ratioMax[i])
        }
        let quickSlack = 1e-6 * max(target, 1)
        guard quickLo <= target + quickSlack, quickHi >= target - quickSlack else { return nil }
        for i in flex { quickBase += f.ratio[i] }
        if quickBase > 0 {
            let plain = target / quickBase
            var sum = 0.0
            for i in flex {
                let l = max(f.ratioMin[i], f.minW[i] / height)
                sum += min(max(f.ratio[i] * plain, l), max(l, f.ratioMax[i]))
            }
            if abs(sum - target) <= 1e-9 * max(target, 1) {
                return flex.map { i in
                    let l = max(f.ratioMin[i], f.minW[i] / height)
                    return min(max(f.ratio[i] * plain, l), max(l, f.ratioMax[i]))
                }
            }
        }
        var base = [Double](), lo = [Double](), hi = [Double]()
        base.reserveCapacity(flex.count); lo.reserveCapacity(flex.count); hi.reserveCapacity(flex.count)
        var loSum = 0.0, hiSum = 0.0
        for i in flex {
            let l = max(f.ratioMin[i], f.minW[i] / height), h = f.ratioMax[i]
            base.append(f.ratio[i]); lo.append(l); hi.append(max(l, h))
            loSum += l; hiSum += max(l, h)
        }
        let slack = 1e-6 * max(target, 1)
        guard loSum <= target + slack, hiSum >= target - slack else { return nil }
        return waterFill(base: base, lo: lo, hi: hi, target: target)
    }

    /// Values clamp(baseᵢ·λ, loᵢ, hiᵢ) whose sum is `target`, or the nearest
    /// extreme when none is. The sum is piecewise linear in λ between the
    /// breakpoints loᵢ/baseᵢ and hiᵢ/baseᵢ, so walking them finds λ exactly.
    private static func waterFill(base: [Double], lo: [Double], hi: [Double], target: Double) -> [Double] {
        let n = base.count
        var baseSum = 0.0, i = 0
        while i < n { baseSum += base[i]; i += 1 }
        var lambda = 0.0
        var settled = false
        if baseSum > 0 {
            let plain = target / baseSum
            var total = 0.0
            i = 0
            while i < n { total += min(max(base[i] * plain, lo[i]), hi[i]); i += 1 }
            if abs(total - target) <= 1e-9 * max(target, 1) { lambda = plain; settled = true }
        }
        if !settled {
            var points = [Double](repeating: 0, count: 1)
            points.reserveCapacity(2 * n + 1)
            i = 0
            while i < n {
                if base[i] > 0 { points.append(lo[i] / base[i]); points.append(hi[i] / base[i]) }
                i += 1
            }
            points.sort()
            func sum(_ value: Double) -> Double {
                var total = 0.0, j = 0
                while j < n { total += min(max(base[j] * value, lo[j]), hi[j]); j += 1 }
                return total
            }
            let last = points[points.count - 1]
            if sum(last) <= target {
                lambda = last
            } else {
                var previous = points[0], previousSum = sum(previous)
                lambda = previous
                if previousSum < target {
                    var k = 1
                    while k < points.count {
                        let point = points[k]
                        k += 1
                        guard point > previous else { continue }
                        let pointSum = sum(point)
                        if pointSum >= target {
                            lambda = previous + (point - previous) * (target - previousSum) / (pointSum - previousSum)
                            break
                        }
                        previous = point
                        previousSum = pointSum
                        lambda = previous
                    }
                }
            }
        }
        var out = [Double](repeating: 0, count: n)
        i = 0
        while i < n { out[i] = min(max(base[i] * lambda, lo[i]), hi[i]); i += 1 }
        return out
    }

    private static func rowWidths(_ f: Flat, row: Row, height: Double, width: Double, gap: Double)
        -> (values: [Double], justified: Bool)
    {
        if row.areaFit { return (areaFitWidths(f, start: row.start, end: row.end, width: width, gap: gap), true) }
        var fixedWidth = 0.0
        var flex: [Int] = []
        for i in row.start..<row.end {
            fixedWidth = fixedWidth + f.fixedW[i] + f.extra[i]
            if !f.isFixed[i] { flex.append(i) }
        }
        let available = width - Double(row.end - row.start - 1) * gap - fixedWidth
        guard !flex.isEmpty, let ratios = rowRatios(f, flex: flex, height: height, available: available) else {
            return ((row.start..<row.end).map { f.fixedW[$0] + f.extra[$0] }, false)
        }
        var values: [Double] = []
        values.reserveCapacity(row.end - row.start)
        var k = 0
        for i in row.start..<row.end {
            if f.isFixed[i] { values.append(f.fixedW[i]) } else { values.append(ratios[k] * height + f.extra[i]); k += 1 }
        }
        // A row ending in a fixed tile is left-aligned exactly; the flexible
        // tiles already sum to the width.
        return (values, !f.isFixed[row.end - 1])
    }

    /// Spread `target` over the rows inside each row's height band: every row
    /// scaled by one factor μ, clamped. When no μ reaches it, the extreme stands
    /// and the zone height changes to match.
    private static func fitHeights(rows: [Row], target: Double) -> [Row] {
        var natural = 0.0
        for row in rows { natural += row.height }
        if abs(natural - target) < 1e-9 { return rows }
        let heights = waterFill(base: rows.map(\.height), lo: rows.map(\.heightMin),
                                hi: rows.map { max($0.heightMin, $0.heightMax) }, target: target)
        var fitted = rows
        for i in fitted.indices { fitted[i].height = heights[i] }
        return fitted
    }

    /// `fitHeights`, then: a row whose fitted height pushes any tile past
    /// `tileAreaCap` (band clamps move width between tiles as a row grows, so the
    /// row's own estimate can miss) gets its exact limit, found by bisection
    /// between its natural height and the fitted one, and the fit runs again.
    private static func fitHeightsUnderCap(_ f: Flat, rows: [Row], target: Double, width: Double, gap: Double) -> [Row] {
        var bounded = rows
        var fitted = fitHeights(rows: bounded, target: target)
        func exceeds(_ row: Row, _ h: Double) -> Bool {
            let widths = rowWidths(f, row: row, height: h, width: width, gap: gap).values
            for (offset, index) in (row.start..<row.end).enumerated() where !f.isFixed[index] {
                if (widths[offset] - f.extra[index]) * h > tileAreaCap * f.area[index] * (1 + 1e-9) { return true }
            }
            return false
        }
        for _ in 0..<3 {
            var changed = false
            for i in fitted.indices where fitted[i].height > bounded[i].height && exceeds(bounded[i], fitted[i].height) {
                var low = bounded[i].height, high = fitted[i].height
                if exceeds(bounded[i], low) { bounded[i].heightMax = low; changed = true; continue }
                for _ in 0..<40 {
                    let middle = (low + high) / 2
                    if exceeds(bounded[i], middle) { high = middle } else { low = middle }
                }
                bounded[i].heightMax = max(bounded[i].heightMin, low)
                changed = true
            }
            if !changed { break }
            fitted = fitHeights(rows: bounded, target: target)
        }
        return fitted
    }

    /// Squared log change of every tile's area plus twice its ratio change,
    /// against the tile as it is now: the mean, plus half the worst so no single
    /// tile is sacrificed to the rest; and the geometric mean area change.
    private static func measure(_ f: Flat, rows: [Row], width: Double, gap: Double) -> (deviation: Double, stretch: Double, withinBand: Bool) {
        var total = 0.0, worst = 0.0, logSum = 0.0, flex = 0.0
        var withinBand = true
        func record(_ index: Int, _ w: Double, _ h: Double) {
            let areaDev = log(max(w * h, 1e-9) / f.area[index])
            let shapeDev = log(max(w / h, 1e-9) / f.ratio[index])
            let change = areaDev * areaDev + 2 * shapeDev * shapeDev + capPenalty(areaDev)
            total += change
            worst = max(worst, change)
            logSum += areaDev
            flex += 1
            if areaDev < log(tileAreaFloor) - 0.01 || areaDev > log(tileAreaHardCap) + 0.01 { withinBand = false }
        }
        for row in rows {
            if let band = row.featured {
                record(band.anchor, band.anchorWidth, row.height)
                let rest = width - gap - band.anchorWidth
                for sub in band.subRows {
                    let subRow = Row(start: sub.start, end: sub.end, height: sub.height, heightMin: sub.height, heightMax: sub.height)
                    let widths = rowWidths(f, row: subRow, height: sub.height, width: rest, gap: gap).values
                    for (offset, index) in (sub.start..<sub.end).enumerated() { record(index, widths[offset], sub.height) }
                }
                continue
            }
            let widths = rowWidths(f, row: row, height: row.height, width: width, gap: gap).values
            for (offset, index) in (row.start..<row.end).enumerated() where !f.isFixed[index] {
                record(index, widths[offset] - f.extra[index], row.height)
            }
        }
        return (total / Double(max(f.count, 1)) + worst / 2, flex > 0 ? exp(logSum / flex) : 1, withinBand)
    }
}
