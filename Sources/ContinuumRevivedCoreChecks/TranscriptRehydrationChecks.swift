import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// Plan: .plans/03-transcript-rehydration.md (transcript rehydration on resume).
//
// Pins the two provider session-file readers against fixtures whose shapes were
// captured live 2026-08-09 from a real `~/.claude/projects/<enc>/<id>.jsonl`
// (claude 2.1.226) and a real `~/.pi/agent/sessions/<slug>/<ts>_<id>.jsonl`.
// The readers restore message BODIES on purpose (rehydration is display-only —
// the I5 guard that these bodies never re-cross the sync boundary lives on the
// supervisor seam and is witnessed in `--agent-restore-check`). What is pinned
// here is the pure parse (line-in → replayable steps-out), the turn/tool
// synthesis, sub-agent skipping, the bounded-with-surfaced-drop behavior, and
// the file-existence backend dispatch (incl. the claude/pi tiebreak and pi's
// slug + timestamp-prefix glob).
func runTranscriptRehydrationChecks() {
    runTranscriptRehydrationSessionIdChecks()
    runClaudeSessionTranscriptParseChecks()
    runPiSessionTranscriptParseChecks()
    runCodexSessionTranscriptParseChecks()
    runTranscriptRehydrationBoundChecks()
    #if os(macOS)
    runTranscriptRehydrationDispatchChecks()
    #endif
    print("TranscriptRehydration checks passed: claude+codex+pi session .jsonl parse to replayable display-only steps, caps surfaced, exact Codex thread identity located, preferred backend dispatched")
}

