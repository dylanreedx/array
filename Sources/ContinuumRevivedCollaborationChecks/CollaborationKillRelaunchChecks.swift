import Darwin
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct KillFailure: Error { let message: String }
private func killExpect(_ value: Bool, _ message: String) throws {
    guard value else { throw KillFailure(message: message) }
    print("PASS kill/relaunch: \(message)")
}

/// What a child process does before it SIGKILLs itself. The parent then
/// relaunches the same side over the same on-disk state.
private struct KillSpec: Codable {
    enum Mode: String, Codable { case outboxBeforeSend, outboxAfterCommit, hostAfterClaim, hostDuringProvider }
    let mode: Mode
    let endpoint: URL
    let credential: Collaboration.Credential
    let area: UUID
    let directory: URL
    let command: SharedArea.Command?
    let draft: SharedAreaLocalDraft?
    let binding: SharedAreaLocalSourceBinding?
}

private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}

private func dieNow() -> Never {
    // Signal delivery may trail kill(2); wait for it instead of trapping, so
    // the witness never produces a crash report for the host session.
    kill(getpid(), SIGKILL)
    while true { pause() }
}

/// Delegates to the production HTTP transport; the hook decides where the
/// process dies relative to the remote effect, and counts relaunch requests.
private final class KillTransport: SharedAreaControllerTransport, @unchecked Sendable {
    let base: any SharedAreaControllerTransport
    let before: @Sendable () -> Void
    let after: @Sendable () -> Void
    private let lock = NSLock()
    private var applied = 0
    var applies: Int { lock.withLock { applied } }
    init(_ base: any SharedAreaControllerTransport, before: @escaping @Sendable () -> Void = {}, after: @escaping @Sendable () -> Void = {}) {
        self.base = base; self.before = before; self.after = after
    }
    func identity() async throws -> Collaboration.Identity { try await base.identity() }
    func state() async throws -> Collaboration.State { try await base.state() }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await base.connection(initial: initial) }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        lock.withLock { applied += 1 }
        before()
        let receipt = try await base.apply(mutation)
        after()
        return receipt
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [KillTransport] = []
    func set(_ value: KillTransport) { lock.withLock { transports.append(value) } }
    var applies: Int { lock.withLock { transports.reduce(0) { $0 + $1.applies } } }
}

private struct KillHostTransport: SharedAgentHandoffTransport {
    let base: SharedAgentHandoffAPI
    let afterClaim: @Sendable () -> Void
    func state() async throws -> Collaboration.State { try await base.state() }
    func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await base.register(request) }
    func control(object: UUID) async throws -> Collaboration.AgentControlState { try await base.control(object: object) }
    func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { try await base.change(object: object, request: request) }
    func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await base.send(object: object, request: request) }
    func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await base.receipt(id: id) }
    func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await base.pending(host: host) }
    func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
        let receipt = try await base.claim(id: id, request: request)
        afterClaim()
        return receipt
    }
    func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await base.admit(id: id, request: request) }
    func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { try await base.finish(id: id, outcome: outcome) }
}

@MainActor
private func controller(_ spec: KillSpec, wrap: @escaping @Sendable (any SharedAreaControllerTransport) -> any SharedAreaControllerTransport) throws -> SharedAreaController {
    let endpoint = try CollaborationServiceEndpoint(spec.endpoint, allowsInsecureLoopback: true)
    let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
    let scope = CollaborationCredentialScope(endpoint: endpoint, identity: spec.credential.identity)
    try credentials.save(spec.credential, for: scope)
    let local = try SharedAreaLocalStore(applicationSupportRoot: spec.directory, bundleIdentifier: nil,
        endpoint: endpoint, person: spec.credential.identity.person, area: .init(spec.area))
    return try SharedAreaController(localStore: local, credentialStore: credentials, credentialScope: scope, bundleIdentifier: nil,
        transportFactory: { endpoint, credential, area in wrap(try SharedAreaController.liveTransport(endpoint: endpoint, credential: credential, area: area)) })
}

