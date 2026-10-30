import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

extension CollaborationStore {
    static func registerUsageMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-v5-usage") { db in
            try db.execute(sql: """
                CREATE TABLE collaboration_usage(area TEXT NOT NULL REFERENCES areas(id), host TEXT NOT NULL REFERENCES hosts(id),
                  device TEXT NOT NULL REFERENCES devices(id), sequence INTEGER NOT NULL, payload BLOB NOT NULL,
                  PRIMARY KEY(area,host));
                """)
        }
    }

    /// The registered host reports cumulative accounting; a cursor frame never
    /// increments a total. Restarted/reordered reporters cannot double count.
    public func reportUsage(token: String, area: UUID, report: Collaboration.UsageReport) throws {
        guard report.snapshot.valid else { throw CollaborationStoreError.invalidRequest }
        let snapshot = report.snapshot
        try database.write { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.epoch == report.epoch else { throw CollaborationStoreError.staleEpoch }
            guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [snapshot.host.rawValue.uuidString]) == identity.device.uuidString else {
                throw CollaborationStoreError.forbidden
            }
            let state: Data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
            let document = try unseal(SharedArea.Document.self, state)
            guard document.items.contains(where: { $0.source?.host == snapshot.host && $0.source?.owner == identity.person }) else {
                throw CollaborationStoreError.forbidden
            }
            if let row = try Row.fetchOne(db, sql: "SELECT sequence,payload FROM collaboration_usage WHERE area=? AND host=?",
                                         arguments: [area.uuidString, snapshot.host.rawValue.uuidString]) {
                let sequence: Int64 = row["sequence"]
                if UInt64(sequence) > snapshot.sequence { return }
                let prior = try unseal(Collaboration.UsageSnapshot.self, row["payload"])
                if UInt64(sequence) == snapshot.sequence {
                    guard prior == snapshot else { throw CollaborationStoreError.invalidRequest }
                    return
                }
                guard snapshot.inputTokens >= prior.inputTokens, snapshot.outputTokens >= prior.outputTokens,
                      snapshot.observedSince == prior.observedSince else { throw CollaborationStoreError.invalidRequest }
            }
            try db.execute(sql: "INSERT INTO collaboration_usage(area,host,device,sequence,payload) VALUES (?,?,?,?,?) ON CONFLICT(area,host) DO UPDATE SET device=excluded.device,sequence=excluded.sequence,payload=excluded.payload",
                arguments: [area.uuidString, snapshot.host.rawValue.uuidString, identity.device.uuidString, Int64(snapshot.sequence), try seal(snapshot)])
        }
        presenceChanged(area)
    }

    func usageForPresence(_ db: Database, area: UUID, identity: Collaboration.Identity) throws -> Collaboration.UsageSnapshot? {
        let reports = try Row.fetchAll(db, sql: "SELECT u.payload FROM collaboration_usage u JOIN devices d ON d.id=u.device JOIN members m ON m.area=u.area AND m.person=d.person WHERE u.area=? AND u.device=? AND d.revoked=0 AND m.active=1 ORDER BY u.host",
                                      arguments: [area.uuidString, identity.device.uuidString]).map {
            try unseal(Collaboration.UsageSnapshot.self, $0["payload"])
        }
        guard let first = reports.first else { return nil }
        guard reports.count > 1 else { return first }
        // A device can have several registered hosts. Presence represents that
        // device, so do not silently select one host's independent sequence.
        let day = reports.map(\.dayUTC).max()!
        var input: UInt64 = 0, output: UInt64 = 0, todayInput: UInt64 = 0, todayOutput: UInt64 = 0
        var covered = 0, running = 0
        for report in reports {
            let (nextInput, a) = input.addingReportingOverflow(report.inputTokens)
            let (nextOutput, b) = output.addingReportingOverflow(report.outputTokens)
            guard !a, !b, nextInput <= UInt64(Int64.max), nextOutput <= UInt64(Int64.max) - nextInput,
                  covered <= 10_000 - report.coveredAgents, running <= 10_000 - report.runningAgents else {
                // Do not substitute a truncated plausible total for an invalid
                // aggregate; the hover card will say usage is unavailable.
                return nil
            }
            input = nextInput; output = nextOutput
            covered += report.coveredAgents; running += report.runningAgents
            if report.dayUTC == day {
                let (nextTodayInput, c) = todayInput.addingReportingOverflow(report.todayInputTokens)
                let (nextTodayOutput, d) = todayOutput.addingReportingOverflow(report.todayOutputTokens)
                guard !c, !d else { return nil }
                todayInput = nextTodayInput; todayOutput = nextTodayOutput
            }
        }
        return .init(host: first.host, sequence: reports.map(\.sequence).max()!, inputTokens: input, outputTokens: output,
            todayInputTokens: todayInput, todayOutputTokens: todayOutput, dayUTC: day,
            observedSince: reports.map(\.observedSince).min()!, measuredAt: reports.compactMap(\.measuredAt).max(),
            coveredAgents: covered, runningAgents: running,
            partial: reports.contains { $0.partial || $0.dayUTC != day })
    }

    func refreshUsageAccess(_ db: Database, area: UUID, document: SharedArea.Document) throws {
        let hosts = Set(document.items.compactMap { $0.source?.host.rawValue.uuidString })
        for row in try Row.fetchAll(db, sql: "SELECT host FROM collaboration_usage WHERE area=?", arguments: [area.uuidString]) {
            let host: String = row["host"]
            if !hosts.contains(host) {
                try db.execute(sql: "DELETE FROM collaboration_usage WHERE area=? AND host=?", arguments: [area.uuidString, host])
            }
        }
    }
}
