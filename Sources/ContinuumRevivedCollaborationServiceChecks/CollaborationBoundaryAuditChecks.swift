import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import NIOCore
import NIOPosix
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

// COL-20: one adversarial A/B/C audit over the real localhost routes. Every
// refusal is asserted twice: the delivered bytes carry no protected sentinel,
// and the durable state an authorized principal reads is unchanged afterwards.
// Each section also shows the counterexample: the same probe from a principal
// who IS entitled does reach the sentinel, so the probe can see a leak.

private struct AuditFailure: Error { let message: String }
private func audit(_ value: Bool, _ label: String) throws {
    guard value else { throw AuditFailure(message: label) }
    print("PASS boundary audit: \(label)")
}
private final class AuditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
}
private struct NoBody: Encodable {}

/// Raw wire client: status and exact response bytes, no client-side mapping.
private struct Wire: Sendable {
    let base: URL
    func send(_ method: String, _ path: String, token: String?, json: Data? = nil, header: (String, String)? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 10
        request.httpBody = method == "GET" ? nil : json
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let header { request.setValue(header.1, forHTTPHeaderField: header.0) }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, bytes)
    }
    func send<B: Encodable>(_ method: String, _ path: String, token: String?, body: B, header: (String, String)? = nil) async throws -> (Int, Data) {
        try await send(method, path, token: token, json: method == "GET" || method == "DELETE" ? nil : try auditEncoder.encode(body), header: header)
    }
    func value<T: Decodable, B: Encodable>(_ type: T.Type, _ method: String, _ path: String, token: String?, body: B, status: Int = 200) async throws -> T {
        let (actual, bytes) = try await send(method, path, token: token, body: body)
        guard actual == status else { throw AuditFailure(message: "\(method) \(path): expected \(status), got \(actual) \(String(decoding: bytes, as: UTF8.self))") }
        return try auditDecoder.decode(type, from: bytes)
    }
}
private let auditEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
private let auditDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

private let postSentinel = "col20-post-sentinel-7f3a"
private let contextSentinel = "col20-context-sentinel-91be"
private let promptSentinel = "col20-prompt-sentinel-c4d2"
private let partialSentinel = "col20-partial-sentinel-55e0"
private let labelSentinel = "col20-label-sentinel"

private func free(_ bytes: Data, of secrets: [String]) -> Bool {
    let text = String(decoding: bytes, as: UTF8.self)
    return !secrets.contains { !$0.isEmpty && text.contains($0) }
}

func runCollaborationBoundaryAuditChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-audit-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = AuditClock(), key = Data(repeating: 91, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    var credentials: [String] = []
    do {
        let wire = Wire(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration/v1")!)
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            credentials.append(enrollment.code)
            let credential = try await wire.value(Collaboration.Credential.self, "POST", "enrollments/redeem", token: nil,
                body: Collaboration.RedeemEnrollment(code: enrollment.code, deviceLabel: label), status: 201)
            credentials.append(credential.token)
            return credential
        }
        let a = try await person("Owner A \(labelSentinel)"), b = try await person("Editor B"), c = try await person("Excluded C")
        let v = try await person("Viewer V")
        func invite(_ owner: String, _ area: UUID, _ who: Collaboration.Credential, role: Collaboration.Role = .editor) async throws {
            let code = try await wire.value(Collaboration.Invitation.self, "POST", "areas/\(area)/invitations", token: owner,
                body: Collaboration.InviteRequest(person: who.identity.person, role: role), status: 201).code
            credentials.append(code)
            _ = try await wire.value(Collaboration.Scope.self, "POST", "invitations/accept", token: who.token, body: Collaboration.AcceptInvitation(code: code))
        }
        func apply(_ token: String, _ area: UUID, epoch: Int64, revision: UInt64, _ edits: [SharedArea.Edit]) async throws -> (Int, Data) {
            try await wire.send("POST", "areas/\(area)/commands", token: token,
                body: Collaboration.Mutation(epoch: epoch, command: .init(area: .init(area), expectedRevision: revision, edits: edits)))
        }
        func state(_ token: String, _ area: UUID) async throws -> Collaboration.State {
            try await wire.value(Collaboration.State.self, "GET", "areas/\(area)", token: token, body: NoBody())
        }
        func receipt(_ token: String, _ area: UUID, _ id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
            try await wire.value(Collaboration.AgentDispatchReceipt.self, "GET", "areas/\(area)/agent-commands/\(id)", token: token, body: NoBody())
        }
        func control(_ token: String, _ area: UUID, _ object: SharedArea.ID<SharedArea.Object>) async throws -> Collaboration.AgentControlState {
            try await wire.value(Collaboration.AgentControlState.self, "GET", "areas/\(area)/agents/\(object.rawValue)/control", token: token, body: NoBody())
        }
        func change(_ token: String, _ area: UUID, _ object: SharedArea.ID<SharedArea.Object>, _ mutation: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState {
            try await wire.value(Collaboration.AgentControlState.self, "POST", "areas/\(area)/agents/\(object.rawValue)/control", token: token, body: mutation)
        }
        func prompt(_ token: String, _ area: UUID, _ object: SharedArea.ID<SharedArea.Object>, _ request: Collaboration.AgentPromptRequest) async throws -> (Int, Data) {
            try await wire.send("POST", "areas/\(area)/agents/\(object.rawValue)/prompts", token: token, body: request)
        }
        func handTo(_ who: Collaboration.Credential, _ area: UUID, _ object: SharedArea.ID<SharedArea.Object>, epoch: Int64) async throws -> Collaboration.AgentControlState {
            let current = try await control(a.token, area, object)
            let offer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: who.identity.person)
            let offered = try await change(a.token, area, object, .init(epoch: epoch, expectedRevision: current.revision, hostGeneration: current.hostGeneration, action: .offer(offer)))
            return try await change(who.token, area, object, .init(epoch: epoch, expectedRevision: offered.revision, hostGeneration: current.hostGeneration, action: .accept(offer: offer.id)))
        }

        // Area X: A owns, B edits, V views, C is excluded. It holds a post, an
        // agreement revision, a published agent with a host, usage and a prompt.
        let x = try await wire.value(Collaboration.State.self, "POST", "areas", token: a.token, body: NoBody(), status: 201).scope.area.rawValue
        try await invite(a.token, x, b); try await invite(a.token, x, v, role: .viewer)
        let hostA = try await wire.value(Collaboration.Host.self, "POST", "hosts", token: a.token, body: NoBody(), status: 201)
        let discussion = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let agent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: hostA.id, binding: .init()))
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: contextSentinel)
        let rect = SharedArea.Rect(x: 0, y: 0, width: 400, height: 300)
        let seeded = try await apply(a.token, x, epoch: 1, revision: 0, [
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: rect)),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 420, y: 0, width: 400, height: 300))),
            .admit(agent, .init(id: .init(), object: agent.id, rect: .init(x: 840, y: 0, width: 400, height: 300))),
            .context(context),
            .post(.init(id: .init(), object: discussion.id, author: a.identity.person, text: postSentinel)),
        ])
        try audit(seeded.0 == 200, "seed area X with post, agreement revision and published agent")
        let generation = UUID()
        _ = try await wire.value(Collaboration.AgentControlState.self, "POST", "areas/\(x)/agent-hosts", token: a.token,
            body: Collaboration.AgentHostRegistration(epoch: 1, object: agent.id, generation: generation))
        var held = try await handTo(b, x, agent.id, epoch: 1)
        let queuedID = UUID()
        let queued = try await prompt(b.token, x, agent.id, .init(id: queuedID, epoch: 1, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: context.id, text: promptSentinel))
        try audit(queued.0 == 200, "B queues a prompt carrying the prompt sentinel")
        let usage = Collaboration.UsageReport(epoch: 1, snapshot: .init(host: hostA.id, sequence: 1, inputTokens: 987_654_321, outputTokens: 17,
            todayInputTokens: 42, todayOutputTokens: 7, dayUTC: "2027-01-15", observedSince: clock.now(), measuredAt: clock.now(),
            coveredAgents: 1, runningAgents: 1, partial: false))
        try audit(try await wire.send("POST", "areas/\(x)/usage", token: a.token, body: usage).0 == 200, "A reports host usage for X")
        let presenceA = try await wire.value(Collaboration.PresenceSession.self, "POST", "areas/\(x)/presence-sessions", token: a.token, body: NoBody(), status: 201)
        _ = try await wire.send("POST", "areas/\(x)/presence", token: a.token,
            body: Collaboration.PresenceInput(session: presenceA.id, sequence: 1, cursor: .init(x: 12, y: 34)))
        let protected = [postSentinel, contextSentinel, promptSentinel, labelSentinel, "987654321"]

        // Counterexample: entitled principals do receive these bytes, so the
        // sentinel probe is able to observe a leak when one exists.
        let entitled = try await wire.send("GET", "areas/\(x)", token: b.token, json: nil)
        let entitledUpdates = try await wire.send("POST", "areas/\(x)/updates", token: v.token,
            body: Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0))
        let entitledReceipt = try await wire.send("GET", "areas/\(x)/agent-commands/\(queuedID)", token: a.token, json: nil)
        try audit(!free(entitled.1, of: [postSentinel]) && !free(entitled.1, of: [contextSentinel])
            && !free(entitledUpdates.1, of: [postSentinel]) && !free(entitledUpdates.1, of: [labelSentinel]) && !free(entitledUpdates.1, of: ["987654321"])
            && !free(entitledReceipt.1, of: [promptSentinel]),
            "counterexample: members read post/context/history/presence/usage and the source owner reads the prompt")

        // Fingerprint of everything an excluded probe could change.
        struct Fingerprint: Equatable {
            let document: SharedArea.Document
            let dispatch: Collaboration.AgentDispatchReceipt
            let control: Collaboration.AgentControlState
            let presence: [String]
            let epoch: Int64
        }
        func fingerprint() async throws -> Fingerprint {
            let updates = try await wire.value(Collaboration.Updates.self, "POST", "areas/\(x)/updates", token: a.token,
                body: Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0))
            return .init(document: try await state(a.token, x).document, dispatch: try await receipt(a.token, x, queuedID),
                control: try await control(a.token, x, agent.id),
                presence: updates.presence.map { "\($0.identity.device) \($0.cursor?.x ?? -1) \($0.usage?.inputTokens ?? 0)" },
                epoch: updates.scope.epoch)
        }

        // 1. Excluded C: every nested route answers a guessed real ID exactly
        // like a random one, leaks nothing, and changes nothing.
        let before = try await fingerprint()
        let ghost = UUID(), ghostObject = UUID(), ghostCommand = UUID(), ghostHost = UUID()
        let claimBody = try auditEncoder.encode(Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation))
        typealias Route = (UUID, UUID, UUID, UUID) -> String
        let mutation = try auditEncoder.encode(Collaboration.Mutation(epoch: 1, command: .init(area: .init(x), expectedRevision: 1,
            edits: [.post(.init(id: .init(), object: discussion.id, author: c.identity.person, text: "C intrusion"))])))
        let controlBody = try auditEncoder.encode(Collaboration.AgentControlMutation(epoch: 1, expectedRevision: held.revision,
            hostGeneration: generation, action: .reclaim))
        let promptBody = try auditEncoder.encode(Collaboration.AgentPromptRequest(epoch: 1, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: context.id, text: "C prompt"))
        let outcomeBody = try auditEncoder.encode(Collaboration.AgentHostOutcome(claim: .init(claimID: UUID(), hostGeneration: generation), phase: .refused))
        let updatesBody = try auditEncoder.encode(Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0))
        let presenceBody = try auditEncoder.encode(Collaboration.PresenceInput(session: presenceA.id, sequence: 9, cursor: .init(x: 1, y: 1)))
        let inviteBody = try auditEncoder.encode(Collaboration.InviteRequest(person: c.identity.person, role: .editor))
        let usageBody = try auditEncoder.encode(usage)
        let hostBody = try auditEncoder.encode(Collaboration.AgentHostRegistration(epoch: 1, object: agent.id, generation: UUID()))
        let ifMatch: (String, String)? = ("if-match", "1")
        let probes: [(String, Route, Data?, (String, String)?)] = [
            ("GET", { a, _, _, _ in "areas/\(a)" }, nil, nil),
            ("POST", { a, _, _, _ in "areas/\(a)/updates" }, updatesBody, nil),
            ("DELETE", { a, _, _, _ in "areas/\(a)/updates/\(UUID())" }, nil, nil),
            ("POST", { a, _, _, _ in "areas/\(a)/presence-sessions" }, Data(), nil),
            ("POST", { a, _, _, _ in "areas/\(a)/presence" }, presenceBody, nil),
            ("DELETE", { a, _, _, _ in "areas/\(a)/presence-sessions/\(presenceA.id)" }, nil, nil),
            ("POST", { a, _, _, _ in "areas/\(a)/invitations" }, inviteBody, nil),
            ("POST", { a, _, _, _ in "areas/\(a)/commands" }, mutation, nil),
            ("DELETE", { a, _, _, _ in "areas/\(a)/members/\(b.identity.person.rawValue)" }, nil, ifMatch),
            ("POST", { a, _, _, _ in "areas/\(a)/usage" }, usageBody, nil),
            ("POST", { a, _, _, _ in "areas/\(a)/agent-hosts" }, hostBody, nil),
            ("GET", { a, o, _, _ in "areas/\(a)/agents/\(o)/control" }, nil, nil),
            ("POST", { a, o, _, _ in "areas/\(a)/agents/\(o)/control" }, controlBody, nil),
            ("POST", { a, o, _, _ in "areas/\(a)/agents/\(o)/prompts" }, promptBody, nil),
            ("GET", { a, _, _, h in "areas/\(a)/agent-hosts/\(h)/commands" }, nil, nil),
            ("GET", { a, _, d, _ in "areas/\(a)/agent-commands/\(d)" }, nil, nil),
            ("POST", { a, _, d, _ in "areas/\(a)/agent-commands/\(d)/claim" }, claimBody, nil),
            ("POST", { a, _, d, _ in "areas/\(a)/agent-commands/\(d)/admit" }, claimBody, nil),
            ("POST", { a, _, d, _ in "areas/\(a)/agent-commands/\(d)/outcome" }, outcomeBody, nil),
            // Artifact/blob/history paths that do not exist yet must not
            // distinguish a real area either (COL-16/19 add them later).
            ("GET", { a, o, _, _ in "areas/\(a)/artifacts/\(o)" }, nil, nil),
            ("GET", { a, o, _, _ in "areas/\(a)/artifacts/\(o)/blob" }, nil, nil),
            ("GET", { a, _, _, _ in "areas/\(a)/history" }, nil, nil),
        ]
        for (method, route, json, header) in probes {
            let real = try await wire.send(method, route(x, agent.id.rawValue, queuedID, hostA.id.rawValue), token: c.token, json: json, header: header)
            let guessed = try await wire.send(method, route(ghost, ghostObject, ghostCommand, ghostHost), token: c.token, json: json, header: header)
            let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let label = "\(method) \(route(zero, zero, zero, zero))"
            guard real.0 == guessed.0, real.1 == guessed.1, (400..<500).contains(real.0), free(real.1, of: protected) else {
                throw AuditFailure(message: "excluded C distinguishes or leaks \(label): \(real.0) \(String(decoding: real.1, as: UTF8.self)) vs \(guessed.0)")
            }
        }
        try audit(try await fingerprint() == before, "excluded C: \(probes.count) nested routes answer real IDs exactly like random ones and change nothing")

        // 2. Member B forwards pointers across areas it legitimately belongs to.
        let y = try await wire.value(Collaboration.State.self, "POST", "areas", token: c.token, body: NoBody(), status: 201).scope.area.rawValue
        try await invite(c.token, y, b)
        let yAgreement = SharedArea.Item(id: .init(), kind: .agreement)
        let yContext = SharedArea.Context(id: .init(), object: yAgreement.id, parent: nil, author: c.identity.person, text: "Y-only agreement")
        _ = try await apply(c.token, y, epoch: 1, revision: 0, [.admit(yAgreement, .init(id: .init(), object: yAgreement.id, rect: rect)), .context(yContext)])
        let xBefore = try await state(a.token, x).document.canonicalData(), yBefore = try await state(c.token, y).document.canonicalData()
        let xPostInY = try await apply(b.token, y, epoch: 1, revision: 1, [.post(.init(id: .init(), object: discussion.id, author: b.identity.person, text: "forwarded"))])
        let yContextInX = try await apply(b.token, x, epoch: 1, revision: 1, [.post(.init(id: .init(), object: discussion.id, author: b.identity.person, text: "pinned", context: yContext.id))])
        let yPromptID = UUID()
        let yContextPrompt = try await prompt(b.token, x, agent.id, .init(id: yPromptID, epoch: 1, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: yContext.id, text: "use the other area's agreement"))
        let xDispatchViaY = try await wire.send("GET", "areas/\(y)/agent-commands/\(queuedID)", token: b.token, json: nil)
        let xControlViaY = try await wire.send("GET", "areas/\(y)/agents/\(agent.id.rawValue)/control", token: b.token, json: nil)
        let hostAInY = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: b.identity.person, host: hostA.id, binding: .init()))
        let forgedHost = try await apply(b.token, y, epoch: 1, revision: 1, [.admit(hostAInY, .init(id: .init(), object: hostAInY.id, rect: rect))])
        let staleClaim = try await wire.send("POST", "areas/\(x)/agent-commands/\(queuedID)/claim", token: b.token, json: claimBody)
        try audit(xPostInY.0 == 400 && yContextInX.0 == 400 && yContextPrompt.0 == 409 && xDispatchViaY.0 == 404 && xControlViaY.0 == 404
            && forgedHost.0 == 403 && staleClaim.0 == 403,
            "member B: X object in Y, Y revision in X, X dispatch/control via Y, A's host in Y and a recipient claim are all refused")
        try audit([xPostInY, yContextInX, yContextPrompt, xDispatchViaY, xControlViaY, forgedHost, staleClaim].allSatisfy { free($0.1, of: protected) },
            "forwarded-pointer refusals carry no protected bytes")
        let yPromptReceipt = try await wire.send("GET", "areas/\(x)/agent-commands/\(yPromptID)", token: b.token, json: nil)
        let xAfter = try await state(a.token, x).document.canonicalData(), yAfter = try await state(c.token, y).document.canonicalData()
        let queuedAfter = try await receipt(a.token, x, queuedID).phase
        try audit(xAfter == xBefore && yAfter == yBefore && yPromptReceipt.0 == 404 && queuedAfter == .queued,
            "forwarded pointers leave both areas, the refused prompt and the queued dispatch unchanged")

        // 3. Viewer V shares the area but not the prompt channel.
        let viewerReceipt = try await wire.send("GET", "areas/\(x)/agent-commands/\(queuedID)", token: v.token, json: nil)
        let viewerPrompt = try await prompt(v.token, x, agent.id, .init(epoch: 1, controlRevision: held.revision, hostGeneration: generation,
            contextRevision: context.id, text: "viewer prompt"))
        let viewerHosts = try await wire.send("GET", "areas/\(x)/agent-hosts/\(hostA.id.rawValue)/commands", token: v.token, json: nil)
        try audit(viewerReceipt.0 == 403 && viewerPrompt.0 == 403 && viewerHosts.0 == 403
            && [viewerReceipt, viewerPrompt, viewerHosts].allSatisfy { free($0.1, of: [promptSentinel]) },
            "viewer V cannot read another person's prompt, prompt the agent or poll A's host queue")

        // 4. Revocation with stale queued work. The host fetched its pending
        // list, then went offline; B is removed, re-invited and replays.
        let pending = try await wire.value([Collaboration.AgentDispatchReceipt].self, "GET", "areas/\(x)/agent-hosts/\(hostA.id.rawValue)/commands", token: a.token, body: NoBody())
        try audit(pending.map(\.command.id) == [queuedID], "host caches a pending list holding B's prompt before going offline")
        let epoch1 = try await state(a.token, x).scope.epoch
        try audit(try await wire.send("DELETE", "areas/\(x)/members/\(b.identity.person.rawValue)", token: a.token, json: nil, header: ("if-match", "\(epoch1)")).0 == 200,
            "A removes B while the host is offline")
        let removedRead = try await wire.send("GET", "areas/\(x)", token: b.token, json: nil)
        let removedHistory = try await wire.send("POST", "areas/\(x)/updates", token: b.token, body: Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0))
        let removedReceipt = try await wire.send("GET", "areas/\(x)/agent-commands/\(queuedID)", token: b.token, json: nil)
        let randomRead = try await wire.send("GET", "areas/\(UUID())", token: b.token, json: nil)
        try audit(removedRead == randomRead && removedHistory.0 == 404 && removedReceipt.0 == 404
            && [removedRead, removedHistory, removedReceipt].allSatisfy { free($0.1, of: protected) },
            "before/after: removed B now reads X, its history and its own prompt exactly like an unknown area")
        let claim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
        let staleHostClaim = try await wire.send("POST", "areas/\(x)/agent-commands/\(queuedID)/claim", token: a.token, body: claim)
        let staleHostAdmit = try await wire.send("POST", "areas/\(x)/agent-commands/\(queuedID)/admit", token: a.token, body: claim)
        let afterStale = try await receipt(a.token, x, queuedID)
        try audit([403, 404].contains(staleHostClaim.0) && [403, 404].contains(staleHostAdmit.0) && afterStale.phase == .queued && afterStale.claimID == nil,
            "reconnected host's cached claim and admission of the removed member's prompt are refused with no phase change")
        try await invite(a.token, x, b)
        let epoch2 = try await state(b.token, x).scope.epoch
        let replay = try await prompt(b.token, x, agent.id, .init(id: queuedID, epoch: 1, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: context.id, text: promptSentinel))
        let replayReceipt = try auditDecoder.decode(Collaboration.AgentDispatchReceipt.self, from: replay.1)
        let reclaimIdea = try await wire.send("POST", "areas/\(x)/agent-commands/\(queuedID)/admit", token: a.token, body: claim)
        let newerStale = try await prompt(b.token, x, agent.id, .init(epoch: epoch2, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: context.id, text: "post-readmission prompt on the retired grant"))
        try audit(epoch2 == epoch1 + 1 && replayReceipt.phase == .queued && reclaimIdea.0 == 403 && newerStale.0 == 409,
            "re-admission: B's replay returns the inert old receipt, the host still cannot admit it, and the old control grant is dead")
        // The host reconnects for real: it re-registers on the new epoch and
        // its fresh poll resolves the stale prompt instead of dispatching it.
        let reset = try await wire.value(Collaboration.AgentControlState.self, "POST", "areas/\(x)/agent-hosts", token: a.token,
            body: Collaboration.AgentHostRegistration(epoch: epoch2, object: agent.id, generation: generation))
        let fresh = try await wire.value([Collaboration.AgentDispatchReceipt].self, "GET", "areas/\(x)/agent-hosts/\(hostA.id.rawValue)/commands", token: a.token, body: NoBody())
        let staleResolved = try await receipt(a.token, x, queuedID).phase
        try audit(reset.controller == a.identity.person && fresh.isEmpty && staleResolved == .refused,
            "host reconnect re-registers, sees nothing pending and the stale prompt is refused, not dispatched")
        let oldAccept = try await wire.send("POST", "areas/\(x)/agents/\(agent.id.rawValue)/control", token: b.token,
            body: Collaboration.AgentControlMutation(epoch: 1, expectedRevision: 0, hostGeneration: generation, action: .reclaim))
        let controllerAfterReplay = try await control(a.token, x, agent.id).controller
        try audit(oldAccept.0 == 409 && controllerAfterReplay == a.identity.person,
            "an old-epoch control mutation from re-admitted B cannot take control back")

        // Device revocation between claim and admission, and an enrollment
        // code minted by the revoked device.
        held = try await handTo(b, x, agent.id, epoch: epoch2)
        let deviceCode = try await wire.value(Collaboration.Enrollment.self, "POST", "devices/enrollments", token: b.token,
            body: Collaboration.DeviceEnrollmentRequest(), status: 201).code
        credentials.append(deviceCode)
        let claimedID = UUID()
        _ = try await prompt(b.token, x, agent.id, .init(id: claimedID, epoch: epoch2, controlRevision: held.revision,
            hostGeneration: generation, contextRevision: context.id, text: promptSentinel))
        let claim2 = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
        _ = try await wire.value(Collaboration.AgentDispatchReceipt.self, "POST", "areas/\(x)/agent-commands/\(claimedID)/claim", token: a.token, body: claim2)
        try audit(try await wire.send("DELETE", "devices/\(b.identity.device)", token: b.token, json: nil).0 == 200, "B revokes its device after the host claimed")
        let revokedAdmit = try await wire.send("POST", "areas/\(x)/agent-commands/\(claimedID)/admit", token: a.token, body: claim2)
        let revokedRedeem = try await wire.send("POST", "enrollments/redeem", token: nil, body: Collaboration.RedeemEnrollment(code: deviceCode, deviceLabel: "B replacement"))
        let revokedRead = try await wire.send("GET", "areas/\(x)", token: b.token, json: nil)
        let afterRevoke = try await receipt(a.token, x, claimedID)
        try audit(revokedAdmit.0 == 403 && afterRevoke.phase == .claimed && revokedRedeem.0 == 410 && revokedRead.0 == 401 && free(revokedRead.1, of: protected),
            "revoked device: claimed prompt cannot be admitted, its enrollment code is dead and its bearer reads nothing")
        let refused = try await wire.value(Collaboration.AgentDispatchReceipt.self, "POST", "areas/\(x)/agent-commands/\(claimedID)/outcome", token: a.token,
            body: Collaboration.AgentHostOutcome(claim: claim2, phase: .refused))
        let lateAccept = try await wire.send("POST", "areas/\(x)/agent-commands/\(claimedID)/outcome", token: a.token,
            body: Collaboration.AgentHostOutcome(claim: claim2, phase: .accepted))
        let finalPhase = try await receipt(a.token, x, claimedID).phase
        try audit(refused.phase == .refused && lateAccept.0 == 409 && finalPhase == .refused,
            "host records the refusal and a later contradictory 'accepted' cannot rewrite it")

        // 5. Partial and failure outcomes leave no fragments.
        let afterHandoff = try await state(a.token, x)
        let mixed = try await apply(a.token, x, epoch: afterHandoff.scope.epoch, revision: afterHandoff.document.revision, [
            .post(.init(id: .init(), object: discussion.id, author: a.identity.person, text: partialSentinel)),
            .post(.init(id: .init(), object: discussion.id, author: b.identity.person, text: partialSentinel)),
        ])
        let afterMixed = try await state(a.token, x)
        let mixedHistory = try await wire.send("POST", "areas/\(x)/updates", token: a.token,
            body: Collaboration.UpdateRequest(after: afterHandoff.document.revision, waitMilliseconds: 0))
        try audit(mixed.0 == 403 && afterMixed.document == afterHandoff.document && free(mixedHistory.1, of: [partialSentinel]),
            "a batch with one forged edit commits none of its allowed edits and adds no history")
        let triggers = try DatabaseQueue(path: path)
        try await triggers.write { try $0.execute(sql: "CREATE TRIGGER audit_reject_epoch BEFORE UPDATE OF epoch ON areas BEGIN SELECT RAISE(ABORT,'injected'); END") }
        let failedRemoval = try await wire.send("DELETE", "areas/\(x)/members/\(v.identity.person.rawValue)", token: a.token, json: nil, header: ("if-match", "\(epoch2)"))
        let viewerStill = try await wire.send("GET", "areas/\(x)", token: v.token, json: nil)
        let epochAfterFailure = try await state(a.token, x).scope.epoch
        try audit(failedRemoval.0 == 500 && viewerStill.0 == 200 && epochAfterFailure == epoch2,
            "a removal that fails at the epoch bump leaves membership and epoch untouched")
        try await triggers.write { try $0.execute(sql: "DROP TRIGGER audit_reject_epoch") }
        try await triggers.write { try $0.execute(sql: "CREATE TRIGGER audit_reject_dispatch BEFORE INSERT ON agent_dispatches BEGIN SELECT RAISE(ABORT,'injected'); END") }
        let ownerControl = try await wire.value(Collaboration.AgentControlState.self, "POST", "areas/\(x)/agent-hosts", token: a.token,
            body: Collaboration.AgentHostRegistration(epoch: epoch2, object: agent.id, generation: UUID()))
        let failedID = UUID()
        let failedPrompt = try await prompt(a.token, x, agent.id, .init(id: failedID, epoch: epoch2, controlRevision: ownerControl.revision,
            hostGeneration: ownerControl.hostGeneration, contextRevision: context.id, text: partialSentinel))
        let failedReceipt = try await wire.send("GET", "areas/\(x)/agent-commands/\(failedID)", token: a.token, json: nil)
        try audit(failedPrompt.0 == 500 && failedReceipt.0 == 404 && free(failedPrompt.1, of: [partialSentinel]),
            "a prompt whose insert fails leaves no receipt and echoes no text")
        try await triggers.write { try $0.execute(sql: "DROP TRIGGER audit_reject_dispatch") }
        let retried = try await prompt(a.token, x, agent.id, .init(id: failedID, epoch: epoch2, controlRevision: ownerControl.revision,
            hostGeneration: ownerControl.hostGeneration, contextRevision: context.id, text: partialSentinel))
        try audit(retried.0 == 200, "the same prompt ID succeeds once the failure clears")

        // 6. Storage at rest: content, prompts and every credential are sealed or hashed.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("collaboration.sqlite") }
        try audit(!files.isEmpty, "collaboration database files exist to scan")
        for file in files {
            let bytes = try Data(contentsOf: file)
            for secret in [postSentinel, contextSentinel, promptSentinel, partialSentinel] + credentials {
                guard bytes.range(of: Data(secret.utf8)) == nil else {
                    throw AuditFailure(message: "\(file.lastPathComponent) stores a protected value in plaintext")
                }
            }
        }
        try audit(true, "database, WAL and SHM exclude posts, agreements, prompts, tokens, invitation and enrollment codes")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
    try await runRelayProcessLogAudit()
    print("Collaboration boundary audit passed: excluded/guessed/forwarded IDs, viewer, removal and device revocation with stale queued work, partial failures, storage and relay logs.")
}

