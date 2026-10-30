import Foundation
import Crypto
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum CollaborationArtifactError: Error, Equatable {
    case hashMismatch, tooLarge, quotaExceeded, missingBlob, conflict, changedIntent, invalidManifest
}

/// Artifact revisions and their bytes live beside the area document, never in
/// its operation log. Every read reauthenticates, reloads current membership
/// and requires the object to be admitted as an artifact right now; a blob is
/// reachable only through a revision of that object that lists it.
extension CollaborationStore {
    public typealias Artifact = Collaboration.Artifact

    static func registerArtifactMigration(_ migrator: inout DatabaseMigrator) {
        // Named, not numbered: parallel lanes add migrations at the same time.
        migrator.registerMigration("collaboration-artifacts-v1") { db in
            try db.execute(sql: """
                CREATE TABLE collaboration_artifact_blobs(area TEXT NOT NULL REFERENCES areas(id), object TEXT NOT NULL,
                  digest TEXT NOT NULL, length INTEGER NOT NULL, sealed BLOB NOT NULL, uploader TEXT NOT NULL REFERENCES devices(id),
                  PRIMARY KEY(area,object,digest));
                CREATE TABLE collaboration_artifact_revisions(area TEXT NOT NULL REFERENCES areas(id), object TEXT NOT NULL,
                  id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, record BLOB NOT NULL,
                  PRIMARY KEY(area,id), UNIQUE(area,object,sequence));
                CREATE TABLE collaboration_artifact_reviews(area TEXT NOT NULL REFERENCES areas(id), object TEXT NOT NULL,
                  id TEXT NOT NULL, revision TEXT NOT NULL, created DOUBLE NOT NULL, review BLOB NOT NULL,
                  PRIMARY KEY(area,id));
                """)
        }
    }

