import ContinuumRevivedAgentContent
import Darwin
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

public enum AgentComposerSubmissionState: String, Codable, Sendable {
    case pending
    case confirming
    case confirmed
}

/// Read-only lifecycle information for a submission recovery journal. The
/// `active` bit is process-local: it distinguishes a journal still owned by a
/// live submission from one left behind by a failed/relaunched submission.
public enum AgentComposerSubmissionRecoveryState: Equatable, Sendable {
    case absent
    case pending(active: Bool)
    case confirming(active: Bool)
    case confirmed
}

public enum AgentComposerDraftStoreError: Error, Equatable, CustomStringConvertible {
    case storageReadFailed(String)

    /// Recovery diagnostics are deliberately bounded and path-free. The detail
    /// is retained only as an opaque local category, never as a filesystem URL.
    public var description: String {
        switch self {
        case .storageReadFailed:
            return "composer recovery storage read failed"
        }
    }
}

public struct AgentComposerSubmissionLease: Equatable, Sendable {
    public let agentID: AgentID
    fileprivate let token: UUID

    fileprivate init(agentID: AgentID, token: UUID) {
        self.agentID = agentID
        self.token = token
    }
}

public struct AgentComposerSubmissionSnapshot: Codable, Equatable, Sendable {
    public var draft: AgentComposerDraft
    public var submittedAt: Date
    public var state: AgentComposerSubmissionState

