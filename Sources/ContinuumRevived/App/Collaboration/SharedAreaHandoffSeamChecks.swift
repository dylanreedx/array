import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Handing an agent over, end to end, for each managed harness. The owner and
/// the teammate each drive a production `SharedAgentHandoffController`
/// (offer, accept, send, reclaim, refresh); the owner's app hosts the agent
/// through the production `SharedAreaHandoffCoordinator`, `AgentSupervisor`
/// and its real `ClaudeAgentRunner` / `CodexAgentRunner` / `PiRpcAgentRunner`
/// against the recording `AgentSteeringQAFakes`. Only the collaboration
/// service is scripted, with `CollaborationStore`'s handoff rules: one
/// controller per agent, revisions, and a queued prompt whose requester no
/// longer holds control resolving `refused` at the host's next poll.
///
/// Each harness must show the real outcome:
/// - the new controller's prompt reaches the owner's runner, once, verbatim;
/// - the old owner's own input stops executing while the teammate holds control;
/// - a prompt the handoff no longer authorises is refused, and reads refused
///   to the teammate who sent it.
@MainActor
enum SharedAreaHandoffSeamChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: "handoff seam: " + message) }
    }
    private static func eventually(_ message: String, timeout: TimeInterval = 12, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "handoff seam: timeout: " + message)
    }

    /// Called per harness with PATH already pointing at the fakes in `root/bin`.
    static func run(_ kind: AgentSteeringQAFakes.Harness, harness: AgentHarness, model modelID: String, root: URL) async throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(kind, in: bin)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
        defer { supervisor.stopAll() }
        let project = UUID()
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: modelID,
                                     thinking: "low", projectId: project)

        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let teammate = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: owner.person, host: host, binding: .init()))
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: owner.person,
            text: "Reviewed plan for the \(kind.rawValue) handoff.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 300, height: 240))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 340, y: 0, width: 300, height: 240))),
            .context(context),
        ]))
        let binding = SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: host,
            projectID: project, agentID: agent)
        let service = HandoffService(document: document, owner: owner)
        let ownerModel = try SharedAgentHandoffController(identity: owner, transport: service.view(owner),
            directory: root.appendingPathComponent("owner-area", isDirectory: true))
        let teammateModel = try SharedAgentHandoffController(identity: teammate, transport: service.view(teammate),
            directory: root.appendingPathComponent("teammate-area", isDirectory: true))
        let coordinator = try SharedAreaHandoffCoordinator(model: ownerModel, supervisor: supervisor, bindings: { [binding] })
        defer { coordinator.stopHosting() }
        await coordinator.pollOnce()

        var prompts: [String] {
            AgentSteeringQAFakes.receivedFrames(in: bin).compactMap { SharedAreaProviderDispatchChecks.promptFrame($0)?.text }
        }
        func count(_ text: String) -> Int { prompts.filter { $0 == text }.count }
        func idle() async throws { try await eventually("\(kind): the turn never settled") { !supervisor.isRunning(agent) } }

        // Positive control: before any handoff the owner's own input runs.
        let before = await supervisor.accept(.sendPrompt(.init("Owner before handoff.")), for: agent)
        try await eventually("\(kind): the owner's own prompt never reached the runner (\(before))") { count("Owner before handoff.") == 1 }
        try await idle()

        // Handoff through both production controllers.
        await ownerModel.refresh(object: item.id)
        await ownerModel.offer(to: teammate.person)
        await teammateModel.refresh(object: item.id)
        await teammateModel.acceptOffer()
        try expect(teammateModel.control?.controller == teammate.person,
                   "\(kind): the teammate must hold control after accepting, got \(String(describing: teammateModel.control?.controller)) — \(teammateModel.message)")

        // 1. The new controller's prompt reaches the owner's runner, once.
        await teammateModel.send(text: "Teammate prompt after handoff.", context: context.id)
        guard let sent = teammateModel.receipt, sent.phase == .queued, sent.command.requester == teammate else {
            throw Failure(description: "handoff seam: \(kind): the teammate's prompt was not queued: \(teammateModel.message)")
        }
        await coordinator.pollOnce()
        try await eventually("\(kind): the new controller's prompt never reached the runner: \(prompts)") { count(sent.command.promptText) == 1 }
        try await idle()
        await teammateModel.refresh(object: item.id)
        try expect(teammateModel.receipt?.phase == .accepted && count(sent.command.promptText) == 1,
                   "\(kind): the teammate must read the host's acceptance of exactly one write, got \(String(describing: teammateModel.receipt?.phase))")

        // 2. The old owner stops executing while the teammate holds control.
        let ownerAfter = await supervisor.accept(.sendPrompt(.init("Owner after handoff.")), for: agent)
        try await Task.sleep(for: .milliseconds(400))
        try expect(ownerAfter == .refused(.sharedAgentControlRequired) && count("Owner after handoff.") == 0,
                   "\(kind): the former owner's input must be refused before any write, got \(ownerAfter) / \(count("Owner after handoff.")) writes")

        // 3. Refused: the teammate queues a prompt, the owner reclaims before the
        //    host polls. The host refuses it, nothing is written, and the
        //    teammate's own controller reads refused.
        await teammateModel.send(text: "Teammate prompt the reclaim overtakes.", context: context.id)
        guard let overtaken = teammateModel.receipt, overtaken.phase == .queued, overtaken.command.id != sent.command.id else {
            throw Failure(description: "handoff seam: \(kind): the second teammate prompt was not queued: \(teammateModel.message)")
        }
        await ownerModel.refresh(object: item.id)
        await ownerModel.reclaim()
        try expect(ownerModel.control?.controller == owner.person, "\(kind): the owner must hold control after reclaiming — \(ownerModel.message)")
        await coordinator.pollOnce()
        try await Task.sleep(for: .milliseconds(400))
        await teammateModel.refresh(object: item.id)
        try expect(teammateModel.receipt?.command.id == overtaken.command.id && teammateModel.receipt?.phase == .refused
                   && count(overtaken.command.promptText) == 0,
                   "\(kind): a prompt the reclaim overtook must read refused with no write, got \(String(describing: teammateModel.receipt?.phase)) / \(count(overtaken.command.promptText)) writes")
        await teammateModel.send(text: "Teammate prompt without control.", context: context.id)
        try expect(teammateModel.pending == nil && teammateModel.receipt?.command.id == overtaken.command.id
                   && teammateModel.message.hasPrefix("This request was not accepted."),
                   "\(kind): a send without control must be refused, not left unresolved — \(teammateModel.message)")

        // Control is back: the owner's own input runs again.
        let reclaimed = await supervisor.accept(.sendPrompt(.init("Owner after reclaim.")), for: agent)
        try await eventually("\(kind): the owner's input never ran after reclaiming (\(reclaimed))") { count("Owner after reclaim.") == 1 }
        try await idle()
        try expect(prompts.count == 3, "\(kind): exactly three prompts may reach the runner, got \(prompts)")
        print("PASS handoff seam: \(kind.rawValue) — the new controller's prompt reaches the runner once, the former owner's input is refused while handed over, and a prompt the reclaim overtook reads refused with no write")
    }

    /// The collaboration service's handoff rules, scripted. Refusals are the
    /// HTTP errors `CollaborationAPI` raises, so the controllers react as they
    /// do to the real service.
    private actor HandoffService {
        let document: SharedArea.Document
        let owner: Collaboration.Identity
        var generation: UUID?
        var revision: UInt64 = 0
        var controller: SharedArea.ID<SharedArea.Person>
        var offer: Collaboration.AgentHandoffOffer?
        var operations: [UUID: Collaboration.AgentControlState] = [:]
        var receipts: [UUID: Collaboration.AgentDispatchReceipt] = [:]
        var order: [UUID] = []
        init(document: SharedArea.Document, owner: Collaboration.Identity) {
            self.document = document; self.owner = owner; controller = owner.person
        }
        nonisolated func view(_ caller: Collaboration.Identity) -> View { View(service: self, caller: caller) }
        private var item: SharedArea.Item { document.items.first { $0.kind == .agentObservation }! }
        private func forbidden() -> CollaborationClientError { .server(status: 403, code: "forbidden") }
        private func conflict() -> CollaborationClientError { .server(status: 409, code: "conflict") }
        func state(_ caller: Collaboration.Identity) -> Collaboration.State {
            .init(scope: .init(area: document.id, epoch: 1, role: caller == owner ? .owner : .editor), document: document)
        }
        func control() throws -> Collaboration.AgentControlState {
            guard let generation else { throw CollaborationClientError.server(status: 404, code: "unavailable") }
            return .init(area: document.id, object: item.id, source: item.source!, hostGeneration: generation,
                         epoch: 1, revision: revision, controller: controller, offer: offer)
        }
        func register(_ caller: Collaboration.Identity, _ request: Collaboration.AgentHostRegistration) throws -> Collaboration.AgentControlState {
            guard caller == owner else { throw forbidden() }
            if generation != request.generation { generation = request.generation; revision += 1; controller = owner.person; offer = nil }
            return try control()
        }
        func change(_ caller: Collaboration.Identity, _ request: Collaboration.AgentControlMutation) throws -> Collaboration.AgentControlState {
            if let done = operations[request.id] { return done }
            guard request.epoch == 1, request.hostGeneration == generation, request.expectedRevision == revision else { throw conflict() }
            switch request.action {
            case .offer(let next):
                guard caller.person == owner.person, next.recipient != caller.person else { throw forbidden() }
                offer = next
            case .accept(let id):
                guard let offer, offer.id == id, offer.recipient == caller.person else { throw forbidden() }
                controller = caller.person; self.offer = nil
            case .reclaim:
                guard caller.person == owner.person else { throw forbidden() }
                controller = owner.person; offer = nil
            }
            revision += 1
            let result = try control(); operations[request.id] = result; return result
        }
        func send(_ caller: Collaboration.Identity, _ request: Collaboration.AgentPromptRequest) throws -> Collaboration.AgentDispatchReceipt {
            if let existing = receipts[request.id] {
                guard existing.command.requester == caller, existing.command.text == request.text else { throw conflict() }
                return existing
            }
            guard request.epoch == 1, request.hostGeneration == generation, request.controlRevision == revision else { throw conflict() }
            guard controller == caller.person else { throw forbidden() }
            guard let context = document.contexts.last(where: { $0.id == request.contextRevision }), let generation else { throw conflict() }
            let command = Collaboration.AgentDispatchCommand(id: request.id, area: document.id, object: item.id, source: item.source!,
                requester: caller, epoch: 1, controlRevision: revision, hostGeneration: generation, context: context,
                text: request.text, mode: request.mode)
            let receipt = Collaboration.AgentDispatchReceipt(command: command, phase: .queued)
            receipts[request.id] = receipt; order.append(request.id); return receipt
        }
        func receipt(_ caller: Collaboration.Identity, _ id: UUID) throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id], receipt.command.requester.person == caller.person || caller.person == owner.person else { throw forbidden() }
            return receipt
        }
        private func authorized(_ command: Collaboration.AgentDispatchCommand) -> Bool {
            controller == command.requester.person && revision == command.controlRevision && generation == command.hostGeneration
        }
        func pending(_ caller: Collaboration.Identity) throws -> [Collaboration.AgentDispatchReceipt] {
            guard caller == owner else { throw forbidden() }
            var result: [Collaboration.AgentDispatchReceipt] = []
            for id in order {
                guard let receipt = receipts[id], !receipt.phase.isFinal else { continue }
                if receipt.phase != .dispatching && !authorized(receipt.command) {
                    receipts[id] = .init(command: receipt.command, phase: .refused, claimID: receipt.claimID); continue
                }
                result.append(receipt)
            }
            return result
        }
        func claim(_ id: UUID, _ request: Collaboration.AgentHostClaim, admit: Bool) throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id], request.hostGeneration == receipt.command.hostGeneration else { throw forbidden() }
            if let existing = receipt.claimID, existing != request.claimID { throw conflict() }
            if receipt.phase.isFinal {
                if admit, receipt.phase == .accepted, receipt.command.mode == .queue, !authorized(receipt.command) { throw forbidden() }
                return receipt
            }
            guard authorized(receipt.command) else { throw forbidden() }
            if admit { guard receipt.claimID == request.claimID, receipt.phase == .claimed || receipt.phase == .dispatching else { throw forbidden() } }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command,
                phase: admit || receipt.phase == .dispatching ? .dispatching : .claimed, claimID: request.claimID)
            receipts[id] = next; return next
        }
        func finish(_ id: UUID, _ outcome: Collaboration.AgentHostOutcome) throws -> Collaboration.AgentDispatchReceipt {
            guard outcome.phase.isFinal, let receipt = receipts[id], receipt.claimID == outcome.claim.claimID else { throw forbidden() }
            if receipt.phase.isFinal { guard receipt.phase == outcome.phase else { throw conflict() }; return receipt }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command, phase: outcome.phase, claimID: receipt.claimID)
            receipts[id] = next; return next
        }

        struct View: SharedAgentHandoffTransport {
            let service: HandoffService
            let caller: Collaboration.Identity
            func state() async throws -> Collaboration.State { await service.state(caller) }
            func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await service.register(caller, request) }
            func control(object: UUID) async throws -> Collaboration.AgentControlState { try await service.control() }
            func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { try await service.change(caller, request) }
            func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await service.send(caller, request) }
            func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await service.receipt(caller, id) }
            func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await service.pending(caller) }
            func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await service.claim(id, request, admit: false) }
            func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await service.claim(id, request, admit: true) }
            func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { try await service.finish(id, outcome) }
        }
    }
}
