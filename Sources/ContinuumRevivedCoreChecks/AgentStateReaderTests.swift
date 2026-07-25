import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/35-agent-state-reader-protocol.md
// Pure executable checks for AgentSnapshot and AgentStateReader. This project has
// no XCTest target in the matrix, so these run through ContinuumRevivedCoreChecks.

func runAgentStateReaderTests() {
    let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    func evidence(_ age: Double = 12.5) -> AgentSnapshot.Evidence {
        AgentSnapshot.Evidence(
            source: "claude:jsonl-tail",
            lastEventType: "assistant",
            mtimeAgeSeconds: age
        )
    }

    // MARK: - AgentSnapshot round-trip over every AgentStatus

    do {
        for status in AgentStatus.allCases {
            let snapshot = AgentSnapshot(
                kind: .claude,
                status: status,
                title: "Status \(status.rawValue)",
                mode: "normal",
                asOf: asOf,
                detail: "known-code",
                evidence: evidence()
            )
            let data = try! JSONEncoder().encode(snapshot)
            let decoded = try! JSONDecoder().decode(AgentSnapshot.self, from: data)
            expect(decoded == snapshot, "AgentSnapshot must round-trip for AgentStatus.\(status.rawValue)")
        }
    }

    // MARK: - Title truncation

    do {
        let longTitle = String(repeating: "x", count: 200)
        let snapshot = AgentSnapshot(
            kind: .pi,
            status: .working,
            title: longTitle,
            mode: nil,
            asOf: asOf,
            detail: nil,
            evidence: evidence()
        )
        expect(snapshot.title?.count == 80, "AgentSnapshot title must clamp to 80 characters, got \(snapshot.title?.count ?? -1)")
    }

    // MARK: - I5 structural field-name proof

    do {
        let snapshot = AgentSnapshot(
            kind: .codex,
            status: .idle,
            title: "metadata",
            mode: "read-only",
            asOf: asOf,
            detail: nil,
            evidence: AgentSnapshot.Evidence(source: "codex:rollout-tail", lastEventType: "turn_finished", mtimeAgeSeconds: 0)
        )
        let forbiddenNames = ["pid", "paneTarget", "body", "content", "message", "toolInput", "toolOutput", "prompt", "credential"]
        let fieldNames = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
        for forbidden in forbiddenNames {
            expect(!fieldNames.contains(forbidden), "AgentSnapshot must not expose body/runtime field named \(forbidden); fields=\(fieldNames.sorted())")
        }
    }

    // MARK: - AgentKind exhaustiveness

    do {
        expect(AgentKind.allCases.count == 6, "AgentKind must remain the six-case closed enum")
        for kind in AgentKind.allCases {
            let data = try! JSONEncoder().encode(kind)
            let decoded = try! JSONDecoder().decode(AgentKind.self, from: data)
            expect(decoded == kind, "AgentKind \(kind.rawValue) must round-trip through JSON")
        }
    }

    // MARK: - Protocol conformance

    struct MockReader: AgentStateReader {
        let kind: AgentKind = .managed
        let detectedProcess: String
        let locatedURL: URL?
        let snapshot: AgentSnapshot

        func detect(processName: String) -> Bool {
            processName == detectedProcess
        }

        func locate(pid: pid_t?, cwd: String, runId: String?) -> URL? {
            locatedURL
        }

        func read(storeURL: URL, asOf: Date) -> AgentSnapshot {
            AgentSnapshot(
                kind: snapshot.kind,
                status: snapshot.status,
                title: snapshot.title,
                mode: snapshot.mode,
                asOf: asOf,
                detail: snapshot.detail,
                evidence: snapshot.evidence
            )
        }
    }

    do {
        let url = URL(fileURLWithPath: "/tmp/continuum-agent-reader-store")
        let staleSnapshot = AgentSnapshot(
            kind: .managed,
            status: .working,
            title: "Managed agent",
            mode: "normal",
            asOf: asOf,
            detail: nil,
            evidence: evidence(901)
        )
        let reader = MockReader(detectedProcess: "managed-agent", locatedURL: url, snapshot: staleSnapshot)
        expect(reader.detect(processName: "managed-agent"), "MockReader detect must accept its configured process")
        expect(!reader.detect(processName: "zsh"), "MockReader detect must reject other processes")
        expect(reader.locate(pid: 123, cwd: "/tmp", runId: "run-1") == url, "MockReader locate must return configured URL")
        let readAsOf = Date(timeIntervalSince1970: 1_800_000_123)
        let read = reader.read(storeURL: url, asOf: readAsOf)
        expect(read.asOf == readAsOf, "AgentStateReader.read must echo observer-supplied asOf")
        expect(read.evidence.mtimeAgeSeconds > 900, "mtimeAgeSeconds is the caller-visible staleness signal for reader output")
    }
}
