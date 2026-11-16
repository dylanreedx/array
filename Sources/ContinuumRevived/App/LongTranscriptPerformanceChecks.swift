import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A real canvas transcript, measured with an offline synthetic history or an
/// explicitly supplied private archive. Never prints or writes its contents.
@MainActor
enum LongTranscriptPerformanceChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func nodeID(_ name: String) -> AgentNodeID { AgentNodeID(rawValue: name)! }

    private static func entry(_ index: Int) -> AgentEntry {
        if index.isMultiple(of: 2) {
            let block = AgentBlock(
                id: nodeID("long-perf-block-\(index)"), revision: 1, kind: .toolCall,
                payload: .toolCall(AgentToolCallPayload(name: "Read", status: .completed)))
            return AgentEntry(
                id: nodeID("long-perf-entry-\(index)"), revision: 1, role: .system,
                provenance: .providerItem(provider: "codex", itemID: "long-perf-item-\(index)"),
                lifecycle: .finished, blocks: [block])
        }
        let block = AgentBlock(
            id: nodeID("long-perf-block-\(index)"), revision: 1, kind: .paragraph,
            payload: .paragraph([.text("A long transcript contains many distinct messages with useful text. " +
                                      "This synthetic paragraph wraps across multiple lines.")]))
        return AgentEntry(
            id: nodeID("long-perf-entry-\(index)"), revision: 1, role: .user,
            provenance: .localPrompt(promptID: "long-perf-\(index)"),
            lifecycle: .finished, blocks: [block])
    }

    private static func percentile95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    static func run() throws {
        let rendererKey = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previousRenderer = ProcessInfo.processInfo.environment[rendererKey]
        setenv(rendererKey, "canvas", 1)
        defer {
            if let previousRenderer { setenv(rendererKey, previousRenderer, 1) }
            else { unsetenv(rendererKey) }
        }
        let source = ProcessInfo.processInfo.environment["ARRAY_LONG_TRANSCRIPT_ARCHIVE"]
        var document: AgentDocument
        if let source {
            // Private data stays in memory. In particular, do not include the
            // decoder's error or the path in output: either can contain content.
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: source)),
                  let archive = try? JSONCodec.makeDecoder().decode(AgentTranscriptArchive.self, from: bytes)
            else { throw Failure(description: "could not read the supplied transcript archive") }
            document = archive.document
        } else {
            document = AgentDocument(entries: (0..<576).map(entry))
        }
        try expect(!document.entries.isEmpty, "fixture must contain transcript entries")

        // Seed the archived history, then drive real reducer mutations through
        // the same typed feed the managed tile uses. A fresh projection owns the
        // appended suffix because an archived document has no projection state.
        var feed = AgentTranscriptDocumentFeed()
        let history = document.entries
        let thread = "long-perf-\(UUID().uuidString)"
        var projection = AgentTranscriptProjection(threadId: thread, monotonicNow: { 0 })
        let canvas = AgentTranscriptCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        let host = NSView(frame: canvas.frame)
        host.addSubview(canvas)
        try feed.present(document.entries, touched: [], structural: true, final: false, to: canvas)
        canvas.flushPendingVisualUpdate()
        host.layoutSubtreeIfNeeded()
        try expect(canvas.qaMaximumScrollOffset > 0, "fixture must exceed the viewport")
        let initialCount = canvas.qaPlacedBlockIDs.count
        try expect(initialCount > 0, "fixture must produce visible transcript blocks")

        var appendMs: [Double] = []
        var updateMs: [Double] = []
        var appendTotalMs: [Double] = []
        var updateTotalMs: [Double] = []
        var appendVisits: [Int] = []
        var updateVisits: [Int] = []
        let initialApplies = canvas.qaVisualApplyCount
        var firstPromptID: AgentNodeID?
        var firstPromptBlockID: AgentNodeID?
        for _ in 0..<12 {
            // The IDs cannot collide with this fixture's stable ids in ordinary
            // use; UUIDs make that true even for an arbitrary private archive.
            let suffix = UUID().uuidString
            let entryID = nodeID("long-perf-entry-\(suffix)")
            let totalStart = ProcessInfo.processInfo.systemUptime
            try projection.appendUserPrompt(id: entryID, text: "A newly arrived message.")
            guard let blockID = projection.document.entries.last?.blocks.first?.id else {
                throw Failure(description: "prompt must produce a block")
            }
            if firstPromptID == nil { firstPromptID = entryID; firstPromptBlockID = blockID }
            let entries = history + projection.document.entries
            let touched = projection.drainTouchedNodes()
            let start = ProcessInfo.processInfo.systemUptime
            try feed.present(entries, touched: touched, final: false, to: canvas)
            canvas.flushPendingVisualUpdate()
            host.layoutSubtreeIfNeeded()
            appendMs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            appendTotalMs.append((ProcessInfo.processInfo.systemUptime - totalStart) * 1_000)
            appendVisits.append(canvas.qaLastRebuildVisitedBlockCount)
            try expect(canvas.qaPlacedBlockIDs.contains(blockID), "appended message must appear")
            try expect(canvas.qaLastRelaidBlockIDs.contains(blockID), "appended message must be laid out")

        }
        try expect(canvas.qaFreshLayoutMismatch() == nil, "appended rows must match fresh layout")

        // Start a genuine open assistant stream. Each following content delta
        // revises its existing paragraph, rather than fabricating a patch.
        let turn = "long-perf-turn"
        projection.ingest(.turnStarted(threadId: thread, turnId: turn))
        projection.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                        delta: "A streamed answer"))
        _ = projection.flushPendingStreamingMarkup()
        let streamEntries = history + projection.document.entries
        try feed.present(streamEntries, touched: projection.drainTouchedNodes(), final: false, to: canvas)
        canvas.flushPendingVisualUpdate()
        host.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            let totalStart = ProcessInfo.processInfo.systemUptime
            projection.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                            delta: " with another chunk"))
            _ = projection.flushPendingStreamingMarkup()
            guard let block = projection.document.entries.last?.blocks.first else {
                throw Failure(description: "stream must produce a block")
            }
            let entries = history + projection.document.entries
            let touched = projection.drainTouchedNodes()
            let updateStart = ProcessInfo.processInfo.systemUptime
            try feed.present(entries, touched: touched, final: false, to: canvas)
            canvas.flushPendingVisualUpdate()
            host.layoutSubtreeIfNeeded()
            updateMs.append((ProcessInfo.processInfo.systemUptime - updateStart) * 1_000)
            updateTotalMs.append((ProcessInfo.processInfo.systemUptime - totalStart) * 1_000)
            updateVisits.append(canvas.qaLastRebuildVisitedBlockCount)
            try expect(canvas.qaLastRelaidBlockIDs.contains(block.id), "updated message must be laid out")
            try expect(canvas.qaPresentedBlock(for: block.id)?.payload == block.payload,
                       "updated message must reach the rendered block")
        }
        try expect(canvas.qaVisualApplyCount - initialApplies == 25, "every append and update must reach the view")
        try expect(canvas.qaFreshLayoutMismatch() == nil, "stream updates must match fresh layout")

        // Two messages can arrive inside the scheduler's presentation window.
        // Present both before flushing and compare its result with a fresh walk.
        let appliesBeforeCoalescing = canvas.qaVisualApplyCount
        for _ in 0..<2 {
            projection.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                            delta: " coalesced"))
            _ = projection.flushPendingStreamingMarkup()
            let entries = history + projection.document.entries
            try feed.present(entries, touched: projection.drainTouchedNodes(), final: false, to: canvas)
        }
        canvas.flushPendingVisualUpdate()
        try expect(canvas.qaVisualApplyCount - appliesBeforeCoalescing == 1, "two queued updates must coalesce into one visual apply")
        try expect(canvas.qaFreshLayoutMismatch() == nil, "coalesced updates must match fresh layout")

        // Render real CoreText drawing into an in-memory context at each scroll
        // position. No bitmap is persisted, and this includes actual draw work.
        guard let cg = CGContext(data: nil, width: 420, height: 520, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "could not create the scroll drawing context")
        }
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        let layoutBeforeScroll = canvas.qaBlockLayoutCount
        let drawsBefore = canvas.qaDrawCount
        var scrollMs: [Double] = []
        for step in 0..<40 {
            let start = ProcessInfo.processInfo.systemUptime
            canvas.scrollTranscript(toY: canvas.qaMaximumScrollOffset * CGFloat(step) / 39)
            try expect(abs(canvas.qaScrollOffset - canvas.qaMaximumScrollOffset * CGFloat(step) / 39) < 0.5,
                       "scroll must reach the requested position")
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            scrollMs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        try expect(canvas.qaDrawCount - drawsBefore == 40, "each scroll must draw the view")
        try expect(canvas.qaBlockLayoutCount == layoutBeforeScroll, "scrolling must not re-layout transcript blocks")
        print(String(format: "long transcript (%@; %d entries, %d placed): append p95 %.2f ms, update p95 %.2f ms, scroll+draw p95 %.2f ms; max visited blocks %d append, %d update",
                     source == nil ? "synthetic" : "private archive", history.count + projection.document.entries.count, initialCount,
                     percentile95(appendMs), percentile95(updateMs), percentile95(scrollMs),
                     appendVisits.max() ?? 0, updateVisits.max() ?? 0))
        print(String(format: "projection + history copy + feed p95: append %.2f ms, update %.2f ms",
                     percentile95(appendTotalMs), percentile95(updateTotalMs)))
        // Removing an older row is not an append. The conservative path must
        // rebuild it, and actually remove the formerly visible block.
        guard let removedEntry = firstPromptID, let removedBlock = firstPromptBlockID else {
            throw Failure(description: "missing prompt removal fixture")
        }
        try projection.withdrawLocalPrompt(id: removedEntry)
        let afterRemoval = history + projection.document.entries
        try feed.present(afterRemoval, touched: projection.drainTouchedNodes(), final: false, to: canvas)
        canvas.flushPendingVisualUpdate()
        try expect(!canvas.qaPlacedBlockIDs.contains(removedBlock), "removed message must disappear")
        try expect(canvas.qaLastRebuildVisitedBlockCount > 8, "removing an older message must take the conservative walk")
        try measureTileIngress(document: document)
        try measureTextViewLifecycle(document: document)
        try TranscriptSourceInvalidationChecks.run()
        try expect((appendVisits.max() ?? 0) <= 8, "appending a message must not walk transcript history")
        try expect((updateVisits.max() ?? 0) <= 8, "updating the tail must not walk transcript history")
    }

    /// Count actual TextKit views, not semantic blocks or retained subviews.
    /// The probe includes AppKit's standard initializers and a deallocation
    /// sentinel. The restored archive has no original runtime ring or image
    /// store, so this answers only for this real tile and its restored document.
    private static func measureTextViewLifecycle(document: AgentDocument) throws {
        let probe = TextViewLifecycleProbe()
        guard probe.install() else { throw Failure(description: "NSTextView lifecycle probe could not install") }
        defer { probe.uninstall() }

        let initial = probe.snapshot()
        autoreleasepool {
            let stock = NSTextView(frame: .zero)
            let stockDefault = NSTextView()
            let rich = RichInlineTextView(frame: .zero)
            let code = CodeTextView()
            withExtendedLifetime((stock, stockDefault, rich, code)) {}
        }
        let deadline = Date().addingTimeInterval(2)
        while probe.snapshot().destroyed - initial.destroyed < 4 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let control = probe.snapshot()
        try expect(control.created - initial.created == 4 && control.destroyed - initial.destroyed == 4,
                   "NSTextView lifecycle probe must count stock, rich and code views created and destroyed")

        let thread = "text-view-count-\(UUID().uuidString)"
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "text view lifecycle check",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")), threadId: thread)
        tile.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        let host = NSView(frame: tile.frame)
        host.addSubview(tile)
        host.layoutSubtreeIfNeeded()
        guard let canvas = tile.qaCanvasTranscript else {
            throw Failure(description: "tile must install the canvas transcript")
        }
        tile.qaInstallTranscriptSnapshotForChecks(ManagedAgentTranscriptModel(qaRestoring: document, threadId: thread))
        canvas.flushPendingVisualUpdate()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let warm = probe.snapshot()
        var messageCreated = 0
        var messageDestroyed = 0
        var messageCreatedTotal = 0
        var messageDestroyedTotal = 0
        for _ in 0..<12 {
            let before = probe.snapshot()
            autoreleasepool {
                tile.qaBeginOptimisticSubmissionForChecks("A newly arrived message.")
                canvas.flushPendingVisualUpdate()
                host.layoutSubtreeIfNeeded()
                tile.qaFinishOptimisticSubmissionForChecks(accepted: true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let after = probe.snapshot()
            messageCreated = max(messageCreated, after.created - before.created)
            messageDestroyed = max(messageDestroyed, after.destroyed - before.destroyed)
            messageCreatedTotal += after.created - before.created
            messageDestroyedTotal += after.destroyed - before.destroyed
        }
        let turn = "text-view-count-turn"
        tile.ingest(.turnStarted(threadId: thread, turnId: turn))
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "First chunk"))
        tile.qaFlushStreamingMarkupForChecks()
        canvas.flushPendingVisualUpdate()
        var updateCreated = 0
        var updateDestroyed = 0
        var updateCreatedTotal = 0
        var updateDestroyedTotal = 0
        for _ in 0..<12 {
            let before = probe.snapshot()
            autoreleasepool {
                tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: " next chunk"))
                tile.qaFlushStreamingMarkupForChecks()
                canvas.flushPendingVisualUpdate()
                host.layoutSubtreeIfNeeded()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let after = probe.snapshot()
            updateCreated = max(updateCreated, after.created - before.created)
            updateDestroyed = max(updateDestroyed, after.destroyed - before.destroyed)
            updateCreatedTotal += after.created - before.created
            updateDestroyedTotal += after.destroyed - before.destroyed
        }
        let beforeRebuild = probe.snapshot()
        autoreleasepool { canvas.rebuild() }
        try expect(canvas.qaLastRebuildVisitedBlockCount > 100, "full rebuild must visit the long history")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let afterRebuild = probe.snapshot()
        let rebuiltCreated = afterRebuild.created - beforeRebuild.created
        let rebuiltDestroyed = afterRebuild.destroyed - beforeRebuild.destroyed
        print("NSTextView lifecycle (standard initializers): tile setup created \(warm.created - control.created); 12 prompts total \(messageCreatedTotal) created/\(messageDestroyedTotal) destructions observed, max \(messageCreated)/\(messageDestroyed) per prompt; 12 updates total \(updateCreatedTotal)/\(updateDestroyedTotal), max \(updateCreated)/\(updateDestroyed); full canvas rebuild \(rebuiltCreated)/\(rebuiltDestroyed) observed; deferred destruction may fall outside these windows")
        let setupClasses = warm.byClass.compactMap { name, count -> String? in
            let delta = count - (control.byClass[name] ?? 0)
            return delta > 0 ? "\(name)=\(delta)" : nil
        }.sorted()
        print("NSTextView tile setup classes: \(setupClasses.joined(separator: ", "))")
        try expect(messageCreated == 0 && updateCreated == 0 && rebuiltCreated == 0,
                   "transcript message or canvas rebuild must not create NSTextViews")
    }

    /// Measures the real tile's model, ingest and synchronization path against
    /// the exact captured history. A semantic archive cannot restore the live
    /// runtime event ring, tool-detail bindings, old open-stream buffer, or
    /// attachment store, so this deliberately begins a new assistant turn.
    private static func measureTileIngress(document: AgentDocument) throws {
        guard (try? document.validateIdentityInvariants()) != nil else {
            throw Failure(description: "restored document has invalid identities")
        }
        let thread = "long-tile-perf-\(UUID().uuidString)"
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "long transcript performance",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")), threadId: thread)
        tile.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        let host = NSView(frame: tile.frame)
        host.addSubview(tile)
        host.layoutSubtreeIfNeeded()
        guard let canvas = tile.qaCanvasTranscript else {
            throw Failure(description: "tile must install the canvas transcript")
        }
        tile.qaInstallTranscriptSnapshotForChecks(ManagedAgentTranscriptModel(qaRestoring: document, threadId: thread))
        canvas.flushPendingVisualUpdate()
        host.layoutSubtreeIfNeeded()
        try expect(canvas.qaPlacedBlockIDs.count > 0, "tile must present the restored transcript")

        var appendMs: [Double] = []
        var appendVisits: [Int] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            tile.qaBeginOptimisticSubmissionForChecks("A newly arrived message.")
            canvas.flushPendingVisualUpdate()
            host.layoutSubtreeIfNeeded()
            appendMs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            appendVisits.append(canvas.qaLastRebuildVisitedBlockCount)
            tile.qaFinishOptimisticSubmissionForChecks(accepted: true)
        }
        let turn = "long-tile-perf-turn"
        tile.ingest(.turnStarted(threadId: thread, turnId: turn))
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                  delta: "A streamed answer"))
        tile.qaFlushStreamingMarkupForChecks()
        canvas.flushPendingVisualUpdate()
        var updateMs: [Double] = []
        var updateVisits: [Int] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                      delta: " with another chunk"))
            tile.qaFlushStreamingMarkupForChecks()
            canvas.flushPendingVisualUpdate()
            host.layoutSubtreeIfNeeded()
            updateMs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            updateVisits.append(canvas.qaLastRebuildVisitedBlockCount)
        }
        guard let streamed = tile.qaDocumentForChecks.entries.last?.blocks.first else {
            throw Failure(description: "tile stream must produce a block")
        }
        try expect(canvas.qaPresentedBlock(for: streamed.id)?.payload == streamed.payload,
                   "tile stream must reach the rendered block")
        print(String(format: "restored tile p95: optimistic prompt %.2f ms, streamed ingest %.2f ms; max visited blocks %d prompt, %d ingest",
                     percentile95(appendMs), percentile95(updateMs), appendVisits.max() ?? 0, updateVisits.max() ?? 0))
        try expect((appendVisits.max() ?? 0) <= 8, "tile prompt must not walk transcript history")
        try expect((updateVisits.max() ?? 0) <= 8, "tile stream must not walk transcript history")
    }
}
