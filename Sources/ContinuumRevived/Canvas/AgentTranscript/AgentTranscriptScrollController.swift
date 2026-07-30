import AppKit
import ContinuumRevivedAgentContent

/// Owns stick-to-bottom and reader-anchor policy; it never decides what content
/// is rendered. Anchors use semantic IDs, not collection indexes.
@MainActor
final class AgentTranscriptScrollController {
    struct Anchor: Equatable {
        let id: AgentNodeID
        let offset: CGFloat
    }

    let nearBottomThreshold: CGFloat
    private(set) var showsJumpToLatest = false

    init(nearBottomThreshold: CGFloat = 48) {
        self.nearBottomThreshold = nearBottomThreshold
    }

    func isNearBottom(in scrollView: NSScrollView) -> Bool {
        let clip = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximum = max(0, documentHeight - clip.height)
        return maximum - clip.origin.y <= nearBottomThreshold
    }

    func captureTopAnchor(
        in scrollView: NSScrollView,
        idAtY: (CGFloat) -> AgentNodeID?,
        yForID: (AgentNodeID) -> CGFloat?
    ) -> Anchor? {
        let y = scrollView.contentView.bounds.minY
        guard let id = idAtY(y), let itemY = yForID(id) else { return nil }
        return Anchor(id: id, offset: y - itemY)
    }

    func apply(
        in scrollView: NSScrollView,
        idAtY: @escaping (CGFloat) -> AgentNodeID?,
        yForID: @escaping (AgentNodeID) -> CGFloat?,
        isSelecting: () -> Bool = { false },
        update: () throws -> Void
    ) rethrows {
        // Selection is an explicit reader intent. Do not stick OR restore an
        // anchor while text is selected: either operation can move the viewport
        // under the pointer. The reader can use Jump to latest afterward.
        if isSelecting() {
            try update()
            showsJumpToLatest = true
            return
        }
        let stick = isNearBottom(in: scrollView)
        let anchor = stick ? nil : captureTopAnchor(in: scrollView, idAtY: idAtY, yForID: yForID)
        try update()
        if stick {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            showsJumpToLatest = false
        } else if let anchor, let newY = yForID(anchor.id) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, newY + anchor.offset)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            showsJumpToLatest = true
        } else {
            showsJumpToLatest = true
        }
    }

    func jumpToLatest(in scrollView: NSScrollView) {
        let height = scrollView.documentView?.frame.height ?? 0
        let viewport = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - viewport)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        showsJumpToLatest = false
    }
}
