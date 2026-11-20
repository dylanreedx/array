import Foundation

#if os(macOS)

/// Reads Codex's host-local rollout log and projects only the normalized numeric
/// context facts Array needs. Raw rollout content never leaves this adapter.
///
/// macOS only, like `CodexAgentRunner`: this reads a codex CLI installation's
/// rollout tree under the user's home, and `homeDirectoryForCurrentUser` does not
/// exist on iOS. Core is shared with the iOS target, so an unguarded reference
/// here fails the iOS build — which is exactly how this was found. Every caller
/// (the runner, the supervisor, the codex backend checks) is already macOS-only.
public enum CodexRolloutTelemetry {
    public static let maximumReadBytes: UInt64 = 8 * 1024 * 1024

    /// Parses one rollout JSONL line. Only the exact
    /// `event_msg.payload.type == token_count` shape is accepted.
    public static func snapshot(
        from line: String,
        freshness: AgentContextWindowFreshness = .live,
        fallbackDate: @autoclosure () -> Date = Date()
    ) -> AgentContextWindowSnapshot? {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "event_msg",
              let payload = envelope["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let used = int(usage["total_tokens"]), used >= 0,
              let window = int(info["model_context_window"]), window > 0
        else { return nil }

        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheRead = int(usage["cached_input_tokens"])
        let cacheWrite = int(usage["cache_write_input_tokens"])
        let observedAt = (envelope["timestamp"] as? String).flatMap(parseTimestamp) ?? fallbackDate()
        return AgentContextWindowSnapshot(
            usedTokens: used,
            maxTokens: window,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalProcessedTokens: used,
            totalCostUsd: nil,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .codexRolloutTokenCount,
            freshness: freshness)
    }

    /// Resolves one rollout by full thread id. Filename filtering is followed by
    /// a session_meta id check; zero or multiple exact matches abstain.
    public static func rolloutURL(
        threadId: String,
        codexHome: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !threadId.isEmpty else { return nil }
        let home = codexHome ?? effectiveCodexHome()
        let roots = [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        var matches: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            rolloutEnumerations.increment()
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasSuffix("-\(threadId).jsonl"),
                      sessionId(in: url) == threadId
                else { continue }
                matches.append(url)
                if matches.count > 1 { return nil }
            }
        }
        return matches.first
    }

    /// A restore owns one immutable index; never cached across launches or turns.
    public struct RestoreIndex: Sendable {
        private var paths: [String: URL] = [:]
        public init(threadIds: Set<String>, codexHome: URL? = nil, fileManager: FileManager = .default) {
            guard !threadIds.isEmpty else { return }
            let home = codexHome ?? effectiveCodexHome()
            var ambiguous: Set<String> = []
            for name in ["sessions", "archived_sessions"] {
                let root = home.appendingPathComponent(name, isDirectory: true)
                guard fileManager.fileExists(atPath: root.path) else { continue }
                rolloutEnumerations.increment()
                guard let files = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in files {
                    guard url.pathExtension == "jsonl",
                          threadIds.contains(where: { url.lastPathComponent.hasSuffix("-\($0).jsonl") }),
                          let id = sessionId(in: url), !id.isEmpty, threadIds.contains(id),
                          url.lastPathComponent.hasSuffix("-\(id).jsonl") else { continue }
                    if paths[id] != nil { ambiguous.insert(id) }
                    else { paths[id] = url }
                }
            }
            for id in ambiguous { paths.removeValue(forKey: id) }
        }
        public func rolloutURL(threadId: String) -> URL? { paths[threadId] }
        public static var enumerationsForQA: Int { rolloutEnumerations.value }
    }

    public static func fileSize(of url: URL, fileManager: FileManager = .default) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    /// Returns the latest complete token_count line appended at or after the
    /// supplied byte offset. Reads are bounded and incomplete edge lines are
    /// discarded.
    public static func latestSnapshot(
        in url: URL,
        afterOffset offset: UInt64,
        freshness: AgentContextWindowFreshness = .live,
        maximumBytes: UInt64 = maximumReadBytes
    ) -> AgentContextWindowSnapshot? {
        guard let size = fileSize(of: url), size > offset,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        let boundedStart = size > maximumBytes ? size - maximumBytes : 0
        let start = max(offset, boundedStart)
        var discardFirst = false
        do {
            if start > 0 {
                try handle.seek(toOffset: start - 1)
                discardFirst = handle.readData(ofLength: 1).first != 0x0A
            }
            try handle.seek(toOffset: start)
        } catch { return nil }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        if legacyFullSplit {
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if discardFirst, !lines.isEmpty { lines.removeFirst() }
            if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
            linesExamined.add(lines.count)
            for bytes in lines.reversed() {
                guard let line = String(data: Data(bytes), encoding: .utf8) else { continue }
                if let result = snapshot(from: line, freshness: freshness) { return result }
            }
            return nil
        }
        return newestSnapshot(in: data, discardFirst: discardFirst, freshness: freshness)
    }

