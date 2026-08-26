import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/03-transcript-rehydration.md (transcript rehydration, pi path).
//
// Pure parse of pi's session `.jsonl` → replayable transcript steps, plus a
// macOS-gated locate/read. This is NOT the `pi --mode json` stream shape
// `PiEventTranslator` consumes — only the `session` line overlaps — so it needs
// its own decoder.
//
// Line shapes captured live from a real
// `~/.pi/agent/sessions/<slug>/<ts>_<sessionId>.jsonl` (2026-08-09):
//   {"type":"message","message":{"role":"user","content":[{"type":"text","text":..}]}}
//   {"type":"message","message":{"role":"assistant","content":[
//       {"type":"thinking","thinking":..},{"type":"text","text":..},
//       {"type":"toolCall","id":..,"name":..,"arguments":{..}}]}}
//   {"type":"message","message":{"role":"toolResult","toolCallId":..,"toolName":..,
//       "isError":Bool,"content":[{"type":"text","text":..},{"type":"image",..}]}}
// The `session`/`model_change`/`thinking_level_change`/`custom_message` lines
// carry no replayable transcript content and are skipped.
//
// B6.3 — `compaction` lines are NOT skipped: pi never rewrites or truncates
// the session file at compaction (`dist/core/session-manager.js`'s
// `appendCompaction`/`_appendEntry` are strictly append-only — verified
// against the installed `@earendil-works/pi-coding-agent` package), so every
// `message` line before and after a compaction survives regardless of what
// this reader does with the `compaction` line itself. What used to be lost
// was only the BOUNDARY marker; it now surfaces as the same compaction item
// kind `ClaudeEventTranslator` gives claude's `compact_boundary`, carrying
// the one real field pi's persisted entry has (`tokensBefore`) — never the
// `summary` prose (a model-authored recap, out of scope for I5's tool-detail
// whitelisting), and never a fabricated post-compaction size or
// manual/automatic flag: pi's entry has neither.
public enum PiSessionTranscriptReader {
    /// Pure: normalized pi session lines → the bounded, replayable transcript.
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

            // B6.3 — pi never rewrites or truncates the session file at
            // compaction (verified against `dist/core/session-manager.js`'s
            // `appendCompaction`/`_appendEntry`: strictly append-only). The
            // pre-compaction `message` lines that follow in this same loop are
            // therefore never lost; this just surfaces the boundary itself,
            // from the one real field the persisted entry carries.
            // `tokensBefore` is what `appendCompaction` writes; there is no
            // persisted post-compaction size (the runtime estimates one only
            // in memory) and no manual/automatic flag (`fromHook` means "an
            // extension supplied the summary", not "triggered automatically").
            if type == "compaction" {
                out.append(NormalizedTranscriptMessage(
                    role: .compaction,
                    countsAsMessage: false,
                    compactionTokensBefore: intValue(object["tokensBefore"])))
                continue
            }

            guard type == "message",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }

            switch role {
            case "user":
                let text = joinedText(message["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(NormalizedTranscriptMessage(role: .userPrompt, text: text))
                }
            case "assistant":
                appendAssistant(message["content"], into: &out)
            case "toolResult":
                guard let toolCallId = message["toolCallId"] as? String else { continue }
                let isError = (message["isError"] as? Bool) ?? false
                out.append(NormalizedTranscriptMessage(
                    role: .toolResult, toolCallId: toolCallId, toolFailed: isError))
            default:
                continue
            }
        }
        return out
    }

    private static func appendAssistant(_ content: Any?, into out: inout [NormalizedTranscriptMessage]) {
        guard let parts = content as? [[String: Any]] else { return }
        var reasoning = ""
        var text = ""
        var toolCalls: [NormalizedTranscriptMessage.ToolCall] = []
        for part in parts {
            switch part["type"] as? String {
            case "thinking":
                if let value = part["thinking"] as? String { reasoning += value }
            case "text":
                if let value = part["text"] as? String { text += value }
            case "toolCall":
                if let id = part["id"] as? String, let name = part["name"] as? String {
                    toolCalls.append(.init(id: id, name: name))
                }
            default:
                // image and any other part type carry no replayable text.
                continue
            }
        }
        guard !reasoning.isEmpty || !text.isEmpty || !toolCalls.isEmpty else { return }
        out.append(NormalizedTranscriptMessage(
            role: .assistant, text: text, reasoning: reasoning, toolCalls: toolCalls))
    }

    /// Joins the `text` parts of a pi content array (dropping thinking/toolCall/
    /// image), for user messages.
    private static func joinedText(_ content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else {
            return (content as? String) ?? ""
        }
        return parts.reduce(into: "") { accumulator, part in
            if (part["type"] as? String) == "text", let value = part["text"] as? String {
                accumulator += value
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as Double where value.isFinite:
            return Int(value)
        default:
            return nil
        }
    }

    /// pi's session-dir slug: the cwd's path components joined by `-`, wrapped
    /// in `--…--`. Dots are PRESERVED (unlike claude's `encodeCwd`). Verified
    /// live: `/Users/dylan/Documents/personal/Array` →
    /// `--Users-dylan-Documents-personal-Array--`.
    public static func slug(forCwd cwd: String) -> String {
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return "--" + components.joined(separator: "-") + "--"
    }
}

#if os(macOS)

extension PiSessionTranscriptReader {
    /// Locates the session file inside `~/.pi/agent/sessions`. The filename has
    /// an ISO-timestamp prefix, so the match is `*_<sessionId>.jsonl` in the
    /// slug dir. If the slug dir is absent or holds no match, falls back to
    /// scanning every session subdir — the session id (`array-agent-<uuid>`) is
    /// globally unique, so a scan is sound and de-risks the slug encoding.
    public static func locateSessionFile(homeURL: URL, cwd: String, sessionId: String) -> URL? {
        let sessionsRoot = homeURL.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        let suffix = "_\(sessionId).jsonl"

        let slugDir = sessionsRoot.appendingPathComponent(slug(forCwd: cwd), isDirectory: true)
        if let match = mostRecentMatch(in: slugDir, suffix: suffix) {
            return match
        }

        // Fallback: the session id is unique, so scan the other slug dirs.
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil) else { return nil }
        var best: URL?
        for dir in subdirs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let match = mostRecentMatch(in: dir, suffix: suffix) {
                if best == nil || match.lastPathComponent > best!.lastPathComponent { best = match }
            }
        }
        return best
    }

    /// The lexically-latest `*<suffix>` file in `directory` (the ISO-timestamp
    /// prefix sorts chronologically), or nil.
    private static func mostRecentMatch(in directory: URL, suffix: String) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .max { $0.lastPathComponent < $1.lastPathComponent }
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
