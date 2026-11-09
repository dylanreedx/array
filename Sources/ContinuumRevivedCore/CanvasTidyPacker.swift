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
///    lead on the left, its helpers stacked in columns beside it, each column's
///    heights (with gaps) summing to the lead's height. Only the lead takes the
///    agent band; helpers are shaped by the block (`.plans/auto-layout-night`).
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
    }

    /// A lead with its helpers. The item's flexible width is the lead's width ×
    /// (1 + q × columns): each helper column is q × the lead's width.
    private struct Block {
        var lead: UUID
        var columns: [[UUID]]
        var q: Double
    }

    /// Helpers stacked per column beside their lead.
    public static let helpersPerColumn = 3

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
    }

    public static func pack(members: [Member], content: CGRect, gap rawGap: Double) -> Result {
        let gap = max(0, rawGap.isFinite ? rawGap : 0)
        guard !members.isEmpty else { return Result(frames: [:], content: content, scale: 1) }
        let items = orderedItems(members, gap: gap)
        var height = max(Double(content.height), 1)

        // Width grows only for a tile that cannot fit across at its minimum.
        var minimumWidth = 1.0
        for item in items {
            if let fixed = item.fixed { minimumWidth = max(minimumWidth, Double(fixed.width)) }
            else { minimumWidth = max(minimumWidth, max(item.minW, item.minH * item.ratioMin) + item.extraWidth) }
        }
        var width = max(Double(content.width), minimumWidth)
        guard var chosen = solve(items: items, width: width, height: height, gap: gap) else {
            return Result(frames: [:], content: content, scale: 1)
        }
        // A zone too big for its tiles shrinks, keeping its proportions: try
        // uniform scales k < 1 (whole points), each charged the shrink weight
        // once per dimension, so for the same area a proportional shrink is
        // cheaper than a height-only one and the zone keeps its shape. Only
        // when the tiles would be stretched past the ceiling or the zone would
        // lose more than a tenth of its height.
        if chosen.stretch > areaCeiling || chosen.total < 0.9 * height {
            let originalWidth = width, originalHeight = height
            var bestCost = chosen.cost
            let kMin = max(minimumWidth / originalWidth, 0.25)
            if kMin < 1 {
                for step in 1...10 {
                    let k = pow(kMin, Double(step) / 10)
                    let w = max(minimumWidth, (originalWidth * k).rounded(.down))
                    let h = max(1, (originalHeight * k).rounded(.down))
                    guard let layout = solve(items: items, width: w, height: h, gap: gap) else { continue }
                    let cost = layout.cost + shrinkWeight * (pow(log(w / originalWidth), 2) + pow(log(h / originalHeight), 2))
                    if cost < bestCost - 1e-12 { bestCost = cost; chosen = layout; width = w; height = h }
                }
            }
        }

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
        for (rowIndex, row) in chosen.rows.enumerated() {
            let rowBottom = rowIndex == chosen.rows.count - 1 ? bottom : snap(y + row.height)
            let widths = rowWidths(items: items, row: row, height: row.height, width: width, gap: gap)
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
    /// q × the lead's width, its helpers splitting the height. The last column
    /// and the last helper of a column end exactly on the block's edges.
    private static func placeBlock(_ block: Block, in frame: TileFrame, gap: Double,
                                   snap: (Double) -> Double, into frames: inout [UUID: TileFrame]) {
        let columns = Double(block.columns.count)
        let flexible = frame.width - columns * gap
        let leadWidth = flexible / (1 + block.q * columns)
        let right = frame.x + frame.width, bottom = frame.y + frame.height
        var x = snap(frame.x + leadWidth)
        frames[block.lead] = TileFrame(x: frame.x, y: frame.y, width: x - frame.x, height: frame.height)
        for (c, column) in block.columns.enumerated() {
            let left = x + gap
            let edge = c == block.columns.count - 1 ? right : snap(left + block.q * leadWidth)
            let share = (frame.height - Double(column.count - 1) * gap) / Double(column.count)
            var y = frame.y
            for (r, id) in column.enumerated() {
                let end = r == column.count - 1 ? bottom : snap(y + share)
                frames[id] = TileFrame(x: left, y: y, width: edge - left, height: end - y)
                y = end + gap
            }
            x = edge
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
        return items
    }

    private static func blockItem(lead: Member, helpers: [Member], gap: Double) -> Item {
        let leadItem = item(for: lead)
        let leadW = max(1, lead.frame.width), leadH = max(1, lead.frame.height)
        let perColumn = helpersPerColumn
        let columns = stride(from: 0, to: helpers.count, by: perColumn).map {
            Array(helpers[$0..<min($0 + perColumn, helpers.count)])
        }
        let cols = Double(columns.count)
        // Column width relative to the lead's: the helpers' mean width as they
        // are now (a fresh helper is its lead's width), within reason.
        let meanHelperWidth = helpers.reduce(0.0) { $0 + $1.frame.width } / Double(helpers.count)
        let q = min(max(meanHelperWidth / leadW, 0.5), 1.25)
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
        let leadRatio = min(max(leadW / leadH, leadItem.ratioMin), leadItem.ratioMax)
        return Item(
            id: lead.id, area: area,
            ratio: leadRatio * factor, ratioMin: leadItem.ratioMin * factor, ratioMax: leadItem.ratioMax * factor,
            minW: leadMinW * factor, minH: minH, fixed: nil,
            extraWidth: cols * gap,
            block: Block(lead: lead.id, columns: columns.map { $0.map(\.id) }, q: q))
    }

    private static func item(for member: Member) -> Item {
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
    private static func solve(items: [Item], width: Double, height: Double, gap: Double) -> Layout? {
        let n = items.count
        var table = [[Row?]](repeating: [], count: n)
        for start in 0..<n {
            table[start] = (1...min(maxRowLength, n - start)).map { length in
                evaluateRow(items: items, start: start, end: start + length, width: width, gap: gap)
            }
        }
        var evaluated: [[Int]: Layout] = [:]
        var best: Layout?
        for scale in scaleGrid() {
            let ls = log(scale)
            var cost = [Double](repeating: .infinity, count: n + 1)
            var choice = [Row?](repeating: nil, count: n + 1)
            cost[0] = 0
            for end in 1...n {
                for start in max(0, end - maxRowLength)..<end where cost[start].isFinite {
                    guard let row = table[start][end - start - 1] else { continue }
                    let total = cost[start] + row.cost(logScale: ls)
                    if total < cost[end] - 1e-12 { cost[end] = total; choice[end] = row }
                }
            }
            guard cost[n].isFinite else { continue }
            var rows: [Row] = []
            var end = n
            while end > 0, let row = choice[end] { rows.append(row); end = row.start }
            rows.reverse()
            var layout: Layout
            if let known = evaluated[rows.map(\.start)] {
                layout = known
            } else {
                let fitted = fitHeights(rows: rows, target: height - Double(rows.count - 1) * gap)
                let total = fitted.reduce(0) { $0 + $1.height } + Double(rows.count - 1) * gap
                let exact = abs(total - height) < 0.5
                let measured = measure(items: items, rows: fitted, width: width, gap: gap)
                let zoneTerm = exact ? 0 : (total > height ? growWeight : shrinkWeight) * pow(log(total / height), 2)
                layout = Layout(rows: fitted, total: total, scale: scale, cost: measured.deviation + zoneTerm,
                                exact: exact, stretch: measured.stretch)
                evaluated[rows.map(\.start)] = layout
            }
            layout.scale = scale
            guard let current = best else { best = layout; continue }
            if layout.cost < current.cost - 1e-12
                || (abs(layout.cost - current.cost) <= 1e-12 && abs(ls) < abs(log(current.scale))) {
                best = layout
            }
        }
        return best
    }

    private static func evaluateRow(items: [Item], start: Int, end: Int, width: Double, gap: Double) -> Row? {
        let slice = items[start..<end]
        var fixedWidth = 0.0, fixedHeight = 0.0
        for item in slice {
            fixedWidth += item.extraWidth
            if let f = item.fixed { fixedWidth += Double(f.width); fixedHeight = max(fixedHeight, Double(f.height)) }
        }
        let available = width - Double(end - start - 1) * gap - fixedWidth
        var flex: [Item] = []
        flex.reserveCapacity(end - start)
        for item in slice where item.fixed == nil { flex.append(item) }
        if flex.isEmpty {
            // Only fixed-size tiles: the row cannot be justified, and the width
            // it leaves is a hole. Allowed, but dear.
            guard available >= -0.5 else { return nil }
            let unused = max(0, available) / width
            return Row(start: start, end: end, height: fixedHeight, heightMin: fixedHeight, heightMax: fixedHeight,
                       shapeCost: Double(end - start) * 40 * unused * unused)
        }
        guard available > 0 else { return nil }
        let ratioSum = flex.reduce(0.0) { $0 + $1.ratio }
        guard let band = heightBand(flex: flex, fixedHeight: fixedHeight, available: available) else { return nil }
        let (lo, hi) = band
        let natural = min(max(available / ratioSum, lo), hi)
        guard let ratios = rowRatios(flex: flex, height: natural, available: available) else { return nil }
        // Fitting the heights may not push any tile past the per-tile cap; a
        // tile's area grows about linearly with its row's height at fixed width.
        var capHeight = Double.infinity
        for (item, ratio) in zip(flex, ratios) {
            capHeight = min(capHeight, natural * tileAreaCap * item.area / (ratio * natural * natural))
        }
        var row = Row(start: start, end: end, height: natural, heightMin: lo,
                      heightMax: max(natural, min(hi, capHeight)))
        for (item, ratio) in zip(flex, ratios) {
            let l = log(ratio * natural * natural / item.area)
            let shape = log(ratio / item.ratio)
            row.sumL += l
            row.sumL2 += l * l
            row.flexCount += 1
            row.shapeCost += 2 * shape * shape + capPenalty(l)
        }
        for item in slice { if let f = item.fixed {
            let slack = log(max(natural, 1) / max(Double(f.height), 1))
            row.shapeCost += 0.5 * slack * slack
        } }
        return row
    }

    /// The heights at which the row's flexible tiles can fill `available`
    /// exactly: at least every fixed tile, minimum height, and the height at
    /// which the widest allowed ratios fill the width; at most the height at
    /// which the narrowest allowed ratios (or minimum widths) fill it.
    private static func heightBand(flex: [Item], fixedHeight: Double, available: Double) -> (Double, Double)? {
        let ratioMaxSum = flex.reduce(0.0) { $0 + $1.ratioMax }
        let ratioMinSum = flex.reduce(0.0) { $0 + $1.ratioMin }
        var lo = max(fixedHeight, available / ratioMaxSum)
        for item in flex { lo = max(lo, item.minH, item.minW / item.ratioMax) }
        func narrowest(_ h: Double) -> Double { flex.reduce(0.0) { $0 + max($1.ratioMin * h, $1.minW) } }
        var hi = available / ratioMinSum
        if narrowest(hi) > available + 1e-9 {
            var low = lo, high = hi
            guard narrowest(low) <= available + 1e-9 else { return nil }
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if narrowest(middle) <= available { low = middle } else { high = middle }
            }
            hi = low
        }
        guard lo <= hi + 1e-9 else { return nil }
        return (lo, max(lo, hi))
    }

    /// Ratios for the flexible tiles of a row of `height` so they sum to
    /// `available / height`: each the preferred ratio × λ, clamped into its band
    /// and its minimum width.
    private static func rowRatios(flex: [Item], height: Double, available: Double) -> [Double]? {
        let target = available / height
        var base = [Double](), lo = [Double](), hi = [Double]()
        base.reserveCapacity(flex.count); lo.reserveCapacity(flex.count); hi.reserveCapacity(flex.count)
        var loSum = 0.0, hiSum = 0.0
        for item in flex {
            let l = max(item.ratioMin, item.minW / height), h = item.ratioMax
            base.append(item.ratio); lo.append(l); hi.append(max(l, h))
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
        func values(_ lambda: Double) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            for i in 0..<n { out[i] = min(max(base[i] * lambda, lo[i]), hi[i]) }
            return out
        }
        func sum(_ lambda: Double) -> Double {
            var total = 0.0
            for i in 0..<n { total += min(max(base[i] * lambda, lo[i]), hi[i]) }
            return total
        }
        var baseSum = 0.0
        for b in base { baseSum += b }
        if baseSum > 0 {
            let plain = target / baseSum
            if abs(sum(plain) - target) <= 1e-9 * max(target, 1) { return values(plain) }
        }
        var points: [Double] = [0]
        for i in 0..<n where base[i] > 0 { points.append(lo[i] / base[i]); points.append(hi[i] / base[i]) }
        points.sort()
        if sum(points[points.count - 1]) <= target { return values(points[points.count - 1]) }
        var previous = points[0], previousSum = sum(previous)
        if previousSum >= target { return values(previous) }
        for point in points.dropFirst() where point > previous {
            let pointSum = sum(point)
            if pointSum >= target {
                let lambda = previous + (point - previous) * (target - previousSum) / (pointSum - previousSum)
                return values(lambda)
            }
            previous = point
            previousSum = pointSum
        }
        return values(previous)
    }

    private static func rowWidths(items: [Item], row: Row, height: Double, width: Double, gap: Double)
        -> (values: [Double], justified: Bool)
    {
        let slice = Array(items[row.start..<row.end])
        let fixedWidth = slice.reduce(0.0) { $0 + Double($1.fixed?.width ?? 0) + $1.extraWidth }
        let available = width - Double(slice.count - 1) * gap - fixedWidth
        let flex = slice.filter { $0.fixed == nil }
        guard !flex.isEmpty, let ratios = rowRatios(flex: flex, height: height, available: available) else {
            return (slice.map { Double($0.fixed?.width ?? 0) + $0.extraWidth }, false)
        }
        var next = ratios.makeIterator()
        let values = slice.map { item in item.fixed.map { Double($0.width) } ?? next.next()! * height + item.extraWidth }
        // A row ending in a fixed tile is left-aligned exactly; the flexible
        // tiles already sum to the width.
        return (values, slice.last?.fixed == nil)
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

    /// Squared log change of every tile's area plus twice its ratio change,
    /// against the tile as it is now: the mean, plus half the worst so no single
    /// tile is sacrificed to the rest; and the geometric mean area change.
    private static func measure(items: [Item], rows: [Row], width: Double, gap: Double) -> (deviation: Double, stretch: Double) {
        var total = 0.0, worst = 0.0, logSum = 0.0, flex = 0.0
        for row in rows {
            let widths = rowWidths(items: items, row: row, height: row.height, width: width, gap: gap).values
            for (offset, index) in (row.start..<row.end).enumerated() where items[index].fixed == nil {
                let item = items[index]
                let w = widths[offset] - item.extraWidth, h = row.height
                let areaDev = log(max(w * h, 1e-9) / item.area)
                let shapeDev = log(max(w / h, 1e-9) / item.ratio)
                let change = areaDev * areaDev + 2 * shapeDev * shapeDev + capPenalty(areaDev)
                total += change
                worst = max(worst, change)
                logSum += areaDev
                flex += 1
            }
        }
        return (total / Double(max(items.count, 1)) + worst / 2, flex > 0 ? exp(logSum / flex) : 1)
    }
}
