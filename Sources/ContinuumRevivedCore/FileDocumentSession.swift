import Foundation

public enum FileDocumentUnavailableReason: Equatable, Sendable {
    case missing
    case notRegularFile
    case tooLarge(maxBytes: Int)
    case unsupportedEncoding
    case unreadable(String)
}

public enum FileDocumentExternalState: Equatable, Sendable {
    case current
    case changed
    case unavailable(FileDocumentUnavailableReason)
}

public enum FileDocumentDraftUpdateResult: Equatable, Sendable {
    case updated(revision: UInt64)
    case stale(currentRevision: UInt64)
}

public enum FileDocumentRefreshResult: Equatable, Sendable {
    case unchanged
    case reloaded(revision: UInt64)
    case conflict
    case unavailable(FileDocumentUnavailableReason)
}

public enum FileDocumentSaveResult: Equatable, Sendable {
    case saved(revision: UInt64)
    case unchanged
    case conflict
    case unavailable(FileDocumentUnavailableReason)
    case draftTooLarge(maxBytes: Int)
    case writeFailed(String)
    case stale(currentRevision: UInt64)
}

public struct FileDocumentRecoverySnapshot: Codable, Equatable, Sendable {
    public var filePath: String
    public var baselineText: String
    public var draftText: String
    public var updatedAt: Date

    public init(filePath: String, baselineText: String, draftText: String, updatedAt: Date) {
        self.filePath = filePath
        self.baselineText = baselineText
        self.draftText = draftText
        self.updatedAt = updatedAt
    }
}

package struct FileDocumentFileOperations: @unchecked Sendable {
    package var attributes: (String) throws -> [FileAttributeKey: Any]
    package var read: (URL) throws -> Data
    package var write: (Data, URL) throws -> Void

    package init(
        attributes: @escaping (String) throws -> [FileAttributeKey: Any],
        read: @escaping (URL) throws -> Data,
        write: @escaping (Data, URL) throws -> Void
    ) {
        self.attributes = attributes
        self.read = read
        self.write = write
    }

    package static let live = FileDocumentFileOperations(
        attributes: { try FileManager.default.attributesOfItem(atPath: $0) },
        read: { try Data(contentsOf: $0) },
        write: { data, url in try data.write(to: url, options: .atomic) }
    )
}

/// Owns one file's draft and disk baseline. UI components supply edits tagged
/// with a revision; only this object decides whether disk may be replaced.
public final class FileDocumentSession {
    public static let maxBytes = FilePreview.maxReadBytes

    public let filePath: String
    public private(set) var draftText: String?
    public private(set) var baselineText: String?
    public private(set) var revision: UInt64 = 0
    public private(set) var externalState: FileDocumentExternalState = .current
    public private(set) var unavailableReason: FileDocumentUnavailableReason?

    private let fileOperations: FileDocumentFileOperations

    public convenience init(path: String) {
        self.init(path: path, fileOperations: .live)
    }

    package init(path: String, fileOperations: FileDocumentFileOperations) {
        filePath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        self.fileOperations = fileOperations
        switch readDisk() {
        case let .text(text):
            draftText = text
            baselineText = text
        case let .unavailable(reason):
            unavailableReason = reason
            externalState = .unavailable(reason)
        }
    }

    public var isDirty: Bool { draftText != baselineText }

    /// Drops the in-memory draft without touching disk. The next refresh may
    /// then adopt a newer disk baseline, which is the explicit Reload path used
    /// by conflict UI.
    public func discardDraft() {
        draftText = baselineText
        externalState = .current
        revision &+= 1
    }

    @discardableResult
    public func updateDraft(_ text: String, expectedRevision: UInt64? = nil) -> FileDocumentDraftUpdateResult {
        if let expectedRevision, expectedRevision != revision {
            return .stale(currentRevision: revision)
        }
        draftText = text
        revision &+= 1
        return .updated(revision: revision)
    }

    /// Reconciles a full editor snapshot after a dropped or out-of-order bridge
    /// message while preserving the editor's monotonic revision.
    @discardableResult
    public func synchronizeDraft(_ text: String, revision incomingRevision: UInt64) -> FileDocumentDraftUpdateResult {
        guard incomingRevision >= revision else { return .stale(currentRevision: revision) }
        draftText = text
        revision = incomingRevision
        return .updated(revision: revision)
    }

