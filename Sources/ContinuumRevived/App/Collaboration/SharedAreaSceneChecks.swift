import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

@MainActor
enum SharedAreaSceneChecks {
    struct Failure: Error { let message: String }
    typealias Mount = @MainActor (SharedAreaController, SharedArea.ID<SharedArea.Person>, NSView) throws -> SharedAreaSceneView

    /// The caller supplies the production AppDelegate mount. The check does
    /// not install a checks-only scene or claim that a scripted provider is real.
    static func run(mount: Mount, executorCount: @MainActor () -> Int = { 0 }) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-shared-scene-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture()
        let authority = Authority(document: fixture.document, owner: fixture.a.person, member: fixture.b.person)
        let state = try fixture.state(person: fixture.a.person)
        let focusWrites = WriteGate()
        let modelA = try controller(root: root.appendingPathComponent("a"), identity: fixture.a, state: state, authority: authority,
            fileOperations: focusWrites.operations())
        let modelB = try controller(root: root.appendingPathComponent("b"), identity: fixture.b,
            state: fixture.state(person: fixture.b.person), authority: authority)
        let sourceDirectory = root.appendingPathComponent("source/.array")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let files = ["canvas.json", "managed-session.json", "hidden-zone.json"].map { sourceDirectory.appendingPathComponent($0) }
        let originals = files.map { Data("source-state-private-\($0.lastPathComponent)".utf8) }
        for (file, bytes) in zip(files, originals) { try bytes.write(to: file) }
        let hostA = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let hostB = NSView(frame: .init(x: 0, y: 0, width: 1100, height: 800))
        let beforeExecutors = executorCount()
        let sceneA = try mount(modelA, fixture.a.person, hostA)
        let sceneB = try mount(modelB, fixture.b.person, hostB)
        hostA.layoutSubtreeIfNeeded(); hostB.layoutSubtreeIfNeeded()
        try expect(sceneA.mountCount == 1 && sceneB.mountCount == 1, "production entry mounts each shared scene exactly once")
        await modelA.open(); await modelB.open()
        try expect(modelA.status == .connected && modelB.status == .connected, "mounted independent identities acquire current authority")
        try sceneA.setCamera(.init(x: -80, y: -40, zoom: 0.8))
        try sceneB.setCamera(.init(x: -160, y: -100, zoom: 0.65))
        let cameraA = modelA.view, cameraB = modelB.view
        guard let aFrame = sceneA.renderedFrame(for: fixture.observation.id), let bFrame = sceneB.renderedFrame(for: fixture.observation.id) else {
            throw Failure(message: "shared observation has no actual visible frame")
        }
        let rect = fixture.observationPosition.rect
        try expect(close(aFrame.minX, (rect.x - cameraA.x) * cameraA.zoom)
            && close(aFrame.minY - 66, (rect.y - cameraA.y) * cameraA.zoom)
            && close(aFrame.width, rect.width * cameraA.zoom), "first native frame converts area geometry through its private camera exactly once")
        try expect(close(bFrame.minX, (rect.x - cameraB.x) * cameraB.zoom)
            && close(bFrame.minY - 66, (rect.y - cameraB.y) * cameraB.zoom)
            && close(bFrame.width, rect.width * cameraB.zoom), "second camera renders the same area rectangle at an independent origin and zoom")
        try sceneA.selectObject(fixture.discussion.id)
        sceneA.setDraftText("Private draft survives failed focus save")
        try sceneA.prepareToClose()
        focusWrites.failNext()
        var focusRefused = false
        do { try sceneA.selectObject(fixture.agreement.id) } catch { focusRefused = true }
        try expect(focusRefused && sceneA.selectedObject == fixture.discussion.id
            && sceneA.draftText == "Private draft survives failed focus save"
            && modelA.view.focusedObject == fixture.discussion.id,
            "failed private focus save preserves the previous logical target and its draft")
        sceneA.setDraftText("Human discussion from the mounted scene")
        await sceneA.submitDraft()
        try await eventually("mounted remote discussion update") { modelB.document?.posts.last?.text == "Human discussion from the mounted scene" }
        try sceneB.selectObject(fixture.discussion.id)
        try expect(sceneB.selectedEntryText == "Human discussion from the mounted scene", "native selected-entry reader displays accepted human discussion")
        try expect(modelA.view.x == cameraA.x && modelA.view.y == cameraA.y && modelB.view.x == cameraB.x && modelB.view.y == cameraB.y,
            "accepted remote discussion leaves both private cameras unchanged")
        try sceneA.selectObject(fixture.agreement.id)
        sceneA.setDraftText("Reviewed working agreement revision")
        await sceneA.submitDraft()
        try await eventually("mounted agreement revision") { modelB.document?.contexts.last?.text == "Reviewed working agreement revision" }
        try sceneB.selectObject(fixture.agreement.id)
        try expect(sceneB.selectedEntryText == "Reviewed working agreement revision", "native agreement editor creates and displays an immutable accepted revision")
        try sceneA.selectObject(fixture.discussion.id)
        sceneA.setDraftText("Old mount delivery with lost reply")
        let reply = ResponseGate()
        await authority.holdNextReply(reply)
        let oldSubmission = Task { await sceneA.submitDraft() }
        for _ in 0..<500 {
            if await reply.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await reply.entered
        try expect(entered, "scripted submission is held after admission before its response")
        sceneA.unmount(); await modelA.close()
        sceneA.mount(); await modelA.open()
        sceneA.setDraftText("New mount private draft")
        await reply.release()
        await oldSubmission.value
        sceneA.setDraftText("New mount remains editable after old response")
        try expect(sceneA.draftText == "New mount remains editable after old response",
            "late old-mount outcome cannot install uncertain-delivery state into a remounted editor")
        try sceneA.prepareToClose()
        try sceneA.selectObject(fixture.observation.id)
        try expect(sceneA.selectedEntryText.contains("publishing host") && sceneA.selectedEntryText.contains("not available"),
            "agent observation truthfully reports absent history and execution controls")
        try expect(executorCount() == beforeExecutors, "mount, selection and discussion do not change the supplied executor census")
        let sourceAfterEdits = try files.map { try Data(contentsOf: $0) }
        try expect(sourceAfterEdits == originals, "mounted shared interactions preserve every supplied source project file byte")
        try sceneB.selectObject(fixture.discussion.id)
        sceneB.setDraftText("Unsaved private draft retained when access is removed")
        await authority.remove(fixture.b.person)
        try await eventually("mounted removed client clears") { modelB.document == nil && sceneB.renderedFrame(for: fixture.observation.id) == nil }
        try expect(sceneB.selectedEntryText.isEmpty, "access loss clears the native shared entry reader as well as canvas objects")
        try sceneB.prepareToClose()
        try expect(modelB.drafts.contains(where: { $0.text == "Unsaved private draft retained when access is removed" }),
            "access removal and close flush preserve a draft still inside the input debounce")
        let previousMounts = sceneA.mountCount
        try sceneA.prepareToClose(); sceneA.unmount(); await modelA.close()
        try expect(sceneA.renderedFrame(for: fixture.observation.id) == nil, "unmount clears presentation while closing only the view subscription")
        sceneA.mount(); await modelA.open()
        try expect(modelA.status == .connected && sceneA.mountCount == previousMounts + 1 && sceneA.renderedFrame(for: fixture.observation.id) != nil,
            "remount restores a shared reference without executor construction")
        try expect(executorCount() == beforeExecutors, "access removal, close and remount preserve the executor census")
        try expect(try files.map { try Data(contentsOf: $0) } == originals, "native remount does not retidy or rewrite source zones")
        sceneA.unmount(); sceneB.unmount(); await modelA.close(); await modelB.close()
        try await runVisibleBudgetChecks(root: root, fixture: fixture, mount: mount)
        print("Shared native scene checks passed: supplied production mount, actual view frames, private cameras, human content, access removal and source preservation. Scripted transport; real-provider effects remain separate.")
    }

