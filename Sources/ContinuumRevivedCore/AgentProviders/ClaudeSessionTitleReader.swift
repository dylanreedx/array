import ContinuumRevivedAgentUI
import Foundation

// The claude CLI names its own conversations. It writes a model-authored title
// into the session `.jsonl` as a standalone line:
//
//   {"type":"ai-title","aiTitle":"Andable Zscaler connection investigation",
//    "sessionId":"35c834ed-…"}
//
// Present in HEADLESS sessions (`-p --output-format stream-json`) through
// claude 2.1.277. From 2.1.278 headless sessions no longer carry it (0 of ~1,900
// sessions since); interactive sessions still do. It stays the FIRST rung
// because it is free, and absence is ordinary: the supervisor then asks claude
// itself for a title (`AgentNameOneShot`).
//
// `ClaudeAgentStateReader` has decoded this field since the tmux observer
// shipped, but only for OBSERVED terminal sessions. A managed agent's session
// file is in the same store, under the same encoding, and nothing read it —
// so every managed claude tile was named by truncating a first prompt while a
// better title sat on disk, free, updated by the CLI as the work moved.
//
// Codex and pi have no equivalent. Codex's `set_thread_title` appears only
// inside Codex Desktop's injected app-context prose, never as a rollout event,
// and pi's session store carries no title field at all. Those two harnesses are
// titled by their own CLI's one-shot instead.
public enum ClaudeSessionTitleReader {
    /// How much of the session tail to scan. The title line is small, repeated,
    /// and rewritten as the conversation develops, so the newest one is near the
    /// end; this is a bound on work, not a correctness limit.
    public static let tailBytes = 512 * 1024

    /// Pure: session lines → the newest title claude gave this conversation.
    ///
    /// Last wins. claude re-emits the line when it revises the title, and the
    /// revision is the point — a conversation that turned into something else
    /// gets a title that says so.
    public static func title(inLines lines: [String]) -> String? {
        for line in lines.reversed() {
            // Substring test before JSON: a session file is overwhelmingly
            // assistant/user frames, and parsing every one of them to find a
            // handful of title lines is the kind of cost that gets a feature
            // switched off later.
            guard line.contains("\"ai-title\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "ai-title" else { continue }
            // Both spellings, matching `ClaudeAgentStateReader.decodeEvent`.
            let raw = object["aiTitle"] as? String ?? object["ai_title"] as? String
            guard let raw, let normalized = AgentName.normalizedLabel(raw) else { continue }
            return normalized
        }
        return nil
    }
}

#if os(macOS)

extension ClaudeSessionTitleReader {
    /// Read the newest title for one managed agent's conversation, or nil when
    /// the session file does not exist yet, carries no title line, or cannot be
    /// read. Every one of those is an ordinary state, not an error: a session
    /// may not have a title yet, and a headless one may never get one.
    public static func title(homeURL: URL, cwd: String, sessionId: String) -> String? {
        let url = ClaudeSessionTranscriptReader.sessionFileURL(
            homeURL: homeURL, cwd: cwd, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (lines, _) = ManagedTranscriptRehydrator.readTailLines(at: url, maxBytes: tailBytes)
        return title(inLines: lines)
    }
}

#endif  // os(macOS)
