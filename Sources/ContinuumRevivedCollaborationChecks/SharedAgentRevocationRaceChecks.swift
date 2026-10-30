import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

// COL-20: stale queued work must not regain authority. The production host
// dispatcher drives real HTTP; revocations land exactly between its pending
// poll, claim and admission calls, and after an offline host reconnects.

private struct RevocationRaceFailure: Error { let message: String }
private func raceCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw RevocationRaceFailure(message: label) }
    print("PASS revocation race: \(label)")
}

/// One-shot hooks run on the host's own transport before the named call.
private actor RaceHooks {
    var beforeClaim: (@Sendable () async throws -> Void)?
    var beforeAdmit: (@Sendable () async throws -> Void)?
    func set(claim: (@Sendable () async throws -> Void)? = nil, admit: (@Sendable () async throws -> Void)? = nil) {
        beforeClaim = claim; beforeAdmit = admit
    }
    func takeClaim() -> (@Sendable () async throws -> Void)? { defer { beforeClaim = nil }; return beforeClaim }
    func takeAdmit() -> (@Sendable () async throws -> Void)? { defer { beforeAdmit = nil }; return beforeAdmit }
}
private struct RacingHostTransport: SharedAgentHandoffTransport {
    let base: SharedAgentHandoffAPI
    let hooks: RaceHooks
    func state() async throws -> Collaboration.State { try await base.state() }
    func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await base.register(request) }
    func control(object: UUID) async throws -> Collaboration.AgentControlState { try await base.control(object: object) }
    func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { try await base.change(object: object, request: request) }
    func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await base.send(object: object, request: request) }
    func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await base.receipt(id: id) }
    func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await base.pending(host: host) }
    func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
        if let hook = await hooks.takeClaim() { try await hook() }
        return try await base.claim(id: id, request: request)
    }
    func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
        if let hook = await hooks.takeAdmit() { try await hook() }
        return try await base.admit(id: id, request: request)
    }
    func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { try await base.finish(id: id, outcome: outcome) }
}

