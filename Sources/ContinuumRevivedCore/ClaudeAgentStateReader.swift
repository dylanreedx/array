import ContinuumRevivedAgentUI
import Foundation

public struct ClaudeReaderConfig: Equatable, Sendable {
    public var freshWorkingWindow: TimeInterval
    public var idleWindow: TimeInterval
    public var staleWindow: TimeInterval
    public var tailBytes: Int

    public init(
        freshWorkingWindow: TimeInterval = 30,
        idleWindow: TimeInterval = 120,
        staleWindow: TimeInterval = 900,
        tailBytes: Int = 8192
    ) {
        self.freshWorkingWindow = freshWorkingWindow
        self.idleWindow = idleWindow
        self.staleWindow = staleWindow
        self.tailBytes = tailBytes
    }
}

public struct ClaudeReaderEvent: Equatable, Sendable {
    public var type: String
    public var stopReason: String?
    public var hasToolUseResult: Bool
    public var aiTitle: String?
    public var permissionMode: String?
    public var timestamp: String?

    public init(
        type: String,
        stopReason: String? = nil,
        hasToolUseResult: Bool = false,
        aiTitle: String? = nil,
        permissionMode: String? = nil,
        timestamp: String? = nil
    ) {
        self.type = type
        self.stopReason = stopReason
        self.hasToolUseResult = hasToolUseResult
        self.aiTitle = aiTitle
        self.permissionMode = permissionMode
        self.timestamp = timestamp
    }
}

public struct ClaudeAgentStateReader: AgentStateReader {
    public let kind: AgentKind = .claude

    private let homeURL: URL
    private let now: @Sendable () -> Date
    private let config: ClaudeReaderConfig
    public static var defaultHomeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public init(
        homeURL: URL = Self.defaultHomeURL,
        now: @Sendable @escaping () -> Date = { Date() },
        config: ClaudeReaderConfig = ClaudeReaderConfig()
    ) {
        self.homeURL = homeURL
        self.now = now
        self.config = config
    }

    public func detect(processName: String) -> Bool {
        processName == "claude"
    }

    public func locate(pid: pid_t?, cwd: String, runId: String?) -> URL? {
        guard let pid else { return nil }
        let pidFile = homeURL
            .appendingPathComponent(".claude/sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: pidFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = object["sessionId"] as? String,
            let pidCwd = object["cwd"] as? String,
            !sessionId.isEmpty
        else {
            return nil
        }

        return homeURL
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(Self.encodeCwd(pidCwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    public func read(storeURL: URL, asOf: Date) -> AgentSnapshot {
        let events = readTailEvents(at: storeURL)
        let ageSeconds = max(0, now().timeIntervalSince(asOf))
        let status = deriveStatus(from: events, ageSeconds: ageSeconds)

        return AgentSnapshot(
            kind: .claude,
            status: status,
            title: extractTitle(from: events),
            mode: extractMode(from: events),
            asOf: asOf,
            detail: nil,
            evidence: AgentSnapshot.Evidence(
                source: "claude:jsonl-tail",
                lastEventType: lastMeaningfulType(from: events),
                mtimeAgeSeconds: ageSeconds
            )
        )
    }

    public static func encodeCwd(_ cwd: String) -> String {
        String(cwd.map { character in
            character == "/" || character == "." ? "-" : character
        })
    }

    public func deriveStatus(from events: [ClaudeReaderEvent], ageSeconds: TimeInterval) -> AgentStatus {
        guard ageSeconds <= config.staleWindow else { return .idle }
        guard let last = lastMeaningfulEvent(from: events) else { return .idle }

        if last.type == "assistant", last.stopReason == "tool_use" {
            return ageSeconds <= config.freshWorkingWindow ? .working : .idle
        }

        if last.type == "user", last.hasToolUseResult {
            return ageSeconds <= config.freshWorkingWindow ? .working : .idle
        }

        if last.type == "assistant", last.stopReason == "end_turn" {
            return .idle
        }

        return .idle
    }

    public func extractTitle(from events: [ClaudeReaderEvent]) -> String? {
        events.last(where: { $0.type == "ai-title" })?.aiTitle
    }

    public func extractMode(from events: [ClaudeReaderEvent]) -> String? {
        events.last(where: { $0.type == "permission-mode" })?.permissionMode
    }

    public func lastMeaningfulType(from events: [ClaudeReaderEvent]) -> String? {
        lastMeaningfulEvent(from: events)?.type
    }

    private func lastMeaningfulEvent(from events: [ClaudeReaderEvent]) -> ClaudeReaderEvent? {
        events.last { event in
            switch event.type {
            case "mode", "permission-mode", "ai-title":
                return false
            default:
                return true
            }
        }
    }

    private func readTailEvents(at url: URL) -> [ClaudeReaderEvent] {
        readTailLines(at: url).compactMap(Self.decodeEvent(line:))
    }

    private func readTailLines(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let maxBytes = UInt64(max(0, config.tailBytes))
        let start = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if start > 0, !text.hasPrefix("\n"), !lines.isEmpty {
                lines.removeFirst()
            }
            return lines
        } catch {
            return []
        }
    }

    private static func decodeEvent(line: String) -> ClaudeReaderEvent? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        let message = object["message"] as? [String: Any]
        let result = object["toolUseResult"] ?? message?["toolUseResult"]
        return ClaudeReaderEvent(
            type: type,
            stopReason: object["stop_reason"] as? String ?? object["stopReason"] as? String,
            hasToolUseResult: result != nil,
            aiTitle: object["aiTitle"] as? String ?? object["ai_title"] as? String,
            permissionMode: object["permissionMode"] as? String ?? object["permission_mode"] as? String,
            timestamp: object["timestamp"] as? String ?? object["ts"] as? String
        )
    }
}