private func stepsDescription(_ transcript: RehydratedTranscript) -> String {
    // A serialized form for the sub-agent-leak scan: encoded events plus the
    // user-prompt bodies.
    let eventsJSON = (try? JSONEncoder().encode(transcript.events)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let prompts = transcript.steps.compactMap { step -> String? in
        if case let .userPrompt(text) = step { return text } else { return nil }
    }.joined(separator: "\n")
    return eventsJSON + "\n" + prompts
}

private func runTranscriptRehydrationSessionIdChecks() {
    // The derived ids the readers locate by. Cross-checked against
    // AgentSupervisor's own derivation in `--agent-restore-check` so the two
    // cannot drift.
    let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    expect(ManagedTranscriptRehydrator.piSessionId(forAgentUUID: uuid) == "array-agent-11111111-2222-3333-4444-555555555555",
           "pi session id must be array-agent-<uuid>, got \(ManagedTranscriptRehydrator.piSessionId(forAgentUUID: uuid))")
    expect(ManagedTranscriptRehydrator.claudeSessionId(forAgentUUID: uuid) == "11111111-2222-3333-4444-555555555555",
           "claude session id must be the lowercased uuid, got \(ManagedTranscriptRehydrator.claudeSessionId(forAgentUUID: uuid))")

    // The pi slug, verified live.
    expect(PiSessionTranscriptReader.slug(forCwd: "/Users/dylan/Documents/personal/Array") == "--Users-dylan-Documents-personal-Array--",
           "pi slug drifted: \(PiSessionTranscriptReader.slug(forCwd: "/Users/dylan/Documents/personal/Array"))")
    // Dots are preserved (claude's encodeCwd would turn them to dashes).
    expect(PiSessionTranscriptReader.slug(forCwd: "/tmp/a.b/c") == "--tmp-a.b-c--",
           "pi slug must preserve dots: \(PiSessionTranscriptReader.slug(forCwd: "/tmp/a.b/c"))")
}

private func runClaudeSessionTranscriptParseChecks() {
    let threadId = "t-claude"
    // Real claude session shapes: a skip-type line, a string-content prompt, an
    // assistant with thinking+text+tool_use, a SUB-AGENT (isSidechain) frame
    // that must be skipped whole, a tool_result carrier user line, a second
    // assistant continuing the same turn with a failing edit, then a new prompt.
    let lines = [
        #"{"type":"ai-title","aiTitle":"skip me"}"#,
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"HELLO_PROMPT_ONE"}}"#,
        #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"REASON_ALPHA"},{"type":"text","text":"ANSWER_ALPHA"},{"type":"tool_use","id":"toolu_A","name":"Bash","input":{"command":"ls"}}]}}"#,
        #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"SIDECHAIN_SECRET"},{"type":"tool_use","id":"toolu_sub","name":"Bash","input":{}}]}}"#,
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_A","type":"tool_result","is_error":false,"content":"ls output"}]}}"#,
        #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_BETA"},{"type":"tool_use","id":"toolu_B","name":"Edit","input":{"file_path":"/x"}}]}}"#,
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_B","type":"tool_result","is_error":true,"content":"boom"}]}}"#,
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"HELLO_PROMPT_TWO"}}"#,
        #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_GAMMA"}]}}"#,
    ]
    let transcript = ClaudeSessionTranscriptReader.parse(lines: lines, threadId: threadId)

    let expected: [RehydratedTranscriptStep] = [
        .userPrompt("HELLO_PROMPT_ONE"),
        .event(.turnStarted(threadId: threadId, turnId: "rehydrated-t1")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .reasoning, delta: "REASON_ALPHA")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "ANSWER_ALPHA")),
        // The command rides the title so a rehydrated card reads "Bash · ls"
        // instead of an opaque "Bash" (display-only; rehydration never re-syncs).
        .event(.itemStarted(threadId: threadId, itemId: "toolu_A", kind: .commandExecution, title: "Bash · ls")),
        .event(.itemCompleted(threadId: threadId, itemId: "toolu_A", kind: .commandExecution, status: .completed)),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "ANSWER_BETA")),
        .event(.itemStarted(threadId: threadId, itemId: "toolu_B", kind: .fileChange, title: "Edit · /x")),
        .event(.itemCompleted(threadId: threadId, itemId: "toolu_B", kind: .fileChange, status: .failed)),
        .event(.turnCompleted(threadId: threadId, turnId: "rehydrated-t1", outcome: .completed, errorMessage: nil)),
        .userPrompt("HELLO_PROMPT_TWO"),
        .event(.turnStarted(threadId: threadId, turnId: "rehydrated-t2")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t2", streamKind: .assistant, delta: "ANSWER_GAMMA")),
        .event(.turnCompleted(threadId: threadId, turnId: "rehydrated-t2", outcome: .completed, errorMessage: nil)),
    ]
    expect(transcript.steps == expected,
           "ClaudeSessionTranscriptReader: steps drifted.\n  got: \(transcript.steps)\n  want: \(expected)")
    expect(transcript.restoredMessageCount == 5,
           "ClaudeSessionTranscriptReader: expected 5 restored messages (2 user + 3 assistant), got \(transcript.restoredMessageCount)")
    expect(transcript.omittedEarlier == false,
           "ClaudeSessionTranscriptReader: nothing was dropped, so omittedEarlier must be false")

    // Sub-agent frame skipped whole: neither its text nor its tool id survives.
    let serialized = stepsDescription(transcript)
    expect(!serialized.contains("SIDECHAIN_SECRET"), "ClaudeSessionTranscriptReader: sub-agent text crossed into the transcript")
    expect(!serialized.contains("toolu_sub"), "ClaudeSessionTranscriptReader: sub-agent tool id crossed into the transcript")

    // The boundary card the tile leads with.
    expect(transcript.boundaryNoticeText == "Previous session — 5 messages restored",
           "ClaudeSessionTranscriptReader: boundary notice drifted: \(transcript.boundaryNoticeText)")
}