    public init(
        draft: AgentComposerDraft,
        submittedAt: Date,
        state: AgentComposerSubmissionState = .pending
    ) {
        self.draft = draft
        self.submittedAt = submittedAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case draft, submittedAt, state
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        draft = try values.decode(AgentComposerDraft.self, forKey: .draft)
        submittedAt = try values.decode(Date.self, forKey: .submittedAt)
        state = try values.decodeIfPresent(AgentComposerSubmissionState.self, forKey: .state) ?? .pending
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(draft, forKey: .draft)
        try values.encode(submittedAt, forKey: .submittedAt)
        try values.encode(state, forKey: .state)
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
    /// Zero in production. Checks may inject a bounded delay to force a
    /// rebind between recovery I/O and its main-actor apply.
    private let submissionRecoveryDelayNanoseconds: UInt64
    private let attachmentStore: AgentComposerAttachmentStore?
    private let clock: any Clock
    private let warn: @Sendable (String) -> Void
    private let writeSubmissionSnapshotFile: @Sendable (AgentComposerSubmissionSnapshot, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private var pending: [AgentID: AgentComposerDraft] = [:]
    private var scheduledWrites: [AgentID: Task<Void, Never>] = [:]
    /// Highest edit timestamp accepted for each agent. UI callbacks enqueue
    /// independent tasks, so actor arrival order is not edit order.
    private var newestSeen: [AgentID: Date] = [:]
    /// Prevents an already-enqueued UI save task from resurrecting a draft after
    /// its later accepted-send task reaches the actor first.
    private var clearedThrough: [AgentID: Date] = [:]
    /// A journal is not recoverable merely because it is present. This
    /// process-local marker remains set while the runner may still complete;
    /// a relaunch has no live submission and therefore treats the journal as
    /// recoverable.
    private var activeSubmissionAgents: Set<AgentID> = []
    /// A lease token prevents a stale cancelled task from relinquishing a
    /// newer submission for the same agent after a rapid rebind.
    private var submissionOwnership: [AgentID: UUID] = [:]

    public init(
        applicationSupportDirectory: URL? = nil,
        debounceInterval: TimeInterval = 0.5,
        attachmentStore: AgentComposerAttachmentStore? = nil,
        submissionRecoveryDelayNanoseconds: UInt64 = 0,
        clock: any Clock = SystemClock(),
        warn: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) },
        submissionSnapshotWriter: (@Sendable (AgentComposerSubmissionSnapshot, URL) throws -> Void)? = nil,
        removeItem: (@Sendable (URL) throws -> Void)? = nil
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
        self.submissionRecoveryDelayNanoseconds = submissionRecoveryDelayNanoseconds
        self.attachmentStore = attachmentStore
        self.clock = clock
        self.warn = warn
        self.writeSubmissionSnapshotFile = submissionSnapshotWriter ?? { snapshot, file in
            try AtomicWriter(backupsDirectory: nil, retainedBackups: 0).write(snapshot, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }
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
                warn("AgentComposerDraftStore.load: invalid draft selection")
                return nil
            }
            if newestSeen[agentID].map({ draft.updatedAt > $0 }) ?? true {
                newestSeen[agentID] = draft.updatedAt
            }
            return draft
        } catch {
            warn("AgentComposerDraftStore.load: unreadable draft")
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
            warn("AgentComposerDraftStore.save: could not persist draft for agent \(agentID.rawValue)")
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
    public func beginSubmissionLease(
        for agentID: AgentID,
        draft explicitDraft: AgentComposerDraft? = nil,
        submittedAt: Date? = nil
    ) async throws -> AgentComposerSubmissionLease? {
        guard let draft = explicitDraft ?? pending[agentID] ?? load(for: agentID) else { return nil }
        let stamp = submittedAt ?? clock.now()
        try persistSubmissionSnapshot(AgentComposerSubmissionSnapshot(draft: draft, submittedAt: stamp), for: agentID)
        clearVisibleDraft(for: agentID, clearThrough: max(stamp, draft.updatedAt))
        let lease = AgentComposerSubmissionLease(agentID: agentID, token: UUID())
        activeSubmissionAgents.insert(agentID)
        submissionOwnership[agentID] = lease.token
        return lease
    }

    @discardableResult
    public func beginSubmission(for agentID: AgentID, draft explicitDraft: AgentComposerDraft? = nil, submittedAt: Date? = nil) async throws -> Bool {
        try await beginSubmissionLease(for: agentID, draft: explicitDraft, submittedAt: submittedAt) != nil
    }

    /// Relinquishes only the exact pre-handoff lease. A stale task cannot
    /// deactivate a newer submission for the same agent after a rebind.
    public func relinquishSubmission(for agentID: AgentID, ownership lease: AgentComposerSubmissionLease) {
        guard lease.agentID == agentID, submissionOwnership[agentID] == lease.token else { return }
        submissionOwnership[agentID] = nil
        activeSubmissionAgents.remove(agentID)
    }

    /// Reads the journal lifecycle without restoring, transferring, or removing
    /// anything. A live pending/confirming journal must remain untouched while
    /// its runner can still emit authoritative completion.
    public func submissionRecoveryState(for agentID: AgentID) throws -> AgentComposerSubmissionRecoveryState {
        guard let snapshot = try loadSubmissionSnapshot(for: agentID) else { return .absent }
        let active = activeSubmissionAgents.contains(agentID)
        switch snapshot.state {
        case .pending: return .pending(active: active)
        case .confirming: return .confirming(active: active)
        case .confirmed: return .confirmed
        }
    }

    /// True when a submission journal exists. Callers use this to avoid falling
    /// back to an ordinary (cleared) draft when recovery itself is temporarily
    /// blocked by local storage validation.
    public func hasSubmissionRecovery(for agentID: AgentID) -> Bool {
        FileManager.default.fileExists(atPath: layout.submissionRecoveryFile(for: agentID).path)
    }

    /// Restores the durable recoverable snapshot after a pre-start/provider
    /// rejection. The snapshot is removed only after the visible draft has been
    /// durably restored.
    @discardableResult
    public func restoreSubmission(for agentID: AgentID) async throws -> AgentComposerDraft? {
        guard let snapshot = try loadSubmissionSnapshot(for: agentID) else { return nil }
        // This is an explicit failure/recovery operation. Once it starts, the
        // journal is no longer protected as an active live submission.
        activeSubmissionAgents.remove(agentID)
        submissionOwnership[agentID] = nil
        if submissionRecoveryDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: submissionRecoveryDelayNanoseconds)
        }
        switch snapshot.state {
        case .pending:
            break
        case .confirming:
            // Ownership recovery precedes any prompt validation. A confirming
            // record is still the durable source of the draft references; only a
            // durable all-sent fact makes it safe to discard them.
            if let attachmentStore {
                try await attachmentStore.recoverPendingOwnershipTransfers()
                var manifests: [AgentComposerAttachmentManifest?] = []
                for reference in snapshot.draft.imageAttachments {
                    manifests.append(try await attachmentStore.manifest(for: reference.attachmentID))
                }
                if !manifests.isEmpty && manifests.allSatisfy({ $0?.ownership.state == .sent }) {
                    try removeSubmissionSnapshot(for: agentID)
                    return nil
                }
            }
        case .confirmed:
            try removeSubmissionSnapshot(for: agentID)
            return nil
        }
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
        guard var snapshot = try loadSubmissionSnapshot(for: agentID) else { return false }
        let stamp = sentAt ?? clock.now()
        // Completion may be delivered by the supervisor after the composer has
        // detached. Keep the journal active until this authoritative operation
        // either succeeds or fails into an explicitly recoverable record.
        activeSubmissionAgents.insert(agentID)
        defer {
            activeSubmissionAgents.remove(agentID)
            submissionOwnership[agentID] = nil
        }
        if snapshot.state == .confirmed {
            try removeSubmissionSnapshot(for: agentID)
            clearVisibleDraft(for: agentID, clearThrough: max(stamp, snapshot.draft.updatedAt))
            return true
        }
        if snapshot.state == .pending {
            snapshot.state = .confirming
            try persistSubmissionSnapshot(snapshot, for: agentID)
        }
        if let attachmentStore, !snapshot.draft.imageAttachments.isEmpty {
            do {
                try await attachmentStore.transferDraftAttachmentsToSent(
                    for: agentID,
                    draftAttachments: snapshot.draft.imageAttachments,
                    sentAt: stamp
                )
            } catch {
                guard try await attachmentsAreAlreadySent(
                    snapshot.draft.imageAttachments,
                    for: agentID,
                    in: attachmentStore
                ) else {
                    throw error
                }
            }
        }
        snapshot.state = .confirmed
        try persistSubmissionSnapshot(snapshot, for: agentID)
        try removeSubmissionSnapshot(for: agentID)
        clearVisibleDraft(for: agentID, clearThrough: max(stamp, snapshot.draft.updatedAt))
        return true
    }

    /// Compatibility shim for existing text-only UI. New prompt-capable callers
    /// must use begin/restore/confirm above so pre-start failures can recover.
    public func resolveSendIntent(for agentID: AgentID, accepted: Bool, sentAt: Date? = nil) async {
        guard accepted else { return }
        do {
            guard try await beginSubmission(for: agentID, submittedAt: sentAt ?? clock.now()) else { return }
            _ = try await confirmSubmissionStarted(for: agentID, sentAt: sentAt)
        } catch {
            warn("AgentComposerDraftStore.resolveSendIntent: preserving recoverable submission for agent \(agentID.rawValue)")
        }
    }

    private func clearVisibleDraft(for agentID: AgentID, clearThrough: Date) {
        clearedThrough[agentID] = clearThrough
        scheduledWrites.removeValue(forKey: agentID)?.cancel()
        pending.removeValue(forKey: agentID)
        let url = layout.draftFile(for: agentID)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try removeItem(url) }
            catch { warn("AgentComposerDraftStore.clear: could not remove draft") }
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
        try writeSubmissionSnapshotFile(snapshot, file)
    }

    private func loadSubmissionSnapshot(for agentID: AgentID) throws -> AgentComposerSubmissionSnapshot? {
        let file = layout.submissionRecoveryFile(for: agentID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try writer.read(at: file)
        } catch {
            // AtomicWriter's noValidBackup(path:) and decoder context are local
            // storage details; recovery callers receive only this opaque category.
            throw AgentComposerDraftStoreError.storageReadFailed("submission recovery unavailable")
        }
    }

    private func attachmentsAreAlreadySent(
        _ attachments: [AgentComposerDraftImageAttachment],
        for agentID: AgentID,
        in attachmentStore: AgentComposerAttachmentStore
    ) async throws -> Bool {
        for attachment in attachments {
            guard let manifest = try await attachmentStore.manifest(for: attachment.attachmentID),
                  manifest.ownership.state == .sent,
                  manifest.ownership.agentID == agentID else {
                return false
            }
        }
        return true
    }

    private func removeSubmissionSnapshot(for agentID: AgentID) throws {
        let file = layout.submissionRecoveryFile(for: agentID)
        if FileManager.default.fileExists(atPath: file.path) {
            try removeItem(file)
            try Self.fsyncDirectory(file.deletingLastPathComponent())
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
}
