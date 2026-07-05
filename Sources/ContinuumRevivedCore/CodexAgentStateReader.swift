import Foundation

public struct CodexReaderConfig: Equatable, Sendable {
    public var freshWorkingWindow: TimeInterval
    public var staleWindow: TimeInterval
    public var tailLineLimit: Int
    public var tailByteLimit: Int

    public init(
        freshWorkingWindow: TimeInterval = 30,
        staleWindow: TimeInterval = 900,
        tailLineLimit: Int = 50,
        tailByteLimit: Int = 200 * 1024
    ) {
        self.freshWorkingWindow = freshWorkingWindow
        self.staleWindow = staleWindow
        self.tailLineLimit = tailLineLimit
        self.tailByteLimit = tailByteLimit
    }
}

public struct CodexAgentStateReader: AgentStateReader {
    public let kind: AgentKind = .codex

    private let sessionsRoot: URL
    private let config: CodexReaderConfig

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        freshWorkingWindow: TimeInterval = 30,
        staleWindow: TimeInterval = 900,
        tailLineLimit: Int = 50,
        tailByteLimit: Int = 200 * 1024
    ) {
        self.sessionsRoot = sessionsRoot
        self.config = CodexReaderConfig(
            freshWorkingWindow: freshWorkingWindow,
            staleWindow: staleWindow,
            tailLineLimit: tailLineLimit,
            tailByteLimit: tailByteLimit
        )
    }

    public init(sessionsRoot: URL, config: CodexReaderConfig) {
        self.sessionsRoot = sessionsRoot
        self.config = config
    }

    public func detect(processName: String) -> Bool {
        processName == "codex" || processName == "node"
    }

    public func locate(pid: pid_t?, cwd: String, runId: String?) -> URL? {
        locate(cwd: cwd, paneStartedAt: .distantPast)
    }

    public func locate(cwd: String, paneStartedAt: Date) -> URL? {
        for rolloutURL in rolloutFiles() {
            guard let meta = readSessionMeta(from: rolloutURL) else { continue }
            guard meta.cwd == cwd else { continue }
            if paneStartedAt > Date.distantPast, meta.timestamp <= paneStartedAt {
                continue
            }
            return rolloutURL
        }
        return nil
    }

    public func read(storeURL: URL, asOf: Date) -> AgentSnapshot {
        read(at: storeURL, processAlive: true, now: asOf)
    }

    public func read(at rolloutURL: URL, processAlive: Bool, now: Date) -> AgentSnapshot {
        let meta = readSessionMeta(from: rolloutURL)
        let tail = readTailEvents(at: rolloutURL)
        let mtime = modificationDate(of: rolloutURL) ?? now
        let mtimeAge = max(0, now.timeIntervalSince(mtime))
        let derived = deriveStatus(from: tail, mtimeAge: mtimeAge, processAlive: processAlive)

        return AgentSnapshot(
            kind: .codex,
            status: derived.status,
            title: title(for: rolloutURL, cwd: meta?.cwd),
            mode: approvalPolicy(in: tail),
            asOf: mtime,
            detail: nil,
            evidence: AgentSnapshot.Evidence(
                source: "codex:rollout-tail",
                lastEventType: derived.lastEventType,
                mtimeAgeSeconds: mtimeAge
            )
        )
    }

    private func deriveStatus(
        from tail: [CodexRolloutEvent],
        mtimeAge: TimeInterval,
        processAlive: Bool
    ) -> (status: AgentStatus, lastEventType: String?) {
        let last = tail.last { $0.isMeaningful }
        let fresh = mtimeAge < config.freshWorkingWindow
        let status: AgentStatus

        if let last {
            switch (last.type, last.payloadType) {
            case ("response_item", "function_call"):
                status = hasPairedOutput(after: last.index, in: tail) ? .idle : (fresh ? .working : .idle)
            case ("response_item", "function_call_output"):
                status = fresh ? .working : .idle
            case ("event_msg", "task_started"):
                status = fresh ? .working : .idle
            case ("event_msg", "agent_message"), ("event_msg", "turn_aborted"):
                status = .idle
            default:
                status = .idle
            }
        } else {
            status = .idle
        }

        if mtimeAge >= config.staleWindow {
            return (processAlive ? .idle : .done, last?.payloadType)
        }
        return (status, last?.payloadType)
    }

    private func hasPairedOutput(after index: Int, in tail: [CodexRolloutEvent]) -> Bool {
        tail.contains { event in
            event.index > index &&
                event.type == "response_item" &&
                event.payloadType == "function_call_output"
        }
    }

    private func approvalPolicy(in tail: [CodexRolloutEvent]) -> String? {
        tail.last { $0.type == "turn_context" }?.approvalPolicy
    }

    private func title(for rolloutURL: URL, cwd: String?) -> String? {
        if let threadName = threadNameFromIndex(for: rolloutURL), !threadName.isEmpty {
            return threadName
        }
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
    }

    private func threadNameFromIndex(for rolloutURL: URL) -> String? {
        let indexURL = sessionsRoot.appendingPathComponent("session_index.jsonl", isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return nil }
        defer { try? handle.close() }

        var found: String?
        while let line = handle.readLine(maxBytes: 64 * 1024) {
            guard
                let object = Self.jsonObject(from: line),
                Self.indexRow(object, matches: rolloutURL),
                let threadName = object["thread_name"] as? String
                    ?? object["threadName"] as? String
                    ?? object["title"] as? String
            else {
                continue
            }
            found = threadName
        }
        return found
    }

    private static func indexRow(_ object: [String: Any], matches rolloutURL: URL) -> Bool {
        let path = object["rollout_path"] as? String
            ?? object["rolloutPath"] as? String
            ?? object["path"] as? String
            ?? object["url"] as? String
        guard let path else { return false }
        return canonicalPath(path) == canonicalPath(rolloutURL.path)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func rolloutFiles() -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [],
                errorHandler: nil
            )
        else {
            return []
        }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return files.sorted { lhs, rhs in
            if lhs.mtime != rhs.mtime {
                return lhs.mtime > rhs.mtime
            }
            return lhs.url.path < rhs.url.path
        }.map(\.url)
    }

    private func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func readSessionMeta(from url: URL) -> CodexSessionMeta? {
        guard
            let handle = try? FileHandle(forReadingFrom: url),
            let line = handle.readLine(maxBytes: 64 * 1024)
        else {
            return nil
        }
        try? handle.close()

        guard
            let object = Self.jsonObject(from: line),
            object["type"] as? String == "session_meta",
            let payload = object["payload"] as? [String: Any],
            let cwd = payload["cwd"] as? String,
            let timestampRaw = payload["timestamp"] as? String ?? object["timestamp"] as? String,
            let timestamp = Self.parseISO8601(timestampRaw)
        else {
            return nil
        }
        return CodexSessionMeta(cwd: cwd, timestamp: timestamp)
    }

    private func readTailEvents(at url: URL) -> [CodexRolloutEvent] {
        readTailLines(at: url).enumerated().compactMap { index, line in
            Self.decodeRolloutEvent(line: line, index: index)
        }
    }

    private func readTailLines(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let maxBytes = UInt64(max(0, config.tailByteLimit))
            let start = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }

            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if start > 0, !text.hasPrefix("\n"), !lines.isEmpty {
                lines.removeFirst()
            }
            if lines.count > config.tailLineLimit {
                lines = Array(lines.suffix(config.tailLineLimit))
            }
            return lines
        } catch {
            return []
        }
    }

    private static func decodeRolloutEvent(line: String, index: Int) -> CodexRolloutEvent? {
        guard
            let object = jsonObject(from: line),
            let type = object["type"] as? String
        else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        return CodexRolloutEvent(
            index: index,
            type: type,
            payloadType: payload?["type"] as? String,
            approvalPolicy: payload?["approval_policy"] as? String
                ?? payload?["approvalPolicy"] as? String
        )
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private struct CodexSessionMeta: Equatable {
    var cwd: String
    var timestamp: Date
}

private struct CodexRolloutEvent: Equatable {
    var index: Int
    var type: String
    var payloadType: String?
    var approvalPolicy: String?

    var isMeaningful: Bool {
        type == "response_item" || type == "event_msg"
    }
}

private extension FileHandle {
    func readLine(maxBytes: Int) -> String? {
        var data = Data()
        while data.count < maxBytes {
            let chunk = try? read(upToCount: 1)
            guard let chunk, !chunk.isEmpty else { break }
            if chunk.first == UInt8(ascii: "\n") {
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