private func runPiSessionTranscriptParseChecks() {
    let threadId = "t-pi"
    // Real pi session shapes: skip lines (session/model_change/compaction), a
    // user text message, an assistant with thinking+text+toolCall, a toolResult
    // matched by toolCallId.
    let lines = [
        #"{"type":"session","version":3,"id":"019fd9ce","timestamp":"2026-08-07T01:20:08.718Z","cwd":"/x"}"#,
        #"{"type":"model_change","provider":"openai-codex","modelId":"gpt-5.6-sol"}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"PI_PROMPT_ONE"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PI_REASON"},{"type":"text","text":"PI_ANSWER"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"/y"}}]}}"#,
        #"{"type":"message","message":{"role":"toolResult","toolCallId":"call_1","toolName":"read","isError":false,"content":[{"type":"text","text":"file body"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"PI_ANSWER_TWO"},{"type":"toolCall","id":"call_2","name":"write","arguments":{"file_path":"/z"}}]}}"#,
        #"{"type":"message","message":{"role":"toolResult","toolCallId":"call_2","toolName":"write","isError":true,"content":[{"type":"text","text":"denied"}]}}"#,
        #"{"type":"compaction","summary":"old history","tokensBefore":26268}"#,
    ]
    let transcript = PiSessionTranscriptReader.parse(lines: lines, threadId: threadId)

    // B6.3 — pi never rewrites or truncates the session file at compaction
    // (verified against `dist/core/session-manager.js`: `appendCompaction`/
    // `_appendEntry` are strictly append-only), so every message above still
    // replays in full; only the boundary itself used to vanish. It now
    // surfaces as the same compaction item kind B6.2 gave claude, carrying the
    // one real field pi's persisted entry has (`tokensBefore`) — never the
    // `summary` prose, and never a fabricated post-compaction size or
    // manual/automatic flag pi's session file does not carry.
    let compactionKind = ItemKind(rawValue: "compaction")
    let compactionTitle = AgentCompactionPayload.encodeTitle(preTokens: 26268, postTokens: nil, automaticCompaction: nil)
    let expected: [RehydratedTranscriptStep] = [
        .userPrompt("PI_PROMPT_ONE"),
        .event(.turnStarted(threadId: threadId, turnId: "rehydrated-t1")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .reasoning, delta: "PI_REASON")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "PI_ANSWER")),
        .event(.itemStarted(threadId: threadId, itemId: "call_1", kind: .commandExecution, title: "read")),
        .event(.itemCompleted(threadId: threadId, itemId: "call_1", kind: .commandExecution, status: .completed)),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "PI_ANSWER_TWO")),
        .event(.itemStarted(threadId: threadId, itemId: "call_2", kind: .fileChange, title: "write")),
        .event(.itemCompleted(threadId: threadId, itemId: "call_2", kind: .fileChange, status: .failed)),
        .event(.itemStarted(threadId: threadId, itemId: "pi-compaction-1", kind: compactionKind, title: compactionTitle)),
        .event(.itemCompleted(threadId: threadId, itemId: "pi-compaction-1", kind: compactionKind, status: .completed)),
        .event(.turnCompleted(threadId: threadId, turnId: "rehydrated-t1", outcome: .completed, errorMessage: nil)),
    ]
    expect(transcript.steps == expected,
           "PiSessionTranscriptReader: steps drifted.\n  got: \(transcript.steps)\n  want: \(expected)")
    expect(transcript.restoredMessageCount == 3,
           "PiSessionTranscriptReader: expected 3 restored messages (1 user + 2 assistant; the compaction boundary is not a conversational message), got \(transcript.restoredMessageCount)")

    // The `compaction` summary prose is never replayed as transcript content.
    expect(!stepsDescription(transcript).contains("old history"),
           "PiSessionTranscriptReader: a compaction summary leaked into the transcript")
}

