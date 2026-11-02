import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

/// `.plans/105-collaboration/SHARE-KINDS.md`: the live-tile lane, through the
/// production client against the real NIO routes on loopback. Who may write a
/// tile's state, who may give it input, and what a reader gets back.
func runLiveTileLaneChecks() async throws {
    func check(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure(label: label) }
        print("PASS live tile: \(label)")
    }
    func refused(_ label: String, status: Int, _ body: () async throws -> Void) async throws {
        do { try await body(); throw CheckFailure(label: "expected \(status): \(label)") }
        catch CollaborationClientError.server(let code, _) where code == status { print("PASS live tile: \(label)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-live-tile-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 51, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ label: String) async throws -> (CollaborationAPI, Collaboration.Credential) {
            let enrollment = try await store.provisionPerson(label: label)
            let credential = try await CollaborationAPI(baseURL: url, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: label)
            return (try CollaborationAPI(baseURL: url, credential: credential.token, allowsInsecureLoopback: true), credential)
        }
        let (owner, ownerCredential) = try await person("Owner")
        let (guest, guestCredential) = try await person("Guest")
        let (viewer, viewerCredential) = try await person("Viewer")
        let state = try await owner.createArea()
        let area = state.document.id.rawValue
        _ = try await guest.accept(code: try await owner.invite(area: area, request: .init(person: guestCredential.identity.person)).code)
        _ = try await viewer.accept(code: try await owner.invite(area: area, request: .init(person: viewerCredential.identity.person, role: .viewer)).code)
        let host = try await owner.registerHost().id
        func admit(kind: SharedArea.Kind) async throws -> SharedArea.ID<SharedArea.Object> {
            let current = try await owner.state(area: area)
            let item = SharedArea.Item(id: .init(), kind: kind, source: .init(owner: ownerCredential.identity.person, host: host, binding: .init()))
            let position = SharedArea.Position(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 400, height: 300))
            _ = try await owner.apply(area: area, mutation: .init(epoch: current.scope.epoch,
                command: .init(area: current.document.id, expectedRevision: current.document.revision, edits: [.admit(item, position)])))
            return item.id
        }
        let epoch = try await owner.state(area: area).scope.epoch
        let note = try await admit(kind: .liveTile), terminal = try await admit(kind: .liveTile), browser = try await admit(kind: .liveTile)
        try check(try await owner.state(area: area).document.items.filter { $0.kind == .liveTile }.count == 3,
                  "the service admits a .liveTile item sourced by the owner's own host")

        // Nothing to read, and no input, before the host says what it is.
        let empty = try await guest.readLiveTile(area: area, object: note.rawValue, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
        try check(empty.state == nil && empty.events.isEmpty, "a tile the host has not published reads empty")
        try await refused("input before the host has published is refused", status: 404) {
            _ = try await guest.appendLiveTileEvent(area: area, object: note.rawValue, body: .browserClick(x: 1, y: 1))
        }

        var replica = Collaboration.NoteText.Replica(replica: "host")
        _ = replica.edit(to: "hello")
        let generation = UUID()
        func publish(_ object: SharedArea.ID<SharedArea.Object>, _ revision: UInt64, _ payload: Collaboration.LiveTile.Payload,
                     as api: CollaborationAPI? = nil, host publisher: SharedArea.ID<SharedArea.Host>? = nil) async throws {
            try await (api ?? owner).publishLiveTileState(area: area, object: object.rawValue, report: .init(epoch: epoch, host: publisher ?? host,
                state: .init(generation: generation, revision: revision, payload: payload)))
        }
        try await publish(note, 1, .note(.init(title: "Plan", snapshot: replica.snapshot, eventsThrough: 0)))
        try await publish(terminal, 1, .terminal(.init(title: "zsh", text: "$ echo hi\nhi\n", columns: 9, rows: 2)))
        try await publish(browser, 1, .browser(.init(url: "http://127.0.0.1:9/", title: "local", reach: .private,
                                                     frame: .init(jpeg: Data(repeating: 7, count: 100_000), width: 800, height: 600, sequence: 1))))
        try await refused("a teammate cannot write the owner's tile state", status: 403) {
            try await publish(note, 2, .note(.init(title: "x", snapshot: replica.snapshot, eventsThrough: 0)), as: guest)
        }
        try await refused("a request over the relay's 256 KiB cap is refused", status: 413) {
            try await publish(browser, 2, .browser(.init(url: nil, title: "big", reach: .private,
                frame: .init(jpeg: Data(repeating: 1, count: 300_000), width: 1, height: 1, sequence: 2))))
        }
        try await refused("a state over the lane's 240 KiB payload cap is refused before it is stored", status: 400) {
            try await publish(browser, 2, .browser(.init(url: nil, title: "big", reach: .private,
                frame: .init(jpeg: Data(repeating: 1, count: 186_000), width: 1, height: 1, sequence: 2))))
        }

        let first = try await guest.readLiveTile(area: area, object: note.rawValue, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
        guard case .note(let snapshot)? = first.state?.payload else { throw CheckFailure(label: "the guest reads the note's state") }
        var guestReplica = Collaboration.NoteText.Replica(snapshot: snapshot.snapshot, replica: "guest")
        try check(guestReplica.text == "hello", "a member reads the owner's state")
        let again = try await guest.readLiveTile(area: area, object: note.rawValue, request: .init(generation: generation, revision: 1, eventsAfter: first.eventHead, waitMilliseconds: 0))
        try check(again.state == nil && again.events.isEmpty, "an unchanged state is not sent again")
        let picture = try await viewer.readLiveTile(area: area, object: browser.rawValue, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
        if case .browser(let value)? = picture.state?.payload { try check(value.frame?.jpeg.count == 100_000, "a 100 KB picture crosses the lane whole") }
        else { throw CheckFailure(label: "the browser state reads back") }

        // A held read wakes when the guest's edit lands.
        let held = Task { try await owner.readLiveTile(area: area, object: note.rawValue, request: .init(generation: generation, revision: 1, eventsAfter: 0, waitMilliseconds: 10_000)) }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        let ops = guestReplica.edit(to: "hello, world")
        let appended = try await guest.appendLiveTileEvent(area: area, object: note.rawValue, body: .noteOps(ops))
        let woke = try await held.value
        try check(appended.sequence == 1 && woke.events.map(\.sequence) == [1] && Date().timeIntervalSince(started) < 3,
                  "a held read returns the moment a teammate's edit is appended")
        try check(woke.events.first?.author == guestCredential.identity.person, "the relay stamps the edit with its author")
        if case .noteOps(let received)? = woke.events.first?.body { replica.apply(received) }
        try check(replica.text == "hello, world", "the owner merges the teammate's note edit")

        try await refused("a terminal refuses a teammate's input", status: 403) {
            _ = try await guest.appendLiveTileEvent(area: area, object: terminal.rawValue, body: .browserClick(x: 1, y: 1))
        }
        try await refused("a kind refuses input it does not take", status: 400) {
            _ = try await guest.appendLiveTileEvent(area: area, object: note.rawValue, body: .browserScroll(dx: 0, dy: 10))
        }
        try await refused("a viewer cannot give input", status: 403) {
            _ = try await viewer.appendLiveTileEvent(area: area, object: browser.rawValue, body: .browserClick(x: 1, y: 1))
        }
        let click = try await guest.appendLiveTileEvent(area: area, object: browser.rawValue, body: .browserClick(x: 120, y: 80))
        let hostReads = try await owner.readLiveTile(area: area, object: browser.rawValue, request: .init(generation: generation, revision: 1, eventsAfter: 0, waitMilliseconds: 0))
        try check(click.sequence == 1 && hostReads.events.first?.body == .browserClick(x: 120, y: 80), "a teammate's browser click reaches the host")

        // The owner removes the tile: its lane goes with it.
        let current = try await owner.state(area: area)
        _ = try await owner.apply(area: area, mutation: .init(epoch: current.scope.epoch,
            command: .init(area: current.document.id, expectedRevision: current.document.revision, edits: [.remove(browser)])))
        try await refused("a removed tile cannot be read", status: 404) {
            _ = try await guest.readLiveTile(area: area, object: browser.rawValue, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
        }
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}