// MARK: - Relay process logs

private func freeLoopbackPort() async throws -> Int {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
    let port = channel.localAddress?.port
    try await channel.close().get()
    try await group.shutdownGracefully()
    guard let port else { throw AuditFailure(message: "no loopback port") }
    return port
}

/// The deployed `continuum-relay` process, its own stdout/stderr, real HTTP
/// traffic with content, credentials, malformed and refused requests, then SIGTERM.
private func runRelayProcessLogAudit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-logs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) }), port = try await freeLoopbackPort(), adminPort = try await freeLoopbackPort()
    let collaborationPath = root.appendingPathComponent("collaboration.sqlite").path
    let stdoutURL = root.appendingPathComponent("stdout.log"), stderrURL = root.appendingPathComponent("stderr.log")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    // Provision people before the server owns the file; the operator seam is
    // not an HTTP route and its one-time output is not a diagnostic log.
    let operatorStore = try CollaborationStore(path: collaborationPath, masterKey: key)
    let enrollA = try await operatorStore.provisionPerson(label: "Log A \(labelSentinel)")
    let enrollB = try await operatorStore.provisionPerson(label: "Log B")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("continuum-relay")
    process.environment = [
        "RELAY_HOST": "127.0.0.1", "PORT": "\(port)", "RELAY_ADMIN_PORT": "\(adminPort)",
        "RELAY_DATABASE_PATH": root.appendingPathComponent("companion.sqlite").path,
        "RELAY_MASTER_KEY": key.base64EncodedString(),
        "RELAY_COLLABORATION_DATABASE_PATH": collaborationPath,
        "RELAY_COLLABORATION_MASTER_KEY": key.base64EncodedString(),
    ]
    process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
    process.standardError = try FileHandle(forWritingTo: stderrURL)
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let wire = Wire(base: URL(string: "http://127.0.0.1:\(port)/collaboration/v1")!)
    let deadline = Date().addingTimeInterval(15)
    while true {
        if let probe = try? await wire.send("GET", "self", token: nil), probe.0 == 401 { break }
        guard Date() < deadline, process.isRunning else { throw AuditFailure(message: "relay process did not start") }
        try await Task.sleep(for: .milliseconds(50))
    }
    let a = try await wire.value(Collaboration.Credential.self, "POST", "enrollments/redeem", token: nil,
        body: Collaboration.RedeemEnrollment(code: enrollA.code, deviceLabel: "Log A device"), status: 201)
    let b = try await wire.value(Collaboration.Credential.self, "POST", "enrollments/redeem", token: nil,
        body: Collaboration.RedeemEnrollment(code: enrollB.code, deviceLabel: "Log B device"), status: 201)
    let area = try await wire.value(Collaboration.State.self, "POST", "areas", token: a.token, body: NoBody(), status: 201).scope.area.rawValue
    let invitation = try await wire.value(Collaboration.Invitation.self, "POST", "areas/\(area)/invitations", token: a.token,
        body: Collaboration.InviteRequest(person: b.identity.person), status: 201)
    _ = try await wire.value(Collaboration.Scope.self, "POST", "invitations/accept", token: b.token, body: Collaboration.AcceptInvitation(code: invitation.code))
    let thread = SharedArea.Item(id: .init(), kind: .discussion)
    _ = try await wire.value(Collaboration.Receipt.self, "POST", "areas/\(area)/commands", token: a.token, body: Collaboration.Mutation(epoch: 1,
        command: .init(area: .init(area), expectedRevision: 0, edits: [.admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 300, height: 200))),
            .post(.init(id: .init(), object: thread.id, author: a.identity.person, text: postSentinel))])))
    // Refused and malformed traffic: forged author, bad bearer containing
    // content, malformed JSON carrying content, oversized body and a replayed code.
    _ = try await wire.send("POST", "areas/\(area)/commands", token: b.token, body: Collaboration.Mutation(epoch: 1,
        command: .init(area: .init(area), expectedRevision: 1, edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: contextSentinel))])))
    _ = try await wire.send("GET", "areas/\(area)", token: "\(promptSentinel)-not-a-token", json: nil)
    _ = try await wire.send("POST", "areas/\(area)/commands", token: a.token, json: Data("{\"broken\": \"\(promptSentinel)\"".utf8))
    _ = try await wire.send("POST", "areas/\(area)/commands", token: a.token, json: Data(repeating: 65, count: 300_000) + Data(partialSentinel.utf8))
    _ = try await wire.send("POST", "enrollments/redeem", token: nil, body: Collaboration.RedeemEnrollment(code: enrollA.code, deviceLabel: "replay"))
    process.interrupt()
    let stopDeadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < stopDeadline { try await Task.sleep(for: .milliseconds(50)) }
    try audit(!process.isRunning && process.terminationStatus == 0, "relay process stops cleanly on SIGINT")
    let output = try Data(contentsOf: stdoutURL) + Data(contentsOf: stderrURL)
    let text = String(decoding: output, as: UTF8.self)
    try audit(text.contains("\"event\":\"ready\"") && text.contains("\"event\":\"stopped\""),
        "positive control: the relay's own structured log lines were captured")
    let secrets = [postSentinel, contextSentinel, promptSentinel, partialSentinel, labelSentinel, a.token, b.token, invitation.code,
                   enrollA.code, enrollB.code, key.base64EncodedString(), area.uuidString, a.identity.person.rawValue.uuidString]
    for secret in secrets where text.contains(secret) {
        throw AuditFailure(message: "relay log carries a protected value (\(secret.prefix(6))…)")
    }
    try audit(true, "relay stdout/stderr carry no content, labels, IDs, tokens, codes or keys across success, refusal and malformed traffic")
}