private func runCodexSessionTranscriptParseChecks() {
    let threadId = "019c0dex-1111-2222-3333-444444444444"
    let lines = [
        #"{"type":"session_meta","payload":{"id":"019c0dex-1111-2222-3333-444444444444","cwd":"/x","timestamp":"2026-08-10T12:00:00.000Z"}}"#,
        #"{"type":"event_msg","payload":{"type":"user_message","message":"CODEX_PROMPT"}}"#,
        #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"CODEX_REASON"}],"encrypted_content":"IGNORE_ENCRYPTED"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"CODEX_PROMPT"}]}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"cmd\":\"do not restore arguments\"}","call_id":"call_ok"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_ok","output":"RAW_TOOL_OUTPUT"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{}","call_id":"call_bad"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_bad","status":"failed","output":"RAW_FAILURE"}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"CODEX_REPLY"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CODEX_REPLY"}]}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{}}}}"#,
        "malformed",
    ]
    let transcript = CodexSessionTranscriptReader.parse(lines: lines, threadId: threadId)
    let expected: [RehydratedTranscriptStep] = [
        .userPrompt("CODEX_PROMPT"),
        .event(.turnStarted(threadId: threadId, turnId: "rehydrated-t1")),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .reasoning, delta: "CODEX_REASON")),
        .event(.itemStarted(threadId: threadId, itemId: "call_ok", kind: .commandExecution, title: "shell_command")),
        .event(.itemCompleted(threadId: threadId, itemId: "call_ok", kind: .commandExecution, status: .completed)),
        .event(.itemStarted(threadId: threadId, itemId: "call_bad", kind: .commandExecution, title: "apply_patch")),
        .event(.itemCompleted(threadId: threadId, itemId: "call_bad", kind: .commandExecution, status: .failed)),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "CODEX_REPLY")),
        .event(.turnCompleted(threadId: threadId, turnId: "rehydrated-t1", outcome: .completed, errorMessage: nil)),
    ]
    expect(transcript.steps == expected, "Codex transcript steps drifted.\n got: \(transcript.steps)\n want: \(expected)")
    expect(transcript.restoredMessageCount == 2,
           "Codex mirrored/reasoning/tool rows must not inflate the 2-message count, got \(transcript.restoredMessageCount)")
    let serialized = stepsDescription(transcript)
    expect(serialized.components(separatedBy: "CODEX_PROMPT").count == 2,
           "Codex mirrored user message rendered more than once")
    expect(serialized.components(separatedBy: "CODEX_REPLY").count == 2,
           "Codex mirrored assistant message rendered more than once")
    expect(!serialized.contains("RAW_TOOL_OUTPUT") && !serialized.contains("RAW_FAILURE")
            && !serialized.contains("IGNORE_ENCRYPTED") && !serialized.contains("do not restore arguments"),
           "Codex raw tool/encrypted/argument bodies crossed the display parser boundary")
}

