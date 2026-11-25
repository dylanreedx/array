import ContinuumRevivedCore
import Foundation

/// The run ledger is replayed at every launch. One helperEvidence row can be
/// megabytes (Dylan's file is 1.4 GB in 595 of them), and nothing in the replay
/// reads them. The witness: a ledger with large evidence rows is recovered by
/// decoding only the rows the reducer reads, to the same remembered sources and
/// the same restart row. RED with `CONTINUUM_LEGACY_LEDGER_RECOVER=1`.
enum LedgerRecoverChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        if let support = ProcessInfo.processInfo.environment["CONTINUUM_LEDGER_RECOVER_TIMING"] {
            return try timing(URL(fileURLWithPath: support))
        }
        try recoverWitness()
        try compactionWitness()
    }

    static func recoverWitness() throws {
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

    /// Rows written before the writer stopped listing unattributed paths carry
    /// one `editNotObserved` fact per path git called changed. The first launch
    /// of the fixed app rewrites them once, through the production recover:
    /// the file shrinks, the helper's own facts and every other row survive,
    /// and the usage page and the reducer read the same tasks before and after.
    /// RED before the fix: nothing compacts.
    static func compactionWitness() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ledger-compact-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let lead = UUID(), task = UUID(), helper = UUID(), shared = UUID(), part = UUID()
        let epoch = Date(timeIntervalSinceReferenceDate: 786_000_000.123456)
        func row(_ kind: String, _ agent: UUID, _ source: String, _ seconds: Double) -> ManagedRunLedger.Row {
            var row = ManagedRunLedger.Row(kind: kind, task: task, agent: agent, source: source)
            row.at = epoch.addingTimeInterval(seconds)
            return row
        }
        var rows = [row("taskOpened", lead, "open/\(task)", 0)]
        var delegated = row("delegated", helper, "delegated/\(part)", 1); delegated.part = part
        rows.append(delegated)
        var usage = row("usage", lead, "usage/1", 2)
        usage.harness = "claude"; usage.model = "fixture/model"; usage.tokens = .init(uncachedInput: 1_234, cacheRead: 7, cacheWrite: 8, output: 56)
        rows.append(usage)
        let noise = (0..<20_000).map { HelperEvidence.FileFact(path: "noise/n\($0).swift", status: "editNotObserved", reasons: ["sharedCheckout"]) }
        var own = HelperEvidence.FileFact(path: "Sources/Own.swift", status: "unknown", reasons: ["checkWritesUnobserved", "sharedCheckout"])
        own.editCall = "t1"; own.editStart = 1; own.editEnd = 2; own.check = "python3 scripts/check-own.py"; own.exit = "unknown"
        for (n, agent) in [shared, helper].enumerated() {
            var evidence = row("helperEvidence", agent, "evidence/\(agent)/\(n)", 3 + Double(n))
            evidence.part = part
            evidence.files = [own] + noise
            evidence.evidence = ["observed": "sinceDelegation", "checkout": "shared", "changes": "git"]
            rows.append(evidence)
        }
        var clean = row("helperEvidence", helper, "evidence/\(helper)/clean", 5)
        clean.files = [own]; clean.evidence = ["changes": "git"]
        rows.append(clean)
        rows.append(row("reported", helper, "reported/\(part)", 6))
        rows.append(row("taskClosed", lead, "closed/\(task)", 7))
        let encoder = JSONEncoder()
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(10) }
        let torn = Data(#"{"v":1,"kind":"usage","tas"#.utf8)
        data.append(torn)

        func ledgerCopy(_ name: String) throws -> (support: URL, file: URL) {
            let support = root.appendingPathComponent(name), dir = support.appendingPathComponent("run-ledger")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("ledger.jsonl")
            try data.write(to: file)
            return (support, file)
        }
        func launch(_ support: URL, skip: Bool) -> ManagedRunLedger {
            ManagedRunLedger.qaSkipCompaction = skip
            defer { ManagedRunLedger.qaSkipCompaction = false }
            let ledger = ManagedRunLedger(support: support)
            ledger.drain()
            return ledger
        }
        // Before: the code as it was, on one copy.
        let before = try ledgerCopy("before")
        let old = launch(before.support, skip: true)
        let oldUsage = RunLedgerUsageReader.read(try Data(contentsOf: before.file))
        // After: the production recover, on another, with a temp file a quit mid-way left behind.
        let after = try ledgerCopy("after")
        try Data("partial".utf8).write(to: after.file.deletingLastPathComponent().appendingPathComponent("ledger.jsonl.compacting"))
        let new = launch(after.support, skip: false)
        let compacted = try Data(contentsOf: after.file)
        let newUsage = RunLedgerUsageReader.read(compacted)
        print("compaction: \(data.count) -> \(compacted.count) bytes, rows rewritten \(new.qaCompaction?.rows ?? 0)")
        guard let done = new.qaCompaction, done.rows == 2, compacted.count * 20 < data.count else {
            throw Failure(description: "fixture ledger not compacted: \(data.count) -> \(compacted.count), \(String(describing: new.qaCompaction))")
        }
        guard compacted.range(of: Data("editNotObserved".utf8)) == nil, compacted.range(of: Data("noise/".utf8)) == nil else {
            throw Failure(description: "compacted ledger still lists unattributed paths")
        }
        guard compacted.suffix(torn.count) == torn else { throw Failure(description: "the torn final append was not kept") }
        guard !fm.fileExists(atPath: after.file.path + ".compacting") else { throw Failure(description: "temporary file left behind") }
        let lines = compacted.split(separator: 10).dropLast()
        guard lines.count == rows.count else { throw Failure(description: "compacted ledger has \(lines.count) rows, expected \(rows.count)") }
        let decoder = JSONDecoder()
        let originalLines = data.split(separator: 10).dropLast()
        for ((line, original), originalLine) in zip(zip(lines, rows), originalLines) {
            let decoded = try decoder.decode(ManagedRunLedger.Row.self, from: Data(line))
            guard decoded.source == original.source, decoded.kind == original.kind, decoded.at == original.at,
                  decoded.files?.first == original.files?.first, decoded.part == original.part else {
                throw Failure(description: "row \(original.source) changed beyond its unattributed facts")
            }
            if original.files?.count ?? 0 > 1 {
                guard decoded.files == [own], decoded.evidence?["otherChangedFiles"] == "20000" else {
                    throw Failure(description: "row \(original.source) lost its own facts or the count: \(String(describing: decoded.evidence))")
                }
            } else if line != originalLine {
                throw Failure(description: "row \(original.source) was rewritten though it needed nothing")
            }
        }
        guard newUsage == oldUsage, !newUsage.tasks.isEmpty, newUsage.tasks[0].usage.count == 1 else {
            throw Failure(description: "the usage page reads different tasks after compaction")
        }
        guard new.qaSeenCount == old.qaSeenCount, new.qaSeenCount == rows.count else {
            throw Failure(description: "recover remembered \(new.qaSeenCount) sources after, \(old.qaSeenCount) before")
        }
        // The next launch does not rerun it, even over a file that would need it.
        try data.write(to: after.file)
        let again = launch(after.support, skip: false)
        guard again.qaCompaction == nil, try Data(contentsOf: after.file) == data else {
            throw Failure(description: "compaction reran on a ledger already marked")
        }
        print("compaction witness passed: \(rows.count) rows, same usage and sources before and after")
    }

    /// `CONTINUUM_LEDGER_RECOVER_TIMING=<support dir>`: times the production
    /// recover over a copied ledger, before compaction, compacting, and after.
    /// Prints only; never point it at a live app's directory.
    static func timing(_ support: URL) throws {
        let file = support.appendingPathComponent("run-ledger/ledger.jsonl")
        func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1 }
        func time(_ label: String, skip: Bool) {
            ManagedRunLedger.qaSkipCompaction = skip
            defer { ManagedRunLedger.qaSkipCompaction = false }
            let start = DispatchTime.now().uptimeNanoseconds
            let ledger = ManagedRunLedger(support: support)
            ledger.drain()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            print("\(label): \(Int(ms)) ms, \(size()) bytes, sources \(ledger.qaSeenCount), compacted rows \(ledger.qaCompaction?.rows ?? 0)")
        }
        time("recover before compaction", skip: true)
        time("first launch (compaction + recover)", skip: false)
        time("recover after compaction", skip: false)
    }
}
