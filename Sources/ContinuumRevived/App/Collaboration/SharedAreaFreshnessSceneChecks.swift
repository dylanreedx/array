import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// COL-14 through scenes mounted by the production entry: per-agent "changed
/// since sent", refused resends, relaunch, a rebind and excerpt posts. Receipts
/// come from the production `SharedAgentHandoffController` over a scripted host;
/// the real HTTP receipt path is witnessed in ContinuumRevivedCollaborationChecks.
@MainActor
enum SharedAreaFreshnessSceneChecks {
    struct Failure: Error { let message: String }

    static func run(mount: SharedAreaSceneChecks.Mount, executorCount: @MainActor () -> Int) async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).appendingPathComponent("array-freshness-scene-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        func agent() -> SharedArea.Item { .init(id: .init(), kind: .agentObservation, source: .init(owner: a.person, host: host, binding: .init())) }
        let first = agent(), second = agent()
        let agreement = SharedArea.Item(id: .init(), kind: .agreement), discussion = SharedArea.Item(id: .init(), kind: .discussion)
        let artifact = SharedArea.Item(id: .init(), kind: .artifact)
        let rev1 = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.person, text: "Revision 1: parser only.")
        var document = SharedArea.Document()
        func rect(_ x: Double) -> SharedArea.Rect { .init(x: x, y: 40, width: 260, height: 180) }
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(first, .init(id: .init(), object: first.id, rect: rect(0))), .admit(second, .init(id: .init(), object: second.id, rect: rect(280))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: rect(560))), .admit(discussion, .init(id: .init(), object: discussion.id, rect: rect(840))),
            .admit(artifact, .init(id: .init(), object: artifact.id, rect: rect(1120))), .context(rev1)]))
        let authority = Authority(document: document, owner: a.person, member: b.person)
        let script = HostScript(authority: authority, owner: a, generations: [first.id: UUID(), second.id: UUID()])
        let executorsBefore = executorCount()

        var hostA = NSView(frame: .init(x: 0, y: 0, width: 1100, height: 760))
        var modelA = try controller(root: root.appendingPathComponent("a"), identity: a, document: document, authority: authority)
        var sceneA = try mount(modelA, a.person, hostA)
        var handoffA = try SharedAgentHandoffController(identity: a, transport: script, directory: root.appendingPathComponent("a-handoff"))
        // Production line from the hub's area open.
        sceneA.agentFreshness = try SharedAgentFreshnessModel(handoff: handoffA)
        sceneA.agentFreshness?.stopWatchingLedger(); sceneA.agentFreshness?.startWatchingLedger(every: .milliseconds(30), identityEvery: 100_000)
        /// Stands in for the client's receipt hook: a separate ledger
        /// connection at the path the scene's model reads.
        let hook = try SharedAgentFreshnessLedger(directory: SharedAgentFreshnessModel.ledgerDirectory(areaDirectory: handoffA.areaDirectory))
        await modelA.open()
        try expect(modelA.status == .connected, "the owner's mounted scene connects")

        func panel(_ object: SharedArea.ID<SharedArea.Object>) throws -> SharedAreaAgentFreshnessView {
            try sceneA.selectObject(object); hostA.layoutSubtreeIfNeeded(); return sceneA.freshnessPanel
        }
        func publish(_ text: String) async throws -> SharedArea.Context {
            try sceneA.selectObject(agreement.id)
            sceneA.setDraftText(text)
            await sceneA.submitDraft()
            guard let head = modelA.document?.currentRevision(of: agreement.id), head.text == text else { throw Failure(message: "revision not saved: \(text)") }
            return head
        }
        func send(_ text: String, to object: SharedArea.Item, context: SharedArea.Context, outcome: Collaboration.AgentDispatchPhase) async throws -> Collaboration.AgentDispatchReceipt {
            await handoffA.refresh(object: object.id)
            await handoffA.send(text: text, context: context.id)
            guard let queued = handoffA.receipt, queued.command.context == context else { throw Failure(message: "no receipt for \(text)") }
            try hook.record(queued)
            await script.settle(queued.command.id, phase: outcome)
            await handoffA.refresh(object: object.id)
            guard let settled = handoffA.receipt, settled.phase == outcome else { throw Failure(message: "no \(outcome) receipt for \(text)") }
            try hook.record(settled)
            return settled
        }

        // 1. Revision 2 to the first agent; queued is not received.
        let firstPanel = try panel(first.id)
        try await eventually("the first agent's host session is confirmed") { firstPanel.statusText == "No accepted revision recorded on this device" }
        try expect(!firstPanel.isHidden && firstPanel.frame.height > 0 && firstPanel.caveatText.contains("Not a record that the agent read or followed it")
            && firstPanel.caveatFits,
            "selecting an agent shows its agreement context with the host-acceptance caveat")
        let rev2 = try await publish("Revision 2: parser and tests.")
        _ = try panel(first.id)
        await handoffA.refresh(object: first.id)
        await handoffA.send(text: "Do the parser change.", context: rev2.id)
        guard let queued = handoffA.receipt else { throw Failure(message: "first send produced no receipt") }
        try hook.record(queued)
        try await eventually("a queued send shows as waiting") { firstPanel.noticeText == "Revision 2 is waiting for the host to accept it." }
        try expect(firstPanel.statusText == "No accepted revision recorded on this device", "a queued delivery is never shown as received")
        await script.settle(queued.command.id, phase: .accepted)
        await handoffA.refresh(object: first.id)
        try hook.record(handoffA.receipt!)
        try await eventually("host acceptance becomes the baseline") { firstPanel.statusText == "Last accepted revision 2 · Current" && firstPanel.noticeText.isEmpty }
        try expect(true, "the mounted panel shows revision 2 accepted by the first agent's host")

        // 2. Revision 3 to the second agent only.
        let rev3 = try await publish("Revision 3: parser, tests and errors.")
        _ = try await send("Do the error type.", to: second, context: rev3, outcome: .accepted)
        let secondPanel = try panel(second.id)
        try await eventually("second agent current at 3") { secondPanel.statusText == "Last accepted revision 3 · Current" }
        _ = try panel(first.id)
        try await eventually("first agent stale at 2") { firstPanel.statusText == "Last accepted revision 2 · Current revision 3 · Changed since sent" }
        try expect(true, "two agents in one scene show different accepted revisions")

        // 3. An edit marks both stale; nothing is sent.
        let sendsBeforeEdit = await script.sends
        let rev4 = try await publish("Revision 4: parser, tests, errors and docs.")
        _ = try panel(first.id)
        try await eventually("first stale against 4") { firstPanel.statusText == "Last accepted revision 2 · Current revision 4 · Changed since sent" }
        _ = try panel(second.id)
        try await eventually("second stale against 4") { secondPanel.statusText == "Last accepted revision 3 · Current revision 4 · Changed since sent" }
        let sendsAfterEdit = await script.sends
        try expect(sendsAfterEdit == sendsBeforeEdit && executorCount() == executorsBefore,
            "editing the agreement marks each agent stale and sends nothing")
        let frozen = try hook.frozenCommand(queued.command.id)
        try expect(frozen?.context == rev2 && frozen?.promptText.contains(rev2.text) == true && frozen?.promptText.contains(rev4.text) == false,
            "the first agent's accepted input still carries revision 2")

        // 4. A refused resend leaves the baseline at revision 2.
        _ = try await send("Pick up revision 4.", to: first, context: rev4, outcome: .refused)
        _ = try panel(first.id)
        try await eventually("refusal reported") { firstPanel.noticeText == "Revision 4 was refused by the host and was not delivered." }
        try expect(firstPanel.statusText == "Last accepted revision 2 · Current revision 4 · Changed since sent",
            "a refused resend is reported without advancing the baseline")

        // 5. Excerpts in discussion: exact source, honest availability.
        let artifactRevision = UUID()
        let quoted = Collaboration.ResultExcerpt(area: document.id, capturedBy: a.person,
            source: .init(incarnation: .init(object: second.id, hostGeneration: await script.generation(second.id)!), host: host, turn: "turn-7",
                          position: .init(generation: 1, sequence: 42), command: nil, artifact: .init(object: artifact.id, revision: artifactRevision, contentDigest: String(repeating: "c", count: 64))),
            text: "Error type added; tests pass.")
        guard case .accepted = await sceneA.shareResultExcerpt(quoted, into: discussion.id, note: "My agent's result.") else {
            throw Failure(message: "owner's excerpt post was not accepted")
        }
        try expect(modelA.document?.posts.last?.excerpt == quoted, "the production controller commits the frozen excerpt unchanged")
        try sceneA.selectObject(discussion.id)
        let source = "Turn turn-7 · event 42 · host \(short(host.rawValue)) · session \(short(quoted.source.incarnation.hostGeneration)) · artifact revision \(short(artifactRevision)) (cccccccccccc)"
        try await eventually("excerpt rendered") { sceneA.selectedEntryText.contains("“Error type added; tests pass.”") }
        try expect(sceneA.selectedEntryText.hasPrefix("My agent's result.") && sceneA.selectedEntryText.contains(source)
            && sceneA.selectedEntryText.contains("The artifact's latest revision has not been checked."),
            "the discussion shows the quote, its exact turn, host, session and artifact revision, and says the artifact was not checked")

        // The teammate's scene: replay, and the export rule.
        let hostB = NSView(frame: .init(x: 0, y: 0, width: 1100, height: 760))
        let modelB = try controller(root: root.appendingPathComponent("b"), identity: b, document: document, authority: authority)
        let sceneB = try mount(modelB, b.person, hostB)
        let handoffB = try SharedAgentHandoffController(identity: b, transport: HostScript(authority: authority, owner: b, generations: await script.generationMap),
            directory: root.appendingPathComponent("b-handoff"))
        sceneB.agentFreshness = try SharedAgentFreshnessModel(handoff: handoffB)
        await modelB.open()
        try sceneB.selectObject(discussion.id)
        try await eventually("teammate sees the quote linked to the agent's session") {
            sceneB.selectedEntryText.contains("“Error type added; tests pass.”") && sceneB.selectedEntryText.contains(source)
        }
        try sceneB.selectObject(first.id); hostB.layoutSubtreeIfNeeded()
        try await eventually("teammate panel is device-scoped") { sceneB.freshnessPanel.statusText == "No accepted revision recorded on this device" }
        try expect(true, "a teammate who cannot read receipts is told nothing was recorded on this device, not that nothing was sent")
        let foreign = Collaboration.ResultExcerpt(area: document.id, capturedBy: b.person,
            source: .init(incarnation: quoted.source.incarnation, host: host, turn: "turn-7"), text: "Error type added; tests pass.")
        let postsBefore = modelB.document?.posts.count
        guard case .rejected = await sceneB.shareResultExcerpt(foreign, into: discussion.id, note: "Quoting your agent.") else {
            throw Failure(message: "teammate exported another person's agent result")
        }
        try expect(modelB.document?.posts.count == postsBefore, "a teammate cannot share a result from an agent they do not own")
        sceneB.unmount(); await modelB.close()

        // 6. Relaunch: scene, controller, handoff client and model rebuilt from disk.
        sceneA.unmount(); await modelA.close()
        hostA = NSView(frame: .init(x: 0, y: 0, width: 1100, height: 760))
        modelA = try controller(root: root.appendingPathComponent("a"), identity: a, document: document, authority: authority)
        sceneA = try mount(modelA, a.person, hostA)
        handoffA = try SharedAgentHandoffController(identity: a, transport: script, directory: root.appendingPathComponent("a-handoff"))
        sceneA.agentFreshness = try SharedAgentFreshnessModel(handoff: handoffA)
        await modelA.open()
        let relaunched = try panel(first.id)
        try await eventually("relaunched first agent") { relaunched.statusText == "Last accepted revision 2 · Current revision 4 · Changed since sent" }
        try expect(relaunched.noticeText == "Revision 4 was refused by the host and was not delivered.", "the refused resend is still reported after relaunch")
        _ = try panel(second.id)
        try await eventually("relaunched second agent") { sceneA.freshnessPanel.statusText == "Last accepted revision 3 · Current revision 4 · Changed since sent" }
        let sendsAfterRelaunch = await script.sends
        try expect(sendsAfterRelaunch == sendsAfterEdit + 1, "relaunch restores every marker and sends nothing")

        // 7. Rebinding the second agent: no inherited baseline, quote labelled.
        await script.rebind(second.id)
        try sceneA.selectObject(discussion.id); sceneA.setDraftText("Rebound the second agent."); await sceneA.submitDraft()
        _ = try panel(second.id)
        try await eventually("rebound agent has no baseline") { sceneA.freshnessPanel.statusText == "No accepted revision recorded on this device" }
        try sceneA.selectObject(discussion.id)
        do {
            // The quote is the earlier of two posts; read it through the same presentation the reader uses.
            let post = modelA.document!.posts.first(where: { $0.excerpt != nil })!
            try await eventually("rebound quote is labelled replaced") {
                SharedAreaExcerptPresentation.entry(for: post, in: modelA.document!, model: sceneA.agentFreshness)
                    .contains("Original unavailable: the agent's session was replaced on its host.")
            }
        }
        try expect(true, "a replaced agent session cannot inherit revision 3, and its quote says the original is unavailable")

        // 8. Light and dark.
        _ = try panel(first.id)
        try await renderAppearances(scene: sceneA, host: hostA)
        try expect(executorCount() == executorsBefore, "freshness, excerpts, relaunch and rebind construct no executor")
        sceneA.unmount(); await modelA.close()
        print("Shared freshness scene checks passed: per-agent changed-since-sent in mounted scenes, refusal, relaunch, rebind, excerpt source lines and the owner-only export rule.")
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// Renders offscreen in both appearances; never orders a window front.
    private static func renderAppearances(scene: SharedAreaSceneView, host: NSView) async throws {
        let directory = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        var colours: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "no bitmap for \(name.rawValue)") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let text = scene.freshnessPanel.statusColor?.usingColorSpace(.deviceRGB) else { throw Failure(message: "status colour unresolved") }
            colours.append(text)
            if let directory, let png = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("freshness-\(name == .aqua ? "light" : "dark").png"))
            }
        }
        host.appearance = nil
        try expect(colours[0].brightnessComponent < colours[1].brightnessComponent,
            "the freshness panel re-resolves its token text colour for light and dark offscreen renders")
    }
    private static func controller(root: URL, identity: Collaboration.Identity, document: SharedArea.Document, authority: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-freshness.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-freshness-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint, person: identity.person, area: document.id)
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
        print("PASS shared freshness scene: \(message)")
    }
    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: message)
    }

    /// The owning host as the handoff client sees it: control with the current
    /// host generation, queued receipts and scripted host outcomes.
    private actor HostScript: SharedAgentHandoffTransport {
        let authority: Authority
        let owner: Collaboration.Identity
        private(set) var generationMap: [SharedArea.ID<SharedArea.Object>: UUID]
        private var receipts: [UUID: Collaboration.AgentDispatchReceipt] = [:]
        private(set) var sends = 0
        init(authority: Authority, owner: Collaboration.Identity, generations: [SharedArea.ID<SharedArea.Object>: UUID]) {
            self.authority = authority; self.owner = owner; generationMap = generations
        }
        func generation(_ object: SharedArea.ID<SharedArea.Object>) -> UUID? { generationMap[object] }
        func rebind(_ object: SharedArea.ID<SharedArea.Object>) { generationMap[object] = UUID() }
        func settle(_ id: UUID, phase: Collaboration.AgentDispatchPhase) {
            guard let receipt = receipts[id] else { return }
            receipts[id] = .init(command: receipt.command, phase: phase, claimID: UUID())
        }
        func state() async throws -> Collaboration.State { try await authority.state(owner) }
        func control(object: UUID) async throws -> Collaboration.AgentControlState {
            let document = try await authority.state(owner).document
            guard let source = document.items.first(where: { $0.id.rawValue == object })?.source,
                  let generation = generationMap[.init(object)] else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(area: document.id, object: .init(object), source: source, hostGeneration: generation, epoch: 1, revision: 1, controller: source.owner)
        }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt {
            if let prior = receipts[request.id] { return prior }
            let document = try await authority.state(owner).document
            guard let source = document.items.first(where: { $0.id.rawValue == object })?.source,
                  generationMap[.init(object)] == request.hostGeneration,
                  let context = document.contexts.first(where: { $0.id == request.contextRevision }) else {
                throw CollaborationClientError.server(status: 409, code: "sourceChanged")
            }
            let command = Collaboration.AgentDispatchCommand(id: request.id, area: document.id, object: .init(object), source: source, requester: owner,
                epoch: request.epoch, controlRevision: request.controlRevision, hostGeneration: request.hostGeneration, context: context, text: request.text, mode: request.mode)
            sends += 1
            let receipt = Collaboration.AgentDispatchReceipt(command: command, phase: .queued)
            receipts[request.id] = receipt
            return receipt
        }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id] else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return receipt
        }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Unscripted() }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Unscripted() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { throw Unscripted() }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unscripted() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unscripted() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Unscripted() }
        struct Unscripted: Error {}
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
        func emit(_ value: CollaborationSession.Status) { pair.continuation.yield(value) }
    }
    /// Runs the real reducer and the service's authoring and refusal mapping.
    private actor Authority {
        var document: SharedArea.Document
        let owner: SharedArea.ID<SharedArea.Person>
        let members: Set<SharedArea.ID<SharedArea.Person>>
        var connections: [UUID: (Collaboration.Identity, Connection)] = [:]
        init(document: SharedArea.Document, owner: SharedArea.ID<SharedArea.Person>, member: SharedArea.ID<SharedArea.Person>) {
            self.document = document; self.owner = owner; members = [owner, member]
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
            guard members.contains(identity.person) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(scope: .init(area: document.id, epoch: 1, role: identity.person == owner ? .owner : .editor), document: document)
        }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try state(identity)
            let connection = Connection(); connections[identity.device] = (identity, connection)
            return connection
        }
        func apply(_ mutation: Collaboration.Mutation, identity: Collaboration.Identity) async throws -> Collaboration.Receipt {
            _ = try state(identity)
            for edit in mutation.command.edits {
                switch edit {
                case .post(let post) where post.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                case .context(let context) where context.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                default: break
                }
            }
            let receipt: Collaboration.Receipt
            do {
                switch try document.apply(mutation.command) {
                case .applied(let revision): receipt = .init(revision: revision, duplicate: false)
                case .duplicate(let revision): receipt = .init(revision: revision, duplicate: true)
                }
            } catch SharedArea.Failure.conflict { throw CollaborationClientError.server(status: 409, code: "revisionConflict") }
            catch is SharedArea.Failure { throw CollaborationClientError.server(status: 400, code: "invalidCommand") }
            for (identity, connection) in connections.values { await connection.emit(.connected(try .init(state: state(identity)))) }
            return receipt
        }
    }
    private struct Transport: SharedAreaControllerTransport {
        let identityValue: Collaboration.Identity
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { try await authority.state(identityValue) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await authority.connection(identityValue) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await authority.apply(mutation, identity: identityValue) }
    }
}
