import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Exercises the real recipient route in the production workspace scene, then
/// drives the composer's actual send action to its sink. The header drag that
/// reaches this route is `CanvasPointerPathChecks`.
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
        // The pointer gesture itself is `--canvas-pointer-path-check`, through
        // real window events. This leg owns the recipient route and the draft.
        let before = canvas.allTilesInWorldFrames()
        let documentBefore = mounted.runtime.document
        let diskBefore = try Data(contentsOf: projectStore.layout.canvasFile)
        let dropped = AgentPromptReference(agentID: agents[0], displayName: "spoofed label")
        try TileInsertSlideChecks.expect(target.handleAgentReference(dropped, commit: false), "recipient must accept reference hover")
        try TileInsertSlideChecks.expect(target.handleAgentReference(dropped, commit: true), "recipient must forward a reference to the draft")
        try TileInsertSlideChecks.expect(target.handleAgentReference(dropped, commit: true), "repeated drop must be harmless")
        try TileInsertSlideChecks.expect(!source.handleAgentReference(dropped, commit: true), "self-drop must be refused")
        await target.qaAwaitReferenceDrop()
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.map(\.displayName) == ["Same name"],
            "the chip must name the source from its record, never the caller's label")
        try TileInsertSlideChecks.expect(composer.draft.agentReferences.map(\.agentID) == [agents[0]], "duplicate names must resolve by exact identity and repeated drops deduplicate")
        try TileInsertSlideChecks.expect(composer.draft.text == "Compare your changes with theirs" && sink.prompts.isEmpty, "drop preserves text and never sends")
        try TileInsertSlideChecks.expect(canvas.allTilesInWorldFrames() == before && mounted.runtime.document == documentBefore,
            "reference drop must change no world frames, ordering, membership or zones")
        let diskAfter = try Data(contentsOf: projectStore.layout.canvasFile)
        try TileInsertSlideChecks.expect(diskAfter == diskBefore, "drop must not write project canvas")

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
        print("AgentReferenceChecks PASS zoom=\(zoom) autoLayout=\(autoLayout): drop, draft, queue, steer, send, harnesses, transcript")
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
