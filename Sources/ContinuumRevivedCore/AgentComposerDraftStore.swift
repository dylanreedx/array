import Foundation

/// Host-local composer state. Prompt text deliberately lives outside
/// `AgentRecord` and every sync model.
public struct AgentComposerDraft: Codable, Equatable, Sendable {
    public var text: String
    public var selection: Range<Int>
    public var updatedAt: Date

    public init(text: String, selection: Range<Int>, updatedAt: Date) {
        self.text = text
        self.selection = selection
        self.updatedAt = updatedAt
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

    public func draftFile(for agentID: AgentID) -> URL {
        draftsDirectory.appendingPathComponent("\(agentID.rawValue.uuidString).json", isDirectory: false)
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
        let newestEdit = newestSeen[agentID] ?? .distantPast
        clearedThrough[agentID] = max(Date(), newestEdit)
        scheduledWrites.removeValue(forKey: agentID)?.cancel()
        pending.removeValue(forKey: agentID)
        let url = layout.draftFile(for: agentID)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { warn("AgentComposerDraftStore.clear: could not remove \(url.path): \(error)") }
        }
    }

    /// The send boundary: a rejected intent is intentionally a no-op.
    public func resolveSendIntent(for agentID: AgentID, accepted: Bool) {
        guard accepted else { return }
        clear(for: agentID)
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
