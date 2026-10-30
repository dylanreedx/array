import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaGeometrySceneChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: message) }
        print("PASS native shared geometry: \(message)")
    }
    private static func eventually(_ label: String, _ value: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await value() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(description: "Timed out: \(label)")
    }
    static func run(mount: SharedAreaSceneChecks.Mount, executorCount: @MainActor () -> Int = { 0 }) async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(description: "geometry witness requires isolated app support") }
        let root = URL(fileURLWithPath: support).appendingPathComponent("geometry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Collaboration.Identity(person: .init(), device: UUID())
        let b = Collaboration.Identity(person: .init(), device: UUID())
        let viewer = Collaboration.Identity(person: .init(), device: UUID())
        let first = SharedArea.Item(id: .init(), kind: .discussion), second = SharedArea.Item(id: .init(), kind: .discussion)
        let p1 = SharedArea.Position(id: .init(), object: first.id, rect: .init(x: -300, y: -120, width: 240, height: 180), z: 1)
        let p2 = SharedArea.Position(id: .init(), object: second.id, rect: .init(x: 50, y: -80, width: 220, height: 200), z: 2)
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [.admit(first, p1), .admit(second, p2)]))
        let authority = Authority(document: document, owner: a, editor: b, viewer: viewer)
        let modelA = try controller(root: root.appendingPathComponent("a"), identity: a, authority: authority)
        let modelB = try controller(root: root.appendingPathComponent("b"), identity: b, authority: authority)
        let viewerModel = try controller(root: root.appendingPathComponent("viewer"), identity: viewer, authority: authority)
        let hostA = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let hostB = NSView(frame: .init(x: 0, y: 0, width: 1100, height: 820))
        let hostViewer = NSView(frame: hostA.frame)
        let sceneA = try mount(modelA, a.person, hostA), sceneB = try mount(modelB, b.person, hostB)
        let viewerScene = try mount(viewerModel, viewer.person, hostViewer)
        hostA.layoutSubtreeIfNeeded(); hostB.layoutSubtreeIfNeeded(); hostViewer.layoutSubtreeIfNeeded()
        await modelA.open(); await modelB.open(); await viewerModel.open()
        let cameraA = SharedAreaLocalView(x: -400, y: -250, zoom: 0.75)
        let cameraB = SharedAreaLocalView(x: -480, y: -340, zoom: 1.1)
        try sceneA.setCamera(cameraA); try sceneB.setCamera(cameraB); try viewerScene.setCamera(cameraA)
        let originalExecutors = executorCount()
        let source = root.appendingPathComponent("source/.array/canvas.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("private source canvas and managed ownership stay local".utf8)
        try sourceBytes.write(to: source)

        guard let frame = sceneA.renderedFrame(for: first.id) else { throw Failure(description: "mounted source card absent") }
        let start = NSPoint(x: frame.minX + 30, y: frame.minY + 24), end = NSPoint(x: start.x + 90, y: start.y + 60)
        let callsBefore = await authority.commands.count
        sceneA.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: start, in: sceneA))
        sceneA.areaCanvasView.mouseDragged(with: try pointer(.leftMouseDragged, point: end, in: sceneA))
        let moved = SharedArea.Rect(x: p1.rect.x + 120, y: p1.rect.y + 80, width: p1.rect.width, height: p1.rect.height)
        try expect(modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == p1.rect
            && modelB.document?.positions.first(where: { $0.id == p1.id })?.rect == p1.rect
            && sceneA.renderedFrame(for: first.id)?.minX == frame.minX + 90,
            "real pointer drag previews locally through camera zoom without mutating either authoritative document")
        try expect(await authority.commands.count == callsBefore, "pointer packets do not send durable geometry operations")
        sceneA.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: end, in: sceneA))
        try await eventually("one accepted drag converges") {
            modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == moved
                && modelB.document?.positions.first(where: { $0.id == p1.id })?.rect == moved && sceneA.canUndoSharedGeometry
        }
        try expect(await authority.commands.count == callsBefore + 1, "mouse release commits exactly one shared move")
        let expectedB = sceneB.screenPoint(forAreaPoint: .init(x: moved.x, y: moved.y))
        try expect(close(sceneB.renderedFrame(for: first.id)?.minX, expectedB.x)
            && close(sceneB.renderedFrame(for: first.id)?.minY, expectedB.y),
            "participant at another camera sees the identical area-local frame")

        let post = SharedArea.Post(id: .init(), object: second.id, author: b.person, text: "Keep this newer discussion while undoing layout")
        guard let beforePost = modelB.document else { throw Failure(description: "editor document missing") }
        _ = await modelB.submit(.init(area: beforePost.id, expectedRevision: beforePost.revision, edits: [.post(post)]))
        try await eventually("teammate post before undo") { modelA.document?.posts.last == post }
        try expect(sceneA.areaCanvasView.tryToPerform(NSSelectorFromString("undo:"), with: nil),
            "Edit Undo reaches the actual shared-canvas responder")
        try await eventually("semantic inverse converges") {
            modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == p1.rect
                && modelB.document?.positions.first(where: { $0.id == p1.id })?.rect == p1.rect && sceneA.canRedoSharedGeometry
        }
        try expect(modelA.document?.posts.last == post && modelB.document?.posts.last == post,
            "native semantic Undo preserves a newer teammate discussion")
        sceneA.areaCanvasView.keyDown(with: try key(code: 6, modifiers: [.command, .shift]))
        try await eventually("keyboard redo converges") { modelB.document?.positions.first(where: { $0.id == p1.id })?.rect == moved && sceneA.canUndoSharedGeometry }

        var teammate = moved
        teammate = .init(x: moved.x + 10, y: moved.y + 15, width: moved.width, height: moved.height)
        try expect(sceneB.beginGeometry(placements: [p1.id]), "second participant can begin its own shared move")
        try expect(sceneB.updateGeometry(frames: [p1.id: teammate]), "second participant proposes a complete frame")
        await sceneB.finishGeometry()
        try await eventually("teammate movement arrives") { modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == teammate }
        let beforeRefusedUndo = await authority.commands.count
        await sceneA.undoSharedGeometry()
        try expect(await authority.commands.count == beforeRefusedUndo
            && modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == teammate,
            "an older local Undo never replaces the teammate's newer placement")

        // Shift-click builds a group using the shipping pointer selection path.
        try click(first.id, in: sceneA)
        try click(second.id, in: sceneA, modifiers: [.shift])
        guard let groupStartFrame = sceneA.renderedFrame(for: first.id) else { throw Failure(description: "group card absent") }
        let groupStart = NSPoint(x: groupStartFrame.minX + 30, y: groupStartFrame.minY + 24)
        let groupEnd = NSPoint(x: groupStart.x + 45, y: groupStart.y - 30)
        let beforeGroup = await authority.commands.count
        sceneA.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: groupStart, in: sceneA))
        sceneA.areaCanvasView.mouseDragged(with: try pointer(.leftMouseDragged, point: groupEnd, in: sceneA))
        sceneA.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: groupEnd, in: sceneA))
        try await eventually("group move accepted") { await authority.commands.count == beforeGroup + 1 && sceneA.canUndoSharedGeometry }
        guard let grouped = modelA.document else { throw Failure(description: "group result missing") }
        let groupFrames = Dictionary(uniqueKeysWithValues: grouped.positions.map { ($0.id, $0.rect) })
        let lastGroup = await authority.commands.last
        try expect(lastGroup?.edits.count == 2
            && groupFrames[p1.id] == .init(x: teammate.x + 60, y: teammate.y - 40, width: teammate.width, height: teammate.height)
            && groupFrames[p2.id] == .init(x: p2.rect.x + 60, y: p2.rect.y - 40, width: p2.rect.width, height: p2.rect.height),
            "one native group gesture moves both members rigidly in one operation")
        let firstGroup = sceneA.renderedFrame(for: first.id)!, secondGroup = sceneA.renderedFrame(for: second.id)!
        let groupRect = firstGroup.union(secondGroup)
        let handle = NSPoint(x: groupRect.maxX, y: groupRect.maxY), resized = NSPoint(x: handle.x + 75, y: handle.y + 45)
        let beforeResize = await authority.commands.count
        sceneA.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: handle, in: sceneA))
        sceneA.areaCanvasView.mouseDragged(with: try pointer(.leftMouseDragged, point: resized, in: sceneA))
        sceneA.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: resized, in: sceneA))
        try await eventually("group resize accepted") { await authority.commands.count == beforeResize + 1 && sceneA.canUndoSharedGeometry }
        try expect(await authority.commands.last?.edits.count == 2
            && (modelA.document?.positions.first(where: { $0.id == p1.id })?.rect.width ?? 0) > teammate.width,
            "native resize handle scales the complete group in one accepted operation")
        await sceneA.undoSharedGeometry()
        try await eventually("group resize undo") {
            guard let state = modelB.document else { return false }
            return Dictionary(uniqueKeysWithValues: state.positions.map { ($0.id, $0.rect) }) == groupFrames
        }
        try expect(modelA.view.x == cameraA.x && modelA.view.y == cameraA.y && modelA.view.zoom == cameraA.zoom
            && modelB.view.x == cameraB.x && modelB.view.y == cameraB.y && modelB.view.zoom == cameraB.zoom,
            "shared moves, resize and compensation preserve both private cameras")

        // A remote authoritative move cancels an in-progress preview as a whole.
        try click(first.id, in: sceneA)
        let conflictFrame = sceneA.renderedFrame(for: first.id)!
        let conflictPoint = NSPoint(x: conflictFrame.minX + 30, y: conflictFrame.minY + 24)
        sceneA.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: conflictPoint, in: sceneA))
        sceneA.areaCanvasView.mouseDragged(with: try pointer(.leftMouseDragged, point: .init(x: conflictPoint.x + 30, y: conflictPoint.y + 20), in: sceneA))
        try expect(sceneA.isGeometryGestureActive, "fixture has a live shared geometry preview")
        let current = modelB.document!.positions.first(where: { $0.id == p1.id })!
        let remoteFrame = SharedArea.Rect(x: current.rect.x + 7, y: current.rect.y + 9, width: current.rect.width, height: current.rect.height)
        let beforeConflict = await authority.commands.count
        try expect(sceneB.beginGeometry(placements: [p1.id]) && sceneB.updateGeometry(frames: [p1.id: remoteFrame]), "teammate prepares conflicting full-frame intent")
        await sceneB.finishGeometry()
        try await eventually("remote update cancels local preview") { !sceneA.isGeometryGestureActive && modelA.document?.positions.first(where: { $0.id == p1.id })?.rect == remoteFrame }
        sceneA.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: conflictPoint, in: sceneA))
        try expect(await authority.commands.count == beforeConflict + 1,
            "remote-authority cancellation never sends the stale local drag on mouse release")

        try click(first.id, in: sceneA)
        let cancelFrame = sceneA.renderedFrame(for: first.id)!
        let cancelPoint = NSPoint(x: cancelFrame.minX + 30, y: cancelFrame.minY + 24)
        let beforeCancel = await authority.commands.count
        sceneA.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: cancelPoint, in: sceneA))
        sceneA.areaCanvasView.mouseDragged(with: try pointer(.leftMouseDragged, point: .init(x: cancelPoint.x - 22, y: cancelPoint.y + 18), in: sceneA))
        sceneA.areaCanvasView.keyDown(with: try key(code: 53, modifiers: []))
        sceneA.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: cancelPoint, in: sceneA))
        try expect(await authority.commands.count == beforeCancel && !sceneA.isGeometryGestureActive
            && sceneA.renderedFrame(for: first.id) == cancelFrame, "Escape cancels preview without a shared operation")
        try expect(!viewerScene.beginGeometry(placements: [p1.id]), "read-only participant cannot begin a geometry mutation")
        try expect(try Data(contentsOf: source) == sourceBytes && executorCount() == originalExecutors,
            "all geometry input preserves supplied private source bytes and executor census")
        sceneA.unmount(); sceneB.unmount(); viewerScene.unmount()
        await modelA.close(); await modelB.close(); await viewerModel.close()
        try await runColdRecovery(root: root.appendingPathComponent("cold"), identity: a, placement: p1.id,
            authority: authority, mount: mount)
        try expect(try Data(contentsOf: source) == sourceBytes && executorCount() == originalExecutors,
            "cold geometry recovery and compensation preserve supplied source bytes and execution")
        print("Native shared geometry passed: production mounts, pointer group move/resize, responder Undo/keyboard Redo, private cameras, remote conflict, cancellation, cold inverse recovery and no source execution.")
    }
    private static func runColdRecovery(root: URL, identity: Collaboration.Identity,
                                        placement: SharedArea.ID<SharedArea.Placement>, authority: Authority,
                                        mount: SharedAreaSceneChecks.Mount) async throws {
        let model = try controller(root: root, identity: identity, authority: authority)
        let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let scene = try mount(model, identity.person, host); host.layoutSubtreeIfNeeded()
        await model.open()
        guard let before = model.document?.positions.first(where: { $0.id == placement }) else { throw Failure(description: "cold source missing") }
        let after = SharedArea.Rect(x: before.rect.x + 31, y: before.rect.y - 27, width: before.rect.width + 20, height: before.rect.height + 15)
        let reply = ReplyGate()
        defer { Task { await reply.release() } }
        await authority.holdNextReply(reply)
        try expect(scene.beginGeometry(placements: [placement]) && scene.updateGeometry(frames: [placement: after]),
            "cold fixture prepares one exact resize intent")
        let originalSend = Task { await scene.finishGeometry() }
        try await eventually("remote commit before reply") { await reply.entered }
        guard let record = model.pendingOperations.first, let ledgerFile = scene.geometryLedgerFile else { throw Failure(description: "pre-effect recovery state absent") }
        let localLedger = try JSONCodec.makeDecoder().decode(SharedAreaGeometryLedger.self, from: Data(contentsOf: ledgerFile))
        try expect(localLedger.pending?.command == record.command && localLedger.pending?.changes.first?.before == before,
            "before the remote reply, disk retains exact data command and complete inverse")
        scene.unmount(); await model.close()

        let coldModel = try controller(root: root, identity: identity, authority: authority)
        let coldHost = NSView(frame: host.frame)
        let coldScene = try mount(coldModel, identity.person, coldHost); coldHost.layoutSubtreeIfNeeded()
        await coldModel.open()
        try await eventually("cold receipt restores Undo") { coldScene.canUndoSharedGeometry }
        let acceptedCount = await authority.commands.filter { $0.id == record.command.id }.count
        try expect(coldModel.document?.positions.first(where: { $0.id == placement })?.rect == after && acceptedCount == 1,
            "new controller recovers remote-success/local-ack loss without sending the accepted move twice")
        await coldScene.undoSharedGeometry()
        try await eventually("cold inverse applies") { coldModel.document?.positions.first(where: { $0.id == placement }) == before && coldScene.canRedoSharedGeometry }
        await reply.release(); await originalSend.value
        try expect(coldModel.document?.positions.first(where: { $0.id == placement }) == before,
            "late old-controller outcome cannot replace the relaunched controller's compensation")
        coldScene.unmount(); await coldModel.close()
    }
    private static func close(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }
    private static func pointer(_ type: NSEvent.EventType, point: NSPoint, in scene: SharedAreaSceneView,
                                modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: scene.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: scene.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(description: "pointer event unavailable") }
        return event
    }
    private static func key(code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: code == 53 ? "\u{1b}" : "z", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "z", isARepeat: false, keyCode: code) else { throw Failure(description: "key event unavailable") }
        return event
    }
    private static func click(_ object: SharedArea.ID<SharedArea.Object>, in scene: SharedAreaSceneView,
                              modifiers: NSEvent.ModifierFlags = []) throws {
        guard let frame = scene.renderedFrame(for: object) else { throw Failure(description: "click target absent") }
        let point = NSPoint(x: frame.minX + 30, y: frame.minY + 24)
        scene.areaCanvasView.mouseDown(with: try pointer(.leftMouseDown, point: point, in: scene, modifiers: modifiers))
        scene.areaCanvasView.mouseUp(with: try pointer(.leftMouseUp, point: point, in: scene, modifiers: modifiers))
    }
    private static func controller(root: URL, identity: Collaboration.Identity, authority: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://geometry.example.test")!)
        let credentials = CollaborationCredentialStore(vault: Vault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-geometry-device"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
            person: identity.person, area: authority.area)
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
    private final class Vault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
        func emit(_ state: Collaboration.State) throws { pair.continuation.yield(.connected(try CollaborationReplica(state: state))) }
    }
    private actor ReplyGate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private actor Authority {
        nonisolated let area: SharedArea.ID<SharedArea.Area>
        let owner: Collaboration.Identity, editor: Collaboration.Identity, viewer: Collaboration.Identity
        var document: SharedArea.Document
        var connections: [(Collaboration.Identity, Connection)] = []
        var commands: [SharedArea.Command] = []
        var replyGate: ReplyGate?
        init(document: SharedArea.Document, owner: Collaboration.Identity, editor: Collaboration.Identity, viewer: Collaboration.Identity) {
            self.document = document; area = document.id; self.owner = owner; self.editor = editor; self.viewer = viewer
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
            guard [owner, editor, viewer].contains(identity) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return .init(scope: .init(area: document.id, epoch: 1, role: identity == owner ? .owner : identity == editor ? .editor : .viewer), document: document)
        }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try state(identity); let value = Connection(); connections.append((identity, value)); return value
        }
        func holdNextReply(_ gate: ReplyGate) { replyGate = gate }
        func apply(_ mutation: Collaboration.Mutation, identity: Collaboration.Identity) async throws -> Collaboration.Receipt {
            let current = try state(identity)
            guard current.scope.canSubmit(mutation.command), mutation.epoch == 1 else { throw CollaborationClientError.server(status: 403, code: "forbidden") }
            commands.append(mutation.command)
            let result: SharedArea.Outcome
            do { result = try document.apply(mutation.command) }
            catch SharedArea.Failure.conflict { throw CollaborationClientError.server(status: 409, code: "conflict") }
            if let gate = replyGate { replyGate = nil; await gate.wait() }
            for (person, connection) in connections { try await connection.emit(state(person)) }
            switch result {
            case .applied(let revision): return .init(revision: revision, duplicate: false)
            case .duplicate(let revision): return .init(revision: revision, duplicate: true)
            }
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
