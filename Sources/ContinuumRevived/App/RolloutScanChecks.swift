import ContinuumRevivedCore
import Foundation

/// Restore reads each Codex agent's rollout tail on the main thread at boot.
/// The witness is how many lines the scan has to look at to find the newest
/// token_count, and that the answer is the same one the old full split gave.
/// RED with `CONTINUUM_LEGACY_ROLLOUT_SCAN=1`, GREEN without.
enum RolloutScanChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func tokenLine(_ used: Int) -> String {
        "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(used),\"input_tokens\":\(used - 10),\"output_tokens\":10},\"model_context_window\":200000}}}"
    }

    static func run() throws {
        let filler = "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"" + String(repeating: "x", count: 100) + "\"}}"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ text: String) throws -> URL {
            let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func used(_ url: URL) -> Int? {
            CodexRolloutTelemetry.latestSnapshot(in: url, afterOffset: 0, freshness: .stale)?.usedTokens
        }
        // 1. A rollout of about 8 MB with the newest reading a few lines from the end.
        let big = try write(
            tokenLine(111) + "\n" + Array(repeating: filler, count: 50_000).joined(separator: "\n")
            + "\n" + tokenLine(4242) + "\n" + filler + "\n" + filler + "\n")
        let before = CodexRolloutTelemetry.linesExaminedForQA
        guard used(big) == 4242 else { throw Failure(description: "the newest reading was not found: \(String(describing: used(big)))") }
        let examined = CodexRolloutTelemetry.linesExaminedForQA - before
        print("lines examined for one 8 MB rollout: \(examined)")
        guard examined <= 100 else {
            throw Failure(description: "restore examined \(examined) lines to find a reading 3 lines from the end")
        }
        // 2. An incomplete last line is never a candidate, even if it names token_count.
        let partial = try write(tokenLine(7) + "\n" + filler + "\n" + String(tokenLine(9).dropLast(30)))
        guard used(partial) == 7 else { throw Failure(description: "an incomplete last line was used: \(String(describing: used(partial)))") }
        // 3. No reading at all.
        guard used(try write(filler + "\n" + filler + "\n")) == nil else { throw Failure(description: "found a reading in a file with none") }
        // 4. A newer reading wins over an older one.
        guard used(try write(tokenLine(1) + "\n" + tokenLine(2) + "\n" + filler + "\n")) == 2 else {
            throw Failure(description: "an older reading won")
        }
    }
}
