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
        limits: RehydrationLimits = RehydrationLimits(),
        now: () -> Date = Date.init
    ) -> RehydratedTranscript {
        ManagedTranscriptRehydrator.assemble(
            normalize(lines: lines), threadId: threadId, truncated: truncated,
            limits: limits, now: now)
    }

    static func normalize(lines: [String]) -> [NormalizedTranscriptMessage] {
        var out: [NormalizedTranscriptMessage] = []
        // When the last tool call began: a command's made files were born after it.
        var lastCallTimestamp: Date?
        // The files the last `apply_patch` call named, so the same change's
        // completed item is not restored a second time.
        var lastPatchNames: [String] = []
        for line in lines {
            guard let object = ManagedTranscriptRehydrator.jsonObject(line),
                  let envelope = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            let firstOutput = out.count
            let timestamp = ManagedTranscriptRehydrator.timestamp(object["timestamp"])
            defer {
                for index in firstOutput..<out.count { out[index].timestamp = timestamp }
            }

            switch (envelope, type) {
            case ("response_item", "context_compaction"),
                 ("response_item", "compaction"):
                guard let id = payload["id"] as? String else { continue }
                out.append(.init(
                    role: .compaction,
                    countsAsMessage: false,
                    compactionBoundaryID: id,
                    // Rollout persistence does not retain whether this boundary
                    // came from a manual request or provider policy.
                    compactionTrigger: .unknown("persisted"),
                    compactionProvider: "codex"))
            case ("event_msg", "user_message"):
                if let text = cleanText(payload["message"] ?? payload["text"]) {
                    out.append(.init(role: .userPrompt, text: text))
                }
            case ("event_msg", "agent_message"):
                if let text = cleanText(payload["message"] ?? payload["text"]) {
                    out.append(.init(role: .assistant, text: text))
                }
            // Codex 0.159+ writes what was said as completed items instead of
            // user_message/agent_message; a rollout never carries both.
            // Codex 0.159+ runs patches and commands inside its `exec` tool, so
            // the rollout's only record of a file change, or of a command that
            // made files, is the completed item itself.
            case ("event_msg", "item_completed")
                where ((payload["item"] as? [String: Any])?["type"] as? String) == "FileChange":
                guard let item = payload["item"] as? [String: Any],
                      let id = item["id"] as? String else { continue }
                let changes = fileChanges(item["changes"])
                guard !changes.isEmpty else { continue }
                let names = changes.map(\.change.path)
                if names == lastPatchNames { lastPatchNames = []; continue }
                let paths = changes.map(\.path).filter { ($0 as NSString).isAbsolutePath }
                out.append(.init(
                    role: .assistant,
                    toolCalls: [.init(
                        id: id, name: "apply_patch", fileChanges: changes.map(\.change),
                        absolutePath: paths.first, affectedPaths: paths)],
                    countsAsMessage: false))
                out.append(.init(role: .toolResult, toolCallId: id,
                                 toolFailed: ["failed", "declined"].contains((item["status"] as? String)?.lowercased() ?? "")))
            case ("event_msg", "item_completed")
                where ((payload["item"] as? [String: Any])?["type"] as? String) == "CommandExecution":
                guard let item = payload["item"] as? [String: Any],
                      let id = item["id"] as? String,
                      let command = CodexAppServerEventTranslator.rawCommand(item["command"]),
                      let startedAt = lastCallTimestamp, let endedAt = timestamp else { continue }
                out += NormalizedTranscriptMessage.madeFiles(
                    shellItemID: id, toolName: "Shell",
                    made: AgentShellMadeFiles.detect(
                        command: command,
                        workingDirectory: CodexAppServerEventTranslator.commandDirectory(item["cwd"]),
                        startedAt: startedAt, endedAt: endedAt))
            case ("event_msg", "item_completed"):
                guard let item = payload["item"] as? [String: Any],
                      let role: NormalizedTranscriptMessage.Role = switch item["type"] as? String {
                          case "UserMessage": .userPrompt
                          case "AgentMessage": .assistant
                          default: nil
                      } else { continue }
                let blocks = item["content"] as? [[String: Any]] ?? []
                if let text = cleanText(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")) {
                    out.append(.init(role: role, text: text))
                }
            case ("response_item", "reasoning"):
                if let summary = reasoningSummary(payload["summary"]) {
                    out.append(.init(role: .assistant, reasoning: summary, countsAsMessage: false))
                }
            case ("response_item", "function_call"),
                 ("response_item", "custom_tool_call"):
                guard let id = payload["call_id"] as? String ?? payload["id"] as? String,
                      let name = payload["name"] as? String, !name.isEmpty else { continue }
                lastCallTimestamp = timestamp ?? lastCallTimestamp
                // TR-01 — `arguments` stays unrestored (it is a command body for
                // `exec_command`, and that is the sensitive payload). The one
                // exception is the patch itself: `apply_patch` states which
                // files changed and how, and captured live it arrives as
                // `input` on a `custom_tool_call`. Only the resulting paths,
                // actions and COUNTS are carried, on the host-local channel —
                // never the patch text, and never into the document.
                let envelope = name.lowercased() == "apply_patch"
                    ? ((payload["input"] as? String) ?? (payload["arguments"] as? String) ?? "")
                    : ""
                let changes = envelope.isEmpty
                    ? []
                    : CodexFileChangeReader.fileChanges(applyPatchEnvelope: envelope)
                if !changes.isEmpty { lastPatchNames = changes.map(\.path) }
                out.append(.init(
                    role: .assistant,
                    toolCalls: [.init(
                        id: id, name: name,
                        fileChanges: changes,
                        absolutePath: changes.isEmpty
                            ? nil
                            : CodexFileChangeReader.firstEnvelopePath(envelope))],
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

    /// A completed `FileChange` item's changes: the rollout keys them by path
    /// (`{path: {type, content | unified_diff}}`); app-server lists them.
    private static func fileChanges(_ value: Any?) -> [(path: String, change: AgentToolDetailObservation.FileChange)] {
        var listed: [[String: Any]] = []
        if let byPath = value as? [String: Any] {
            for (path, raw) in byPath.sorted(by: { $0.key < $1.key }) {
                var change = raw as? [String: Any] ?? [:]
                change["path"] = path
                listed.append(change)
            }
        } else if let list = value as? [[String: Any]] {
            listed = list
        }
        return listed.prefix(24).compactMap { change in
            guard let path = change["path"] as? String, !path.isEmpty else { return nil }
            var shaped = change
            if shaped["diff"] == nil { shaped["diff"] = change["unified_diff"] }
            guard var detail = CodexFileChangeReader.fileDetails(["changes": [shaped]]).first else { return nil }
            // An added file's content is all of it: its lines are its count.
            if detail.action == .add, detail.addedLines == nil, let content = change["content"] as? String {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
                    - (content.hasSuffix("\n") ? 1 : 0)
                detail = .init(action: .add, path: path, addedLines: UInt(max(0, lines)))
            }
            return (path, detail)
        }
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
