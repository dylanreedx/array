import AppKit
import ContinuumRevivedAgentContent

/// A single-column, flipped-coordinate collection layout. It computes lightweight
/// attributes for the semantic rows, while NSCollectionView creates views only for
/// rows intersecting the viewport.
@MainActor
final class AgentTranscriptLayout: NSCollectionViewLayout {
    var itemCount: () -> Int = { 0 }
    var measuredHeight: (Int, CGFloat) -> CGFloat = { _, _ in 0 }
    var rowSpacing: CGFloat = 12
    var contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize = NSSize.zero
    private var preparedWidthBucket: Int?
    private(set) var preparePassCount = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        let width = max(0, collectionView.bounds.width - contentInsets.left - contentInsets.right)
        let widthBucket = Int(width.rounded())
        let count = itemCount()
        if preparedWidthBucket == widthBucket, attributes.count == count, !attributes.isEmpty || count == 0 {
            return
        }
        // Counted below the fast path: a REAL recomputation is what the tick and
        // streaming contracts bound — the list's offscreen layout drive (P5.5)
        // calls prepare on every pass and early-returns here when nothing moved.
        preparePassCount += 1

        preparedWidthBucket = widthBucket
        attributes.removeAll(keepingCapacity: true)
        attributes.reserveCapacity(count)
        var y = contentInsets.top
        for index in 0..<count {
            let path = IndexPath(item: index, section: 0)
            let itemAttributes = NSCollectionViewLayoutAttributes(forItemWith: path)
            let height = max(1, measuredHeight(index, width))
            itemAttributes.frame = NSRect(x: contentInsets.left, y: y, width: width, height: height)
            attributes.append(itemAttributes)
            y += height
            if index + 1 < count { y += rowSpacing }
        }
        y += contentInsets.bottom
        contentSize = NSSize(width: collectionView.bounds.width, height: y)
    }

    override var collectionViewContentSize: NSSize { contentSize }

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
        invalidateLayout()
    }

    func invalidateForStructureChange() {
        preparedWidthBucket = nil
        invalidateLayout()
    }
}
