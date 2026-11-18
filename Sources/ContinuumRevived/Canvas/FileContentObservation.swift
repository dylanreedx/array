import Foundation
import Darwin

/// Shared vnode observation for file bodies. File and directory sources detect
/// in-place edits, atomic replacement, and missing-path restoration.
@MainActor
final class FileContentObservation {
    static let shared = FileContentObservation()
    struct Stamp: Equatable {
        let device: Int32?
        let inode: UInt64?
        let bytes: UInt64?
        let modifiedSeconds: Int?
        let modifiedNanoseconds: Int?
        let changedSeconds: Int?
        let changedNanoseconds: Int?
        let mode: UInt16?
        let exists: Bool
        // lstat describes the link itself; follow it too so edits to a linked
        // target are visible and its vnode is rearmed after replacement.
        let targetDevice: Int32?
        let targetInode: UInt64?
        let targetBytes: Int64?
        let targetModifiedSeconds: Int?
        let targetModifiedNanoseconds: Int?
        let targetChangedSeconds: Int?
        let targetChangedNanoseconds: Int?
        init(path: String) {
            // Capture ctime as well as mtime: a same-inode, same-size write can
            // restore its mtime while the change time still exposes new bytes.
            var state = stat()
            let found = path.withCString { Darwin.lstat($0, &state) } == 0
            device = found ? state.st_dev : nil
            inode = found ? state.st_ino : nil
            bytes = found && state.st_size >= 0 ? UInt64(state.st_size) : nil
            modifiedSeconds = found ? state.st_mtimespec.tv_sec : nil
            modifiedNanoseconds = found ? state.st_mtimespec.tv_nsec : nil
            changedSeconds = found ? state.st_ctimespec.tv_sec : nil
            changedNanoseconds = found ? state.st_ctimespec.tv_nsec : nil
            mode = found ? state.st_mode : nil
            exists = found
            var target = stat()
            let targetFound = path.withCString { fstatat(AT_FDCWD, $0, &target, 0) } == 0
            targetDevice = targetFound ? target.st_dev : nil
            targetInode = targetFound ? target.st_ino : nil
            targetBytes = targetFound ? target.st_size : nil
            targetModifiedSeconds = targetFound ? target.st_mtimespec.tv_sec : nil
            targetModifiedNanoseconds = targetFound ? target.st_mtimespec.tv_nsec : nil
            targetChangedSeconds = targetFound ? target.st_ctimespec.tv_sec : nil
            targetChangedNanoseconds = targetFound ? target.st_ctimespec.tv_nsec : nil
        }
    }
    private struct Entry {
        let path: String
        var stamp: Stamp
        let changed: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    private final class Watch {
        let id = UUID()
        let stamp: Stamp
        let broad: Bool
        let source: DispatchSourceFileSystemObject
        init(stamp: Stamp, broad: Bool, source: DispatchSourceFileSystemObject) {
            self.stamp = stamp
            self.broad = broad
            self.source = source
        }
    }
    private var watches: [String: Watch] = [:]
    private var subscribersByPath: [String: Set<UUID>] = [:]
    private(set) var qaEventCount = 0
    private var qaSuppressedCallbackPaths: Set<String> = []
    private var qaSuppressedCallbackCounts: [String: Int] = [:]
    var qaObserverCount: Int { entries.count }
    var qaObserverPaths: [String] { entries.values.map(\.path) }
    private static func qaPathKey(_ path: String) -> String {
        path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
    }
    func qaSetCallbacksSuppressed(forPath path: String, suppressed: Bool) {
        let key = Self.qaPathKey(path)
        if suppressed {
            qaSuppressedCallbackPaths.insert(key)
            qaSuppressedCallbackCounts[key] = 0
        } else {
            qaSuppressedCallbackPaths.remove(key)
            qaSuppressedCallbackCounts[key] = nil
        }
    }
    func qaSuppressedCallbackCount(forPath path: String) -> Int {
        qaSuppressedCallbackCounts[Self.qaPathKey(path), default: 0]
    }
    func observe(path: String, stamp: Stamp, changed: @escaping () -> Void) -> UUID {
        let id = UUID(); entries[id] = Entry(path: path, stamp: stamp, changed: changed)
        // Cover the interval between the caller's snapshot and source installation.
        reconcileAndPoll([id])
        return id
    }
    func remove(_ id: UUID?) {
        if let id { entries.removeValue(forKey: id) }
        reconcileAndPoll([])
    }

