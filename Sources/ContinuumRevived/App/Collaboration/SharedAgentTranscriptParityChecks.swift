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
        supervisor.qaObserveSharedTranscript(.toolDetail(itemId: "cmd-1", detail: .init(phase: .started, toolName: "bash", fields: [(key: "command", value: "echo hello")], observedAt: Date())), for: agent)
        supervisor.qaObserveSharedTranscript(.toolDetail(itemId: "cmd-1", detail: .init(phase: .ended, outputPreview: "hello from command", exitCode: 0, observedAt: Date())), for: agent)
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
        let toolFixtures: [(String, ItemKind, String)] = [
            ("read-1", .mcpToolCall, "Read"), ("edit-detail-1", .fileChange, "Edit"),
            ("search-1", .mcpToolCall, "Search"), ("web-1", .webSearch, "WebFetch"),
            ("mcp-1", .mcpToolCall, "mcp__example__query"), ("failed-1", .commandExecution, "bash"),
            ("private-1", .mcpToolCall, "mcp__example__private")
        ]
        for (item, kind, name) in toolFixtures {
            deliver(.itemStarted(threadId: thread, itemId: item, kind: kind, title: name))
            supervisor.qaObserveSharedTranscript(.toolDetail(itemId: item, detail: .init(phase: .started, toolName: name,
                fields: [(key: "query", value: "visible query")],
                fileChanges: item == "edit-detail-1" ? [.init(action: .edit, path: "Sources/Checkout.swift", addedLines: 2, removedLines: 1)] : [],
                observedAt: Date())), for: agent)
            let output = item == "mcp-1" ? String(repeating: "x", count: 5 * 1024 * 1024)
                : (item == "private-1" ? "token=supersecretvalue" : "visible result for \(name)")
            supervisor.qaObserveSharedTranscript(.toolDetail(itemId: item, detail: .init(phase: .ended, outputPreview: output,
                exitCode: item == "failed-1" ? 1 : 0, observedAt: Date())), for: agent)
            deliver(.itemCompleted(threadId: thread, itemId: item, kind: kind, status: item == "failed-1" ? .failed : .completed))
        }
        for _ in 0..<200 {
            let details = supervisor.sharedTranscriptToolBlocks(for: agent)
            let outputs = details.values.compactMap { block -> String? in
                guard case let .toolCall(tool) = block.payload else { return nil }
                return tool.presentedOutputText
            }
            if details.count >= toolFixtures.count + 1 && outputs.contains("hello from command")
                && outputs.contains(where: { $0.count == AgentToolDetailObservation.maxOutputCharacters })
                && outputs.contains(where: { $0.contains("[REDACTED]") || $0.contains("redaction unavailable") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let headlessDetails = supervisor.sharedTranscriptToolBlocks(for: agent)
        try expect(headlessDetails.values.contains { block in
            guard case let .toolCall(tool) = block.payload else { return false }
            return tool.presentedOutputText == "hello from command"
        }, "tool detail is captured by the supervisor with no tile")
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
        guard let publishedLog = lane.log else { throw Failure(description: "transcript log missing") }
        let publishedBodies = [publishedLog.checkpoint.body] + publishedLog.frames.map(\.body)
        try expect(!publishedBodies.contains { String(decoding: $0, as: UTF8.self).contains("supersecretvalue") },
                   "a secret-shaped tool output is redacted before it reaches the lane")
        try expect(!publishedBodies.contains { String(decoding: $0, as: UTF8.self).contains("Audit the wallet path") },
                   "a delegation row hidden by a subagent chip does not disclose its hidden title")
        let sharedDetails = headlessDetails.compactMapValues { SharedAgentToolPresentation(presented: $0) }
        try expect(guest.transcriptView.mirror.toolDetails == sharedDetails,
                   "command, read, edit, search, web and MCP presented details survive the checkpoint")
        let longPreview = headlessDetails.values.compactMap { block -> String? in
            guard case let .toolCall(tool) = block.payload, tool.presentedOutputText?.hasPrefix("xxxx") == true else { return nil }
            return tool.presentedOutputText
        }.first
        try expect(longPreview?.count == AgentToolDetailObservation.maxOutputCharacters,
                   "a 5 MiB output reaches the guest at the host observation's own preview limit")
        let pendingBlock = AgentBlock(id: AgentNodeID(rawValue: "pending-tool")!, kind: .toolCall,
            payload: .toolCall(.init(name: "Waiting for tool", status: .pending)))
        let nestedTool = AgentBlock(id: AgentNodeID(rawValue: "pending-nested-tool")!, kind: .toolCall,
            payload: .toolCall(.init(name: "Nested visible tool", status: .pending)))
        let nestedContainer = AgentBlock(id: AgentNodeID(rawValue: "pending-container")!, kind: .quote,
            payload: .quote, children: [nestedTool])
        let pendingEntry = AgentEntry(id: AgentNodeID(rawValue: "pending-entry")!, role: .system,
            provenance: .localNotice(reason: "pending fixture"), lifecycle: .open(markupBlockID: nil), blocks: [pendingBlock, nestedContainer])
        let pendingLane = LaneSink(host: hostID)
        let pendingPublisher = SharedAgentTranscriptPublisher(agent: agent, generation: 1, sink: pendingLane,
            details: { [pendingBlock.id: SharedAgentToolPresentation(presented: pendingBlock)!,
                        nestedTool.id: SharedAgentToolPresentation(presented: nestedTool)!] },
            document: { AgentDocument(version: 1, entries: [pendingEntry]) })
        await pendingPublisher.tick()
        let pendingGuest = SharedAgentTranscriptView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        try expect(pendingGuest.receive(try pendingLane.read(.init(stream: Lane.mainStream, cursor: nil, waitMilliseconds: 0))),
                   "a pending tool reaches the guest lane")
        pendingGuest.layoutSubtreeIfNeeded(); pendingGuest.surface.flushPendingVisualUpdate()
        let pendingRendered: AgentBlock?
        if let canvas = pendingGuest.surface as? AgentTranscriptCanvasView { pendingRendered = canvas.qaPresentedBlock(for: pendingBlock.id) }
        else if let list = pendingGuest.surface as? AgentTranscriptListView { pendingRendered = list.qaPresentedToolBlock(for: pendingBlock.id) }
        else { pendingRendered = nil }
        guard case let .toolCall(pendingTool)? = pendingRendered?.payload else { throw Failure(description: "pending tool row missing") }
        try expect(pendingTool.status == .pending && pendingTool.name == "Waiting for tool", "the guest renderer retains the pending tool state and visible name")
        guard let nestedRendered = pendingGuest.qaRenderedDocument.entries.first?.blocks.last?.children.first,
              case let .toolCall(nestedValue) = nestedRendered.payload else { throw Failure(description: "nested tool missing") }
        try expect(nestedValue.name == "Nested visible tool" && nestedValue.status == .pending,
                   "a nested tool presentation survives into the guest render feed")

        // Two references to the same multi-frame image: the lane sends the
        // digest's bytes once and a late reader reconstructs both aliases.
        let imageA = AgentImageAttachmentID(rawValue: "shared-image-a")!
        let imageB = AgentImageAttachmentID(rawValue: "shared-image-b")!
        let imageC = AgentImageAttachmentID(rawValue: "shared-image-too-large")!
        guard let imageFixture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure(description: "image fixture allocation") }
        for y in 0..<64 { for x in 0..<64 {
            let color = (x / 16 + y / 16).isMultiple(of: 2)
                ? NSColor(calibratedRed: 0.15, green: 0.40, blue: 0.85, alpha: 1)
                : NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.12, alpha: 1)
            imageFixture.setColor(color, atX: x, y: y)
        } }
        guard var imageBytes = imageFixture.representation(using: .png, properties: [:]) else { throw Failure(description: "image fixture encoding") }
        imageBytes.append(Data(repeating: 0, count: 40_000))
        let imageBlock = AgentBlock(id: AgentNodeID(rawValue: "shared-image-block")!, kind: .imageGallery,
            payload: .imageGallery(.init(images: [.init(attachment: .init(id: imageA)), .init(attachment: .init(id: imageB)),
                .init(attachment: .init(id: imageC, byteCount: UInt64(SharedAgentTranscriptImages.maxImageBytes + 1)))])))
        let imageEntry = AgentEntry(id: AgentNodeID(rawValue: "shared-image-entry")!, role: .user,
            provenance: .localNotice(reason: "image fixture"), lifecycle: .finished, blocks: [imageBlock])
        var imageDocument = AgentDocument(version: 1, entries: [imageEntry])
        var privateImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
        privateImage.append(Data("private-image-metadata".utf8))
        let staged = try await supervisor.stageBrowserScreenshot(privateImage, for: agent)
        let stagedBlock = AgentBlock(id: AgentNodeID(rawValue: "host-staged-image")!, kind: .image,
            payload: .image(.init(attachment: staged.manifest.metadata)))
        let stagedEntry = AgentEntry(id: AgentNodeID(rawValue: "host-staged-entry")!, role: .user,
            provenance: .localNotice(reason: "image fixture"), lifecycle: .finished, blocks: [stagedBlock])
        let stagedDocument = AgentDocument(version: 1, entries: [stagedEntry])
        let cleaned = await supervisor.sharedTranscriptImages(for: agent, document: stagedDocument)[staged.manifest.id]
        try expect(cleaned != nil && cleaned?.range(of: Data("private-image-metadata".utf8)) == nil,
                   "the supervisor strips undisplayed image metadata before sharing")
        let otherAgent = AgentID(rawValue: UUID())
        try expect(await supervisor.sharedTranscriptImages(for: otherAgent, document: stagedDocument).isEmpty,
                   "an image owned by another agent is not shared")
        let imageLane = LaneSink(host: hostID)
        let imagePublisher = SharedAgentTranscriptPublisher(agent: agent, generation: 1, sink: imageLane,
            imageData: { _ in [imageA: imageBytes, imageB: imageBytes] }, document: { imageDocument })
        await imagePublisher.tick()
        let imageGuest = SharedAgentTranscriptView(frame: .zero)
        try expect(imageGuest.receive(try imageLane.read(.init(stream: Lane.mainStream, cursor: nil, waitMilliseconds: 0)))
                   && imageGuest.mirror.images.data(for: imageA) == imageBytes
                   && imageGuest.mirror.images.data(for: imageB) == imageBytes,
                   "a chunked image and its deduplicated alias round-trip through the lane")
        try expect(imageGuest.qaImageState(for: imageC) == .tooLargeToShare,
                   "the guest labels an over-limit image honestly")
        let thumbnail = await imageGuest.qaImageThumbnail(for: imageA)
        try expect(thumbnail?.attachmentID == imageA && (thumbnail?.pixelSize.width ?? 0) > 0,
                   "the guest image provider decodes the received image for the transcript")
        imageGuest.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
        imageGuest.wantsLayer = true
        canvas.addSubview(imageGuest)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            imageGuest.layer?.backgroundColor = SurfaceToken.tileBody.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor
            for _ in 0..<5 {
                canvas.layoutSubtreeIfNeeded(); imageGuest.surface.flushPendingVisualUpdate()
                imageGuest.surface.scrollTranscript(toY: 0)
                try await Task.sleep(for: .milliseconds(30))
            }
            if let drawn = imageGuest.surface as? AgentTranscriptCanvasView {
                try expect(drawn.imageSources[imageA] != nil && drawn.imageSources[imageB] != nil,
                           "the guest canvas draws both received image references")
            }
            guard let rep = imageGuest.bitmapImageRepForCachingDisplay(in: imageGuest.bounds) else { throw Failure(description: "no image bitmap") }
            imageGuest.cacheDisplay(in: imageGuest.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no image png") }
            let url = directory.appendingPathComponent("shared-images-\(appearance == .aqua ? "light" : "dark").png")
            try png.write(to: url); print("WROTE \(url.path)")
        }
        imageGuest.removeFromSuperview()
        window.appearance = NSAppearance(named: .aqua)
        let expectedChunks = SharedAgentTranscriptImages.chunks(imageBytes).count
        try expect(imagePublisher.frames == expectedChunks + 2, "the duplicate image sends its bytes only once")
        imageLane.log = nil
        var changedImageEntry = imageEntry; changedImageEntry.revision += 1
        imageDocument = AgentDocument(version: 2, entries: [changedImageEntry])
        await imagePublisher.tick(); await imagePublisher.tick()
        let rejoinedImageGuest = SharedAgentTranscriptView(frame: .zero)
        try expect(rejoinedImageGuest.receive(try imageLane.read(.init(stream: Lane.mainStream, cursor: nil, waitMilliseconds: 0)))
                   && rejoinedImageGuest.mirror.images.data(for: imageA) == imageBytes,
                   "a late joiner receives image chunks again after relay recovery")
        var invalidImageReceiver = SharedAgentTranscriptImages.Receiver()
        let validManifest = SharedAgentTranscriptImages.Manifest(attachment: imageA, data: imageBytes)
        try invalidImageReceiver.register(validManifest)
        var chunks = SharedAgentTranscriptImages.chunks(imageBytes)
        let first = chunks.removeFirst()
        var corrupted = first.bytes; corrupted[corrupted.startIndex] ^= 1
        try invalidImageReceiver.receive(.init(digest: first.digest, offset: first.offset, bytes: corrupted))
        var rejectedCorruption = false
        do { for chunk in chunks { try invalidImageReceiver.receive(chunk) } }
        catch { rejectedCorruption = true }
        try expect(rejectedCorruption && invalidImageReceiver.data(for: imageA) == nil,
                   "a corrupted image never becomes available")
        let oversizedImage = Data(repeating: 1, count: SharedAgentTranscriptImages.maxImageBytes + 1)
        var rejectedOversize = false
        do { try invalidImageReceiver.register(.init(attachment: imageB, data: oversizedImage)) }
        catch { rejectedOversize = true }
        try expect(rejectedOversize && SharedAgentTranscriptImages.chunks(oversizedImage).isEmpty,
                   "an over-limit image is not transferred")
        try expect(AgentDiffSummaryView.bodyMaxLines == 30 && AgentDiffSummaryView.maximumVisibleFiles == 8,
                   "the shared diff budget matches the host renderer's line and file limits")
        let hiddenToolChild = AgentBlock(id: AgentNodeID(rawValue: "hidden-tool-child")!, kind: .paragraph,
            payload: .paragraph([.text("undisplayed-tool-child-secret")]))
        let privateArgument = AgentBlock(id: AgentNodeID(rawValue: "private-argument")!, kind: .toolCall,
            payload: .toolCall(.init(name: "Visible tool", arguments: .object(["private": .string("undisplayed-argument-secret")]), status: .completed)),
            children: [hiddenToolChild])
        let argumentContainer = AgentBlock(id: AgentNodeID(rawValue: "private-container")!, kind: .quote,
            payload: .quote, children: [privateArgument])
        let safeArguments = SharedAgentTranscriptSafeBudget().fit(argumentContainer, limit: SharedAgentTranscriptWire.maxBlockBytes)
        let argumentWire = String(decoding: try SharedAgentTranscriptWire.encode(safeArguments), as: UTF8.self)
        try expect(!argumentWire.contains("undisplayed-argument-secret") && !argumentWire.contains("undisplayed-tool-child-secret"),
                   "opaque arguments and undrawn tool children stay off the wire")
        let hiddenOldPath = "/private/hidden-old-path.txt"
        let hiddenLine = "private-hidden-hunk-content"
        let diffLines = (0..<35).map { $0 == 34 ? "+" + hiddenLine : "+visible-\($0)" }.joined(separator: "\n")
        let sourceDiff = "diff --git a/old b/visible.txt\n--- " + hiddenOldPath + "\n+++ b/visible.txt\n@@ -1,1 +1,35 @@\n" + diffLines
        let files = (0..<9).map { AgentDiffFileSummary(displayName: $0 == 8 ? "private-hidden-ninth-file" : "visible-\($0)", addedLineCount: 1, removedLineCount: 0) }
        let rawDiff = AgentBlock(id: AgentNodeID(rawValue: "safe-diff")!, kind: .diff,
            payload: .diff(.init(text: sourceDiff, files: files)))
        let safeDiff = SharedAgentTranscriptSafeBudget().fit(rawDiff, limit: SharedAgentTranscriptWire.maxBlockBytes)
        let safeBytes = try SharedAgentTranscriptWire.encode(safeDiff)
        let safeText = String(decoding: safeBytes, as: UTF8.self)
        try expect(!safeText.contains(hiddenOldPath) && !safeText.contains(hiddenLine)
                   && !safeText.contains("private-hidden-ninth-file") && safeText.contains("visible-29"),
                   "diff budget sends visible lines while withholding undisplayed paths, names and hunks")
        guard case let .diff(safePayload) = safeDiff.payload else { throw Failure(description: "safe diff missing") }
        let shownDiffLines = GitDiffParser.parse(safePayload.text).files.flatMap(\.hunks).reduce(0) { $0 + $1.lines.count }
        try expect(shownDiffLines == 30, "diff budget keeps exactly the host's first 30 hunk lines")
        var presentedDiff = rawDiff
        if case var .diff(value) = presentedDiff.payload {
            value.presentedTotalLines = 35; presentedDiff.payload = .diff(value)
        }
        guard let diffPresentation = SharedAgentToolPresentation(presented: presentedDiff) else { throw Failure(description: "diff presentation missing") }
        let decodedDiffPresentation = try SharedAgentTranscriptWire.decode(SharedAgentToolPresentation.self,
            from: SharedAgentTranscriptWire.encode(diffPresentation))
        let renderedDiff = decodedDiffPresentation.applying(to: safeDiff)
        guard case let .diff(renderedPayload) = renderedDiff.payload else { throw Failure(description: "diff presentation kind") }
        let diffView = AgentDiffSummaryView(frame: .zero)
        diffView.frame = NSRect(x: 0, y: 0, width: 480, height: 1000)
        diffView.apply(blockID: renderedDiff.id, revision: renderedDiff.revision, payload: renderedPayload,
                       context: AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark))
        diffView.layoutSubtreeIfNeeded()
        try expect(!diffView.bodyOverflowLabel.isHidden && diffView.bodyOverflowLabel.stringValue == "+5 more lines"
                   && diffView.bodyTextView?.string.contains(hiddenLine) == false,
                   "the guest diff renderer preserves the host overflow count without hidden hunk text")
        let failedEntry = guest.transcriptView.mirror.document.entries.first { entry in
            if case let .providerItem(_, itemID) = entry.provenance { return itemID == "failed-1" }; return false
        }
        guard case let .toolCall(failedTool)? = failedEntry?.blocks.first?.payload else { throw Failure(description: "failed tool row missing") }
        try expect(failedTool.status == .failed, "the guest retains a failed tool state")
        let hostSurface = try surface(of: tile), guestSurface = guest.transcriptView.surface
        try expect(type(of: hostSurface) == type(of: guestSurface),
                   "the guest draws with the host tile's renderer (\(type(of: hostSurface)))")

        func compare(_ label: String) async throws {
            let source = supervisor.transcriptDocument(for: agent)?.entries ?? []
            let mirror = guest.transcriptView.qaMirrorDocument.entries
            let budget = SharedAgentTranscriptSafeBudget()
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
        func presented(_ surface: any AgentTranscriptSurface, id: AgentNodeID, expected: AgentBlock) -> AgentBlock? {
            if let canvas = surface as? AgentTranscriptCanvasView { return canvas.qaPresentedBlock(for: id) }
            guard let list = surface as? AgentTranscriptListView else { return nil }
            if case .diff = expected.payload, let diff = list.qaPresentedDiffPayload(for: id) {
                var block = expected; block.payload = .diff(diff); return block
            }
            return list.qaPresentedToolBlock(for: id)
        }
        let toolItemIDs = Set(["cmd-1", "edit-1"] + toolFixtures.map { $0.0 })
        let comparableIDs = Set((supervisor.transcriptDocument(for: agent)?.entries ?? []).filter { entry in
            guard case let .providerItem(_, itemID?) = entry.provenance else { return false }
            return toolItemIDs.contains(itemID)
        }.flatMap { $0.blocks.map(\.id) })
        try expect(comparableIDs.count == toolItemIDs.count && Set(headlessDetails.keys).isSuperset(of: comparableIDs),
                   "every tool fixture has retained presentation detail")
        for (id, expected) in headlessDetails where comparableIDs.contains(id) {
            let owner = presented(hostSurface, id: id, expected: expected)
            let remote = presented(guestSurface, id: id, expected: expected)
            guard let owner, let remote else { throw Failure(description: "presented row missing for \(id.rawValue)") }
            switch (expected.payload, owner.payload, remote.payload) {
            case let (.toolCall(_), .toolCall(host), .toolCall(guestTool)):
                try expect(host.name == guestTool.name && host.summary == guestTool.summary && host.status == guestTool.status
                    && host.presentedOutputText == guestTool.presentedOutputText && host.presentedShell == guestTool.presentedShell,
                    "owner and guest render the same tool detail for \(id.rawValue)")
            case let (.diff(_), .diff(host), .diff(guestDiff)):
                try expect(host.files == guestDiff.files && host.presentedFilesArePending == guestDiff.presentedFilesArePending,
                           "owner and guest render the same diff summary for \(id.rawValue)")
            default: throw Failure(description: "presented kind differs for \(id.rawValue)")
            }
        }
        let commandID = headlessDetails.first { _, block in
            guard case let .toolCall(tool) = block.payload else { return false }
            return tool.presentedOutputText == "hello from command"
        }!.key
        let renderedCommand: AgentBlock?
        if let canvas = guestSurface as? AgentTranscriptCanvasView { renderedCommand = canvas.qaPresentedBlock(for: commandID) }
        else if let list = guestSurface as? AgentTranscriptListView {
            renderedCommand = list.qaPresentedToolBlock(for: commandID)
        } else { renderedCommand = nil }
        guard case let .toolCall(command)? = renderedCommand?.payload else { throw Failure(description: "guest command row missing") }
        try expect(command.presentedOutputText == "hello from command", "the guest's expanded command uses the host's output")
        if let drawn = guestSurface as? AgentTranscriptCanvasView {
            drawn.qaReveal(blockID: commandID)
            guard let open = drawn.qaControls.first(where: { $0.blockID == commandID && $0.kind == "chevron.collapsed" }),
                  drawn.qaSendClick(at: open.center) else { throw Failure(description: "guest tool disclosure is not clickable") }
            try expect(drawn.qaIsExpanded(commandID) && drawn.qaLaidOutText.contains("hello from command"),
                       "expanding the guest command draws the output")
            guard let close = drawn.qaControls.first(where: { $0.blockID == commandID && $0.kind == "chevron.expanded" }),
                  drawn.qaSendClick(at: close.center) else { throw Failure(description: "guest tool disclosure cannot collapse") }
            try expect(!drawn.qaIsExpanded(commandID), "collapsing the guest command closes it")
        } else if let list = guestSurface as? AgentTranscriptListView {
            for _ in 0..<4 where !list.qaDisplayedRowIDsForChecks.contains(commandID) {
                for header in list.qaClusterHeaderIDsForChecks where list.qaDisclosureState(for: header) != true {
                    list.qaToggleClusterForChecks(header)
                }
            }
            guard list.qaRevealToolRowForChecks(commandID) else { throw Failure(description: "list tool row is folded") }
            try await paint()
            guard let row = list.qaOnScreenToolRowForChecks(for: commandID) else { throw Failure(description: "list tool row is offscreen") }
            let initial = row.view.isExpanded
            guard list.qaPerformToolDisclosureClick(for: commandID) else { throw Failure(description: "list tool disclosure is not clickable") }
            try expect(list.qaDisclosureState(for: commandID) == !initial, "the list tool disclosure toggles")
            guard list.qaPerformToolDisclosureClick(for: commandID) else { throw Failure(description: "list tool disclosure cannot toggle back") }
            try expect(list.qaDisclosureState(for: commandID) == initial, "the list tool disclosure toggles back")
        }
        let kinds = Set(guest.transcriptView.qaMirrorDocument.entries.flatMap(\.blocks).map(\.kind.rawValue))
        let roles = Set(guest.transcriptView.qaMirrorDocument.entries.map(\.role.rawValue))
        try expect(["tool-call", "agent-reference", "fenced-code", "list", "diff"].allSatisfy(kinds.contains)
                   && ["user", "assistant"].allSatisfy(roles.contains),
                   "the guest holds the prompt, tool calls, the file change, the subagent, markup and code (\(kinds.sorted()), \(roles.sorted()))")
        if let drawn = guestSurface as? AgentTranscriptCanvasView {
            let laid = drawn.qaLaidOutText
            try expect(laid.contains("CheckoutState") || laid.contains("Seven states"), "the guest lays out the host's words")
        }
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
        hostSurface.scrollTranscript(toY: 0)
        guestSurface.scrollTranscript(toY: 0)
        try await paint()
        if let hostList = hostSurface as? AgentTranscriptListView,
           let guestList = guestSurface as? AgentTranscriptListView {
            let hostScroll = hostList.qaScrollViewForChecks
            let guestScroll = guestList.qaScrollViewForChecks
            print("LIST VIEWPORT host items=\(hostList.qaVisibleItemCountForChecks) snapshot=\(hostList.qaSnapshotItemCountForChecks) rows=\(hostList.qaDisplayedRowIDsForChecks.count) error=\(String(describing: hostList.qaRenderingErrorDescription)) frame=\(hostList.frame) visible=\(hostList.visibleRect) clip=\(hostScroll.contentView.bounds) document=\(String(describing: hostScroll.documentView?.frame)) docVisible=\(String(describing: hostScroll.documentView?.visibleRect)); guest items=\(guestList.qaVisibleItemCountForChecks) snapshot=\(guestList.qaSnapshotItemCountForChecks) rows=\(guestList.qaDisplayedRowIDsForChecks.count) error=\(String(describing: guestList.qaRenderingErrorDescription)) frame=\(guestList.frame) visible=\(guestList.visibleRect) clip=\(guestScroll.contentView.bounds) document=\(String(describing: guestScroll.documentView?.frame)) docVisible=\(String(describing: guestScroll.documentView?.visibleRect))")
            print("LIST COLLECTION host \(hostList.qaCollectionDiagnosticsForChecks); guest \(guestList.qaCollectionDiagnosticsForChecks)")
            try expect(hostList.qaVisibleItemCountForChecks > 0, "the host list viewport actually renders transcript rows")
        }
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
        // A tile opened while a command is running must hear the supervisor's
        // later detail refresh even though it missed that command's start event.
        deliver(.turnStarted(threadId: thread, turnId: "late-tool-turn"))
        deliver(.itemStarted(threadId: thread, itemId: "late-tool", kind: .commandExecution, title: "bash"))
        supervisor.qaObserveSharedTranscript(.toolDetail(itemId: "late-tool", detail: .init(phase: .started,
            toolName: "bash", fields: [(key: "command", value: "echo late")], observedAt: Date())), for: agent)
        for _ in 0..<20 { await Task.yield() }
        let lateTile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Late host",
            frame: .init(x: 0, y: 0, width: 520, height: 760), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: .init()), threadId: thread)
        lateTile.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
        canvas.addSubview(lateTile)
        lateTile.attach(agentID: agent, supervisor: supervisor)
        canvas.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        lateTile.qaFlushStreamingMarkupForChecks(final: true)
        let lateID = supervisor.transcriptDocument(for: agent)?.entries.first { entry in
            if case let .providerItem(_, itemID) = entry.provenance { return itemID == "late-tool" }
            return false
        }?.blocks.first?.id
        guard let lateID else { throw Failure(description: "late tool row missing") }
        for _ in 0..<200 {
            if supervisor.sharedTranscriptToolBlocks(for: agent)[lateID] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        let running = guest.transcriptView.mirror.document.entries.flatMap(\.blocks).first { $0.id == lateID }
        guard case let .toolCall(runningTool)? = running?.payload else { throw Failure(description: "guest running tool missing") }
        try expect(runningTool.status == .inProgress, "the guest sees a tool while it is running")
        supervisor.qaObserveSharedTranscript(.toolDetail(itemId: "late-tool", detail: .init(phase: .ended,
            outputPreview: "late output arrived", exitCode: 0, observedAt: Date())), for: agent)
        deliver(.itemCompleted(threadId: thread, itemId: "late-tool", kind: .commandExecution, status: .completed))
        var lateOutput: String?
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            lateTile.qaFlushStreamingMarkupForChecks(final: true)
            lateTile.layoutSubtreeIfNeeded()
            lateTile.qaTranscriptSurface?.flushPendingVisualUpdate()
            if case let .toolCall(tool)? = lateTile.qaPresentedToolBlock(for: lateID)?.payload {
                lateOutput = tool.presentedOutputText
            }
            if lateOutput == "late output arrived" { break }
        }
        try expect(lateOutput == "late output arrived", "a late-attached host tile receives a running tool's completion detail")
        await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        let completed = guest.transcriptView.mirror.document.entries.flatMap(\.blocks).first { $0.id == lateID }
        guard let completed, case let .toolCall(completedTool) = completed.payload,
              let detail = guest.transcriptView.mirror.toolDetails[lateID],
              case let .toolCall(renderedTool) = detail.applying(to: completed).payload else {
            throw Failure(description: "guest completed tool missing")
        }
        try expect(completedTool.status == .completed && renderedTool.presentedOutputText == "late output arrived",
                   "the guest receives the completed status and output after the running state")
        lateTile.detach(); lateTile.removeFromSuperview()
        // A call can first be visible, then be replaced by a child chip. The
        // presentation op must disappear when the host folds that call away.
        deliver(.turnStarted(threadId: thread, turnId: "fold-transition"))
        deliver(.itemStarted(threadId: thread, itemId: "transient-delegation", kind: .subagent, title: "visible before child"))
        let foldedID = supervisor.transcriptDocument(for: agent)?.entries.first { entry in
            if case let .providerItem(_, itemID) = entry.provenance { return itemID == "transient-delegation" }
            return false
        }?.blocks.first?.id
        guard let foldedID else { throw Failure(description: "delegation source row missing") }
        await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        try expect(guest.transcriptView.mirror.toolDetails[foldedID] != nil, "a visible delegation has its presentation")
        deliver(.childAgentSpawned(threadId: thread, childAgentID: UUID(), parentAgentID: agent.rawValue,
            displayName: "Child", sourceItemID: "transient-delegation", provider: "pi", spawnedAt: Date()))
        await publisher.tick()
        _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
        try expect(guest.transcriptView.mirror.toolDetails[foldedID] == nil,
                   "a newly folded delegation removes its presentation from the guest")
        let stableLane = LaneSink(host: hostID)
        let stableDocument = AgentDocument(version: 1, entries: [])
        var detailReads = 0
        var detailRevision: UInt64 = 1
        let stablePublisher = SharedAgentTranscriptPublisher(agent: agent, generation: 1, sink: stableLane,
            details: { detailReads += 1; return [:] }, detailRevision: { detailRevision }, document: { stableDocument })
        await stablePublisher.tick()
        for _ in 0..<20 { await stablePublisher.tick() }
        try expect(detailReads == 1, "unchanged ticks do not rescan transcript tool detail")
        detailRevision += 1
        await stablePublisher.tick()
        try expect(detailReads == 2, "a detail revision triggers a fresh read without a document change")
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
