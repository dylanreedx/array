import AppKit
import ContinuumRevivedAgentUI

// WS5: how a page zoom reaches the views inside one managed-agent tile.
//
// There are exactly TWO delivery paths, and which one a view uses is decided by
// whether it is a transcript RENDERER's view:
//
//   1. Renderer views learn the rung from `AgentRenderContext.pageZoom` in
//      `update(view:block:context:)` and `measure(block:width:context:)`. That
//      is the only correct path for them, because a renderer view is recycled:
//      a view built at 100% and reused for a row at 150% must re-derive its
//      metrics from the context it is handed, not from whatever it was born
//      with. `AgentTranscriptListView.updateRenderContext` re-applies every
//      visible host, and offscreen rows adopt the current rung when reuse
//      materializes them.
//
//   2. Every other view inside the tile's content — header, status row,
//      composer, rails, footer, buttons — conforms to `AgentPageZoomScalable`
//      and is notified by a walk of the content subtree. These views are not
//      recycled and have no render context.
//
// Nothing here mutates a shared token. `Space`, `Inset`, `Typography` keep their
// shipped values; a scaled value is derived per tile at the use site.

/// A view inside a managed-agent tile's content whose metrics follow the tile's
/// page zoom.
///
/// `applyPageZoom` must be idempotent and must assign EVERY zoom-derived metric
/// the view owns from scratch — the same contract `TokenThemed.applyTokens` has,
/// for the same reason: it runs on a view that may already be showing content.
@MainActor
protocol AgentPageZoomScalable: NSView {
    func applyPageZoom(_ zoom: AgentPageZoom)
}

enum AgentPageZoomScaling {
    /// Deliver `zoom` to every `AgentPageZoomScalable` in `root`'s subtree,
    /// including `root` itself.
    ///
    /// Returns how many views were notified. That count is the positive control
    /// for every witness that asserts something did NOT change across a zoom: a
    /// zero here means the walk found nothing and the "unchanged" assertions
    /// were vacuous.
    @discardableResult
    @MainActor
    static func apply(_ zoom: AgentPageZoom, in root: NSView) -> Int {
        var notified = 0
        func visit(_ view: NSView) {
            if let scalable = view as? AgentPageZoomScalable {
                scalable.applyPageZoom(zoom)
                notified += 1
            }
            for subview in view.subviews { visit(subview) }
        }
        visit(root)
        return notified
    }
}
