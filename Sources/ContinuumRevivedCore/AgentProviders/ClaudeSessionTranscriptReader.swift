import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/03-transcript-rehydration.md (transcript rehydration, claude path).
//
// Pure parse of claude's session `.jsonl` → replayable transcript steps, plus a
// macOS-gated locate/read. The session file is COMPLETE messages (not the deltas
// the live headless stream emits), so this reader normalizes each message and
// hands them to the shared assembler, which synthesizes the turnStarted →
// content/reasoning → item start/complete → turnCompleted shape the projection
// consumes.
//
// Line shapes captured live from a real `~/.claude/projects/<enc>/<id>.jsonl`
// (claude 2.1.226, 2026-08-09):
//   user      {"type":"user","isSidechain":false,"message":{"role":"user",
//               "content": <String> | [{"type":"tool_result","tool_use_id":..,
//               "is_error":Bool,...}, {"type":"text","text":..}]}}
//   assistant {"type":"assistant","isSidechain":false,"message":{"role":"assistant",
//               "content":[{"type":"thinking","thinking":..},{"type":"text","text":..},
//               {"type":"tool_use","id":..,"name":..,"input":..}]}}
// Everything else (ai-title, agent-name, mode, permission-mode, system,
// attachment, last-prompt, queue-operation, file-history-*) carries no transcript
// content and is skipped. `isSidechain:true` frames are sub-agent chatter: the
// top-level Task tool item already represents them, so they are skipped whole
// (matching `ClaudeEventTranslator`).
public enum ClaudeSessionTranscriptReader {
    /// Pure: normalized claude session lines → the bounded, replayable transcript.
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
                  let type = object["type"] as? String else { continue }
            // Sub-agent frames are skipped everywhere.
            if (object["isSidechain"] as? Bool) == true { continue }

            switch type {
            case "system" where (object["subtype"] as? String) == "compact_boundary":
                let metadata = object["compact_metadata"] as? [String: Any] ?? [:]
                out.append(NormalizedTranscriptMessage(
                    role: .compaction,
                    countsAsMessage: false,
                    compactionTokensBefore: intValue(metadata["pre_tokens"]),
                    compactionTokensAfter: intValue(metadata["post_tokens"]),
                    compactionBoundaryID: object["uuid"] as? String,
                    compactionTrigger: AgentCompactionTrigger(providerValue: metadata["trigger"] as? String),
                    compactionProvider: "claude"))
            case "user":
                guard let message = object["message"] as? [String: Any] else { continue }
                appendUserMessage(message["content"], into: &out)
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                appendAssistantMessage(blocks, into: &out)
            default:
                continue
            }
        }
        return out
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// A `user` line is either a real prompt (content is a String, or text
    /// blocks) or the carrier for tool_result completions of the assistant's
    /// prior tool calls (content is a list of tool_result blocks).
    private static func appendUserMessage(_ content: Any?, into out: inout [NormalizedTranscriptMessage]) {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(NormalizedTranscriptMessage(role: .userPrompt, text: trimmed))
            }
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        var promptText = ""
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let toolUseId = block["tool_use_id"] as? String else { continue }
                let isError = (block["is_error"] as? Bool) ?? false
                out.append(NormalizedTranscriptMessage(
                    role: .toolResult, toolCallId: toolUseId, toolFailed: isError))
            case "text":
                if let text = block["text"] as? String { promptText += text }
            default:
                continue
            }
        }
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            out.append(NormalizedTranscriptMessage(role: .userPrompt, text: trimmed))
        }
    }

    private static func appendAssistantMessage(
        _ blocks: [[String: Any]], into out: inout [NormalizedTranscriptMessage]
    ) {
        var reasoning = ""
        var text = ""
        var toolCalls: [NormalizedTranscriptMessage.ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "thinking":
                if let value = block["thinking"] as? String { reasoning += value }
            case "text":
                if let value = block["text"] as? String { text += value }
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    // Rehydration is display-only local content (the user's own
                    // on-disk session, never re-synced — see ManagedTranscriptRehydrator's
                    // header), so unlike the live translator it MAY surface the
                    // command for context instead of a bare "Bash" card.
                    toolCalls.append(.init(
                        id: id, name: name,
                        detail: Self.toolDetail(from: block["input"] as? [String: Any])))
                }
            default:
                continue
            }
        }
        guard !reasoning.isEmpty || !text.isEmpty || !toolCalls.isEmpty else { return }
        out.append(NormalizedTranscriptMessage(
            role: .assistant, text: text, reasoning: reasoning, toolCalls: toolCalls))
    }

    /// A short, safe one-line detail for a tool card title: the command for
    /// Bash, else a description or a file/path/pattern. Control characters are
    /// stripped and the result is bounded so a card title never carries a wall
    /// of text or breaks layout.
    private static func toolDetail(from input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let candidate = ["command", "description", "file_path", "path", "pattern", "query"]
            .lazy.compactMap { input[$0] as? String }.first
        guard let candidate else { return nil }
        let oneLine = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > 140 ? String(oneLine.prefix(139)) + "…" : oneLine
    }
}

#if os(macOS)

extension ClaudeSessionTranscriptReader {
    /// `~/.claude/projects/<encodeCwd(cwd)>/<sessionId>.jsonl`. Reuses
    /// `ClaudeAgentStateReader.encodeCwd` (both `/` and `.` → `-`).
    public static func sessionFileURL(homeURL: URL, cwd: String, sessionId: String) -> URL {
        homeURL
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeAgentStateReader.encodeCwd(cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    static func read(
        sessionFileURL url: URL, threadId: String, limits: RehydrationLimits
    ) -> RehydratedTranscript? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (lines, truncated) = ManagedTranscriptRehydrator.readTailLines(at: url, maxBytes: limits.maxBytes)
        guard !lines.isEmpty else { return nil }
        return parse(lines: lines, threadId: threadId, truncated: truncated, limits: limits)
    }
}

#endif  // os(macOS)
