import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// Endorsements, concurrent agreement drafts and @mention discussion through
/// two scenes mounted by the production entry. The authority runs the real
/// reducer; the service's own authoring rules are witnessed over localhost HTTP
/// in ContinuumRevivedCollaborationChecks.
@MainActor
enum SharedAreaAgreementSceneChecks {
    struct Failure: Error { let message: String }

    static func run(mount: SharedAreaSceneChecks.Mount, executorCount: @MainActor () -> Int) async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).appendingPathComponent("array-agreement-scene-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let discussion = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let first = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.person,
            text: "Instructions for our agents: keep changes inside the parser module.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 40, y: 40, width: 300, height: 220))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 380, y: 40, width: 420, height: 220))),
            .context(first)]))
        let authority = Authority(document: document, owner: a.person, member: b.person)
        let modelA = try controller(root: root.appendingPathComponent("a"), identity: a, document: document, authority: authority)
        let modelB = try controller(root: root.appendingPathComponent("b"), identity: b, document: document, authority: authority)
        let hostA = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760)), hostB = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let executorsBefore = executorCount()
        let sceneA = try mount(modelA, a.person, hostA), sceneB = try mount(modelB, b.person, hostB)
        await modelA.open(); await modelB.open()
        try expect(modelA.status == .connected && modelB.status == .connected, "both mounted scenes connect")
        try sceneA.selectObject(agreement.id); try sceneB.selectObject(agreement.id)
        hostA.layoutSubtreeIfNeeded(); hostB.layoutSubtreeIfNeeded()
        let panelA = sceneA.agreementPanel, panelB = sceneB.agreementPanel
        try expect(!panelB.isHidden && panelB.frame.height > 0 && panelB.summaryText == "Revision 1 · not endorsed yet" && panelB.canEndorse,
            "selecting an agreement shows its current revision with an enabled Endorse control")
        try expect(panelB.guidanceText.contains("instructions") && panelB.guidanceText.contains("does not enforce")
            && !panelB.guidanceText.lowercased().contains("restricted"),
            "agreement copy reads as instructions to agents, not an enforced restriction")

        // Endorse through the actual control.
        try click("Endorse", in: panelB)
        try await eventually("A shows B's endorsement") { panelA.summaryText == "Revision 1 · endorsed by 1 teammate" }
        try await eventually("B shows its own endorsement") { panelB.summaryText == "Revision 1 · endorsed by you" && !panelB.canEndorse }
        try expect(modelA.document?.endorsements(of: first.id).map(\.person) == [b.person],
            "the Endorse control records the signed-in person against the displayed revision")

        // Both edit revision 1; A saves first.
        sceneA.setDraftText("A's draft: agents may also touch the lexer.")
        sceneB.setDraftText("B's draft: agents must ask before touching tests.")
        await sceneA.submitDraft()
        try await eventually("B receives A's revision") { modelB.document?.currentRevision(of: agreement.id)?.text == "A's draft: agents may also touch the lexer." }
        let second = modelB.document!.currentRevision(of: agreement.id)!
        try expect(panelB.summaryText == "Revision 2 · not endorsed yet" && panelB.canEndorse,
            "B's endorsement of revision 1 is not shown on revision 2")
        await sceneB.submitDraft()
        try expect(modelB.document?.currentRevision(of: agreement.id) == second
            && sceneB.draftText == "B's draft: agents must ask before touching tests."
            && modelB.drafts.contains(where: { $0.text == "B's draft: agents must ask before touching tests." && $0.basedOn == first.id }),
            "B's save against revision 1 conflicts, leaves A's revision current and keeps B's draft")
        try expect(panelB.canRebase && panelB.noticeText.contains("earlier revision"), "the scene offers a deliberate rebase of the stale draft")
        try click("Rebase draft", in: panelB)
        try expect(!panelB.canRebase && modelB.drafts.contains(where: { $0.basedOn == second.id && $0.text == "B's draft: agents must ask before touching tests." })
            && modelB.document?.revision == 3, "rebasing pins B's exact text to revision 2 and sends nothing")
        await sceneB.submitDraft()
        try await eventually("A receives B's revision") { modelA.document?.contexts.count == 3 }
        try expect(modelA.document?.contexts.map(\.text) == [first.text, "A's draft: agents may also touch the lexer.", "B's draft: agents must ask before touching tests."]
            && modelA.document?.currentRevision(of: agreement.id)?.parent == second.id,
            "B's resubmission lands on top of A's revision; both drafts survive in history")
        try await eventually("A's panel follows revision 3") { panelA.summaryText == "Revision 3 · not endorsed yet" }
        try expect(true, "a new revision starts with zero endorsements in the mounted scene")

        // @mentions in human discussion are just discussion.
        try sceneA.selectObject(discussion.id); try sceneB.selectObject(discussion.id)
        try expect(panelA.isHidden, "the endorsement strip is shown only for an agreement")
        sceneA.setDraftText("@Builder please implement the parser now.")
        await sceneA.submitDraft()
        try await eventually("B sees A's mention") { modelB.document?.posts.last?.text == "@Builder please implement the parser now." }
        sceneB.setDraftText("Agent: run the full test suite and push.")
        await sceneB.submitDraft()
        try await eventually("A sees B's agent-addressed post") { modelA.document?.posts.count == 2 }
        try expect(executorCount() == executorsBefore, "endorsing, revising and @mention discussion construct no executor and start no agent")

        try sceneB.selectObject(agreement.id)
        sceneB.setDraftText("A private follow-up draft")
        try sceneB.prepareToClose()
        try await renderAppearances(scene: sceneB, host: hostB)
        sceneA.unmount(); sceneB.unmount(); await modelA.close(); await modelB.close()
        print("Shared agreement scene checks passed: Endorse control on the current revision, conflict and deliberate rebase, instruction copy and zero executors from @mention discussion. Scripted authority runs the real reducer.")
    }

    /// Renders offscreen in both appearances; never orders a window front.
    private static func renderAppearances(scene: SharedAreaSceneView, host: NSView) async throws {
        let directory = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        var colours: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "no bitmap for \(name.rawValue)") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let text = scene.agreementPanel.summaryColor?.usingColorSpace(.deviceRGB) else { throw Failure(message: "summary colour unresolved") }
            colours.append(text)
            if let directory, let png = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("agreement-\(name == .aqua ? "light" : "dark").png"))
            }
        }
        host.appearance = nil
        try expect(colours[0].brightnessComponent < colours[1].brightnessComponent,
            "the agreement strip re-resolves its token text colour for light and dark offscreen renders")
    }

    private static func click(_ title: String, in panel: SharedAreaAgreementView) throws {
        guard let button = panel.subviews.compactMap({ $0 as? ComposerActionButton }).first(where: {
            !$0.isHidden && $0.presentation.title.hasPrefix(title) && $0.presentation.isEnabled
            && $0.isEnabled
        }), let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        else { throw Failure(message: "no enabled \(title) control") }
        // The control's own keyboard activation path, as a focused Return press.
        button.keyDown(with: returnKey)
    }
    private static func controller(root: URL, identity: Collaboration.Identity, document: SharedArea.Document, authority: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-agreement.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-agreement-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint, person: identity.person, area: document.id)
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
        print("PASS shared agreement scene: \(message)")
    }
    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: message)
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:]
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
    private actor Authority {
        var document: SharedArea.Document
        let owner: SharedArea.ID<SharedArea.Person>
        let members: Set<SharedArea.ID<SharedArea.Person>>
        var connections: [UUID: (Collaboration.Identity, Connection)] = [:]
        init(document: SharedArea.Document, owner: SharedArea.ID<SharedArea.Person>, member: SharedArea.ID<SharedArea.Person>) {
            self.document = document; self.owner = owner; members = [owner, member]
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
            guard members.contains(identity.person) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(scope: .init(area: document.id, epoch: 1, role: identity.person == owner ? .owner : .editor), document: document)
        }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try state(identity)
            let connection = Connection(); connections[identity.device] = (identity, connection)
            return connection
        }
        func apply(_ mutation: Collaboration.Mutation, identity: Collaboration.Identity) async throws -> Collaboration.Receipt {
            _ = try state(identity)
            for edit in mutation.command.edits {
                switch edit {
                case .post(let post) where post.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                case .context(let context) where context.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                case .endorse(let endorsement) where endorsement.person != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                default: break
                }
            }
            let receipt: Collaboration.Receipt
            do {
                switch try document.apply(mutation.command) {
                case .applied(let revision): receipt = .init(revision: revision, duplicate: false)
                case .duplicate(let revision): receipt = .init(revision: revision, duplicate: true)
                }
            } catch SharedArea.Failure.conflict { throw CollaborationClientError.server(status: 409, code: "revisionConflict") }
            for (identity, connection) in connections.values { await connection.emit(.connected(try .init(state: state(identity)))) }
            return receipt
        }
    }
    private struct Transport: SharedAreaControllerTransport {
        let identityValue: Collaboration.Identity
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { try await authority.state(identityValue) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await authority.connection(identityValue) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await authority.apply(mutation, identity: identityValue) }
    }
}
