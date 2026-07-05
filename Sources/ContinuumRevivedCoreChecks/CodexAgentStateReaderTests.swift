import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/38-codex-reader.md
// Hermetic executable checks for Codex rollout metadata reading. These fixtures
// must never consult the live ~/.codex tree.

func runCodexAgentStateReaderTests() {
    struct Manifest: Codable, Equatable {
        var ticket: String
        var locateChecks: Int
        var statusRows: [String]
        var modeRows: [String]
        var titleRows: [String]
        var i5ForbiddenTokens: [String]
    }

    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-codex-reader-\(UUID().uuidString)", isDirectory: true)
    let sessionsRoot = base
        .appendingPathComponent("fake-home", isDirectory: true)
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try! fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let now = Date(timeIntervalSince1970: 1_800_200_000)
    let paneStartedAt = now
    let cwd = "/Users/dylan/Documents/personal/continuum-fixes"
    let otherCwd = "/Users/dylan/Documents/personal/other"
    let redactedTokens = ["<agent_message_body>", "<user_message>", "<function_args>"]
    let reader = CodexAgentStateReader(
        sessionsRoot: sessionsRoot,
        freshWorkingWindow: 30,
        staleWindow: 900
    )
    var locateChecks = 0
    var statusRows: [String] = []
    var modeRows: [String] = []
    var titleRows: [String] = []

    func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func metaLine(cwd: String, timestamp: Date) -> String {
        jsonLine([
            "type": "session_meta",
            "timestamp": iso(timestamp),
            "payload": [
                "cwd": cwd,
                "timestamp": iso(timestamp)
            ]
        ])
    }

    func eventLine(type: String, payloadType: String, extraPayload: [String: Any] = [:]) -> String {
        var payload = extraPayload
        payload["type"] = payloadType
        return jsonLine([
            "type": type,
            "timestamp": iso(now),
            "payload": payload
        ])
    }

    func writeRollout(
        _ name: String,
        cwd rolloutCwd: String = cwd,
        timestamp: Date,
        mtime: Date,
        lines: [String],
        day: String = "2026/07/05"
    ) -> URL {
        let dir = sessionsRoot.appendingPathComponent(day, isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(name).jsonl", isDirectory: false)
        let body = ([metaLine(cwd: rolloutCwd, timestamp: timestamp)] + lines).joined(separator: "\n") + "\n"
        try! body.write(to: url, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func writeIndex(_ rows: [[String: Any]]) {
        let data = rows.map(jsonLine).joined(separator: "\n") + "\n"
        try! data.write(to: sessionsRoot.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    }

    func assertRoundTrip(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(AgentSnapshot.self, from: data)
        expect(decoded == snapshot, "\(label): AgentSnapshot round-trips through Codable")
    }

    func assertI5Clean(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8)!
        for token in redactedTokens {
            expect(!json.contains(token), "\(label): snapshot omits transcript/body taint \(token)")
        }
    }

    func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    func readFixture(
        _ label: String,
        lines: [String],
        age: TimeInterval,
        processAlive: Bool = true,
        expectedStatus: AgentStatus,
        expectedLastEvent: String?
    ) -> AgentSnapshot {
        let url = writeRollout(
            label,
            timestamp: paneStartedAt.addingTimeInterval(1),
            mtime: now.addingTimeInterval(-age),
            lines: lines
        )
        let snapshot = reader.read(at: url, processAlive: processAlive, now: now)
        expect(snapshot.status == expectedStatus, "\(label): expected \(expectedStatus.rawValue), got \(snapshot.status.rawValue)")
        expect(snapshot.asOf == now.addingTimeInterval(-age), "\(label): asOf is rollout mtime")
        expect(snapshot.evidence.source == "codex:rollout-tail", "\(label): evidence source names rollout tail")
        expect(snapshot.evidence.lastEventType == expectedLastEvent, "\(label): records last meaningful payload type")
        expect(snapshot.evidence.mtimeAgeSeconds == age, "\(label): records measured mtime age")
        assertRoundTrip(snapshot, label)
        assertI5Clean(snapshot, label)
        statusRows.append("\(label)=\(snapshot.status.rawValue):\(snapshot.evidence.lastEventType ?? "nil"):\(Int(snapshot.evidence.mtimeAgeSeconds))")
        return snapshot
    }

    do {
        expect(reader.detect(processName: "codex"), "Codex reader detects codex")
        expect(reader.detect(processName: "node"), "Codex reader detects node shim")
        expect(!reader.detect(processName: "zsh"), "Codex reader rejects shell")
    }

    do {
        let older = writeRollout(
            "older",
            timestamp: paneStartedAt.addingTimeInterval(-60),
            mtime: now.addingTimeInterval(-5),
            lines: []
        )
        let equal = writeRollout(
            "equal",
            timestamp: paneStartedAt,
            mtime: now.addingTimeInterval(-4),
            lines: []
        )
        let mismatch = writeRollout(
            "mismatch",
            cwd: otherCwd,
            timestamp: paneStartedAt.addingTimeInterval(10),
            mtime: now.addingTimeInterval(-1),
            lines: []
        )
        let newer = writeRollout(
            "newer",
            timestamp: paneStartedAt.addingTimeInterval(5),
            mtime: now.addingTimeInterval(-3),
            lines: []
        )
        let located = reader.locate(cwd: cwd, paneStartedAt: paneStartedAt)
        expect(sameFile(located, newer), "locate returns newest mtime cwd match strictly after pane start, got \(located?.path ?? "nil"), expected \(newer.path)")
        expect(!sameFile(located, older) && !sameFile(located, equal) && !sameFile(located, mismatch), "locate rejects older/equal/mismatched candidates")
        locateChecks += 1

        let none = reader.locate(cwd: "/missing", paneStartedAt: paneStartedAt)
        expect(none == nil, "locate returns nil when no cwd match exists")
        locateChecks += 1

        let oldOnlyRoot = base.appendingPathComponent("old-only", isDirectory: true)
        let oldOnlyReader = CodexAgentStateReader(sessionsRoot: oldOnlyRoot)
        try! fm.createDirectory(at: oldOnlyRoot.appendingPathComponent("2026/07/05", isDirectory: true), withIntermediateDirectories: true)
        let oldOnlyURL = oldOnlyRoot
            .appendingPathComponent("2026/07/05", isDirectory: true)
            .appendingPathComponent("rollout-old-only.jsonl")
        try! metaLine(cwd: cwd, timestamp: paneStartedAt.addingTimeInterval(-5))
            .write(to: oldOnlyURL, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: now], ofItemAtPath: oldOnlyURL.path)
        expect(oldOnlyReader.locate(cwd: cwd, paneStartedAt: paneStartedAt) == nil, "locate returns nil when cwd match predates pane start")
        expect(sameFile(oldOnlyReader.locate(cwd: cwd, paneStartedAt: .distantPast), oldOnlyURL), "locate distantPast accepts cwd match regardless of timestamp")
        locateChecks += 2
    }

    do {
        _ = readFixture(
            "tool-call-in-flight-fresh",
            lines: [
                eventLine(type: "response_item", payloadType: "function_call", extraPayload: ["arguments": "<function_args>"])
            ],
            age: 10,
            expectedStatus: .working,
            expectedLastEvent: "function_call"
        )
        _ = readFixture(
            "tool-call-in-flight-stalled",
            lines: [
                eventLine(type: "response_item", payloadType: "function_call", extraPayload: ["arguments": "<function_args>"])
            ],
            age: 60,
            expectedStatus: .idle,
            expectedLastEvent: "function_call"
        )
        _ = readFixture(
            "tool-loop-fresh",
            lines: [
                eventLine(type: "response_item", payloadType: "function_call", extraPayload: ["call_id": "call-a", "arguments": "<function_args>"]),
                eventLine(type: "response_item", payloadType: "function_call_output", extraPayload: ["call_id": "call-a", "output": "<agent_message_body>"])
            ],
            age: 10,
            expectedStatus: .working,
            expectedLastEvent: "function_call_output"
        )
        _ = readFixture(
            "tool-loop-stale",
            lines: [
                eventLine(type: "response_item", payloadType: "function_call_output", extraPayload: ["output": "<agent_message_body>"])
            ],
            age: 60,
            expectedStatus: .idle,
            expectedLastEvent: "function_call_output"
        )
        _ = readFixture(
            "task-started-fresh",
            lines: [
                eventLine(type: "event_msg", payloadType: "task_started")
            ],
            age: 10,
            expectedStatus: .working,
            expectedLastEvent: "task_started"
        )
        _ = readFixture(
            "task-started-stale",
            lines: [
                eventLine(type: "event_msg", payloadType: "task_started")
            ],
            age: 60,
            expectedStatus: .idle,
            expectedLastEvent: "task_started"
        )
        _ = readFixture(
            "task-started-then-call",
            lines: [
                eventLine(type: "event_msg", payloadType: "task_started"),
                eventLine(type: "response_item", payloadType: "function_call", extraPayload: ["arguments": "<function_args>"])
            ],
            age: 10,
            expectedStatus: .working,
            expectedLastEvent: "function_call"
        )
        _ = readFixture(
            "agent-message-mid-idle",
            lines: [
                eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])
            ],
            age: 60,
            expectedStatus: .idle,
            expectedLastEvent: "agent_message"
        )
        _ = readFixture(
            "agent-message-fresh-idle",
            lines: [
                eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])
            ],
            age: 5,
            expectedStatus: .idle,
            expectedLastEvent: "agent_message"
        )
        _ = readFixture(
            "turn-aborted",
            lines: [
                eventLine(type: "event_msg", payloadType: "turn_aborted")
            ],
            age: 10,
            expectedStatus: .idle,
            expectedLastEvent: "turn_aborted"
        )
        _ = readFixture(
            "stale-alive",
            lines: [
                eventLine(type: "response_item", payloadType: "function_call", extraPayload: ["arguments": "<function_args>"])
            ],
            age: 1_000,
            processAlive: true,
            expectedStatus: .idle,
            expectedLastEvent: "function_call"
        )
        _ = readFixture(
            "stale-dead",
            lines: [
                eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])
            ],
            age: 1_000,
            processAlive: false,
            expectedStatus: .done,
            expectedLastEvent: "agent_message"
        )
        _ = readFixture(
            "unparseable-tail",
            lines: ["not json", #"{ "type": "response_item", "payload": "#],
            age: 10,
            expectedStatus: .idle,
            expectedLastEvent: nil
        )
    }

    do {
        let single = readFixture(
            "mode-single",
            lines: [
                eventLine(type: "turn_context", payloadType: "context", extraPayload: ["approval_policy": "on-request"]),
                eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])
            ],
            age: 10,
            expectedStatus: .idle,
            expectedLastEvent: "agent_message"
        )
        expect(single.mode == "on-request", "mode-single: approval policy comes from tail")
        modeRows.append("single=\(single.mode ?? "nil")")

        let newest = readFixture(
            "mode-newest-wins",
            lines: [
                eventLine(type: "turn_context", payloadType: "context", extraPayload: ["approval_policy": "untrusted"]),
                eventLine(type: "turn_context", payloadType: "context", extraPayload: ["approval_policy": "on-failure"]),
                eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])
            ],
            age: 10,
            expectedStatus: .idle,
            expectedLastEvent: "agent_message"
        )
        expect(newest.mode == "on-failure", "mode-newest-wins: newest turn_context wins")
        modeRows.append("newest=\(newest.mode ?? "nil")")

        var buriedLines = [eventLine(type: "turn_context", payloadType: "context", extraPayload: ["approval_policy": "never-read"])]
        buriedLines.append(contentsOf: (0..<60).map { index in
            eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body> \(index)"])
        })
        let buriedURL = writeRollout(
            "mode-buried",
            timestamp: paneStartedAt.addingTimeInterval(1),
            mtime: now.addingTimeInterval(-10),
            lines: buriedLines
        )
        let buriedText = try! String(contentsOf: buriedURL, encoding: .utf8)
        let buriedOffset = buriedText.range(of: "never-read")!.lowerBound.utf16Offset(in: buriedText)
        let tailStartOffset = buriedText.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(50)
            .joined(separator: "\n")
            .utf16
            .count
        let buried = reader.read(at: buriedURL, processAlive: true, now: now)
        expect(buried.mode == nil, "mode-buried: turn_context before 50-line tail is not scanned; offsets \(buriedOffset)<\(tailStartOffset)")
        modeRows.append("buried=nil@\(buriedOffset)<\(tailStartOffset)")
        assertRoundTrip(buried, "mode-buried")
        assertI5Clean(buried, "mode-buried")
    }

    do {
        let titledURL = writeRollout(
            "title-indexed",
            timestamp: paneStartedAt.addingTimeInterval(1),
            mtime: now.addingTimeInterval(-10),
            lines: [eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])]
        )
        writeIndex([
            [
                "rollout_path": titledURL.path,
                "thread_name": "refactor the parser",
                "updated_at": iso(now.addingTimeInterval(-16 * 24 * 60 * 60))
            ]
        ])
        let titled = reader.read(at: titledURL, processAlive: true, now: now)
        expect(titled.title == "refactor the parser", "title-indexed: thread_name display title is used")
        titleRows.append("indexed=\(titled.title ?? "nil")")
        assertI5Clean(titled, "title-indexed")

        let fallbackURL = writeRollout(
            "title-fallback",
            cwd: "/Users/x/selectus-ms",
            timestamp: paneStartedAt.addingTimeInterval(1),
            mtime: now.addingTimeInterval(-10),
            lines: [eventLine(type: "event_msg", payloadType: "agent_message", extraPayload: ["message": "<agent_message_body>"])]
        )
        try? fm.removeItem(at: sessionsRoot.appendingPathComponent("session_index.jsonl"))
        let fallback = reader.read(at: fallbackURL, processAlive: true, now: now)
        expect(fallback.title == "selectus-ms", "title-fallback: cwd basename is used without index")
        titleRows.append("fallback=\(fallback.title ?? "nil")")

        let longTitle = String(repeating: "x", count: 84)
        writeIndex([
            [
                "rollout_path": fallbackURL.path,
                "thread_name": longTitle,
                "updated_at": iso(now)
            ]
        ])
        let truncated = reader.read(at: fallbackURL, processAlive: true, now: now)
        expect(truncated.title?.count == 80, "title-truncated: 84-char thread name truncates to 80")
        titleRows.append("truncated=\(truncated.title?.count ?? -1)")
    }

    do {
        writeIndex([
            [
                "rollout_path": "/missing/rollout-stale-index.jsonl",
                "thread_name": "stale index must not affect locate",
                "updated_at": iso(now.addingTimeInterval(-16 * 24 * 60 * 60))
            ]
        ])
        let rollout = writeRollout(
            "stale-index-locate",
            timestamp: paneStartedAt.addingTimeInterval(20),
            mtime: now,
            lines: []
        )
        let located = reader.locate(cwd: cwd, paneStartedAt: paneStartedAt)
        expect(sameFile(located, rollout), "stale-index-locate: locate uses rollout mtime scan, not session_index")
        locateChecks += 1
    }

    let manifest = Manifest(
        ticket: "38-codex-reader.md",
        locateChecks: locateChecks,
        statusRows: statusRows,
        modeRows: modeRows,
        titleRows: titleRows,
        i5ForbiddenTokens: redactedTokens
    )
    let manifestData = try! JSONEncoder().encode(manifest)
    let decoded = try! JSONDecoder().decode(Manifest.self, from: manifestData)
    expect(decoded == manifest, "Codex reader measured manifest round-trips")
    expect(locateChecks >= 5, "Codex reader locate checks measured \(locateChecks)")
    expect(statusRows.count >= 13, "Codex reader status rows measured \(statusRows.count)")
    print("CodexAgentStateReaderChecks passed: locateChecks=\(locateChecks), statusRows=\(statusRows.count), modeRows=\(modeRows.count), titleRows=\(titleRows.count)")
}
