import Foundation
import Crypto
import GRDB
import ContinuumRevivedRelayProtocol

extension RelayStore {
    static func taskOwner(_ db: Database, instanceID: UUID) throws -> RelayNotificationOwnership? {
        guard let row = try Row.fetchOne(db, sql: "SELECT publisher_id,revision FROM notification_ownership WHERE instance_id=?", arguments: [instanceID.uuidString]),
              let publisher = UUID(uuidString: row["publisher_id"]) else { return nil }
        let revision: Int64 = row["revision"]
        return .init(publisherID: publisher, revision: UInt64(max(0, revision)))
    }
    public func taskNotificationOwner(instanceID: UUID) throws -> RelayNotificationOwnership? {
        try database.read { try Self.taskOwner($0, instanceID: instanceID) }
    }
    public func notificationOwnership(auth: RelayCredentialContext) throws -> RelayNotificationOwnershipResponse {
        guard auth.role == .desktop, auth.capabilities.contains(.publishState) else { throw RelayStoreError.forbidden }
        return try .init(owner: taskNotificationOwner(instanceID: auth.instanceID))
    }

    static func enqueueTaskBatch(_ db: Database, event: RelayEvent, instanceID: UUID, key: SymmetricKey, now: Date) throws -> [RelayOutboxTrace] {
        guard let batch = try? JSONDecoder().decode(RelayTaskBatch.self, from: event.payload) else {
            RelayNotificationOwnershipPath.invalidBatch.log(); throw RelayStoreError.invalidNotificationBatch
        }
        guard batch.revision <= UInt64(Int64.max), batch.tasks.count <= 512,
              batch.tasks.reduce(0, { $0 + $1.members.count }) <= 4096,
              Set(batch.tasks.map(\.taskID)).count == batch.tasks.count,
              Set(batch.tasks.flatMap { $0.members.map(\.runID) }).count == batch.tasks.reduce(0, { $0 + $1.members.count }) else {
            RelayNotificationOwnershipPath.invalidBatch.log()
            throw RelayStoreError.invalidNotificationBatch
        }
        let decisions = try batch.tasks.map { task -> RelayNotificationDecision in
            let decision = RelaySystemSurfaceProjection.evaluate(event: .init(kind: "task.state.v1", payload: try JSONEncoder().encode(task)), instanceID: instanceID)
            guard decision.path != .invalidTask, decision.projection != nil else { RelayNotificationOwnershipPath.invalidBatch.log(); throw RelayStoreError.invalidNotificationBatch }
            return decision
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = batch
        canonical.tasks.sort { $0.taskID.uuidString < $1.taskID.uuidString }
        for index in canonical.tasks.indices { canonical.tasks[index].members.sort { $0.runID.uuidString < $1.runID.uuidString } }
        let hash = Data(SHA256.hash(data: try encoder.encode(canonical)))
        let previous = try taskOwner(db, instanceID: instanceID)
        if let previous {
            guard previous.publisherID == batch.publisherID else { RelayNotificationOwnershipPath.publisherMismatch.log(); throw RelayStoreError.notificationOwnerMismatch }
            if batch.revision < previous.revision { RelayNotificationOwnershipPath.stale.log(); return [] }
            if batch.revision == previous.revision {
                let old = try Data.fetchOne(db, sql: "SELECT payload_hash FROM notification_ownership WHERE instance_id=?", arguments: [instanceID.uuidString])
                guard old == hash else { RelayNotificationOwnershipPath.revisionConflict.log(); throw RelayStoreError.notificationRevisionConflict }
            }
        }
        try db.execute(sql: """
            INSERT INTO notification_ownership(instance_id,publisher_id,revision,payload_hash) VALUES (?,?,?,?)
            ON CONFLICT(instance_id) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash
            """, arguments: [instanceID.uuidString, batch.publisherID.uuidString, Int64(batch.revision), hash])
        // Switching owners and dropping outstanding legacy intents are one commit.
        // The first full task snapshot is a quiet baseline, not a replay of history.
        var traces: [RelayOutboxTrace] = []
        let subjects = Set(batch.tasks.map { "task:\($0.taskID.uuidString)" })
        let pending = try Row.fetchAll(db, sql: "SELECT * FROM notification_outbox WHERE instance_id=?", arguments: [instanceID.uuidString])
        for row in pending where !subjects.contains(row["subject_key"] as String) {
            try closeOutbox(db, row: row, transition: .superseded, now: now)
            traces.append(trace(row, .superseded))
        }
        let registrations = try Row.fetchAll(db, sql: """
            SELECT p.id FROM push_registrations p JOIN instances i ON i.id=p.instance_id
            WHERE p.instance_id=? AND p.kind='apns' AND p.revoked_at IS NULL AND i.revoked_at IS NULL
              AND EXISTS (SELECT 1 FROM credentials c WHERE c.instance_id=p.instance_id AND c.device_id=p.device_id AND c.role='companion' AND c.revoked_at IS NULL)
            """, arguments: [instanceID.uuidString]).compactMap { UUID(uuidString: $0["id"]) }
        for (task, decision) in zip(batch.tasks, decisions) {
            let projection = decision.projection!
            traces += try supersedeOutbox(db, projection: projection, now: now, authoritativeRevision: true)
            // A recipient cohort belongs to the decision identity forever, not
            // merely until another state is selected. Otherwise unknown/recovery
            // could enroll a phone paired after an old completion was accepted.
            let prior = try Row.fetchOne(db, sql: "SELECT recipients FROM notification_task_decisions WHERE instance_id=? AND task_id=? AND decision_key=?",
                arguments: [instanceID.uuidString, task.taskID.uuidString, projection.notificationIdentity])
            let recipients: [UUID]
            if let prior {
                recipients = (try? JSONDecoder().decode([UUID].self, from: prior["recipients"])) ?? []
            } else { recipients = previous == nil ? [] : registrations }
            try db.execute(sql: """
                INSERT INTO notification_task_decisions(instance_id,task_id,decision_key,recipients) VALUES (?,?,?,?)
                ON CONFLICT(instance_id,task_id,decision_key) DO NOTHING
                """, arguments: [instanceID.uuidString, task.taskID.uuidString, projection.notificationIdentity, try JSONEncoder().encode(recipients)])
            guard let intent = try RelayOutboxIntent(projection: projection) else { continue }
            for registration in recipients where registrations.contains(registration) {
                traces.append(try enqueueOutbox(db, instanceID: instanceID, registrationID: registration, intent: intent,
                                               eventSequence: event.sequence, key: key, now: now).1)
            }
        }
        return traces
    }
}
