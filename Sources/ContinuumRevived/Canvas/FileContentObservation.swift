import Foundation

/// One observation clock for all read-only file bodies, coalesced by path.
/// Renderers never own polling timers and observation ends with the last host.
@MainActor
final class FileContentObservation {
    static let shared = FileContentObservation()
    struct Stamp: Equatable {
        let inode: UInt64?
        let bytes: UInt64?
        let modified: Date?
        let exists: Bool
        init(path: String) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            bytes = (attributes?[.size] as? NSNumber)?.uint64Value
            modified = attributes?[.modificationDate] as? Date
            exists = attributes != nil
        }
    }
    private struct Entry {
        let path: String
        var stamp: Stamp
        let changed: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    var qaObserverCount: Int { entries.count }
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
                entry.stamp = current; entries[id] = entry; callbacks.append(entry.changed)
            }
        }
        for callback in callbacks { callback() }
    }
}
