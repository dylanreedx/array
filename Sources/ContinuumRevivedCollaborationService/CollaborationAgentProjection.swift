import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

extension CollaborationStore {
    static func registerAgentProjectionMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-agent-projection") { db in
            try db.execute(sql: """
                CREATE TABLE collaboration_agent_projection(area TEXT NOT NULL REFERENCES areas(id), object TEXT NOT NULL,
                  host TEXT NOT NULL REFERENCES hosts(id), device TEXT NOT NULL REFERENCES devices(id), payload BLOB NOT NULL,
                  PRIMARY KEY(area,object));
                """)
        }
    }

    /// Only the registered device that publishes this agent observation, as its
    /// current owner, may extend its projection. The log enforces generation and
    /// sequence; a gap or newer generation without a snapshot is refused so the
    /// host resends state instead of the service inventing continuity.
    public func publishAgentProjection(token: String, area: UUID, object: SharedArea.ID<SharedArea.Object>,
                                       report: Collaboration.AgentProjection.PublishReport) throws {
        let batch = report.batch
        guard let host = batch.snapshot?.host ?? batch.frames.first?.host,
              batch.snapshot.map({ $0.object == object && $0.host == host }) ?? true,
              batch.frames.allSatisfy({ $0.object == object && $0.host == host }),
              batch.snapshot != nil || !batch.frames.isEmpty else { throw CollaborationStoreError.invalidRequest }
        try database.write { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.epoch == report.epoch else { throw CollaborationStoreError.staleEpoch }
            guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [host.rawValue.uuidString]) == identity.device.uuidString else {
                throw CollaborationStoreError.forbidden
            }
            let state: Data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
            let document = try unseal(SharedArea.Document.self, state)
            guard document.items.contains(where: { $0.id == object && $0.kind == .agentObservation
                    && $0.source?.host == host && $0.source?.owner == identity.person }) else {
                throw CollaborationStoreError.forbidden
            }
            var log: Collaboration.AgentProjection.Log
            if let row = try Row.fetchOne(db, sql: "SELECT host,payload FROM collaboration_agent_projection WHERE area=? AND object=?",
                                         arguments: [area.uuidString, object.rawValue.uuidString]),
               (row["host"] as String) == host.rawValue.uuidString {
                log = try unseal(Collaboration.AgentProjection.Log.self, row["payload"])
            } else {
                guard let snapshot = batch.snapshot else { throw CollaborationStoreError.invalidCursor }
                log = .init(snapshot: snapshot)
            }
            do { try log.publish(batch) }
            catch Collaboration.AgentProjection.Log.Failure.staleGeneration { throw SharedArea.Failure.conflict }
            catch Collaboration.AgentProjection.Log.Failure.apply { throw CollaborationStoreError.invalidCursor }
            catch { throw CollaborationStoreError.invalidRequest }
            try db.execute(sql: "INSERT INTO collaboration_agent_projection(area,object,host,device,payload) VALUES (?,?,?,?,?) ON CONFLICT(area,object) DO UPDATE SET host=excluded.host,device=excluded.device,payload=excluded.payload",
                arguments: [area.uuidString, object.rawValue.uuidString, host.rawValue.uuidString, identity.device.uuidString, try seal(log)])
        }
        // Projection frames have no durable operation; reuse the presence lane's
        // coalesced wake so held readers return and fetch the new frames.
        presenceChanged(area)
    }

    /// Any current member may read a projection that the area still publishes
    /// from that host. A cursor outside the retained window, or from another
    /// generation, gets an explicit resnapshot.
    public func readAgentProjection(token: String, area: UUID, object: SharedArea.ID<SharedArea.Object>,
                                    cursor: Collaboration.AgentProjection.Cursor?) throws -> Collaboration.AgentProjection.Read {
        try database.read { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.allows(.view) else { throw CollaborationStoreError.forbidden }
            let state: Data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
            let document = try unseal(SharedArea.Document.self, state)
            guard let source = document.items.first(where: { $0.id == object && $0.kind == .agentObservation })?.source,
                  let row = try Row.fetchOne(db, sql: "SELECT host,payload FROM collaboration_agent_projection WHERE area=? AND object=?",
                                             arguments: [area.uuidString, object.rawValue.uuidString]),
                  (row["host"] as String) == source.host.rawValue.uuidString else { throw CollaborationStoreError.unavailable }
            return try unseal(Collaboration.AgentProjection.Log.self, row["payload"]).read(after: cursor)
        }
    }

    /// Unpublished or re-hosted observations lose their retained projection.
    func refreshAgentProjectionAccess(_ db: Database, area: UUID, document: SharedArea.Document) throws {
        let live = Dictionary(document.items.compactMap { item in
            item.kind == .agentObservation ? item.source.map { (item.id.rawValue.uuidString, $0.host.rawValue.uuidString) } : nil
        }, uniquingKeysWith: { first, _ in first })
        for row in try Row.fetchAll(db, sql: "SELECT object,host FROM collaboration_agent_projection WHERE area=?", arguments: [area.uuidString]) {
            let object: String = row["object"], host: String = row["host"]
            if live[object] != host {
                try db.execute(sql: "DELETE FROM collaboration_agent_projection WHERE area=? AND object=?", arguments: [area.uuidString, object])
            }
        }
    }
}
