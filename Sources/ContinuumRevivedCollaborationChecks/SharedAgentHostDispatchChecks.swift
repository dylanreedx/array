import Foundation
import GRDB
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct HostDispatchCheckFailure: Error { let message: String }
private func hostDispatchCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw HostDispatchCheckFailure(message: label) }
    print("PASS host dispatch: \(label)")
}
private actor DropHostOutcome {
    var once = true
    func shouldDrop() -> Bool { if once { once = false; return true }; return false }
}
private struct LossyHostTransport: SharedAgentHandoffTransport {
    let base: SharedAgentHandoffAPI
    let drop: DropHostOutcome
    func state() async throws -> Collaboration.State { try await base.state() }
    func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await base.register(request) }
    func control(object: UUID) async throws -> Collaboration.AgentControlState { try await base.control(object: object) }
    func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { try await base.change(object: object, request: request) }
    func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await base.send(object: object, request: request) }
    func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await base.receipt(id: id) }
    func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await base.pending(host: host) }
    func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await base.claim(id: id, request: request) }
    func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await base.admit(id: id, request: request) }
    func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt {
        if await drop.shouldDrop() { throw URLError(.networkConnectionLost) }
        return try await base.finish(id: id, outcome: outcome)
    }
}

@MainActor
func runSharedAgentHostDispatchChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-host-dispatch-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 73, count: 32)
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
        let a = try await person("Owner A"), b = try await person("Teammate B")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let initial = try await aa.createArea(), area = initial.document.id.rawValue
        let invitation = try await aa.invite(area: area, request: .init(person: b.identity.person))
        _ = try await bb.accept(code: invitation.code)
        let host = try await aa.registerHost()
        let object = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person,
            text: "This immutable agreement defines the shared change.")
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: initial.document.id, expectedRevision: 0, edits: [
            .admit(object, .init(id: .init(), object: object.id, rect: .init(x: 0, y: 0, width: 300, height: 200))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 350, y: 0, width: 300, height: 200))), .context(context)
        ])))
        let binding = SharedAreaLocalSourceBinding(object: object.id, binding: object.source!.binding, host: host.id,
            projectID: UUID(), tileID: UUID(), agentID: .init(rawValue: UUID()))
        let hostDirectory = root.appendingPathComponent("owner-host", isDirectory: true)
        let journal = try SharedAgentHostJournal(directory: hostDirectory)
        let liveA = SharedAgentHandoffAPI(api: aa, area: area), liveB = SharedAgentHandoffAPI(api: bb, area: area)
        var sourceAcceptances = 0, recipientAcceptances = 0, markerBeforeEffect = true
        let execute: SharedAgentHostDispatcher.Execute = { local, command in
            markerBeforeEffect = markerBeforeEffect && ((try? journal.attempts().first(where: { $0.id == command.id })?.phase) == .attempting)
            guard local.agentID == binding.agentID, local.projectID == binding.projectID else { return .refused(.unknownAgent) }
            sourceAcceptances += 1
            return .accepted
        }
        let lossy = LossyHostTransport(base: liveA, drop: DropHostOutcome())
        let source = SharedAgentHostDispatcher(identity: a.identity, transport: lossy, journal: journal, bootID: UUID(), execute: execute)
        await source.pollOnce(bindings: [binding])
        let clientA = try SharedAgentHandoffController(identity: a.identity, transport: liveA, directory: root.appendingPathComponent("client-a"))
        let bDirectory = root.appendingPathComponent("client-b")
        let clientB = try SharedAgentHandoffController(identity: b.identity, transport: liveB, directory: bDirectory)
        await clientA.refresh(object: object.id); await clientA.offer(to: b.identity.person)
        await clientB.refresh(object: object.id); await clientB.acceptOffer()
        try hostDispatchCheck(clientB.control?.controller == b.identity.person, "native-facing controller completes explicit targeted handoff through real HTTP")
        await clientB.send(text: "Implement the reviewed change.", context: context.id)
        guard let queued = clientB.receipt else { throw HostDispatchCheckFailure(message: "prompt not queued") }
        try hostDispatchCheck(try clientB.freshness.frozenCommand(queued.command.id) == queued.command
            && clientB.freshness.unsettledCommands() == [queued.command.id],
            "the production controller freezes the delivered prompt in its freshness ledger, awaiting the host")
        let faultDB = try DatabaseQueue(path: hostDirectory.appendingPathComponent("agent-host-journal.sqlite").path)
        try await faultDB.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_attempt BEFORE UPDATE OF phase ON handoff_attempts WHEN NEW.phase='attempting' BEGIN SELECT RAISE(ABORT,'injected host marker fault'); END")
        }
        await source.pollOnce(bindings: [binding])
        let afterFault = try await bb.agentDispatchReceipt(area: area, id: queued.command.id)
        try hostDispatchCheck(sourceAcceptances == 0 && source.lastError != nil && afterFault.phase == .claimed,
            "failed irreversible marker commits no provider acceptance after a durable service claim")
        try await faultDB.write { try $0.execute(sql: "DROP TRIGGER reject_attempt") }
        await source.pollOnce(bindings: [binding])
        let beforeLostReport = try await bb.agentDispatchReceipt(area: area, id: queued.command.id)
        try hostDispatchCheck(sourceAcceptances == 1 && markerBeforeEffect && beforeLostReport.phase == .dispatching,
            "host writes the attempt before its single acceptance and preserves a lost outcome report")
        let reopenedJournal = try SharedAgentHostJournal(directory: hostDirectory)
        let reattached = SharedAreaLocalSourceBinding(object: binding.object, binding: binding.binding, host: binding.host,
            projectID: binding.projectID, tileID: UUID(), agentID: binding.agentID)
        try hostDispatchCheck(try journal.generation(for: binding) == reopenedJournal.generation(for: reattached),
            "source view reattachment preserves logical host generation and AgentID")
        let rebooted = SharedAgentHostDispatcher(identity: a.identity, transport: liveA, journal: reopenedJournal, bootID: UUID(), execute: execute)
        await rebooted.pollOnce(bindings: [reattached])
        let bAfterRelaunch = try SharedAgentHandoffController(identity: b.identity, transport: liveB, directory: bDirectory)
        await bAfterRelaunch.refresh(object: object.id)
        try hostDispatchCheck(sourceAcceptances == 1 && bAfterRelaunch.receipt?.command.id == queued.command.id && bAfterRelaunch.receipt?.phase == .accepted,
            "both client relaunch and lost host report recover the original accepted receipt without another prompt")
        let incarnation = Collaboration.AgentIncarnation(object: object.id, hostGeneration: queued.command.hostGeneration)
        let given = try bAfterRelaunch.freshness.freshness(of: incarnation, agreement: agreement.id,
            in: bAfterRelaunch.areaState?.document ?? SharedArea.Document())
        try hostDispatchCheck(try bAfterRelaunch.freshness.unsettledCommands().isEmpty && given.state == .current(context.id)
            && given.lastAccepted == queued.command,
            "a relaunched controller's refresh settles the host's acceptance: the agent was given the current agreement revision")
        await bAfterRelaunch.send(text: "Second deliberate prompt.", context: context.id)
        guard let second = bAfterRelaunch.receipt else { throw HostDispatchCheckFailure(message: "second prompt absent") }
        let interrupted = try reopenedJournal.prepare(second.command)
        let interruptedClaim = Collaboration.AgentHostClaim(claimID: interrupted.claimID, hostGeneration: second.command.hostGeneration)
        _ = try await aa.claimAgentDispatch(area: area, id: second.command.id, claim: interruptedClaim)
        try hostDispatchCheck(try reopenedJournal.beginAttempt(interrupted, bootID: UUID()), "crash fixture persists its irreversible boundary")
        _ = try await aa.admitAgentDispatch(area: area, id: second.command.id, claim: interruptedClaim)
        let afterCrash = SharedAgentHostDispatcher(identity: a.identity, transport: liveA,
            journal: try SharedAgentHostJournal(directory: hostDirectory), bootID: UUID(), execute: execute)
        await afterCrash.pollOnce(bindings: [reattached])
        let uncertain = try await bb.agentDispatchReceipt(area: area, id: second.command.id)
        try hostDispatchCheck(uncertain.phase == .uncertain && sourceAcceptances == 1,
            "crash after attempt marker reports honest uncertainty and never replays an executable prompt")
        let receiver = SharedAgentHostDispatcher(identity: b.identity, transport: liveB,
            journal: try SharedAgentHostJournal(directory: root.appendingPathComponent("recipient-host")), execute: { _, _ in recipientAcceptances += 1; return .accepted })
        await receiver.pollOnce(bindings: [])
        try hostDispatchCheck(recipientAcceptances == 0, "recipient view has no local binding and constructs no execution path")
        guard let current = bAfterRelaunch.control else { throw HostDispatchCheckFailure(message: "missing current control") }
        let savedRequest = Collaboration.AgentPromptRequest(epoch: 1, controlRevision: current.revision, hostGeneration: current.hostGeneration,
            contextRevision: context.id, text: "Recover this exact client intent.")
        let pending = SharedAgentPendingIntent(object: object.id, action: .prompt(savedRequest))
        let clientJournal = try SharedAgentHandoffIntentStore(directory: bDirectory, device: b.identity.device)
        try clientJournal.save(pending)
        _ = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: savedRequest)
        let resumedB = try SharedAgentHandoffController(identity: b.identity, transport: liveB, directory: bDirectory)
        try hostDispatchCheck(resumedB.pending?.id == savedRequest.id, "client restart retains the exact pre-effect request identity")
        await resumedB.checkDelivery()
        try hostDispatchCheck(resumedB.pending == nil && resumedB.receipt?.command.id == savedRequest.id,
            "resumed client recovers an accepted lost reply without a new command ID")
        await afterCrash.pollOnce(bindings: [reattached])
        try hostDispatchCheck(sourceAcceptances == 2 && recipientAcceptances == 0,
            "only the new deliberate command adds one source acceptance; recovery adds none")
        await resumedB.refresh(object: object.id)
        try hostDispatchCheck(try resumedB.freshness.unsettledCommands().isEmpty,
            "refresh settles older prompts too: the interrupted one is no longer awaiting the host")
        try await server.stop()
        print("Shared agent host dispatch checks passed: actual HTTP, source-only dispatch callback, pre-effect journal failure, lost report, client/host reconstruction, view-independent identity and honest interrupted-attempt uncertainty.")
    } catch { try? await server.stop(); throw error }
}
