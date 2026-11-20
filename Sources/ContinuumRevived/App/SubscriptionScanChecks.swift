import ContinuumRevivedCore
import Foundation

/// Restore asked every lead to list its project's subscription directory and
/// search it. The witness: leads sharing one project cost ONE listing, and each
/// still gets exactly its own rows. RED with `CONTINUUM_LEGACY_SUBSCRIPTION_SCAN=1`.
enum SubscriptionScanChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.path
        let leads = (0..<40).map { _ in UUID() }
        var expected: [UUID: Set<String>] = [:]
        for (index, lead) in leads.enumerated() where index % 3 == 0 {
            for n in 0..<2 {
                let helper = UUID()
                let handle = "h\(index)-\(n)"
                try SpawnResultFile.saveSubscription(
                    .init(helper: helper, recipient: lead, handle: handle, baseline: Date(timeIntervalSince1970: 1_000)),
                    parentCwd: cwd)
                expected[lead, default: []].insert(handle)
            }
        }
        let before = SpawnResultFile.subscriptionListingsForQA
        let rows = SpawnResultFile.subscriptions(leads: leads.map { (cwd, $0) })
        let listings = SpawnResultFile.subscriptionListingsForQA - before
        print("directory listings for \(leads.count) leads in one project: \(listings)")
        for lead in leads {
            let got = Set((rows[lead] ?? []).map(\.handle))
            guard got == (expected[lead] ?? []) else {
                throw Failure(description: "lead \(lead) got \(got), expected \(expected[lead] ?? [])")
            }
        }
        guard listings == 1 else {
            throw Failure(description: "\(listings) directory listings for leads that share one project")
        }
    }
}
