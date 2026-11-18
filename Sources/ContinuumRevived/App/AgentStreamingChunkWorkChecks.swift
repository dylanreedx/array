import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--agent-streaming-chunk-work-check`: what a real managed agent tile does per
/// streamed chunk, with 24 agents and 12 helpers streaming at 120 Hz in mind.
///
/// 1. Chrome: every chunk re-resolves the header, the composer's action button
///    and the provider footer. An unchanged value must leave all three clean;
///    re-applying it re-laid and repainted them per chunk (about 5%).
/// 2. Tool rows: presenting a cached tool row must not re-validate its provider
///    item ID, which ran the secret-redaction pass per row on every rebuild
///    (about 4%). Timed against one validation in the same run.
@MainActor
enum AgentStreamingChunkWorkChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func pump(_ seconds: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() async throws -> String {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "chunk-work",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 640),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")), threadId: "chunks")
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tile.layoutSubtreeIfNeeded()
        let chrome = try chromeViews(in: tile)
        let summary = try checkChunksLeaveChromeClean(tile, chrome: chrome)
        return summary + "; " + (try await checkCachedToolRowsSkipValidation(tile))
    }

    /// The tile's own header, action button and provider footer. A tile with
    /// chrome at rest keeps them out of the view tree, so wake it first: the
    /// hovered or focused tile is the one that pays per chunk.
    private static func chromeViews(in tile: ManagedAgentTileNSView) throws -> [(name: String, view: NSView)] {
        tile.wakeChrome()
        tile.layoutSubtreeIfNeeded()
        guard let button = tile.qaPageZoomActionButton else {
            throw Failure(description: "the tile has no composer action button")
        }
        return [("header", tile.qaPageZoomHeaderView), ("action button", button),
                ("provider footer", tile.qaProviderFooterView)]
    }

    private static func dirty(_ view: NSView) -> Bool {
        view.needsLayout || view.needsDisplay || view.subviews.contains(where: dirty)
    }

    private static func markClean(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        func clear(_ view: NSView) {
            view.needsDisplay = false
            view.subviews.forEach(clear)
        }
        clear(view)
    }

    private static func checkChunksLeaveChromeClean(
        _ tile: ManagedAgentTileNSView, chrome: [(name: String, view: NSView)]
    ) throws -> String {
        let thread = "chunks", turn = "t1"
        tile.ingest(.sessionStateChanged(.running))
        tile.ingest(.turnStarted(threadId: thread, turnId: turn))
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "Starting. "))
        pump()
        tile.layoutSubtreeIfNeeded()

        // The header's elapsed seconds may tick once while this runs; that is a
        // real change. Each chunk is checked alone, and at most one may dirty.
        var dirtied: [String: Int] = [:]
        let chunks = 40
        for index in 0..<chunks {
            chrome.forEach { markClean($0.view) }
            tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "chunk \(index) "))
            for (name, view) in chrome where dirty(view) { dirtied[name, default: 0] += 1 }
        }
        let offenders = dirtied.filter { $0.value > 1 }
        try expect(offenders.isEmpty,
                   "\(chunks) streamed chunks re-laid or repainted unchanged chrome: "
                   + offenders.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // A real change still reaches the chrome.
        chrome.forEach { markClean($0.view) }
        tile.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        let changed = chrome.filter { dirty($0.view) }.map(\.name)
        try expect(changed.contains("header") && changed.contains("action button"),
                   "a completed turn must still update the header and the action button; dirtied \(changed)")
        return "\(chunks) chunks dirtied chrome \(dirtied.values.reduce(0, +)) time(s), turn end updated \(changed.joined(separator: ", "))"
    }

    private static func checkCachedToolRowsSkipValidation(_ tile: ManagedAgentTileNSView) async throws -> String {
        guard let surface = tile.qaTranscriptSurface as? AgentTranscriptCanvasView else {
            throw Failure(description: "the tile did not install the canvas transcript")
        }
        surface.bindToolDetailAgent(AgentID(rawValue: UUID()))
        let thread = "chunks", turn = "t2"
        let started = AgentRuntimeEvent.turnStarted(threadId: thread, turnId: turn)
        tile.ingest(started)
        surface.captureRuntimeEvent(started)
        let rows = 60
        var identities: [String: AgentToolDetailKey] = [:]
        for index in 0..<rows {
            let item = "call_\(index)_9fX2kQ7mZ"
            let begin = AgentRuntimeEvent.itemStarted(threadId: thread, itemId: item, kind: .commandExecution, title: "swift build")
            tile.ingest(begin)
            identities[item] = surface.captureRuntimeEvent(begin)
            surface.captureRuntimeObservation(.toolDetail(itemId: item, detail: AgentToolDetailObservation(
                phase: .ended, toolName: "Bash", fields: [(key: "command", value: "swift build --product Array")],
                outputPreview: "Build complete \(index)", exitCode: 0, observedAt: Date())))
            let end = AgentRuntimeEvent.itemCompleted(threadId: thread, itemId: item, kind: .commandExecution, status: .completed)
            tile.ingest(end)
            surface.captureRuntimeEvent(end)
        }
        let finished = AgentRuntimeEvent.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil)
        tile.ingest(finished)
        surface.captureRuntimeEvent(finished)

        let toolRows: [(AgentBlock, AgentEntry, String)] = tile.qaDocumentForChecks.entries.flatMap { entry in
            guard case let .providerItem(_, itemID?) = entry.provenance else { return [(AgentBlock, AgentEntry, String)]() }
            return entry.blocks.filter { $0.kind == .toolCall }.map { ($0, entry, itemID) }
        }
        try expect(toolRows.count == rows, "expected \(rows) tool rows, found \(toolRows.count)")
        for (_, entry, itemID) in toolRows {
            guard let identity = identities[itemID], surface.bindToolDetailIdentity(identity, to: entry.id) else {
                throw Failure(description: "tool row \(itemID) has no capture identity to bind")
            }
        }
        // Present each once so the cache holds it, as a first rebuild does.
        let deadline = Date().addingTimeInterval(10)
        var cached = 0
        repeat {
            // The capture writes through the main actor: yield to it, do not spin the run loop.
            try await Task.sleep(for: .milliseconds(50))
            toolRows.forEach { _ = surface.toolDetail.presented($0.0, in: $0.1) }
            let presentation = surface.toolDetail.presentation
            cached = toolRows.filter {
                if case .cached = presentation.present($0.0, in: $0.1) { return true }
                return false
            }.count
        } while cached < rows && Date() < deadline
        try expect(cached == rows, "only \(cached) of \(rows) tool rows reached the presentation cache")

        let presentation = surface.toolDetail.presentation
        let presentCost = bestNanos(20) {
            for row in toolRows { _ = presentation.present(row.0, in: row.1) }
        } / Double(rows)
        let validationCost = bestNanos(20) {
            for row in toolRows { _ = AgentToolDetailID.isValid(row.2) }
        } / Double(rows)
        try expect(presentCost < validationCost * 0.5,
                   "presenting a cached tool row must cost under half of validating its item ID once: "
                   + "present \(Int(presentCost)) ns, validate \(Int(validationCost)) ns per row")
        return "cached tool row \(Int(presentCost)) ns vs ID validation \(Int(validationCost)) ns"
    }

    /// Best of seven batches, nanoseconds per batch.
    private static func bestNanos(_ batches: Int, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<batches { body() }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / Double(batches))
        }
        return best
    }
}
