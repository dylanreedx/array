import AppKit
import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-transcript-parity-check [dir]`: a teammate sees a shared
/// agent's transcript exactly as its owner's tile draws it.
///
/// Host: a production supervisor, the production projection host
/// (`SharedAreaAgentProjectionHost.sync`), which starts the transcript
/// publisher, and a real `ManagedAgentTileNSView` attached the way the canvas
/// attaches one. Relay: the lane's own `Collaboration.AgentTranscript.Log`,
/// which the service runs. Guest: `SharedAgentLiveView`'s own lane poll into
/// `SharedAgentTranscriptView`. Asserted: the same renderer class, the same
/// document, the same placed blocks and laid-out text, through a checkpoint,
/// streamed patches, a late joiner and a relay that loses a frame. Light and
/// dark stills of host beside guest go to `dir`.
@MainActor
enum SharedAgentTranscriptParityChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    typealias Lane = Collaboration.AgentTranscript

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS shared transcript parity: \(label)")
    }

    /// The relay's lane: the service's `Log`, behind the publisher's sink seam.
    final class LaneSink: SharedAgentTranscriptSink {
        let host: SharedArea.ID<SharedArea.Host>
        var log: Lane.Log?
        var publishes = 0
        /// Acknowledge but lose the next frame, as a relay restart between
        /// frames does.
        var loseNextFrame = false
        init(host: SharedArea.ID<SharedArea.Host>) { self.host = host }
        func publish(stream: String, checkpoint: Lane.Checkpoint?, frames: [Lane.Frame]) async throws {
            publishes += 1
            if loseNextFrame, checkpoint == nil { loseNextFrame = false; log = nil; return }
            do { log = try Lane.Log.publish(.init(epoch: 1, host: host, stream: stream, checkpoint: checkpoint, frames: frames), onto: log) }
            catch .checkpointRequired { throw SharedAgentTranscriptRefusal.checkpointRequired }
            catch .stale { throw SharedAgentTranscriptRefusal.superseded }
        }
        func read(_ request: Lane.ReadRequest) throws -> Lane.Read {
            guard let log else { throw Failure(description: "unavailable") }
            return log.read(after: request.cursor)
        }
    }
    final class ProjectionSink: SharedAgentProjectionSink {
        var log: Collaboration.AgentProjection.Log?
        func publish(_ batch: Collaboration.AgentProjection.Batch) async throws {
            if log == nil {
                guard let snapshot = batch.snapshot else { throw SharedAgentProjectionRefusal.resnapshotRequired }
                log = .init(snapshot: snapshot)
            }
            try log!.publish(batch)
        }
    }

    static func run(directory: URL) async throws {
        let root = try SharedAreaCheckRig.root("shared-transcript-parity")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Host: a supervisor with a durable transcript, as production has.
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID(), agent = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(id: agent, displayName: "Checkout states", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                     thinking: "none", cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { print("supervisor: \($0)") }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        let thread = AgentSupervisor.threadId(for: agent)
        func deliver(_ event: AgentRuntimeEvent) { supervisor.qaDeliver(event, to: agent) }

        // The production host session: projection and transcript, per binding.
        let hostID = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
        let lane = LaneSink(host: hostID), projection = ProjectionSink()
        let projectionHost = SharedAreaAgentProjectionHost(supervisor: supervisor, directory: root, makeSink: { _ in projection },
                                                           makeTranscriptSink: { _, _ in lane })
        projectionHost.sync([.init(object: object, binding: .init(), host: hostID, projectID: project, agentID: agent)])
        guard let publisher = projectionHost.transcripts[object] else { throw Failure(description: "the host session started no transcript publisher") }
        publisher.stop()   // the check drives ticks itself, deterministically

        // A turn with everything the old view flattened away.
        let sent = supervisor.send(AgentPrompt("Map every state the checkout can be in, and the events that move it."), to: agent)
        try expect(sent, "the owner's prompt starts a turn")
        deliver(.turnStarted(threadId: thread, turnId: "t1"))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .reasoning, delta: "Start from the cart and follow payment."))
        deliver(.itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "rg -n \"enum CheckoutState\" Sources"))
        deliver(.itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed))
        deliver(.itemStarted(threadId: thread, itemId: "edit-1", kind: .fileChange, title: "Sources/Checkout/CheckoutState.swift"))
        deliver(.itemCompleted(threadId: thread, itemId: "edit-1", kind: .fileChange, status: .completed))
        let child = UUID()
        deliver(.itemStarted(threadId: thread, itemId: "task-1", kind: .subagent, title: "Audit the wallet path"))
        deliver(.childAgentSpawned(threadId: thread, childAgentID: child, parentAgentID: agent.rawValue, displayName: "Wallet auditor",
                                   sourceItemID: "task-1", provider: "pi", spawnedAt: Date()))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant,
                              delta: "**Seven states.** `Cart`, `Address`, `Payment`, `Authorising`, `Paid`, plus:\n\n- Declined\n- Abandoned\n\n```swift\nenum CheckoutState { case cart, address, payment, authorising, paid, declined, abandoned }\n```\n"))
        let oversized = String(repeating: "let row = 1 // padding to exceed the block budget\n", count: 900)
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "\n```text\n" + oversized + "```\n\nWallets next."))
        var hostTile: ManagedAgentTileNSView?
        func settleHost() async throws {
            for _ in 0..<20 { await Task.yield() }
            hostTile?.qaFlushStreamingMarkupForChecks(final: true)
        }
        try await settleHost()

        // Host tile, attached the way the canvas attaches one.
        let tile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Checkout states",
                                                     frame: .init(x: 0, y: 0, width: 520, height: 760), zPosition: .fromLegacyRank(1),
                                                     runtimeRef: nil, metadata: .init()), threadId: thread)
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
        tile.attach(agentID: agent, supervisor: supervisor)
        hostTile = tile
        try await settleHost()

        // Guest: the live view's own lane poll, reading the relay's log.
        let me = Collaboration.Identity(person: .init(), device: UUID()), owner = Collaboration.Identity(person: .init(), device: UUID())
        let item = SharedArea.Item(id: object, kind: .agentObservation, source: .init(owner: owner.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 400, height: 500), z: 1))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (owner, .owner)])
        let controller = try SharedAreaCheckRig.controller(root: root.appendingPathComponent("guest"), identity: me, label: "Sam",
                                                           authority: authority, seed: (document, .editor))
        func makeGuest() -> SharedAgentLiveView {
            let live = SharedAgentLiveView(controller: controller,
                read: { _, cursor in
                    guard let log = projection.log else { throw Failure(description: "no projection") }
                    return log.read(after: cursor)
                },
                readTranscript: { _, request in try lane.read(request) })
            live.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
            return live
        }
        let guest = makeGuest()
        guest.show(object: object, in: document)
        guest.stop()   // the check polls itself, deterministically

        // Host tile and guest view side by side, off screen, for layout and stills.
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 800))
        canvas.wantsLayer = true
        tile.frame.origin = NSPoint(x: 20, y: 20); guest.frame.origin = NSPoint(x: 548, y: 20)
        canvas.addSubview(tile); canvas.addSubview(guest)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        func paint() async throws {
            for _ in 0..<3 {
                canvas.layoutSubtreeIfNeeded()
                guest.transcriptView.surface.flushPendingVisualUpdate(); tile.qaTranscriptSurface?.flushPendingVisualUpdate()
                canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        // Negative control: before the host publishes the lane, the guest has
        // only the flattened rows, which is what 0.7.39 drew.
        try await expect(!guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0) && !guest.transcriptLive,
                         "with no transcript lane the guest falls back to the projection rows (the 0.7.39 view)")

        await publisher.tick()
        try await expect(guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0) && guest.transcriptLive,
                         "once the host publishes, the guest switches to the transcript lane")
        let hostSurface = try surface(of: tile), guestSurface = guest.transcriptView.surface
        try expect(type(of: hostSurface) == type(of: guestSurface),
                   "the guest draws with the host tile's renderer (\(type(of: hostSurface)))")

        func compare(_ label: String) async throws {
            let source = supervisor.transcriptDocument(for: agent)?.entries ?? []
            let mirror = guest.transcriptView.qaMirrorDocument.entries
            let budget = SharedAgentTranscriptTruncatingBudget()
            try expect(!mirror.isEmpty && mirror == source.map { budget.fit($0) },
                       "\(label): the guest's document is the owner's, entry for entry, ids and revisions (\(mirror.count) entries)")
            let shown = tile.qaDocumentForChecks.entries.map { visible(budget.fit($0)) }
            try expect(mirror.map(visible) == shown,
                       "\(label): the guest shows what the owner's tile shows, block for block")
            try await paint()
            if let host = hostSurface as? AgentTranscriptCanvasView, let guest = guestSurface as? AgentTranscriptCanvasView {
                try expect(host.qaPlacedBlockIDs == guest.qaPlacedBlockIDs && !guest.qaPlacedBlockIDs.isEmpty,
                           "\(label): the same blocks are placed, in the same order (\(guest.qaPlacedBlockIDs.count))")
            }
        }
        try await compare("checkpoint")
        let kinds = Set(guest.transcriptView.qaMirrorDocument.entries.flatMap(\.blocks).map(\.kind.rawValue))
        let roles = Set(guest.transcriptView.qaMirrorDocument.entries.map(\.role.rawValue))
        try expect(["tool-call", "agent-reference", "fenced-code", "list", "diff"].allSatisfy(kinds.contains)
                   && ["user", "assistant"].allSatisfy(roles.contains),
                   "the guest holds the prompt, tool calls, the file change, the subagent, markup and code (\(kinds.sorted()), \(roles.sorted()))")
        let laid = (guestSurface as? AgentTranscriptCanvasView)?.qaLaidOutText ?? ""
        try expect(laid.contains("CheckoutState") || laid.contains("Seven states"), "the guest lays out the host's words")
        let hostBlocks = Dictionary((supervisor.transcriptDocument(for: agent)?.entries ?? []).flatMap(\.blocks).map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let cut = guest.transcriptView.qaMirrorDocument.entries.flatMap(\.blocks).filter { block in
            hostBlocks[block.id].map { $0.kind != block.kind || $0.payload != block.payload } ?? false
        }
        try expect(!cut.isEmpty && cut.allSatisfy { hostBlocks[$0.id]?.revision == $0.revision },
                   "a block over the budget arrives under the host's own id and revision, cut (\(cut.map(\.kind.rawValue)))")

        // Streaming: patches, not checkpoints.
        let checkpoints = publisher.checkpoints
        deliver(.turnStarted(threadId: thread, turnId: "t2"))
        for word in ["Adding ", "Wallet ", "between ", "Payment ", "and ", "Authorising."] {
            deliver(.contentDelta(threadId: thread, turnId: "t2", streamKind: .assistant, delta: word))
            try await settleHost()
            await publisher.tick()
            _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        }
        deliver(.turnCompleted(threadId: thread, turnId: "t2", outcome: .completed, errorMessage: nil))
        try await settleHost(); await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        try expect(publisher.checkpoints == checkpoints && publisher.frames > 0 && guest.transcriptView.appliedFrames > 0,
                   "streamed text travels as patches (\(publisher.frames) frames, no new checkpoint)")
        try await compare("after streaming")

        // A relay that loses a frame: the next publish is refused, the host
        // checkpoints, and the guest converges without guessing.
        lane.loseNextFrame = true
        deliver(.turnStarted(threadId: thread, turnId: "t3"))
        deliver(.contentDelta(threadId: thread, turnId: "t3", streamKind: .assistant, delta: "A wallet failure returns to Payment."))
        try await settleHost(); await publisher.tick()
        deliver(.turnCompleted(threadId: thread, turnId: "t3", outcome: .completed, errorMessage: nil))
        try await settleHost(); await publisher.tick(); await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        try expect(publisher.checkpoints > checkpoints, "a lost frame costs one checkpoint")
        try await compare("after a lost frame")

        // A late joiner starts from the checkpoint and the frames after it.
        let late = makeGuest()
        late.show(object: object, in: document); late.stop()
        _ = await late.pollTranscript(object, ticket: late.qaTicket, waitMilliseconds: 0)
        try expect(late.transcriptView.qaMirrorDocument.entries == guest.transcriptView.qaMirrorDocument.entries,
                   "a late joiner sees the same transcript")

        // Stills: host tile beside the guest's view, light and dark.
        // The status lane (agent-chrome's) once, so the header reads as live.
        await guest.poll(object, ticket: guest.qaTicket)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layer?.backgroundColor = SurfaceToken.canvas.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor
            try await paint()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw Failure(description: "no bitmap") }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
            let url = directory.appendingPathComponent("transcript-parity-\(appearance == .aqua ? "light" : "dark").png")
            try png.write(to: url)
            print("WROTE \(url.path)")
        }
        projectionHost.stop()
    }

    /// What a reader sees of an entry: role and blocks, without revisions or
    /// source ranges, which count parses rather than content.
    private static func visible(_ entry: AgentEntry) -> String {
        func block(_ value: AgentBlock) -> String {
            var copy = value; copy.revision = 0; copy.sourceRange = nil; copy.children = []
            let data = (try? SharedAgentTranscriptWire.encode(copy)) ?? Data()
            return String(decoding: data, as: UTF8.self) + "[" + value.children.map(block).joined(separator: ",") + "]"
        }
        return "\(entry.role.rawValue):" + entry.blocks.map(block).joined(separator: "|")
    }

    private static func surface(of tile: ManagedAgentTileNSView) throws -> any AgentTranscriptSurface {
        guard let surface = tile.qaTranscriptSurface else { throw Failure(description: "host tile has no transcript surface") }
        return surface
    }
}
