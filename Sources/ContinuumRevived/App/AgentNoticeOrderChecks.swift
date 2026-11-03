import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--agent-notice-order-check`: an Array-authored notice (a browser
/// screenshot) published while streamed events are still queued for a tile
/// must land in the tile where it lands in the agent's saved transcript.
///
/// The tile takes runtime events from the supervisor's async tail, one main-actor
/// hop each, but used to take notices synchronously. A screenshot published
/// right after a burst of events therefore jumped ahead of the events the tile
/// had not read yet: mid-transcript on screen, last in the document that the
/// guest, a reload and the persisted file all read.
///
/// Drives the production path: a real supervisor and tile, events through
/// `deliver`, the screenshot through `publishBrowserScreenshot`, with events
/// before AND after it in one main-actor step so the tail is non-empty both
/// ways. Asserts the tile's entry order equals the supervisor's document order.
@MainActor
func runAgentNoticeOrderChecks() async throws -> String {
    struct Failure: Error, CustomStringConvertible { let description: String }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-notice-order-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let project = UUID(), agent = AgentID(rawValue: UUID())
    try store.upsert(AgentRecord(id: agent, displayName: "Notice order", harness: .claudeCode,
                                 model: "fixture/notice-order", thinking: "medium", cwd: root.path, projectId: project,
                                 createdAt: Date(), lastActivityAt: Date()))
    // One attachment store for the supervisor and the tile, as the app has.
    let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: root)
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                     warn: { _ in }, nameTitlerCommand: { _ in nil },
                                     attachmentStore: attachments,
                                     transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
    _ = supervisor.restore()
    defer { supervisor.stopAll() }

    let tile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Notice order",
        frame: .init(x: 0, y: 0, width: 520, height: 640), zPosition: .first, runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed-agent")))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
    tile.bindV2ComposerState(draftStore: AgentComposerDraftStore(applicationSupportDirectory: root, attachmentStore: attachments),
                             promptHistory: AgentPromptHistory(), attachmentStore: attachments)
    tile.attach(agentID: agent, supervisor: supervisor)

    // Stored before the race: staging and committing are async.
    let staged = try await supervisor.stageBrowserScreenshot(SharedTileParityChecks.screenshotPNG(), for: agent)
    await supervisor.commitBrowserScreenshot(staged.manifest.metadata.id, for: agent)

    // One main-actor step: events, the screenshot, more events. Nothing here
    // yields, so the tile has read none of them when the screenshot is published.
    let thread = AgentSupervisor.threadId(for: agent)
    func deliver(_ event: AgentRuntimeEvent) { supervisor.qaDeliver(event, to: agent) }
    deliver(.turnStarted(threadId: thread, turnId: "t1"))
    deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "Opening the checkout page."))
    deliver(.itemStarted(threadId: thread, itemId: "bash-1", kind: .commandExecution, title: "Bash: open checkout"))
    deliver(.itemCompleted(threadId: thread, itemId: "bash-1", kind: .commandExecution, status: .completed))
    try supervisor.publishBrowserScreenshot(staged.manifest.metadata, for: agent)
    deliver(.itemStarted(threadId: thread, itemId: "read-1", kind: .commandExecution, title: "Read: Sources/Checkout/CheckoutState.swift"))
    deliver(.itemCompleted(threadId: thread, itemId: "read-1", kind: .commandExecution, status: .completed))
    deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "The page renders the wallet button."))

    func order(_ document: AgentDocument?) -> [String] {
        (document?.entries ?? []).map { entry in
            "\(entry.role)/" + entry.blocks.map(\.kind.rawValue).joined(separator: "+")
        }
    }
    let saved = { order(supervisor.transcriptDocument(for: agent)) }
    let shown = { order(tile.qaDocumentForChecks) }
    let imageIndex = { (rows: [String]) in rows.firstIndex { $0.contains("image") } }
    // Settle: the tile has read the whole tail when it holds as many entries as
    // the document and the closing sentence has arrived.
    var waited = 0
    while waited < 5000 {
        if shown().count == saved().count, tile.qaDocumentForChecks.entries.last?.role == .assistant,
           imageIndex(shown()) != nil { break }
        try await Task.sleep(for: .milliseconds(20)); waited += 20
    }
    let savedRows = saved(), shownRows = shown()
    guard let savedImage = imageIndex(savedRows), savedImage > 0, savedImage < savedRows.count - 1 else {
        throw Failure(description: "fixture: the saved document must hold the screenshot between events, got \(savedRows)")
    }
    guard shownRows == savedRows else {
        throw Failure(description: "the tile's entry order differs from the saved transcript's:\n  tile:  \(shownRows)\n  saved: \(savedRows)")
    }
    return "tile and saved transcript agree on \(savedRows.count) entries, screenshot at \(savedImage + 1) of \(savedRows.count)"
}
