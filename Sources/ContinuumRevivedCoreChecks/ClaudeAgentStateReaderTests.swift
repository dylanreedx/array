import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/37-claude-reader.md
// Executable checks for Claude's pid-file-to-JSONL AgentStateReader.

func runClaudeAgentStateReaderTests() {
    struct Manifest: Codable, Equatable {
        var ticket: String
        var deriveRows: [String]
        var fixturesRead: Int
        var locateChecks: Int
        var i5ForbiddenTokens: [String]
    }

    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-claude-reader-\(UUID().uuidString)", isDirectory: true)
    let home = base.appendingPathComponent("home", isDirectory: true)
    try! fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let config = ClaudeReaderConfig()
    let reader = ClaudeAgentStateReader(homeURL: home, now: { now }, config: config)
    let pid: pid_t = 38649
    let sessionId = "11111111-2222-3333-4444-555555555555"
    let defaultCwd = "/Users/dylan/Documents/personal/continuum-revived"
    let redacted = "REDACTED_BODY"
    var deriveRows: [String] = []
    var fixturesRead = 0
    var locateChecks = 0

    func assertRoundTrip(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(AgentSnapshot.self, from: data)
        expect(decoded == snapshot, "\(label): AgentSnapshot round-trips through Codable")
    }

    func assertI5Clean(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8)!
        expect(!json.contains(redacted), "\(label): snapshot omits transcript/body taint")
    }

    func event(_ type: String, stop: String? = nil, toolUseResult: Bool = false) -> ClaudeReaderEvent {
        ClaudeReaderEvent(type: type, stopReason: stop, hasToolUseResult: toolUseResult)
    }

    func checkDerive(_ label: String, _ events: [ClaudeReaderEvent], age: TimeInterval, expected: AgentStatus) {
        let actual = reader.deriveStatus(from: events, ageSeconds: age)
        expect(actual == expected, "\(label): expected \(expected.rawValue), got \(actual.rawValue)")
        deriveRows.append("\(label)=\(actual.rawValue)")
    }

    do {
        expect(reader.detect(processName: "claude"), "Claude reader detects pane_current_command claude")
        expect(!reader.detect(processName: "node"), "Claude reader rejects node")
        expect(!reader.detect(processName: "pi"), "Claude reader rejects pi")
        expect(!reader.detect(processName: "codex"), "Claude reader rejects codex")
    }

    do {
        expect(ClaudeAgentStateReader.encodeCwd("/Users/dylan/project") == "-Users-dylan-project", "encodeCwd maps leading slash to dash")
        expect(ClaudeAgentStateReader.encodeCwd("/Users/dylan/.claude/worktrees/x") == "-Users-dylan--claude-worktrees-x", "encodeCwd maps /. to double dash")
        expect(ClaudeAgentStateReader.encodeCwd("") == "", "encodeCwd keeps empty cwd safe")
    }

    do {
        checkDerive("assistant-tool-use-open", [event("assistant", stop: "tool_use")], age: 10, expected: .working)
        checkDerive("tool-result-loop-open", [
            event("assistant", stop: "tool_use"),
            event("user", toolUseResult: true),
            event("assistant", stop: "tool_use")
        ], age: 10, expected: .working)
        checkDerive("assistant-end-turn-fresh", [event("assistant", stop: "end_turn")], age: 60, expected: .idle)
        checkDerive("assistant-end-turn-past-idle-window", [event("assistant", stop: "end_turn")], age: 200, expected: .idle)
        checkDerive("assistant-tool-use-stale", [event("assistant", stop: "tool_use")], age: 1_000, expected: .idle)
        checkDerive("empty-tail", [], age: 10, expected: .idle)
        checkDerive("control-only-tail", [
            event("mode"),
            event("permission-mode"),
            event("ai-title")
        ], age: 10, expected: .idle)
        checkDerive("unknown-event-tail", [event("future-event-type")], age: 10, expected: .idle)
    }

    do {
        let events = [
            ClaudeReaderEvent(type: "ai-title", aiTitle: "First title"),
            ClaudeReaderEvent(type: "assistant", stopReason: "end_turn"),
            ClaudeReaderEvent(type: "ai-title", aiTitle: "Second title")
        ]
        expect(reader.extractTitle(from: events) == "Second title", "Claude reader extracts the last ai-title")
        expect(reader.extractTitle(from: [event("assistant", stop: "end_turn")]) == nil, "Claude reader returns nil without ai-title")
        let longTitle = String(repeating: "x", count: 200)
        let snapshot = AgentSnapshot(
            kind: .claude,
            status: .idle,
            title: longTitle,
            mode: nil,
            asOf: now,
            detail: nil,
            evidence: .init(source: "claude:jsonl-tail", lastEventType: nil, mtimeAgeSeconds: 0)
        )
        expect(snapshot.title?.count == 80, "AgentSnapshot clamps Claude titles to 80 chars")
    }

    func writeScenario(
        _ name: String,
        cwd: String = defaultCwd,
        writePidFile: Bool = true,
        lines: [String],
        mtime: Date
    ) -> URL {
        let scenarioHome = home.appendingPathComponent(name, isDirectory: true)
        let sessions = scenarioHome.appendingPathComponent(".claude/sessions", isDirectory: true)
        try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        if writePidFile {
            let pidJSON: [String: Any] = [
                "sessionId": sessionId,
                "cwd": cwd,
                "status": "busy"
            ]
            let pidData = try! JSONSerialization.data(withJSONObject: pidJSON, options: [.sortedKeys])
            try! pidData.write(to: sessions.appendingPathComponent("\(pid).json"))
        }

        let project = scenarioHome
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeAgentStateReader.encodeCwd(cwd), isDirectory: true)
        try! fm.createDirectory(at: project, withIntermediateDirectories: true)
        let jsonl = project.appendingPathComponent("\(sessionId).jsonl")
        try! lines.joined(separator: "\n").write(to: jsonl, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: mtime], ofItemAtPath: jsonl.path)
        return scenarioHome
    }

    func line(_ json: String) -> String { json }

    func readScenario(
        _ name: String,
        expectedStatus: AgentStatus,
        expectedTitle: String?,
        expectedMode: String?,
        expectedLastEvent: String?,
        mtime: Date
    ) {
        let scenarioHome = home.appendingPathComponent(name, isDirectory: true)
        let scenarioReader = ClaudeAgentStateReader(homeURL: scenarioHome, now: { now }, config: config)
        let store = scenarioReader.locate(pid: pid, cwd: "/wrong-pane-cwd-is-ignored", runId: nil)
        let expectedPath = scenarioHome
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeAgentStateReader.encodeCwd(defaultCwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        expect(store == expectedPath, "\(name): locate uses pid-file cwd to build JSONL path")
        locateChecks += 1
        let snapshot = scenarioReader.read(storeURL: store!, asOf: mtime)
        fixturesRead += 1
        let manifest = [
            "scenario": name,
            "expectedStatus": expectedStatus.rawValue,
            "actualStatus": snapshot.status.rawValue,
            "actualTitle": snapshot.title ?? "nil",
            "ageSeconds": "\(snapshot.evidence.mtimeAgeSeconds)"
        ]
        expect(snapshot.kind == .claude, "\(name): kind is claude")
        expect(snapshot.status == expectedStatus, "\(name): status manifest \(manifest)")
        expect(snapshot.status != .needsAttention, "\(name): Claude reader never emits needsAttention")
        expect(snapshot.title == expectedTitle, "\(name): title manifest \(manifest)")
        expect(snapshot.mode == expectedMode, "\(name): permission mode is extracted")
        expect(snapshot.asOf == mtime, "\(name): read echoes observer-supplied JSONL mtime")
        expect(snapshot.evidence.source == "claude:jsonl-tail", "\(name): evidence source names JSONL tail")
        expect(snapshot.evidence.lastEventType == expectedLastEvent, "\(name): last meaningful event is measured")
        assertRoundTrip(snapshot, name)
        assertI5Clean(snapshot, name)
    }

    do {
        let mtime = now.addingTimeInterval(-10)
        _ = writeScenario("claude-working", lines: [
            line(#"{"type":"ai-title","aiTitle":"Implement login page","message":{"content":"\#(redacted)"}}"#),
            line(#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#),
            line(#"{"type":"assistant","stop_reason":"tool_use","message":{"content":"\#(redacted)"}}"#),
            line(#"{"type":"user","toolUseResult":{"content":"\#(redacted)"}}"#),
            line(#"{"type":"assistant","stop_reason":"tool_use","message":{"content":"\#(redacted)"}}"#)
        ], mtime: mtime)
        readScenario("claude-working", expectedStatus: .working, expectedTitle: "Implement login page", expectedMode: "bypassPermissions", expectedLastEvent: "assistant", mtime: mtime)
    }

    do {
        let mtime = now.addingTimeInterval(-60)
        _ = writeScenario("claude-idle", lines: [
            line(#"{"type":"assistant","stop_reason":"end_turn","message":{"content":"\#(redacted)"}}"#)
        ], mtime: mtime)
        readScenario("claude-idle", expectedStatus: .idle, expectedTitle: nil, expectedMode: nil, expectedLastEvent: "assistant", mtime: mtime)
    }

    do {
        let scenarioHome = writeScenario("claude-done", writePidFile: false, lines: [
            line(#"{"type":"assistant","stop_reason":"end_turn"}"#)
        ], mtime: now)
        let scenarioReader = ClaudeAgentStateReader(homeURL: scenarioHome, now: { now }, config: config)
        expect(scenarioReader.locate(pid: pid, cwd: defaultCwd, runId: nil) == nil, "claude-done: missing pid file returns nil for observer done/shell fallback")
        locateChecks += 1
    }

    do {
        let mtime = now.addingTimeInterval(-1_000)
        _ = writeScenario("claude-stale", lines: [
            line(#"{"type":"assistant","stop_reason":"tool_use","message":{"content":"\#(redacted)"}}"#)
        ], mtime: mtime)
        readScenario("claude-stale", expectedStatus: .idle, expectedTitle: nil, expectedMode: nil, expectedLastEvent: "assistant", mtime: mtime)
    }

    do {
        let cwd = "/Users/dylan/.claude/worktrees/ticket-37"
        let mtime = now.addingTimeInterval(-5)
        let scenarioHome = writeScenario("claude-encode-cwd", cwd: cwd, lines: [
            line(#"{"type":"assistant","stop_reason":"end_turn"}"#)
        ], mtime: mtime)
        let scenarioReader = ClaudeAgentStateReader(homeURL: scenarioHome, now: { now }, config: config)
        let located = scenarioReader.locate(pid: pid, cwd: defaultCwd, runId: nil)
        expect(located?.path.contains("-Users-dylan--claude-worktrees-ticket-37") == true, "claude-encode-cwd: locate builds double-dash path")
        locateChecks += 1
        let snapshot = scenarioReader.read(storeURL: located!, asOf: mtime)
        fixturesRead += 1
        expect(snapshot.status == .idle, "claude-encode-cwd: readable double-dash fixture maps end_turn to idle")
        expect(snapshot.asOf == mtime, "claude-encode-cwd: read echoes observer mtime")
        assertRoundTrip(snapshot, "claude-encode-cwd")
        assertI5Clean(snapshot, "claude-encode-cwd")
    }

    do {
        let mtime = now.addingTimeInterval(-10)
        _ = writeScenario("claude-unknown-events", lines: [
            line(#"{"type":"attachment","message":{"content":"\#(redacted)"}}"#),
            line(#"{"type":"file-history-snapshot","message":{"content":"\#(redacted)"}}"#),
            line(#"{"type":"queue-operation","message":{"content":"\#(redacted)"}}"#)
        ], mtime: mtime)
        readScenario("claude-unknown-events", expectedStatus: .idle, expectedTitle: nil, expectedMode: nil, expectedLastEvent: "queue-operation", mtime: mtime)
    }

    let manifest = Manifest(
        ticket: "37-claude-reader.md",
        deriveRows: deriveRows,
        fixturesRead: fixturesRead,
        locateChecks: locateChecks,
        i5ForbiddenTokens: [redacted]
    )
    let manifestData = try! JSONEncoder().encode(manifest)
    let decoded = try! JSONDecoder().decode(Manifest.self, from: manifestData)
    expect(decoded == manifest, "Claude reader measured manifest round-trips")
    expect(fixturesRead == 5, "Claude reader read-producing fixture count measured \(fixturesRead)")
    expect(locateChecks >= 6, "Claude reader locate checks measured \(locateChecks)")
    print("ClaudeAgentStateReaderChecks passed: fixtures=\(fixturesRead), locateChecks=\(locateChecks), deriveRows=\(deriveRows.count)")
}
