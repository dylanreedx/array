import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/36-pi-reader.md
// Executable checks for the first concrete AgentStateReader implementation.

func runPiAgentStateReaderTests() {
    struct Manifest: Codable, Equatable {
        var ticket: String
        var fixturesRead: Int
        var locateChecks: Int
        var statusTransitions: [String]
        var i5ForbiddenTokens: [String]
    }

    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-pi-reader-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let projectRoot = base.appendingPathComponent("project", isDirectory: true)
    let globalRoot = base.appendingPathComponent("global-agent-runs", isDirectory: true)
    try! fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try! fm.createDirectory(at: globalRoot, withIntermediateDirectories: true)

    let reader = PiAgentStateReader(globalAgentRunsRoot: globalRoot)
    let fixtureNow = Date(timeIntervalSince1970: 1_800_010_000)
    var fixturesRead = 0
    var locateChecks = 0
    var statusTransitions: [String] = []

    func writeRun(
        _ directory: URL,
        status: String?,
        task: String = "Review a focused implementation without reading body artifacts",
        eventTypes: [String] = [],
        mtime: Date
    ) {
        try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "id": directory.lastPathComponent,
            "role": "code-reviewer",
            "task": task,
            "cwd": projectRoot.path,
            "createdAt": "2026-06-11T12:46:57Z",
            "updatedAt": "2026-06-11T12:47:12Z"
        ]
        if let status {
            object["status"] = status
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let runURL = directory.appendingPathComponent("run.json")
        try! data.write(to: runURL)
        try! fm.setAttributes([.modificationDate: mtime], ofItemAtPath: runURL.path)

        let events = eventTypes.map { type in
            #"{"ts":"2026-06-11T12:47:12Z","type":"\#(type)","body":"SECRET_BODY_\#(type)"}"#
        }.joined(separator: "\n")
        try! events.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try! "SECRET_FINAL_BODY".write(to: directory.appendingPathComponent("final.md"), atomically: true, encoding: .utf8)
        try! "SECRET_OUTPUT_BODY".write(to: directory.appendingPathComponent("output.json"), atomically: true, encoding: .utf8)
        try! "SECRET_SUMMARY_BODY".write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    func assertRoundTrip(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(AgentSnapshot.self, from: data)
        expect(decoded == snapshot, "\(label): AgentSnapshot round-trips through Codable")
    }

    func assertI5Clean(_ snapshot: AgentSnapshot, _ label: String) {
        let data = try! JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8)!
        for forbidden in ["SECRET_BODY", "SECRET_FINAL", "SECRET_OUTPUT", "SECRET_SUMMARY"] {
            expect(!json.contains(forbidden), "\(label): snapshot omits body-adjacent taint \(forbidden)")
        }
    }

    // MARK: - detect(processName:)

    do {
        expect(reader.detect(processName: "pi"), "Pi reader detects pane_current_command pi")
        expect(!reader.detect(processName: "node"), "Pi reader rejects node shim commands")
        expect(!reader.detect(processName: "codex"), "Pi reader rejects codex")
        expect(!reader.detect(processName: "claude"), "Pi reader rejects claude")
    }

    // MARK: - locate project-local before global

    do {
        let runId = "code-reviewer-20260611T124657Z-884e9d"
        let projectRun = projectRoot
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        let globalRun = globalRoot.appendingPathComponent(runId, isDirectory: true)
        try! fm.createDirectory(at: projectRun, withIntermediateDirectories: true)
        try! fm.createDirectory(at: globalRun, withIntermediateDirectories: true)

        expect(
            HarnessRoleRunBuilder.makeRunId(
                roleId: "code-reviewer",
                now: ISO8601DateFormatter().date(from: "2026-06-11T12:46:57Z")!,
                suffix: "884e9d"
            ) == runId,
            "Harness role runId matches Pi run directory basename"
        )
        expect(reader.locate(pid: nil, cwd: projectRoot.path, runId: runId) == projectRun, "Pi reader prefers project-local run directory over global")
        locateChecks += 1
        expect(reader.locate(pid: nil, cwd: projectRoot.path, runId: "missing-run") == nil, "Pi reader returns nil when runId is absent from both roots")
        locateChecks += 1
        expect(reader.locate(pid: nil, cwd: projectRoot.path, runId: nil) == nil, "Pi reader returns nil without a runId")
        locateChecks += 1
    }

    // MARK: - status fixtures

    do {
        let runDir = base.appendingPathComponent("pi-done", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-5)
        writeRun(runDir, status: "done", eventTypes: ["finished"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.kind == .pi, "pi-done: kind is pi")
        expect(snapshot.status == .done, "pi-done: done maps to AgentStatus.done")
        expect(snapshot.asOf == mtime, "pi-done: asOf is run.json mtime")
        expect(snapshot.evidence.source == "pi:run.json", "pi-done: evidence source names run.json")
        expect((snapshot.title?.count ?? 0) > 0 && (snapshot.title?.count ?? 0) <= 80, "pi-done: title is present and truncated")
        assertRoundTrip(snapshot, "pi-done")
        assertI5Clean(snapshot, "pi-done")
    }

    do {
        let runDir = base.appendingPathComponent("pi-working", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-10)
        writeRun(runDir, status: "running", eventTypes: ["tool_execution_start"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status == .working, "pi-working: fresh running run maps to working")
        expect(snapshot.evidence.lastEventType == "tool_execution_start", "pi-working: records last event type")
        assertRoundTrip(snapshot, "pi-working")
        assertI5Clean(snapshot, "pi-working")
    }

    do {
        let runDir = base.appendingPathComponent("pi-agent-end-retry-window", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-2)
        writeRun(runDir, status: "running", eventTypes: ["turn_end", "agent_end"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status == .working,
               "pi-agent-end-retry-window: agent_end is non-terminal until agent_settled")
        assertRoundTrip(snapshot, "pi-agent-end-retry-window")
        assertI5Clean(snapshot, "pi-agent-end-retry-window")
    }

    do {
        let runDir = base.appendingPathComponent("pi-settled", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-2)
        writeRun(runDir, status: "running", eventTypes: ["agent_end", "agent_settled"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status == .done,
               "pi-settled: agent_settled is the observed terminal boundary")
        assertRoundTrip(snapshot, "pi-settled")
        assertI5Clean(snapshot, "pi-settled")
    }

    do {
        let runDir = base.appendingPathComponent("pi-stale", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-1_000)
        writeRun(runDir, status: "running", eventTypes: ["tool_execution_start"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status != .working, "pi-stale: stale running evidence must not fabricate working")
        assertRoundTrip(snapshot, "pi-stale")
        assertI5Clean(snapshot, "pi-stale")
    }

    do {
        let runDir = base.appendingPathComponent("pi-configuring", isDirectory: true)
        let mtime = fixtureNow.addingTimeInterval(-2)
        writeRun(runDir, status: "queued", eventTypes: ["started"], mtime: mtime)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status == .configuring, "pi-configuring: queued maps to configuring")
        assertRoundTrip(snapshot, "pi-configuring")
        assertI5Clean(snapshot, "pi-configuring")
    }

    do {
        let runDir = base.appendingPathComponent("pi-run-missing", isDirectory: true)
        try! fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let snapshot = reader.read(storeURL: runDir, config: .init(now: fixtureNow))
        fixturesRead += 1
        expect(snapshot.status == .idle, "pi-run-missing: absent run.json maps to idle")
        expect(snapshot.asOf == fixtureNow, "pi-run-missing: asOf falls back to injected clock")
        expect(snapshot.evidence.source == "pi:run.json:absent", "pi-run-missing: evidence source names missing run.json")
        expect(snapshot.evidence.mtimeAgeSeconds == 0, "pi-run-missing: missing mtime age is zero")
        expect(snapshot.title == nil, "pi-run-missing: title is nil")
        assertRoundTrip(snapshot, "pi-run-missing")
        assertI5Clean(snapshot, "pi-run-missing")
    }

    // MARK: - Real filesystem transition

    do {
        let runId = HarnessRoleRunBuilder.makeRunId(roleId: "explorer", now: fixtureNow, suffix: "abc123")
        let runDir = projectRoot
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        let doneMtime = fixtureNow.addingTimeInterval(-5)
        writeRun(runDir, status: "done", eventTypes: ["finished"], mtime: doneMtime)
        expect(reader.locate(pid: nil, cwd: projectRoot.path, runId: runId) == runDir, "real-path: locate returns temp project-local run")
        locateChecks += 1
        let doneSnapshot = reader.read(storeURL: runDir, config: .init(now: doneMtime.addingTimeInterval(5)))
        expect(doneSnapshot.status == .done, "real-path: done run reads as done")
        fixturesRead += 1

        let runningMtime = fixtureNow.addingTimeInterval(25)
        writeRun(runDir, status: "running", eventTypes: ["tool_execution_start"], mtime: runningMtime)
        let runningSnapshot = reader.read(storeURL: runDir, config: .init(now: runningMtime.addingTimeInterval(5)))
        expect(runningSnapshot.status == .working, "real-path: mutated running run reads as working")
        fixturesRead += 1
        statusTransitions.append("\(doneSnapshot.status.rawValue)->\(runningSnapshot.status.rawValue)")
    }

    do {
        let manifest = Manifest(
            ticket: "36-pi-reader",
            fixturesRead: fixturesRead,
            locateChecks: locateChecks,
            statusTransitions: statusTransitions,
            i5ForbiddenTokens: ["SECRET_BODY", "SECRET_FINAL", "SECRET_OUTPUT", "SECRET_SUMMARY"]
        )
        let url = base.appendingPathComponent("pi-reader-manifest.json")
        let data = try! JSONEncoder().encode(manifest)
        try! data.write(to: url)
        let decoded = try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        expect(decoded == manifest, "Pi reader manifest round-trips with measured values")
        print("pi-reader: manifest at \(url.path)")
    }
}
