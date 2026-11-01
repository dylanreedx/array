import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// COL-15, end to end. (1) The three PRODUCTION runners, driven through the
/// reactive fake CLIs on PATH, stream a real turn through the supervisor into
/// the projector. (2) A teammate's scene, mounted by the production entry,
/// renders that projection read-only through the controller's read route.
@MainActor
enum SharedAgentLiveChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private typealias P = Collaboration.AgentProjection

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS live agent view: \(label)")
    }
    private static func eventually(_ label: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "timed out: \(label)")
    }

    static func run(mount: SharedAreaSceneChecks.Mount) async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("array-live-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let originalCodexTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
        setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
        defer {
            setenv("PATH", originalPath, 1)
            if let originalCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalCodexTransport, 1) }
            else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
        }
        var claudeLog: P.Log?
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let log = try await runHarness(kind, root: root.appendingPathComponent(kind.rawValue), originalPath: originalPath)
            if kind == .claude { claudeLog = log }
        }
        guard let claudeLog else { return }
        try await runScene(mount: mount, root: root.appendingPathComponent("scene"), log: claudeLog)
    }

    /// One production runner, one real fake-CLI turn, projected.
    private static func runHarness(_ kind: AgentSteeringQAFakes.Harness, root: URL, originalPath: String) async throws -> P.Log {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(kind, in: bin)
        setenv("PATH", "\(bin.path):\(originalPath)", 1)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        let (harness, model): (AgentHarness, String) = switch kind {
        case .claude: (.claudeCode, "anthropic/claude-haiku-4-5-20251001")
        case .codex: (.codex, "openai-codex/gpt-5.6-sol")
        case .pi: (.pi, "openai-codex/gpt-5.6-sol")
        }
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: model, thinking: "low")
        let sink = SharedAgentProjectorChecks.LogSink()
        let host = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
        let owner = SharedArea.ID<SharedArea.Person>()
        let projector = try SharedAgentProjector(supervisor: supervisor, agent: id, host: host, object: object, generation: 1,
                                                 owner: owner, sink: sink)
        defer { projector.stop() }
        let prompt = "TOOL private-prompt-\(kind.rawValue)-marker"
        guard supervisor.send(prompt, to: id) else { throw Failure(description: "\(kind): send refused") }
        var busy: P.Capabilities?
        try await eventually("\(kind): the projection advertises the bound runner mid-turn") {
            if projector.log.head.capabilities.canSteer { busy = projector.log.head.capabilities }
            return busy != nil
        }
        // The fakes stream assistant text only in answer to a steer, so steer
        // the bound runner: its reply is real provider text through the translator.
        if kind != .claude {
            let steered = await supervisor.accept(.steer(AgentPrompt("change course")), for: id)
            guard steered == .accepted else { throw Failure(description: "\(kind): steer refused: \(steered)") }
        }
        // A second view of the same agent attaches mid-turn: no second executor.
        let second = try SharedAgentProjector(supervisor: supervisor, agent: id, host: host, object: .init(), generation: 1,
                                              sink: SharedAgentProjectorChecks.LogSink())
        try await eventually("\(kind): the turn finishes and the runner is released") {
            !supervisor.isRunning(id) && projector.log.head.phase == .ready && !projector.log.head.capabilities.canSteer
        }
        for _ in 0..<10 { await Task.yield() }
        await projector.flush()
        second.stop()
        let head = projector.log.head
        let bytes = String(decoding: sink.batches.reduce(Data(), +), as: UTF8.self)
        let spawns = AgentSteeringQAFakes.spawnCount(in: bin)
        try expect(busy?.canInterrupt == true && busy?.canSend == false && busy?.locallyManaged == true
            && !head.capabilities.canSteer && !head.capabilities.canInterrupt,
            "\(kind): the production runner's own steer/interrupt facts reach the projection only while it is bound")
        // The codex fake omits `exitCode`, which its translator reads as failed:
        // the projection reports what the translator said, finished either way.
        try expect(head.rows.contains { $0.kind == .tool(.command) && $0.status != nil && $0.status != .running }
            // The claude fake sends whole assistant messages, never `text_delta`;
            // the translator drops those for the main thread, so no text exists.
            && (kind == .claude || head.rows.contains { $0.kind == .assistant && $0.text.contains("steered: change course") })
            && sink.log?.head == head,
            "\(kind): a real turn projects its tool step and assistant text, and the delivered log equals the host head"
            + " (rows: \(head.rows.map { "\($0.kind)/\($0.status.map { "\($0)" } ?? "-")/\($0.text.prefix(40))" }), delivered equal: \(sink.log?.head == head))")
        // The owner's own prompt crosses, as theirs and exactly as typed (the
        // decision changed in 0.7.38: teammates read every prompt, by name).
        // So does the owner's steer, once the provider takes it.
        let promptRows = head.rows.filter { $0.kind == .prompt(owner) }
        let typed = kind == .claude ? [prompt] : [prompt, "change course"]
        try expect(promptRows.map(\.text) == typed && head.lastPrompt?.person == owner
            && !bytes.contains("toolu_") && !bytes.contains("cmd-fake"),
            "\(kind): the human prompt and steer cross once each as the owner's, word for word; provider item ids never cross"
            + " (prompt rows \(promptRows.map(\.text)))")
        try expect(spawns == 1, "\(kind): two attached projections and one turn started exactly one CLI process (\(spawns))")
        return sink.log ?? P.Log(snapshot: head)
    }

    /// B's production-mounted scene renders A's projection, read-only.
    private static func runScene(mount: SharedAreaSceneChecks.Mount, root: URL, log: P.Log) async throws {
        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let agent = SharedArea.Item(id: log.head.object, kind: .agentObservation,
            source: .init(owner: a.person, host: log.head.host, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(agent, .init(id: .init(), object: agent.id, rect: .init(x: 40, y: 40, width: 420, height: 300)))]))
        let authority = Authority(document: document, members: [a.person, b.person], log: log)
        let model = try controller(root: root, identity: b, document: document, authority: authority)
        let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let scene = try mount(model, b.person, host)
        await model.open()
        try scene.selectObject(agent.id)
        host.layoutSubtreeIfNeeded()
        let panel = scene.livePanel
        try await eventually("B's live panel shows the projection", seconds: 5) { panel.replica.state == log.head }
        try expect(!panel.isHidden && panel.frame.height > 0 && panel.statusText.hasPrefix("Idle")
            && panel.transcriptText.contains("• Command · done") && panel.controlsText.contains("stay with its owner"),
            "selecting the agent shows its live state, tool steps and host-governed controls in place of the reader")
        let replays = await authority.reads
        try expect(replays >= 1 && panel.resnapshots == 1, "the first read is an explicit snapshot; later reads page frames")

        // A new tail frame reaches the mounted view; a gap forces a resnapshot.
        await authority.append([.phase(.working)])
        try await eventually("B sees the new frame", seconds: 5) { panel.statusText.hasPrefix("Working") }
        let resnapshots = panel.resnapshots
        // One actor step: the two frames are published together, and the next
        // read that carries both loses the first in transit.
        await authority.appendLosingFirst([.phase(.ready), .phase(.failed)])
        try await eventually("B recovers from the gap", seconds: 5) { panel.statusText.hasPrefix("Last turn failed") }
        try expect(panel.resnapshots == resnapshots + 1, "a gap in what B received is repaired by exactly one explicit resnapshot")

        // Light and dark, offscreen, from the real token resolution.
        var colours: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(description: "no bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let colour = panel.statusColor?.usingColorSpace(.deviceRGB) else { throw Failure(description: "status colour unresolved") }
            colours.append(colour)
            if let directory = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_EVIDENCE"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try png.write(to: url.appendingPathComponent("live-agent-\(name == .aqua ? "light" : "dark").png"))
            }
        }
        host.appearance = nil
        try expect(colours[0].brightnessComponent < colours[1].brightnessComponent,
            "the live panel re-resolves its token colours for light and dark offscreen renders")

        // Liveness arrives the production way: the area's host list on the
        // controller's own connection, read by the scene (COL-06).
        await authority.publish(host: log.head.host, state: .offline)
        try await eventually("B's panel follows its host offline", seconds: 5) { panel.statusText.contains("host offline, last confirmed") }
        try expect(panel.controlsText.hasPrefix("Its host is offline"),
            "an offline host from the area's liveness turns the view into last-confirmed history with nothing offered")
        await authority.publish(host: log.head.host, state: .online)
        try await eventually("B's panel follows its host back online", seconds: 5) { !panel.statusText.contains("host offline") }

        // Unselect and unmount stop the read loop; nothing was ever executed.
        try scene.selectObject(nil)
        try expect(panel.isHidden && !panel.isPolling, "deselecting the agent hides the panel and stops reading")
        try scene.selectObject(agent.id)
        try expect(panel.isPolling, "reselecting resumes reading")
        scene.unmount()
        let after = await authority.reads
        try await Task.sleep(for: .milliseconds(1300))
        let later = await authority.reads
        try expect(!panel.isPolling && later == after, "unmounting stops the read loop: no read after close")
    }

    // MARK: - Fixture transport

    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
        func emit(_ value: CollaborationSession.Status) { pair.continuation.yield(value) }
    }
    /// The service stand-in. Its projection read is the same portable log the
    /// HTTP route serves; `skipNextFrame` models a frame lost in transit.
    private actor Authority {
        let document: SharedArea.Document
        let members: Set<SharedArea.ID<SharedArea.Person>>
        var log: P.Log
        var reads = 0
        private var skip = false
        private var connections: [Connection] = []
        init(document: SharedArea.Document, members: Set<SharedArea.ID<SharedArea.Person>>, log: P.Log) {
            self.document = document; self.members = members; self.log = log
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
            guard members.contains(identity.person) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(scope: .init(area: document.id, epoch: 1, role: .editor), document: document)
        }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try state(identity)
            let connection = Connection(); connections.append(connection)
            return connection
        }
        func read(_ identity: Collaboration.Identity, object: UUID, cursor: P.Cursor?) throws -> P.Read {
            _ = try state(identity)
            guard object == log.head.object.rawValue else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            reads += 1
            let value = log.read(after: cursor)
            guard skip, case .frames(let generation, let frames, let more) = value, frames.count > 1 else { return value }
            skip = false
            return .frames(generation: generation, frames: Array(frames.dropFirst()), more: more)
        }
        func append(_ payloads: [P.Payload]) {
            for payload in payloads {
                let frame = P.Frame(host: log.head.host, object: log.head.object, generation: log.head.generation,
                                    sequence: log.head.through + 1, payload: payload)
                try? log.publish(.init(snapshot: nil, frames: [frame]))
            }
        }
        func appendLosingFirst(_ payloads: [P.Payload]) { append(payloads); skip = true }
        func publish(host: SharedArea.ID<SharedArea.Host>, state: Collaboration.HostLivenessState) async {
            let current = Collaboration.State(scope: .init(area: document.id, epoch: 1, role: .editor), document: document)
            let now = Date()
            let liveness = Collaboration.HostLiveness(host: host, generation: UUID(), state: state, lastSeen: now,
                staleAt: now.addingTimeInterval(30), offlineAt: now.addingTimeInterval(90), reason: state == .offline ? .expired : nil)
            guard var replica = try? CollaborationReplica(state: current),
                  (try? replica.receive(.init(scope: current.scope, after: document.revision, through: document.revision, events: [],
                      nextCursor: document.revision, presenceVersion: UUID(), presence: [], serverTime: now, hosts: [liveness]))) != nil
            else { return }
            for connection in connections { await connection.emit(.connected(replica)) }
        }
    }
    private struct Transport: SharedAreaControllerTransport {
        let identityValue: Collaboration.Identity
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { try await authority.state(identityValue) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await authority.connection(identityValue) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
            throw CollaborationClientError.server(status: 403, code: "forbidden")
        }
        func readAgentProjection(object: UUID, cursor: P.Cursor?) async throws -> P.Read {
            try await authority.read(identityValue, object: object, cursor: cursor)
        }
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private static func controller(root: URL, identity: Collaboration.Identity, document: SharedArea.Document,
                                   authority: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-live-agent.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-live-agent-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
                                             person: identity.person, area: document.id)
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
}