private func runTranscriptRehydrationBoundChecks() {
    let threadId = "t-bound"
    // Five user prompts, cap at two: only the last two survive and the drop is
    // surfaced (AGENTS.md "no silent caps").
    let lines = (1...5).map { #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"PROMPT_\#($0)"}]}}"# }
    let capped = PiSessionTranscriptReader.parse(
        lines: lines, threadId: threadId, limits: RehydrationLimits(maxMessages: 2))
    let prompts = capped.steps.compactMap { step -> String? in
        if case let .userPrompt(text) = step { return text } else { return nil }
    }
    expect(prompts == ["PROMPT_4", "PROMPT_5"],
           "RehydrationLimits: the cap must keep the most recent messages, got \(prompts)")
    expect(capped.omittedEarlier, "RehydrationLimits: a cap that dropped messages must set omittedEarlier")
    expect(capped.boundaryNoticeText == "Previous session — 2 messages restored · earlier history not shown",
           "RehydrationLimits: the boundary notice must surface the drop, got \(capped.boundaryNoticeText)")

    // A byte-truncated read surfaces the drop even when nothing was cap-dropped.
    let truncated = PiSessionTranscriptReader.parse(
        lines: [#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"ONLY"}]}}"#],
        threadId: threadId, truncated: true)
    expect(truncated.omittedEarlier, "RehydrationLimits: a truncated tail read must set omittedEarlier")
    expect(truncated.boundaryNoticeText.contains("earlier history not shown"),
           "RehydrationLimits: a truncated read must surface the drop in the notice")

    // Singular grammar.
    let one = PiSessionTranscriptReader.parse(
        lines: [#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"SOLO"}]}}"#],
        threadId: threadId)
    expect(one.boundaryNoticeText == "Previous session — 1 message restored",
           "RehydrationLimits: singular grammar drifted: \(one.boundaryNoticeText)")
}

#if os(macOS)
private func runTranscriptRehydrationDispatchChecks() {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-rehydrate-dispatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }

    let cwd = "/Users/dylan/Documents/personal/Array"

    func claudeLines(_ marker: String) -> [String] {
        [#"{"type":"user","isSidechain":false,"message":{"role":"user","content":"\#(marker)"}}"#,
         #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}"#]
    }
    func piLines(_ marker: String) -> [String] {
        [#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"\#(marker)"}]}}"#,
         #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}"#]
    }
    func writeClaude(home: URL, agentUUID: UUID, marker: String) {
        let url = ClaudeSessionTranscriptReader.sessionFileURL(
            homeURL: home, cwd: cwd, sessionId: ManagedTranscriptRehydrator.claudeSessionId(forAgentUUID: agentUUID))
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! claudeLines(marker).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func writePi(home: URL, agentUUID: UUID, marker: String, slug: String? = nil) {
        let sessionId = ManagedTranscriptRehydrator.piSessionId(forAgentUUID: agentUUID)
        let dirName = slug ?? PiSessionTranscriptReader.slug(forCwd: cwd)
        let dir = home
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Real pi filename shape: <ISO-timestamp>_<sessionId>.jsonl
        let url = dir.appendingPathComponent("2026-08-07T01-20-08-718Z_\(sessionId).jsonl")
        try! piLines(marker).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    @discardableResult
    func writeCodex(
        home: URL, threadId: String, marker: String, archived: Bool = false,
        filename: String = "rollout-fixture.jsonl", metaPadBytes: Int = 0
    ) -> URL {
        let rootName = archived ? "archived_sessions" : "sessions/2026/08/10"
        let dir = home.appendingPathComponent(".codex/\(rootName)", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        // Real rollouts carry the environment/instruction preamble on the
        // session_meta line, so it runs ~18 KB — the size that made a
        // byte-at-a-time read ruinous. `metaPadBytes` reproduces that weight.
        let pad = metaPadBytes > 0 ? #","pad":"\#(String(repeating: "x", count: metaPadBytes))""# : ""
        let lines = [
            #"{"type":"session_meta","payload":{"id":"\#(threadId)","cwd":"\#(cwd)","timestamp":"2026-08-10T12:00:00.000Z"\#(pad)}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(marker)"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"reply"}}"#,
        ]
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func inputs(home: URL, agentUUID: UUID, model: String, claudeCLIAvailable: Bool) -> ManagedTranscriptRehydrator.Inputs {
        ManagedTranscriptRehydrator.Inputs(
            agentUUID: agentUUID, cwd: cwd, model: model,
            harness: model.hasPrefix("anthropic/") ? .claudeCode : .pi,
            claudeCLIAvailable: claudeCLIAvailable, homeURL: home)
    }
    func firstUserPrompt(_ transcript: RehydratedTranscript?) -> String? {
        transcript?.steps.compactMap { step -> String? in
            if case let .userPrompt(text) = step { return text } else { return nil }
        }.first
    }

    // 1 · claude file only → claude chosen.
    do {
        let home = base.appendingPathComponent("claude-only", isDirectory: true)
        let id = UUID()
        writeClaude(home: home, agentUUID: id, marker: "CLAUDE_MARKER")
        let t = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: id, model: "anthropic/opus", claudeCLIAvailable: true))
        expect(firstUserPrompt(t) == "CLAUDE_MARKER", "dispatch: a claude-only agent must rehydrate from the claude session file, got \(String(describing: firstUserPrompt(t)))")
    }

    // 2 · pi file only → pi chosen (even for an anthropic model with claude present).
    do {
        let home = base.appendingPathComponent("pi-only", isDirectory: true)
        let id = UUID()
        writePi(home: home, agentUUID: id, marker: "PI_MARKER")
        let t = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: id, model: "openai-codex/gpt-5.6", claudeCLIAvailable: false))
        expect(firstUserPrompt(t) == "PI_MARKER", "dispatch: a pi-only agent must rehydrate from the pi session file, got \(String(describing: firstUserPrompt(t)))")
    }

    // 3 · both present → the routing policy breaks the tie.
    do {
        let home = base.appendingPathComponent("both", isDirectory: true)
        let id = UUID()
        writeClaude(home: home, agentUUID: id, marker: "CLAUDE_MARKER")
        writePi(home: home, agentUUID: id, marker: "PI_MARKER")
        let claudeWon = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: id, model: "anthropic/opus", claudeCLIAvailable: true))
        expect(firstUserPrompt(claudeWon) == "CLAUDE_MARKER", "dispatch: both present + anthropic model + claude available must pick claude, got \(String(describing: firstUserPrompt(claudeWon)))")
        let piWon = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: id, model: "openai-codex/gpt-5.6", claudeCLIAvailable: true))
        expect(firstUserPrompt(piWon) == "PI_MARKER", "dispatch: both present + non-anthropic model must pick pi, got \(String(describing: firstUserPrompt(piWon)))")
    }

    // 4 · neither present → nil (caller falls back to the plain notice).
    do {
        let home = base.appendingPathComponent("neither", isDirectory: true)
        try! fm.createDirectory(at: home, withIntermediateDirectories: true)
        let t = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: UUID(), model: "anthropic/opus", claudeCLIAvailable: true))
        expect(t == nil, "dispatch: no session file must return nil so the caller shows the notice")
    }

    // 5 · pi file under the WRONG slug dir is still found by the unique-id scan.
    do {
        let home = base.appendingPathComponent("pi-fallback", isDirectory: true)
        let id = UUID()
        writePi(home: home, agentUUID: id, marker: "PI_FALLBACK", slug: "--some-other-project--")
        let t = ManagedTranscriptRehydrator.rehydrate(inputs(home: home, agentUUID: id, model: "openai-codex/gpt-5.6", claudeCLIAvailable: false))
        expect(firstUserPrompt(t) == "PI_FALLBACK", "dispatch: a pi session file under a different slug must still be found by the unique-id scan, got \(String(describing: firstUserPrompt(t)))")
    }

    // 6 · Codex selects the exact stored id, never a newer rollout from the
    // same cwd, and the preferred native route beats an older Pi transcript.
    do {
        let home = base.appendingPathComponent("codex-exact", isDirectory: true)
        let id = UUID()
        let wanted = "019c0dex-wanted"
        _ = writeCodex(home: home, threadId: "019c0dex-wrong", marker: "WRONG_NEWEST", filename: "rollout-z-newest.jsonl")
        _ = writeCodex(home: home, threadId: wanted, marker: "CODEX_EXACT", filename: "rollout-a-wanted.jsonl")
        writePi(home: home, agentUUID: id, marker: "OLD_PI")
        let value = ManagedTranscriptRehydrator.rehydrate(.init(
            agentUUID: id, cwd: cwd, model: "openai-codex/gpt-5.6", harness: .codex,
            claudeCLIAvailable: false, homeURL: home,
            codexThreadId: wanted))
        expect(firstUserPrompt(value) == "CODEX_EXACT",
               "dispatch: Codex must select exact stored thread id and preferred route, got \(String(describing: firstUserPrompt(value)))")
    }

    // 7 · archived fallback works; ambiguity within one tier fails closed.
    do {
        let home = base.appendingPathComponent("codex-archive", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let archived = writeCodex(home: home, threadId: "archived-id", marker: "ARCHIVED", archived: true)
        // Resolve BOTH sides: the fixture URL keeps the `/var/...` spelling the
        // temp dir handed us, while the locator's directory enumerator returns
        // the symlink-resolved `/private/var/...` for the very same file. Compare
        // canonical paths or this asserts on the spelling instead of the file.
        let locatedArchived = CodexSessionTranscriptReader.locateRollout(
            codexHomeURL: codexHome, threadId: "archived-id")
        expect(locatedArchived?.resolvingSymlinksInPath().path == archived.resolvingSymlinksInPath().path,
               "Codex locator must find an exact archived rollout when no active copy exists; wanted \(archived.resolvingSymlinksInPath().path) got \(String(describing: locatedArchived?.resolvingSymlinksInPath().path))")
        _ = writeCodex(home: home, threadId: "duplicate-id", marker: "ONE", filename: "rollout-one.jsonl")
        _ = writeCodex(home: home, threadId: "duplicate-id", marker: "TWO", filename: "rollout-two.jsonl")
        expect(CodexSessionTranscriptReader.locateRollout(codexHomeURL: codexHome, threadId: "duplicate-id") == nil,
               "Codex locator must fail closed for duplicate active matches")
    }

    // 8 · Locating a thread in a real-sized corpus must not cost a syscall per
    //     byte. 0.4.4–0.4.10 read the ~18 KB session_meta line ONE BYTE AT A
    //     TIME for every rollout in ~/.codex/sessions: 688 files ≈ 15.5 million
    //     read() calls per scan, which pinned prod at 97% CPU for 90 s inside
    //     rehydratePreviousSessionOrNotice (Array_2026-08-11-142854
    //     .cpu_resource.diag). The fixture filenames deliberately do NOT carry
    //     the thread id, so this drives the full meta scan rather than the
    //     filename fast path. The budget is wall-clock because the defect IS
    //     the syscall count, and it was calibrated by running this fixture
    //     against both implementations: the per-byte loop measured 3.32 s at
    //     201 files (so ~6.6 s at 401), the buffered read ~0.03 s. A 1 s
    //     ceiling therefore sits ~6x under the broken cost and ~30x over the
    //     fixed one.
    do {
        let home = base.appendingPathComponent("codex-scan-cost", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let wanted = "019ff241-208f-7940-9d21-e8b3bd28f4a9"
        for index in 0..<400 {
            writeCodex(home: home, threadId: "decoy-\(index)", marker: "DECOY",
                       filename: "rollout-decoy-\(index).jsonl", metaPadBytes: 18 * 1024)
        }
        writeCodex(home: home, threadId: wanted, marker: "WANTED",
                   filename: "rollout-target.jsonl", metaPadBytes: 18 * 1024)

        let started = Date()
        let located = CodexSessionTranscriptReader.locateRollout(codexHomeURL: codexHome, threadId: wanted)
        let elapsed = Date().timeIntervalSince(started)
        expect(located?.lastPathComponent == "rollout-target.jsonl",
               "scan cost: the wanted rollout must still be located, got \(String(describing: located?.lastPathComponent))")
        expect(elapsed < 1.0,
               "scan cost: locating one thread among 401 padded rollouts took \(String(format: "%.2f", elapsed))s — a per-byte read loop is back")
        print("Codex rollout scan cost: 401 padded rollouts scanned in \(String(format: "%.3f", elapsed))s")
    }

    // 9 · The filename fast path never outranks the file's own session_meta: a
    //     rollout NAMED after the wanted thread but carrying a different id
    //     must lose to the correctly-identified file.
    do {
        let home = base.appendingPathComponent("codex-name-impostor", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let wanted = "019ff237-b008-7f83-9ca8-7ee2d5b66f96"
        writeCodex(home: home, threadId: "some-other-thread", marker: "IMPOSTOR",
                   filename: "rollout-2026-08-11T15-06-03-\(wanted).jsonl")
        writeCodex(home: home, threadId: wanted, marker: "REAL", filename: "rollout-real.jsonl")
        let located = CodexSessionTranscriptReader.locateRollout(codexHomeURL: codexHome, threadId: wanted)
        expect(located?.lastPathComponent == "rollout-real.jsonl",
               "Codex locator must confirm the thread id from session_meta, not from the filename; got \(String(describing: located?.lastPathComponent))")
    }
}
#endif
