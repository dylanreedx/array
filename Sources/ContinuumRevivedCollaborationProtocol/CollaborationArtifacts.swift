import Foundation
import Crypto

/// Immutable file/diff artifacts published into a shared area (COL-16/COL-07).
/// A revision is exact captured bytes plus a declaration of what it covers. It
/// is read on the recipient into memory only: nothing here names a recipient
/// checkout, and no API in this lane writes to one.
extension Collaboration {
    public enum Artifact {
        public enum RevisionTag: Sendable {}
        public enum ReviewTag: Sendable {}

        /// Publication budgets. Blobs travel on their own bounded routes,
        /// never in the area operation/event stream.
        public enum Limits {
            public static let blobBytes = 1_048_576
            public static let revisionBytes = 8 * 1_048_576
            public static let areaBytes = 64 * 1_048_576
            public static let entries = 256
            public static let pathBytes = 1_024
            public static let refBytes = 200
            public static let reviewNoteBytes = 4_096
        }

        public enum Kind: String, Codable, Sendable { case files, diff }
        /// What the revision is relative to. `branch` is committed changes in
        /// `mergeBase...head` only; it never implies working-tree changes.
        public enum Range: String, Codable, Sendable { case files, workingTree, staged, branch }
        public enum Change: String, Codable, Sendable { case added, modified, deleted, renamed, untracked, unchanged }
        /// Per selected path. Only `included` carries bytes.
        public enum Coverage: String, Codable, Sendable { case included, binary, oversized, symlink, submodule, unavailable }

        public struct Base: Codable, Equatable, Sendable {
            /// Commit object id of HEAD at capture; nil for an unborn branch.
            public let head: String?
            /// Merge base for `.branch`; nil otherwise.
            public let mergeBase: String?
            /// The base ref name the owner chose for `.branch` (it is shown).
            public let baseRef: String?
            public init(head: String?, mergeBase: String? = nil, baseRef: String? = nil) {
                self.head = head; self.mergeBase = mergeBase; self.baseRef = baseRef
            }
        }

        /// Honest declaration of the capture. Names of unselected paths are
        /// never published, only their counts.
        public struct Declaration: Codable, Equatable, Sendable {
            public let range: Range
            public let includesCommitted: Bool
            public let includesStaged: Bool
            public let includesUnstaged: Bool
            /// True only when at least one untracked path was explicitly selected.
            public let includesUntracked: Bool
            public let omittedChangedPaths: Int
            public let omittedUntrackedPaths: Int
            public init(range: Range, includesCommitted: Bool, includesStaged: Bool, includesUnstaged: Bool,
                        includesUntracked: Bool, omittedChangedPaths: Int, omittedUntrackedPaths: Int) {
                self.range = range; self.includesCommitted = includesCommitted; self.includesStaged = includesStaged
                self.includesUnstaged = includesUnstaged; self.includesUntracked = includesUntracked
                self.omittedChangedPaths = omittedChangedPaths; self.omittedUntrackedPaths = omittedUntrackedPaths
            }
        }

        public struct Entry: Codable, Equatable, Sendable {
            /// Repository-relative; never absolute, never `..`.
            public let path: String
            public let previousPath: String?
            public let change: Change
            public let coverage: Coverage
            /// SHA-256 (lowercase hex) of the published payload; `included` only.
            public let blob: String?
            public let length: Int?
            /// `text/plain` for file bytes, `text/x-diff` for a per-path patch.
            public let mediaType: String?
            /// SHA-256 of the owner's working file at capture ("" when absent).
            /// Lets the owner's host decide applicability later; it is not a
            /// copy of content and the recipient never needs it.
            public let sourceDigest: String
            public init(path: String, previousPath: String? = nil, change: Change, coverage: Coverage,
                        blob: String? = nil, length: Int? = nil, mediaType: String? = nil, sourceDigest: String) {
                self.path = path; self.previousPath = previousPath; self.change = change; self.coverage = coverage
                self.blob = blob; self.length = length; self.mediaType = mediaType; self.sourceDigest = sourceDigest
            }
        }

