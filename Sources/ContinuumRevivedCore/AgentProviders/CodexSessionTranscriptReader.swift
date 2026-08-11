import Foundation

// Plan: .plans/09-codex-transcript-rehydration.md.
//
// Codex persists a richer rollout than the JSON emitted by `codex exec --json`.
// This reader intentionally chooses event_msg user/agent messages as the one
// canonical visible-message source and ignores mirrored response_item/message
// rows, preventing duplicate cards. Restored bodies remain display-only at the
// ManagedTranscriptRehydrator/AgentSupervisor boundary.
public enum CodexSessionTranscriptReader {
    public static func parse(
        lines: [String],
        threadId: String,
        truncated: Bool = false,
        limits: RehydrationLimits = RehydrationLimits()
    ) -> RehydratedTranscript {
        ManagedTranscriptRehydrator.assemble(
            normalize(lines: lines), threadId: threadId, truncated: truncated, limits: limits)
    }

    static func normalize(lines: [String]) -> [NormalizedTranscriptMessage] {
        var out: [NormalizedTranscriptMessage] = []
        for line in lines {
            guard let object = ManagedTranscriptRehydrator.jsonObject(line),
                  let envelope = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            switch (envelope, type) {
            case ("event_msg", "user_message"):
                if let text = cleanText(payload["message"] ?? payload["text"]) {
                    out.append(.init(role: .userPrompt, text: text))
                }
            case ("event_msg", "agent_message"):
                if let text = cleanText(payload["message"] ?? payload["text"]) {
                    out.append(.init(role: .assistant, text: text))
                }
            case ("response_item", "reasoning"):
                if let summary = reasoningSummary(payload["summary"]) {
                    out.append(.init(role: .assistant, reasoning: summary, countsAsMessage: false))
                }
            case ("response_item", "function_call"),
                 ("response_item", "custom_tool_call"):
                guard let id = payload["call_id"] as? String ?? payload["id"] as? String,
                      let name = payload["name"] as? String, !name.isEmpty else { continue }
                out.append(.init(
                    role: .assistant,
                    toolCalls: [.init(id: id, name: name)],
                    countsAsMessage: false))
            case ("response_item", "function_call_output"),
                 ("response_item", "custom_tool_call_output"):
                guard let id = payload["call_id"] as? String ?? payload["id"] as? String else { continue }
                out.append(.init(role: .toolResult, toolCallId: id, toolFailed: toolFailed(payload)))
            default:
                // response_item/message mirrors event_msg/*_message; telemetry,
                // task markers, context and encrypted reasoning are not cards.
                continue
            }
        }
        return out
    }

    private static func cleanText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func reasoningSummary(_ value: Any?) -> String? {
        let parts: [String]
        if let text = value as? String {
            parts = [text]
        } else if let blocks = value as? [[String: Any]] {
            parts = blocks.compactMap { cleanText($0["text"] ?? $0["summary_text"]) }
        } else {
            return nil
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func toolFailed(_ payload: [String: Any]) -> Bool {
        if let isError = payload["is_error"] as? Bool { return isError }
        if let success = payload["success"] as? Bool { return !success }
        if let status = payload["status"] as? String {
            return ["failed", "error", "cancelled"].contains(status.lowercased())
        }
        return false
    }
}

#if os(macOS)

extension CodexSessionTranscriptReader {
    public static func locateRollout(codexHomeURL: URL, threadId: String) -> URL? {
        CodexRolloutLocator(
            sessionsRoot: codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            archivedSessionsRoot: codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ).locate(threadId: threadId)
    }

    static func read(
        sessionFileURL url: URL, threadId: String, limits: RehydrationLimits
    ) -> RehydratedTranscript? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (lines, truncated) = ManagedTranscriptRehydrator.readTailLines(at: url, maxBytes: limits.maxBytes)
        guard !lines.isEmpty else { return nil }
        let transcript = parse(lines: lines, threadId: threadId, truncated: truncated, limits: limits)
        return transcript.restoredMessageCount > 0 ? transcript : nil
    }
}

#endif
