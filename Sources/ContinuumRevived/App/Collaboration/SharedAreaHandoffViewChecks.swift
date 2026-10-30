import AppKit
import GRDB
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaHandoffViewChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(message: label) }
        print("PASS handoff UI: \(label)")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func control(_ label: String, in view: NSView) throws -> NSControl {
        guard let item = descendants(view).compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == label }) else {
            throw Failure(message: "missing control \(label)")
        }
        return item
    }
    private static func click(_ label: String, in view: NSView) throws {
        let item = try control(label, in: view)
        guard item.isEnabled, item.sendAction(item.action, to: item.target) else { throw Failure(message: "disabled or unwired control \(label)") }
    }
    private static func eventually(_ label: String, _ check: () async -> Bool) async throws {
        for _ in 0..<200 { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "timeout \(label)")
    }
    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated support required") }
        let root = URL(fileURLWithPath: support).appendingPathComponent("handoff-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let authority = try Authority(identity: identity)
        let model = try SharedAgentHandoffController(identity: identity, transport: authority, directory: root)
        let object = authority.object
        let context = authority.context
        let teammate = UUID()
        let saved = SharedAgentHandoffDraft(recipient: teammate.uuidString, text: "Please apply this reviewed revision.",
            context: context.id, mode: .queue)
        try model.saveDraft(saved, object: object)
        await model.refresh(object: object)
        let window = SharedAreaHandoffWindowController(model: model, object: object)
        let view = window.content
        defer { window.window.close() }
        guard let editor = descendants(view).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Prompt for handed-off agent" }),
              let recipient = try control("Handoff recipient collaboration ID", in: view) as? NSTextField else { throw Failure(message: "missing editable fields") }
        try expect(editor.string == saved.text && recipient.stringValue == saved.recipient,
            "reopening the native dialog restores private prompt and recipient fields")
        let mode = descendants(view).compactMap { $0 as? ChoiceButton }.first(where: { $0.items.contains(where: { $0.id == "queue" }) })
        let contextPicker = descendants(view).compactMap { $0 as? ChoiceButton }.first(where: { $0.items.contains(where: { $0.id == context.id.rawValue.uuidString }) })
        try expect(mode?.selectedID == "queue" && contextPicker?.selectedID == context.id.rawValue.uuidString,
            "reopening preserves exact context revision and prompt timing")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let probe = try UIProbe.render(.init(id: "collaboration.handoff.\(appearance.rawValue)", size: .init(width: 780, height: 820), appearance: appearance), make: { view })
            try expect(probe.view.effectiveAppearance.tokenTheme == (appearance == .aqua ? .light : .dark), "handoff controls render in \(appearance.rawValue)")
            if let destination = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let png = probe.hostRep.representation(using: .png, properties: [:]) else { throw Failure(message: "handoff render encoding failed") }
                try png.write(to: directory.appendingPathComponent("handoff-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        try click("Offer handoff", in: view)
        try await eventually("native offer") { await authority.offers == 1 && !model.isBusy }
        try expect(model.control?.offer?.recipient.rawValue == teammate,
            "native Offer uses the explicitly entered teammate identity")
        try click("Send reviewed prompt", in: view)
        try await eventually("native prompt") { await authority.prompts == 1 && !model.isBusy && editor.string.isEmpty }
        let sent = await authority.lastPrompt
        try expect(sent?.text == saved.text && sent?.contextRevision == context.id && sent?.mode == .queue,
            "native Send preserves reviewed text, exact immutable context and chosen timing")
        try view.prepareToClose()
        try expect(try model.draft(object: object).text.isEmpty,
            "acknowledged native prompt clears only its saved private draft")
        editor.string = "Send this second deliberate prompt."
        view.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        await authority.pauseNextPrompt()
        try click("Send reviewed prompt", in: view)
        try await eventually("paused prompt response") { await authority.responseIsPaused }
        editor.string = "A new private draft written while delivery is pending."
        view.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        await authority.releasePromptResponse()
        try await eventually("second native prompt") { await authority.prompts == 2 && !model.isBusy }
        try expect(editor.string == "A new private draft written while delivery is pending.",
            "a late acknowledgement preserves newer edits made while its prompt was in flight")
        editor.string = "An unsent private edit must survive a save refusal."
        view.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        let database = try DatabaseQueue(path: root.appendingPathComponent("agent-client-\(identity.device.uuidString).sqlite").path)
        try await database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_draft BEFORE UPDATE ON handoff_drafts BEGIN SELECT RAISE(ABORT,'injected draft save failure'); END")
        }
        do { try view.prepareToClose(); throw Failure(message: "failed save allowed close") }
        catch is DatabaseError { print("PASS handoff UI: failed close flush refuses before discarding the private draft") }
        try expect(editor.string == "An unsent private edit must survive a save refusal.", "failed private save keeps the complete editable draft")
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_draft") }
        try view.prepareToClose()
        let reopened = try SharedAgentHandoffController(identity: identity, transport: authority, directory: root)
        try expect(try reopened.draft(object: object).text == editor.string,
            "successful retry survives a new controller without another service prompt")
        try expect(await authority.prompts == 2, "private draft saves never dispatch additional agent work")
        try await AgentSupervisor.runSharedAgentDeferredControlChecks()
        try await checkStoppedCoordinator(root: root.appendingPathComponent("stopped-coordinators"))
        print("Shared area handoff UI checks passed: real controls, private draft recovery/save refusal, exact context/timing and light/dark renders; scripted authority, no executor or Keychain.")
    }

    private static func checkStoppedCoordinator(root: URL) async throws {
        let modelID = AgentCatalogQAFixture.pi[0]
        let previous = AgentModelCatalog.shared.snapshot(for: .pi)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
            models: [modelID], displayNames: [:], refreshedAt: Date()))
        defer { AgentModelCatalog.shared.resetForQA(snapshot: previous) }
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let authority = try Authority(identity: identity)
        let state = try await authority.state()
        let source = state.document.items.first(where: { $0.id == authority.object })!.source!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let agent = AgentID(rawValue: UUID()), project = UUID()
        var record = AgentRecord(id: agent, displayName: "Original source", harness: .pi, model: modelID,
            thinking: "medium", cwd: root.path, createdAt: Date(), lastActivityAt: Date())
        record.projectId = project
        try store.upsert(record)
        var factories = 0
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in factories += 1; return ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
        _ = supervisor.restore()
        let binding = SharedAreaLocalSourceBinding(object: authority.object, binding: source.binding, host: source.host,
            projectID: project, tileID: UUID(), agentID: agent)
        let model = try SharedAgentHandoffController(identity: identity, transport: authority, directory: root.appendingPathComponent("handoff"))
        let stopped = try SharedAreaHandoffCoordinator(model: model, supervisor: supervisor, bindings: { [binding] })
        await authority.pauseNextState()
        let oldPoll = Task { await stopped.pollOnce() }
        try await eventually("paused source-host snapshot") { await authority.stateResponseIsPaused }
        stopped.stopHosting()
        await authority.releaseStateResponse()
        await oldPoll.value
        let lateRegistrations = await authority.registrations, latePending = await authority.pendingRequests
        try expect(lateRegistrations == 0 && latePending == 0 && factories == 0,
            "a late snapshot after stop cannot reinstall host hooks, register or dispatch provider work")

        let active = try SharedAreaHandoffCoordinator(model: model, supervisor: supervisor, bindings: { [binding] })
        await active.pollOnce()
        await authority.pauseNextState()
        let oldInput = Task { await supervisor.accept(.sendPrompt(.init("This stale shared input must never execute.")), for: agent) }
        try await eventually("paused source-input admission") { await authority.stateResponseIsPaused }
        active.stopHosting()
        await authority.releaseStateResponse()
        let staleOutcome = await oldInput.value
        try expect(staleOutcome == .refused(.sharedAgentControlRequired) && factories == 0,
            "stopping during an awaited authority check fences the older intent before provider creation")
        try expect(await supervisor.accept(.sendPrompt(.init("A new deliberate private prompt after stopping.")), for: agent) == .accepted && factories == 1,
            "explicit stop removes only its hooks and permits a new deliberate private prompt")
    }

    private actor Authority: SharedAgentHandoffTransport {
        nonisolated let object: SharedArea.ID<SharedArea.Object>
        nonisolated let context: SharedArea.Context
        let identity: Collaboration.Identity
        var area: Collaboration.State
        var current: Collaboration.AgentControlState
        var offers = 0
        var prompts = 0
        var lastPrompt: Collaboration.AgentPromptRequest?
        var registrations = 0
        var pendingRequests = 0
        private var pausePrompt = false
        private var responseContinuation: CheckedContinuation<Void, Never>?
        private var pauseState = false
        private var stateContinuation: CheckedContinuation<Void, Never>?
        var stateResponseIsPaused: Bool { stateContinuation != nil }
        func pauseNextState() { pauseState = true }
        func releaseStateResponse() { stateContinuation?.resume(); stateContinuation = nil }
        var responseIsPaused: Bool { responseContinuation != nil }
        func pauseNextPrompt() { pausePrompt = true }
        func releasePromptResponse() { responseContinuation?.resume(); responseContinuation = nil }
        init(identity: Collaboration.Identity) throws {
            self.identity = identity
            let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: identity.person, host: .init(), binding: .init()))
            let agreement = SharedArea.Item(id: .init(), kind: .agreement)
            object = item.id
            context = .init(id: .init(), object: agreement.id, parent: nil, author: identity.person, text: "Only the reviewed module may change.")
            var document = SharedArea.Document()
            _ = try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
                .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 300, height: 200))),
                .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 350, y: 0, width: 300, height: 200))), .context(context)
            ]))
            area = .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document)
            current = .init(area: document.id, object: item.id, source: item.source!, hostGeneration: UUID(), epoch: 1, revision: 1, controller: identity.person)
        }
        func state() async throws -> Collaboration.State {
            if pauseState {
                pauseState = false
                await withCheckedContinuation { stateContinuation = $0 }
            }
            return area
        }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { registrations += 1; return current }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { current }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState {
            if case .offer(let offer) = request.action { offers += 1; current.offer = offer; current.revision += 1 }
            return current
        }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt {
            prompts += 1; lastPrompt = request
            if pausePrompt {
                pausePrompt = false
                await withCheckedContinuation { responseContinuation = $0 }
            }
            return receiptValue(request)
        }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
            guard let lastPrompt else { throw Failure(message: "missing prompt") }
            return receiptValue(lastPrompt)
        }
        private func receiptValue(_ request: Collaboration.AgentPromptRequest) -> Collaboration.AgentDispatchReceipt {
            .init(command: .init(id: request.id, area: area.document.id, object: current.object, source: current.source, requester: identity,
                epoch: 1, controlRevision: current.revision, hostGeneration: current.hostGeneration, context: context, text: request.text, mode: request.mode), phase: .queued)
        }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { pendingRequests += 1; return [] }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
    }
}
