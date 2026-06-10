import Foundation
import ContinuumRevivedCore

@MainActor
public final class FileTreeViewModel {
    public private(set) var currentTask: Task<Void, Never>?
    public private(set) var scanGeneration = 0
    public private(set) var latestSnapshot: FileTreeSnapshot?
    public private(set) var lastError: Error?
    public var onSnapshotChange: ((FileTreeSnapshot) -> Void)?
    public var onError: ((Error) -> Void)?

    private let scanner: FileTreeScanner
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
        let generation = scanGeneration
        let scanner = scanner
        let gitStatusProvider = gitStatusProvider
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        currentTask = Task.detached(priority: .utility) {
            do {
                try await scanner.scan(root: root, ignoreList: ignoreList, cancellation: nil) { snapshot in
                    Task { @MainActor [weak self] in
                        self?.apply(snapshot, generation: generation)
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
