import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct ArtifactCheckFailure: Error { let message: String }
private final class ArtifactClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// COL-16 / COL-07 artifact witnesses through the real NIO routes and the
/// production client: publication, pinned review, applicability, nested blob
/// boundaries, hash mismatch, oversized content and revocation.
func runCollaborationArtifactChecks() async throws {
    typealias A = Collaboration.Artifact
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ArtifactCheckFailure(message: message) }
        print("PASS artifacts: \(message)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-artifact-service-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 43, count: 32), path = root.appendingPathComponent("collaboration.sqlite").path
    let clock = ArtifactClock()
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let base = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func enroll(_ label: String) async throws -> Collaboration.Credential {
            let code = try await store.provisionPerson(label: label)
            return try await store.redeem(.init(code: code.code, deviceLabel: label))
        }
        func api(_ credential: Collaboration.Credential) throws -> CollaborationAPI {
            try CollaborationAPI(baseURL: base, credential: credential.token, allowsInsecureLoopback: true)
        }
        /// Raw request so refusals can be compared byte for byte.
        func raw(_ method: String, _ path: String, _ token: String?, _ body: Data? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: base.appendingPathComponent("collaboration/v1/" + path))
            request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 5
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        func refused(_ label: String, status: Int = 404, code: String? = nil, _ attempt: () async throws -> Void) async throws {
            do { try await attempt(); throw ArtifactCheckFailure(message: "\(label): expected refusal") }
            catch let CollaborationClientError.server(actual, actualCode) {
                try expect(actual == status && (code == nil || code == actualCode), "\(label) refuses (\(actual) \(actualCode))")
            }
        }
        let a = try await enroll("Owner A"), b = try await enroll("Reviewer B"), v = try await enroll("Viewer V"), c = try await enroll("Excluded C")
        let apiA = try api(a), apiB = try api(b), apiV = try api(v)
        let created = try await apiA.createArea()
        let area = created.document.id.rawValue
        for (member, role) in [(b, Collaboration.Role.editor), (v, .viewer)] {
            let invite = try await apiA.invite(area: area, request: .init(person: member.identity.person, role: role))
            _ = try await api(member).accept(code: invite.code)
        }
        let host = try await apiA.registerHost()
        _ = try await apiB.registerHost()
        var revision: UInt64 = 0
        func admitArtifact(_ api: CollaborationAPI, area: UUID, owner: Collaboration.Credential, host: SharedArea.ID<SharedArea.Host>, revision: inout UInt64) async throws -> SharedArea.ID<SharedArea.Object> {
            let item = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: owner.identity.person, host: host, binding: .init()))
            let command = SharedArea.Command(area: .init(area), expectedRevision: revision,
                edits: [.admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 640, height: 480)))])
            revision = try await api.apply(area: area, mutation: .init(epoch: 1, command: command)).revision
            return item.id
        }
        let object = try await admitArtifact(apiA, area: area, owner: a, host: host.id, revision: &revision)
        let sourceless = SharedArea.Item(id: .init(), kind: .artifact)
        let sourcelessCommand = SharedArea.Command(area: .init(area), expectedRevision: revision,
            edits: [.admit(sourceless, .init(id: .init(), object: sourceless.id, rect: .init(x: 0, y: 0, width: 10, height: 10)))])
        try await refused("artifact admitted without a publishing source", status: 400) {
            _ = try await apiA.apply(area: area, mutation: .init(epoch: 1, command: sourcelessCommand))
        }

        // A synthetic capture: the producer's own witness covers git; this
        // leg covers what the service and client do with any capture.
        func capture(_ object: SharedArea.ID<SharedArea.Object>, parent: SharedArea.ID<A.RevisionTag>?, _ text: String,
                     id: SharedArea.ID<A.RevisionTag> = .init()) -> A.Capture {
            let bytes = Data(text.utf8), digest = A.digest(bytes)
            let manifest = A.Manifest(id: id, object: object, parent: parent, kind: .diff, base: .init(head: String(repeating: "a", count: 40)),
                declaration: .init(range: .workingTree, includesCommitted: false, includesStaged: true, includesUnstaged: true,
                                   includesUntracked: false, omittedChangedPaths: 2, omittedUntrackedPaths: 1),
                entries: [.init(path: "src/main.swift", change: .modified, coverage: .included, blob: digest, length: bytes.count,
                                mediaType: "text/x-diff", sourceDigest: String(repeating: "b", count: 64)),
                          .init(path: "assets/logo.png", change: .modified, coverage: .binary, sourceDigest: String(repeating: "c", count: 64))],
                capturedAt: 1_800_000_000_000)
            return .init(manifest: manifest, blobs: [digest: bytes])
        }
        let first = capture(object, parent: nil, "@@ -1 +1 @@\n-old\n+shared-artifact-sentinel-r1\n")
        let receipt = try await apiA.publishArtifact(area: area, epoch: 1, capture: first)
        try expect(receipt.sequence == 1 && !receipt.duplicate, "owner publishes an immutable revision through blob and revision routes")
        let retry = try await apiA.publishArtifact(area: area, epoch: 1, capture: first)
        try expect(retry.duplicate && retry.sequence == 1, "identical retry returns the original receipt")
        let r1 = first.manifest.id.rawValue
        let read = try await apiB.readArtifact(area: area, object: object.rawValue, revision: r1)
        try expect(read.bytes["src/main.swift"] == first.blobs.values.first && read.bytes.count == 1,
                   "teammate reads exact verified bytes; the binary entry carries none")
        try expect(read.record.manifest.declaration.omittedChangedPaths == 2 && read.record.contentDigest == first.manifest.contentDigest,
                   "coverage declaration and content digest survive the round trip")
        _ = try await apiV.readArtifact(area: area, object: object.rawValue)
        try expect(true, "viewer reads the live latest revision")

        // Publication authority.
        try await refused("teammate publishing on the owner's artifact", status: 403) {
            _ = try await apiB.publishArtifact(area: area, epoch: 1, capture: capture(object, parent: .init(r1), "forged"))
        }
        let mismatchDigest = A.digest(Data("declared".utf8))
        let mismatch = try await raw("PUT", "areas/\(area)/artifacts/\(object.rawValue)/blobs/\(mismatchDigest)", a.token, Data("different bytes".utf8))
        try expect(mismatch.0 == 400 && String(decoding: mismatch.1, as: UTF8.self).contains("hashMismatch"), "blob whose bytes do not hash to its name is refused")
        let big = Data(repeating: 0x61, count: A.Limits.blobBytes + 1)
        let oversized = try await raw("PUT", "areas/\(area)/artifacts/\(object.rawValue)/blobs/\(A.digest(big))", a.token, big)
        try expect(oversized.0 == 413, "blob over the 1 MiB budget is refused before storage")
        let ghost = capture(object, parent: .init(r1), "ghost-not-uploaded")
        let ghostPublish = try await raw("POST", "areas/\(area)/artifacts/\(object.rawValue)/revisions", a.token,
                                         try JSONEncoder().encode(A.PublishRequest(epoch: 1, manifest: ghost.manifest)))
        try expect(ghostPublish.0 == 400 && String(decoding: ghostPublish.1, as: UTF8.self).contains("missingBlob"), "revision naming an unstaged blob is refused")
        for bad in ["/etc/passwd", "../outside.txt", "src/../../x", "~/notes"] {
            let base = capture(object, parent: .init(r1), "path probe")
            let e = base.manifest.entries[0], m = base.manifest
            let manifest = A.Manifest(id: m.id, object: m.object, parent: m.parent, kind: m.kind, base: m.base, declaration: m.declaration,
                entries: [.init(path: bad, change: e.change, coverage: e.coverage, blob: e.blob, length: e.length, mediaType: e.mediaType, sourceDigest: e.sourceDigest)],
                capturedAt: m.capturedAt)
            let response = try await raw("POST", "areas/\(area)/artifacts/\(object.rawValue)/revisions", a.token,
                                         try JSONEncoder().encode(A.PublishRequest(epoch: 1, manifest: manifest)))
            try expect(response.0 == 400, "host-style path \(bad) is refused")
        }

        // Pinned review, drift and supersession.
        let approval = try await apiB.reviewArtifact(area: area, object: object.rawValue, request: .init(epoch: 1, revision: .init(r1), verdict: .approve, note: "Looks right"))
        try expect(approval.contentDigest == first.manifest.contentDigest, "review pins the revision's content digest")
        try await refused("viewer review", status: 403) {
            _ = try await apiV.reviewArtifact(area: area, object: object.rawValue, request: .init(epoch: 1, revision: .init(r1), verdict: .approve, note: ""))
        }
        var state = try await apiB.artifactState(area: area, object: object.rawValue)
        try expect(state.reviews.first?.applicability == .current, "approval applies while R1 is the unchanged latest")
        try await refused("teammate reporting drift", status: 403) {
            _ = try await apiB.reportArtifactDrift(area: area, object: object.rawValue, revision: r1, report: .init(epoch: 1, changedPaths: 1, baseMoved: false))
        }
        let drifted = try await apiA.reportArtifactDrift(area: area, object: object.rawValue, revision: r1, report: .init(epoch: 1, changedPaths: 1, baseMoved: false))
        let again = try await apiA.reportArtifactDrift(area: area, object: object.rawValue, revision: r1, report: .init(epoch: 1, changedPaths: 5, baseMoved: true))
        try expect(drifted.drift?.changedPaths == 1 && again.drift == drifted.drift, "source drift is set once and cannot be rewritten")
        state = try await apiB.artifactState(area: area, object: object.rawValue)
        if case .sourceChanged = state.reviews.first?.applicability { try expect(true, "source change invalidates the approval instead of carrying it") }
        else { throw ArtifactCheckFailure(message: "approval still applies after source drift: \(String(describing: state.reviews.first?.applicability))") }
        try await refused("stale parent", status: 409, code: "revisionConflict") {
            _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: capture(object, parent: nil, "stale parent"))
        }
        let second = capture(object, parent: .init(r1), "@@ -1 +1 @@\n-old\n+shared-artifact-sentinel-r2\n")
        // Live wake: B's held subscription returns on publication with the new head.
        let idle = try await store.updates(token: b.token, area: area, request: .init(after: revision, waitMilliseconds: 0))
        try expect(idle.artifactHeads?.first(where: { $0.object == object })?.sequence == 1
                   && idle.artifactHeads?.first(where: { $0.object == object })?.sourceChanged == true
                   && idle.artifactHeads?.first(where: { $0.object == object })?.reviews == 1,
                   "updates page carries the artifact head, its drift and review count")
        let heldStart = Date(), heldRequest = Collaboration.UpdateRequest(after: revision, presenceVersion: idle.presenceVersion, waitMilliseconds: 10_000)
        async let held = store.updates(token: b.token, area: area, request: heldRequest)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: second)
        let woken = try await held
        try expect(Date().timeIntervalSince(heldStart) < 5 && woken.events.isEmpty
                   && woken.artifactHeads?.first(where: { $0.object == object })?.revision == second.manifest.id,
                   "a held subscription wakes on publication and names the new latest revision")
        try await refused("same revision id, different content", status: 409, code: "changedIntent") {
            _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: capture(object, parent: .init(r1), "rewritten", id: second.manifest.id))
        }
        state = try await apiB.artifactState(area: area, object: object.rawValue)
        try expect(state.latest?.manifest.id == second.manifest.id && state.revisions.map(\.sequence) == [1, 2],
                   "live latest advances to R2 while R1 stays listed")
        try expect(state.reviews.count == 1 && state.reviews[0].review.revision.rawValue == r1
                   && state.reviews[0].applicability == .superseded(by: second.manifest.id),
                   "approval stays pinned to R1 and is marked superseded; nothing applies to R2")
        let pinned = try await apiB.readArtifact(area: area, object: object.rawValue, revision: r1)
        let latest = try await apiB.readArtifact(area: area, object: object.rawValue)
        try expect(pinned.bytes == read.bytes && latest.bytes["src/main.swift"] == second.blobs.values.first,
                   "pinned R1 remains byte-identical alongside the different latest")

        // Recipient verification: a tampered blob or record is refused.
        let entry = first.manifest.entries[0]
        do { try A.verify(Data("tampered".utf8), for: entry); throw ArtifactCheckFailure(message: "tampered blob verified") }
        catch A.ValidationFailure.hashMismatch { try expect(true, "reader refuses bytes whose hash does not match the pinned entry") }
        var forgedRecord = read.record
        forgedRecord = A.Record(manifest: second.manifest, sequence: forgedRecord.sequence, publisher: forgedRecord.publisher,
                                host: forgedRecord.host, publishedAt: forgedRecord.publishedAt, contentDigest: forgedRecord.contentDigest)
        do { try A.verify(forgedRecord); throw ArtifactCheckFailure(message: "record with swapped manifest verified") }
        catch A.ValidationFailure.hashMismatch { try expect(true, "reader refuses a record whose manifest does not match its digest") }

        // Nested boundaries: every miss is the same 404 as an unknown id.
        let blobPath = "areas/\(area)/artifacts/\(object.rawValue)/revisions/\(r1)/blobs/\(entry.blob!)"
        let unknown = try await raw("GET", "areas/\(area)/artifacts/\(UUID())/revisions/\(UUID())/blobs/\(entry.blob!)", b.token)
        try expect(unknown.0 == 404, "unknown artifact is 404")
        func sameMiss(_ label: String, _ path: String, _ token: String) async throws {
            let response = try await raw("GET", path, token)
            try expect(response.0 == 404 && response.1 == unknown.1 && !String(decoding: response.1, as: UTF8.self).contains("sentinel"),
                       "\(label) gets the unknown-id 404 with no content")
        }
        try await sameMiss("excluded C reading a published blob", blobPath, c.token)
        try await sameMiss("excluded C reading artifact state", "areas/\(area)/artifacts/\(object.rawValue)", c.token)
        let staged = Data("staged-but-unpublished-sentinel".utf8)
        _ = try await raw("PUT", "areas/\(area)/artifacts/\(object.rawValue)/blobs/\(A.digest(staged))", a.token, staged)
        try await sameMiss("staged blob guessed through a published revision", "areas/\(area)/artifacts/\(object.rawValue)/revisions/\(r1)/blobs/\(A.digest(staged))", b.token)
        let sibling = try await admitArtifact(apiA, area: area, owner: a, host: host.id, revision: &revision)
        let siblingCapture = capture(sibling, parent: nil, "sibling-object-sentinel")
        _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: siblingCapture)
        try await sameMiss("sibling object's digest through R1", "areas/\(area)/artifacts/\(object.rawValue)/revisions/\(r1)/blobs/\(siblingCapture.manifest.entries[0].blob!)", b.token)
        try await sameMiss("R1 addressed under the sibling object", "areas/\(area)/artifacts/\(sibling.rawValue)/revisions/\(r1)/blobs/\(entry.blob!)", b.token)
        let other = try await apiA.createArea()
        var otherRevision: UInt64 = 0
        let otherObject = try await admitArtifact(apiA, area: other.document.id.rawValue, owner: a, host: host.id, revision: &otherRevision)
        let otherCapture = capture(otherObject, parent: nil, "other-area-sentinel")
        _ = try await apiA.publishArtifact(area: other.document.id.rawValue, epoch: 1, capture: otherCapture)
        try await sameMiss("another area's digest through this area", "areas/\(area)/artifacts/\(object.rawValue)/revisions/\(r1)/blobs/\(otherCapture.manifest.entries[0].blob!)", b.token)
        try await sameMiss("another area's artifact by id", "areas/\(other.document.id.rawValue)/artifacts/\(otherObject.rawValue)/revisions/\(otherCapture.manifest.id.rawValue)/blobs/\(otherCapture.manifest.entries[0].blob!)", b.token)

        // Bytes stay off the event stream and are sealed at rest.
        let page = try await store.updates(token: b.token, area: area, request: .init(after: 0, waitMilliseconds: 0))
        let pageBytes = try JSONEncoder().encode(page)
        try expect(!String(decoding: pageBytes, as: UTF8.self).contains("shared-artifact-sentinel"), "area update stream carries no artifact bytes")
        let disk = try Data(contentsOf: URL(fileURLWithPath: path))
        try expect(disk.range(of: Data("shared-artifact-sentinel".utf8)) == nil && disk.range(of: Data("src/main.swift".utf8)) == nil,
                   "artifact bytes and manifests are sealed at rest")

        // Quota and staging retention: abandoned uploads stop counting once expired.
        let quotaObject = try await admitArtifact(apiA, area: area, owner: a, host: host.id, revision: &revision)
        var stagedCount = 0, quotaStatus = 0, quotaBody = Data()
        for index in 0..<70 {
            var chunk = Data(repeating: UInt8(index), count: A.Limits.blobBytes); chunk[0] = 0xff
            let response = try await raw("PUT", "areas/\(area)/artifacts/\(quotaObject.rawValue)/blobs/\(A.digest(chunk))", a.token, chunk)
            if response.0 == 201 { stagedCount += 1; continue }
            quotaStatus = response.0; quotaBody = response.1; break
        }
        try expect(stagedCount >= 62 && stagedCount < 64 && quotaStatus == 413 && String(decoding: quotaBody, as: UTF8.self).contains("artifactQuotaExceeded"),
                   "the 64 MiB area quota refuses the next blob after \(stagedCount) MiB")
        clock.advance(3601)
        var fresh = Data(repeating: 0xab, count: A.Limits.blobBytes); fresh[0] = 0x01
        let afterExpiry = try await raw("PUT", "areas/\(area)/artifacts/\(quotaObject.rawValue)/blobs/\(A.digest(fresh))", a.token, fresh)
        try expect(afterExpiry.0 == 201, "unpublished staged blobs expire after the staging lifetime and free the quota")
        let stillPinned = try await apiV.readArtifact(area: area, object: object.rawValue, revision: r1)
        try expect(stillPinned.bytes == read.bytes, "published revision bytes survive staging collection")

        // Revocation: removal and unpublication close the routes.
        let before = try await raw("GET", blobPath, b.token)
        try expect(before.0 == 200, "B reads the blob before removal")
        let epoch = try await apiA.state(area: area).scope.epoch
        try await apiA.removeMember(area: area, person: b.identity.person.rawValue, epoch: epoch)
        try await sameMiss("removed member re-fetching a cached blob route", blobPath, b.token)
        try await sameMiss("removed member reading pinned revision", "areas/\(area)/artifacts/\(object.rawValue)/revisions/\(r1)", b.token)
        let current = try await apiA.state(area: area)
        let unpublish = SharedArea.Command(area: .init(area), expectedRevision: current.document.revision, edits: [.remove(object)])
        _ = try await apiA.apply(area: area, mutation: .init(epoch: current.scope.epoch, command: unpublish))
        try await sameMiss("unpublished artifact, even for its owner", blobPath, a.token)
        try await sameMiss("unpublished artifact for a remaining viewer", blobPath, v.token)
        let database = try DatabaseQueue(path: path)
        let leftovers = try await database.read { db in
            try ["collaboration_artifact_blobs", "collaboration_artifact_revisions", "collaboration_artifact_reviews"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE area=? AND object=?", arguments: [area.uuidString, object.rawValue.uuidString]) ?? -1
            }
        }
        try expect(leftovers == [0, 0, 0], "unpublishing an artifact deletes its blobs, revisions and reviews")
        let heads = try await store.updates(token: v.token, area: area, request: .init(after: try await apiV.state(area: area).document.revision, waitMilliseconds: 0))
        try expect(heads.artifactHeads?.contains(where: { $0.object == object }) == false, "an unpublished artifact has no head")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
    print("Collaboration artifact checks passed: real localhost routes, pinned revisions, nested 404s, no event-stream bytes.")
}
