import Foundation

/// Where sharing and joining spend their time. Off unless
/// `CONTINUUM_SHARE_TIMELINE` names a file; then every mark and every relay
/// request is appended to it as one JSON line with a monotonic millisecond
/// timestamp, so a two-app walk can split share-to-link and
/// link-to-first-paint into phases.
public enum CollaborationTimeline {
    private static let path = ProcessInfo.processInfo.environment["CONTINUUM_SHARE_TIMELINE"].flatMap { $0.isEmpty ? nil : $0 }
    private static let lock = NSLock()
    public static var isEnabled: Bool { path != nil }

    public static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    /// One phase boundary, e.g. `join.tile-installed`.
    public static func mark(_ name: String, _ detail: String = "") {
        guard path != nil else { return }
        write(["t": now(), "mark": name, "detail": detail])
    }

    /// One relay request, from send to response.
    static func request(_ method: String, _ path: String, started: Double, status: Int?) {
        guard Self.path != nil else { return }
        let ended = now()
        write(["t": ended, "request": "\(method) \(redact(path))", "started": started, "ms": ended - started, "status": status ?? -1])
    }

    /// Area and object ids are noise in a timeline; keep the route's shape.
    private static func redact(_ path: String) -> String {
        path.split(separator: "/").map { $0.count == 36 && $0.contains("-") ? "{id}" : String($0) }.joined(separator: "/")
    }

    private static func write(_ object: [String: Any]) {
        guard let path, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
    }
}
