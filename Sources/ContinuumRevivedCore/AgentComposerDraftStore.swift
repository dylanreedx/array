import ContinuumRevivedAgentContent
import Foundation

/// One host-local image attachment retained by an unfinished composer draft.
/// The id is opaque and resolves only through `AgentComposerAttachmentStore`;
/// no local path or provider-specific payload is persisted here.
public struct AgentComposerDraftImageAttachment: Codable, Equatable, Sendable {
    public var metadata: AgentImageAttachmentMetadata

    public init(metadata: AgentImageAttachmentMetadata) {
        self.metadata = metadata
    }

    public var attachmentID: AgentImageAttachmentID { metadata.id }
}

/// Host-local composer state. Prompt text deliberately lives outside
/// `AgentRecord` and every sync model.
public struct AgentComposerDraft: Codable, Equatable, Sendable {
    public var text: String
    public var selection: Range<Int>
    public var updatedAt: Date
    public var imageAttachments: [AgentComposerDraftImageAttachment]

    public init(
        text: String,
        selection: Range<Int>,
        updatedAt: Date,
        imageAttachments: [AgentComposerDraftImageAttachment] = []
    ) {
        self.text = text
        self.selection = selection
        self.updatedAt = updatedAt
        self.imageAttachments = imageAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case text, selection, updatedAt, imageAttachments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        selection = try values.decode(Range<Int>.self, forKey: .selection)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        imageAttachments = try values.decodeIfPresent([AgentComposerDraftImageAttachment].self, forKey: .imageAttachments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        try values.encode(selection, forKey: .selection)
        try values.encode(updatedAt, forKey: .updatedAt)
        if !imageAttachments.isEmpty {
            try values.encode(imageAttachments, forKey: .imageAttachments)
        }
    }
}

public struct AgentComposerDraftStoreLayout: Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var draftsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("agent-composer-drafts", isDirectory: true)
    }

    public var backupsDirectory: URL {
        draftsDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public var submissionRecoveryDirectory: URL {
        draftsDirectory.appendingPathComponent("submission-recovery", isDirectory: true)
    }

    public func draftFile(for agentID: AgentID) -> URL {
        draftsDirectory.appendingPathComponent("\(agentID.rawValue.uuidString).json", isDirectory: false)
    }

    public func submissionRecoveryFile(for agentID: AgentID) -> URL {
        submissionRecoveryDirectory.appendingPathComponent("\(agentID.rawValue.uuidString).json", isDirectory: false)
    }
}

public struct AgentComposerSubmissionSnapshot: Codable, Equatable, Sendable {
    public var draft: AgentComposerDraft
    public var submittedAt: Date

    public init(draft: AgentComposerDraft, submittedAt: Date) {
        self.draft = draft
        self.submittedAt = submittedAt
    }
}