        /// What the owner's host publishes. `id` is host-minted so an identical
        /// retry is a duplicate; `parent` is the live revision it supersedes.
        public struct Manifest: Codable, Equatable, Sendable {
            public let schema: Int
            public let id: SharedArea.ID<RevisionTag>
            public let object: SharedArea.ID<SharedArea.Object>
            public let parent: SharedArea.ID<RevisionTag>?
            public let kind: Kind
            public let base: Base
            public let declaration: Declaration
            public let entries: [Entry]
            /// Unix milliseconds; an integer so the digest is platform-stable.
            public let capturedAt: Int64
            public init(schema: Int = 1, id: SharedArea.ID<RevisionTag> = .init(), object: SharedArea.ID<SharedArea.Object>,
                        parent: SharedArea.ID<RevisionTag>?, kind: Kind, base: Base, declaration: Declaration,
                        entries: [Entry], capturedAt: Int64) {
                self.schema = schema; self.id = id; self.object = object; self.parent = parent; self.kind = kind
                self.base = base; self.declaration = declaration; self.entries = entries; self.capturedAt = capturedAt
            }

            /// Hand-built, length-prefixed canonical bytes. JSON encoders
            /// differ across platforms (slash/unicode escaping), so the content
            /// digest must not depend on one.
            public var contentDigest: String {
                var bytes = Data("array.collaboration.artifact.v1".utf8)
                func put(_ s: String?) {
                    guard let s else { bytes.append(0); return }
                    bytes.append(1)
                    let utf8 = Array(s.utf8)
                    withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { bytes.append(contentsOf: $0) }
                    bytes.append(contentsOf: utf8)
                }
                func put(_ n: Int64) { withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) } }
                put(Int64(schema)); put(id.rawValue.uuidString); put(object.rawValue.uuidString)
                put(parent?.rawValue.uuidString); put(kind.rawValue)
                put(base.head); put(base.mergeBase); put(base.baseRef)
                let d = declaration
                put(d.range.rawValue)
                for flag in [d.includesCommitted, d.includesStaged, d.includesUnstaged, d.includesUntracked] { put(flag ? 1 : 0) }
                put(Int64(d.omittedChangedPaths)); put(Int64(d.omittedUntrackedPaths))
                put(Int64(entries.count))
                for e in entries {
                    put(e.path); put(e.previousPath); put(e.change.rawValue); put(e.coverage.rawValue)
                    put(e.blob); put(e.length.map(Int64.init) ?? -1); put(e.mediaType); put(e.sourceDigest)
                }
                put(capturedAt)
                return Artifact.digest(bytes)
            }
            public var includedBytes: Int { entries.reduce(0) { $0 + ($1.coverage == .included ? ($1.length ?? 0) : 0) } }
        }

        /// A capture ready to publish: the manifest and exactly the bytes its
        /// `included` entries name, keyed by digest.
        public struct Capture: Sendable {
            public let manifest: Manifest
            public let blobs: [String: Data]
            public init(manifest: Manifest, blobs: [String: Data]) { self.manifest = manifest; self.blobs = blobs }
        }

        public struct PublishRequest: Codable, Sendable {
            public let epoch: Int64
            public let manifest: Manifest
            public init(epoch: Int64, manifest: Manifest) { self.epoch = epoch; self.manifest = manifest }
        }

        /// Owner's host observed that the source no longer matches a revision.
        public struct DriftReport: Codable, Equatable, Sendable {
            public let epoch: Int64
            public let changedPaths: Int
            public let baseMoved: Bool
            public init(epoch: Int64, changedPaths: Int, baseMoved: Bool) {
                self.epoch = epoch; self.changedPaths = changedPaths; self.baseMoved = baseMoved
            }
        }
        public struct Drift: Codable, Equatable, Sendable {
            public let changedPaths: Int
            public let baseMoved: Bool
            public let observedAt: Date
            public init(changedPaths: Int, baseMoved: Bool, observedAt: Date) {
                self.changedPaths = changedPaths; self.baseMoved = baseMoved; self.observedAt = observedAt
            }
        }

        /// Service-issued, immutable apart from `drift`, which can only be set.
        public struct Record: Codable, Equatable, Sendable {
            public let manifest: Manifest
            public let sequence: UInt64
            public let publisher: SharedArea.ID<SharedArea.Person>
            public let host: SharedArea.ID<SharedArea.Host>
            public let publishedAt: Date
            public let contentDigest: String
            public var drift: Drift?
            public init(manifest: Manifest, sequence: UInt64, publisher: SharedArea.ID<SharedArea.Person>,
                        host: SharedArea.ID<SharedArea.Host>, publishedAt: Date, contentDigest: String, drift: Drift? = nil) {
                self.manifest = manifest; self.sequence = sequence; self.publisher = publisher; self.host = host
                self.publishedAt = publishedAt; self.contentDigest = contentDigest; self.drift = drift
            }
        }
        public struct PublishReceipt: Codable, Equatable, Sendable {
            public let revision: SharedArea.ID<RevisionTag>
            public let sequence: UInt64
            public let duplicate: Bool
            public init(revision: SharedArea.ID<RevisionTag>, sequence: UInt64, duplicate: Bool) {
                self.revision = revision; self.sequence = sequence; self.duplicate = duplicate
            }
        }
        public struct BlobReceipt: Codable, Equatable, Sendable {
            public let digest: String
            public let length: Int
            public init(digest: String, length: Int) { self.digest = digest; self.length = length }
        }

        /// Whether a pinned revision still describes the live artifact.
        /// Approval never moves: `current` is the only state that means the
        /// reviewed bytes are what the owner currently publishes as latest.
        public enum Applicability: Codable, Equatable, Sendable {
            case current
            case superseded(by: SharedArea.ID<RevisionTag>)
            case sourceChanged(Drift)
        }
        public enum Verdict: String, Codable, Sendable { case approve, requestChanges, comment }
        public struct ReviewRequest: Codable, Equatable, Sendable {
            public let id: SharedArea.ID<ReviewTag>
            public let epoch: Int64
            public let revision: SharedArea.ID<RevisionTag>
            public let verdict: Verdict
            public let note: String
            public init(id: SharedArea.ID<ReviewTag> = .init(), epoch: Int64, revision: SharedArea.ID<RevisionTag>, verdict: Verdict, note: String) {
                self.id = id; self.epoch = epoch; self.revision = revision; self.verdict = verdict; self.note = note
            }
        }
        /// A review is pinned to (object, revision, contentDigest) forever.
        public struct Review: Codable, Equatable, Sendable {
            public let id: SharedArea.ID<ReviewTag>
            public let object: SharedArea.ID<SharedArea.Object>
            public let revision: SharedArea.ID<RevisionTag>
            public let contentDigest: String
            public let author: SharedArea.ID<SharedArea.Person>
            public let verdict: Verdict
            public let note: String
            public let createdAt: Date
            public init(id: SharedArea.ID<ReviewTag>, object: SharedArea.ID<SharedArea.Object>, revision: SharedArea.ID<RevisionTag>,
                        contentDigest: String, author: SharedArea.ID<SharedArea.Person>, verdict: Verdict, note: String, createdAt: Date) {
                self.id = id; self.object = object; self.revision = revision; self.contentDigest = contentDigest
                self.author = author; self.verdict = verdict; self.note = note; self.createdAt = createdAt
            }
        }
        public struct ReviewState: Codable, Equatable, Sendable {
            public let review: Review
            public let applicability: Applicability
            public init(review: Review, applicability: Applicability) { self.review = review; self.applicability = applicability }
        }
        public struct RevisionSummary: Codable, Equatable, Sendable {
            public let id: SharedArea.ID<RevisionTag>
            public let sequence: UInt64
            public let contentDigest: String
            public let applicability: Applicability
            public init(id: SharedArea.ID<RevisionTag>, sequence: UInt64, contentDigest: String, applicability: Applicability) {
                self.id = id; self.sequence = sequence; self.contentDigest = contentDigest; self.applicability = applicability
            }
        }
        /// Live view of one artifact object: the latest revision is separate
        /// from every pinned revision a review names.
        public struct State: Codable, Equatable, Sendable {
            public let object: SharedArea.ID<SharedArea.Object>
            public let latest: Record?
            public let revisions: [RevisionSummary]
            public let reviews: [ReviewState]
            public init(object: SharedArea.ID<SharedArea.Object>, latest: Record?, revisions: [RevisionSummary], reviews: [ReviewState]) {
                self.object = object; self.latest = latest; self.revisions = revisions; self.reviews = reviews
            }
        }

        /// Live pointer for one artifact, carried on every updates page.
        public struct Head: Codable, Equatable, Sendable {
            public let object: SharedArea.ID<SharedArea.Object>
            public let revision: SharedArea.ID<RevisionTag>
            public let sequence: UInt64
            public let sourceChanged: Bool
            public let reviews: Int
            public init(object: SharedArea.ID<SharedArea.Object>, revision: SharedArea.ID<RevisionTag>, sequence: UInt64, sourceChanged: Bool, reviews: Int) {
                self.object = object; self.revision = revision; self.sequence = sequence; self.sourceChanged = sourceChanged; self.reviews = reviews
            }
        }

        public enum ValidationFailure: Error, Equatable, Sendable {
            case invalidManifest(String), hashMismatch, tooLarge
        }

        public static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        public static func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        static func isObjectID(_ value: String) -> Bool {
            (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        /// Repository-relative path rule shared by producer, service and reader.
        public static func isPortablePath(_ path: String) -> Bool {
            guard !path.isEmpty, path.utf8.count <= Limits.pathBytes, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
            return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
        }

        /// Structural validation the service applies before storing anything
        /// and the reader applies again before trusting a fetched record.
        public static func validate(_ m: Manifest) throws {
            func fail(_ reason: String) -> ValidationFailure { .invalidManifest(reason) }
            guard m.schema == 1 else { throw fail("schema") }
            guard m.entries.count <= Limits.entries else { throw fail("entries") }
            guard Set(m.entries.map(\.path)).count == m.entries.count else { throw fail("duplicatePath") }
            for ref in [m.base.head, m.base.mergeBase].compactMap({ $0 }) where !isObjectID(ref) { throw fail("objectID") }
            if let ref = m.base.baseRef, ref.isEmpty || ref.utf8.count > Limits.refBytes || ref.unicodeScalars.contains(where: { $0.value < 0x20 }) { throw fail("baseRef") }
            switch (m.kind, m.declaration.range) {
            case (.files, .files), (.diff, .workingTree), (.diff, .staged), (.diff, .branch): break
            default: throw fail("range")
            }
            if m.declaration.range == .branch { guard m.base.mergeBase != nil, m.base.head != nil else { throw fail("branchBase") } }
            guard m.declaration.omittedChangedPaths >= 0, m.declaration.omittedUntrackedPaths >= 0 else { throw fail("counts") }
            for e in m.entries {
                guard isPortablePath(e.path), e.previousPath.map(isPortablePath) ?? true else { throw fail("path") }
                guard e.sourceDigest.isEmpty || isDigest(e.sourceDigest) else { throw fail("sourceDigest") }
                if e.coverage == .included {
                    guard let blob = e.blob, isDigest(blob), let length = e.length, length >= 0, length <= Limits.blobBytes,
                          e.mediaType == "text/plain" || e.mediaType == "text/x-diff" else { throw fail("included") }
                } else {
                    guard e.blob == nil, e.length == nil else { throw fail("excludedCarriesBytes") }
                }
            }
            guard m.includedBytes <= Limits.revisionBytes else { throw ValidationFailure.tooLarge }
        }

        /// Recipient-side check of a fetched blob against the pinned manifest.
        public static func verify(_ data: Data, for entry: Entry) throws {
            guard entry.coverage == .included, let blob = entry.blob, data.count == entry.length, digest(data) == blob
            else { throw ValidationFailure.hashMismatch }
        }
        public static func verify(_ record: Record) throws {
            try validate(record.manifest)
            guard record.manifest.contentDigest == record.contentDigest else { throw ValidationFailure.hashMismatch }
        }
    }
}
