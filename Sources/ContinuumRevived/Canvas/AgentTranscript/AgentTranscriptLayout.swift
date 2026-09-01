import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// A single-column, flipped-coordinate collection layout. It computes lightweight
/// attributes for the semantic rows, while NSCollectionView creates views only for
/// rows intersecting the viewport.
@MainActor
final class AgentTranscriptLayout: NSCollectionViewLayout {
    var itemCount: () -> Int = { 0 }
    var measuredHeight: (Int, CGFloat) -> CGFloat = { _, _ in 0 }
    /// Separation between two rows of the SAME entry.
    ///
    /// 8, not 12 (2026-08-24): `AssistantProseView` already uses 8pt between
    /// its own sub-rows, so 12 here made every row-to-row gap wider than the
    /// paragraph gaps inside a reply — "spread out too much". The turn boundary
    /// carries the separation instead, at 4x this.
    var rowSpacing: CGFloat = 8
    /// WS5 page zoom. Every geometry term below is derived from it, and it is
    /// part of the prepared identity: without that the fast path early-returns
    /// on a zoom change and the transcript keeps the previous rung's frames.
    var pageZoom: AgentPageZoom = .default {
        didSet {
            guard pageZoom != oldValue else { return }
            invalidateForStructureChange()
        }
    }
    /// The row gap actually left, at the current rung.
    var scaledRowSpacing: CGFloat { CGFloat(pageZoom.scaled(Double(rowSpacing))) }
    /// `interTurnSpacing` at the current rung.
    var scaledInterTurnSpacing: CGFloat {
        CGFloat(pageZoom.scaled(Double(Self.interTurnSpacing)))
    }
    /// `contentInsets` at the current rung.
    var scaledContentInsets: NSEdgeInsets {
        NSEdgeInsets(
            top: CGFloat(pageZoom.scaled(Double(contentInsets.top))),
            left: CGFloat(pageZoom.scaled(Double(contentInsets.left))),
            bottom: CGFloat(pageZoom.scaled(Double(contentInsets.bottom))),
            right: CGFloat(pageZoom.scaled(Double(contentInsets.right)))
        )
    }
    /// Separation between two rows belonging to different turns.
    ///
    /// `_DESIGN.md` §11 asks for a soft hairline for section separation; the rule
    /// is drawn by the list into this gap, so the air and the rule stay one
    /// decision rather than drifting apart.
    /// Corrected 2026-08-24 (`.plans/45` S4.0): 20 vs a 12pt row gap was the
    /// "slightly bigger paragraph gap" the turn witness's own failure message
    /// forbids — part of what Dylan rejected. `Space.xl * 2`; the final value
    /// is judged in the S7 gallery, not by this number.
    static let interTurnSpacing: CGFloat = 24
    /// Returns the gap to leave ABOVE `index`, or nil for the default `rowSpacing`.
    var spacingBefore: ((Int) -> CGFloat?)?
    /// Cheap digest of where the turn boundaries currently are.
    var boundarySignature: (() -> Int)?
    var contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize = NSSize.zero
    private var preparedWidthBucket: Int?
    private var preparedBoundarySignature: Int?
    private var preparedZoomPercent: Int?
    private(set) var preparePassCount = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        let insets = scaledContentInsets
        let width = max(0, collectionView.bounds.width - insets.left - insets.right)
        let widthBucket = Int(width.rounded())
        let count = itemCount()
        // The signature is part of the guard, not decoration. Spacing now depends
        // on a row's NEIGHBOUR, so a change that leaves the row count and the
        // width alone -- one entry's rows becoming two entries' rows -- would
        // otherwise early-return with the previous turn boundaries baked in.
        let signature = boundarySignature?() ?? 0
        // WS5: the zoom rung is part of the identity. A zoom change moves every
        // row's height and every gap between them while leaving the width
        // bucket, the boundary signature and the row count alone — exactly the
        // shape this fast path was built to skip.
        if preparedWidthBucket == widthBucket, preparedBoundarySignature == signature,
           preparedZoomPercent == pageZoom.percent,
           attributes.count == count, !attributes.isEmpty || count == 0 {
            return
        }
        // Counted below the fast path: a REAL recomputation is what the tick and
        // streaming contracts bound — the list's offscreen layout drive (P5.5)
        // calls prepare on every pass and early-returns here when nothing moved.
        preparePassCount += 1

        preparedWidthBucket = widthBucket
        preparedBoundarySignature = signature
        preparedZoomPercent = pageZoom.percent
        attributes.removeAll(keepingCapacity: true)
        attributes.reserveCapacity(count)
        var y = insets.top
        for index in 0..<count {
            let path = IndexPath(item: index, section: 0)
            let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: path)
            let height = max(1, measuredHeight(index, width))
            itemAttributes.frame = NSRect(x: insets.left, y: y, width: width, height: height)
            attributes.append(itemAttributes)
            y += height
            if index + 1 < count { y += spacingBefore?(index + 1) ?? scaledRowSpacing }
        }
        y += insets.bottom
        contentSize = NSSize(width: collectionView.bounds.width, height: y)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    /// `.plans/45` T3. The vertical gaps actually left between consecutive rows,
    /// read back from the prepared attributes.
    ///
    /// Deliberately derived from the frames rather than reported from the spacing
    /// rule: a witness that asked the rule what it would return would agree with
    /// a rule that is never consulted, which is precisely how a flat 12 survived
    /// being called three tiers of separation.
    /// The measured gap above one row, from the SAME prepared attributes the
    /// screen uses (not from the spacing closure, which could disagree).
    func qaGapAboveForChecks(_ index: Int) -> CGFloat? {
        guard index > 0, attributes.indices.contains(index) else { return nil }
        return attributes[index].frame.minY - attributes[index - 1].frame.maxY
    }

    var qaRowGapsForChecks: [CGFloat] {
        guard attributes.count > 1 else { return [] }
        return (1..<attributes.count).map { index in
            attributes[index].frame.minY - attributes[index - 1].frame.maxY
        }
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return true }
        return Int(newBounds.width.rounded()) != Int(collectionView.bounds.width.rounded())
    }

    /// A semantic change can alter one row's height and every following row's y
    /// coordinate. Invalidating layout does not invalidate renderer measurements:
    /// the shared cache remains keyed by ID/revision/width bucket.
    func invalidate(changedIDs: Set<AgentNodeID>) {
        guard !changedIDs.isEmpty else { return }
        preparedWidthBucket = nil
        preparedZoomPercent = nil
        invalidateLayout()
    }

    func invalidateForStructureChange() {
        preparedWidthBucket = nil
        preparedZoomPercent = nil
        invalidateLayout()
    }
}
