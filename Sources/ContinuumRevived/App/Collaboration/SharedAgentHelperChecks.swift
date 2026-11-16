import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-helpers-check [stills directory]`: a shared lead's helpers on
/// the guest read as they do on the host. Production host session
/// (`SharedAreaAgentProjectionHost` and its transcript publishers), the relay's
/// per-stream `Log`, and the guest's `SharedAgentLiveView` polling the lane
/// itself; the host chip's own status seam (`ManagedAgentTileNSView`) is the
/// reference. A lead with two running helpers; one finishes, then the other.
@MainActor
enum SharedAgentHelperChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    typealias Lane = Collaboration.AgentTranscript
    typealias Wire = SharedAgentTranscriptWire

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS shared agent helpers: \(label)")
    }

    /// The relay's transcript lane: one `Log` per stream, as the service keys them.
    final class StreamsSink: SharedAgentTranscriptSink {
        let host: SharedArea.ID<SharedArea.Host>
        var logs: [String: Lane.Log] = [:]
        var bodies: [Data] = []
        init(host: SharedArea.ID<SharedArea.Host>) { self.host = host }
        func publish(stream: String, checkpoint: Lane.Checkpoint?, frames: [Lane.Frame]) async throws {
            bodies += [checkpoint?.body].compactMap { $0 } + frames.map(\.body)
            do { logs[stream] = try Lane.Log.publish(.init(epoch: 1, host: host, stream: stream, checkpoint: checkpoint, frames: frames),
                                                     onto: logs[stream]) }
            catch .checkpointRequired { throw SharedAgentTranscriptRefusal.checkpointRequired }
            catch .stale { throw SharedAgentTranscriptRefusal.superseded }
        }
        func read(_ request: Lane.ReadRequest) throws -> Lane.Read {
            guard let log = logs[request.stream] else { throw Failure(description: "unavailable") }
            // The bytes a guest decodes.
            let read = log.read(after: request.cursor)
            return try JSONDecoder().decode(Lane.Read.self, from: JSONEncoder().encode(read))
        }
    }

    static func run(directory: URL) async throws {
        let root = try SharedAreaCheckRig.root("shared-agent-helpers")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Characters on, the built-in set, in a suite and themes folder of its own.
        let controller = AgentCharacterController.shared
        let suite = "ArraySharedAgentHelpersChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.importsDirectory = root.appendingPathComponent("characters", isDirectory: true)
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        guard let set = controller.theme, set.characters.count >= 6 else { throw Failure(description: "the built-in set did not load") }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID(), start = Date()
        func record(_ name: String, parent: AgentID?, observed: Bool = false, color: String? = nil, at offset: TimeInterval,
                    ordinal: ((UUID) -> Int)? = nil, pick: String? = nil) throws -> AgentID {
            let id = AgentID(rawValue: UUID())
            var value = AgentRecord(id: id, displayName: name, harness: .claudeCode, model: "scripted/helpers", thinking: "none",
                                    cwd: root.path, projectId: project, createdAt: start.addingTimeInterval(offset), lastActivityAt: start)
            value.parentAgentID = parent
            value.parentRelativeOrdinal = ordinal?(id.rawValue)
            value.characterName = pick
            if observed { value.capabilities = .observedReadOnly }
            value.identityColor = color
            try store.upsert(value)
            return id
        }
        let lead = try record("Checkout lead", parent: nil, at: 0)
        // Scout's delegation slot is one its id's hash would not pick, so a guest
        // that re-derived instead of adopting the host's fact draws another duck.
        let scout = try record("Scout the relay", parent: lead, color: "teal", at: 1, ordinal: { id in
            (AgentCharacterConfig.characterIndex(for: id, count: set.characters.count) + 1) % set.characters.count + 1
        })
        let reviewer = try record("Review the diff", parent: lead, observed: true, at: 2, ordinal: { _ in 2 },
                                  pick: set.characters[4].name)
        let unrelated = try record("Someone else's agent", parent: nil, at: 3)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        supervisor.publishCharacterPacks()
        func deliver(_ event: AgentRuntimeEvent, _ id: AgentID) { supervisor.qaDeliver(event, to: id) }
        func thread(_ id: AgentID) -> String { AgentSupervisor.threadId(for: id) }
        func settle() async { for _ in 0..<20 { await Task.yield() } }

        // The lead starts a turn and spawns both helpers; each helper works.
        deliver(.turnStarted(threadId: thread(lead), turnId: "lead-1"), lead)
        deliver(.contentDelta(threadId: thread(lead), turnId: "lead-1", streamKind: .assistant, delta: "Splitting this in two."), lead)
        for (child, name) in [(scout, "Scout the relay"), (reviewer, "Review the diff")] {
            deliver(.childAgentSpawned(threadId: thread(lead), childAgentID: child.rawValue, parentAgentID: lead.rawValue,
                                       displayName: name, sourceItemID: "toolu-\(name)", provider: "claude", spawnedAt: start), lead)
            deliver(.turnStarted(threadId: thread(child), turnId: "child-1"), child)
            deliver(.contentDelta(threadId: thread(child), turnId: "child-1", streamKind: .assistant,
                                  delta: "\(name): reading the relay routes and the lane log."), child)
        }
        deliver(.turnStarted(threadId: thread(unrelated), turnId: "other"), unrelated)
        await settle()

        // The production host session.
        let hostID = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
        let lane = StreamsSink(host: hostID)
        let projectionHost = SharedAreaAgentProjectionHost(supervisor: supervisor, directory: root,
                                                           makeSink: { _ in SharedAgentTranscriptParityChecks.ProjectionSink() },
                                                           makeTranscriptSink: { _, _ in lane })
        defer { projectionHost.stop() }
        projectionHost.sync([.init(object: object, binding: .init(), host: hostID, projectID: project, agentID: lead)])
        guard let main = projectionHost.transcripts[object] else { throw Failure(description: "no transcript publisher") }
        main.stop()
        func publishAll() async {
            await settle()
            await main.tick()
            for publisher in (projectionHost.helperTranscripts[object] ?? [:]).values { publisher.stop(); await publisher.tick() }
        }
        await publishAll()

        // The guest: the live view's own lane polls.
        let me = Collaboration.Identity(person: .init(), device: UUID()), owner = Collaboration.Identity(person: .init(), device: UUID())
        let item = SharedArea.Item(id: object, kind: .agentObservation, source: .init(owner: owner.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 400, height: 500), z: 1))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (owner, .owner)])
        let area = try SharedAreaCheckRig.controller(root: root.appendingPathComponent("guest"), identity: me, label: "Sam",
                                                           authority: authority, seed: (document, .editor))
        let hostCharacters = ManagedAgentTileNSView.agentCharacterSource(supervisor)
        let picks = [scout: nil as String?, reviewer: set.characters[4].name]
        let hostAssignments = [scout, reviewer].map { controller.assignment(for: $0.rawValue, name: picks[$0] ?? nil) }
        // A guest Mac holds none of the host's records, so no packs either.
        controller.setPacks([:])
        let guest = SharedAgentLiveView(controller: area, read: { _, _ in throw Failure(description: "rows lane not used") },
                                        readTranscript: { _, request in try lane.read(request) })
        guest.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        guest.show(object: object, in: document)
        guest.stop()
        func read() async { _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0) }
        await read()

        let hostChip = ManagedAgentTileNSView.agentReferenceStatusSource(supervisor)
        let guestChip = guest.transcriptView.agentStatus
        func compare(_ label: String) throws {
            let ids = [scout, reviewer].map(\.rawValue)
            let host = ids.map { hostChip.current($0) }, shown = ids.map { guestChip.current($0) }
            try expect(host == shown && host.allSatisfy { $0 != nil },
                       "\(label): every helper chip in the guest's transcript reads the host chip's status (host \(host.map { $0!.rawValue }), guest \(shown.map { $0?.rawValue ?? "none" }))")
            let hostPose = ids.map { hostCharacters.current($0) }, guestPose = ids.map { guest.transcriptView.agentCharacters.current($0) }
            try expect(hostPose == guestPose && hostPose.allSatisfy { $0 != nil },
                       "\(label): every helper chip's character input on the guest is the host chip's (pose and pick)")
            let drawn = ids.map { controller.assignment(for: $0, name: picks[AgentID(rawValue: $0)] ?? nil) }
            try expect(drawn == hostAssignments,
                       "\(label): the guest draws each helper as the host does (host \(hostAssignments.map { "\($0!.kind.rawValue) \($0!.index)" }), guest \(drawn.map { $0.map { "\($0.kind.rawValue) \($0.index)" } ?? "none" }))")
        }

        let roster = guest.helpers
        try expect(guest.transcriptLive && roster.known && roster.helpers.map(\.id) == [scout.rawValue, reviewer.rawValue],
                   "the guest's roster holds both helpers in spawn order, and not an unrelated agent")
        let chips = guest.transcriptView.qaMirrorDocument.entries.flatMap(\.blocks).compactMap { block -> AgentReferencePayload? in
            if case .agentReference(let payload) = block.payload { return payload } else { return nil }
        }
        let hostChips = (supervisor.transcriptDocument(for: lead)?.entries ?? []).flatMap(\.blocks).compactMap { block -> AgentReferencePayload? in
            if case .agentReference(let payload) = block.payload { return payload } else { return nil }
        }
        try expect(chips.count == 2 && chips == hostChips && Set(chips.map(\.agentID)) == Set(roster.helpers.map(\.id)),
                   "the guest's transcript holds the host's two subagent chips, names included, keyed by the roster's ids")
        try expect(roster.helpers.map { $0.character?.theme } == [set.id, set.id]
                   && roster.helpers.map { $0.character?.assignment } == hostAssignments
                   && roster.helpers.map { $0.character?.pick } == [nil, set.characters[4].name],
                   "each helper's character names the host's set, its pick and the host's assignment")
        try expect(roster.helpers.map(\.name) == ["Scout the relay", "Review the diff"]
                   && roster.helpers.map(\.origin) == [.delegated, .provider] && roster.helpers.allSatisfy { $0.parent == nil },
                   "each helper's name is the host's, with its origin and nesting")
        try compare("both running")
        try expect(roster.rollup.working == 2 && roster.rollup.anyWorking, "the lead's rollup on the guest counts two working helpers")
        try expect(guest.transcriptView.agentMessageSenders.current(scout.rawValue)?.identityColorName == "teal",
                   "a helper's message card on the guest takes its identity colour")

        // A chip's reveal opens that helper's own stream, drawn by the same renderer.
        guard let reveal = guest.transcriptView.onRevealAgent else { throw Failure(description: "the guest's chips reveal nothing") }
        reveal(scout.rawValue, lead.rawValue)
        guest.qaCancelHelperPolling()   // the check polls the helper's stream itself
        _ = await guest.pollHelper(object, scout.rawValue, ticket: guest.qaTicket, waitMilliseconds: 0)
        let budget = SharedAgentTranscriptTruncatingBudget()
        func helperParity(_ label: String) throws {
            let hostEntries = (supervisor.transcriptDocument(for: scout)?.entries ?? []).map { budget.fit($0) }
            let shown = guest.helperView.qaMirrorDocument.entries
            try expect(guest.openedHelper == scout.rawValue && !shown.isEmpty && shown == hostEntries
                       && type(of: guest.helperView.surface) == type(of: guest.transcriptView.surface),
                       "\(label): the helper's stream on the guest is the helper's own transcript, entry for entry, with the same renderer (\(shown.count) entries)")
        }
        try helperParity("opened")
        try expect(guest.helperTitleText == "Scout the relay", "the opened helper is titled with its host name")

        // One helper finishes, and its stream follows.
        deliver(.contentDelta(threadId: thread(reviewer), turnId: "child-1", streamKind: .assistant, delta: " Looks right."), reviewer)
        deliver(.turnCompleted(threadId: thread(reviewer), turnId: "child-1", outcome: .completed, errorMessage: nil), reviewer)
        deliver(.contentDelta(threadId: thread(scout), turnId: "child-1", streamKind: .assistant, delta: " Found the route."), scout)
        await publishAll(); await read()
        _ = await guest.pollHelper(object, scout.rawValue, ticket: guest.qaTicket, waitMilliseconds: 0)
        try compare("one finished")
        try expect(hostChip.current(reviewer.rawValue) == .ready && roster.rollup.working == 1 && roster.rollup.anyWorking,
                   "after one helper finishes the guest's lead still shows the working glyph, with one working")
        try helperParity("streaming")

        // Stills: the lead with its chips, then a helper opened, light and dark.
        let window = NSWindow(contentRect: guest.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let backdrop = NSView(frame: guest.frame)
        backdrop.wantsLayer = true
        backdrop.addSubview(guest)
        window.contentView = backdrop
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        func still(_ name: String) async throws {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                backdrop.layer?.backgroundColor = SurfaceToken.tileBody.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor
                for _ in 0..<3 {
                    guest.layoutSubtreeIfNeeded()
                    guest.transcriptView.surface.flushPendingVisualUpdate(); guest.helperView.surface.flushPendingVisualUpdate()
                    guest.layoutSubtreeIfNeeded(); guest.displayIfNeeded(); CATransaction.flush()
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { throw Failure(description: "no bitmap") }
                backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
                let url = directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                try png.write(to: url)
                print("WROTE \(url.path)")
            }
        }
        try await still("helper-open")
        guest.qaPressHelperBack()
        try expect(guest.openedHelper == nil && !guest.transcriptView.isHidden && guest.helperView.isHidden,
                   "Back returns to the shared agent's own transcript")
        try await still("lead-chips")

        // The last helper ends: the glyph clears on the guest as on the host.
        deliver(.turnCompleted(threadId: thread(scout), turnId: "child-1", outcome: .failed, errorMessage: "PRIVATE-CHILD-ERROR"), scout)
        await publishAll(); await read()
        try compare("all finished")
        try expect(roster.rollup.working == 0 && roster.rollup.failed == 1 && !roster.rollup.anyWorking,
                   "with no helper working the guest's lead drops the working glyph and counts the failure")

        // A late joiner starts from the checkpoint, roster included.
        let late = SharedAgentLiveView(controller: area, read: { _, _ in throw Failure(description: "rows lane not used") },
                                       readTranscript: { _, request in try lane.read(request) })
        late.show(object: object, in: document); late.stop()
        _ = await late.pollTranscript(object, ticket: late.qaTicket, waitMilliseconds: 0)
        try expect(late.helpers.helpers == roster.helpers, "a late joiner holds the same roster")

        // Nothing private crosses in the roster, and an older guest skips it.
        let roster0 = String(decoding: try Wire.encode(Wire.Patch(ops: [.helpers(roster.helpers)])), as: UTF8.self)
        let leaked = ["PRIVATE-CHILD-ERROR", "toolu-", "Someone else", root.path].filter { roster0.contains($0) }
        try expect(leaked.isEmpty, "the roster carries no child error text, provider item id, unrelated agent or path (leaked: \(leaked))")
        try expect(roster0.contains("\"op\":\"helpers\""), "the roster travels as a helpers op")
        let older = try JSONDecoder().decode(Wire.Patch.self, from: Data(roster0.replacingOccurrences(of: "\"op\":\"helpers\"", with: "\"op\":\"helpers-v9\"").utf8))
        var mirror = Wire.Mirror()
        _ = try mirror.apply(older)
        try expect(older.ops.allSatisfy { if case .unknown = $0 { return true } else { return false } } && mirror.helpers == nil,
                   "an op a guest does not know is decoded and skipped, as an older guest skips the roster")
    }
}
