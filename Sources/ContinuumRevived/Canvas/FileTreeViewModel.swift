import Foundation
import ContinuumRevivedCore

/// Latest-wins mailbox between the detached scanner and the main actor.
///
/// `FileTreeScanner` emits a GROWING FULL snapshot every 512 processed nodes, and
/// the view model used to hop each one onto the main actor with its own
/// `Task { @MainActor }`. Every accepted snapshot rebuilds `FileTreeOutlineModel`
/// and drives `NSOutlineView.reloadData` plus a collapse/expansion/selection
/// restore, so a 100k-path root queued ~195 unbounded main-actor tasks, each
/// carrying a full copy of the nodes so far, each doing a full outline reload —
/// and 194 of those reloads drew a tree that was already superseded before the
/// user could read it.
///
/// A snapshot is a complete picture, never a delta, so an older one has no value
/// once a newer one exists: this keeps exactly one pending snapshot and schedules
/// at most one drain at a time. The final snapshot is always applied, because a
/// drain clears `pending` and `isDrainScheduled` together under the lock — an
/// offer that arrives after that always schedules a fresh drain.
///
/// `--file-tree-snapshot-coalescing-check` owns the bound.
private final class FileTreeSnapshotInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: FileTreeSnapshot?
    private var isDrainScheduled = false
    private var offered = 0
    private var applied = 0
    private var scheduled = 0

    /// Returns true when the caller must schedule a drain.
    func offer(_ snapshot: FileTreeSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        offered += 1
        pending = snapshot
        if isDrainScheduled { return false }
        isDrainScheduled = true
        scheduled += 1
        return true
    }

    func take() -> FileTreeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = pending
        pending = nil
        isDrainScheduled = false
        if snapshot != nil { applied += 1 }
        return snapshot
    }

    var counts: (offered: Int, applied: Int, scheduled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (offered, applied, scheduled)
    }
}

@MainActor
public final class FileTreeViewModel {
    public private(set) var currentTask: Task<Void, Never>?
    public private(set) var scanGeneration = 0
    public private(set) var latestSnapshot: FileTreeSnapshot?
    public private(set) var lastError: Error?
    public var onSnapshotChange: ((FileTreeSnapshot) -> Void)?
    public var onError: ((Error) -> Void)?

    private let scanner: FileTreeScanner
    private var inbox = FileTreeSnapshotInbox()

    /// QA (WS3): how many snapshots the scanner produced, and how many of those
    /// actually reached the main actor and reloaded the outline. The gap is the
    /// coalescing; the second number is the one that must stay bounded.
    public var qaSnapshotsOffered: Int { inbox.counts.offered }
    public var qaSnapshotsApplied: Int { inbox.counts.applied }
    /// QA (WS3): main-actor drain tasks the mailbox asked for. The pending slot
    /// alone already bounds how many snapshots get APPLIED — a later offer
    /// overwrites an unread one — so `qaSnapshotsApplied` stays small even with
    /// the one-drain-at-a-time flag removed. This counter is the only thing that
    /// witnesses the flag, and the flag is what stops a 100k-path scan queueing
    /// ~195 unbounded main-actor tasks, each holding a full copy of the nodes.
    public var qaDrainsScheduled: Int { inbox.counts.scheduled }
    private let gitStatusProvider: @Sendable (URL) -> [String: FileTreeGitStatus]

    public init(
        scanner: FileTreeScanner = FileTreeScanner(),
        gitStatusProvider: @escaping @Sendable (URL) -> [String: FileTreeGitStatus] = {
            FileTreeGitStatusProbe().statuses(root: $0)
        }
    ) {
        self.scanner = scanner
        self.gitStatusProvider = gitStatusProvider
    }

    deinit {
        currentTask?.cancel()
    }

    public func start(
        rootPath: String,
        ignoreList: Set<String>,
        gitBadgeMode: FileTreeGitBadgeMode = .off
    ) {
        currentTask?.cancel()
        scanGeneration += 1
        latestSnapshot = nil
        lastError = nil
        // A fresh mailbox per scan: a snapshot still pending from the previous
        // root must never be drained into this one, and the counters are
        // per-scan by construction rather than by a caller remembering to reset.
        inbox = FileTreeSnapshotInbox()
        let inbox = inbox
        let generation = scanGeneration
        let scanner = scanner
        let gitStatusProvider = gitStatusProvider
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        currentTask = Task.detached(priority: .utility) {
            do {
                try await scanner.scan(root: root, ignoreList: ignoreList, cancellation: nil) { snapshot in
                    guard inbox.offer(snapshot) else { return }
                    Task { @MainActor [weak self] in
                        self?.drain(inbox, generation: generation)
                    }
                }
                if gitBadgeMode == .cheap {
                    let statuses = gitStatusProvider(root)
                    await MainActor.run { [weak self] in
                        self?.applyGitStatuses(statuses, generation: generation)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { [weak self] in
                    self?.apply(error, generation: generation)
                }
            }
        }
    }

    /// QA (WS3): offer a snapshot through the exact production mailbox the
    /// scanner callback uses, so a check can witness coalescing without a
    /// filesystem. Deliberately not a shortcut past `offer`/`drain`.
    public func qaOfferSnapshot(_ snapshot: FileTreeSnapshot) {
        let inbox = inbox
        let generation = scanGeneration
        guard inbox.offer(snapshot) else { return }
        Task { @MainActor [weak self] in
            self?.drain(inbox, generation: generation)
        }
    }

    private func drain(_ inbox: FileTreeSnapshotInbox, generation: Int) {
        guard let snapshot = inbox.take() else { return }
        apply(snapshot, generation: generation)
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        scanGeneration += 1
    }

    private func apply(_ snapshot: FileTreeSnapshot, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        latestSnapshot = snapshot
        lastError = nil
        onSnapshotChange?(snapshot)
    }

    private func apply(_ error: Error, generation: Int) {
        guard generation == scanGeneration else {
            return
        }

        lastError = error
        onError?(error)
    }

    private func applyGitStatuses(_ statuses: [String: FileTreeGitStatus], generation: Int) {
        guard generation == scanGeneration,
              !statuses.isEmpty,
              var snapshot = latestSnapshot else {
            return
        }

        snapshot.nodes = snapshot.nodes.map { node in
            var node = node
            node.gitStatus = statuses[node.relativePath]
            return node
        }
        latestSnapshot = snapshot
        onSnapshotChange?(snapshot)
    }
}
