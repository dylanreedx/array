import Crypto
import Foundation
import GRDB
import ContinuumRevivedRelayProtocol

extension RelayStore {
    private static func outboxAAD(instanceID: UUID, registrationID: UUID, decisionID: String) -> Data {
        Data("\(instanceID.uuidString)|\(registrationID.uuidString)|\(decisionID)".utf8)
    }
    // Alias q is the candidate outbox row. Credentials, instance and token must
    // still be live; possession of a historical registration row is insufficient.
    private static let outboxAuthority = """
        EXISTS (SELECT 1 FROM push_registrations p JOIN instances i ON i.id=p.instance_id
          WHERE p.id=q.registration_id AND p.instance_id=q.instance_id AND p.kind='apns'
            AND p.revoked_at IS NULL AND i.revoked_at IS NULL
            AND EXISTS (SELECT 1 FROM credentials c WHERE c.instance_id=p.instance_id
              AND c.device_id=p.device_id AND c.role='companion' AND c.revoked_at IS NULL))
        """

    static func enqueueOutbox(_ db: Database, instanceID: UUID, registrationID: UUID, intent: RelayOutboxIntent,
                              eventSequence: Int64, key: SymmetricKey, now: Date) throws -> (RelayOutboxEnqueueResult, RelayOutboxTrace) {
        let arguments: StatementArguments = [registrationID.uuidString, intent.decisionID]
        let closed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notification_claims WHERE registration_id=? AND decision_key=? AND (accepted_at IS NOT NULL OR disposition IS NOT NULL))", arguments: arguments) ?? false
        let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notification_outbox WHERE registration_id=? AND decision_key=?)", arguments: arguments) ?? false
        let result: RelayOutboxEnqueueResult
        let transition: RelayOutboxTrace.Transition
        if closed || pending { result = closed ? .deduplicated : .pending; transition = .deduplicated }
        else if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notification_outbox WHERE instance_id=?", arguments: [instanceID.uuidString]) ?? 0 >= RelayOutboxPolicy.maximumPendingPerInstance {
            result = .capacityRejected; transition = .capacityRejected
        } else {
            let sealed = try AES.GCM.seal(JSONEncoder().encode(intent), using: key,
                authenticating: outboxAAD(instanceID: instanceID, registrationID: registrationID, decisionID: intent.decisionID)).combined!
            try db.execute(sql: """
                INSERT INTO notification_outbox(registration_id,decision_key,instance_id,event_sequence,decision_path,subject_key,sealed_intent,created_at,expires_at,next_attempt_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [registrationID.uuidString, intent.decisionID, instanceID.uuidString, eventSequence,
                                   intent.path.rawValue, intent.subject, sealed, now.timeIntervalSince1970,
                                   now.addingTimeInterval(RelayOutboxPolicy.maximumAge).timeIntervalSince1970, now.timeIntervalSince1970])
            result = .queued; transition = .queued
        }
        return (result, .init(path: transition, decisionPath: intent.path, instanceID: instanceID, registrationID: registrationID,
                             decisionID: intent.decisionID, eventSequence: eventSequence, attempt: 0, statusCode: nil))
    }

    /// Called inside publish's event transaction, before any fanout or APNs task.
    static func enqueuePublishedAlerts(_ db: Database, event: RelayEvent, instanceID: UUID, key: SymmetricKey, now: Date) throws -> [RelayOutboxTrace] {
        if event.kind == "task.batch.v1" { return try enqueueTaskBatch(db, event: event, instanceID: instanceID, key: key, now: now) }
        if event.kind == "sync.message", try taskOwner(db, instanceID: instanceID) != nil { return [] }
        guard let projection = RelaySystemSurfaceProjection.project(event: event, instanceID: instanceID) else {
            guard let subject = RelaySystemSurfaceProjection.rejectedOutboxSubject(event: event) else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM notification_outbox WHERE instance_id=? AND subject_key=?", arguments: [instanceID.uuidString, subject])
            return try rows.map { row in
                try closeOutbox(db, row: row, transition: .superseded, now: now)
                return trace(row, .superseded)
            }
        }
        var traces = try supersedeOutbox(db, projection: projection, now: now)
        guard projection.notification != nil else { return traces }
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.id FROM push_registrations p JOIN instances i ON i.id=p.instance_id
            WHERE p.instance_id=? AND p.kind='apns' AND p.revoked_at IS NULL AND i.revoked_at IS NULL
              AND EXISTS (SELECT 1 FROM credentials c WHERE c.instance_id=p.instance_id AND c.device_id=p.device_id
                AND c.role='companion' AND c.revoked_at IS NULL)
            """, arguments: [instanceID.uuidString])
        traces += try rows.compactMap { row in
            guard let registrationID = UUID(uuidString: row["id"]) else { return nil }
            guard let intent = try? RelayOutboxIntent(projection: projection) else {
                return .init(path: .preparationFailure, decisionPath: projection.notification!.path, instanceID: instanceID,
                             registrationID: registrationID, decisionID: projection.notificationIdentity,
                             eventSequence: event.sequence, attempt: 0, statusCode: nil)
            }
            return try enqueueOutbox(db, instanceID: instanceID, registrationID: registrationID, intent: intent,
                                     eventSequence: event.sequence, key: key, now: now).1
        }
        return traces
    }

    static func supersedeOutbox(_ db: Database, projection: RelaySystemSurfaceProjection, now: Date, authoritativeRevision: Bool = false) throws -> [RelayOutboxTrace] {
        let old = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notification_claims c JOIN push_registrations p ON p.id=c.registration_id WHERE p.instance_id=? AND c.decision_key=? AND c.disposition IS NOT NULL)",
                                   arguments: [projection.instanceID.uuidString, projection.notificationIdentity]) ?? false
        // An already-closed source event being republished cannot cancel newer
        // pending attention. Fresh observations otherwise follow publish order.
        // A validated newer task batch proves current state even if this terminal
        // identity was accepted earlier. It must still cancel obsolete attention.
        guard authoritativeRevision || !old else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM notification_outbox WHERE instance_id=? AND subject_key=? AND decision_key<>?",
                                   arguments: [projection.instanceID.uuidString, projection.outboxSubject, projection.notificationIdentity])
        return try rows.map { row in
            try closeOutbox(db, row: row, transition: .superseded, now: now)
            return trace(row, .superseded)
        }
    }

    public func supersedeAlerts(projection: RelaySystemSurfaceProjection, now: Date = .init()) throws {
        let traces = try database.write { try Self.supersedeOutbox($0, projection: projection, now: now) }
        traces.forEach(outboxTrace)
    }

    public func existingAlert(registrationID: UUID, decisionID: String) throws -> RelayOutboxEnqueueResult {
        try database.read { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notification_outbox WHERE registration_id=? AND decision_key=?)", arguments: [registrationID.uuidString, decisionID]) ?? false { return .pending }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notification_claims WHERE registration_id=? AND decision_key=? AND (disposition IS NOT NULL OR accepted_at IS NOT NULL))", arguments: [registrationID.uuidString, decisionID]) ?? false { return .deduplicated }
            return .suppressed
        }
    }

    public func enqueueAlert(projection: RelaySystemSurfaceProjection, eventSequence: Int64, registrationID: UUID,
                             now: Date = .init()) throws -> RelayOutboxEnqueueResult {
        guard let intent = try RelayOutboxIntent(projection: projection) else { return .suppressed }
        let result = try database.write { db -> (RelayOutboxEnqueueResult, RelayOutboxTrace)? in
            let active = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM (SELECT id AS registration_id,instance_id FROM push_registrations) q
                  WHERE q.registration_id=? AND q.instance_id=? AND \(Self.outboxAuthority))
                """, arguments: [registrationID.uuidString, projection.instanceID.uuidString]) ?? false
            guard active else { return nil }
            return try Self.enqueueOutbox(db, instanceID: projection.instanceID, registrationID: registrationID,
                                          intent: intent, eventSequence: eventSequence, key: encryptionKey, now: now)
        }
        if let result { outboxTrace(result.1); return result.0 }
        return .suppressed
    }

    public func pendingAlertCount(instanceID: UUID) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notification_outbox WHERE instance_id=?", arguments: [instanceID.uuidString]) ?? 0 }
    }

    static func trace(_ row: Row, _ transition: RelayOutboxTrace.Transition, status: Int? = nil) -> RelayOutboxTrace {
        .init(path: transition, decisionPath: RelayNotificationPath(rawValue: row["decision_path"]) ?? .unprojectable,
              instanceID: UUID(uuidString: row["instance_id"])!, registrationID: UUID(uuidString: row["registration_id"])!,
              decisionID: row["decision_key"], eventSequence: row["event_sequence"], attempt: row["attempts"], statusCode: status)
    }

    static func closeOutbox(_ db: Database, row: Row, transition: RelayOutboxTrace.Transition, now: Date) throws {
        let accepted: Double? = transition == .accepted ? now.timeIntervalSince1970 : nil
        try db.execute(sql: """
            INSERT INTO notification_claims(registration_id,decision_key,claim_id,claimed_at,accepted_at,disposition)
            VALUES (?,?,?,?,?,?) ON CONFLICT(registration_id,decision_key) DO UPDATE SET
              claim_id=excluded.claim_id,claimed_at=excluded.claimed_at,accepted_at=excluded.accepted_at,disposition=excluded.disposition
            WHERE notification_claims.disposition IS NULL
            """, arguments: [row["registration_id"] as String, row["decision_key"] as String, UUID().uuidString,
                               now.timeIntervalSince1970, accepted, transition.rawValue])
        try db.execute(sql: "DELETE FROM notification_outbox WHERE registration_id=? AND decision_key=?",
                       arguments: [row["registration_id"] as String, row["decision_key"] as String])
    }

    /// Database leases fence concurrent workers and survive a process exiting
    /// mid-attempt. Completed identities remain compact tombstones; payloads go.
    public func claimNextAlert(now: Date = .init(), instanceID: UUID? = nil) throws -> RelayOutboxClaim? {
        let result = try database.write { db -> (RelayOutboxClaim?, [RelayOutboxTrace]) in
            var traces: [RelayOutboxTrace] = []
            for _ in 0..<RelayOutboxPolicy.batchLimit {
                let scope = instanceID.map { _ in "AND q.instance_id=?" } ?? ""
                var args: StatementArguments = [now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970]
                if let instanceID { args += [instanceID.uuidString] }
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT q.*, \(Self.outboxAuthority) AS authorized FROM notification_outbox q
                    LEFT JOIN notification_backoff b ON b.registration_id=q.registration_id
                    WHERE (q.lease_until IS NULL OR q.lease_until<=?)
                      AND ((q.next_attempt_at<=? AND COALESCE(b.not_before,0)<=?) OR q.expires_at<=? OR NOT \(Self.outboxAuthority)) \(scope)
                    ORDER BY q.next_attempt_at,q.registration_id,q.decision_key LIMIT 1
                    """, arguments: args) else { return (nil, traces) }
                let registration: String = row["registration_id"], decision: String = row["decision_key"]
                let old = try Row.fetchOne(db, sql: "SELECT disposition,accepted_at,claimed_at FROM notification_claims WHERE registration_id=? AND decision_key=?", arguments: [registration, decision])
                if let old {
                    let disposition: String? = old["disposition"], accepted: Double? = old["accepted_at"]
                    if disposition != nil || accepted != nil {
                        try db.execute(sql: "DELETE FROM notification_outbox WHERE registration_id=? AND decision_key=?", arguments: [registration, decision])
                        traces.append(Self.trace(row, .deduplicated)); continue
                    }
                    let claimed: Double = old["claimed_at"]
                    if claimed + RelayOutboxPolicy.leaseDuration > now.timeIntervalSince1970 {
                        // An older sender holds the shared identity claim. Defer
                        // this row so it cannot starve other due recipients.
                        try db.execute(sql: "UPDATE notification_outbox SET next_attempt_at=? WHERE registration_id=? AND decision_key=?",
                                       arguments: [claimed + RelayOutboxPolicy.leaseDuration, registration, decision])
                        return (nil, traces)
                    }
                }
                let expiry: Double = row["expires_at"], attempts: Int = row["attempts"], authorized: Bool = row["authorized"]
                let closed: RelayOutboxTrace.Transition? = !authorized ? .revoked : (expiry <= now.timeIntervalSince1970 ? .expired : (attempts >= RelayOutboxPolicy.maximumAttempts ? .exhausted : nil))
                if let closed { try Self.closeOutbox(db, row: row, transition: closed, now: now); traces.append(Self.trace(row, closed)); continue }
                let intent: RelayOutboxIntent
                do {
                    let sealed: Data = row["sealed_intent"]
                    intent = try JSONDecoder().decode(RelayOutboxIntent.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: encryptionKey,
                        authenticating: Self.outboxAAD(instanceID: UUID(uuidString: row["instance_id"])!, registrationID: UUID(uuidString: registration)!, decisionID: decision)))
                } catch {
                    try Self.closeOutbox(db, row: row, transition: .preparationFailure, now: now)
                    traces.append(Self.trace(row, .preparationFailure)); continue
                }
                let lease = UUID()
                try db.execute(sql: "UPDATE notification_outbox SET attempts=attempts+1,lease_id=?,lease_until=? WHERE registration_id=? AND decision_key=?",
                               arguments: [lease.uuidString, now.addingTimeInterval(RelayOutboxPolicy.leaseDuration).timeIntervalSince1970, registration, decision])
                try db.execute(sql: """
                    INSERT INTO notification_claims(registration_id,decision_key,claim_id,claimed_at) VALUES (?,?,?,?)
                    ON CONFLICT(registration_id,decision_key) DO UPDATE SET claim_id=excluded.claim_id,claimed_at=excluded.claimed_at
                    """, arguments: [registration, decision, lease.uuidString, now.timeIntervalSince1970])
                let claim = RelayOutboxClaim(instanceID: UUID(uuidString: row["instance_id"])!, registrationID: UUID(uuidString: registration)!,
                    decisionID: decision, eventSequence: row["event_sequence"], attempt: attempts + 1,
                    expiresAt: Date(timeIntervalSince1970: expiry), leaseID: lease, intent: intent)
                traces.append(.init(path: .leased, decisionPath: intent.path, instanceID: claim.instanceID, registrationID: claim.registrationID,
                                    decisionID: decision, eventSequence: claim.eventSequence, attempt: attempts + 1, statusCode: nil))
                return (claim, traces)
            }
            return (nil, traces)
        }
        result.1.forEach(outboxTrace)
        return result.0
    }

    /// Re-read authority and current token after taking the lease, immediately
    /// before signing/sending. Token material is never persisted in the intent.
    public func prepareAlertRecipient(_ claim: RelayOutboxClaim, now: Date = .init()) throws -> RelayOutboxRecipient? {
        let result = try database.write { db -> (RelayOutboxRecipient?, RelayOutboxTrace?) in
            guard let row = try Row.fetchOne(db, sql: "SELECT q.*, \(Self.outboxAuthority) AS authorized FROM notification_outbox q WHERE q.registration_id=? AND q.decision_key=? AND q.lease_id=? AND q.lease_until>?",
                arguments: [claim.registrationID.uuidString, claim.decisionID, claim.leaseID.uuidString, now.timeIntervalSince1970]) else { return (nil, nil) }
            let authorized: Bool = row["authorized"], expires: Double = row["expires_at"]
            if !authorized || expires <= now.timeIntervalSince1970 {
                let why: RelayOutboxTrace.Transition = authorized ? .expired : .revoked
                try Self.closeOutbox(db, row: row, transition: why, now: now)
                return (nil, Self.trace(row, why))
            }
            if let until = try Double.fetchOne(db, sql: "SELECT not_before FROM notification_backoff WHERE registration_id=?", arguments: [claim.registrationID.uuidString]), until > now.timeIntervalSince1970 {
                // Another in-flight alert learned a provider cooldown after we
                // took this lease. No request began, so return the unused slot.
                try db.execute(sql: "UPDATE notification_outbox SET lease_id=NULL,lease_until=NULL,attempts=MAX(0,attempts-1),next_attempt_at=MAX(next_attempt_at,?) WHERE registration_id=? AND decision_key=?",
                               arguments: [until, claim.registrationID.uuidString, claim.decisionID])
                try db.execute(sql: "DELETE FROM notification_claims WHERE registration_id=? AND decision_key=? AND claim_id=? AND disposition IS NULL",
                               arguments: [claim.registrationID.uuidString, claim.decisionID, claim.leaseID.uuidString])
                return (nil, Self.trace(row, .retryScheduled))
            }
            guard let recipient = try Row.fetchOne(db, sql: "SELECT device_id,sealed_token FROM push_registrations WHERE id=?", arguments: [claim.registrationID.uuidString]) else { return (nil, nil) }
            do {
                let sealed: Data = recipient["sealed_token"]
                let token = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: encryptionKey)
                return (.init(registration: .init(id: claim.registrationID, deviceID: UUID(uuidString: recipient["device_id"])!, kind: .apns, token: token), generation: sealed), nil)
            } catch {
                try Self.closeOutbox(db, row: row, transition: .preparationFailure, now: now)
                return (nil, Self.trace(row, .preparationFailure))
            }
        }
        if let trace = result.1 { outboxTrace(trace) }
        return result.0
    }

    public func finishAlertAttempt(_ claim: RelayOutboxClaim, recipient: RelayOutboxRecipient, statusCode: Int?,
                                   retryAfter: TimeInterval? = nil, now: Date = .init()) throws {
        let trace = try database.write { db -> RelayOutboxTrace in
            guard let row = try Row.fetchOne(db, sql: "SELECT q.*, \(Self.outboxAuthority) AS authorized FROM notification_outbox q WHERE q.registration_id=? AND q.decision_key=? AND q.lease_id=? AND q.lease_until>?",
                arguments: [claim.registrationID.uuidString, claim.decisionID, claim.leaseID.uuidString, now.timeIntervalSince1970]) else {
                return .init(path: .staleLease, decisionPath: claim.intent.path, instanceID: claim.instanceID, registrationID: claim.registrationID,
                             decisionID: claim.decisionID, eventSequence: claim.eventSequence, attempt: claim.attempt, statusCode: statusCode)
            }
            if statusCode == 410 {
                // A delayed response for an old token cannot revoke a fresh one.
                try db.execute(sql: "UPDATE push_registrations SET revoked_at=? WHERE id=? AND sealed_token=?",
                               arguments: [now.timeIntervalSince1970, claim.registrationID.uuidString, recipient.generation])
            }
            let authorized: Bool = row["authorized"]
            let transition: RelayOutboxTrace.Transition
            if statusCode == 200 { transition = .accepted }
            else if !authorized { transition = .revoked }
            else if let delay = RelayOutboxPolicy.retryDelay(attempt: claim.attempt, statusCode: statusCode, retryAfter: retryAfter) {
                // Cooldown belongs to the recipient, not only this source
                // identity. Fresh events cannot bypass provider/network backoff.
                try db.execute(sql: """
                    INSERT INTO notification_backoff(registration_id,not_before) VALUES (?,?)
                    ON CONFLICT(registration_id) DO UPDATE SET not_before=MAX(not_before,excluded.not_before)
                    """, arguments: [claim.registrationID.uuidString, now.addingTimeInterval(delay).timeIntervalSince1970])
                if claim.attempt >= RelayOutboxPolicy.maximumAttempts { transition = .exhausted }
                else if now.addingTimeInterval(delay) >= claim.expiresAt { transition = .expired }
                else {
                    try db.execute(sql: "UPDATE notification_outbox SET lease_id=NULL,lease_until=NULL,next_attempt_at=? WHERE registration_id=? AND decision_key=?",
                                   arguments: [now.addingTimeInterval(delay).timeIntervalSince1970, claim.registrationID.uuidString, claim.decisionID])
                    try db.execute(sql: "DELETE FROM notification_claims WHERE registration_id=? AND decision_key=? AND claim_id=? AND disposition IS NULL AND accepted_at IS NULL",
                                   arguments: [claim.registrationID.uuidString, claim.decisionID, claim.leaseID.uuidString])
                    return Self.trace(row, .retryScheduled, status: statusCode)
                }
            } else { transition = .permanentFailure }
            try Self.closeOutbox(db, row: row, transition: transition, now: now)
            return Self.trace(row, transition, status: statusCode)
        }
        outboxTrace(trace)
    }
}
