import Foundation
import Darwin

/// One observation clock for all read-only file bodies, coalesced by path.
/// Renderers never own polling timers and observation ends with the last host.
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
        }
    }
    private struct Entry {
        let path: String
        var stamp: Stamp
        let changed: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    private var qaSuppressedCallbackPaths: Set<String> = []
    private var qaSuppressedCallbackCounts: [String: Int] = [:]
    var qaObserverCount: Int { entries.count }
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
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        return id
    }
    func remove(_ id: UUID?) {
        if let id { entries.removeValue(forKey: id) }
        if entries.isEmpty { timer?.invalidate(); timer = nil }
    }
    func poll() {
        var stamps: [String: Stamp] = [:]
        var callbacks: [() -> Void] = []
        for (id, var entry) in entries {
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
