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
    runTranscriptRehydrationBoundChecks()
    #if os(macOS)
    runTranscriptRehydrationDispatchChecks()
    #endif
    print("TranscriptRehydration checks passed: claude+pi session .jsonl parse to replayable steps, sub-agent frames skipped, caps surfaced, backend dispatched by file existence with the claude/pi tiebreak")
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
        .event(.itemStarted(threadId: threadId, itemId: "toolu_A", kind: .commandExecution, title: "Bash")),
        .event(.itemCompleted(threadId: threadId, itemId: "toolu_A", kind: .commandExecution, status: .completed)),
        .event(.contentDelta(threadId: threadId, turnId: "rehydrated-t1", streamKind: .assistant, delta: "ANSWER_BETA")),
        .event(.itemStarted(threadId: threadId, itemId: "toolu_B", kind: .fileChange, title: "Edit")),
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
        #"{"type":"compaction","summary":"old history"}"#,
    ]
    let transcript = PiSessionTranscriptReader.parse(lines: lines, threadId: threadId)

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
        .event(.turnCompleted(threadId: threadId, turnId: "rehydrated-t1", outcome: .completed, errorMessage: nil)),
    ]
    expect(transcript.steps == expected,
           "PiSessionTranscriptReader: steps drifted.\n  got: \(transcript.steps)\n  want: \(expected)")
    expect(transcript.restoredMessageCount == 3,
           "PiSessionTranscriptReader: expected 3 restored messages (1 user + 2 assistant), got \(transcript.restoredMessageCount)")

    // The `compaction` summary is not replayed as transcript content.
    expect(!stepsDescription(transcript).contains("old history"),
           "PiSessionTranscriptReader: a compaction summary leaked into the transcript")
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
    func inputs(home: URL, agentUUID: UUID, model: String, claudeCLIAvailable: Bool) -> ManagedTranscriptRehydrator.Inputs {
        ManagedTranscriptRehydrator.Inputs(
            agentUUID: agentUUID, cwd: cwd, model: model,
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
}
#endif
