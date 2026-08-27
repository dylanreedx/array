import Crypto
import Foundation
import GRDB
import ContinuumRevivedRelayProtocol

public enum RelayStoreError: Error, Equatable {
    case unauthorized, forbidden, invalidOrExpiredCode, payloadTooLarge, invalidCommand
}

public struct RelayCredentialContext: Sendable, Equatable {
    public var credentialID: UUID; public var instanceID: UUID; public var role: RelayCredentialRole
    public var capabilities: Set<RelayCapability>; public var deviceID: UUID?
}
public struct RelayAdminInstance: Sendable, Equatable {
    public var id: UUID; public var label: String; public var createdAt: Date; public var revokedAt: Date?; public var devices: [RelayDevice]
}
public struct RelayStoredPushRegistration: Sendable, Equatable {
    public var id: UUID; public var deviceID: UUID; public var kind: RelayPushRegistrationKind; public var token: Data
}

/// Durable, per-Mac relay state. All mutations are transactions and all externally
/// supplied secrets are reduced to SHA-256 digests before storage.
public actor RelayStore {
    public static let schemaVersion = 1
    private let database: DatabaseQueue
    private let encryptionKey: SymmetricKey
    private let eventTailLimit: Int

    public init(path: String, masterKey: Data, eventTailLimit: Int = 2_000) throws {
        guard masterKey.count >= 32 else { throw RelayStoreError.unauthorized }
        database = try DatabaseQueue(path: path)
        // Deployment recovery material may be any high-entropy value of at least
        // 32 bytes. Normalize it to AES-256 instead of passing a non-AES key length
        // through to Crypto (which fails only when the first token is registered).
        encryptionKey = SymmetricKey(data: Data(SHA256.hash(data: masterKey)))
        self.eventTailLimit = max(100, eventTailLimit)
        try Self.migrator.migrate(database)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("relay-v1") { db in
            try db.execute(sql: """
                CREATE TABLE relay_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                INSERT INTO relay_metadata(key,value) VALUES ('schema_version','1');
                CREATE TABLE alpha_invites (
                  id TEXT PRIMARY KEY NOT NULL, code_hash BLOB UNIQUE NOT NULL,
                  expires_at DOUBLE NOT NULL, consumed_at DOUBLE
                );
                CREATE TABLE instances (
                  id TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL, created_at DOUBLE NOT NULL,
                  revoked_at DOUBLE, next_sequence INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE credentials (
                  id TEXT PRIMARY KEY NOT NULL, instance_id TEXT NOT NULL REFERENCES instances(id) ON DELETE CASCADE,
                  token_hash BLOB UNIQUE NOT NULL, role TEXT NOT NULL, capabilities TEXT NOT NULL,
                  device_id TEXT, device_label TEXT NOT NULL, created_at DOUBLE NOT NULL,
                  last_seen_at DOUBLE, revoked_at DOUBLE
                );
                CREATE INDEX credentials_instance ON credentials(instance_id);
                CREATE TABLE pairing_grants (
                  id TEXT PRIMARY KEY NOT NULL, instance_id TEXT NOT NULL REFERENCES instances(id) ON DELETE CASCADE,
                  code_hash BLOB UNIQUE NOT NULL, device_label TEXT NOT NULL, expires_at DOUBLE NOT NULL,
                  consumed_at DOUBLE, cancelled_at DOUBLE
                );
                CREATE TABLE relay_events (
                  instance_id TEXT NOT NULL REFERENCES instances(id) ON DELETE CASCADE,
                  sequence INTEGER NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL,
                  is_snapshot INTEGER NOT NULL DEFAULT 0, created_at DOUBLE NOT NULL,
                  PRIMARY KEY(instance_id, sequence)
                );
                CREATE TABLE commands (
                  instance_id TEXT NOT NULL REFERENCES instances(id) ON DELETE CASCADE,
                  idempotency_key TEXT NOT NULL, device_id TEXT, kind TEXT NOT NULL, agent_id TEXT NOT NULL,
                  accepted INTEGER NOT NULL, created_at DOUBLE NOT NULL,
                  PRIMARY KEY(instance_id, idempotency_key)
                );
                CREATE TABLE push_registrations (
                  id TEXT PRIMARY KEY NOT NULL, instance_id TEXT NOT NULL REFERENCES instances(id) ON DELETE CASCADE,
                  device_id TEXT NOT NULL, kind TEXT NOT NULL, sealed_token BLOB NOT NULL,
                  created_at DOUBLE NOT NULL, revoked_at DOUBLE,
                  UNIQUE(device_id, kind)
                );
                CREATE TABLE device_preferences (
                  device_id TEXT PRIMARY KEY NOT NULL, json BLOB NOT NULL, updated_at DOUBLE NOT NULL
                );
                CREATE TABLE rate_limits (
                  bucket TEXT PRIMARY KEY NOT NULL, window_started_at DOUBLE NOT NULL, count INTEGER NOT NULL
                );
                """)
        }
        return migrator
    }

    public func health() throws -> RelayHealth {
        try database.read { db in
            _ = try String.fetchOne(db, sql: "SELECT value FROM relay_metadata WHERE key='schema_version'")
            return RelayHealth(schemaVersion: Self.schemaVersion)
        }
    }

    public func adminOverview() throws -> [RelayAdminInstance] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id,label,created_at,revoked_at FROM instances ORDER BY created_at DESC").compactMap { instance in
                guard let id = UUID(uuidString: instance["id"]) else { return nil }
                let revoked: Double? = instance["revoked_at"]
                let devices = try Row.fetchAll(db, sql: "SELECT id,device_label,last_seen_at,capabilities FROM credentials WHERE instance_id=? AND role='companion' AND revoked_at IS NULL ORDER BY created_at", arguments: [id.uuidString]).compactMap { row -> RelayDevice? in
                    guard let deviceID = UUID(uuidString: row["id"]) else { return nil }
                    let seen: Double? = row["last_seen_at"], raw: String = row["capabilities"]
                    return RelayDevice(id: deviceID, label: row["device_label"], lastSeenAt: seen.map(Date.init(timeIntervalSince1970:)), capabilities: Set(raw.split(separator: ",").compactMap { RelayCapability(rawValue: String($0)) }))
                }
                return RelayAdminInstance(id: id, label: instance["label"], createdAt: Date(timeIntervalSince1970: instance["created_at"]), revokedAt: revoked.map(Date.init(timeIntervalSince1970:)), devices: devices)
            }
        }
    }

    public func adminRevokeInstance(_ id: UUID, now: Date = .init()) throws {
        try database.write { db in try db.execute(sql: "UPDATE instances SET revoked_at=? WHERE id=?", arguments: [now.timeIntervalSince1970, id.uuidString]) }
    }

    public func adminRevokeCredential(_ id: UUID, now: Date = .init()) throws {
        try database.write { db in try db.execute(sql: "UPDATE credentials SET revoked_at=? WHERE id=? AND role='companion'", arguments: [now.timeIntervalSince1970, id.uuidString]) }
    }

    public func createAlphaInvite(expiresAt: Date) throws -> RelayPairingGrant {
        let id = UUID(), code = Self.secret(prefix: "ai")
        try database.write { db in
            try db.execute(sql: "INSERT INTO alpha_invites(id,code_hash,expires_at) VALUES (?,?,?)",
                           arguments: [id.uuidString, Self.hash(code), expiresAt.timeIntervalSince1970])
        }
        return RelayPairingGrant(id: id, code: code, expiresAt: expiresAt)
    }

    public func redeemAlphaInvite(_ request: RelayInviteRedemption, now: Date = .init()) throws -> RelayDesktopProvisioning {
        let instanceID = UUID(), credentialID = UUID(), token = Self.secret(prefix: "desk")
        return try database.write { db in
            guard let inviteID = try String.fetchOne(db, sql: "SELECT id FROM alpha_invites WHERE code_hash=? AND consumed_at IS NULL AND expires_at>?", arguments: [Self.hash(request.code), now.timeIntervalSince1970]) else {
                throw RelayStoreError.invalidOrExpiredCode
            }
            try db.execute(sql: "UPDATE alpha_invites SET consumed_at=? WHERE id=? AND consumed_at IS NULL", arguments: [now.timeIntervalSince1970, inviteID])
            guard db.changesCount == 1 else { throw RelayStoreError.invalidOrExpiredCode }
            try db.execute(sql: "INSERT INTO instances(id,label,created_at) VALUES (?,?,?)", arguments: [instanceID.uuidString, request.deviceLabel, now.timeIntervalSince1970])
            let capabilities: Set<RelayCapability> = [.publishState, .createPairingGrant, .revokeDevices]
            try Self.insertCredential(db, id: credentialID, instanceID: instanceID, token: token, role: .desktop, capabilities: capabilities, deviceID: nil, label: request.deviceLabel, now: now)
            return RelayDesktopProvisioning(instanceID: instanceID, credential: token)
        }
    }

    public func authenticate(_ token: String, now: Date = .init()) throws -> RelayCredentialContext {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: """
              SELECT c.id,c.instance_id,c.role,c.capabilities,c.device_id
              FROM credentials c JOIN instances i ON i.id=c.instance_id
              WHERE c.token_hash=? AND c.revoked_at IS NULL AND i.revoked_at IS NULL
              """, arguments: [Self.hash(token)]),
                  let credentialID = UUID(uuidString: row["id"]),
                  let instanceID = UUID(uuidString: row["instance_id"]),
                  let role = RelayCredentialRole(rawValue: row["role"]) else { throw RelayStoreError.unauthorized }
            let capabilities = Set((row["capabilities"] as String).split(separator: ",").compactMap { RelayCapability(rawValue: String($0)) })
            let deviceString: String? = row["device_id"]
            try db.execute(sql: "UPDATE credentials SET last_seen_at=? WHERE id=?", arguments: [now.timeIntervalSince1970, credentialID.uuidString])
            return RelayCredentialContext(credentialID: credentialID, instanceID: instanceID, role: role, capabilities: capabilities, deviceID: deviceString.flatMap(UUID.init(uuidString:)))
        }
    }

    public func createPairingGrant(auth: RelayCredentialContext, deviceLabel: String, now: Date = .init()) throws -> RelayPairingGrant {
        guard auth.role == .desktop, auth.capabilities.contains(.createPairingGrant) else { throw RelayStoreError.forbidden }
        let id = UUID(), code = Self.secret(prefix: "pair"), expiresAt = now.addingTimeInterval(30 * 60)
        try database.write { db in
            try db.execute(sql: "INSERT INTO pairing_grants(id,instance_id,code_hash,device_label,expires_at) VALUES (?,?,?,?,?)",
                           arguments: [id.uuidString, auth.instanceID.uuidString, Self.hash(code), deviceLabel, expiresAt.timeIntervalSince1970])
        }
        return RelayPairingGrant(id: id, code: code, expiresAt: expiresAt)
    }

    public func cancelPairingGrant(auth: RelayCredentialContext, id: UUID, now: Date = .init()) throws {
        guard auth.role == .desktop, auth.capabilities.contains(.createPairingGrant) else { throw RelayStoreError.forbidden }
        try database.write { db in
            try db.execute(sql: "UPDATE pairing_grants SET cancelled_at=? WHERE id=? AND instance_id=? AND consumed_at IS NULL AND cancelled_at IS NULL", arguments: [now.timeIntervalSince1970, id.uuidString, auth.instanceID.uuidString])
            guard db.changesCount == 1 else { throw RelayStoreError.invalidOrExpiredCode }
        }
    }

    public func exchangePairingGrant(_ request: RelayPairingExchange, now: Date = .init()) throws -> RelayCompanionProvisioning {
        let token = Self.secret(prefix: "phone"), credentialID = UUID(), deviceID = UUID()
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id,instance_id FROM pairing_grants WHERE code_hash=? AND consumed_at IS NULL AND cancelled_at IS NULL AND expires_at>?", arguments: [Self.hash(request.code), now.timeIntervalSince1970]),
                  let instanceID = UUID(uuidString: row["instance_id"]) else { throw RelayStoreError.invalidOrExpiredCode }
            let grantID: String = row["id"]
            try db.execute(sql: "UPDATE pairing_grants SET consumed_at=? WHERE id=? AND consumed_at IS NULL", arguments: [now.timeIntervalSince1970, grantID])
            guard db.changesCount == 1 else { throw RelayStoreError.invalidOrExpiredCode }
            try Self.insertCredential(db, id: credentialID, instanceID: instanceID, token: token, role: .companion, capabilities: RelayWire.companionCapabilities, deviceID: deviceID, label: request.deviceLabel, now: now)
            return RelayCompanionProvisioning(instanceID: instanceID, deviceID: deviceID, credential: token, capabilities: RelayWire.companionCapabilities)
        }
    }

    public func publish(auth: RelayCredentialContext, request: RelayPublishRequest, now: Date = .init()) throws -> RelayEvent {
        guard auth.capabilities.contains(.publishState) else { throw RelayStoreError.forbidden }
        guard request.payload.count <= 512 * 1024 else { throw RelayStoreError.payloadTooLarge }
        return try database.write { db in
            guard let seq = try Int64.fetchOne(db, sql: "SELECT next_sequence FROM instances WHERE id=? AND revoked_at IS NULL", arguments: [auth.instanceID.uuidString]) else { throw RelayStoreError.unauthorized }
            try db.execute(sql: "UPDATE instances SET next_sequence=next_sequence+1 WHERE id=?", arguments: [auth.instanceID.uuidString])
            try db.execute(sql: "INSERT INTO relay_events(instance_id,sequence,kind,payload,is_snapshot,created_at) VALUES (?,?,?,?,?,?)", arguments: [auth.instanceID.uuidString, seq, request.kind, request.payload, request.isSnapshot, now.timeIntervalSince1970])
            if request.isSnapshot {
                try db.execute(sql: "DELETE FROM relay_events WHERE instance_id=? AND sequence<? AND is_snapshot=1", arguments: [auth.instanceID.uuidString, seq])
            }
            let floor = max(0, seq - Int64(eventTailLimit))
            try db.execute(sql: "DELETE FROM relay_events WHERE instance_id=? AND sequence<=? AND is_snapshot=0", arguments: [auth.instanceID.uuidString, floor])
            return RelayEvent(sequence: seq, kind: request.kind, payload: request.payload, createdAt: now)
        }
    }

    public func events(auth: RelayCredentialContext, after cursor: Int64) throws -> RelayEventPage {
        guard auth.role == .companion || auth.role == .desktop else { throw RelayStoreError.forbidden }
        return try database.read { db in
            let latest = (try Int64.fetchOne(db, sql: "SELECT next_sequence-1 FROM instances WHERE id=?", arguments: [auth.instanceID.uuidString])) ?? 0
            let snapshotRow = try Row.fetchOne(db, sql: "SELECT sequence,kind,payload,created_at FROM relay_events WHERE instance_id=? AND is_snapshot=1 AND sequence>? ORDER BY sequence DESC LIMIT 1", arguments: [auth.instanceID.uuidString, cursor])
            let snapshot = snapshotRow.map(Self.event)
            let start = snapshot?.sequence ?? cursor
            let rows = try Row.fetchAll(db, sql: "SELECT sequence,kind,payload,created_at FROM relay_events WHERE instance_id=? AND sequence>? ORDER BY sequence LIMIT 500", arguments: [auth.instanceID.uuidString, start])
            return RelayEventPage(snapshot: snapshot, events: rows.map(Self.event), latestSequence: latest)
        }
    }

    public func acceptCommand(auth: RelayCredentialContext, request: RelayCommandRequest, now: Date = .init()) throws -> RelayCommandReceipt {
        let required: RelayCapability
        switch request.kind { case "approval.respond": required = .respondToApprovals; case "agent.stop": required = .stopAgents; default: throw RelayStoreError.invalidCommand }
        guard auth.capabilities.contains(required) else { throw RelayStoreError.forbidden }
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT accepted,created_at FROM commands WHERE instance_id=? AND idempotency_key=?", arguments: [auth.instanceID.uuidString, request.idempotencyKey.uuidString]) {
                return RelayCommandReceipt(idempotencyKey: request.idempotencyKey, accepted: row["accepted"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
            try db.execute(sql: "INSERT INTO commands(instance_id,idempotency_key,device_id,kind,agent_id,accepted,created_at) VALUES (?,?,?,?,?,?,?)", arguments: [auth.instanceID.uuidString, request.idempotencyKey.uuidString, auth.deviceID?.uuidString, request.kind, request.agentID.uuidString, true, now.timeIntervalSince1970])
            return RelayCommandReceipt(idempotencyKey: request.idempotencyKey, accepted: true, createdAt: now)
        }
    }

    public func revokeCredential(auth: RelayCredentialContext, credentialID: UUID, now: Date = .init()) throws {
        guard auth.role == .desktop, auth.capabilities.contains(.revokeDevices) else { throw RelayStoreError.forbidden }
        try database.write { db in
            try db.execute(sql: "UPDATE credentials SET revoked_at=? WHERE id=? AND instance_id=? AND role='companion'", arguments: [now.timeIntervalSince1970, credentialID.uuidString, auth.instanceID.uuidString])
        }
    }

    public func devices(auth: RelayCredentialContext) throws -> [RelayDevice] {
        guard auth.role == .desktop else { throw RelayStoreError.forbidden }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id,device_label,last_seen_at,capabilities FROM credentials WHERE instance_id=? AND role='companion' AND revoked_at IS NULL ORDER BY created_at", arguments: [auth.instanceID.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let raw: String = row["capabilities"]; let seen: Double? = row["last_seen_at"]
                return RelayDevice(id: id, label: row["device_label"], lastSeenAt: seen.map(Date.init(timeIntervalSince1970:)), capabilities: Set(raw.split(separator: ",").compactMap { RelayCapability(rawValue: String($0)) }))
            }
        }
    }

    public func savePushToken(auth: RelayCredentialContext, kind: RelayPushRegistrationKind, token: Data, now: Date = .init()) throws {
        guard auth.role == .companion, let deviceID = auth.deviceID, !token.isEmpty, token.count <= 4_096 else { throw RelayStoreError.forbidden }
        let sealed = try AES.GCM.seal(token, using: encryptionKey).combined!
        try database.write { db in
            try db.execute(sql: "INSERT INTO push_registrations(id,instance_id,device_id,kind,sealed_token,created_at) VALUES (?,?,?,?,?,?) ON CONFLICT(device_id,kind) DO UPDATE SET sealed_token=excluded.sealed_token,created_at=excluded.created_at,revoked_at=NULL", arguments: [UUID().uuidString, auth.instanceID.uuidString, deviceID.uuidString, kind.rawValue, sealed, now.timeIntervalSince1970])
        }
    }

    public func removePushToken(auth: RelayCredentialContext, kind: RelayPushRegistrationKind, now: Date = .init()) throws {
        guard auth.role == .companion, let deviceID = auth.deviceID else { throw RelayStoreError.forbidden }
        try database.write { db in
            try db.execute(sql: "UPDATE push_registrations SET revoked_at=? WHERE instance_id=? AND device_id=? AND kind=?", arguments: [now.timeIntervalSince1970, auth.instanceID.uuidString, deviceID.uuidString, kind.rawValue])
        }
    }

    public func pushRegistrationKinds(auth: RelayCredentialContext) throws -> Set<RelayPushRegistrationKind> {
        guard auth.role == .companion, let deviceID = auth.deviceID else { throw RelayStoreError.forbidden }
        return try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT kind FROM push_registrations WHERE instance_id=? AND device_id=? AND revoked_at IS NULL", arguments: [auth.instanceID.uuidString, deviceID.uuidString]).compactMap(RelayPushRegistrationKind.init(rawValue:)))
        }
    }

    public func pushRegistrations(instanceID: UUID) throws -> [RelayStoredPushRegistration] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id,device_id,kind,sealed_token FROM push_registrations WHERE instance_id=? AND revoked_at IS NULL", arguments: [instanceID.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]), let deviceID = UUID(uuidString: row["device_id"]), let kind = RelayPushRegistrationKind(rawValue: row["kind"]) else { return nil }
                let sealed: Data = row["sealed_token"]
                guard let box = try? AES.GCM.SealedBox(combined: sealed), let token = try? AES.GCM.open(box, using: encryptionKey) else { return nil }
                return RelayStoredPushRegistration(id: id, deviceID: deviceID, kind: kind, token: token)
            }
        }
    }

    public func invalidatePushRegistration(id: UUID, now: Date = .init()) throws {
        try database.write { db in try db.execute(sql: "UPDATE push_registrations SET revoked_at=? WHERE id=?", arguments: [now.timeIntervalSince1970, id.uuidString]) }
    }

    private static func insertCredential(_ db: Database, id: UUID, instanceID: UUID, token: String, role: RelayCredentialRole, capabilities: Set<RelayCapability>, deviceID: UUID?, label: String, now: Date) throws {
        let encodedCapabilities = capabilities.map(\.rawValue).sorted().joined(separator: ",")
        try db.execute(sql: "INSERT INTO credentials(id,instance_id,token_hash,role,capabilities,device_id,device_label,created_at) VALUES (?,?,?,?,?,?,?,?)", arguments: [id.uuidString, instanceID.uuidString, hash(token), role.rawValue, encodedCapabilities, deviceID?.uuidString, label, now.timeIntervalSince1970])
    }
    private static func event(_ row: Row) -> RelayEvent {
        RelayEvent(sequence: row["sequence"], kind: row["kind"], payload: row["payload"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
    private static func hash(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    private static func secret(prefix: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return prefix + "_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
