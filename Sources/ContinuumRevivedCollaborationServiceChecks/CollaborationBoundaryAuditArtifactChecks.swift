import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

// COL-20 continued: artifact routes and retention under the same adversarial
// A/B/C rules as CollaborationBoundaryAuditChecks. Real NIO routes, a store
// that compacts after every command, and an injectable clock for the
// dispatch authority window.

private struct ArtifactAuditFailure: Error { let message: String }
private func audit(_ value: Bool, _ label: String) throws {
    guard value else { throw ArtifactAuditFailure(message: label) }
    print("PASS boundary audit: \(label)")
}
private final class ArtifactAuditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

let auditBlobSentinel = "col20-blob-sentinel-3e8a"
let auditDraftSentinel = "col20-draft-sentinel-b07c"
// No "/" in the sentinel itself: JSON may escape it as "\/" and hide a leak.
let auditPathSentinel = "col20-path-sentinel-dir"
let auditReviewSentinel = "col20-review-sentinel-61f9"
private let latePostSentinel = "col20-late-post-sentinel-d2a4"

private struct ArtifactWire: Sendable {
    let base: URL
    func send(_ method: String, _ path: String, token: String?, body: Data? = nil, header: (String, String)? = nil) async throws -> (Int, Data, String?) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 10
        request.httpBody = method == "GET" ? nil : body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let header { request.setValue(header.1, forHTTPHeaderField: header.0) }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, bytes, http.value(forHTTPHeaderField: "cache-control"))
    }
    func json<T: Encodable>(_ method: String, _ path: String, token: String?, _ value: T, header: (String, String)? = nil) async throws -> (Int, Data) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let (status, bytes, _) = try await send(method, path, token: token, body: try encoder.encode(value), header: header)
        return (status, bytes)
    }
    func get(_ path: String, token: String?) async throws -> (Int, Data) {
        let (status, bytes, _) = try await send("GET", path, token: token)
        return (status, bytes)
    }
    func decode<T: Decodable>(_ type: T.Type, _ response: (Int, Data), _ expected: Int = 200, _ label: String) throws -> T {
        guard response.0 == expected else {
            throw ArtifactAuditFailure(message: "\(label): expected \(expected), got \(response.0) \(String(decoding: response.1, as: UTF8.self))")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: response.1)
    }
}

private func clean(_ bytes: Data, _ secrets: [String]) -> Bool {
    let text = String(decoding: bytes, as: UTF8.self)
    return !secrets.contains { text.contains($0) }
}

/// One included entry carrying `bytes` at `path`.
func auditManifest(object: SharedArea.ID<SharedArea.Object>, parent: SharedArea.ID<Collaboration.Artifact.RevisionTag>? = nil,
                   path: String, bytes: Data) -> Collaboration.Artifact.Manifest {
    typealias A = Collaboration.Artifact
    return A.Manifest(object: object, parent: parent, kind: .diff, base: .init(head: String(repeating: "a", count: 40)),
        declaration: .init(range: .workingTree, includesCommitted: false, includesStaged: true, includesUnstaged: true,
                           includesUntracked: false, omittedChangedPaths: 0, omittedUntrackedPaths: 0),
        entries: [.init(path: path, change: .modified, coverage: .included, blob: A.digest(bytes), length: bytes.count,
                        mediaType: "text/x-diff", sourceDigest: "")],
        capturedAt: 1_800_000_000_000)
}

