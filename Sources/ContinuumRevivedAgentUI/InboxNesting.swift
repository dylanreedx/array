import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
// Follow-up: .plans/0721-subagents-handoff.md — "a subagent under a subagent reads
// as a subagent of the wrong parent".
//
// The inbox is a FLAT table on purpose (see the header of `AgentInboxView`):
// `InboxSort` already places a child immediately under its parent and stamps the
// depth, so the array carries the order and the indent an `NSOutlineView` would
// compute. What the array did NOT carry was the one thing an outline view draws for
// free — where a group STARTS and where it ENDS. A 16 pt inset alone cannot say
// that: two sibling groups drawn back to back are one unbroken column of cards, and
// the first root after a nested child reads as another child of whatever was above
// it.
//
// This file is the missing half, and it is deliberately PURE arithmetic in the leaf
// module: the list decides what the tree is, the cell decides what colour to paint,
// and the shape of the connector between them is a value a check can drive without
// a window.

/// Where one visible row sits in the tree, in the only two numbers a flat,
/// pre-ordered list needs.
///
/// WHY `nextDepth` IS SUFFICIENT: `InboxSort` emits a pre-order walk, so every
/// descendant of a row is CONTIGUOUS with it. The moment the depth of the following
/// row drops to `k` or below, every group at level `k` or deeper has ended — there
/// can be no later row belonging to them. So "does the group at level `k` continue
/// past this row" is exactly `k < nextDepth`, and one lookahead replaces a
/// per-level scan of the rest of the list.
public struct InboxNesting: Equatable, Sendable {
    /// This row's own indent level. 0 is a root.
    public let depth: Int
    /// The depth of the row drawn immediately BELOW this one — 0 when this is the
    /// last row, and 0 for a section heading, which ends every open group because
    /// nothing below it belongs to anything above it.
    public let nextDepth: Int

    public init(depth: Int, nextDepth: Int) {
        self.depth = max(0, depth)
        self.nextDepth = max(0, nextDepth)
    }

    /// A row with nothing above or below it in the tree: draws no connector at all.
    public static let none = InboxNesting(depth: 0, nextDepth: 0)

    /// This row has its children on screen right now, so its own lane carries a
    /// descender down to the first of them.
    public var isExpandedParent: Bool { nextDepth > depth }

    /// At least one group ends AT this row — it is the last member of it. This is
    /// what earns the extra breathing room below the row, so the next root cannot be
    /// mistaken for one more sibling.
    public var endsGroup: Bool { depth > nextDepth }

    /// Does the group whose members sit at `level + 1` have another member below
    /// this row?
    public func continues(level: Int) -> Bool { level < nextDepth }
}

/// The horizontal rhythm the connector shares with the cards.
///
/// Every number here is READ from the list's own layout rather than chosen for the
/// spine: the lane a connector lives in IS the indent step the card to its right was
/// pushed by, so a change to `indentPerLevel` moves both or neither. That is the
/// whole reason this is a struct and not four literals in a `draw`.
public struct InboxSpineMetrics: Equatable, Sendable {
    /// The list's outer gutter — where a root card's leading edge sits.
    public let gutter: Double
    /// One nesting step. Also the width of one connector lane.
    public let indentPerLevel: Double
    /// The hairline's stroke width.
    public let lineWidth: Double
    /// Extra room under the last row of a group. The strongest grouping cue a list
    /// has is space, and it costs no colour and no new vocabulary.
    public let endGap: Double

    public init(gutter: Double, indentPerLevel: Double, lineWidth: Double, endGap: Double) {
        self.gutter = gutter
        self.indentPerLevel = indentPerLevel
        self.lineWidth = lineWidth
        self.endGap = endGap
    }

    /// The leading edge of the card of a row at this depth.
    public func cardLeading(depth: Int) -> Double {
        gutter + Double(max(0, depth)) * indentPerLevel
    }

    /// The centre of the connector lane owned by a row at `level` — which is the
    /// centre of that row's own disclosure triangle, so the descender leaves the
    /// triangle it belongs to rather than running beside it.
    public func spineX(level: Int) -> Double {
        cardLeading(depth: level) + indentPerLevel / 2
    }

    /// How much taller than a card a row is, given where it sits in the tree.
    public func trailingGap(_ nesting: InboxNesting) -> Double {
        nesting.endsGroup ? endGap : 0
    }
}

/// One piece of the connector, in the ROW's own coordinates, y growing downward.
public struct InboxSpineSegment: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A lane running down the list.
        case vertical
        /// The stub that turns out of a lane into the card of the row it belongs to.
        case elbow
    }

    public let kind: Kind
    /// Which lane this segment is in. A vertical at `level` is the descender of a
    /// parent drawn at depth `level`; an elbow at `level` hands off to a child at
    /// depth `level + 1`.
    public let level: Int
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(kind: Kind, level: Int, minX: Double, minY: Double,
                width: Double, height: Double) {
        self.kind = kind
        self.level = level
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midY: Double { minY + height / 2 }
}

public enum InboxSpine {
    /// What one row draws of the tree it belongs to.
    ///
    /// - `cardTop`/`cardHeight` are the CARD's, not the row's: the elbow meets the
    ///   card's vertical centre, and a row that ends a group is taller than its card.
    /// - `rowHeight` is the whole row, so a lane that continues runs edge to edge and
    ///   the segments of consecutive rows meet with no seam.
    public static func segments(
        _ nesting: InboxNesting, metrics: InboxSpineMetrics,
        cardTop: Double, cardHeight: Double, rowHeight: Double
    ) -> [InboxSpineSegment] {
        guard rowHeight > 0, cardHeight > 0 else { return [] }
        let width = metrics.lineWidth
        let mid = cardTop + cardHeight / 2

        func vertical(level: Int, from top: Double, to bottom: Double) -> InboxSpineSegment? {
            guard bottom > top else { return nil }
            return InboxSpineSegment(
                kind: .vertical, level: level,
                minX: metrics.spineX(level: level) - width / 2, minY: top,
                width: width, height: bottom - top)
        }

        var segments: [InboxSpineSegment] = []
        let depth = nesting.depth
        for level in 0..<max(0, depth) {
            // The row's OWN parent lane: it always turns in here, so this is the
            // level that carries the elbow. Above it, an ancestor lane is drawn only
            // while its group is still open — which is what makes the last member of
            // a group the row where the lanes visibly stop.
            let isParentLane = level == depth - 1
            if isParentLane {
                let bottom = nesting.continues(level: level) ? rowHeight : mid
                if let run = vertical(level: level, from: 0, to: bottom) {
                    segments.append(run)
                }
                let start = metrics.spineX(level: level)
                let end = metrics.cardLeading(depth: depth)
                if end > start {
                    segments.append(InboxSpineSegment(
                        kind: .elbow, level: level,
                        minX: start, minY: mid - width / 2,
                        width: end - start, height: width))
                }
            } else if nesting.continues(level: level) {
                if let run = vertical(level: level, from: 0, to: rowHeight) {
                    segments.append(run)
                }
            }
        }
        // The descender starts BELOW the triangle rather than at it, so the triangle
        // reads as the head of the group instead of a bead threaded on a wire.
        if nesting.isExpandedParent,
           let run = vertical(level: depth, from: mid + metrics.indentPerLevel / 2,
                              to: rowHeight) {
            segments.append(run)
        }
        return segments
    }
}
