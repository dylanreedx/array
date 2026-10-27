import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Exactly what `ManagedAgentTileNSView` asks of its transcript, so the tile can
/// hold either renderer: `AgentTranscriptListView` (one AppKit view per row, the
/// shipped default) or `AgentTranscriptCanvasView` (one view, drawn with
/// CoreText). Nothing here is renderer-specific; QA seams that are stay on the
/// concrete types.
@MainActor
protocol AgentTranscriptSurface: NSView {
    func enqueue(document: AgentDocument, patch: AgentDocumentPatch, final: Bool) throws
    func jumpToLatest()
    func flushPendingVisualUpdate()
    func updateRenderContext(_ context: AgentRenderContext) throws

    func bindToolDetailAgent(_ agentID: AgentID?)
    func captureRuntimeObservation(_ observation: AgentRuntimeObservation)
    @discardableResult
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) -> AgentToolDetailKey?
    func bindToolDetailIdentity(_ identity: AgentToolDetailKey, to entryID: AgentNodeID) -> Bool

    func setThinkingIndicatorVisible(_ visible: Bool)
    func setTurnInFlight(_ inFlight: Bool)
    func setThinkingStatusText(_ text: String?)
    func setTurnPresence(_ presence: AgentTurnPresence?)
    func setSettledTailStatus(_ text: String)

    /// The transcript's scroll origin (y grows down the document). A tile bake
    /// compares it to decide whether its picture is stale.
    var transcriptScrollOrigin: CGPoint { get }
    func scrollTranscript(toY y: CGFloat)

    var qaTailStatusText: String { get }
}

extension AgentTranscriptListView: AgentTranscriptSurface {
    var transcriptScrollOrigin: CGPoint { scrollView.contentView.bounds.origin }

    func scrollTranscript(toY y: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