    /// `CONTINUUM_LEGACY_ROLLOUT_SCAN=1` restores the old scan, which split the
    /// whole read (up to 8 MB, byte by byte through `Data`) into lines before
    /// looking at the last one. Boot paid that once per Codex agent on the main
    /// thread. The RED arm of `--rollout-scan-check`.
    nonisolated(unsafe) public static var legacyFullSplit =
        ProcessInfo.processInfo.environment["CONTINUUM_LEGACY_ROLLOUT_SCAN"] != nil
    private static let linesExamined = QACounter()
    public static var linesExaminedForQA: Int { linesExamined.value }

    /// Walks complete lines newest first and only decodes one that names
    /// `token_count`: the same answer as parsing every line, without touching
    /// the thousands that cannot match.
    private static func newestSnapshot(
        in data: Data, discardFirst: Bool, freshness: AgentContextWindowFreshness
    ) -> AgentContextWindowSnapshot? {
        data.withUnsafeBytes { raw -> AgentContextWindowSnapshot? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            func lastNewline(before end: Int, notBefore low: Int) -> Int? {
                var i = end - 1
                while i >= low { if base[i] == 0x0A { return i }; i -= 1 }
                return nil
            }
            var low = 0
            if discardFirst {
                guard let first = (0..<bytes.count).first(where: { base[$0] == 0x0A }) else { return nil }
                low = first + 1
            }
            var end = bytes.count
            if base[end - 1] != 0x0A {
                // The last line is incomplete: never a candidate.
                guard let cut = lastNewline(before: end, notBefore: low) else { return nil }
                end = cut
            }
            let needle: [UInt8] = Array("token_count".utf8)
            while end > low {
                let newline = lastNewline(before: end, notBefore: low)
                let start = (newline ?? (low - 1)) + 1
                if end > start {
                    linesExamined.increment()
                    if memmem(base + start, end - start, needle, needle.count) != nil,
                       let line = String(
                        data: Data(bytes: base + start, count: end - start), encoding: .utf8),
                       let result = snapshot(from: line, freshness: freshness) { return result }
                }
                guard let newline else { break }
                end = newline
            }
            return nil
        }
    }

    public static func latestSnapshot(
        threadId: String,
        codexHome: URL? = nil,
        freshness: AgentContextWindowFreshness = .stale,
        fileManager: FileManager = .default
    ) -> AgentContextWindowSnapshot? {
        guard let url = rolloutURL(threadId: threadId, codexHome: codexHome, fileManager: fileManager)
        else { return nil }
        return latestSnapshot(in: url, afterOffset: 0, freshness: freshness)
    }

    /// Terminal stdout usage is accounting; rollout telemetry is occupancy.
    /// Keep completion/ready behind both so observers persist one coherent final
    /// state even when the rollout write lands after stdout's terminal line.
    public static func orderedFinalEvents(
        threadId: String,
        terminalEvents: [AgentRuntimeEvent],
        snapshot: AgentContextWindowSnapshot?
    ) -> [AgentRuntimeEvent] {
        let usage = terminalEvents.filter {
            if case .tokenUsageUpdated = $0 { return true }
            return false
        }
        let terminal = terminalEvents.filter {
            if case .tokenUsageUpdated = $0 { return false }
            return true
        }
        var result = usage
        if let snapshot { result.append(.contextWindowUpdated(threadId: threadId, snapshot: snapshot)) }
        result.append(contentsOf: terminal)
        return result
    }

    public static func effectiveCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static let rolloutEnumerations = QACounter()
    private static let metadataReads = QACounter()
    public static var metadataReadsForQA: Int { metadataReads.value }

    private static func sessionId(in url: URL) -> String? {
        metadataReads.increment()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        for bytes in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            return payload["id"] as? String
        }
        return nil
    }

    private static func int(_ raw: Any?) -> Int? {
        guard !(raw is Bool), let number = raw as? NSNumber else { return nil }
        // Parsing the decimal spelling avoids NSNumber's saturating/truncating
        // integer conversions: fractions, infinities, and overflow all abstain.
        return Int(number.stringValue)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

#endif  // os(macOS)
