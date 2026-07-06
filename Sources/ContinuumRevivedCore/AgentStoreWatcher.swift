import Darwin
import Foundation

public final class AgentStoreWatcher: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var debounceInterval: TimeInterval
        public var maxReadsPerSecond: Int

        public init(debounceInterval: TimeInterval = 0.25, maxReadsPerSecond: Int = 10) {
            self.debounceInterval = max(0.0, debounceInterval)
            self.maxReadsPerSecond = max(1, maxReadsPerSecond)
        }
    }

    public typealias ChangeHandler = @Sendable (_ tileId: UUID, _ changedURL: URL) -> Void

    private let config: Config
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var tileByURL: [URL: UUID] = [:]
    private var handlerByURL: [URL: ChangeHandler] = [:]
    private var dirtyURLsByTile: [UUID: Set<URL>] = [:]
    private var firstDirtyAtByTile: [UUID: Date] = [:]
    private var readWindowStartedAtByTile: [UUID: Date] = [:]
    private var readsInWindowByTile: [UUID: Int] = [:]

    public init(
        config: Config = Config(),
        queue: DispatchQueue = DispatchQueue(label: "continuum.agent-store-watcher", qos: .utility)
    ) {
        self.config = config
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: queueToken)
    }

    deinit {
        stop()
    }

    public func watch(url: URL, tileId: UUID, onChange: @escaping ChangeHandler) {
        let work = {
            self.unwatchOnQueue(url: url)
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: self.queue
            )
            source.setEventHandler { [weak self] in
                self?.fileDidChange(url: url, tileId: tileId)
            }
            source.setCancelHandler { close(fd) }
            self.sources[url] = source
            self.tileByURL[url] = tileId
            self.handlerByURL[url] = onChange
            source.resume()
        }
        performOnQueue(work)
    }

    public func unwatch(url: URL) {
        performOnQueue {
            self.unwatchOnQueue(url: url)
        }
    }

    public func unwatchAll(for tileId: UUID) {
        performOnQueue {
            let urls = self.tileByURL.compactMap { url, owner in owner == tileId ? url : nil }
            for url in urls {
                self.unwatchOnQueue(url: url)
            }
            self.dirtyURLsByTile[tileId] = nil
            self.firstDirtyAtByTile[tileId] = nil
            self.readWindowStartedAtByTile[tileId] = nil
            self.readsInWindowByTile[tileId] = nil
        }
    }

    public func stop() {
        performOnQueue {
            for source in self.sources.values {
                source.cancel()
            }
            self.sources.removeAll()
            self.tileByURL.removeAll()
            self.handlerByURL.removeAll()
            self.dirtyURLsByTile.removeAll()
            self.firstDirtyAtByTile.removeAll()
            self.readWindowStartedAtByTile.removeAll()
            self.readsInWindowByTile.removeAll()
        }
    }

    public func activeWatchCount(for tileId: UUID) -> Int {
        valueOnQueue {
            self.tileByURL.values.filter { $0 == tileId }.count
        }
    }

    public var activeWatchCount: Int {
        valueOnQueue { self.sources.count }
    }

    private func fileDidChange(url: URL, tileId: UUID) {
        guard sources[url] != nil, tileByURL[url] == tileId else { return }
        dirtyURLsByTile[tileId, default: []].insert(url)
        if firstDirtyAtByTile[tileId] == nil {
            firstDirtyAtByTile[tileId] = Date()
        }
        queue.asyncAfter(deadline: .now() + config.debounceInterval) { [weak self] in
            self?.flush(tileId: tileId)
        }
    }

    private func flush(tileId: UUID) {
        guard let firstDirtyAt = firstDirtyAtByTile[tileId],
              Date().timeIntervalSince(firstDirtyAt) >= config.debounceInterval,
              let dirtyURLs = dirtyURLsByTile[tileId],
              !dirtyURLs.isEmpty
        else { return }
        resetReadWindowIfNeeded(tileId: tileId, now: Date())
        let readsInWindow = readsInWindowByTile[tileId] ?? 0
        guard readsInWindow < config.maxReadsPerSecond else { return }

        let liveURLs = dirtyURLs.filter { sources[$0] != nil && tileByURL[$0] == tileId }
        dirtyURLsByTile[tileId] = nil
        firstDirtyAtByTile[tileId] = nil
        guard let changedURL = liveURLs.sorted(by: { $0.path < $1.path }).first,
              let handler = handlerByURL[changedURL]
        else { return }
        readsInWindowByTile[tileId] = readsInWindow + 1
        handler(tileId, changedURL)
    }

    private func resetReadWindowIfNeeded(tileId: UUID, now: Date) {
        guard let started = readWindowStartedAtByTile[tileId] else {
            readWindowStartedAtByTile[tileId] = now
            readsInWindowByTile[tileId] = 0
            return
        }
        if now.timeIntervalSince(started) >= 1.0 {
            readWindowStartedAtByTile[tileId] = now
            readsInWindowByTile[tileId] = 0
        }
    }

    private func unwatchOnQueue(url: URL) {
        guard let source = sources.removeValue(forKey: url) else {
            tileByURL.removeValue(forKey: url)
            handlerByURL.removeValue(forKey: url)
            return
        }
        let tileId = tileByURL.removeValue(forKey: url)
        handlerByURL.removeValue(forKey: url)
        source.cancel()
        if let tileId {
            dirtyURLsByTile[tileId]?.remove(url)
            if dirtyURLsByTile[tileId]?.isEmpty == true {
                dirtyURLsByTile[tileId] = nil
                firstDirtyAtByTile[tileId] = nil
            }
        }
    }

    private func performOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func valueOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            return work()
        }
        return queue.sync(execute: work)
    }
}