    /// The wrapper owns the disposable cache for exactly its view lifetime.
    /// Neither a Keychain adapter nor a network session is constructed.
    static func makeAppearanceFixture() throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-shared-scene-appearance-\(UUID())")
        let fixture = try Fixture()
        let authority = Authority(document: fixture.document, owner: fixture.a.person, member: fixture.b.person)
        let model = try controller(root: root, identity: fixture.a, state: fixture.state(person: fixture.a.person), authority: authority)
        let host = AppearanceHost(root: root)
        let scene = SharedAreaSceneView(controller: model, person: fixture.a.person)
        scene.frame = host.bounds; scene.autoresizingMask = [.width, .height]
        host.addSubview(scene); scene.mount(); host.layoutSubtreeIfNeeded()
        try scene.fitContent(); try scene.selectObject(fixture.discussion.id)
        scene.setDraftText("A private draft for the next discussion")
        try scene.prepareToClose()
        return host
    }

    private static func controller(root: URL, identity: Collaboration.Identity, state: Collaboration.State, authority: Authority,
                                   fileOperations: AtomicWriterFileOperations = .live) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-scene.example.test")!)
        let vault = MemoryVault(), credentials = CollaborationCredentialStore(vault: vault, bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-scene-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil,
            endpoint: endpoint, person: identity.person, area: state.document.id, fileOperations: fileOperations)
        try cache.save(.init(scope: cache.scope, document: state.document, observedMembershipEpoch: state.scope.epoch))
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
    private static func runVisibleBudgetChecks(root: URL, fixture: Fixture, mount: Mount) async throws {
        var document = SharedArea.Document()
        let items = (0..<130).map { _ in SharedArea.Item(id: .init(), kind: .discussion) }
        let edits = items.enumerated().map { index, item in
            SharedArea.Edit.admit(item, .init(id: .init(), object: item.id,
                rect: .init(x: Double(index % 13) * 40 + 10, y: Double(index / 13) * 40 + 10, width: 24, height: 24), z: index))
        }
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: edits))
        let authority = Authority(document: document, owner: fixture.a.person, member: fixture.b.person)
        let state = Collaboration.State(scope: .init(area: document.id, epoch: 1, role: .owner), document: document)
        let model = try controller(root: root.appendingPathComponent("visible-budget"), identity: fixture.a, state: state, authority: authority)
        let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let scene = try mount(model, fixture.a.person, host)
        host.layoutSubtreeIfNeeded()
        try expect(scene.renderedFrame(for: items[0].id) == nil && scene.renderedFrame(for: items[129].id) != nil,
            "bounded rendering keeps the frontmost 128 visible objects")
        try expect(scene.object(at: .init(x: 22, y: 88)) == nil,
            "an object omitted by the render budget cannot intercept pointer input")
        guard let front = scene.renderedFrame(for: items[129].id) else { throw Failure(message: "front object missing") }
        try expect(scene.object(at: .init(x: front.midX, y: front.midY)) == items[129].id,
            "rendered frames and pointer input use the same eligible visible objects")
        guard let canvas = scene.subviews.first(where: { $0.accessibilityLabel() == "Shared objects" }),
              let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48),
              let shiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                  windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else {
            throw Failure(message: "canvas keyboard input could not be constructed")
        }
        canvas.keyDown(with: tab)
        try expect(scene.selectedObject == items[2].id, "Tab selects the first actually rendered object")
        canvas.keyDown(with: shiftTab)
        try expect(scene.selectedObject == items[129].id, "Shift-Tab cycles backward through eligible visible objects only")
        scene.unmount(); await model.close()
    }
    private static func close(_ a: CGFloat, _ b: Double) -> Bool { abs(Double(a) - b) < 0.001 }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
        print("PASS shared scene: \(message)")
    }
    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: message)
    }
    private final class AppearanceHost: NSView {
        let root: URL
        init(root: URL) { self.root = root; super.init(frame: .init(x: 0, y: 0, width: 960, height: 680)) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    private struct Fixture {
        let a = Collaboration.Identity(person: .init(), device: UUID())
        let b = Collaboration.Identity(person: .init(), device: UUID())
        let observation: SharedArea.Item
        let observationPosition: SharedArea.Position
        let discussion = SharedArea.Item(id: .init(), kind: .discussion)
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let document: SharedArea.Document
        init() throws {
            observation = .init(id: .init(), kind: .agentObservation, source: .init(owner: a.person, host: .init(), binding: .init()))
            observationPosition = .init(id: .init(), object: observation.id, rect: .init(x: 40, y: 40, width: 300, height: 260))
            var document = SharedArea.Document()
            try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
                .admit(observation, observationPosition),
                .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 380, y: 40, width: 300, height: 260))),
                .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 40, y: 340, width: 640, height: 220))),
                .post(.init(id: .init(), object: discussion.id, author: a.person, text: "Coordinate the next change here, then send reviewed context to your own agent when that capability is available.")),
                .context(.init(id: .init(), object: agreement.id, parent: nil, author: a.person, text: "Keep each agent's execution on its owning host."))
            ]))
            self.document = document
        }
        func state(person: SharedArea.ID<SharedArea.Person>) throws -> Collaboration.State {
            .init(scope: .init(area: document.id, epoch: 1, role: person == a.person ? .owner : .editor), document: document)
        }
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private final class WriteGate: @unchecked Sendable {
        private let lock = NSLock()
        private var nextFails = false
        func failNext() { lock.withLock { nextFails = true } }
        func operations() -> AtomicWriterFileOperations {
            var operations = AtomicWriterFileOperations.live
            let write = operations.writeTemporary
            operations.writeTemporary = { [self] data, url in
                let fail = lock.withLock { let fail = nextFails; nextFails = false; return fail }
                if fail { throw Failure(message: "injected private focus write failure") }
                try write(data, url)
            }
            return operations
        }
    }
    private actor ResponseGate {
        private(set) var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
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
        var members: Set<SharedArea.ID<SharedArea.Person>>
        var epoch: Int64 = 1
        var connections: [UUID: (Collaboration.Identity, Connection)] = [:]
        var responseGate: ResponseGate?
        init(document: SharedArea.Document, owner: SharedArea.ID<SharedArea.Person>, member: SharedArea.ID<SharedArea.Person>) {
            self.document = document; self.owner = owner; members = [owner, member]
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
            guard members.contains(identity.person) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(scope: .init(area: document.id, epoch: epoch, role: identity.person == owner ? .owner : .editor), document: document)
        }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try state(identity)
            let connection = Connection(); connections[identity.device] = (identity, connection)
            return connection
        }
        func apply(_ mutation: Collaboration.Mutation, identity: Collaboration.Identity) async throws -> Collaboration.Receipt {
            let responseGate = responseGate; self.responseGate = nil
            let current = try state(identity)
            guard current.scope.epoch == mutation.epoch else { throw CollaborationClientError.server(status: 409, code: "staleEpoch") }
            for edit in mutation.command.edits {
                switch edit {
                case .post(let post) where post.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                case .context(let context) where context.author != identity.person: throw CollaborationClientError.server(status: 403, code: "forbidden")
                default: break
                }
            }
            let result = try document.apply(mutation.command)
            let receipt: Collaboration.Receipt
            switch result {
            case .applied(let revision): receipt = .init(revision: revision, duplicate: false)
            case .duplicate(let revision): receipt = .init(revision: revision, duplicate: true)
            }
            for (identity, connection) in connections.values where members.contains(identity.person) {
                await connection.emit(.connected(try .init(state: state(identity))))
            }
            if let responseGate { await responseGate.wait(); throw URLError(.networkConnectionLost) }
            return receipt
        }
        func holdNextReply(_ gate: ResponseGate) { responseGate = gate }
        func remove(_ person: SharedArea.ID<SharedArea.Person>) async {
            members.remove(person); epoch += 1
            for (identity, connection) in connections.values where identity.person == person { await connection.emit(.unavailable) }
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