    public func uploadArtifactBlob(token: String, area: UUID, object: UUID, digest: String, bytes: Data) throws -> Artifact.BlobReceipt {
        guard Artifact.isDigest(digest) else { throw CollaborationStoreError.invalidRequest }
        guard bytes.count <= Artifact.Limits.blobBytes else { throw CollaborationArtifactError.tooLarge }
        guard Artifact.digest(bytes) == digest else { throw CollaborationArtifactError.hashMismatch }
        return try database.write { db in
            let caller = try authenticate(db, token)
            _ = try artifactOwnerAccess(db, caller, area, object)
            if try Int.fetchOne(db, sql: "SELECT length FROM collaboration_artifact_blobs WHERE area=? AND object=? AND digest=?",
                                arguments: [area.uuidString, object.uuidString, digest]) != nil {
                return .init(digest: digest, length: bytes.count)
            }
            let used = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length),0) FROM collaboration_artifact_blobs WHERE area=?", arguments: [area.uuidString]) ?? 0
            guard used <= Artifact.Limits.areaBytes - bytes.count else { throw CollaborationArtifactError.quotaExceeded }
            let sealed = try AES.GCM.seal(bytes, using: key, authenticating: Self.blobAAD(area, object, digest)).combined!
            try db.execute(sql: "INSERT INTO collaboration_artifact_blobs(area,object,digest,length,sealed,uploader) VALUES (?,?,?,?,?,?)",
                arguments: [area.uuidString, object.uuidString, digest, bytes.count, sealed, caller.device.uuidString])
            return .init(digest: digest, length: bytes.count)
        }
    }

    public func publishArtifactRevision(token: String, area: UUID, object: UUID, request: Artifact.PublishRequest) throws -> Artifact.PublishReceipt {
        let manifest = request.manifest
        do { try Artifact.validate(manifest) }
        catch Artifact.ValidationFailure.tooLarge { throw CollaborationArtifactError.tooLarge }
        catch { throw CollaborationArtifactError.invalidManifest }
        guard manifest.object.rawValue == object else { throw CollaborationArtifactError.invalidManifest }
        let digest = manifest.contentDigest
        return try database.write { db in
            let caller = try authenticate(db, token)
            let (scope, source) = try artifactOwnerAccess(db, caller, area, object)
            guard scope.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            if let row = try Row.fetchOne(db, sql: "SELECT object,sequence,digest FROM collaboration_artifact_revisions WHERE area=? AND id=?",
                                         arguments: [area.uuidString, manifest.id.rawValue.uuidString]) {
                guard row["object"] as String == object.uuidString, row["digest"] as String == digest else { throw CollaborationArtifactError.changedIntent }
                return .init(revision: manifest.id, sequence: UInt64(row["sequence"] as Int64), duplicate: true)
            }
            let latest = try Row.fetchOne(db, sql: "SELECT id,sequence FROM collaboration_artifact_revisions WHERE area=? AND object=? ORDER BY sequence DESC LIMIT 1",
                                          arguments: [area.uuidString, object.uuidString])
            guard latest.map({ $0["id"] as String }) == manifest.parent?.rawValue.uuidString else { throw CollaborationArtifactError.conflict }
            for entry in manifest.entries where entry.coverage == .included {
                guard try Int.fetchOne(db, sql: "SELECT length FROM collaboration_artifact_blobs WHERE area=? AND object=? AND digest=?",
                                       arguments: [area.uuidString, object.uuidString, entry.blob!]) == entry.length else { throw CollaborationArtifactError.missingBlob }
            }
            let sequence = (latest.map { $0["sequence"] as Int64 } ?? 0) + 1
            let record = Artifact.Record(manifest: manifest, sequence: UInt64(sequence), publisher: caller.person, host: source.host,
                                         publishedAt: clock(), contentDigest: digest)
            try db.execute(sql: "INSERT INTO collaboration_artifact_revisions(area,object,id,sequence,digest,record) VALUES (?,?,?,?,?,?)",
                arguments: [area.uuidString, object.uuidString, manifest.id.rawValue.uuidString, sequence, digest, try seal(record)])
            return .init(revision: manifest.id, sequence: UInt64(sequence), duplicate: false)
        }
    }

    public func artifactState(token: String, area: UUID, object: UUID) throws -> Artifact.State {
        try database.read { db in
            let caller = try authenticate(db, token)
            _ = try artifactReadAccess(db, caller, area, object)
            let records = try Row.fetchAll(db, sql: "SELECT record FROM collaboration_artifact_revisions WHERE area=? AND object=? ORDER BY sequence",
                                           arguments: [area.uuidString, object.uuidString]).map { try unseal(Artifact.Record.self, $0["record"]) }
            let latest = records.last
            func applicability(_ id: SharedArea.ID<Artifact.RevisionTag>) -> Artifact.Applicability {
                guard let record = records.first(where: { $0.manifest.id == id }), let latest else { return .current }
                if record.manifest.id != latest.manifest.id { return .superseded(by: latest.manifest.id) }
                if let drift = record.drift { return .sourceChanged(drift) }
                return .current
            }
            let reviews = try Row.fetchAll(db, sql: "SELECT review FROM collaboration_artifact_reviews WHERE area=? AND object=? ORDER BY created,id",
                                           arguments: [area.uuidString, object.uuidString]).map { try unseal(Artifact.Review.self, $0["review"]) }
            return .init(object: .init(object), latest: latest,
                revisions: records.map { .init(id: $0.manifest.id, sequence: $0.sequence, contentDigest: $0.contentDigest, applicability: applicability($0.manifest.id)) },
                reviews: reviews.map { .init(review: $0, applicability: applicability($0.revision)) })
        }
    }

    public func artifactRevision(token: String, area: UUID, object: UUID, revision: UUID) throws -> Artifact.Record {
        try database.read { db in
            let caller = try authenticate(db, token)
            _ = try artifactReadAccess(db, caller, area, object)
            return try record(db, area, object, revision)
        }
    }

    /// The nested lookup: (current member, admitted artifact, its revision,
    /// a digest that revision includes). Anything else is the same 404.
    public func artifactBlob(token: String, area: UUID, object: UUID, revision: UUID, digest: String) throws -> Data {
        guard Artifact.isDigest(digest) else { throw CollaborationStoreError.unavailable }
        return try database.read { db in
            let caller = try authenticate(db, token)
            _ = try artifactReadAccess(db, caller, area, object)
            let record = try record(db, area, object, revision)
            guard let entry = record.manifest.entries.first(where: { $0.coverage == .included && $0.blob == digest }),
                  let sealed = try Data.fetchOne(db, sql: "SELECT sealed FROM collaboration_artifact_blobs WHERE area=? AND object=? AND digest=?",
                                                 arguments: [area.uuidString, object.uuidString, digest]) else { throw CollaborationStoreError.unavailable }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Self.blobAAD(area, object, digest))
            try Artifact.verify(bytes, for: entry)
            return bytes
        }
    }

    public func reviewArtifact(token: String, area: UUID, object: UUID, request: Artifact.ReviewRequest) throws -> Artifact.Review {
        guard request.note.utf8.count <= Artifact.Limits.reviewNoteBytes else { throw CollaborationStoreError.invalidRequest }
        return try database.write { db in
            let caller = try authenticate(db, token)
            let scope = try artifactReadAccess(db, caller, area, object)
            guard scope.allows(.discuss) else { throw CollaborationStoreError.forbidden }
            guard scope.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            let pinned = try record(db, area, object, request.revision.rawValue)
            if let data = try Data.fetchOne(db, sql: "SELECT review FROM collaboration_artifact_reviews WHERE area=? AND id=?",
                                            arguments: [area.uuidString, request.id.rawValue.uuidString]) {
                let prior = try unseal(Artifact.Review.self, data)
                guard prior.object.rawValue == object, prior.revision == request.revision, prior.author == caller.person,
                      prior.verdict == request.verdict, prior.note == request.note else { throw CollaborationArtifactError.changedIntent }
                return prior
            }
            let review = Artifact.Review(id: request.id, object: .init(object), revision: request.revision, contentDigest: pinned.contentDigest,
                                         author: caller.person, verdict: request.verdict, note: request.note, createdAt: clock())
            try db.execute(sql: "INSERT INTO collaboration_artifact_reviews(area,object,id,revision,created,review) VALUES (?,?,?,?,?,?)",
                arguments: [area.uuidString, object.uuidString, request.id.rawValue.uuidString, request.revision.rawValue.uuidString,
                            review.createdAt.timeIntervalSince1970, try seal(review)])
            return review
        }
    }

    /// Set-once: the first observation that the source moved stands; it can
    /// never be cleared back to applicable. A new revision is the remedy.
    public func reportArtifactDrift(token: String, area: UUID, object: UUID, revision: UUID, report: Artifact.DriftReport) throws -> Artifact.Record {
        guard report.changedPaths >= 0, report.changedPaths <= Artifact.Limits.entries, report.changedPaths > 0 || report.baseMoved else {
            throw CollaborationStoreError.invalidRequest
        }
        return try database.write { db in
            let caller = try authenticate(db, token)
            let (scope, _) = try artifactOwnerAccess(db, caller, area, object)
            guard scope.epoch == report.epoch else { throw CollaborationStoreError.staleEpoch }
            var current = try record(db, area, object, revision)
            guard current.drift == nil else { return current }
            current.drift = .init(changedPaths: report.changedPaths, baseMoved: report.baseMoved, observedAt: clock())
            try db.execute(sql: "UPDATE collaboration_artifact_revisions SET record=? WHERE area=? AND id=?",
                arguments: [try seal(current), area.uuidString, revision.uuidString])
            return current
        }
    }

    private func record(_ db: Database, _ area: UUID, _ object: UUID, _ revision: UUID) throws -> Artifact.Record {
        guard let data = try Data.fetchOne(db, sql: "SELECT record FROM collaboration_artifact_revisions WHERE area=? AND object=? AND id=?",
                                           arguments: [area.uuidString, object.uuidString, revision.uuidString]) else { throw CollaborationStoreError.unavailable }
        return try unseal(Artifact.Record.self, data)
    }

    /// Current membership plus a currently admitted `.artifact` item. An
    /// unpublished object is indistinguishable from one that never existed.
    private func artifactReadAccess(_ db: Database, _ caller: Collaboration.Identity, _ area: UUID, _ object: UUID) throws -> Collaboration.Scope {
        try artifactItem(db, caller, area, object).0
    }
    private func artifactItem(_ db: Database, _ caller: Collaboration.Identity, _ area: UUID, _ object: UUID) throws -> (Collaboration.Scope, SharedArea.Item) {
        let scope = try scope(db, caller, area)
        let bytes = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
        let document = try unseal(SharedArea.Document.self, bytes)
        guard let item = document.items.first(where: { $0.id.rawValue == object && $0.kind == .artifact }) else { throw CollaborationStoreError.unavailable }
        return (scope, item)
    }
    /// Only the source owner, from the device that registered the source host,
    /// may add bytes or revisions. Area ownership is not source ownership.
    private func artifactOwnerAccess(_ db: Database, _ caller: Collaboration.Identity, _ area: UUID, _ object: UUID) throws -> (Collaboration.Scope, SharedArea.Source) {
        let (scope, item) = try artifactItem(db, caller, area, object)
        guard scope.allows(.publish), let source = item.source, source.owner == caller.person,
              try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [source.host.rawValue.uuidString]) == caller.device.uuidString
        else { throw CollaborationStoreError.forbidden }
        return (scope, source)
    }
    static func blobAAD(_ area: UUID, _ object: UUID, _ digest: String) -> Data {
        Data("array.collaboration.artifact-blob.v1|\(area.uuidString)|\(object.uuidString)|\(digest)".utf8)
    }
}
