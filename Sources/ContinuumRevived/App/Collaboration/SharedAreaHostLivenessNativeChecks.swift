import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// Host liveness as a teammate sees it, through the production host session:
/// relay projections arrive on the controller's connection, the mounted scene
/// draws the card text, and the session forwards each change to an open
/// handoff dialog, which warns before Send now and still allows it.
@MainActor
enum SharedAreaHostLivenessNativeChecks {
    struct Failure: Error { let message: String }
    typealias Mount = @MainActor (SharedAreaController, SharedArea.ID<SharedArea.Person>, NSView) throws -> SharedAreaSceneView

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(message: label) }
        print("PASS host liveness native: \(label)")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func eventually(_ label: String, _ check: () -> Bool) async throws {
        for _ in 0..<300 { if check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "timeout \(label)")
    }

    static func run(mount: Mount, supervisor: AgentSupervisor) async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated support required") }
        let root = URL(fileURLWithPath: support).appendingPathComponent("host-liveness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let viewer = Collaboration.Identity(person: .init(), device: UUID())
        let owner = SharedArea.ID<SharedArea.Person>()
        let fixture = try Authority(viewer: viewer, owner: owner)
        let controller = try makeController(root: root.appendingPathComponent("controller"), identity: viewer, fixture: fixture)
        let handoffModel = try SharedAgentHandoffController(identity: viewer, transport: fixture, directory: root.appendingPathComponent("handoff"))
        let session = try SharedAreaHostSession(controller: controller, handoffModel: handoffModel, supervisor: supervisor)
        session.start()
        defer { session.stop() }
        try await eventually("connected") { controller.status == .connected }
        let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let scene = try mount(controller, viewer.person, host)
        defer { scene.unmount() }
        host.layoutSubtreeIfNeeded()
        let object = fixture.observation.id, hostID = fixture.observation.source!.host
        guard let reader = descendants(scene).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Selected shared entry" }) else {
            throw Failure(message: "missing shared entry reader")
        }
        try scene.selectObject(object)
        let now = Date()
        func liveness(_ state: Collaboration.HostLivenessState, reason: Collaboration.HostOfflineReason? = nil) -> Collaboration.HostLiveness {
            .init(host: hostID, generation: fixture.generation, state: state, lastSeen: now, staleAt: now.addingTimeInterval(30),
                offlineAt: now.addingTimeInterval(90), reason: reason)
        }
        let states: [(name: String, hosts: [Collaboration.HostLiveness], line: String)] = [
            ("not checked in", [], "Host has not checked in."),
            ("online", [liveness(.online)], "Host online."),
            ("not responding", [liveness(.stale)], "Host not responding. Its agents may still be running."),
            ("offline", [liveness(.offline, reason: .expired)], "Host offline. Execution is unavailable."),
        ]
        var digests: [NSAppearance.Name: Set<String>] = [:]
        for state in states {
            await fixture.publish(hosts: state.hosts)
            do { try await eventually("card shows \(state.name)") { host.layoutSubtreeIfNeeded(); return scene.renderedCardPreview(for: object)?.hasPrefix(state.line) == true } }
            catch { throw Failure(message: "card shows \(state.name): drew \(String(describing: scene.renderedCardPreview(for: object))), frame \(String(describing: scene.renderedFrame(for: object))), status \(controller.status), doc \(controller.document?.items.count ?? -1)") }
            try expect(reader.string.hasPrefix(state.line), "the selected agent's reader names the host as \(state.name)")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let probe = try UIProbe.render(.init(id: "collaboration.host-liveness.\(state.name).\(appearance.rawValue)",
                    size: .init(width: 1000, height: 760), appearance: appearance), make: { host })
                try expect(probe.view.effectiveAppearance.tokenTheme == (appearance == .aqua ? .light : .dark),
                    "the \(state.name) card renders in \(appearance == .aqua ? "light" : "dark")")
                digests[appearance, default: []].insert(probe.contentDigest)
                try save(probe.hostRep, "host-liveness-\(state.name.replacingOccurrences(of: " ", with: "-"))-\(appearance == .aqua ? "light" : "dark").png")
            }
        }
        try expect(digests.values.allSatisfy { $0.count == states.count },
            "each liveness state draws different card pixels in light and in dark")
        try expect(controller.isHostOnline(forObject: object) == false && controller.hostLiveness(forObject: object)?.state == .offline,
            "the controller exposes the published agent's host liveness")
        try expect(controller.document?.items.count == 2, "the shared workspace stays readable while the host is offline")

        // The production session opens the dialog and keeps its warning live.
        session.handoff.show(object: object)
        guard let dialog = NSApp.windows.compactMap({ $0.contentView as? SharedAreaHandoffView }).first(where: { $0.object == object }) else {
            throw Failure(message: "handoff dialog did not open")
        }
        defer { dialog.window?.close() }
        guard let editor = descendants(dialog).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Prompt for handed-off agent" }),
              let warning = descendants(dialog).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Host availability warning" }),
              let mode = descendants(dialog).compactMap({ $0 as? ChoiceButton }).first(where: { $0.items.contains(where: { $0.id == "queue" }) }) else {
            throw Failure(message: "missing dialog controls")
        }
        editor.string = "Apply the reviewed change."
        dialog.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        func sendLabel() -> String? {
            descendants(dialog).compactMap { $0 as? ComposerActionButton }
                .first(where: { ["Send reviewed prompt", "Send now anyway"].contains($0.accessibilityLabel() ?? "") })?.accessibilityLabel()
        }
        try await eventually("dialog control loaded") { handoffModel.control?.object == object }
        try expect(mode.selectedID == "send" && !warning.isHidden
            && warning.stringValue.hasPrefix("The agent's host is offline.") && sendLabel() == "Send now anyway",
            "Send now to an offline host shows a warning and relabels the action")
        await fixture.publish(hosts: [liveness(.online)])
        try await eventually("warning clears when online") { warning.isHidden && sendLabel() == "Send reviewed prompt" }
        print("PASS host liveness native: the open dialog clears its warning when the host comes back online")
        await fixture.publish(hosts: [liveness(.stale)])
        try await eventually("warning returns when stale") { !warning.isHidden && warning.stringValue.hasPrefix("The agent's host is not responding.") }
        print("PASS host liveness native: the open dialog warns again when the host stops responding")
        try expect(mode.chooseForQA(id: "queue") && warning.isHidden && sendLabel() == "Send reviewed prompt",
            "choosing Queue for next turn needs no warning")
        try expect(mode.chooseForQA(id: "send") && !warning.isHidden, "choosing Send now again restores the warning")
        dialog.layoutSubtreeIfNeeded()
        let clipped = descendants(dialog).compactMap { $0 as? ComposerActionButton }.flatMap { button in
            button.subviews.compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty && $0.frame.width < $0.fittingSize.width.rounded(.up) }
        }.map(\.stringValue)
        try expect(clipped.isEmpty && warning.frame.height > 0 && warning.frame.maxY <= dialog.bounds.height - 52,
            "the warning and Send now anyway fit above the action row (clipped: \(clipped))")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let probe = try UIProbe.render(.init(id: "collaboration.host-liveness.handoff.\(appearance.rawValue)",
                size: .init(width: 780, height: 820), appearance: appearance), make: { dialog })
            try expect(probe.view.effectiveAppearance.tokenTheme == (appearance == .aqua ? .light : .dark),
                "the send-now warning renders in \(appearance == .aqua ? "light" : "dark")")
            try save(probe.hostRep, "host-liveness-handoff-\(appearance == .aqua ? "light" : "dark").png")
        }
        guard let send = descendants(dialog).compactMap({ $0 as? ComposerActionButton }).first(where: { $0.accessibilityLabel() == "Send now anyway" }),
              send.isEnabled, send.sendAction(send.action, to: send.target) else { throw Failure(message: "Send now anyway is not actionable") }
        try await eventually("warned prompt sent") { fixture.promptsSent == 1 && !handoffModel.isBusy }
        try expect(fixture.lastMode == .send, "the warning does not block a deliberate Send now")
        try dialog.prepareToClose()
    }

    private static func save(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(message: "render encoding failed") }
        try png.write(to: directory.appendingPathComponent(name))
    }

    private static func makeController(root: URL, identity: Collaboration.Identity, fixture: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://host-liveness.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-host-liveness-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil,
            endpoint: endpoint, person: identity.person, area: fixture.state.document.id)
        try cache.save(.init(scope: cache.scope, document: fixture.state.document, observedMembershipEpoch: 1))
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in fixture })
    }

    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
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

    /// Scripted relay for one area: the viewer holds control of a teammate's
    /// published agent, and host liveness is whatever the check publishes.
    private final class Authority: SharedAreaControllerTransport, SharedAgentHandoffTransport, @unchecked Sendable {
        let viewer: Collaboration.Identity
        let observation: SharedArea.Item
        let context: SharedArea.Context
        let state: Collaboration.State
        let generation = UUID()
        private let lock = NSLock()
        private var connection: Connection?
        private var sent: [Collaboration.AgentPromptRequest] = []
        var promptsSent: Int { lock.withLock { sent.count } }
        var lastMode: Collaboration.AgentPromptMode? { lock.withLock { sent.last?.mode } }
        init(viewer: Collaboration.Identity, owner: SharedArea.ID<SharedArea.Person>) throws {
            self.viewer = viewer
            observation = .init(id: .init(), kind: .agentObservation, source: .init(owner: owner, host: .init(), binding: .init()))
            let agreement = SharedArea.Item(id: .init(), kind: .agreement)
            context = .init(id: .init(), object: agreement.id, parent: nil, author: owner, text: "Keep execution on the owning host.")
            var document = SharedArea.Document()
            _ = try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
                .admit(observation, .init(id: .init(), object: observation.id, rect: .init(x: 40, y: 40, width: 360, height: 260))),
                .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 440, y: 40, width: 360, height: 260))), .context(context)
            ]))
            state = .init(scope: .init(area: document.id, epoch: 1, role: .editor), document: document)
        }
        func publish(hosts: [Collaboration.HostLiveness]) async {
            var replica = try! CollaborationReplica(state: state)
            try! replica.receive(.init(scope: state.scope, after: state.document.revision, through: state.document.revision, events: [],
                nextCursor: state.document.revision, presenceVersion: UUID(), presence: [], serverTime: Date(), hosts: hosts))
            let current = lock.withLock { connection }
            await current?.emit(.connected(replica))
        }
        // Controller transport.
        func identity() async throws -> Collaboration.Identity { viewer }
        func state() async throws -> Collaboration.State { state }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection {
            let value = Connection()
            lock.withLock { connection = value }
            await value.emit(.connected(try CollaborationReplica(state: state)))
            return value
        }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { throw Failure(message: "read-only fixture") }
        // Handoff transport: the viewer already holds control.
        private var control: Collaboration.AgentControlState {
            .init(area: state.document.id, object: observation.id, source: observation.source!, hostGeneration: generation,
                epoch: 1, revision: 1, controller: viewer.person)
        }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { control }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { control }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { control }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt {
            lock.withLock { sent.append(request) }
            return .init(command: .init(id: request.id, area: state.document.id, object: observation.id, source: observation.source!,
                requester: viewer, epoch: 1, controlRevision: 1, hostGeneration: generation, context: context, text: request.text,
                mode: request.mode), phase: .queued)
        }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no receipt") }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { [] }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no host") }
    }
}
