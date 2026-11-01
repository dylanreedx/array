import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct ProjectionCheckFailure: Error { let message: String }
private func projectionCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw ProjectionCheckFailure(message: label) }
    print("PASS agent projection: \(label)")
}
private func projectionRefuses(_ expected: Int, _ label: String, _ action: () async throws -> Void) async throws {
    do { try await action(); throw ProjectionCheckFailure(message: "\(label) unexpectedly succeeded") }
    catch let error as CollaborationClientError {
        guard case .server(let code, _) = error, code == expected else { throw error }
        print("PASS agent projection: \(label)")
    }
}

private typealias P = Collaboration.AgentProjection

/// COL-15. The portable reducer/log/replica contract the host, the service and
/// every recipient share, then the real localhost A/B/C routes.
func runCollaborationAgentProjectionChecks() async throws {
    try runProjectionContractChecks()
    try await runProjectionHTTPChecks()
}

private func runProjectionContractChecks() throws {
    let host = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
    let caps = P.Capabilities(locallyManaged: true, canSend: true, canQueue: false, canSteer: false, canInterrupt: false)
    func frame(_ generation: UInt64, _ sequence: UInt64, _ payload: P.Payload) -> P.Frame {
        .init(host: host, object: object, generation: generation, sequence: sequence, payload: payload)
    }
    // A host stream: turn, two text deltas, a tool row, completion; repeated.
    var payloads: [P.Payload] = []
    for turn in 0..<20 {
        payloads += [.turnStarted(turn: "t\(turn)"), .assistantText(row: "r\(turn)", turn: "t\(turn)", delta: "Hello "),
                     .tool(row: "x\(turn)", turn: nil, kind: .command, status: .running),
                     .assistantText(row: "r\(turn)", turn: "t\(turn)", delta: "world \(turn)"),
                     .tool(row: "x\(turn)", turn: nil, kind: .command, status: .completed),
                     .turnCompleted(turn: "t\(turn)", outcome: .completed)]
    }
    let initial = P.Snapshot(host: host, object: object, generation: 1, history: .excluded, phase: .ready, capabilities: caps)
    var log = P.Log(snapshot: initial)
    for (index, payload) in payloads.enumerated() {
        try log.publish(.init(snapshot: nil, frames: [frame(1, UInt64(index + 1), payload)]))
    }

    // Late join: no cursor is an explicit resnapshot of the complete head.
    var late = P.Replica()
    guard case .resnapshot(let head) = log.read(after: nil) else { throw ProjectionCheckFailure(message: "late join was not a snapshot") }
    _ = late.receive(.resnapshot(head))
    try projectionCheck(late.state == log.head && late.state?.through == UInt64(payloads.count),
        "a late join receives the complete head through the last sequenced event")

    // An early viewer at the boundary pages every tail event, each exactly once.
    var early = P.Replica()
    _ = early.receive(.resnapshot(initial))
    var pages = 0, applied = 0
    while true {
        let read = log.read(after: early.cursor, limit: 7)
        guard case .frames(_, let frames, let more) = read else { throw ProjectionCheckFailure(message: "retained cursor resnapshotted") }
        guard case .applied(let count) = early.receive(read) else { throw ProjectionCheckFailure(message: "paged frames refused") }
        applied += count; pages += 1
        // Redelivery of the same page (lost acknowledgement) adds nothing.
        guard case .applied(0) = early.receive(.frames(generation: 1, frames: frames, more: more)) else {
            throw ProjectionCheckFailure(message: "duplicate page applied twice")
        }
        if !more { break }
    }
    try projectionCheck(early.state == log.head && applied == payloads.count && pages == (payloads.count + 6) / 7,
        "a viewer from the snapshot boundary applies all \(payloads.count) tail events once across \(pages) pages, duplicates ignored")
    try projectionCheck(early.state?.rows.first(where: { $0.id == "r13" })?.text == "Hello world 13"
        && early.state?.rows.first(where: { $0.id == "x13" })?.status == .completed
        && early.state?.rows.count == P.maxRows && early.state?.omittedRows == 8 && early.state?.rows.first?.id == "r4",
        "text deltas fold into one row, tool rows update in place, and the oldest 8 of 40 rows are counted as omitted")
    // Turn 13 is payloads 79...84: its text row last changed at 82, its tool at 83.
    let quoted = early.state!.rows.first { $0.id == "r13" }!
    let source = Collaboration.ResultExcerpt.Source(incarnation: .init(object: object, hostGeneration: UUID()), host: host,
        turn: quoted.turn!, position: early.state!.position(of: "r13"))
    try projectionCheck(source.position == P.Position(generation: 1, sequence: 82)
        && early.state!.position(of: "x13") == P.Position(generation: 1, sequence: 83) && source.turn == "t13",
        "each row records the frame that last changed it, so a result excerpt cites the projection's own turn and position")

    // A gap never advances: the replica asks for a resnapshot instead.
    var gapped = P.Replica()
    _ = gapped.receive(.resnapshot(initial))
    _ = gapped.receive(.frames(generation: 1, frames: [log.frames[0], log.frames[1]], more: false))
    let gap = gapped.receive(.frames(generation: 1, frames: [log.frames[3]], more: false))
    try projectionCheck(gap == .needsResnapshot(.gap(expected: 3, received: 4)) && gapped.state?.through == 2,
        "a dropped frame is detected as a gap and the replica stays at its last contiguous sequence")
    _ = gapped.receive(log.read(after: nil))
    try projectionCheck(gapped.state == log.head, "an explicit resnapshot repairs the gap")

    var overflow = log
    for index in 0..<(P.retainedFrames + 10) {
        try overflow.publish(.init(snapshot: nil, frames: [frame(1, overflow.head.through + 1, .phase(index % 2 == 0 ? .working : .ready))]))
    }
    guard case .resnapshot = overflow.read(after: .init(generation: 1, through: 5)) else {
        throw ProjectionCheckFailure(message: "cursor older than retention was paged instead of resnapshotted")
    }
    try projectionCheck(overflow.frames.count == P.retainedFrames, "a cursor older than retained frames gets an explicit resnapshot")

    // Generations: a relaunched host (generation 2) supersedes; generation 1 is dead.
    let second = P.Snapshot(host: host, object: object, generation: 2, history: .excluded, phase: .ready, capabilities: caps)
    var relaunched = log
    try relaunched.publish(.init(snapshot: second, frames: [frame(2, 1, .turnStarted(turn: "new"))]))
    var staleRefused = false
    do { try relaunched.publish(.init(snapshot: nil, frames: [frame(1, log.head.through + 1, .phase(.failed))])) }
    catch P.Log.Failure.staleGeneration { staleRefused = true }
    var staleSnapshotRefused = false
    do { try relaunched.publish(.init(snapshot: log.head, frames: [])) }
    catch P.Log.Failure.staleGeneration { staleSnapshotRefused = true }
    try projectionCheck(staleRefused && staleSnapshotRefused && relaunched.head.generation == 2 && relaunched.head.phase == .working,
        "a stale host generation's late frames and snapshot cannot update the log")
    guard case .resnapshot(let fresh) = relaunched.read(after: early.cursor) else {
        throw ProjectionCheckFailure(message: "old-generation cursor paged into a new generation")
    }
    var viewer = early
    _ = viewer.receive(.resnapshot(fresh))
    let lateOld = viewer.receive(.frames(generation: 1, frames: [frame(1, log.head.through + 1, .phase(.failed))], more: false))
    let lateOldSnapshot = viewer.receive(.resnapshot(log.head))
    try projectionCheck(viewer.state == relaunched.head && lateOld == .applied(0) && lateOldSnapshot == .applied(0),
        "a viewer moves to the new generation and ignores the old session's late frames and snapshot")
    var behind = early
    let newer = behind.receive(.frames(generation: 2, frames: [frame(2, 1, .phase(.working))], more: false))
    try projectionCheck(newer == .needsResnapshot(.newerGeneration) && behind.state == early.state,
        "a newer generation's frame without its snapshot asks for a resnapshot")

    // Bounds are deterministic, and a full snapshot fits the request limit.
    var bounded = P.Snapshot(host: host, object: object, generation: 3, history: .excluded, phase: .ready, capabilities: caps)
    let heavy = String(repeating: "\"/\\\n", count: P.maxDeltaBytes / 4)
    var sequence: UInt64 = 0
    for row in 0..<(P.maxRows + 4) {
        for _ in 0..<4 {
            sequence += 1
            try bounded.apply(.init(host: host, object: object, generation: 3, sequence: sequence,
                                    payload: .assistantText(row: String(format: "%064d", row), turn: String(repeating: "t", count: 64), delta: heavy)))
        }
    }
    let encoded = try JSONEncoder().encode(P.PublishReport(epoch: 1, batch: .init(snapshot: bounded, frames: [])))
    try projectionCheck(bounded.rows.count == P.maxRows && bounded.omittedRows == 4 && bounded.rows.allSatisfy { $0.truncated && $0.text.utf8.count <= P.maxRowTextBytes }
        && bounded.valid && encoded.count < 262_144,
        "rows and row text truncate deterministically; a worst-case escaped snapshot is \(encoded.count) bytes, under 256 KiB")
    var invalid = bounded
    let escape = try? invalid.apply(.init(host: host, object: object, generation: 3, sequence: sequence + 1,
        payload: .assistantText(row: "esc", turn: "t", delta: "\u{1B}[31mred")))
    try projectionCheck(escape == nil && P.sanitize("\u{1B}[31mred\u{7}\n") == "[31mred\n",
        "terminal control characters are refused on the wire and stripped by the host sanitizer")

    // Prompt rows: bounded, sanitized, and a worst-case batch still fits.
    let person = SharedArea.ID<SharedArea.Person>(), at = Date(timeIntervalSince1970: 1_800_000_000)
    func promptFrame(_ sequence: UInt64, _ text: String, row: String? = nil) -> P.Frame {
        .init(host: host, object: object, generation: 3, sequence: sequence,
              payload: .prompt(row: row ?? "p\(sequence)", prompt: .init(person: person, at: at), text: text, truncated: false))
    }
    var prompts = bounded
    let tooLong = try? prompts.apply(promptFrame(sequence + 1, String(repeating: "a", count: P.maxRowTextBytes + 1)))
    let controls = try? prompts.apply(promptFrame(sequence + 1, "\u{1B}[31mred"))
    let empty = try? prompts.apply(promptFrame(sequence + 1, ""))
    try prompts.apply(promptFrame(sequence + 1, "Fix the tests"))
    let reused = try? prompts.apply(promptFrame(sequence + 2, "again", row: "p\(sequence + 1)"))
    try projectionCheck(tooLong == nil && controls == nil && empty == nil && reused == nil && prompts.valid
        && prompts.rows.last?.kind == .prompt(person) && prompts.rows.last?.text == "Fix the tests" && prompts.lastPrompt?.person == person
        && prompts.withoutPrompts.rows.count == prompts.rows.count - 1 && prompts.withoutPrompts.valid,
        "a prompt row is refused over \(P.maxRowTextBytes) bytes, with control characters, empty or reusing a row; a valid one names its sender")
    let heavyPrompt = String(repeating: "\"/\\\n", count: P.maxRowTextBytes / 4)
    var worst: [P.Frame] = []
    for index in 0..<P.maxBatchFrames {
        let row = String(format: "%064d", index), sequence = UInt64(index + 1)
        if index < P.maxBatchPromptFrames {
            worst.append(promptFrame(sequence, heavyPrompt, row: row))
        } else {
            let delta = P.Payload.assistantText(row: row, turn: String(repeating: "t", count: 64), delta: heavy)
            worst.append(P.Frame(host: host, object: object, generation: 3, sequence: sequence, payload: delta))
        }
    }
    let worstBatch = try JSONEncoder().encode(P.PublishReport(epoch: 1, batch: .init(snapshot: nil, frames: worst)))
    try projectionCheck(worstBatch.count < 262_144,
        "a worst-case batch of \(P.maxBatchPromptFrames) full prompt rows and escaped deltas is \(worstBatch.count) bytes, under 256 KiB")

    // Controls: only routed actions, for any member who may prompt (full access).
    let wire = try JSONDecoder().decode(P.Capabilities.self,
        from: Data(#"{"locallyManaged":false,"canSend":true,"canQueue":true,"canSteer":true,"canInterrupt":true}"#.utf8))
    let full = P.Capabilities(locallyManaged: true, canSend: true, canQueue: true, canSteer: true, canInterrupt: true)
    let holder = P.RemoteControls(host: full, role: .editor), watcher = P.RemoteControls(host: full, role: .viewer)
    let external = P.RemoteControls(host: wire, role: .editor)
    try projectionCheck(holder.send && holder.queue && !holder.steer && !holder.interrupt && !holder.approveProviderRequest
        && !watcher.send && !watcher.queue && !external.send && !external.queue,
        "remote controls: send/queue for an editor of a locally managed agent, never a viewer; steer, interrupt and approvals have no remote route")
}

private func runProjectionHTTPChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-projection-http-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 71, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: label)
        }
        let a = try await person("Source A"), b = try await person("Teammate B"), c = try await person("Excluded C")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let cc = try CollaborationAPI(baseURL: endpoint, credential: c.token, allowsInsecureLoopback: true)
        let state = try await aa.createArea(), area = state.document.id.rawValue
        let invite = try await aa.invite(area: area, request: .init(person: b.identity.person))
        _ = try await bb.accept(code: invite.code)
        let host = try await aa.registerHost(), otherHost = try await bb.registerHost()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let placement = SharedArea.Position(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 400, height: 300))
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: 0,
            edits: [.admit(item, placement)])))
        let object = item.id
        func frame(_ generation: UInt64, _ sequence: UInt64, _ payload: P.Payload, host frameHost: SharedArea.ID<SharedArea.Host>? = nil) -> P.Frame {
            .init(host: frameHost ?? host.id, object: object, generation: generation, sequence: sequence, payload: payload)
        }
        let caps = P.Capabilities(locallyManaged: true, canSend: true, canQueue: true, canSteer: true, canInterrupt: true)
        let snapshot = P.Snapshot(host: host.id, object: object, generation: 1, history: .excluded, phase: .ready, capabilities: caps)

        try await projectionRefuses(409, "frames without any snapshot are refused: the host must establish state first") {
            try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
                batch: .init(snapshot: nil, frames: [frame(1, 1, .turnStarted(turn: "a"))])))
        }
        try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
            batch: .init(snapshot: snapshot, frames: [frame(1, 1, .turnStarted(turn: "a")), frame(1, 2, .assistantText(row: "r", turn: "a", delta: "Shared answer"))])))
        let joined = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: nil)
        guard case .resnapshot(let head) = joined else { throw ProjectionCheckFailure(message: "late join was not a snapshot") }
        try projectionCheck(head.through == 2 && head.rows.first?.text == "Shared answer" && head.phase == .working,
            "teammate B's late join over HTTP receives the snapshot through every published event")
        var replica = P.Replica()
        _ = replica.receive(joined)
        try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
            batch: .init(snapshot: nil, frames: [frame(1, 3, .turnCompleted(turn: "a", outcome: .completed))])))
        let tail = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: replica.cursor)
        guard case .frames(1, let frames, false) = tail, frames.map(\.sequence) == [3] else { throw ProjectionCheckFailure(message: "tail read was not the one new frame") }
        _ = replica.receive(tail)
        try projectionCheck(replica.state?.phase == .ready && replica.state?.through == 3, "B's cursor read returns exactly the new tail frame")

        // A prompt crosses as its sender and the words they typed (0.7.38).
        let asked = P.LastPrompt(person: b.identity.person, at: Date(timeIntervalSince1970: 1_800_000_000))
        try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
            batch: .init(snapshot: nil, frames: [frame(1, 4, .prompt(row: "p1", prompt: asked, text: "Summarise the diff, please", truncated: false))])))
        let prompted = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: replica.cursor)
        guard case .frames(1, let promptFrames, false) = prompted, promptFrames.map(\.sequence) == [4] else {
            throw ProjectionCheckFailure(message: "the prompt frame did not read back as the one new frame")
        }
        _ = replica.receive(prompted)
        try projectionCheck(replica.state?.rows.last == P.Row(id: "p1", turn: nil, kind: .prompt(b.identity.person), text: "Summarise the diff, please", sequence: 4)
            && replica.state?.lastPrompt == asked && replica.state?.through == 4,
            "a published prompt reads back over HTTP as a prompt row naming its sender, and sets who sent the last prompt")
        // A 0.7.37 reader sends no `prompts`: the same positions, with each
        // prompt as `.prompted` and no prompt row, so its decoder never meets one.
        func legacyRead(_ cursor: P.Cursor?) async throws -> (Data, P.Read) {
            var request = URLRequest(url: endpoint.appendingPathComponent("collaboration/v1/areas/\(area)/agents/\(object.rawValue)/projection/read"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(b.token)", forHTTPHeaderField: "authorization")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(["cursor": cursor])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProjectionCheckFailure(message: "legacy read refused") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (data, try decoder.decode(P.Read.self, from: data))
        }
        let (legacyTailBytes, legacyTail) = try await legacyRead(.init(generation: 1, through: 3))
        let (legacyJoinBytes, legacyJoin) = try await legacyRead(nil)
        let legacyBytes = String(decoding: legacyTailBytes + legacyJoinBytes, as: UTF8.self)
        guard case .frames(1, let legacyFrames, false) = legacyTail, case .resnapshot(let legacyHead) = legacyJoin else {
            throw ProjectionCheckFailure(message: "legacy reads changed shape")
        }
        try projectionCheck(legacyFrames.map(\.payload) == [.prompted(asked)] && legacyFrames.map(\.sequence) == [4]
            && legacyHead.through == 4 && legacyHead.lastPrompt == asked && !legacyHead.hasPromptRows && legacyHead.valid
            && !legacyBytes.contains("\"prompt\"") && !legacyBytes.contains("Summarise"),
            "a 0.7.37 reader gets the prompt as \"who and when\" at the same sequence, with no prompt row or text it cannot decode")
        // What a relay answers a payload its decoder has no case for (a 0.7.37
        // relay meeting a prompt): 400 invalidRequest, which the host's sink
        // reads as `.unreadable`. Nothing is stored.
        var future = URLRequest(url: endpoint.appendingPathComponent("collaboration/v1/areas/\(area)/agents/\(object.rawValue)/projection"))
        future.httpMethod = "POST"
        future.setValue("Bearer \(a.token)", forHTTPHeaderField: "authorization")
        future.setValue("application/json", forHTTPHeaderField: "content-type")
        let valid = String(decoding: try JSONEncoder().encode(P.PublishReport(epoch: 1,
            batch: .init(snapshot: nil, frames: [frame(1, 5, .phase(.working))]))), as: UTF8.self)
        let unknown = valid.replacingOccurrences(of: #"{"phase":{"_0":"working"}}"#, with: #"{"futureCase":{"row":"f"}}"#)
        guard unknown != valid else { throw ProjectionCheckFailure(message: "could not substitute an unknown payload case into \(valid)") }
        future.httpBody = Data(unknown.utf8)
        let (futureBody, futureResponse) = try await URLSession.shared.data(for: future)
        let futureCode = try? JSONDecoder().decode(Collaboration.ErrorBody.self, from: futureBody).code
        try projectionCheck((futureResponse as? HTTPURLResponse)?.statusCode == 400 && futureCode == "invalidRequest",
            "a relay refuses a payload case it cannot decode with 400 invalidRequest (got \((futureResponse as? HTTPURLResponse)?.statusCode ?? 0) \(futureCode ?? "-"))")
        // A 0.7.37 relay cannot decode a prompt; the host resends the same
        // positions without them, which this relay (and that one) accepts.
        let stripped = P.Batch(snapshot: nil, frames: [frame(1, 5, .prompt(row: "p2", prompt: asked, text: "Again", truncated: false))]).withoutPrompts
        try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1, batch: stripped))
        let afterStripped = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: replica.cursor)
        _ = replica.receive(afterStripped)
        try projectionCheck(!stripped.carriesPrompts && replica.state?.through == 5 && replica.state?.rows.last?.id == "p1",
            "a prompt delivered without its row keeps the sequence contiguous and adds no row")

        try await projectionRefuses(409, "a host gap is refused rather than stored as continuity") {
            try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
                batch: .init(snapshot: nil, frames: [frame(1, 7, .phase(.failed))])))
        }
        try await projectionRefuses(403, "teammate B cannot forge frames for A's host") {
            try await bb.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
                batch: .init(snapshot: nil, frames: [frame(1, 6, .phase(.failed))])))
        }
        try await projectionRefuses(403, "B's own registered host cannot publish A's observation") {
            let forged = P.Snapshot(host: otherHost.id, object: object, generation: 9, history: .excluded, phase: .failed, capabilities: .none)
            try await bb.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
                batch: .init(snapshot: forged, frames: [])))
        }
        try await projectionRefuses(404, "excluded C cannot read the projection") {
            _ = try await cc.readAgentProjection(area: area, object: object.rawValue, cursor: nil)
        }
        try await projectionRefuses(404, "excluded C cannot publish into the area") {
            try await cc.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1, batch: .init(snapshot: snapshot, frames: [])))
        }

        // Relaunch: generation 2 supersedes; generation 1's late frame is refused.
        let relaunched = P.Snapshot(host: host.id, object: object, generation: 2, history: .excluded, phase: .ready, capabilities: caps)
        try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1, batch: .init(snapshot: relaunched, frames: [])))
        try await projectionRefuses(409, "a stale host generation's late frame is refused after relaunch") {
            try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1,
                batch: .init(snapshot: nil, frames: [frame(1, 6, .phase(.failed))])))
        }
        let after = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: replica.cursor)
        guard case .resnapshot(let current) = after, current.generation == 2, current.rows.isEmpty else {
            throw ProjectionCheckFailure(message: "old-generation cursor did not resnapshot to the new session")
        }
        _ = replica.receive(after)
        try projectionCheck(replica.state?.generation == 2 && replica.state?.phase == .ready,
            "B's old-generation cursor gets an explicit resnapshot of the relaunched session")
        let staleEpoch = try? await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 99,
            batch: .init(snapshot: nil, frames: [frame(2, 1, .phase(.working))])))
        try projectionCheck(staleEpoch == nil, "a publish against a stale membership epoch is refused")

        // Unpublish removes the retained projection for everyone.
        let revision = try await aa.state(area: area).document.revision
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: revision, edits: [.remove(object)])))
        try await projectionRefuses(404, "after unpublishing, B can no longer read the projection") {
            _ = try await bb.readAgentProjection(area: area, object: object.rawValue, cursor: nil)
        }
        try await projectionRefuses(403, "after unpublishing, the host can no longer publish it") {
            try await aa.publishAgentProjection(area: area, object: object.rawValue, report: .init(epoch: 1, batch: .init(snapshot: relaunched, frames: [])))
        }
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}
