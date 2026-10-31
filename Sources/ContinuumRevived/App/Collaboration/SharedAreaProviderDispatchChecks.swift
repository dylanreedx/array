import Foundation
import SQLite3
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// COL-13: a teammate's reviewed prompt, dispatched through the owning host into
/// each managed harness's REAL runner. `AgentSupervisor.productionRunner` starts
/// `ClaudeAgentRunner`, `CodexAgentRunner` and `PiRpcAgentRunner` against the
/// reactive `AgentSteeringQAFakes` on PATH, which record every stdin line. The
/// host side is the production `SharedAreaHandoffCoordinator` (control gates,
/// journal, dispatcher). Only the collaboration service is scripted, refusing
/// the way the real one does (`forbidden`) for a stale host generation or a
/// requester whose membership was removed; the service's own refusals are
/// witnessed over real HTTP in the service suite.
///
/// The five states are told apart by what each one leaves behind:
/// requested (service receipt queued, nothing on the wire), host accepted
/// (receipt accepted), queued (accepted, held in Array's queue, nothing on the
/// wire), provider observed (the frame on the CLI's stdin), outcome unknown
/// (receipt uncertain after a crash, the frame written once and never again).
@MainActor
enum SharedAreaProviderDispatchChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: "provider dispatch: " + message) }
    }
    private static func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 12,
                                   _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "provider dispatch: timeout: " + message())
    }

    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated support required")
        }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let originalTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
        setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
        let savedCatalog = AgentHarness.allCases.map { AgentModelCatalog.shared.snapshot(for: $0) }
        defer {
            setenv("PATH", originalPath, 1)
            if let originalTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalTransport, 1) }
            else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
            for snapshot in savedCatalog { AgentModelCatalog.shared.resetForQA(snapshot: snapshot) }
        }
        // Handing the agent over, per harness, through both production controllers.
        for (kind, harness, model) in [(AgentSteeringQAFakes.Harness.claude, AgentHarness.claudeCode, AgentCatalogQAFixture.claude.seedModel ?? ""),
                                       (.codex, .codex, "openai-codex/gpt-5.6-sol"), (.pi, .pi, AgentCatalogQAFixture.pi[0])] {
            switch kind {
            case .claude: AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
            case .codex: AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
            case .pi: AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
            }
            let root = URL(fileURLWithPath: support).appendingPathComponent("handoff-seam-\(kind.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            setenv("PATH", "\(root.appendingPathComponent("bin").path):\(originalPath)", 1)
            try await SharedAreaHandoffSeamChecks.run(kind, harness: harness, model: model, root: root)
        }
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let root = URL(fileURLWithPath: support).appendingPathComponent("provider-dispatch-\(kind.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            setenv("PATH", "\(root.appendingPathComponent("bin").path):\(originalPath)", 1)
            try await run(kind, root: root)
        }
        print("PASS provider dispatch: Claude Code, Codex and Pi runners each received exactly the frozen reviewed context once, refused stale/removed authority before any write, ran prompts in arrival order across a busy turn, and reported a crash as outcome unknown with no second write")
    }

    private static func run(_ kind: AgentSteeringQAFakes.Harness, root: URL) async throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(kind, in: bin)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (harness, modelID): (AgentHarness, String)
        switch kind {
        case .claude:
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
            harness = .claudeCode; modelID = AgentCatalogQAFixture.claude.seedModel ?? ""
        case .codex:
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
            harness = .codex; modelID = "openai-codex/gpt-5.6-sol"
        case .pi:
            AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
            harness = .pi; modelID = AgentCatalogQAFixture.pi[0]
        }
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
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 300, height: 240))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 340, y: 0, width: 300, height: 240))),
        ]))
        // The reviewed context names host-looking paths. They must reach the
        // provider as the words a teammate wrote, never as attachments.
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: owner.person,
            text: "Agreed change for \(kind.rawValue): keep @/private/etc/hosts and file:///Users/teammate/Desktop/secret.png as text.")
        let binding = SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: host,
            projectID: project, agentID: agent)
        let authority = Authority(document: document, owner: owner.person)
        let model = try SharedAgentHandoffController(identity: owner, transport: authority,
            directory: root.appendingPathComponent("area", isDirectory: true))
        let coordinator = try SharedAreaHandoffCoordinator(model: model, supervisor: supervisor, bindings: { [binding] })
        defer { coordinator.stopHosting() }
        await coordinator.pollOnce()
        guard let generation = await authority.registered[item.id] else {
            throw Failure(description: "\(kind): the owning host never registered its generation")
        }
        func make(_ text: String, _ mode: Collaboration.AgentPromptMode = .send, generation stale: UUID? = nil) -> Collaboration.AgentDispatchCommand {
            .init(id: UUID(), area: document.id, object: item.id, source: item.source!, requester: teammate, epoch: 1,
                  controlRevision: 1, hostGeneration: stale ?? generation, context: context, text: text, mode: mode,
                  requesterName: "Teammate Tam")
        }
        var frames: [[String: Any]] { AgentSteeringQAFakes.receivedFrames(in: bin) }
        var prompts: [(text: String, attachments: Int)] { frames.compactMap { promptFrame($0) } }
        func written(_ command: Collaboration.AgentDispatchCommand) -> Int { prompts.filter { $0.text == command.promptText }.count }
        func phase(_ command: Collaboration.AgentDispatchCommand) async -> Collaboration.AgentDispatchPhase? {
            await authority.receipts[command.id]?.phase
        }
        func idle() async throws {
            try await eventually("\(kind): the turn never settled") { !supervisor.isRunning(agent) }
        }

        // 1. requested → host accepted → provider observed, with the frozen
        //    context and human attribution written verbatim, exactly once.
        let reviewed = make("Implement the reviewed change.")
        await authority.enqueue(reviewed)
        try expect(await phase(reviewed) == .queued && prompts.isEmpty,
                   "\(kind): a requested prompt must be on the service only, got \(String(describing: await phase(reviewed))) with \(prompts.count) frames")
        await coordinator.pollOnce()
        try expect(await phase(reviewed) == .accepted, "\(kind): the owning host must accept the reviewed prompt, got \(String(describing: await phase(reviewed)))")
        try await eventually("\(kind): the runner never received the reviewed prompt: \(prompts.map(\.text))") { written(reviewed) == 1 }
        try expect(reviewed.promptText.contains(context.text) && reviewed.promptText.contains("\nFrom Teammate Tam\n")
                   && !reviewed.promptText.contains(teammate.person.rawValue.uuidString)
                   && prompts.count == 1 && prompts[0].text == reviewed.promptText && prompts[0].attachments == 0,
                   "\(kind): the transport must carry exactly the frozen context and attribution as text, got \(prompts)")
        try await idle()

        // 2. A stale host generation is refused at the claim, before any write,
        //    and does not hold the next command behind it.
        let stale = make("Stale generation prompt.", generation: UUID())
        let next = make("Prompt after the stale one.")
        await authority.enqueue(stale); await authority.enqueue(next)
        await coordinator.pollOnce()
        try await eventually("\(kind): the command after a stale one never reached the runner") { written(next) == 1 }
        let stalePhaseValue = await phase(stale), nextPhaseValue = await phase(next)
        try expect(written(stale) == 0 && stalePhaseValue == .queued && nextPhaseValue == .accepted,
                   "\(kind): a stale generation must never reach the transport nor block later commands")
        try await idle()

        // 3. Membership removed after the claim: admission is refused before the
        //    provider call, so the outcome is a refusal, not an unknown.
        let revoked = make("Prompt from a removed member.")
        await authority.enqueue(revoked); await authority.revokeAtAdmission(revoked.id)
        await coordinator.pollOnce()
        let revokedPhaseValue = await phase(revoked)
        try expect(written(revoked) == 0 && revokedPhaseValue == .refused,
                   "\(kind): removed membership must refuse before any transport write, got \(String(describing: await phase(revoked))) / \(written(revoked)) writes")

        // 4. A busy turn: a send-now waits on the service, unclaimed, and the
        //    prompt behind it waits too (arrival order, full access). Once the
        //    turn ends the send-now runs; the queue-mode prompt behind it is
        //    host accepted and QUEUED, not yet observed, then drains after it.
        let seed = await supervisor.accept(.sendPrompt(.init("TOOL owner turn")), for: agent)
        try expect(seed == .accepted, "\(kind): the owner's own turn was refused: \(seed)")
        try await eventually("\(kind): the owner's turn never started") { supervisor.isRunning(agent) }
        let busySend = make("TOOL send now while busy.")
        let queued = make("Queue after this turn.", .queue)
        await authority.enqueue(busySend); await authority.enqueue(queued)
        await coordinator.pollOnce()
        let waitingSend = await phase(busySend), waitingQueue = await phase(queued)
        try expect(waitingSend == .queued && written(busySend) == 0 && waitingQueue == .queued && written(queued) == 0,
                   "\(kind): a send-now on a busy turn must wait unclaimed with the prompt behind it, got \(String(describing: waitingSend)) / \(String(describing: waitingQueue))")
        try await idle()
        await coordinator.pollOnce()
        try await eventually("\(kind): the waiting send-now never ran after the turn: \(prompts.map(\.text))") { written(busySend) == 1 }
        let ranPhase = await phase(busySend), heldPhase = await phase(queued)
        try expect(ranPhase == .accepted && heldPhase == .accepted && written(queued) == 0
                   && supervisor.queuedMessages(for: agent).contains { $0.text == queued.promptText },
                   "\(kind): a queued prompt must be accepted and held behind the running one, not observed by the provider yet")
        try await eventually("\(kind): the queued prompt never drained to the provider: \(prompts.map(\.text))") { written(queued) == 1 }
        let order = prompts.map(\.text)
        try expect(order.firstIndex(of: busySend.promptText)! < order.firstIndex(of: queued.promptText)!,
                   "\(kind): prompts must run in arrival order, got \(order)")
        try await idle()

        // 5. A dropped outcome report is recovered as accepted, never resent.
        let dropped = make("Prompt whose report is lost.")
        await authority.enqueue(dropped); await authority.dropNextFinish()
        await coordinator.pollOnce()
        try await eventually("\(kind): the dropped-report prompt never reached the runner") { written(dropped) == 1 }
        try await idle()
        try expect((await phase(dropped)) == .dispatching, "\(kind): a lost report must leave the receipt dispatching")
        await coordinator.pollOnce()
        try expect((await phase(dropped)) == .accepted && written(dropped) == 1,
                   "\(kind): a lost report must recover the accepted receipt without a second write")

        // 6. The host crashes after the provider write and before it records the
        //    outcome. A relaunched host reports outcome unknown; nothing resends.
        let journalFile = model.areaDirectory.appendingPathComponent("host-dispatch/agent-host-journal.sqlite")
        try sqlite(journalFile, "CREATE TRIGGER qa_crash BEFORE UPDATE OF phase ON handoff_attempts WHEN OLD.phase='attempting' BEGIN SELECT RAISE(ABORT,'qa crash'); END")
        let crashed = make("Prompt in flight at the crash.")
        await authority.enqueue(crashed)
        await coordinator.pollOnce()
        try await eventually("\(kind): the in-flight prompt never reached the runner") { written(crashed) == 1 }
        try expect((await phase(crashed)) == .dispatching, "\(kind): a crashed host must leave the receipt dispatching, got \(String(describing: await phase(crashed)))")
        try sqlite(journalFile, "DROP TRIGGER qa_crash")
        try await idle()
        await coordinator.pollOnce()
        let unresolvedPhaseValue = await phase(crashed)
        try expect(written(crashed) == 1 && unresolvedPhaseValue == .dispatching,
                   "\(kind): the same process must neither resend nor guess while its attempt is unresolved")
        let relaunched = SharedAgentHostDispatcher(identity: owner, transport: authority,
            journal: try SharedAgentHostJournal(directory: journalFile.deletingLastPathComponent()), bootID: UUID(),
            execute: { local, command in
                await supervisor.acceptSharedAgentPrompt(command, for: local.agentID ?? agent,
                    scope: model.areaDirectory.path + "/" + local.object.rawValue.uuidString)
            })
        await relaunched.pollOnce(bindings: [binding])
        try await Task.sleep(for: .milliseconds(300))
        try expect((await phase(crashed)) == .uncertain && written(crashed) == 1,
                   "\(kind): a relaunched host must report outcome unknown with zero second write, got \(String(describing: await phase(crashed))) / \(written(crashed)) writes")
        let total = prompts.count
        try expect(total == 7, "\(kind): exactly seven prompts may reach the runner (reviewed, next, owner, busy send, queued, dropped, crashed), got \(prompts.map(\.text))")
        print("PASS provider dispatch: \(kind.rawValue) runner transport carries the frozen context once; stale generation and removed membership write nothing; a busy turn holds later prompts in arrival order; queued is distinct from observed; a crash is outcome unknown with no resend")
    }

    /// The user prompt a fake recorded, and how many non-text parts rode with it.
    static func promptFrame(_ frame: [String: Any]) -> (text: String, attachments: Int)? {
        if frame["type"] as? String == "prompt", let text = frame["message"] as? String {
            return (text, (frame["images"] as? [Any])?.count ?? 0)
        }
        if frame["method"] as? String == "turn/start",
           let input = (frame["params"] as? [String: Any])?["input"] as? [[String: Any]] {
            let texts = input.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            return (texts.joined(), input.count - texts.count)
        }
        if frame["type"] as? String == "user", let message = frame["message"] as? [String: Any] {
            if let text = message["content"] as? String { return (text, 0) }
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                return (texts.joined(), parts.count - texts.count)
            }
        }
        return nil
    }

    private static func sqlite(_ file: URL, _ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw Failure(description: "cannot open the host journal") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw Failure(description: "host journal fault injection failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// The collaboration service, scripted. Claim and admission refuse with a
    /// thrown error, as `CollaborationStore` does, when the command's host
    /// generation is not the registered one or its requester was removed.
    private actor Authority: SharedAgentHandoffTransport {
        struct Forbidden: Error {}
        let document: SharedArea.Document
        let owner: SharedArea.ID<SharedArea.Person>
        var registered: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
        var receipts: [UUID: Collaboration.AgentDispatchReceipt] = [:]
        var order: [UUID] = []
        var revokedAtAdmission: Set<UUID> = []
        var dropFinish = false
        init(document: SharedArea.Document, owner: SharedArea.ID<SharedArea.Person>) { self.document = document; self.owner = owner }
        func enqueue(_ command: Collaboration.AgentDispatchCommand) {
            receipts[command.id] = .init(command: command, phase: .queued); order.append(command.id)
        }
        func revokeAtAdmission(_ id: UUID) { revokedAtAdmission.insert(id) }
        func dropNextFinish() { dropFinish = true }
        private func authorize(_ command: Collaboration.AgentDispatchCommand) throws {
            guard registered[command.object] == command.hostGeneration, !revokedAtAdmission.contains(command.id) else { throw Forbidden() }
        }
        func state() async throws -> Collaboration.State { .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document) }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState {
            registered[request.object] = request.generation
            return try await control(object: request.object.rawValue)
        }
        func control(object: UUID) async throws -> Collaboration.AgentControlState {
            guard let item = document.items.first(where: { $0.id.rawValue == object }), let source = item.source else { throw Forbidden() }
            return .init(area: document.id, object: item.id, source: source, hostGeneration: registered[item.id] ?? UUID(),
                         epoch: 1, revision: 1, controller: owner)
        }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Forbidden() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Forbidden() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id] else { throw Forbidden() }
            return receipt
        }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] {
            order.compactMap { receipts[$0] }.filter { !$0.phase.isFinal && $0.command.source.host.rawValue == host }
        }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id], request.hostGeneration == receipt.command.hostGeneration else { throw Forbidden() }
            if let existing = receipt.claimID, existing != request.claimID { throw Forbidden() }
            if receipt.phase.isFinal { return receipt }
            guard registered[receipt.command.object] == receipt.command.hostGeneration else { throw Forbidden() }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command,
                phase: receipt.phase == .dispatching ? .dispatching : .claimed, claimID: request.claimID)
            receipts[id] = next; return next
        }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
            guard let receipt = receipts[id], request.hostGeneration == receipt.command.hostGeneration else { throw Forbidden() }
            if let existing = receipt.claimID, existing != request.claimID { throw Forbidden() }
            if receipt.phase.isFinal {
                if receipt.phase == .accepted && receipt.command.mode == .queue { try authorize(receipt.command) }
                return receipt
            }
            try authorize(receipt.command)
            guard receipt.claimID == request.claimID, receipt.phase == .claimed || receipt.phase == .dispatching else { throw Forbidden() }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command, phase: .dispatching, claimID: request.claimID)
            receipts[id] = next; return next
        }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt {
            guard outcome.phase.isFinal, let receipt = receipts[id], receipt.claimID == outcome.claim.claimID,
                  receipt.command.hostGeneration == outcome.claim.hostGeneration else { throw Forbidden() }
            if receipt.phase.isFinal {
                guard receipt.phase == outcome.phase else { throw Forbidden() }
                return receipt
            }
            guard receipt.phase == .dispatching || (receipt.phase == .claimed && outcome.phase != .accepted) else { throw Forbidden() }
            if dropFinish {
                // The report never arrives: the receipt stays dispatching.
                dropFinish = false
                throw URLError(.networkConnectionLost)
            }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command, phase: outcome.phase, claimID: receipt.claimID)
            receipts[id] = next; return next
        }
    }
}
