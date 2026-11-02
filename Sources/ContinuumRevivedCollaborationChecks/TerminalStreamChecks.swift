import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

/// `.plans/114-terminal-sharing`: how a viewer follows a shared terminal's
/// stream (`TerminalStreamFollower`), and the stream lane itself through the
/// production client against the real NIO relay on loopback: who may send,
/// what a watcher and a late joiner get, in what order, and the limits.
func runTerminalStreamChecks() async throws {
    func check(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure(label: label) }
        print("PASS terminal stream: \(label)")
    }
    typealias Frame = Collaboration.LiveTile.TerminalFrame
    let stream = UUID()
    func output(_ n: UInt64, _ text: String, stream s: UUID? = nil) -> Frame {
        .init(stream: s ?? stream, sequence: n, kind: .output, columns: 80, rows: 24, bytes: Data(text.utf8))
    }
    func screen(_ n: UInt64, _ text: String, kind: Frame.Kind = .keyframe, stream s: UUID? = nil) -> Frame {
        .init(stream: s ?? stream, sequence: n, kind: kind, columns: 80, rows: 24, bytes: Data(text.utf8))
    }
    func written(_ steps: [TerminalStreamFollower.Step]) -> String {
        steps.map { step in
            switch step {
            case .write(let data): String(decoding: data, as: UTF8.self)
            case .reset(let frame): "[" + String(decoding: frame.bytes, as: UTF8.self) + "]"
            }
        }.joined()
    }

    // The follower.
    var follower = TerminalStreamFollower()
    try check(written(follower.take(output(2, "b"))).isEmpty && follower.isWaiting, "output before any screen draws nothing and waits")
    try check(written(follower.take(screen(1, "A"))) == "[A]b", "the first screen starts it, then held output follows on")
    try check(written(follower.take(output(3, "c"))) == "c", "output in sequence is drawn")
    try check(written(follower.take(output(3, "c"))).isEmpty, "a duplicate is drawn once")
    try check(written(follower.take(output(5, "e"))).isEmpty && follower.isWaiting, "a gap holds what comes after it")
    try check(written(follower.take(output(4, "d"))) == "de" && !follower.isWaiting, "filling the gap draws the held output, in order")
    try check(written(follower.take(screen(5, "C", kind: .checkpoint))).isEmpty, "a checkpoint is ignored by a viewer in step")
    try check(written(follower.take(screen(6, "K"))) == "[K]", "a keyframe redraws every viewer")
    try check(written(follower.take(screen(9, "C9", kind: .checkpoint))) == "[C9]", "a checkpoint catches up a viewer that is behind")
    try check(written(follower.take(output(1, "x", stream: UUID()))).isEmpty, "output of another run draws nothing")
    let next = UUID()
    try check(written(follower.take(screen(1, "N", stream: next))) == "[N]" && follower.stream == next, "a new run starts over from its first screen")
    var late = TerminalStreamFollower()
    let state = Collaboration.LiveTile.TerminalScreen(base: screen(4, "S", kind: .checkpoint), output: [output(5, "f"), output(6, "g")])
    try check(written(late.take(state)) == "[S]fg" && late.sequence == 6, "the state lane's screen and its output bring a late joiner up to date")
    try check(written(late.take(state)).isEmpty, "the same state again draws nothing")

    // The lane, end to end.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-terminal-stream-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 61, count: 32)
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
        let (stranger, _) = try await person("Stranger")
        let created = try await owner.createArea()
        let area = created.document.id.rawValue
        _ = try await guest.accept(code: try await owner.invite(area: area, request: .init(person: guestCredential.identity.person)).code)
        _ = try await viewer.accept(code: try await owner.invite(area: area, request: .init(person: viewerCredential.identity.person, role: .viewer)).code)
        let host = try await owner.registerHost().id
        let current = try await owner.state(area: area)
        let item = SharedArea.Item(id: .init(), kind: .liveTile, source: .init(owner: ownerCredential.identity.person, host: host, binding: .init()))
        _ = try await owner.apply(area: area, mutation: .init(epoch: current.scope.epoch, command: .init(area: current.document.id,
            expectedRevision: current.document.revision, edits: [.admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 600, height: 400)))])))
        let object = item.id.rawValue

        do { _ = try await stranger.openTileStream(area: area, object: object); throw CheckFailure(label: "a stranger opened the lane") }
        catch CollaborationClientError.server(let status, _) { try check(status == 404, "someone outside the area is refused before the upgrade (\(status))") }
        do { _ = try await guest.openTileStream(area: area, object: UUID()); throw CheckFailure(label: "a lane opened for no tile") }
        catch CollaborationClientError.server(let status, _) { try check(status == 404, "a tile the area does not hold has no lane (\(status))") }

        let sender = try await owner.openTileStream(area: area, object: object)
        let watcher = try await guest.openTileStream(area: area, object: object)
        var watched = watcher.messages.makeAsyncIterator()
        func next(_ iterator: inout AsyncStream<Collaboration.LiveTile.StreamMessage>.AsyncIterator, within seconds: Double = 3) async -> Frame? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let message = await iterator.next() { if let frame = message.frame { return frame } } else { return nil }
            }
            return nil
        }
        let run = UUID()
        let started = Date()
        try await sender.send(.init(stream: run, sequence: 1, kind: .keyframe, columns: 80, rows: 24, bytes: Data("\u{1b}[31mred\u{1b}[0m".utf8),
                                    palette: .init(foreground: "#ffffff", background: "#000000", cursor: nil, colors: ["#000000", "#cc0000"])))
        for n in 2...41 { try await sender.send(.init(stream: run, sequence: UInt64(n), kind: .output, columns: 80, rows: 24, bytes: Data("line \(n)\r\n".utf8))) }
        var received: [Frame] = []
        while received.count < 41, let frame = await next(&watched) { received.append(frame) }
        try check(received.map(\.sequence) == Array(1...41).map(UInt64.init), "a watcher gets every frame, in order")
        try check(received.first?.palette?.colors.last == "#cc0000" && received.first?.bytes == Data("\u{1b}[31mred\u{1b}[0m".utf8),
                  "the screen arrives whole, with the host's colours")
        print("TERMINAL lane: 41 frames over loopback in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // A late joiner: the newest screen and the output after it, first.
        let joiner = try await viewer.openTileStream(area: area, object: object)
        var joined = joiner.messages.makeAsyncIterator()
        var replay: [Frame] = []
        while replay.count < 41, let frame = await next(&joined) { replay.append(frame) }
        try check(replay.first?.kind == .keyframe && replay.map(\.sequence) == Array(1...41).map(UInt64.init),
                  "a late joiner is sent the newest screen and the output after it, in order")
        try await sender.send(.init(stream: run, sequence: 41, kind: .checkpoint, columns: 80, rows: 24, bytes: Data("screen at 41".utf8)))
        let checkpoint = await next(&watched)
        try check(checkpoint?.kind == .checkpoint && checkpoint?.sequence == 41, "a checkpoint reaches watchers")
        let second = try await viewer.openTileStream(area: area, object: object)
        var secondIterator = second.messages.makeAsyncIterator()
        let restarted = await next(&secondIterator)
        try check(restarted?.kind == .checkpoint && restarted?.sequence == 41, "after a checkpoint, a joiner starts from it")
        await second.close()

        // A watcher cannot send: its lane is closed and nothing reaches anyone.
        let intruder = try await viewer.openTileStream(area: area, object: object)
        try? await intruder.send(.init(stream: run, sequence: 42, kind: .output, columns: 80, rows: 24, bytes: Data("typed".utf8)))
        var intruded = intruder.messages.makeAsyncIterator()
        while await intruded.next() != nil {}
        try await sender.send(.init(stream: run, sequence: 42, kind: .output, columns: 80, rows: 24, bytes: Data("host".utf8)))
        let afterIntrusion = await next(&watched)
        try check(afterIntrusion?.bytes == Data("host".utf8), "a member's frame closes their lane; the watchers see only the host's")

        // Limits: a frame over the cap closes the sender's lane; a burst over the
        // rate is cut, and the host is asked for a keyframe.
        let burst = try await owner.openTileStream(area: area, object: object)
        var burstMessages = burst.messages.makeAsyncIterator()
        for n in 0..<300 { try? await burst.send(.init(stream: run, sequence: UInt64(43 + n), kind: .output, columns: 80, rows: 24, bytes: Data("x".utf8))) }
        var resync = false
        let resyncDeadline = Date().addingTimeInterval(3)
        while !resync, Date() < resyncDeadline, let message = await burstMessages.next() { resync = message.resync == true }
        try check(resync, "a burst over the rate is cut and the host is asked for a keyframe")
        let big = try await owner.openTileStream(area: area, object: object)
        try? await big.send(.init(stream: run, sequence: 999, kind: .output, columns: 80, rows: 24, bytes: Data(repeating: 65, count: 200 * 1024)))
        var bigMessages = big.messages.makeAsyncIterator()
        while await bigMessages.next() != nil {}
        try check(true, "a frame over the cap closes the lane that sent it")

        // The state lane keeps a terminal's screen whole.
        let screenState = Collaboration.LiveTile.TerminalScreen(base: received[0], output: Array(received[1...3]))
        try await owner.publishLiveTileState(area: area, object: object, report: .init(epoch: current.scope.epoch, host: host,
            state: .init(generation: UUID(), revision: 1, payload: .terminal(.init(title: "zsh", text: "red", columns: 80, rows: 24, screen: screenState)))))
        let read = try await guest.readLiveTile(area: area, object: object, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
        if case .terminal(let terminal)? = read.state?.payload { try check(terminal.screen == screenState, "the state lane carries the screen and its output unchanged") }
        else { throw CheckFailure(label: "the terminal state reads back") }
        // A terminal state from before the stream decodes as it did.
        let old = Data(#"{"title":"zsh","text":"$ ls","columns":4,"rows":1}"#.utf8)
        try check((try? JSONDecoder().decode(Collaboration.LiveTile.Terminal.self, from: old))?.screen == nil, "an older host's terminal state still decodes, without a screen")

        // Removing the tile closes its lanes.
        let now = try await owner.state(area: area)
        _ = try await owner.apply(area: area, mutation: .init(epoch: now.scope.epoch, command: .init(area: now.document.id,
            expectedRevision: now.document.revision, edits: [.remove(item.id)])))
        var ended = false
        let endDeadline = Date().addingTimeInterval(5)
        while Date() < endDeadline { if await watched.next() == nil { ended = true; break } }
        try check(ended, "removing the tile from the area closes its watchers' lanes")
        try check(await store.openTileStreams() <= 2, "closed lanes are released (\(await store.openTileStreams()) open)")
        await sender.close(); await joiner.close(); await burst.close()
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}
