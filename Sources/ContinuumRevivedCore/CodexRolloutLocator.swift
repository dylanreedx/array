import Foundation

/// Shared enumeration and metadata decoding for Codex rollout files. State
/// observation locates by cwd/time; transcript restoration locates by the
/// persisted thread id. Both operations use this one filesystem substrate.
struct CodexRolloutLocator {
    struct SessionMeta: Equatable {
        var id: String?
        var cwd: String
        var timestamp: Date
    }

    var sessionsRoot: URL
    var archivedSessionsRoot: URL?

    /// Finds one rollout belonging to `threadId`. Active files take precedence
    /// over archived copies, because archiving may leave the same rollout in
    /// both trees briefly. Multiple matches within either tier fail closed.
    func locate(threadId: String) -> URL? {
        guard !threadId.isEmpty else { return nil }
        let active = rolloutFiles(in: sessionsRoot).filter {
            readSessionMeta(from: $0)?.id == threadId
        }
        if active.count == 1 { return active[0] }
        if active.count > 1 { return nil }

        guard let archivedSessionsRoot else { return nil }
        let archived = rolloutFiles(in: archivedSessionsRoot).filter {
            readSessionMeta(from: $0)?.id == threadId
        }
        return archived.count == 1 ? archived[0] : nil
    }

    func rolloutFiles() -> [URL] {
        rolloutFiles(in: sessionsRoot)
    }

    func rolloutFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return [] }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { lhs, rhs in
            lhs.mtime == rhs.mtime ? lhs.url.path < rhs.url.path : lhs.mtime > rhs.mtime
        }.map(\.url)
    }

    func readSessionMeta(from url: URL) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let line = handle.codexReadLine(maxBytes: 64 * 1024) else { return nil }
        try? handle.close()
        guard let object = Self.jsonObject(from: line),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let timestampRaw = payload["timestamp"] as? String ?? object["timestamp"] as? String,
              let timestamp = Self.parseISO8601(timestampRaw) else { return nil }
        return SessionMeta(id: payload["id"] as? String, cwd: cwd, timestamp: timestamp)
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension FileHandle {
    func codexReadLine(maxBytes: Int) -> String? {
        var data = Data()
        while data.count < maxBytes {
            let chunk = try? read(upToCount: 1)
            guard let chunk, !chunk.isEmpty else { break }
            if chunk.first == UInt8(ascii: "\n") { break }
            data.append(chunk)
        }
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }
}
