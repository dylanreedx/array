import Foundation

/// The run ledger is replayed at every launch. One helperEvidence row can be
/// megabytes (Dylan's file is 1.4 GB in 595 of them), and nothing in the replay
/// reads them. The witness: a ledger with large evidence rows is recovered by
/// decoding only the rows the reducer reads, to the same remembered sources and
/// the same restart row. RED with `CONTINUUM_LEGACY_LEDGER_RECOVER=1`.
enum LedgerRecoverChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recover-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("run-ledger")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = dir.appendingPathComponent("ledger.jsonl")
        let lead = UUID(), task = UUID(), helper = UUID(), part = UUID()
        var rows: [ManagedRunLedger.Row] = []
        rows.append(.init(kind: "taskOpened", task: task, agent: lead, source: "opened/\(task)"))
        var delegated = ManagedRunLedger.Row(kind: "delegated", task: task, agent: helper, source: "delegated/\(part)")
        delegated.part = part
        rows.append(delegated)
        for n in 0..<30 { rows.append(.init(kind: "hook", task: task, agent: lead, source: "hook/\(n)/\"q\"")) }
        for n in 0..<3 {
            var big = ManagedRunLedger.Row(kind: "helperEvidence", task: task, agent: helper, source: "evidence/\(helper)/\(n)")
            big.evidence = ["blob": String(repeating: "x", count: 2_000_000)]
            rows.append(big)
        }
        let encoder = JSONEncoder()
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(10) }
        try data.write(to: url)

        let ledger = ManagedRunLedger(support: root)
        ledger.drain()
        let decoded = ledger.qaRecoverDecodedBytes
        print("bytes decoded in full: \(decoded) of \(data.count); sources remembered: \(ledger.qaSeenCount)")
        // Every source is remembered, plus the restart row for the task still open.
        guard ledger.qaSeenCount == rows.count + 1 else {
            throw Failure(description: "remembered \(ledger.qaSeenCount) sources, expected \(rows.count + 1)")
        }
        let lines = try Data(contentsOf: url).split(separator: 10).count
        guard lines == rows.count + 1 else { throw Failure(description: "file has \(lines) rows, expected \(rows.count + 1)") }
        guard decoded < 50_000 else {
            throw Failure(description: "recovery decoded \(decoded) bytes of rows the reducer never reads")
        }
    }
}
