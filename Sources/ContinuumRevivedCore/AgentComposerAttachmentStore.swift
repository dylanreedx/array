import ContinuumRevivedAgentContent
import CryptoKit
import Darwin
import Foundation

public enum AgentComposerAttachmentStoreError: Error, Equatable {
    case nonFileURL(String)
    case unreadableSource(String)
    case unsafeRelativePath(String)
    case ownershipMismatch(id: AgentImageAttachmentID, expected: AgentID, actual: AgentID?)
    case atomicWriteFailed(String)
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

/// Array-managed host-local storage for composer image originals. It imports
/// bytes/files into Application Support, persists only opaque ids plus
/// path-free metadata in drafts/transcripts, and resolves ids back to local file
/// capabilities for provider adapters on this host.
public actor AgentComposerAttachmentStore {
    public let layout: AgentComposerAttachmentStoreLayout

    private let writer = AtomicWriter(backupsDirectory: nil, retainedBackups: 0)
    private let clock: any Clock
    private let warn: @Sendable (String) -> Void

    public init(
        applicationSupportDirectory: URL? = nil,
        clock: any Clock = SystemClock(),
        warn: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        let root = applicationSupportDirectory
            ?? AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
            ?? RegistryStore.defaultApplicationSupportDirectory()
        self.layout = AgentComposerAttachmentStoreLayout(applicationSupportDirectory: root)
        self.clock = clock
        self.warn = warn
    }

    public func importPastedBytes(
        _ data: Data,
        displayName: String? = nil,
        contentType: String? = nil,
        pixelWidth: UInt? = nil,
        pixelHeight: UInt? = nil,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        try importManagedBytes(
            data,
            displayName: displayName,
            contentType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            forDraftOf: agentID
        )
    }

    public func importLocalImageFile(
        _ sourceURL: URL,
        displayName: String? = nil,
        contentType: String? = nil,
        pixelWidth: UInt? = nil,
        pixelHeight: UInt? = nil,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        guard sourceURL.isFileURL else {
            throw AgentComposerAttachmentStoreError.nonFileURL(sourceURL.absoluteString)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw AgentComposerAttachmentStoreError.unreadableSource(sourceURL.path)
        }
        let data = try Data(contentsOf: sourceURL)
        return try importManagedBytes(
            data,
            displayName: displayName ?? sourceURL.lastPathComponent,
            contentType: contentType ?? Self.inferredContentType(from: sourceURL.pathExtension),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
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

    public func promptAttachment(for draftAttachment: AgentComposerDraftImageAttachment) throws -> AgentPromptImageAttachment? {
        try storedAttachment(for: draftAttachment.attachmentID)?.promptAttachment
    }

    public func manifest(for id: AgentImageAttachmentID) throws -> AgentComposerAttachmentManifest? {
        try loadManifest(for: id)
    }

    public func transferDraftAttachmentsToSent(
        for agentID: AgentID,
        attachmentIDs: [AgentImageAttachmentID],
        sentAt explicitSentAt: Date? = nil
    ) throws {
        let sentAt = explicitSentAt ?? clock.now()
        for id in attachmentIDs {
            guard var manifest = try loadManifest(for: id) else { continue }
            switch manifest.ownership.state {
            case .draft:
                guard manifest.ownership.agentID == agentID else {
                    throw AgentComposerAttachmentStoreError.ownershipMismatch(
                        id: id,
                        expected: agentID,
                        actual: manifest.ownership.agentID
                    )
                }
                manifest.ownership = .sent(agentID: agentID, at: sentAt)
                manifest.updatedAt = sentAt
                try persist(manifest)
            case .sent:
                guard manifest.ownership.agentID == agentID else {
                    throw AgentComposerAttachmentStoreError.ownershipMismatch(
                        id: id,
                        expected: agentID,
                        actual: manifest.ownership.agentID
                    )
                }
            }
        }
    }

    /// Conservative cleanup seam. Callers supply the current draft references;
    /// only stale draft-owned attachments outside that set are removed. Sent
    /// attachments are never removed here because transcripts may still refer to
    /// their path-free metadata.
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
        for manifestURL in manifestURLs where manifestURL.pathExtension == "json" {
            do {
                let manifest: AgentComposerAttachmentManifest = try writer.read(at: manifestURL)
                guard manifest.ownership.state == .draft else { continue }
                guard !referencedIDs.contains(manifest.id) else { continue }
                guard manifest.updatedAt <= cutoff else { continue }
                let objectURL = try fileURL(for: manifest)
                try? FileManager.default.removeItem(at: objectURL)
                try? FileManager.default.removeItem(at: manifestURL)
                removed.append(manifest.id)
            } catch {
                warn("AgentComposerAttachmentStore.cleanup: skipped unreadable or unsafe manifest at \(manifestURL.path): \(error)")
                continue
            }
        }
        return removed
    }

    private func importManagedBytes(
        _ data: Data,
        displayName: String?,
        contentType: String?,
        pixelWidth: UInt?,
        pixelHeight: UInt?,
        forDraftOf agentID: AgentID
    ) throws -> AgentComposerStoredAttachment {
        let now = clock.now()
        let id = try Self.makeOpaqueID()
        let metadata = AgentImageAttachmentMetadata(
            id: id,
            displayName: Self.safeDisplayName(displayName),
            contentType: contentType,
            byteCount: UInt64(data.count),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
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
        try persist(manifest)
        return AgentComposerStoredAttachment(manifest: manifest, fileURL: fileURL)
    }

    private func prepareDirectories() throws {
        for directory in [layout.attachmentsDirectory, layout.objectsDirectory, layout.manifestsDirectory] {
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
        try writer.write(manifest, to: manifestFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestFile.path)
    }

    private func loadManifest(for id: AgentImageAttachmentID) throws -> AgentComposerAttachmentManifest? {
        let manifestFile = layout.manifestFile(for: id)
        guard FileManager.default.fileExists(atPath: manifestFile.path) else { return nil }
        let manifest: AgentComposerAttachmentManifest = try writer.read(at: manifestFile)
        return manifest
    }

    private func fileURL(for manifest: AgentComposerAttachmentManifest) throws -> URL {
        try Self.safeLocalURL(root: layout.attachmentsDirectory, relativePath: manifest.relativePath)
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

    private static func inferredContentType(from pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    private static func safeLocalURL(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw AgentComposerAttachmentStoreError.unsafeRelativePath(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentComposerAttachmentStoreError.unsafeRelativePath(relativePath)
        }
        let rootURL = root.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
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
            fsync(fd)
            close(fd)
            closeNeeded = false
            if rename(tmp.path, url.path) != 0 {
                let err = errno
                try? FileManager.default.removeItem(at: tmp)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            let dfd = open(dir.path, O_RDONLY)
            if dfd >= 0 { fsync(dfd); close(dfd) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            if closeNeeded { close(fd) }
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
