import AppKit
import ContinuumRevivedAgentUI
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Full access (`.plans/105` round 2), per managed harness. Whoever a share
/// admits as an editor prompts the owner's agent, which runs on the owner's Mac
/// under the owner's CLI login. Everything that acts is production:
///
/// - the teammate types into `SharedAgentLiveView`'s real `AgentComposerView`
///   and presses its real Send, which submits through the teammate's
///   `SharedAgentHandoffController`;
/// - the owner's `SharedAreaHandoffCoordinator` admits and dispatches into
///   `AgentSupervisor` and its real `ClaudeAgentRunner` / `CodexAgentRunner` /
///   `PiRpcAgentRunner` against the recording `AgentSteeringQAFakes`;
/// - `SharedAgentProjector` carries the agent back to the teammate's view, and
///   the owner's own `ManagedAgentTileNSView` shows who sent the last prompt.
///
/// Only the collaboration service is scripted, with `CollaborationStore`'s
/// full-access rules: membership and capability admit a prompt, removal bumps
/// the epoch and refuses its queued work. Those rules are witnessed over real
/// HTTP in `CollaborationHandoffChecks`.
///
/// No managed runner opens a provider approval today (Claude runs with
/// bypassed permissions, Codex declines, Pi has none), so the approval is
/// opened at the supervisor's own event seam on the live runner's turn.
@MainActor
enum SharedAgentFullAccessChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private typealias P = Collaboration.AgentProjection

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: "full access: " + label) }
        print("PASS full access: \(label)")
    }
    private static func eventually(_ label: @autoclosure () -> String, timeout: TimeInterval = 15,
                                   _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "full access: timeout: " + label())
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
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let (harness, model): (AgentHarness, String)
            switch kind {
            case .claude:
                AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
                (harness, model) = (.claudeCode, AgentCatalogQAFixture.claude.seedModel ?? "")
            case .codex:
                AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
                (harness, model) = (.codex, "openai-codex/gpt-5.6-sol")
            case .pi:
                AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
                (harness, model) = (.pi, AgentCatalogQAFixture.pi[0])
            }
            let root = URL(fileURLWithPath: support).appendingPathComponent("full-access-\(kind.rawValue)-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            setenv("PATH", "\(root.appendingPathComponent("bin").path):\(originalPath)", 1)
            try await run(kind, harness: harness, model: model, root: root)
        }
        print("PASS full access: Claude Code, Codex and Pi — a teammate's prompt reaches the owner's runner once, concurrent prompts run in arrival order, both sides name who sent the last prompt, approvals stay on the owner's Mac, and a removed person's prompt is refused")
    }

    private static func run(_ kind: AgentSteeringQAFakes.Harness, harness: AgentHarness, model modelID: String, root: URL) async throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(kind, in: bin)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        let project = UUID(), tileID = UUID()
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: modelID,
                                     thinking: "low", projectId: project, tileId: tileID)

        // The owner's own tile, as it sits on Dylan's canvas.
        let ownerTile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "full-access-owner",
            frame: TileFrame(x: 0, y: 0, width: 900, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        ownerTile.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        ownerTile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("tile-drafts"), debounceInterval: 60),
            promptHistory: AgentPromptHistory())
        ownerTile.attach(agentID: agent, supervisor: supervisor)

        let dylan = Collaboration.Identity(person: .init(), device: UUID())
        let sam = Collaboration.Identity(person: .init(), device: UUID())
        let priya = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: dylan.person, host: host, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 420, height: 420))),
        ]))
        let binding = SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: host,
            projectID: project, agentID: agent)
        let service = Service(document: document, owner: dylan, members: [dylan.person: .owner, sam.person: .editor, priya.person: .editor],
                              names: [dylan.person: "Dylan", sam.person: "Sam", priya.person: "Priya"])
        let ownerModel = try SharedAgentHandoffController(identity: dylan, transport: service.view(dylan),
            directory: root.appendingPathComponent("dylan-area", isDirectory: true))
        let samModel = try SharedAgentHandoffController(identity: sam, transport: service.view(sam),
            directory: root.appendingPathComponent("sam-area", isDirectory: true))
        let priyaModel = try SharedAgentHandoffController(identity: priya, transport: service.view(priya),
            directory: root.appendingPathComponent("priya-area", isDirectory: true))
        let coordinator = try SharedAreaHandoffCoordinator(model: ownerModel, supervisor: supervisor, bindings: { [binding] })
        defer { coordinator.stopHosting() }
        await coordinator.pollOnce()
        // The host session copies these from presence labels.
        supervisor.sharedParticipantNames = [sam.person: "Sam", priya.person: "Priya"]

        // The agent's projection, as the owner's host session publishes it.
        let sink = SharedAgentProjectorChecks.LogSink()
        let projector = try SharedAgentProjector(supervisor: supervisor, agent: agent, host: host, object: item.id,
                                                 generation: 1, owner: dylan.person, sink: sink)
        defer { projector.stop() }

        // Sam's and Priya's views of it, each over their own area controller.
        let rig = SharedAreaCheckRig.Authority(document: document, members: [(dylan, .owner), (sam, .editor), (priya, .editor)])
        func view(_ identity: Collaboration.Identity, _ label: String, _ model: SharedAgentHandoffController) async throws -> (SharedAgentLiveView, SharedAreaController) {
            let area = try SharedAreaCheckRig.controller(root: root.appendingPathComponent("\(label)-view"), identity: identity,
                                                         label: label, authority: rig, seed: (document, .editor))
            await area.open()
            let view = SharedAgentLiveView(controller: area, read: { _, cursor in
                await projector.flush()
                guard let log = sink.log else { throw Failure(description: "nothing published yet") }
                return log.read(after: cursor)
            })
            view.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
            view.prompter = model
            view.show(object: item.id, in: document)
            return (view, area)
        }
        let (samView, samArea) = try await view(sam, "Sam", samModel)
        let (priyaView, priyaArea) = try await view(priya, "Priya", priyaModel)
        defer { samView.stop(); priyaView.stop(); Task { await samArea.close(); await priyaArea.close() } }
        try await rig.setPresence(.init(identity: dylan, cursor: .init(x: 10, y: 10), viewport: nil,
                                        expiresAt: Date().addingTimeInterval(600), label: "Dylan"))

        var prompts: [String] {
            AgentSteeringQAFakes.receivedFrames(in: bin).compactMap { SharedAreaProviderDispatchChecks.promptFrame($0)?.text }
        }
        func written(_ text: String) -> Int { prompts.filter { $0.hasSuffix("\n---\n" + text) || $0 == text }.count }
        func idle() async throws { try await eventually("\(kind): the turn never settled") { !supervisor.isRunning(agent) } }
        func type(_ text: String, into view: SharedAgentLiveView) {
            view.composer.apply(AgentComposerDraft(text: text, selection: NSRange(location: (text as NSString).length, length: 0), revision: 1))
        }
        func phase(_ id: UUID?) async -> Collaboration.AgentDispatchPhase? {
            guard let id else { return nil }
            return await service.phase(id)
        }

        // 1. Sam types into the real composer and presses Send. The prompt
        //    reaches the owner's runner exactly once, with no handoff.
        try await eventually("\(kind): Sam's view never offered the composer") { samView.offersComposer }
        let first = "PLAIN Sam's first prompt for \(kind.rawValue)."
        type(first, into: samView); samView.qaPressSend()
        try await eventually("\(kind): Sam's prompt never queued: \(samModel.message)") {
            await phase(samModel.receipt?.command.id) == .queued && samView.composer.textView.string.isEmpty
        }
        try expect(samModel.receipt?.command.requester == sam && samModel.receipt?.command.context == nil
                   && samModel.control?.controller == dylan.person && written(first) == 0,
                   "\(kind): Sam's Send queues an attributed prompt with no handoff and no agreement revision, and nothing runs before the host polls")
        await coordinator.pollOnce()
        try await eventually("\(kind): Sam's prompt never reached the owner's runner: \(prompts)") { written(first) == 1 }
        try await idle()
        await coordinator.pollOnce(); await coordinator.pollOnce()
        let firstPhase = await phase(samModel.receipt?.command.id)
        try expect(written(first) == 1 && firstPhase == .accepted,
                   "\(kind): Sam's prompt reaches the owner's runner exactly once and reads accepted")
        // Attribution reads as a person, on the wire and as the agent's name.
        let delivered = prompts.first { $0.hasSuffix(first) } ?? ""
        let title = supervisor.records[agent]?.displayName ?? ""
        try expect(delivered.hasPrefix("From Sam\n") && !delivered.contains(sam.person.rawValue.uuidString)
                   && !delivered.contains("participant"),
                   "\(kind): the owner's agent reads the prompt as \"From Sam\", with no person id in the text (got \(delivered.debugDescription))")
        try expect(supervisor.records[agent]?.displayNameSource == .prompt && title != AgentRecord.defaultAgentName
                   && !title.contains("From") && !title.contains("participant") && !title.contains(sam.person.rawValue.uuidString.prefix(8))
                   && title.lowercased().contains("first prompt"),
                   "\(kind): an unnamed agent takes its name from what Sam typed, never the attribution (got \(title.debugDescription))")

        // 2. Who sent the last prompt, on both Macs.
        try await eventually("\(kind): the last-prompt label never reached either side (Sam: \(samView.lastPromptText), owner: \(ownerTile.qaLastPromptText ?? "none"))") {
            samView.lastPromptText == "You sent the last prompt"
                && ownerTile.qaLastPromptText?.hasPrefix("Sam sent the last prompt · ") == true
        }
        let ownerOwn = await supervisor.accept(.sendPrompt(.init("PLAIN Dylan's own prompt.")), for: agent)
        try await eventually("\(kind): the owner's own prompt never ran (\(ownerOwn))") { written("PLAIN Dylan's own prompt.") == 1 }
        try await idle()
        try await eventually("\(kind): the label never followed the owner's prompt (Sam: \(samView.lastPromptText), owner: \(ownerTile.qaLastPromptText ?? "none"))") {
            samView.lastPromptText.hasPrefix("Dylan sent the last prompt · ") && ownerTile.qaLastPromptText == "You sent the last prompt"
        }
        try expect(true, "\(kind): the composer rows say \"Sam sent the last prompt · time\" / \"You sent the last prompt\" on each Mac, and follow the owner's own prompt")

        // 3. Two prompts at once: the owner is mid-turn; Sam then Priya send.
        //    Both wait on the service, unclaimed, then run in arrival order.
        let busy = await supervisor.accept(.sendPrompt(.init("TOOL Dylan is mid-turn.")), for: agent)
        try await eventually("\(kind): the owner's turn never started (\(busy))") { supervisor.isRunning(agent) }
        let samSecond = "PLAIN Sam sends while the agent is busy.", priyaFirst = "PLAIN Priya sends right after Sam."
        type(samSecond, into: samView); samView.qaPressSend()
        try await eventually("\(kind): Sam's concurrent prompt never queued: \(samModel.message)") {
            samModel.receipt.map { $0.command.text == samSecond } == true && samView.composer.textView.string.isEmpty
        }
        type(priyaFirst, into: priyaView); priyaView.qaPressSend()
        try await eventually("\(kind): Priya's concurrent prompt never queued: \(priyaModel.message)") {
            priyaModel.receipt.map { $0.command.text == priyaFirst } == true && priyaView.composer.textView.string.isEmpty
        }
        let samID = samModel.receipt!.command.id, priyaID = priyaModel.receipt!.command.id
        await coordinator.pollOnce()
        let whileBusy = (await phase(samID), await phase(priyaID))
        try expect(whileBusy.0 == .queued && whileBusy.1 == .queued && written(samSecond) == 0 && written(priyaFirst) == 0,
                   "\(kind): prompts sent during the owner's turn wait on the service, neither dropped nor started, got \(whileBusy)")
        for _ in 0..<3 {
            try await idle()
            await coordinator.pollOnce()
            try await Task.sleep(for: .milliseconds(150))
        }
        try await eventually("\(kind): both concurrent prompts must run: \(prompts)") { written(samSecond) == 1 && written(priyaFirst) == 1 }
        try await idle(); await coordinator.pollOnce()
        let order = prompts
        let samAt = order.firstIndex { $0.hasSuffix(samSecond) }!, priyaAt = order.firstIndex { $0.hasSuffix(priyaFirst) }!
        let samPhase = await phase(samID), priyaPhase = await phase(priyaID)
        try expect(samAt < priyaAt && written(samSecond) == 1 && written(priyaFirst) == 1
                   && samPhase == .accepted && priyaPhase == .accepted,
                   "\(kind): two concurrent prompts both run once each, in arrival order (Sam, then Priya)")

        // 4. The agent stops to ask: only the owner's Mac shows the approval.
        //    Receipts answer at a relay's pace here, so a view that renders the
        //    projection before it has read its receipt is caught every time.
        await service.setReceiptDelay(.milliseconds(300))
        let asking = "SLOW Sam's prompt that needs an approval."
        type(asking, into: samView); samView.qaPressSend()
        try await eventually("\(kind): the approval prompt never queued: \(samModel.message)") {
            samModel.receipt.map { $0.command.text == asking } == true
        }
        await coordinator.pollOnce()
        // The agent asks in the same main-actor turn the host accepted Sam's
        // prompt, before Sam's view has read that acceptance: the moment the
        // gate once caught it showing "Waiting for Dylan" beside a stale
        // "Queued". The host binds the runner before the poll returns.
        guard supervisor.isRunning(agent) else { throw Failure(description: "full access: \(kind): the approval prompt never started") }
        supervisor.qaDeliver(.requestOpened(threadId: AgentSupervisor.threadId(for: agent), requestId: "full-access-approve-1",
                                            kind: .commandExecutionApproval), to: agent)
        func ownerHoldsApproval() -> Bool {
            if case .needsAction(let request)? = supervisor.turnSnapshot(for: agent)?.state { return request.kind == .approval }
            return false
        }
        try await eventually("\(kind): the owner's supervisor never showed the approval (\(String(describing: supervisor.turnSnapshot(for: agent)?.state)))") {
            ownerHoldsApproval()
        }
        let ownerSees = ownerHoldsApproval()
        try await eventually("\(kind): the approval prompt never reached the runner: \(prompts)") { written(asking) == 1 }
        try await eventually("\(kind): Sam's view never said it is waiting on Dylan (\(samView.statusText))") {
            samView.statusText.hasPrefix("Waiting for Dylan to approve")
        }
        let wire = String(decoding: sink.batches.reduce(Data(), +), as: UTF8.self)
        let crossed = wire.contains("full-access-approve-1") || wire.contains("commandExecutionApproval")
        let remoteRoute = P.RemoteControls(host: projector.log.head.capabilities, role: .editor).approveProviderRequest
            || Collaboration.Role.editor.allows(.approveProviderRequest)
        try expect(ownerSees && !crossed && !remoteRoute
                   && samView.offersComposer && samView.controlsText.contains("Approvals stay with its owner"),
                   "\(kind): an approval opens on the owner's supervisor only; the teammate reads \"Waiting for Dylan to approve\", no request crosses and no approve route exists"
                   + " (owner sees \(ownerSees), crossed \(crossed), remote route \(remoteRoute), composer \(samView.offersComposer),"
                   + " status \(samView.statusText.debugDescription), controls \(samView.controlsText.debugDescription))")
        supervisor.qaDeliver(.requestResolved(threadId: AgentSupervisor.threadId(for: agent), requestId: "full-access-approve-1", decision: "accept"), to: agent)
        _ = await supervisor.accept(.stop, for: agent)
        try await idle()
        await service.setReceiptDelay(.zero)
        await coordinator.pollOnce()

        // 5. Removing Priya stops her prompting at once. A prompt she sent
        //    before removal, still waiting behind a turn, is refused and reads
        //    refused in her view; nothing reaches the runner.
        let busyAgain = await supervisor.accept(.sendPrompt(.init("TOOL Dylan works while Priya is removed.")), for: agent)
        try await eventually("\(kind): the owner's second turn never started (\(busyAgain))") { supervisor.isRunning(agent) }
        let inFlight = "PLAIN Priya's prompt in flight at removal."
        type(inFlight, into: priyaView); priyaView.qaPressSend()
        try await eventually("\(kind): Priya's in-flight prompt never queued: \(priyaModel.message)") {
            priyaModel.receipt.map { $0.command.text == inFlight } == true
        }
        let inFlightID = priyaModel.receipt!.command.id
        await service.remove(priya.person)
        for _ in 0..<3 {
            try await idle()
            await coordinator.pollOnce()
            try await Task.sleep(for: .milliseconds(150))
        }
        try await eventually("\(kind): Priya's view never showed her prompt refused (\(priyaView.controlsText))") {
            priyaModel.receipt?.phase == .refused && priyaView.controlsText.hasPrefix("Refused")
        }
        try expect((await phase(inFlightID)) == .refused && written(inFlight) == 0,
                   "\(kind): a removed person's prompt in flight is refused before any write, and her view shows it refused")
        let after = "PLAIN Priya tries again after removal."
        type(after, into: priyaView); priyaView.qaPressSend()
        try await eventually("\(kind): Priya's send after removal was not refused: \(priyaModel.message)") {
            priyaView.controlsText.hasPrefix("Refused") && priyaView.composer.textView.string == after
        }
        await coordinator.pollOnce()
        try expect(written(after) == 0 && priyaModel.receipt?.command.id == inFlightID,
                   "\(kind): once removed, a new prompt is refused at the service, keeps its draft, and nothing runs")
        // Sam, still a member, keeps prompting across the epoch change.
        let samAfter = "PLAIN Sam after Priya left."
        type(samAfter, into: samView); samView.qaPressSend()
        try await eventually("\(kind): Sam's prompt after the removal never queued: \(samModel.message)") {
            samModel.receipt.map { $0.command.text == samAfter } == true
        }
        await coordinator.pollOnce()
        try await eventually("\(kind): Sam's prompt after the removal never ran") { written(samAfter) == 1 }
        try await idle()

        // Light and dark, offscreen, for the receipt.
        if let directory = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_EVIDENCE"] {
            type("Draft a gentler retry message", into: samView)
            // On the scene's own panel surface, as it is mounted.
            let backdrop = NSView(frame: samView.frame.insetBy(dx: -16, dy: -16))
            backdrop.wantsLayer = true
            samView.removeFromSuperview(); samView.frame.origin = .init(x: 16, y: 16); backdrop.addSubview(samView)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                backdrop.appearance = NSAppearance(named: name)
                backdrop.layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: backdrop)
                samView.needsLayout = true; backdrop.layoutSubtreeIfNeeded(); backdrop.displayIfNeeded()
                guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { continue }
                backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: url.appendingPathComponent("full-access-\(kind.rawValue)-\(name == .aqua ? "light" : "dark").png"))
            }
            backdrop.appearance = nil
            // In a window that is never shown, so appearance flips arrive the
            // way they do on the canvas.
            let window = NSWindow(contentRect: ownerTile.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = ownerTile
            defer { window.contentView = nil }
            let savedTheme = AppTheme.current
            defer { AppThemeController.apply(savedTheme) }
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                // The app's own theme switch, which gives a resting body back.
                AppThemeController.apply(name == .aqua ? .paper : .neutral)
                try await Task.sleep(for: .milliseconds(200))
                ownerTile.layoutSubtreeIfNeeded(); ownerTile.displayIfNeeded()
                let row = ownerTile.qaCompactStatusRow
                let expected = SurfaceToken.cardMessage.color.cgColor(for: row.effectiveTokenTheme)
                try expect(row.qaLastPromptFill.map { NSColor(cgColor: $0) == NSColor(cgColor: expected) } == true,
                           "\(kind): the owner's last-prompt pill paints its \(name == .aqua ? "light" : "dark") token fill (\(String(describing: row.qaLastPromptFill)) vs \(expected))")
                guard let bitmap = ownerTile.bitmapImageRepForCachingDisplay(in: ownerTile.bounds) else { continue }
                ownerTile.cacheDisplay(in: ownerTile.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("full-access-\(kind.rawValue)-owner-tile-\(name == .aqua ? "light" : "dark").png"))
            }
        }
        print("PASS full access: \(kind.rawValue) — teammate prompt once, concurrent prompts in order, last-prompt labels, owner-only approval, removed person refused")
    }

    /// `CollaborationStore`'s full-access rules, scripted: a member whose role
    /// may prompt is admitted; removal deactivates the person and bumps the
    /// epoch, so their queued work is refused at the host's next poll.
    private actor Service {
        let document: SharedArea.Document
        let owner: Collaboration.Identity
        var members: [SharedArea.ID<SharedArea.Person>: Collaboration.Role]
        /// `people.label`, which the store stamps into each command.
        let names: [SharedArea.ID<SharedArea.Person>: String]
        var epoch: Int64 = 1
        var controlEpoch: Int64 = 1
        var generation: UUID?
        var revision: UInt64 = 0
        var receipts: [UUID: Collaboration.AgentDispatchReceipt] = [:]
        var order: [UUID] = []
        init(document: SharedArea.Document, owner: Collaboration.Identity, members: [SharedArea.ID<SharedArea.Person>: Collaboration.Role],
             names: [SharedArea.ID<SharedArea.Person>: String]) {
            self.document = document; self.owner = owner; self.members = members; self.names = names
        }
        nonisolated func view(_ caller: Collaboration.Identity) -> View { View(service: self, caller: caller) }
        private var item: SharedArea.Item { document.items.first { $0.kind == .agentObservation }! }
        private func error(_ status: Int, _ code: String) -> CollaborationClientError { .server(status: status, code: code) }
        func phase(_ id: UUID) -> Collaboration.AgentDispatchPhase? { receipts[id]?.phase }
        /// How long a requester's receipt read takes, as over a real relay.
        var receiptDelay: Duration = .zero
        func setReceiptDelay(_ value: Duration) { receiptDelay = value }
        func remove(_ person: SharedArea.ID<SharedArea.Person>) { members[person] = nil; epoch += 1 }
        private func scope(_ caller: Collaboration.Identity) throws -> Collaboration.Scope {
            guard let role = members[caller.person] else { throw error(404, "unavailable") }
            return .init(area: document.id, epoch: epoch, role: role)
        }
        func state(_ caller: Collaboration.Identity) throws -> Collaboration.State { .init(scope: try scope(caller), document: document) }
        func control(_ caller: Collaboration.Identity) throws -> Collaboration.AgentControlState {
            _ = try scope(caller)
            guard let generation else { throw error(404, "unavailable") }
            return .init(area: document.id, object: item.id, source: item.source!, hostGeneration: generation,
                         epoch: controlEpoch, revision: revision, controller: owner.person)
        }
        func register(_ caller: Collaboration.Identity, _ request: Collaboration.AgentHostRegistration) throws -> Collaboration.AgentControlState {
            guard caller == owner else { throw error(403, "forbidden") }
            guard request.epoch == epoch else { throw error(409, "staleEpoch") }
            if generation != request.generation || controlEpoch != epoch {
                generation = request.generation; controlEpoch = epoch; revision += 1
            }
            return try control(caller)
        }
        func send(_ caller: Collaboration.Identity, _ request: Collaboration.AgentPromptRequest) throws -> Collaboration.AgentDispatchReceipt {
            if let existing = receipts[request.id] {
                guard existing.command.requester == caller, existing.command.text == request.text else { throw error(409, "changedIntent") }
                return existing
            }
            let current = try scope(caller)
            guard request.epoch == current.epoch else { throw error(409, "staleEpoch") }
            guard current.allows(.promptAgent) else { throw error(403, "forbidden") }
            guard let generation, request.hostGeneration == generation, request.contextRevision == nil else { throw error(409, "conflict") }
            let command = Collaboration.AgentDispatchCommand(id: request.id, area: document.id, object: item.id, source: item.source!,
                requester: caller, epoch: epoch, controlRevision: revision, hostGeneration: generation, context: nil,
                text: request.text, mode: request.mode, requesterName: names[caller.person])
            let receipt = Collaboration.AgentDispatchReceipt(command: command, phase: .queued)
            receipts[request.id] = receipt; order.append(request.id); return receipt
        }
        func receipt(_ caller: Collaboration.Identity, _ id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
            if receiptDelay > .zero, caller != owner { try await Task.sleep(for: receiptDelay) }
            _ = try scope(caller)
            guard let receipt = receipts[id], receipt.command.requester.person == caller.person || caller.person == owner.person else { throw error(403, "forbidden") }
            return receipt
        }
        private func authorized(_ command: Collaboration.AgentDispatchCommand) -> Bool {
            guard let role = members[command.requester.person], role.allows(.promptAgent) else { return false }
            return command.epoch == epoch && command.hostGeneration == generation
        }
        func pending(_ caller: Collaboration.Identity) throws -> [Collaboration.AgentDispatchReceipt] {
            guard caller == owner else { throw error(403, "forbidden") }
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
            guard let receipt = receipts[id], request.hostGeneration == receipt.command.hostGeneration else { throw error(403, "forbidden") }
            if let existing = receipt.claimID, existing != request.claimID { throw error(409, "conflict") }
            if receipt.phase.isFinal {
                if admit, receipt.phase == .accepted, receipt.command.mode == .queue, !authorized(receipt.command) { throw error(403, "forbidden") }
                return receipt
            }
            guard authorized(receipt.command) else { throw error(403, "forbidden") }
            if admit { guard receipt.claimID == request.claimID, receipt.phase == .claimed || receipt.phase == .dispatching else { throw error(403, "forbidden") } }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command,
                phase: admit || receipt.phase == .dispatching ? .dispatching : .claimed, claimID: request.claimID)
            receipts[id] = next; return next
        }
        func finish(_ id: UUID, _ outcome: Collaboration.AgentHostOutcome) throws -> Collaboration.AgentDispatchReceipt {
            guard outcome.phase.isFinal, let receipt = receipts[id], receipt.claimID == outcome.claim.claimID else { throw error(403, "forbidden") }
            if receipt.phase.isFinal { guard receipt.phase == outcome.phase else { throw error(409, "conflict") }; return receipt }
            let next = Collaboration.AgentDispatchReceipt(command: receipt.command, phase: outcome.phase, claimID: receipt.claimID)
            receipts[id] = next; return next
        }

        struct View: SharedAgentHandoffTransport {
            let service: Service
            let caller: Collaboration.Identity
            func state() async throws -> Collaboration.State { try await service.state(caller) }
            func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await service.register(caller, request) }
            func control(object: UUID) async throws -> Collaboration.AgentControlState { try await service.control(caller) }
            func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState {
                throw CollaborationClientError.server(status: 403, code: "forbidden")
            }
            func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await service.send(caller, request) }
            func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await service.receipt(caller, id) }
            func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await service.pending(caller) }
            func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await service.claim(id, request, admit: false) }
            func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await service.claim(id, request, admit: true) }
            func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { try await service.finish(id, outcome) }
        }
    }
}
