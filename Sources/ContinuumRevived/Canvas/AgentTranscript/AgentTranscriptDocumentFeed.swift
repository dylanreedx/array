import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// The one step from a semantic document to a transcript surface. The managed
/// agent tile and a teammate's view of a shared agent both go through it, so
/// the guest draws the host's document with the same renderer, the same view
/// versions and the same locality the host tile does.
@MainActor
struct AgentTranscriptDocumentFeed {
    /// What the surface was last given. Its version is the view's own: the
    /// surface requires exactly-once steps, whatever the source's versions do.
    private(set) var rendered = AgentDocument()

    /// The renderer the tile holds: the drawn canvas unless the list is chosen.
    static func makeSurface(toolDetailStore: AgentToolDetailStore) -> any AgentTranscriptSurface {
        AgentTranscriptCanvasView.isSelected
            ? AgentTranscriptCanvasView(toolDetailStore: toolDetailStore)
            : AgentTranscriptListView(toolDetailStore: toolDetailStore)
    }

    /// `touched` is the source's own changed set. A structural change, or none
    /// known, takes the surface's full walk: the expensive answer is always right.
    mutating func present(_ entries: [AgentEntry], touched: Set<AgentNodeID>, structural: Bool, final: Bool,
                          to surface: any AgentTranscriptSurface) throws {
        let next = AgentDocument(version: rendered.version &+ 1, entries: entries)
        let patch: AgentDocumentPatch
        if structural || touched.isEmpty {
            patch = try AgentDocumentPatch.empty(fromVersion: rendered.version)
        } else {
            patch = try AgentDocumentPatch(fromVersion: rendered.version, toVersion: next.version, updated: Array(touched))
        }
        try surface.enqueue(document: next, patch: patch, final: final)
        rendered = next
    }
}
