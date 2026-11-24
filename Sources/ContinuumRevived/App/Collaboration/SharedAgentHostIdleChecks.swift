import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// An idle host must not hammer the relay. The production
/// `SharedAreaHandoffCoordinator` loop runs for two virtual minutes against a
/// transport that counts every request while nothing happens (no command, no
/// document change). Before the fix that was three reads a second per shared
/// agent; the budget below fails it. The loop's sleeper is virtual, so the
/// window costs no wall time, and a command still waits no longer than the
/// slowest idle interval.
@MainActor
enum SharedAgentHostIdleChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Clock {
        var elapsed: Duration = .zero
        var longest: Duration = .zero
        var sleeps = 0
        let window: Duration
        init(window: Duration) { self.window = window }
        func advance(_ d: Duration) throws {
            elapsed += d; sleeps += 1; longest = max(longest, d)
            if elapsed >= window { throw CancellationError() }
        }
        var done: Bool { elapsed >= window }
    }

    private actor Counting: SharedAgentHandoffTransport {
        struct Forbidden: Error {}
        let document: SharedArea.Document
        var counts: [String: Int] = [:]
        var registered: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
        init(document: SharedArea.Document) { self.document = document }
        private func hit(_ name: String) { counts[name, default: 0] += 1 }
        var total: Int { counts.values.reduce(0, +) }
        func state() async throws -> Collaboration.State {
            hit("state")
            return .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document)
        }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState {
            hit("register"); registered[request.object] = request.generation
            return try await control(object: request.object.rawValue)
        }
        func control(object: UUID) async throws -> Collaboration.AgentControlState {
            hit("control")
            guard let item = document.items.first(where: { $0.id.rawValue == object }), let source = item.source else { throw Forbidden() }
            return .init(area: document.id, object: item.id, source: source, hostGeneration: registered[item.id] ?? UUID(),
                         epoch: 1, revision: 1, controller: source.owner)
        }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Forbidden() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { hit("pending"); return [] }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
    }

    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated support required")
        }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let savedClaude = AgentModelCatalog.shared.snapshot(for: .claudeCode)
        let root = URL(fileURLWithPath: support).appendingPathComponent("host-idle-\(UUID())")
        defer {
            setenv("PATH", originalPath, 1)
            AgentModelCatalog.shared.resetForQA(snapshot: savedClaude)
            try? FileManager.default.removeItem(at: root)
        }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(.claude, in: bin)
        setenv("PATH", "\(bin.path):\(originalPath)", 1)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
        defer { supervisor.stopAll() }
        let project = UUID()
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                                     model: AgentCatalogQAFixture.claude.seedModel ?? "", thinking: "low", projectId: project)

        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: owner.person, host: host, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 300, height: 240))),
        ]))
        let binding = SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: host,
            projectID: project, agentID: agent)
        let transport = Counting(document: document)
        let model = try SharedAgentHandoffController(identity: owner, transport: transport,
            directory: root.appendingPathComponent("area", isDirectory: true))
        let window = Duration.seconds(120)
        let clock = Clock(window: window)
        let coordinator = try SharedAreaHandoffCoordinator(model: model, supervisor: supervisor, bindings: { [binding] },
                                                           sleep: { try await clock.advance($0) })
        defer { coordinator.stopHosting() }
        coordinator.startHosting()
        let deadline = Date().addingTimeInterval(30)
        while !(await clock.done), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard await clock.done else { throw Failure(description: "host idle: the loop never reached the end of the window") }
        let total = await transport.total, counts = await transport.counts
        let longest = await clock.longest
        guard (await transport.registered[item.id]) != nil else {
            throw Failure(description: "host idle: the host never registered, so the poll did nothing and the count means nothing")
        }
        // The command read has no held read on the relay, so it stays a poll: a
        // guest's prompt waits at most one idle gap. The old loop made about
        // three hundred and sixty requests; the area re-reads are what backs off.
        guard total <= 115 else {
            throw Failure(description: "host idle: \(total) relay requests in 120 idle seconds (\(counts)); budget 115")
        }
        guard longest <= .milliseconds(1500) else {
            throw Failure(description: "host idle: the loop slept \(longest) between polls; a prompt must not wait longer than 1.5 seconds")
        }
        // Activity snaps the gap back, so a busy host is polled at 1 s.
        var pacing = SharedAgentHostPollPacing()
        for _ in 0..<60 { pacing.settled(busy: false) }
        guard pacing.interval == .milliseconds(1500) else { throw Failure(description: "host idle: a quiet host never reached its slowest gap") }
        pacing.settled(busy: true)
        guard pacing.interval == .seconds(1), pacing.refreshesState else {
            throw Failure(description: "host idle: activity did not return the loop to 1 s with a fresh area read")
        }
        print("PASS host idle: \(total) relay requests in 120 idle seconds (\(counts)), longest wait \(longest)")
    }
}
