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
        let flat = Flat(items)
        defer { flat.free() }
        guard var chosen = solve(flat, width: width, height: height, gap: gap) else {
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
                var bestStep: Double?
                func attempt(_ step: Double) {
                    let k = pow(kMin, step / 10)
                    let w = max(minimumWidth, (originalWidth * k).rounded(.down))
                    let h = max(1, (originalHeight * k).rounded(.down))
                    // A layout's own cost is never negative, so the shrink charge
                    // alone bounds this attempt: skip any that cannot win.
                    let charge = shrinkWeight * (pow(log(w / originalWidth), 2) + pow(log(h / originalHeight), 2))
                    guard charge < bestCost - 1e-12 else { return }
                    guard let layout = solve(flat, width: w, height: h, gap: gap) else { return }
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
                let guess: Double = chosen.stretch > areaCeiling
                    ? 10 * log(sqrt(areaCeiling / chosen.stretch)) / log(kMin) : 1
                for step in nearestFirst((1...10).map { Double($0) }, to: guess) { attempt(step) }
                if let coarse = bestStep {
                    let fine: [Double] = [1, 2, 3, 5, 6, 7, 8].map { coarse - 1 + Double($0) / 4 }
                    for step in nearestFirst(fine, to: coarse) { attempt(step) }
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
        return items
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
        return Item(
            id: lead.id, area: area,
            ratio: leadRatio * factor, ratioMin: leadLo * factor, ratioMax: leadHi * factor,
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
    private static func solve(_ f: Flat, width: Double, height: Double, gap: Double) -> Layout? {
        let n = f.count
        // Every candidate row, once: table[start * maxRowLength + length - 1].
        var table = [Row?](repeating: nil, count: n * maxRowLength)
        var start = 0
        while start < n {
            var length = 1
            while length <= maxRowLength && start + length <= n {
                table[start * maxRowLength + length - 1] = evaluateRow(f, start: start, end: start + length, width: width, gap: gap)
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
                end += 1
            }
            guard cost[n].isFinite else { continue }
            var rows: [Row] = []
            end = n
            while end > 0, choice[end] >= 0, let row = table[choice[end]] { rows.append(row); end = row.start }
            rows.reverse()
            var layout: Layout
            if let known = evaluated[rows.map(\.start)] {
                layout = known
            } else {
                let fitted = fitHeightsUnderCap(f, rows: rows, target: height - Double(rows.count - 1) * gap,
                                                width: width, gap: gap)
                let total = fitted.reduce(0) { $0 + $1.height } + Double(rows.count - 1) * gap
                let exact = abs(total - height) < 0.5
                let measured = measure(f, rows: fitted, width: width, gap: gap)
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

    /// One candidate row. The common case, where no tile's ratio clamps, does
    /// the same arithmetic as `rowRatios` + `waterFill`, in the same order,
    /// without allocating; a row where a clamp binds goes through them.
    private static func evaluateRow(_ f: Flat, start: Int, end: Int, width: Double, gap: Double) -> Row? {
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
        return base.withUnsafeBufferPointer { b in lo.withUnsafeBufferPointer { l in hi.withUnsafeBufferPointer { h in
            func sum(_ lambda: Double) -> Double {
                var total = 0.0, i = 0
                while i < n { total += min(max(b[i] * lambda, l[i]), h[i]); i += 1 }
                return total
            }
            func values(_ lambda: Double) -> [Double] {
                [Double](unsafeUninitializedCapacity: n) { out, initialized in
                    var i = 0
                    while i < n { out[i] = min(max(b[i] * lambda, l[i]), h[i]); i += 1 }
                    initialized = n
                }
            }
            var baseSum = 0.0, i = 0
            while i < n { baseSum += b[i]; i += 1 }
            if baseSum > 0 {
                let plain = target / baseSum
                if abs(sum(plain) - target) <= 1e-9 * max(target, 1) { return values(plain) }
            }
            return withUnsafeTemporaryAllocation(of: Double.self, capacity: 2 * n + 1) { storage in
                var count = 1
                storage[0] = 0
                var i = 0
                while i < n {
                    if b[i] > 0 { storage[count] = l[i] / b[i]; storage[count + 1] = h[i] / b[i]; count += 2 }
                    i += 1
                }
                var points = UnsafeMutableBufferPointer(rebasing: storage[0..<count])
                points.sort()
                if sum(points[count - 1]) <= target { return values(points[count - 1]) }
                var previous = points[0], previousSum = sum(previous)
                if previousSum >= target { return values(previous) }
                var k = 1
                while k < count {
                    let point = points[k]
                    k += 1
                    guard point > previous else { continue }
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
        } } }
    }

    private static func rowWidths(_ f: Flat, row: Row, height: Double, width: Double, gap: Double)
        -> (values: [Double], justified: Bool)
    {
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
    private static func measure(_ f: Flat, rows: [Row], width: Double, gap: Double) -> (deviation: Double, stretch: Double) {
        var total = 0.0, worst = 0.0, logSum = 0.0, flex = 0.0
        for row in rows {
            let widths = rowWidths(f, row: row, height: row.height, width: width, gap: gap).values
            for (offset, index) in (row.start..<row.end).enumerated() where !f.isFixed[index] {
                let w = widths[offset] - f.extra[index], h = row.height
                let areaDev = log(max(w * h, 1e-9) / f.area[index])
                let shapeDev = log(max(w / h, 1e-9) / f.ratio[index])
                let change = areaDev * areaDev + 2 * shapeDev * shapeDev + capPenalty(areaDev)
                total += change
                worst = max(worst, change)
                logSum += areaDev
                flex += 1
            }
        }
        return (total / Double(max(f.count, 1)) + worst / 2, flex > 0 ? exp(logSum / flex) : 1)
    }
}
