import ContinuumRevivedAgentContent
import CryptoKit
import Darwin
import Foundation

public enum AgentComposerAttachmentStoreError: Error, Equatable {
    case nonFileURL(String)
    case unreadableSource(String)
    case unsafeRelativePath(String)
    case ownershipMismatch(id: AgentImageAttachmentID, expected: AgentID, actual: AgentID?)
    case manifestIdentityMismatch(expected: AgentImageAttachmentID, actual: AgentImageAttachmentID)
    case draftMetadataMismatch(id: AgentImageAttachmentID)
    case missingAttachment(AgentImageAttachmentID)
    case unreadableManagedFile(id: AgentImageAttachmentID, path: String)
    case cleanupDeletionFailed([String])
    case importRollbackFailed(manifestError: String, objectPath: String, rollbackError: String)
    case transferRollbackFailed(transferError: String, rollbackFailures: [String], journalPath: String)
    case transferRecoveryFailed(journalPath: String, failures: [String])
    case imageInputNotValidated(String)
    case atomicWriteFailed(String)
}

/// Platform-neutral proof supplied by the AppKit/import boundary after it has
/// decoded or otherwise validated that the bytes are an image. Core intentionally
/// does not import AppKit/ImageIO; it only requires callers to cross this typed
/// seam before managed storage accepts image bytes.
public struct AgentComposerImageValidation: Equatable, Sendable {
    public var contentType: String
    public var pixelWidth: UInt?
    public var pixelHeight: UInt?
    public var byteCount: UInt64?

    public init(
        validatedContentType contentType: String,
        pixelWidth: UInt? = nil,
        pixelHeight: UInt? = nil,
        byteCount: UInt64? = nil
    ) throws {
        let normalized = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("image/"), normalized.count > "image/".count else {
            throw AgentComposerAttachmentStoreError.imageInputNotValidated("caller validation must identify an image/* content type")
        }
        if let pixelWidth, pixelWidth == 0 {
            throw AgentComposerAttachmentStoreError.imageInputNotValidated("validated pixel width must be positive when present")
        }
        if let pixelHeight, pixelHeight == 0 {
            throw AgentComposerAttachmentStoreError.imageInputNotValidated("validated pixel height must be positive when present")
        }
        self.contentType = normalized
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

public struct AgentComposerAttachmentStoreLayout: Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var attachmentsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("agent-composer-attachments", isDirectory: true)
    }

    public var objectsDirectory: URL {
        attachmentsDirectory.appendingPathComponent("objects", isDirectory: true)
    }

    public var manifestsDirectory: URL {
        attachmentsDirectory.appendingPathComponent("manifests", isDirectory: true)
    }

    public var ownershipTransactionsDirectory: URL {
        attachmentsDirectory.appendingPathComponent("ownership-transactions", isDirectory: true)
    }

    public func objectRelativePath(for id: AgentImageAttachmentID) -> String {
        "objects/\(Self.storageKey(for: id)).bin"
    }

    public func manifestFile(for id: AgentImageAttachmentID) -> URL {
        manifestsDirectory.appendingPathComponent("\(Self.storageKey(for: id)).json", isDirectory: false)
    }

    fileprivate static func storageKey(for id: AgentImageAttachmentID) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct AgentComposerAttachmentOwnership: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case draft
        case sent
    }

    public var state: State
    public var agentID: AgentID
    public var updatedAt: Date
    public var sentAt: Date?

    public init(state: State, agentID: AgentID, updatedAt: Date, sentAt: Date? = nil) {
        self.state = state
        self.agentID = agentID
        self.updatedAt = updatedAt
        self.sentAt = sentAt
    }

    public static func draft(agentID: AgentID, at date: Date) -> Self {
        Self(state: .draft, agentID: agentID, updatedAt: date, sentAt: nil)
    }

    public static func sent(agentID: AgentID, at date: Date) -> Self {
        Self(state: .sent, agentID: agentID, updatedAt: date, sentAt: date)
    }
}

public struct AgentComposerAttachmentManifest: Codable, Equatable, Sendable {
    public var id: AgentImageAttachmentID
    public var metadata: AgentImageAttachmentMetadata
    /// Relative to `AgentComposerAttachmentStoreLayout.attachmentsDirectory`.
    /// This is a store-internal path, not a source/original path.
    public var relativePath: String
    public var ownership: AgentComposerAttachmentOwnership
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: AgentImageAttachmentID,
        metadata: AgentImageAttachmentMetadata,
        relativePath: String,
        ownership: AgentComposerAttachmentOwnership,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.metadata = metadata
        self.relativePath = relativePath
        self.ownership = ownership
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var draftAttachment: AgentComposerDraftImageAttachment {
        AgentComposerDraftImageAttachment(metadata: metadata)
    }
}