func runCollaborationArtifactRetentionAuditChecks() async throws {
    typealias A = Collaboration.Artifact
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-audit-artifacts-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ArtifactAuditClock(), key = Data(repeating: 92, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    // Compact as soon as anything is behind a two-operation tail.
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() },
        retention: .init(operationTail: 2, operationAge: 0, compactionBatch: 1, dispatchAuthorityWindow: 900))
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let wire = ArtifactWire(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration/v1")!)
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await store.redeem(.init(code: enrollment.code, deviceLabel: label))
        }
        let a = try await person("Owner A"), b = try await person("Editor B"), v = try await person("Viewer V")
        let c = try await person("Excluded C"), d = try await person("Late joiner D")
        func invite(_ owner: String, _ area: UUID, _ who: Collaboration.Credential, role: Collaboration.Role = .editor) async throws {
            let code = try wire.decode(Collaboration.Invitation.self, try await wire.json("POST", "areas/\(area)/invitations", token: owner,
                Collaboration.InviteRequest(person: who.identity.person, role: role)), 201, "invite").code
            _ = try wire.decode(Collaboration.Scope.self, try await wire.json("POST", "invitations/accept", token: who.token,
                Collaboration.AcceptInvitation(code: code)), 200, "accept")
        }
        func state(_ token: String, _ area: UUID) async throws -> Collaboration.State {
            try wire.decode(Collaboration.State.self, try await wire.get("areas/\(area)", token: token), 200, "state")
        }
        func apply(_ token: String, _ area: UUID, id: SharedArea.ID<SharedArea.Operation> = .init(), _ edits: [SharedArea.Edit]) async throws -> (Int, Data) {
            let current = try await state(a.token, area)
            return try await wire.json("POST", "areas/\(area)/commands", token: token, Collaboration.Mutation(epoch: current.scope.epoch,
                command: .init(area: .init(area), id: id, expectedRevision: current.document.revision, edits: edits)))
        }
        func epoch(_ area: UUID) async throws -> Int64 { try await state(a.token, area).scope.epoch }
        func remove(_ who: Collaboration.Credential, _ name: String, _ area: UUID) async throws {
            let (status, _, _) = try await wire.send("DELETE", "areas/\(area)/members/\(who.identity.person.rawValue)", token: a.token,
                header: ("if-match", "\(try await epoch(area))"))
            try audit(status == 200, "A removes \(name) from the area")
        }

        // Area X with two published artifacts, an unlisted draft blob, a
        // review, a discussion, an agreement and a published agent.
        let x = try wire.decode(Collaboration.State.self, try await wire.json("POST", "areas", token: a.token, [String: String]()), 201, "area").scope.area.rawValue
        try await invite(a.token, x, b); try await invite(a.token, x, v, role: .viewer)
        let host = try wire.decode(Collaboration.Host.self, try await wire.json("POST", "hosts", token: a.token, [String: String]()), 201, "host")
        let rect = SharedArea.Rect(x: 0, y: 0, width: 300, height: 200)
        func item(_ kind: SharedArea.Kind, sourced: Bool = true) -> SharedArea.Item {
            .init(id: .init(), kind: kind, source: sourced ? .init(owner: a.identity.person, host: host.id, binding: .init()) : nil)
        }
        let art = item(.artifact), art2 = item(.artifact), agent = item(.agentObservation)
        let discussion = item(.discussion, sourced: false), agreement = item(.agreement, sourced: false)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: "Agreement.")
        let bPostID = SharedArea.ID<SharedArea.Operation>()
        let agreementPlacement = SharedArea.ID<SharedArea.Placement>()
        func nudge(_ step: Double) -> SharedArea.Edit { .place(.init(id: agreementPlacement, object: agreement.id, rect: .init(x: step, y: 0, width: 300, height: 200))) }
        try audit(try await apply(a.token, x, [art, art2, agent, discussion].map { .admit($0, .init(id: .init(), object: $0.id, rect: rect)) }
            + [.admit(agreement, .init(id: agreementPlacement, object: agreement.id, rect: rect))]
            + [.context(context), .post(.init(id: .init(), object: discussion.id, author: a.identity.person, text: latePostSentinel))]).0 == 200,
            "seed X with two artifacts, an agent, a discussion and an agreement")
        let bSeed = try await state(a.token, x)
        let bCommand = SharedArea.Command(area: .init(x), id: bPostID, expectedRevision: bSeed.document.revision,
            edits: [.post(.init(id: .init(), object: discussion.id, author: b.identity.person, text: "B note"))])
        try audit(try await wire.json("POST", "areas/\(x)/commands", token: b.token, Collaboration.Mutation(epoch: bSeed.scope.epoch, command: bCommand)).0 == 200,
            "B commits an operation whose receipt must outlive compaction")
        let blob = Data("\(auditBlobSentinel) diff body".utf8), draft = Data("\(auditDraftSentinel) never listed".utf8)
        let blob2 = Data("\(auditBlobSentinel) second artifact".utf8)
        for (object, bytes) in [(art.id, blob), (art.id, draft), (art2.id, blob2)] {
            let (status, _, _) = try await wire.send("PUT", "areas/\(x)/artifacts/\(object.rawValue)/blobs/\(A.digest(bytes))", token: a.token, body: bytes)
            try audit(status == 201, "A uploads an artifact blob")
        }
        let manifest = auditManifest(object: art.id, path: "\(auditPathSentinel)/change.diff", bytes: blob)
        let manifest2 = auditManifest(object: art2.id, path: "second.diff", bytes: blob2)
        for value in [manifest, manifest2] {
            _ = try wire.decode(A.PublishReceipt.self, try await wire.json("POST", "areas/\(x)/artifacts/\(value.object.rawValue)/revisions", token: a.token,
                A.PublishRequest(epoch: try await epoch(x), manifest: value)), 201, "publish")
        }
        _ = try wire.decode(A.Review.self, try await wire.json("POST", "areas/\(x)/artifacts/\(art.id.rawValue)/reviews", token: b.token,
            A.ReviewRequest(epoch: try await epoch(x), revision: manifest.id, verdict: .comment, note: auditReviewSentinel)), 201, "review")
        let digest = A.digest(blob), digest2 = A.digest(blob2), draftDigest = A.digest(draft)
        let blobPath = "areas/\(x)/artifacts/\(art.id.rawValue)/revisions/\(manifest.id.rawValue)/blobs/\(digest)"
        let blob2Path = "areas/\(x)/artifacts/\(art2.id.rawValue)/revisions/\(manifest2.id.rawValue)/blobs/\(digest2)"
        let protected = [auditBlobSentinel, auditDraftSentinel, auditPathSentinel, auditReviewSentinel, latePostSentinel]

        // Counterexample: a member receives bytes, path and review, uncached.
        let memberBlob = try await wire.send("GET", blobPath, token: b.token)
        let memberState = try await wire.get("areas/\(x)/artifacts/\(art.id.rawValue)", token: v.token)
        let memberBlob2 = try await wire.get(blob2Path, token: b.token)
        try audit(memberBlob.0 == 200 && memberBlob.1 == blob && memberBlob.2 == "no-store"
            && !clean(memberState.1, [auditPathSentinel]) && !clean(memberState.1, [auditReviewSentinel]) && memberBlob2.1 == blob2,
            "counterexample: members read blob bytes (no-store), manifest path and review note")

        struct Fingerprint: Equatable { let art: A.State; let art2: A.State; let document: SharedArea.Document }
        func fingerprint() async throws -> Fingerprint {
            .init(art: try wire.decode(A.State.self, try await wire.get("areas/\(x)/artifacts/\(art.id.rawValue)", token: a.token), 200, "art"),
                  art2: try wire.decode(A.State.self, try await wire.get("areas/\(x)/artifacts/\(art2.id.rawValue)", token: a.token), 200, "art2"),
                  document: try await state(a.token, x).document)
        }

        // 1. Excluded C on every artifact route: real IDs answer like random ones.
        let before = try await fingerprint()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        // A body naming its own URL's object: the refusal then depends only
        // on server state, which is what must not differ.
        func publishBody(_ object: UUID) throws -> Data {
            try encoder.encode(A.PublishRequest(epoch: 1, manifest: auditManifest(object: .init(object), parent: manifest.id, path: "c.diff", bytes: blob)))
        }
        let reviewBody = try encoder.encode(A.ReviewRequest(epoch: 1, revision: manifest.id, verdict: .approve, note: "C"))
        let driftBody = try encoder.encode(A.DriftReport(epoch: 1, changedPaths: 1, baseMoved: false))
        typealias Route = (UUID, UUID, UUID) -> String
        let probes: [(String, Route, (UUID) throws -> Data?)] = [
            ("GET", { a, o, _ in "areas/\(a)/artifacts/\(o)" }, { _ in nil }),
            ("GET", { a, o, r in "areas/\(a)/artifacts/\(o)/revisions/\(r)" }, { _ in nil }),
            ("GET", { a, o, r in "areas/\(a)/artifacts/\(o)/revisions/\(r)/blobs/\(digest)" }, { _ in nil }),
            ("PUT", { a, o, _ in "areas/\(a)/artifacts/\(o)/blobs/\(digest)" }, { _ in blob }),
            ("POST", { a, o, _ in "areas/\(a)/artifacts/\(o)/revisions" }, publishBody),
            ("POST", { a, o, _ in "areas/\(a)/artifacts/\(o)/reviews" }, { _ in reviewBody }),
            ("POST", { a, o, r in "areas/\(a)/artifacts/\(o)/revisions/\(r)/drift" }, { _ in driftBody }),
            ("POST", { a, _, _ in "areas/\(a)/updates" }, { _ in try encoder.encode(Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0)) }),
        ]
        for (method, route, body) in probes {
            let ghostObject = UUID()
            let real = try await wire.send(method, route(x, art.id.rawValue, manifest.id.rawValue), token: c.token, body: try body(art.id.rawValue))
            let guessed = try await wire.send(method, route(UUID(), ghostObject, UUID()), token: c.token, body: try body(ghostObject))
            guard real.0 == guessed.0, real.1 == guessed.1, real.0 == 404, clean(real.1, protected) else {
                throw ArtifactAuditFailure(message: "excluded C distinguishes \(method) \(route(UUID(), UUID(), UUID())): \(real.0) vs \(guessed.0)")
            }
        }
        try audit(try await fingerprint() == before, "excluded C: \(probes.count) artifact and history routes answer real IDs like random ones and change nothing")

        // 2. Member B forwards artifact pointers.
        let y = try wire.decode(Collaboration.State.self, try await wire.json("POST", "areas", token: c.token, [String: String]()), 201, "area Y").scope.area.rawValue
        try await invite(c.token, y, b)
        let unknown = try await wire.get("areas/\(x)/artifacts/\(UUID())/revisions/\(UUID())/blobs/\(digest)", token: b.token)
        let forwarded = [
            try await wire.get("areas/\(y)/artifacts/\(art.id.rawValue)/revisions/\(manifest.id.rawValue)/blobs/\(digest)", token: b.token),
            try await wire.get("areas/\(x)/artifacts/\(art2.id.rawValue)/revisions/\(manifest.id.rawValue)/blobs/\(digest)", token: b.token),
            try await wire.get("areas/\(x)/artifacts/\(art.id.rawValue)/revisions/\(manifest.id.rawValue)/blobs/\(draftDigest)", token: b.token),
            try await wire.get("areas/\(x)/artifacts/\(art.id.rawValue)/revisions/\(manifest2.id.rawValue)/blobs/\(digest2)", token: b.token),
            try await wire.get("areas/\(x)/artifacts/\(discussion.id.rawValue)/revisions/\(manifest.id.rawValue)/blobs/\(digest)", token: b.token),
        ]
        try audit(unknown.0 == 404 && forwarded.allSatisfy { $0 == unknown },
            "member B: Y path, foreign object, unlisted draft, cross-object revision and non-artifact object all equal an unknown blob")
        let bUpload = try await wire.send("PUT", "areas/\(x)/artifacts/\(art.id.rawValue)/blobs/\(draftDigest)", token: b.token, body: draft)
        let bPublish = try await wire.json("POST", "areas/\(x)/artifacts/\(art.id.rawValue)/revisions", token: b.token,
            A.PublishRequest(epoch: try await epoch(x), manifest: auditManifest(object: art.id, parent: manifest.id, path: "b.diff", bytes: draft)))
        let vReview = try await wire.json("POST", "areas/\(x)/artifacts/\(art.id.rawValue)/reviews", token: v.token,
            A.ReviewRequest(epoch: try await epoch(x), revision: manifest.id, verdict: .approve, note: "viewer"))
        let afterRefusals = try await fingerprint()
        try audit(bUpload.0 == 403 && bPublish.0 == 403 && vReview.0 == 403 && afterRefusals == before,
            "editor B cannot add bytes or revisions to A's artifact, viewer V cannot review, and nothing changed")

        // 3. Unpublish: the member's cached blob URL now equals an unknown one.
        try audit(try await apply(a.token, x, [.remove(art2.id)]).0 == 200, "A unpublishes the second artifact")
        let cached = try await wire.get(blob2Path, token: b.token), ownerCached = try await wire.get(blob2Path, token: a.token)
        let unpublishedState = try await wire.get("areas/\(x)/artifacts/\(art2.id.rawValue)", token: b.token)
        let unknownState = try await wire.get("areas/\(x)/artifacts/\(UUID())", token: b.token)
        try audit(cached.0 == 404 && cached.1 == unknown.1 && ownerCached.0 == 404 && unpublishedState == unknownState,
            "before/after: unpublished artifact's cached blob and state read like an unknown object, even for its owner")

        // 4. Late joiner and the retained-history decision (pinned, see
        // docs/internals/collaboration.md "History on join"). The removed
        // discussion's text stays in shared history; the unpublished
        // artifact's bytes do not, because blobs follow current publication.
        try audit(try await apply(a.token, x, [.remove(discussion.id)]).0 == 200, "A removes the discussion before D joins")
        try await invite(a.token, x, d)
        let lateState = try await wire.get("areas/\(x)", token: d.token)
        let lateBlob = try await wire.get(blob2Path, token: d.token)
        try audit(!clean(lateState.1, [latePostSentinel]) && lateBlob == cached,
            "pinned policy: late joiner D receives a removed discussion's text, never an unpublished artifact's bytes")

        // 5. Retention: compaction ran; a horizon never becomes an oracle.
        let report = try await store.verifyIntegrity()
        try audit((report.horizons[x] ?? 0) > 0, "compaction folded X behind a horizon and the store verifies")
        let behind = Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0)
        let cBehind = try await wire.json("POST", "areas/\(x)/updates", token: c.token, behind)
        let cRandom = try await wire.json("POST", "areas/\(UUID())/updates", token: c.token, behind)
        let bBehind = try await wire.json("POST", "areas/\(x)/updates", token: b.token, behind)
        try audit(cBehind == cRandom && cBehind.0 == 404 && bBehind.0 == 409 && clean(bBehind.1, protected),
            "behind the horizon: excluded C gets the unknown-area answer, member B a content-free 'snapshot required'")
        try await remove(b, "B", x)
        let removedBehind = try await wire.json("POST", "areas/\(x)/updates", token: b.token, behind)
        let removedBlob = try await wire.get(blobPath, token: b.token)
        try audit(removedBehind == cRandom && removedBlob == unknown,
            "before/after: removed B's horizon read and cached blob URL equal an unknown area's")
        // Receipts outlive compaction: B's retired operation ID stays bound.
        let retired = try await store.verifyIntegrity()
        let reuseByA = try await apply(a.token, x, id: bPostID, [nudge(11)])
        // Exact replay of B's retired command by A: without the receipt
        // binding it would come back as B's duplicate receipt.
        let replayByA = try await wire.json("POST", "areas/\(x)/commands", token: a.token, Collaboration.Mutation(epoch: try await epoch(x), command: bCommand))
        try await invite(a.token, x, b)
        let changedByB = try await apply(b.token, x, id: bPostID, [nudge(12)])
        try audit(retired.receipts > retired.retainedOperations && reuseByA.0 == 409 && replayByA.0 == 409 && changedByB.0 == 409,
            "a compacted operation ID cannot be reused or exactly replayed by another person, nor changed by its re-admitted author")

        // 6. Stale queued work across compaction and the authority window.
        let generation = UUID()
        _ = try await wire.json("POST", "areas/\(x)/agent-hosts", token: a.token,
            Collaboration.AgentHostRegistration(epoch: try await epoch(x), object: agent.id, generation: generation))
        func handToB() async throws -> Collaboration.AgentControlState {
            let path = "areas/\(x)/agents/\(agent.id.rawValue)/control", e = try await epoch(x)
            let current = try wire.decode(Collaboration.AgentControlState.self, try await wire.get(path, token: a.token), 200, "control")
            let offer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: b.identity.person)
            let offered = try wire.decode(Collaboration.AgentControlState.self, try await wire.json("POST", path, token: a.token,
                Collaboration.AgentControlMutation(epoch: e, expectedRevision: current.revision, hostGeneration: generation, action: .offer(offer))), 200, "offer")
            return try wire.decode(Collaboration.AgentControlState.self, try await wire.json("POST", path, token: b.token,
                Collaboration.AgentControlMutation(epoch: e, expectedRevision: offered.revision, hostGeneration: generation, action: .accept(offer: offer.id))), 200, "accept")
        }
        func queue(_ control: Collaboration.AgentControlState) async throws -> UUID {
            let id = UUID()
            _ = try wire.decode(Collaboration.AgentDispatchReceipt.self, try await wire.json("POST", "areas/\(x)/agents/\(agent.id.rawValue)/prompts", token: b.token,
                Collaboration.AgentPromptRequest(id: id, epoch: try await epoch(x), controlRevision: control.revision, hostGeneration: generation,
                    contextRevision: context.id, text: "queued under the old grant")), 200, "prompt")
            return id
        }
        func phase(_ id: UUID) async throws -> Collaboration.AgentDispatchPhase {
            try wire.decode(Collaboration.AgentDispatchReceipt.self, try await wire.get("areas/\(x)/agent-commands/\(id)", token: a.token), 200, "receipt").phase
        }
        let stale = try await queue(try await handToB())
        for step in 0..<3 { try audit(try await apply(a.token, x, [nudge(Double(20 + step))]).0 == 200, "A keeps editing so compaction advances") }
        try await remove(b, "B again", x); try await invite(a.token, x, b)
        let claim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
        let staleClaim = try await wire.json("POST", "areas/\(x)/agent-commands/\(stale)/claim", token: a.token, claim)
        let staleAdmit = try await wire.json("POST", "areas/\(x)/agent-commands/\(stale)/admit", token: a.token, claim)
        let stalePhase = try await phase(stale)
        try audit(staleClaim.0 >= 400 && staleAdmit.0 >= 400 && stalePhase != .dispatching && stalePhase != .accepted,
            "a prompt queued before compaction, removal and re-admission cannot be claimed or admitted")
        _ = try await wire.json("POST", "areas/\(x)/agent-hosts", token: a.token,
            Collaboration.AgentHostRegistration(epoch: try await epoch(x), object: agent.id, generation: generation))
        let windowed = try await queue(try await handToB())
        clock.advance(901)
        let lateClaim = try wire.decode(Collaboration.AgentDispatchReceipt.self,
            try await wire.json("POST", "areas/\(x)/agent-commands/\(windowed)/claim", token: a.token, claim), 200, "late claim")
        let pending = try wire.decode([Collaboration.AgentDispatchReceipt].self,
            try await wire.get("areas/\(x)/agent-hosts/\(host.id.rawValue)/commands", token: a.token), 200, "pending")
        let staleFinal = try await phase(stale)
        try audit(lateClaim.phase == .refused && lateClaim.claimID == nil && pending.isEmpty && staleFinal == .refused,
            "past the authority window a still-authorized prompt is refused at claim; nothing stays pending")

        // 7. Storage after compaction: horizon snapshot, blobs, drafts, reviews sealed.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("collaboration.sqlite") }
        for file in files {
            let bytes = try Data(contentsOf: file)
            for secret in protected + [a.token, b.token, c.token] where bytes.range(of: Data(secret.utf8)) != nil {
                throw ArtifactAuditFailure(message: "\(file.lastPathComponent) stores a protected value in plaintext")
            }
        }
        try audit(!files.isEmpty, "database, WAL and SHM keep blobs, drafts, paths, reviews and the horizon snapshot sealed")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
}
