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
        limits: RehydrationLimits = RehydrationLimits(),
        now: () -> Date = Date.init
    ) -> RehydratedTranscript {
        ManagedTranscriptRehydrator.assemble(
            normalize(lines: lines), threadId: threadId, truncated: truncated, limits: limits,
            now: now)
    }

    static func normalize(lines: [String]) -> [NormalizedTranscriptMessage] {
        var out: [NormalizedTranscriptMessage] = []
        for line in lines {
            guard let object = ManagedTranscriptRehydrator.jsonObject(line),
                  let type = object["type"] as? String else { continue }
            // Sub-agent frames are skipped everywhere.
            if (object["isSidechain"] as? Bool) == true { continue }

            let firstOutput = out.count
            let timestamp = ManagedTranscriptRehydrator.timestamp(object["timestamp"])
            defer {
                for index in firstOutput..<out.count { out[index].timestamp = timestamp }
            }

            switch type {
            case "system" where (object["subtype"] as? String) == "compact_boundary":
                // The live stream says `compact_metadata.pre_tokens`; the session
                // FILE says `compactMetadata.preTokens` (claude 2.1.x, captured
                // 2026-10-13). Reading only the first dropped every restored count.
                let metadata = object["compact_metadata"] as? [String: Any]
                    ?? object["compactMetadata"] as? [String: Any] ?? [:]
                out.append(NormalizedTranscriptMessage(
                    role: .compaction,
                    countsAsMessage: false,
                    compactionTokensBefore: intValue(metadata["pre_tokens"] ?? metadata["preTokens"]),
                    compactionTokensAfter: intValue(metadata["post_tokens"] ?? metadata["postTokens"]),
                    compactionBoundaryID: object["uuid"] as? String,
                    compactionTrigger: AgentCompactionTrigger(providerValue: metadata["trigger"] as? String),
                    compactionProvider: "claude"))
            case "user":
                // Another Claude session's message, delivered by Claude Code's
                // peer channel. It is logged `isMeta`, wrapped in a sentence and
                // a reminder addressed to the model; the
                // `<cross-session-message>` inside is what the sender wrote, and
                // it restores as a message from that session. A peer line with
                // no such element carries nothing readable and stays hidden.
                if ((object["origin"] as? [String: Any])?["kind"] as? String) == "peer" {
                    if let element = AgentMessageEnvelope.crossSessionElement(in: userText(object["message"])) {
                        out.append(NormalizedTranscriptMessage(role: .userPrompt, text: element))
                    }
                    continue
                }
                // Claude's own bookkeeping, never something the user said: the
                // hidden `isMeta` context (a local command's caveat, an expanded
                // skill body) and the post-compaction summary it feeds the model.
                // Both render as raw user bubbles if imported.
                if (object["isMeta"] as? Bool) == true
                    || (object["isCompactSummary"] as? Bool) == true
                    || (object["isVisibleInTranscriptOnly"] as? Bool) == true { continue }
                // A background job's completion notice is logged as a user
                // message too, without `isMeta`; `origin` says who sent it.
                if ((object["origin"] as? [String: Any])?["kind"] as? String) == "task-notification" { continue }
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

    /// A user record's text, whether its content is a String or text blocks.
    private static func userText(_ message: Any?) -> String {
        let content = (message as? [String: Any])?["content"]
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? [])
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
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
            if let visible = visiblePromptText(text) {
                out.append(NormalizedTranscriptMessage(role: .userPrompt, text: visible))
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
        if let visible = visiblePromptText(promptText) {
            out.append(NormalizedTranscriptMessage(role: .userPrompt, text: visible))
        }
    }

    /// What the user actually typed, from a `user` record's text — or nil when
    /// the record is claude's local-command bookkeeping. A slash command run
    /// in claude itself is logged as `<command-name>/x</command-name>
    /// <command-message>…</command-message><command-args>…</command-args>`
    /// and its output as `<local-command-stdout>`/`<local-command-stderr>`.
    /// The command reads back as the user typed it (`/x args`); its output is
    /// not a prompt. `/compact` is dropped outright: its `compact_boundary`
    /// record already restores as the boundary row, exactly as the live
    /// compaction does. A `<system-reminder>` the Claude app puts in front of
    /// what you typed is context for the model, not part of the prompt.
    /// Messages between sessions (`<cross-session-message>`, a background
    /// note, `<side-sessions-event>`) pass through as written: the projection's
    /// `AgentMessageEnvelope` draws them as from their sender.
    static func visiblePromptText(_ text: String) -> String? {
        let trimmed = text
            .replacingOccurrences(
                of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<local-command-") || trimmed.hasPrefix("<task-notification>") { return nil }
        // `! cmd` in the TUI logs the command and its output as user messages.
        // Like a slash command, the command reads back as typed and the
        // output is not a prompt.
        if trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") { return nil }
        if trimmed.hasPrefix("<bash-input>"), let close = trimmed.range(of: "</bash-input>") {
            let command = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "<bash-input>".count)..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : "! \(command)"
        }
        guard trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") else {
            return trimmed
        }
        func tag(_ name: String) -> String? {
            guard let open = trimmed.range(of: "<\(name)>"),
                  let close = trimmed.range(of: "</\(name)>", range: open.upperBound..<trimmed.endIndex)
            else { return nil }
            return String(trimmed[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var command = tag("command-name"), !command.isEmpty else { return nil }
        if !command.hasPrefix("/") { command = "/" + command }
        if command == "/compact" { return nil }
        let arguments = tag("command-args") ?? ""
        return arguments.isEmpty ? command : "\(command) \(arguments)"
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
                    let input = block["input"] as? [String: Any]
                    // TR-01 — the session file holds the SAME `input` the live
                    // stream carries, so a restored edit can be described
                    // exactly as a live one is: same extractor, same counting,
                    // same privacy boundary. Reading it here is what stopped
                    // "0 files · line counts unavailable" from being every
                    // restored card's verdict.
                    toolCalls.append(.init(
                        id: id, name: name,
                        detail: Self.toolDetail(from: input),
                        fileChanges: ClaudeEventTranslator.fileDetails(
                            toolName: name, input: input ?? [:]),
                        absolutePath: (input?["file_path"] as? String)
                            ?? (input?["notebook_path"] as? String)
                            ?? (input?["path"] as? String),
                        messageText: AgentToolDetailObservation.messageTextField(toolName: name, arguments: input ?? [:])?.value))
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
    /// `ClaudeAgentStateReader.encodeCwd` (every non-alphanumeric → `-`).
    public static func sessionFileURL(homeURL: URL, cwd: String, sessionId: String) -> URL {
        homeURL
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeAgentStateReader.encodeCwd(cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
    }

    public static func read(
        sessionFileURL url: URL, threadId: String, limits: RehydrationLimits = RehydrationLimits()
    ) -> RehydratedTranscript? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (lines, truncated) = ManagedTranscriptRehydrator.readTailLines(at: url, maxBytes: limits.maxBytes)
        guard !lines.isEmpty else { return nil }
        return parse(lines: lines, threadId: threadId, truncated: truncated, limits: limits)
    }
}

#endif  // os(macOS)