    @discardableResult
    public func refreshFromDisk() -> FileDocumentRefreshResult {
        switch readDisk() {
        case let .unavailable(reason):
            unavailableReason = reason
            externalState = .unavailable(reason)
            return .unavailable(reason)
        case let .text(diskText):
            unavailableReason = nil
            guard diskText != baselineText else {
                externalState = .current
                return .unchanged
            }
            if isDirty {
                externalState = .changed
                return .conflict
            }
            baselineText = diskText
            draftText = diskText
            externalState = .current
            revision &+= 1
            return .reloaded(revision: revision)
        }
    }

    @discardableResult
    public func save(
        expectedRevision: UInt64? = nil,
        overwriteExternalChanges: Bool = false
    ) -> FileDocumentSaveResult {
        if let expectedRevision, expectedRevision != revision {
            return .stale(currentRevision: revision)
        }
        guard let draftText, let baselineText else {
            return .unavailable(unavailableReason ?? .missing)
        }
        let data = Data(draftText.utf8)
        guard data.count <= Self.maxBytes else { return .draftTooLarge(maxBytes: Self.maxBytes) }

        switch readDisk() {
        case let .unavailable(reason):
            externalState = .unavailable(reason)
            unavailableReason = reason
            return .unavailable(reason)
        case let .text(diskText):
            guard diskText == baselineText || overwriteExternalChanges else {
                externalState = .changed
                return .conflict
            }
        }

        if draftText == baselineText {
            externalState = .current
            return .unchanged
        }
        do {
            try fileOperations.write(data, URL(fileURLWithPath: filePath))
            self.baselineText = draftText
            unavailableReason = nil
            externalState = .current
            revision &+= 1
            return .saved(revision: revision)
        } catch {
            return .writeFailed(Self.boundedMessage(error))
        }
    }

    public func recoverySnapshot(updatedAt: Date = Date()) -> FileDocumentRecoverySnapshot? {
        guard isDirty, let baselineText, let draftText else { return nil }
        return FileDocumentRecoverySnapshot(
            filePath: filePath, baselineText: baselineText, draftText: draftText, updatedAt: updatedAt
        )
    }

    /// Restores only a snapshot for this exact canonical file. A baseline
    /// mismatch keeps the recovered draft and exposes an external conflict.
    @discardableResult
    public func restoreRecovery(_ snapshot: FileDocumentRecoverySnapshot) -> Bool {
        let recoveredPath = URL(fileURLWithPath: snapshot.filePath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard recoveredPath == filePath else { return false }
        baselineText = snapshot.baselineText
        draftText = snapshot.draftText
        revision &+= 1
        switch readDisk() {
        case let .text(diskText):
            unavailableReason = nil
            externalState = diskText == snapshot.baselineText ? .current : .changed
        case let .unavailable(reason):
            unavailableReason = reason
            externalState = .unavailable(reason)
        }
        return true
    }

    private enum DiskRead {
        case text(String)
        case unavailable(FileDocumentUnavailableReason)
    }

    private func readDisk() -> DiskRead {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileOperations.attributes(filePath)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .unavailable(.missing)
        } catch {
            // FileManager commonly reports a missing path as Cocoa 260, but
            // custom and platform implementations need a deterministic check.
            if !FileManager.default.fileExists(atPath: filePath) { return .unavailable(.missing) }
            return .unavailable(.unreadable(Self.boundedMessage(error)))
        }
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            return .unavailable(.notRegularFile)
        }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(Self.maxBytes) {
            return .unavailable(.tooLarge(maxBytes: Self.maxBytes))
        }
        do {
            let data = try fileOperations.read(URL(fileURLWithPath: filePath))
            guard data.count <= Self.maxBytes else {
                return .unavailable(.tooLarge(maxBytes: Self.maxBytes))
            }
            guard !Self.hasUnsupportedBOM(data), !data.prefix(8 * 1_024).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                return .unavailable(.unsupportedEncoding)
            }
            return .text(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        } catch {
            return .unavailable(.unreadable(Self.boundedMessage(error)))
        }
    }

    private static func hasUnsupportedBOM(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(4))
        return bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
    }

    private static func boundedMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}
