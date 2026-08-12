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
        let active = matches(of: threadId, in: sessionsRoot)
        if active.count == 1 { return active[0] }
        if active.count > 1 { return nil }

        guard let archivedSessionsRoot else { return nil }
        let archived = matches(of: threadId, in: archivedSessionsRoot)
        return archived.count == 1 ? archived[0] : nil
    }

    /// Codex names a rollout after the session id it carries, so a filename
    /// filter usually cuts a corpus of hundreds of files down to one before any
    /// of them is opened — and the id is still confirmed from the file's own
    /// `session_meta`, so a coincidental name cannot win. A duplicate arises
    /// from copying (archiving), which carries the name along, so the
    /// fail-closed ambiguity rule still sees both copies. When nothing matches
    /// by name the full scan runs, which is what fixtures with arbitrary names
    /// rely on.
    private func matches(of threadId: String, in root: URL) -> [URL] {
        let files = rolloutFiles(in: root)
        let named = files.filter { $0.lastPathComponent.contains(threadId) }
        let confirmed = named.filter { readSessionMeta(from: $0)?.id == threadId }
        if !confirmed.isEmpty { return confirmed }
        return files.filter { readSessionMeta(from: $0)?.id == threadId }
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
        guard let line = Self.firstLine(of: url, maxBytes: 64 * 1024) else { return nil }
        guard let object = Self.jsonObject(from: line),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let timestampRaw = payload["timestamp"] as? String ?? object["timestamp"] as? String,
              let timestamp = Self.parseISO8601(timestampRaw) else { return nil }
        return SessionMeta(id: payload["id"] as? String, cwd: cwd, timestamp: timestamp)
    }

    /// The first newline-terminated line, read in ONE bounded chunk. A rollout's
    /// `session_meta` line runs ~18 KB and a real corpus is hundreds of files,
    /// so reading it a byte at a time cost ~15.5 million syscalls per scan and
    /// pinned the app at 97% CPU for 90 seconds inside rehydration
    /// (`Array_2026-08-11-142854.cpu_resource.diag`). Budgeted by the scan-cost
    /// section of `ContinuumRevivedCoreChecks`'s rehydration dispatch checks.
    static func firstLine(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        let line = Data(data.prefix { $0 != UInt8(ascii: "\n") })
        return line.isEmpty ? nil : String(data: line, encoding: .utf8)
    }

    /// Every line of a small line-delimited file, read whole. Same syscall
    /// reason as `firstLine(of:maxBytes:)`; callers that walk a file top to
    /// bottom must not re-open a byte-at-a-time loop to do it.
    static func lines(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // At the cap the tail line is probably cut mid-JSON; drop it rather than
        // hand a caller a line that decodes to something wrong.
        if data.count >= maxBytes, !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        return lines
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
