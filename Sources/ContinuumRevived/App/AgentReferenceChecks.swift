import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Exercises the real source control and destination handler in the production
/// workspace scene, then drives the composer's actual send action to its sink.
@MainActor
enum AgentReferenceChecks {
    static func run() async throws {
        for zoom in [1.0, 0.35] {
            for autoLayout in [false, true] {
                try await exercise(zoom: zoom, autoLayout: autoLayout)
            }
        }
    }

    private static func exercise(zoom: Double, autoLayout: Bool) async throws {
        let fixture = try TileInsertSlideChecks.makeFixture("agent-reference")
        defer { fixture.dispose() }
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        let projectStore = ProjectStore(projectRoot: root)
        var state = try projectStore.loadCanvas()
        let tileIDs = [TileInsertSlideChecks.tileA, TileInsertSlideChecks.tileB]
        for (offset, id) in tileIDs.enumerated() {
            let index = state.tiles.firstIndex { $0.id == id }!
            state.tiles[index].kind = .managedAgent
            state.tiles[index].metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
            state.tiles[index].frame = TileFrame(x: 440 + Double(offset) * 660, y: 380, width: 640, height: 520)
        }
        try projectStore.saveCanvas(state)
        var agents: [AgentID] = []
        let appSupport = fixture.appSupport
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            for id in tileIDs {
                agents.append(delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                    model: "fixture/reference", thinking: "medium",
                    projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root,
                    tileId: id, displayName: "Same name"))
            }
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("agent reference")
        let canvas = mounted.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: autoLayout)
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil) }
        guard let source = canvas.tileView(for: tileIDs[0]) as? ManagedAgentTileNSView,
              let target = canvas.tileView(for: tileIDs[1]) as? ManagedAgentTileNSView,
              let composer = target.qaComposerForChecks else {
            throw TileInsertSlideChecks.Failure(message: "production mount did not hydrate managed tiles")
        }
        mounted.delegate.wireManagedAgentTile(tileIDs[0], agentID: agents[0])
        mounted.delegate.wireManagedAgentTile(tileIDs[1], agentID: agents[1])
        // Wait for the bound draft restore, then use a recording sink at the
        // actual action boundary rather than constructing an outgoing prompt.
        await composer.qaAwaitDraftRestore()
        let sink = ReferenceSink()
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport)
        composer.bindDraftStore(drafts, agentID: agents[1])
        await composer.qaAwaitDraftRestore()
        composer.bindActionSink(sink, agentID: agents[1], snapshot: .init(
            state: .ready, capabilities: .init(canSend: true), turnStartedAt: nil))
        composer.apply(.init(text: "Compare your changes with theirs", selection: NSRange(location: 0, length: 0), revision: 1))
        canvas.layoutSubtreeIfNeeded()
        // Flush the mount/camera's pending save before attributing any later
        // canvas write to the gesture under test.
        try mounted.runtime.controller(for: WorkspaceInvariantsFixture.projectA1)?.flushCanvasSave()
        canvas.tileSelection.selectOnly(tileIDs[0])
        let selectionPoint = target.convert(NSPoint(x: target.bounds.midX, y: 12), to: nil)
        _ = canvas.tileSelection.mouseDown(on: target,
            event: event(.leftMouseDown, selectionPoint, [.shift]), isHeader: true, isResize: false)
        _ = canvas.tileSelection.mouseUp(with: event(.leftMouseUp, selectionPoint, [.shift]))
        try TileInsertSlideChecks.expect(canvas.tileSelection.ids == Set(tileIDs), "reference witness must start with a real multi-selection")
        let selectionBefore = canvas.tileSelection.ids
        let before = canvas.allTilesInWorldFrames()
        let documentBefore = mounted.runtime.document
        let diskBefore = try Data(contentsOf: projectStore.layout.canvasFile)
        let undoBefore = canvas.undoManager?.canUndo
        // The requested gesture is the TILE HEADER, not the supplemental @
        // control. Cross the recipient's swap region before its composer: the
        // layout must remain fixed throughout, or the drop target runs away.
        canvas.tileSelection.selectOnly(tileIDs[0])
        let headerStart = source.convert(NSPoint(x: source.bounds.midX, y: source.chromeBarHeight / 2), to: nil)
        let recipientHeader = target.convert(NSPoint(x: target.bounds.midX, y: target.chromeBarHeight / 2), to: nil)
        let compose = target.qaPageZoomComposeBackdrop
        let recipientComposer = compose.convert(NSPoint(x: compose.bounds.midX, y: compose.bounds.midY), to: nil)
        source.mouseDown(with: event(.leftMouseDown, headerStart))
        source.mouseDragged(with: event(.leftMouseDragged, recipientHeader))
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before,
            "header drag must defer auto-layout before crossing the recipient's swap region")
        source.mouseDragged(with: event(.leftMouseDragged, recipientComposer))
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before,
            "composer reference hover must leave source, recipient and sibling geometry fixed")
        if zoom == 1, !autoLayout {
            let directory = URL(fileURLWithPath: "qa-runs/agent-reference-check", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("header-drop-light", NSAppearance.Name.aqua), ("header-drop-dark", .darkAqua)] {
                canvas.appearance = NSAppearance(named: appearance)
                canvas.layoutSubtreeIfNeeded()
                guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                    throw TileInsertSlideChecks.Failure(message: "cannot render header reference hover")
                }
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        source.mouseUp(with: event(.leftMouseUp, recipientComposer))
        await target.qaAwaitReferenceDrop()
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.map(\.agentID) == [agents[0]] && sink.prompts.isEmpty,
            "dragging the tile header onto a composer must add exactly one unsent reference")
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before && mounted.runtime.document == documentBefore,
            "header reference drop must preserve tile frames and zone document")
        let diskAfterHeaderReference = try Data(contentsOf: projectStore.layout.canvasFile)
        try TileInsertSlideChecks.expect(diskAfterHeaderReference == diskBefore,
            "header reference drop must not persist geometry")
        composer.qaRemoveAgentReference(at: 0)
        source.mouseDown(with: event(.leftMouseDown, headerStart))
        source.mouseDragged(with: event(.leftMouseDragged, recipientComposer))
        canvas.cancelOperation(nil)
        source.mouseUp(with: event(.leftMouseUp, recipientComposer))
        await target.qaAwaitReferenceDrop()
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.isEmpty && canvas.allTilesInWorldFrames() == before
            && !canvas.isGeometryGestureActive && !AgentReferenceDragHandle.isTracking(in: window),
            "Escape during header reference hover must cancel without a late drop or geometry commit")
        _ = canvas.tileSelection.mouseDown(on: target,
            event: event(.leftMouseDown, selectionPoint, [.shift]), isHeader: true, isResize: false)
        _ = canvas.tileSelection.mouseUp(with: event(.leftMouseUp, selectionPoint, [.shift]))
        print("AgentReferenceChecks header drag through swap region passed zoom=\(zoom) autoLayout=\(autoLayout)")
        let handle = source.qaReferenceDragHandle
        try TileInsertSlideChecks.expect(!handle.isHidden && handle.bounds.width > 0, "reference control must be reachable at zoom \(zoom)")
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let hit = source.hitTest(source.superview!.convert(point, from: nil))
        try TileInsertSlideChecks.expect(hit === handle, "reference control must win over the enlarged move strip")
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var transferred: Data?
        var nativePasteboardAvailable = false
        handle.dragSessionForChecks = { item in
            transferred = item.data(forType: AgentReferenceDragHandle.pasteboardType)
            board.clearContents()
            nativePasteboardAvailable = board.writeObjects([item])
        }
        handle.mouseDown(with: event(.leftMouseDown, point, [.shift]))
        handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: point.x + 60, y: point.y - 50), [.shift]))
        try TileInsertSlideChecks.expect(handle.startedDragCount == 1, "explicit handle must start exactly one copy drag even with Shift")
        try TileInsertSlideChecks.expect(AgentReferenceDragHandle.isTracking(in: window), "reference intent must suppress mouse-up selection/focus routing")
        guard let transferredReference = AgentReferenceDragHandle.reference(from: transferred) else {
            throw TileInsertSlideChecks.Failure(message: "source did not encode a valid reference")
        }
        try TileInsertSlideChecks.expect(transferredReference.agentID == agents[0], "native drag item must name its owning agent")
        if !nativePasteboardAvailable {
            print("MATRIX-NOTE: native pasteboard service unavailable; reference source item and production recipient exercised through the decoded data seam")
        }
        func drop(_ view: ManagedAgentTileNSView, commit: Bool) -> Bool {
            nativePasteboardAvailable ? view.handleAgentReference(board, commit: commit)
                : view.handleAgentReference(transferredReference, commit: commit)
        }
        try TileInsertSlideChecks.expect(drop(target, commit: false), "whole tile must accept reference hover")
        try TileInsertSlideChecks.expect(drop(target, commit: true), "whole tile must forward a reference to the draft")
        try TileInsertSlideChecks.expect(drop(target, commit: true), "repeated drop must be harmless")
        try TileInsertSlideChecks.expect(!drop(source, commit: true), "self-drop must be refused")
        await target.qaAwaitReferenceDrop()
        handle.mouseUp(with: event(.leftMouseUp, point))
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.map(\.agentID) == [agents[0]], "duplicate names must resolve by exact identity and repeated drops deduplicate")
        try TileInsertSlideChecks.expect(composer.draft.text == "Compare your changes with theirs" && sink.prompts.isEmpty, "drop preserves text and never sends")
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before && mounted.runtime.document == documentBefore,
            "reference drag must change no world frames, ordering, membership or zones")
        try TileInsertSlideChecks.expect(canvas.tileSelection.ids == selectionBefore && canvas.undoManager?.canUndo == undoBefore,
            "reference drag must preserve selection and geometry undo")
        let diskAfter = try Data(contentsOf: projectStore.layout.canvasFile)
        try TileInsertSlideChecks.expect(diskAfter == diskBefore, "drop must not write project canvas")

        // The same private type is also handled when AppKit picks the editor.
        if nativePasteboardAvailable {
            try TileInsertSlideChecks.expect(composer.textView.onAgentReferenceDrag?(board, true) == true, "editor drop must use the same validated recipient route")
        }
        await target.qaAwaitReferenceDrop()
        let ref = composer.draft.agentReferences[0]
        for _ in 0..<10 { await Task.yield() }
        try await drafts.flushReportingFailure(agentID: agents[1])
        let reloaded = await AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport).load(for: agents[1])
        try TileInsertSlideChecks.expect(reloaded?.agentReferences == [ref], "agent reference must survive a fresh draft store")
        let queued = await drafts.enqueueMessage(text: "later", agentReferences: [ref], for: agents[1])
        let steered = await drafts.enqueueSteer(text: "now", agentReferences: [ref], for: agents[1])
        let queue = await AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport).queuedMessages(for: agents[1])
        try TileInsertSlideChecks.expect(queue.map(\.id) == [steered.id, queued.id] && queue.allSatisfy { $0.agentReferences == [ref] }, "durable queue and steer must preserve references")
        if zoom == 1, !autoLayout {
            let directory = URL(fileURLWithPath: "qa-runs/agent-reference-check", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                target.applyTokens()
                canvas.layoutSubtreeIfNeeded()
                guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
                    throw TileInsertSlideChecks.Failure(message: "cannot render reference chip")
                }
                target.cacheDisplay(in: target.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        composer.composerRequestedSend(composer.textView)
        for _ in 0..<100 where sink.prompts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try TileInsertSlideChecks.expect(sink.prompts.count == 1 && sink.prompts[0].agentReferences == [ref], "real composer send must deliver reference to the sink exactly once")
        let sent = sink.prompts[0]
        let wire = sent.providerText
        try TileInsertSlideChecks.expect(ClaudeAgentRunner.promptArgument(sent) == wire
            && CodexCLIBackend.promptArgument(sent) == wire
            && PiAgentRunner.promptArgumentSegments(sent) == [wire], "all harnesses must receive the same reference envelope")
        let parsed = AgentReferencePromptEnvelope.parse(wire)
        try TileInsertSlideChecks.expect(parsed?.references == [ref] && parsed?.text == sent.text, "provider reference must roundtrip without sharing a conversation")
        let mixed = AgentReferencePromptEnvelope.parse(wire + "\n@/tmp/design doc.md")
        try TileInsertSlideChecks.expect(mixed?.references == [ref] && mixed?.text == sent.text + "\n\n@/tmp/design doc.md",
            "reference decoding must preserve provider-appended file paths")
        var live = AgentTranscriptProjection(threadId: "reference-live")
        var restored = AgentTranscriptProjection(threadId: "reference-restored")
        let entryID = AgentNodeID(rawValue: "reference-check")!
        try live.appendUserPrompt(id: entryID, prompt: sent)
        try restored.appendUserPrompt(id: entryID, prompt: AgentPrompt(wire))
        try TileInsertSlideChecks.expect(live.document.entries.first?.blocks == restored.document.entries.first?.blocks, "live and restored transcripts must show the same user mention")
        composer.apply(.init(text: "", selection: NSRange(location: 0, length: 0), revision: 3, agentReferences: [ref]))
        composer.qaRemoveAgentReference(at: 0)
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.isEmpty, "remove chip must remove its reference")
        // Leave the reference target, then release over the recipient's header.
        // That must still go through the ordinary move/swap persistence path.
        canvas.tileSelection.selectOnly(tileIDs[0])
        source.mouseDown(with: event(.leftMouseDown, headerStart))
        source.mouseDragged(with: event(.leftMouseDragged, recipientComposer))
        source.mouseDragged(with: event(.leftMouseDragged, recipientHeader))
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before && composer.draft.agentReferences.isEmpty,
            "retreating from composer must keep layout pending and add no reference")
        source.mouseUp(with: event(.leftMouseUp, recipientHeader))
        await target.qaAwaitReferenceDrop()
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() != before && composer.draft.agentReferences.isEmpty
            && !canvas.isGeometryGestureActive && !AgentReferenceDragHandle.isTracking(in: window),
            "header release outside composer must commit a normal move/swap and add no reference")
        let persistedAfterMove = try projectStore.loadCanvas()
        let visibleSource = canvas.allTilesInWorldFrames().first { $0.id == tileIDs[0] }
        try TileInsertSlideChecks.expect(persistedAfterMove.tiles.first { $0.id == tileIDs[0] }?.frame == visibleSource?.frame,
            "ordinary fallback must persist the same world frame shown on canvas")
        print("AgentReferenceChecks PASS zoom=\(zoom) autoLayout=\(autoLayout): source, drop, layout, draft, queue, steer, send, harnesses, transcript")
    }
}

@MainActor
private final class ReferenceSink: AgentTileActionSink {
    var prompts: [AgentPrompt] = []
    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        if case .sendPrompt(let prompt) = intent { prompts.append(prompt) }
        return .accepted
    }
}