    private func reconcileAndPoll(_ initial: Set<UUID>) {
        var affected = initial
        // Reconcile and rescan after installing sources. If rearming one source
        // retired a queued event for another, its subscribers are included too.
        for _ in 0..<4 {
            affected.formUnion(reconcileWatches())
            guard !affected.isEmpty else { return }
            poll(ids: affected)
            affected = []
        }
    }

    private func reconcileWatches() -> Set<UUID> {
        var subscribers: [String: Set<UUID>] = [:]
        var broadPaths: Set<String> = []
        let previousSubscribers = subscribersByPath
        var affected: Set<UUID> = []
        for (id, entry) in entries {
            var url = URL(fileURLWithPath: entry.path).standardizedFileURL
            var visited: Set<String> = []
            // A dangling link still reveals its target, so creation in a
            // different directory can rearm the chain. Stop cycles safely.
            while visited.insert(url.path).inserted {
                subscribers[url.path, default: []].insert(id)
                broadPaths.insert(url.path)
                var parent = url.deletingLastPathComponent()
                var nearest = true
                while true {
                    subscribers[parent.path, default: []].insert(id)
                    if nearest && Stamp(path: parent.path).exists {
                        broadPaths.insert(parent.path)
                        nearest = false
                    }
                    let next = parent.deletingLastPathComponent()
                    if next.path == parent.path { break }
                    parent = next
                }
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
                url = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                       : url.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
            }
        }
        subscribersByPath = subscribers
        for path in Array(watches.keys) {
            let current = Stamp(path: path)
            guard let watch = watches[path] else { continue }
            if subscribers[path] == nil || !current.exists || watch.broad != broadPaths.contains(path) ||
                current.device != watch.stamp.device || current.inode != watch.stamp.inode ||
                current.targetDevice != watch.stamp.targetDevice || current.targetInode != watch.stamp.targetInode {
                affected.formUnion(previousSubscribers[path] ?? [])
                affected.formUnion(subscribers[path] ?? [])
                watches.removeValue(forKey: path)?.source.cancel()
            }
        }
        // Arm ancestors before descendants so an atomic replacement racing
        // installation leaves an event on an already-armed directory source.
        let orderedPaths = subscribers.keys.sorted { URL(fileURLWithPath: $0).pathComponents.count < URL(fileURLWithPath: $1).pathComponents.count }
        for path in orderedPaths where watches[path] == nil {
            // The pathname can be atomically replaced between lstat and open.
            // Arm only when the opened vnode still matches the pathname.
            var opened: (fd: Int32, stamp: Stamp)?
            for _ in 0..<3 {
                let stamp = Stamp(path: path)
                guard stamp.exists else { break }
                let fd = open(path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { break }
                var descriptor = stat()
                var target = stat()
                let current = Stamp(path: path)
                let same = fstat(fd, &descriptor) == 0 &&
                    path.withCString { fstatat(AT_FDCWD, $0, &target, 0) } == 0 &&
                    descriptor.st_dev == target.st_dev && descriptor.st_ino == target.st_ino &&
                    current.device == stamp.device && current.inode == stamp.inode &&
                    current.targetDevice == stamp.targetDevice && current.targetInode == stamp.targetInode
                if same { opened = (fd, stamp); break }
                close(fd)
            }
            guard let opened else { continue }
            let fd = opened.fd
            let broad = broadPaths.contains(path)
            let mask: DispatchSource.FileSystemEvent = broad
                ? [.write, .delete, .rename, .attrib, .extend, .link, .revoke]
                : [.delete, .rename, .revoke]
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: mask, queue: .main)
            let watch = Watch(stamp: opened.stamp, broad: broad, source: source)
            let id = watch.id
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.qaEventCount += 1
                    guard self.watches[path]?.id == id else { return }
                    let affected = self.subscribersByPath[path] ?? []
                    self.reconcileAndPoll(affected)
                }
            }
            watches[path] = watch
            affected.formUnion(subscribers[path] ?? [])
            source.resume()
        }
        return affected
    }

    /// Reconcile snapshots; retained for deterministic rich-content checks.
    func poll() { poll(ids: Set(entries.keys)) }

    private func poll(ids: Set<UUID>) {
        var stamps: [String: Stamp] = [:]
        var callbacks: [() -> Void] = []
        for id in ids {
            guard var entry = entries[id] else { continue }
            let current = stamps[entry.path] ?? Stamp(path: entry.path)
            stamps[entry.path] = current
            if current != entry.stamp {
                entry.stamp = current; entries[id] = entry
                let key = Self.qaPathKey(entry.path)
                if qaSuppressedCallbackPaths.contains(key) { qaSuppressedCallbackCounts[key, default: 0] += 1 }
                else { callbacks.append(entry.changed) }
            }
        }
        for callback in callbacks { callback() }
    }
}