/// The service clock, advanced by a race hook to lapse a claim's authority window.
private final class RaceClock: @unchecked Sendable {
    private let lock = NSLock(); private var offset: TimeInterval = 0
    func now() -> Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

@MainActor
func runSharedAgentRevocationRaceChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-revocation-race-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 97, count: 32)
    let clock = RaceClock()
    let service = try CollaborationStore(path: root.appendingPathComponent("service.sqlite").path, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: service)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ name: String) async throws -> Collaboration.Credential {
            let enrollment = try await service.provisionPerson(label: name)
            return try await service.redeem(.init(code: enrollment.code, deviceLabel: name))
        }
        let a = try await person("Source A"), b = try await person("Teammate B")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        var bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let initial = try await aa.createArea(), area = initial.document.id.rawValue
        func admitB(_ api: CollaborationAPI) async throws {
            let code = try await aa.invite(area: area, request: .init(person: b.identity.person)).code
            _ = try await api.accept(code: code)
        }
        try await admitB(bb)
        let host = try await aa.registerHost()
        let object = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: "Reviewed boundary.")
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: initial.document.id, expectedRevision: 0, edits: [
            .admit(object, .init(id: .init(), object: object.id, rect: .init(x: 0, y: 0, width: 300, height: 200))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 350, y: 0, width: 300, height: 200))), .context(context),
        ])))
        let binding = SharedAreaLocalSourceBinding(object: object.id, binding: object.source!.binding, host: host.id,
            projectID: UUID(), tileID: UUID(), agentID: .init(rawValue: UUID()))
        let journal = try SharedAgentHostJournal(directory: root.appendingPathComponent("owner-host", isDirectory: true))
        var executions: [UUID] = []
        let hooks = RaceHooks()
        let dispatcher = SharedAgentHostDispatcher(identity: a.identity,
            transport: RacingHostTransport(base: SharedAgentHandoffAPI(api: aa, area: area), hooks: hooks),
            journal: journal, bootID: UUID(), execute: { _, command in executions.append(command.id); return .accepted })
        func epoch() async throws -> Int64 { try await aa.state(area: area).scope.epoch }
        func handToB() async throws -> Collaboration.AgentControlState {
            let current = try await aa.agentControl(area: area, object: object.id.rawValue), e = try await epoch()
            let offer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: b.identity.person)
            let offered = try await aa.changeAgentControl(area: area, object: object.id.rawValue,
                request: .init(epoch: e, expectedRevision: current.revision, hostGeneration: current.hostGeneration, action: .offer(offer)))
            return try await bb.changeAgentControl(area: area, object: object.id.rawValue,
                request: .init(epoch: e, expectedRevision: offered.revision, hostGeneration: current.hostGeneration, action: .accept(offer: offer.id)))
        }
        func promptFromB(_ control: Collaboration.AgentControlState) async throws -> UUID {
            let request = Collaboration.AgentPromptRequest(epoch: try await epoch(), controlRevision: control.revision,
                hostGeneration: control.hostGeneration, contextRevision: context.id, text: "Change the reviewed module.")
            return try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: request).command.id
        }
        func removeB() async throws { try await aa.removeMember(area: area, person: b.identity.person.rawValue, epoch: try await epoch()) }

        // Positive control: the same dispatcher, unhindered, executes once.
        await dispatcher.pollOnce(bindings: [binding])
        let control = try await handToB()
        let allowed = try await promptFromB(control)
        await dispatcher.pollOnce(bindings: [binding])
        let allowedPhase = try await aa.agentDispatchReceipt(area: area, id: allowed).phase
        try raceCheck(executions == [allowed] && allowedPhase == .accepted,
            "counterexample: an authorized prompt executes exactly once through the same dispatcher")

        // R1. Host is offline while B queues, is removed and re-admitted.
        let offline = try await promptFromB(try await handToB())
        try await removeB(); try await admitB(bb)
        await dispatcher.pollOnce(bindings: [binding])
        let offlinePhase = try await aa.agentDispatchReceipt(area: area, id: offline).phase
        let controllerAfterReconnect = try await aa.agentControl(area: area, object: object.id.rawValue).controller
        try raceCheck(executions == [allowed] && offlinePhase == .refused && controllerAfterReconnect == a.identity.person,
            "offline host reconnects after B's removal and re-admission: the stale prompt is refused, control returned to A")

        // R2. Removal lands after the host's pending poll, before its claim.
        let raced = try await promptFromB(try await handToB())
        let bPerson = b.identity.person.rawValue
        await hooks.set(claim: { [aa] in
            try await aa.removeMember(area: area, person: bPerson, epoch: try await aa.state(area: area).scope.epoch)
        })
        await dispatcher.pollOnce(bindings: [binding])
        let afterClaimRace = try await aa.agentDispatchReceipt(area: area, id: raced)
        try raceCheck(executions == [allowed] && dispatcher.lastError != nil && afterClaimRace.claimID == nil
            && (afterClaimRace.phase == .queued || afterClaimRace.phase == .refused),
            "removal between pending poll and claim: no claim, no execution")
        try await admitB(bb)
        await dispatcher.pollOnce(bindings: [binding])
        let racedPhase = try await aa.agentDispatchReceipt(area: area, id: raced).phase
        try raceCheck(executions == [allowed] && racedPhase == .refused,
            "after re-admission the raced prompt resolves refused, never executed")

        // R4. The claim's authority window lapses between claim and admission.
        //     The service refuses the admission; the host journal must agree
        //     (refused, not uncertain): the provider call never started.
        let lapsed = try await promptFromB(try await handToB())
        await hooks.set(admit: { clock.advance(CollaborationRetention().dispatchAuthorityWindow + 60) })
        await dispatcher.pollOnce(bindings: [binding])
        let lapsedPhase = try await aa.agentDispatchReceipt(area: area, id: lapsed).phase
        let lapsedJournal = try journal.attempts().first { $0.id == lapsed }?.phase
        try raceCheck(executions == [allowed] && lapsedPhase == .refused && lapsedJournal == .refused,
            "claim lapses before admission: service receipt and host journal both say refused, no execution")

        // R3. Device revocation lands after the claim, before admission.
        let claimed = try await promptFromB(try await handToB())
        let bDevice = b.identity.device, bToken = b.token
        await hooks.set(admit: { try await service.revokeDevice(token: bToken, device: bDevice) })
        await dispatcher.pollOnce(bindings: [binding])
        let afterAdmitRace = try await aa.agentDispatchReceipt(area: area, id: claimed)
        let revokedJournal = try journal.attempts().first { $0.id == claimed }?.phase
        try raceCheck(executions == [allowed] && afterAdmitRace.phase == .refused && revokedJournal == .refused,
            "device revoked between claim and admission: a definitive refusal before execute is refused, not uncertain, in receipt and journal")
        await dispatcher.pollOnce(bindings: [binding])
        try raceCheck(executions == [allowed] && (try journal.attempts()).filter { $0.phase == .accepted }.map(\.id) == [allowed],
            "a further poll executes nothing; the host journal holds exactly one accepted attempt")
        bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        do { _ = try await bb.agentDispatchReceipt(area: area, id: claimed); throw RevocationRaceFailure(message: "revoked bearer read a receipt") }
        catch let error as CollaborationClientError {
            guard case .server(401, _) = error else { throw error }
            print("PASS revocation race: revoked bearer cannot read its own prompt receipt")
        }
        try await server.stop()
        print("Shared agent revocation race checks passed: offline reconnect, removal before claim, device revocation before admission; one execution total.")
    } catch { try? await server.stop(); throw error }
}