public struct AgentComposerStoredAttachment: Equatable, Sendable {
    public var manifest: AgentComposerAttachmentManifest
    public var fileURL: URL

    public init(manifest: AgentComposerAttachmentManifest, fileURL: URL) {
        precondition(fileURL.isFileURL, "AgentComposerStoredAttachment requires a local file URL")
        self.manifest = manifest
        self.fileURL = fileURL
    }

    public var draftAttachment: AgentComposerDraftImageAttachment { manifest.draftAttachment }

    public var promptAttachment: AgentPromptImageAttachment {
        AgentPromptImageAttachment(metadata: manifest.metadata, fileURL: fileURL)
    }
}

private struct AgentComposerOwnershipTransferJournal: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case committed
    }

    var id: UUID
    var state: State
    var originals: [AgentComposerAttachmentManifest]
    var sent: [AgentComposerAttachmentManifest]
    var updatedAt: Date
}

/// Array-managed host-local storage for composer image originals. It imports
/// caller-validated image bytes/files into Application Support, persists only
/// opaque ids plus path-free metadata in drafts/transcripts, and resolves ids
/// back to local file capabilities for provider adapters on this host.
public actor AgentComposerAttachmentStore {
    public let layout: AgentComposerAttachmentStoreLayout

    private let reader = AtomicWriter(backupsDirectory: nil, retainedBackups: 0)
    private let clock: any Clock
    private let warn: @Sendable (String) -> Void
    private let writeManifest: @Sendable (AgentComposerAttachmentManifest, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void

    public init(
        applicationSupportDirectory: URL? = nil,
        clock: any Clock = SystemClock(),
        warn: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) },
        manifestWriter: (@Sendable (AgentComposerAttachmentManifest, URL) throws -> Void)? = nil,
        removeItem: (@Sendable (URL) throws -> Void)? = nil
    ) {
        let root = applicationSupportDirectory
            ?? AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
            ?? RegistryStore.defaultApplicationSupportDirectory()
        self.layout = AgentComposerAttachmentStoreLayout(applicationSupportDirectory: root)
        self.clock = clock
        self.warn = warn
        self.writeManifest = manifestWriter ?? Self.defaultPersistManifest
        self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }
    }

    public func importValidatedPastedImage(
        _ data: Data,
        displayName: String? = nil,
        validation: AgentComposerImageValidation,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        try importManagedBytes(
            data,
            displayName: displayName,
            validation: validation,
            forDraftOf: agentID
        )
    }

    public func importValidatedLocalImageFile(
        _ sourceURL: URL,
        displayName: String? = nil,
        validation: AgentComposerImageValidation,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        guard sourceURL.isFileURL else {
            throw AgentComposerAttachmentStoreError.nonFileURL(sourceURL.absoluteString)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw AgentComposerAttachmentStoreError.unreadableSource(sourceURL.path)
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw AgentComposerAttachmentStoreError.unreadableSource(sourceURL.path)
        }
        let data = try Data(contentsOf: sourceURL)
        return try importManagedBytes(
            data,
            displayName: displayName ?? sourceURL.lastPathComponent,
            validation: validation,
            forDraftOf: agentID
        )
    }

    public func storedAttachment(for id: AgentImageAttachmentID) throws -> AgentComposerStoredAttachment? {
        guard let manifest = try loadManifest(for: id) else { return nil }
        let url = try fileURL(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return AgentComposerStoredAttachment(manifest: manifest, fileURL: url)
    }

    public func fileURL(for id: AgentImageAttachmentID) throws -> URL? {
        guard let manifest = try loadManifest(for: id) else { return nil }
        let url = try fileURL(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// All-or-nothing transport preparation for the expected agent. Every draft
    /// reference is validated before any prompt is returned: manifest storage key
    /// and decoded ids must match, path-free draft metadata must match the
    /// manifest, ownership must still be draft-owned by `agentID`, the managed
    /// object must remain canonically under the attachment root (including
    /// symlink resolution), and the object must be a readable regular file.
    public func preparePromptAttachments(
        for agentID: AgentID,
        draftAttachments: [AgentComposerDraftImageAttachment]
    ) throws -> [AgentPromptImageAttachment] {
        try preparedDraftManifests(for: agentID, draftAttachments: draftAttachments)
            .map { AgentComposerStoredAttachment(manifest: $0.manifest, fileURL: $0.fileURL).promptAttachment }
    }

    public func manifest(for id: AgentImageAttachmentID) throws -> AgentComposerAttachmentManifest? {
        try loadManifest(for: id)
    }

    public func transferDraftAttachmentsToSent(
        for agentID: AgentID,
        draftAttachments: [AgentComposerDraftImageAttachment],
        sentAt explicitSentAt: Date? = nil
    ) throws {
        try recoverPendingOwnershipTransfers()
        let prepared = try preparedDraftManifests(for: agentID, draftAttachments: draftAttachments)
        try transferPreparedDraftManifestsToSent(prepared.map(\.manifest), sentAt: explicitSentAt ?? clock.now())
    }

    public func transferDraftAttachmentsToSent(
        for agentID: AgentID,
        attachmentIDs: [AgentImageAttachmentID],
        sentAt explicitSentAt: Date? = nil
    ) throws {
        try recoverPendingOwnershipTransfers()
        let manifests = try attachmentIDs.map { id -> AgentComposerAttachmentManifest in
            guard let manifest = try loadManifest(for: id) else {
                throw AgentComposerAttachmentStoreError.missingAttachment(id)
            }
            guard manifest.ownership.state == .draft, manifest.ownership.agentID == agentID else {
                throw AgentComposerAttachmentStoreError.ownershipMismatch(
                    id: id,
                    expected: agentID,
                    actual: manifest.ownership.agentID
                )
            }
            _ = try validatedManagedFileURL(for: manifest)
            return manifest
        }
        try transferPreparedDraftManifestsToSent(manifests, sentAt: explicitSentAt ?? clock.now())
    }

    /// Conservative cleanup seam. Callers supply the current draft references;
    /// only stale draft-owned attachments outside that set are removed. Sent
    /// attachments are never removed here because transcripts may still refer to
    /// their path-free metadata. Any object/manifest deletion failure is surfaced
    /// as a thrown error instead of being reported as a successful cleanup.
    @discardableResult
    public func cleanupUnreferencedDraftAttachments(
        retaining referencedIDs: Set<AgentImageAttachmentID>,
        graceInterval: TimeInterval
    ) throws -> [AgentImageAttachmentID] {
        guard FileManager.default.fileExists(atPath: layout.manifestsDirectory.path) else { return [] }
        let cutoff = clock.now().addingTimeInterval(-max(0, graceInterval))
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: layout.manifestsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removed: [AgentImageAttachmentID] = []
        var deletionFailures: [String] = []
        for manifestURL in manifestURLs where manifestURL.pathExtension == "json" {
            do {
                let manifest: AgentComposerAttachmentManifest = try reader.read(at: manifestURL)
                guard manifest.id == manifest.metadata.id else {
                    throw AgentComposerAttachmentStoreError.manifestIdentityMismatch(
                        expected: manifest.id,
                        actual: manifest.metadata.id
                    )
                }
                guard manifest.ownership.state == .draft else { continue }
                guard !referencedIDs.contains(manifest.id) else { continue }
                guard manifest.updatedAt <= cutoff else { continue }
                let objectURL = try fileURL(for: manifest)
                var objectDeleted = true
                if FileManager.default.fileExists(atPath: objectURL.path) {
                    do { try removeItem(objectURL) }
                    catch {
                        objectDeleted = false
                        deletionFailures.append("object \(manifest.id.rawValue): \(error)")
                    }
                }
                guard objectDeleted else { continue }
                do {
                    try removeItem(manifestURL)
                    removed.append(manifest.id)
                } catch {
                    deletionFailures.append("manifest \(manifest.id.rawValue): \(error)")
                }
            } catch {
                warn("AgentComposerAttachmentStore.cleanup: skipped unreadable or unsafe manifest at \(manifestURL.path): \(error)")
                continue
            }
        }
        if !deletionFailures.isEmpty {
            throw AgentComposerAttachmentStoreError.cleanupDeletionFailed(deletionFailures)
        }
        return removed
    }

    private struct PreparedDraftManifest {
        var manifest: AgentComposerAttachmentManifest
        var fileURL: URL
    }

    private func preparedDraftManifests(
        for agentID: AgentID,
        draftAttachments: [AgentComposerDraftImageAttachment]
    ) throws -> [PreparedDraftManifest] {
        var prepared: [PreparedDraftManifest] = []
        prepared.reserveCapacity(draftAttachments.count)
        for draftAttachment in draftAttachments {
            let id = draftAttachment.attachmentID
            guard let manifest = try loadManifest(for: id) else {
                throw AgentComposerAttachmentStoreError.missingAttachment(id)
            }
            guard manifest.draftAttachment == draftAttachment else {
                throw AgentComposerAttachmentStoreError.draftMetadataMismatch(id: id)
            }
            guard manifest.ownership.state == .draft, manifest.ownership.agentID == agentID else {
                throw AgentComposerAttachmentStoreError.ownershipMismatch(
                    id: id,
                    expected: agentID,
                    actual: manifest.ownership.agentID
                )
            }
            let url = try validatedManagedFileURL(for: manifest)
            prepared.append(PreparedDraftManifest(manifest: manifest, fileURL: url))
        }
        return prepared
    }

    public func recoverPendingOwnershipTransfers() throws {
        guard FileManager.default.fileExists(atPath: layout.ownershipTransactionsDirectory.path) else { return }
        let journalURLs = try FileManager.default.contentsOfDirectory(
            at: layout.ownershipTransactionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        for journalURL in journalURLs {
            let journal: AgentComposerOwnershipTransferJournal = try reader.read(at: journalURL)
            let manifests = journal.state == .pending ? journal.originals : journal.sent
            var failures: [String] = []
            for manifest in manifests {
                do { try persist(manifest) }
                catch { failures.append("manifest \(manifest.id.rawValue): \(error)") }
            }
            guard failures.isEmpty else {
                throw AgentComposerAttachmentStoreError.transferRecoveryFailed(
                    journalPath: journalURL.path,
                    failures: failures
                )
            }
            try removeDurably(journalURL)
        }
    }

    private func transferPreparedDraftManifestsToSent(_ manifests: [AgentComposerAttachmentManifest], sentAt: Date) throws {
        guard !manifests.isEmpty else { return }
        let sentManifests = manifests.map { original -> AgentComposerAttachmentManifest in
            var manifest = original
            manifest.ownership = .sent(agentID: original.ownership.agentID, at: sentAt)
            manifest.updatedAt = sentAt
            return manifest
        }
        let journalURL = layout.ownershipTransactionsDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString).json", isDirectory: false)
        var journal = AgentComposerOwnershipTransferJournal(
            id: UUID(),
            state: .pending,
            originals: manifests,
            sent: sentManifests,
            updatedAt: sentAt
        )
        try persistTransferJournal(journal, at: journalURL)
        var persistedOriginals: [AgentComposerAttachmentManifest] = []
        do {
            for manifest in sentManifests {
                try persist(manifest)
                if let original = manifests.first(where: { $0.id == manifest.id }) {
                    persistedOriginals.append(original)
                }
            }
            journal.state = .committed
            journal.updatedAt = sentAt
            try persistTransferJournal(journal, at: journalURL)
        } catch {
            var rollbackFailures: [String] = []
            for original in persistedOriginals.reversed() {
                do { try persist(original) }
                catch { rollbackFailures.append("manifest \(original.id.rawValue): \(error)") }
            }
            if rollbackFailures.isEmpty {
                try? removeDurably(journalURL)
                throw error
            }
            throw AgentComposerAttachmentStoreError.transferRollbackFailed(
                transferError: String(describing: error),
                rollbackFailures: rollbackFailures,
                journalPath: journalURL.path
            )
        }
        do {
            try removeDurably(journalURL)
        } catch {
            throw AgentComposerAttachmentStoreError.transferRecoveryFailed(
                journalPath: journalURL.path,
                failures: ["committed journal removal: \(error)"]
            )
        }
    }

    private func importManagedBytes(
        _ data: Data,
        displayName: String?,
        validation: AgentComposerImageValidation,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        let now = clock.now()
        let id = try Self.makeOpaqueID()
        let metadata = AgentImageAttachmentMetadata(
            id: id,
            displayName: Self.safeDisplayName(displayName),
            contentType: validation.contentType,
            byteCount: validation.byteCount ?? UInt64(data.count),
            pixelWidth: validation.pixelWidth,
            pixelHeight: validation.pixelHeight
        )
        let relativePath = layout.objectRelativePath(for: id)
        let manifest = AgentComposerAttachmentManifest(
            id: id,
            metadata: metadata,
            relativePath: relativePath,
            ownership: .draft(agentID: agentID, at: now),
            createdAt: now,
            updatedAt: now
        )
        let fileURL = try fileURL(for: manifest)
        try prepareDirectories()
        try Self.atomicRestrictedWrite(data, to: fileURL)
        do {
            try persist(manifest)
        } catch {
            do {
                try removeItem(fileURL)
            } catch let rollbackError {
                throw AgentComposerAttachmentStoreError.importRollbackFailed(
                    manifestError: String(describing: error),
                    objectPath: fileURL.path,
                    rollbackError: String(describing: rollbackError)
                )
            }
            throw error
        }
        return AgentComposerStoredAttachment(manifest: manifest, fileURL: fileURL)
    }

    private func prepareDirectories() throws {
        for directory in [layout.attachmentsDirectory, layout.objectsDirectory, layout.manifestsDirectory, layout.ownershipTransactionsDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    private func persist(_ manifest: AgentComposerAttachmentManifest) throws {
        try prepareDirectories()
        let manifestFile = layout.manifestFile(for: manifest.id)
        try writeManifest(manifest, manifestFile)
    }

    private func persistTransferJournal(_ journal: AgentComposerOwnershipTransferJournal, at url: URL) throws {
        try prepareDirectories()
        try AtomicWriter(backupsDirectory: nil, retainedBackups: 0).write(journal, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeDurably(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try removeItem(url)
            try Self.fsyncDirectory(url.deletingLastPathComponent())
        }
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if fsync(fd) != 0 {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if close(fd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func defaultPersistManifest(_ manifest: AgentComposerAttachmentManifest, to manifestFile: URL) throws {
        try AtomicWriter(backupsDirectory: nil, retainedBackups: 0).write(manifest, to: manifestFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestFile.path)
    }

    private func loadManifest(for id: AgentImageAttachmentID) throws -> AgentComposerAttachmentManifest? {
        let manifestFile = layout.manifestFile(for: id)
        guard FileManager.default.fileExists(atPath: manifestFile.path) else { return nil }
        let manifest: AgentComposerAttachmentManifest = try reader.read(at: manifestFile)
        guard manifest.id == id else {
            throw AgentComposerAttachmentStoreError.manifestIdentityMismatch(expected: id, actual: manifest.id)
        }
        guard manifest.metadata.id == id else {
            throw AgentComposerAttachmentStoreError.manifestIdentityMismatch(expected: id, actual: manifest.metadata.id)
        }
        return manifest
    }

    private func fileURL(for manifest: AgentComposerAttachmentManifest) throws -> URL {
        try Self.safeLocalURL(root: layout.attachmentsDirectory, relativePath: manifest.relativePath)
    }

    private func validatedManagedFileURL(for manifest: AgentComposerAttachmentManifest) throws -> URL {
        let url = try fileURL(for: manifest)
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            throw AgentComposerAttachmentStoreError.missingAttachment(manifest.id)
        }
        let fileKind = statBuffer.st_mode & S_IFMT
        guard fileKind == S_IFREG, FileManager.default.isReadableFile(atPath: url.path) else {
            throw AgentComposerAttachmentStoreError.unreadableManagedFile(id: manifest.id, path: url.path)
        }
        _ = try Self.safeLocalURL(root: layout.attachmentsDirectory, relativePath: manifest.relativePath)
        return url
    }

    private static func makeOpaqueID() throws -> AgentImageAttachmentID {
        guard let id = AgentImageAttachmentID(rawValue: "local-image-\(UUID().uuidString.lowercased())") else {
            throw AgentComposerAttachmentStoreError.atomicWriteFailed("could not create opaque attachment id")
        }
        return id
    }

    private static func safeDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func safeLocalURL(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw AgentComposerAttachmentStoreError.unsafeRelativePath(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentComposerAttachmentStoreError.unsafeRelativePath(relativePath)
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard canonicalCandidate.path.hasPrefix(rootPrefix) else {
            throw AgentComposerAttachmentStoreError.unsafeRelativePath(relativePath)
        }
        return candidate
    }

    private static func atomicRestrictedWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw AgentComposerAttachmentStoreError.atomicWriteFailed(tmp.path)
        }
        var closeNeeded = true
        do {
            try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) throws in
                var remaining = rawBuffer.count
                var pointer = rawBuffer.baseAddress
                while remaining > 0 {
                    let written = Darwin.write(fd, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    remaining -= written
                    pointer = pointer?.advanced(by: written)
                }
            }
            if fsync(fd) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if close(fd) != 0 {
                closeNeeded = false
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            closeNeeded = false
            if rename(tmp.path, url.path) != 0 {
                let err = errno
                try? FileManager.default.removeItem(at: tmp)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            let dfd = open(dir.path, O_RDONLY)
            guard dfd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if fsync(dfd) != 0 {
                let err = errno
                close(dfd)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            if close(dfd) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            if closeNeeded { close(fd) }
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