/// Child entry point. Reaching the end means the kill point was never hit.
@MainActor
func runKillChild(_ specPath: String) async -> Never {
    do {
        let spec = try JSONDecoder().decode(KillSpec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
        switch spec.mode {
        case .outboxBeforeSend, .outboxAfterCommit:
            let child = try controller(spec) { live in
                spec.mode == .outboxBeforeSend ? KillTransport(live, before: { dieNow() }) : KillTransport(live, after: { dieNow() })
            }
            await child.open()
            guard child.status == .connected, let command = spec.command else { throw KillFailure(message: "child not connected") }
            if let draft = spec.draft { try child.saveDraft(draft) }
            _ = await child.submit(command, preserving: spec.draft)
        case .hostAfterClaim, .hostDuringProvider:
            let api = try CollaborationAPI(baseURL: spec.endpoint, credential: spec.credential.token, allowsInsecureLoopback: true)
            let live = SharedAgentHandoffAPI(api: api, area: spec.area)
            let transport = KillHostTransport(base: live, afterClaim: { if spec.mode == .hostAfterClaim { dieNow() } })
            let journal = try SharedAgentHostJournal(directory: spec.directory)
            let host = SharedAgentHostDispatcher(identity: spec.credential.identity, transport: transport, journal: journal,
                bootID: UUID(), execute: { _, _ in dieNow() })
            guard let binding = spec.binding else { throw KillFailure(message: "missing binding") }
            await host.pollOnce(bindings: [binding])
            print("child: poll ended without reaching its kill point: \(String(describing: host.lastError))")
        }
    } catch { print("child: \(error)") }
    exit(3)
}

@MainActor
private func killedChild(_ spec: KillSpec, root: URL) async throws {
    let file = root.appendingPathComponent("spec-\(spec.mode.rawValue).json")
    try JSONEncoder().encode(spec).write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--kill-child", file.path]
    try process.run()
    await Task.detached { process.waitUntilExit() }.value
    try killExpect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
        "\(spec.mode.rawValue): child process was SIGKILLed at its kill point")
}