/// Debounced, per-agent local persistence for sensitive unfinished prompts.
///
/// The actor keeps the newest edit in memory immediately and performs at most
/// one AtomicWriter write per agent per debounce window. `flush` is exposed for
/// orderly shutdown and deterministic checks; normal editing must use `save`.
public actor AgentComposerDraftStore {
    public let layout: AgentComposerDraftStoreLayout

    private let writer: AtomicWriter
    private let debounceNanoseconds: UInt64
    private let attachmentStore: AgentComposerAttachmentStore?
    private let clock: any Clock
    private let warn: @Sendable (String) -> Void
    private var pending: [AgentID: AgentComposerDraft] = [:]
    private var scheduledWrites: [AgentID: Task<Void, Never>] = [:]
    /// Highest edit timestamp accepted for each agent. UI callbacks enqueue
    /// independent tasks, so actor arrival order is not edit order.
    private var newestSeen: [AgentID: Date] = [:]
    /// Prevents an already-enqueued UI save task from resurrecting a draft after
    /// its later accepted-send task reaches the actor first.
    private var clearedThrough: [AgentID: Date] = [:]

    public init(
        applicationSupportDirectory: URL? = nil,
        debounceInterval: TimeInterval = 0.5,
        attachmentStore: AgentComposerAttachmentStore? = nil,
        clock: any Clock = SystemClock(),
        warn: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        let root = applicationSupportDirectory
            ?? AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
            ?? RegistryStore.defaultApplicationSupportDirectory()
        let layout = AgentComposerDraftStoreLayout(applicationSupportDirectory: root)
        self.layout = layout
        // Do not supply a backup directory at all. AtomicWriter creates a backup
        // before pruning, so retention zero alone can still leave prompt text if
        // pruning fails. Temp-file + fsync + rename durability does not need backups.
        self.writer = AtomicWriter(backupsDirectory: nil, retainedBackups: 0)
        self.debounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        self.attachmentStore = attachmentStore
        self.clock = clock
        self.warn = warn
    }

    public func save(_ draft: AgentComposerDraft, for agentID: AgentID) {
        if let clearedAt = clearedThrough[agentID], draft.updatedAt <= clearedAt {
            return
        }
        if let newest = newestSeen[agentID], draft.updatedAt < newest {
            return
        }
        newestSeen[agentID] = draft.updatedAt
        pending[agentID] = draft
        scheduledWrites[agentID]?.cancel()
        let delay = debounceNanoseconds
        scheduledWrites[agentID] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.flush(agentID: agentID)
        }
    }

    /// Returns the newest in-memory edit when a debounce is outstanding.
    /// Missing or malformed files fail closed to no draft and never touch agent records.
    public func load(for agentID: AgentID) -> AgentComposerDraft? {
        if let draft = pending[agentID] { return draft }
        let url = layout.draftFile(for: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let draft: AgentComposerDraft = try writer.read(at: url)
            guard Self.hasValidSelection(draft) else {
                warn("AgentComposerDraftStore.load: invalid selection in \(url.path)")
                return nil
            }
            if newestSeen[agentID].map({ draft.updatedAt > $0 }) ?? true {
                newestSeen[agentID] = draft.updatedAt
            }
            return draft
        } catch {
            warn("AgentComposerDraftStore.load: unreadable draft at \(url.path): \(error)")
            return nil
        }
    }

    public func flush(agentID: AgentID) {
        scheduledWrites[agentID]?.cancel()
        scheduledWrites[agentID] = nil
        guard let draft = pending.removeValue(forKey: agentID) else { return }
        do {
            try persistDraft(draft, for: agentID)
        } catch {
            // Keep the newest value available for a later explicit flush instead of
            // losing it merely because this disk write failed.
            pending[agentID] = draft
            warn("AgentComposerDraftStore.save: could not persist draft for \(agentID.rawValue): \(error)")
        }
    }

    public func flushAll() {
        for agentID in Array(pending.keys) {
            flush(agentID: agentID)
        }
    }

    public func clear(for agentID: AgentID) {
        clearVisibleDraft(for: agentID, clearThrough: max(clock.now(), newestSeen[agentID] ?? .distantPast))
    }

    /// Explicit submission lifecycle, replacing the old "accepted means delete"
    /// model for prompt-capable callers. This persists a recoverable snapshot
    /// before clearing visible composer state, so a pre-start/provider refusal can
    /// restore the exact draft instead of losing local attachment references.
    @discardableResult
    public func beginSubmission(for agentID: AgentID, draft explicitDraft: AgentComposerDraft? = nil, submittedAt: Date? = nil) throws -> Bool {
        guard let draft = explicitDraft ?? pending[agentID] ?? load(for: agentID) else { return false }
        let stamp = submittedAt ?? clock.now()
        try persistSubmissionSnapshot(AgentComposerSubmissionSnapshot(draft: draft, submittedAt: stamp), for: agentID)
        clearVisibleDraft(for: agentID, clearThrough: max(stamp, draft.updatedAt))
        return true
    }

    /// Restores the durable recoverable snapshot after a pre-start/provider
    /// rejection. The snapshot is removed only after the visible draft has been
    /// durably restored.
    @discardableResult
    public func restoreSubmission(for agentID: AgentID) throws -> AgentComposerDraft? {
        guard let snapshot = try loadSubmissionSnapshot(for: agentID) else { return nil }
        clearedThrough[agentID] = nil
        newestSeen[agentID] = snapshot.draft.updatedAt
        pending[agentID] = snapshot.draft
        try persistDraft(snapshot.draft, for: agentID)
        try removeSubmissionSnapshot(for: agentID)
        return snapshot.draft
    }

    /// Confirms provider/turn start. Attachment ownership is transferred only
    /// after the recoverable snapshot has been retained; if transfer fails, the
    /// snapshot remains available for restore and the visible draft stays cleared.
    @discardableResult
    public func confirmSubmissionStarted(for agentID: AgentID, sentAt: Date? = nil) async throws -> Bool {
        guard let snapshot = try loadSubmissionSnapshot(for: agentID) else { return false }
        if let attachmentStore, !snapshot.draft.imageAttachments.isEmpty {
            try await attachmentStore.transferDraftAttachmentsToSent(
                for: agentID,
                draftAttachments: snapshot.draft.imageAttachments,
                sentAt: sentAt ?? clock.now()
            )
        }
        try removeSubmissionSnapshot(for: agentID)
        clearVisibleDraft(for: agentID, clearThrough: max(sentAt ?? clock.now(), snapshot.draft.updatedAt))
        return true
    }

    /// Compatibility shim for existing text-only UI. New prompt-capable callers
    /// must use begin/restore/confirm above so pre-start failures can recover.
    public func resolveSendIntent(for agentID: AgentID, accepted: Bool, sentAt: Date? = nil) async {
        guard accepted else { return }
        do {
            guard try beginSubmission(for: agentID, submittedAt: sentAt ?? clock.now()) else { return }
            _ = try await confirmSubmissionStarted(for: agentID, sentAt: sentAt)
        } catch {
            warn("AgentComposerDraftStore.resolveSendIntent: preserving recoverable submission for \(agentID.rawValue) because confirmation failed: \(error)")
        }
    }

    private func clearVisibleDraft(for agentID: AgentID, clearThrough: Date) {
        clearedThrough[agentID] = clearThrough
        scheduledWrites.removeValue(forKey: agentID)?.cancel()
        pending.removeValue(forKey: agentID)
        let url = layout.draftFile(for: agentID)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { warn("AgentComposerDraftStore.clear: could not remove \(url.path): \(error)") }
        }
    }

    private func persistDraft(_ draft: AgentComposerDraft, for agentID: AgentID) throws {
        try FileManager.default.createDirectory(
            at: layout.draftsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: layout.draftsDirectory.path
        )
        try writer.write(draft, to: layout.draftFile(for: agentID))
        try Self.restrictPermissions(at: layout.draftsDirectory, file: layout.draftFile(for: agentID))
    }

    private func persistSubmissionSnapshot(_ snapshot: AgentComposerSubmissionSnapshot, for agentID: AgentID) throws {
        try FileManager.default.createDirectory(
            at: layout.submissionRecoveryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: layout.submissionRecoveryDirectory.path
        )
        let file = layout.submissionRecoveryFile(for: agentID)
        try writer.write(snapshot, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func loadSubmissionSnapshot(for agentID: AgentID) throws -> AgentComposerSubmissionSnapshot? {
        let file = layout.submissionRecoveryFile(for: agentID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try writer.read(at: file)
    }

    private func removeSubmissionSnapshot(for agentID: AgentID) throws {
        let file = layout.submissionRecoveryFile(for: agentID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func hasValidSelection(_ draft: AgentComposerDraft) -> Bool {
        let utf16Count = (draft.text as NSString).length
        return draft.selection.lowerBound >= 0
            && draft.selection.upperBound >= draft.selection.lowerBound
            && draft.selection.upperBound <= utf16Count
    }

    private static func restrictPermissions(at directory: URL, file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
