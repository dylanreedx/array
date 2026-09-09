import Foundation

/// Remembers the last account quota reading per harness across launches, so a
/// relaunched app shows real percentages instead of a row of em dashes.
///
/// This reverses an earlier call, and the reasoning is worth keeping. The first
/// version held quota in memory only, on the argument that a wall-clock
/// allowance goes wrong while the app is closed. That is true and it is not a
/// reason to discard the reading — it is a reason to CHECK it. A five-hour
/// window observed at 18% four minutes ago is still approximately 18%; the same
/// reading found after its `resets_at` has passed is worthless. So the window's
/// own stated reset is the validity test, and `restore` applies it:
///
/// - a window whose `resets_at` has passed is DROPPED, never shown as stale.
///   The provider itself drops such a window rather than restating it at zero.
/// - a window with no stated reset is dropped too. Without a reset instant
///   there is nothing to check it against, and an unbounded old percentage is
///   exactly the confidently-wrong number this ticket exists to avoid.
/// - what survives is presented as a real reading, because it is one, and the
///   next `rate_limit_event` replaces it within a turn.
///
/// Nothing here is a credential: it is a utilization fraction and a reset
/// instant. It lives beside the other app-level stores (channel-split, and
/// honouring `CONTINUUM_APP_SUPPORT`) because an account is app-scoped —
/// emphatically not in a project's `.array/`, which is shared across channels
/// and would leak one account's usage into another install.
public struct AgentAccountQuotaStore {
    private let fileURL: URL
    private let writer: AtomicWriter

    public init(applicationSupportDirectory: URL) {
        fileURL = applicationSupportDirectory
            .appendingPathComponent("account-quotas.json", isDirectory: false)
        writer = AtomicWriter(
            backupsDirectory: applicationSupportDirectory
                .appendingPathComponent("backups", isDirectory: true),
            retainedBackups: 1,
            legacyBackupPolicy: .targetDedicated)
    }

    private struct Payload: Codable {
        var snapshots: [AgentAccountQuotaSnapshot]
    }

    public func save(_ snapshots: [AgentHarness: AgentAccountQuotaSnapshot]) {
        // Sorted by harness so the file does not churn on dictionary order.
        let ordered = snapshots.keys.sorted { $0.rawValue < $1.rawValue }
            .compactMap { snapshots[$0] }
        try? writer.write(Payload(snapshots: ordered), to: fileURL)
    }

    /// Loads and VALIDATES. The `now` parameter is explicit so a check can pin
    /// the expiry arithmetic instead of racing a real clock.
    public func restore(now: Date) -> [AgentHarness: AgentAccountQuotaSnapshot] {
        // `JSONCodec.makeDecoder()`, not a bare `JSONDecoder`: the writer
        // encodes dates as ISO-8601 and a default decoder expects a numeric
        // interval, so the asymmetry silently restored nothing at all.
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONCodec.makeDecoder().decode(Payload.self, from: data)
        else { return [:] }

        var result: [AgentHarness: AgentAccountQuotaSnapshot] = [:]
        for var snapshot in payload.snapshots {
            snapshot.windows = snapshot.windows.filter { window in
                // A reading with no reset instant cannot be validated, and one
                // past its reset is no longer true. Both are dropped rather
                // than shown — the element then renders nothing at all, which
                // is what "we do not know" should look like.
                guard let resetsAt = window.resetsAt else { return false }
                return resetsAt > now
            }
            guard !snapshot.windows.isEmpty || !(snapshot.credits?.isEmpty ?? true) else { continue }
            result[snapshot.harness] = snapshot
        }
        return result
    }
}
