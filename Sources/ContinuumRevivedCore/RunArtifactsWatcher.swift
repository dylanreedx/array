import Foundation

public struct RunArtifactsWatcherConfig: Equatable, Sendable {
    public var debounceInterval: TimeInterval
    public var maxReadsPerSecond: Int
    public var pollInterval: TimeInterval

    public init(debounceInterval: TimeInterval = 0.5, maxReadsPerSecond: Int = 4, pollInterval: TimeInterval = 0.25) {
        self.debounceInterval = debounceInterval
        self.maxReadsPerSecond = max(1, maxReadsPerSecond)
        self.pollInterval = pollInterval
    }
}

public struct RunArtifactsWatcherUpdate: Equatable, Sendable {
    public var snapshots: [String: RunArtifactsSnapshot]
    public var readCount: Int

    public init(snapshots: [String: RunArtifactsSnapshot], readCount: Int) {
        self.snapshots = snapshots
        self.readCount = readCount
    }
}

public final class RunArtifactsWatcher: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable (RunArtifactsWatcherUpdate) -> Void

    private let rootURL: URL
    private let fileManager: FileManager
    private let config: RunArtifactsWatcherConfig
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()
    private var timer: DispatchSourceTimer?
    private var handler: UpdateHandler?
    private var lastSignatures: [String: String] = [:]
    private var dirtyRunIds: Set<String> = []
    private var firstDirtyAt: Date?
    private var readWindowStartedAt: Date?
    private var readsInWindow = 0

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        config: RunArtifactsWatcherConfig = RunArtifactsWatcherConfig(),
        queue: DispatchQueue = DispatchQueue(label: "continuum.run-artifacts-watcher")
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.config = config
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: queueToken)
    }

    deinit {
        stop()
    }

    public func start(onUpdate: @escaping UpdateHandler) {
        queue.async {
            self.timer?.cancel()
            self.handler = onUpdate
            self.scan(now: Date())
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = max(0.05, self.config.pollInterval)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.scan(now: Date()) }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        let work = {
            self.timer?.cancel()
            self.timer = nil
            self.handler = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    public func scanForTesting(now: Date = Date()) -> RunArtifactsWatcherUpdate? {
        queue.sync { scan(now: now) }
    }

    @discardableResult
    private func scan(now: Date) -> RunArtifactsWatcherUpdate? {
        let current = currentRunSignatures()
        if lastSignatures.isEmpty {
            lastSignatures = current
            if !current.isEmpty {
                dirtyRunIds.formUnion(current.keys)
                firstDirtyAt = firstDirtyAt ?? now
            }
        } else {
            for (runId, signature) in current where lastSignatures[runId] != signature {
                dirtyRunIds.insert(runId)
                firstDirtyAt = firstDirtyAt ?? now
            }
            lastSignatures = current
        }
        guard let firstDirtyAt, now.timeIntervalSince(firstDirtyAt) >= config.debounceInterval else { return nil }
        resetReadWindowIfNeeded(now: now)
        let remaining = max(0, config.maxReadsPerSecond - readsInWindow)
        guard remaining > 0 else { return nil }
        let idsToRead = Array(dirtyRunIds.sorted().prefix(remaining))
        guard !idsToRead.isEmpty else { return nil }
        var snapshots: [String: RunArtifactsSnapshot] = [:]
        for id in idsToRead {
            dirtyRunIds.remove(id)
            readsInWindow += 1
            snapshots[id] = RunArtifactsReader.read(runDirectory: rootURL.appendingPathComponent(id, isDirectory: true), fileManager: fileManager)
        }
        if dirtyRunIds.isEmpty { self.firstDirtyAt = nil } else { self.firstDirtyAt = now }
        let update = RunArtifactsWatcherUpdate(snapshots: snapshots, readCount: readsInWindow)
        handler?(update)
        return update
    }

    private func resetReadWindowIfNeeded(now: Date) {
        guard let started = readWindowStartedAt else {
            readWindowStartedAt = now
            readsInWindow = 0
            return
        }
        if now.timeIntervalSince(started) >= 1.0 {
            readWindowStartedAt = now
            readsInWindow = 0
        }
    }

    private func currentRunSignatures() -> [String: String] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [:] }
        var signatures: [String: String] = [:]
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            signatures[child.lastPathComponent] = directorySignature(child)
        }
        return signatures
    }

    private func directorySignature(_ directory: URL) -> String {
        var parts: [String] = []
        let directoryAttributes = (try? fileManager.attributesOfItem(atPath: directory.path)) ?? [:]
        parts.append(attributeSignature(".", directoryAttributes))
        for name in ["run.json", "events.jsonl", "final.md"] {
            let url = directory.appendingPathComponent(name)
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            parts.append(attributeSignature(name, attributes))
        }
        return parts.joined(separator: "|")
    }

    private func attributeSignature(_ name: String, _ attributes: [FileAttributeKey: Any]) -> String {
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        return "\(name):\(modified):\(size)"
    }
}