/// (a) A real separate process dies mid-change; a fresh process-side object
/// reconstructs only from disk and the service. Nothing is lost or duplicated,
/// and an uncertain provider attempt is reported, never replayed.
@MainActor
func runCollaborationKillRelaunchChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-kill-relaunch-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 91, count: 32)
    let service = try CollaborationStore(path: root.appendingPathComponent("service.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: service)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ name: String) async throws -> Collaboration.Credential {
            let enrollment = try await service.provisionPerson(label: name)
            return try await service.redeem(.init(code: enrollment.code, deviceLabel: name))
        }
        let a = try await person("Killed A"), b = try await person("Teammate B")
        let apiA = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let apiB = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let created = try await apiA.createArea(), area = created.document.id
        _ = try await apiB.accept(code: try await apiA.invite(area: area.rawValue, request: .init(person: b.identity.person)).code)
        let host = try await apiA.registerHost()
        let agent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let thread = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: "Agreed scope.")
        func rect(_ x: Double) -> SharedArea.Rect { .init(x: x, y: 0, width: 300, height: 200) }
        _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 0, edits: [
            .admit(agent, .init(id: .init(), object: agent.id, rect: rect(0))),
            .admit(thread, .init(id: .init(), object: thread.id, rect: rect(350))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: rect(700))), .context(context),
        ])))

        // Outbox: die after the durable record but before the request leaves,
        // then die after the service committed but before the reply arrived.
        for mode in [KillSpec.Mode.outboxBeforeSend, .outboxAfterCommit] {
            let revision = try await apiA.state(area: area.rawValue).document.revision
            let text = "Exactly once through \(mode.rawValue)"
            let command = SharedArea.Command(area: area, expectedRevision: revision,
                edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: text))])
            let draft = SharedAreaLocalDraft(object: thread.id, text: "private draft for \(mode.rawValue)")
            let unrelated = SharedAreaLocalDraft(object: thread.id, text: "unrelated draft survives \(mode.rawValue)")
            let spec = KillSpec(mode: mode, endpoint: endpoint, credential: a, area: area.rawValue,
                directory: root.appendingPathComponent(mode.rawValue), command: command, draft: draft, binding: nil)
            // Seed an unrelated private draft so loss is visible after the kill.
            let seed = try controller(spec) { $0 }
            await seed.open(); try seed.saveDraft(unrelated); await seed.close()
            try await killedChild(spec, root: root)
            let landed = try await apiA.state(area: area.rawValue).document
            try killExpect(landed.posts.filter { $0.text == text }.count == (mode == .outboxAfterCommit ? 1 : 0),
                "\(mode.rawValue): service holds the change \(mode == .outboxAfterCommit ? "once" : "not yet") at the moment of death")
            let counter = CounterBox()
            let relaunched = try controller(spec) { live in let wrapped = KillTransport(live); counter.set(wrapped); return wrapped }
            await relaunched.open()
            let deadline = ContinuousClock.now + .seconds(5)
            while relaunched.deliveryRecord(for: command.id)?.isPending != false, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let final = try await apiB.state(area: area.rawValue).document
            try killExpect(final.posts.filter { $0.text == text }.count == 1 && final.revision == revision + 1
                && relaunched.deliveryRecord(for: command.id)?.state == .accepted(revision + 1),
                "\(mode.rawValue): relaunch lands the exact intent exactly once")
            try killExpect(counter.applies == (mode == .outboxBeforeSend ? 1 : 0),
                "\(mode.rawValue): relaunch \(mode == .outboxBeforeSend ? "sends the unsent intent once" : "reconciles the lost reply from the authoritative receipt without resending")")
            try killExpect(relaunched.drafts.contains(unrelated) && !relaunched.drafts.contains(draft),
                "\(mode.rawValue): private drafts survive and the accepted draft retires")
            await relaunched.close()
        }

        // Host: hand the agent to B, who queues prompts; A's host process dies.
        let binding = SharedAreaLocalSourceBinding(object: agent.id, binding: agent.source!.binding, host: host.id,
            projectID: UUID(), tileID: UUID(), agentID: .init(rawValue: UUID()))
        let liveA = SharedAgentHandoffAPI(api: apiA, area: area.rawValue), liveB = SharedAgentHandoffAPI(api: apiB, area: area.rawValue)
        let journalDirectory = root.appendingPathComponent("host-journal", isDirectory: true)
        let clientA = try SharedAgentHandoffController(identity: a.identity, transport: liveA, directory: root.appendingPathComponent("client-a"))
        let clientB = try SharedAgentHandoffController(identity: b.identity, transport: liveB, directory: root.appendingPathComponent("client-b"))
        // Register the host generation before offering control.
        let registrar = SharedAgentHostDispatcher(identity: a.identity, transport: liveA,
            journal: try SharedAgentHostJournal(directory: journalDirectory), bootID: UUID(), execute: { _, _ in .refused(.unknownAgent) })
        await registrar.pollOnce(bindings: [binding])
        await clientA.refresh(object: agent.id); await clientA.offer(to: b.identity.person)
        await clientB.refresh(object: agent.id); await clientB.acceptOffer()
        try killExpect(clientB.control?.controller == b.identity.person, "teammate B controls the shared agent")
        for mode in [KillSpec.Mode.hostAfterClaim, .hostDuringProvider] {
            await clientB.refresh(object: agent.id)
            await clientB.send(text: "Prompt for \(mode.rawValue)", context: context.id)
            guard let queued = clientB.receipt, queued.command.text == "Prompt for \(mode.rawValue)" else {
                throw KillFailure(message: "\(mode.rawValue): prompt was not queued")
            }
            try await killedChild(KillSpec(mode: mode, endpoint: endpoint, credential: a, area: area.rawValue,
                directory: journalDirectory, command: nil, draft: nil, binding: binding), root: root)
            var executions = 0
            let relaunched = SharedAgentHostDispatcher(identity: a.identity, transport: liveA,
                journal: try SharedAgentHostJournal(directory: journalDirectory), bootID: UUID(),
                execute: { _, _ in executions += 1; return .accepted })
            await relaunched.pollOnce(bindings: [binding])
            await relaunched.pollOnce(bindings: [binding])
            let outcome = try await apiB.agentDispatchReceipt(area: area.rawValue, id: queued.command.id)
            if mode == .hostAfterClaim {
                try killExpect(executions == 1 && outcome.phase == .accepted,
                    "hostAfterClaim: a claim that never reached the provider runs exactly once after relaunch")
            } else {
                try killExpect(executions == 0 && outcome.phase == .uncertain,
                    "hostDuringProvider: an attempt cut off inside the provider call is reported uncertain and never resent")
            }
        }
        try await server.stop()
        print("Collaboration kill/relaunch checks passed: SIGKILLed child processes before send, after commit, after host claim and inside the provider call.")
    } catch { try? await server.stop(); throw error }
}
