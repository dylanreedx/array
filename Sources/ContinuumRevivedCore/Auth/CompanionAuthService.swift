import Foundation
import GRDB

public struct ContinuumInstance: Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var createdAt: Date

    public init(id: UUID, displayName: String, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public struct ContinuumUser: Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var createdAt: Date

    public init(id: UUID, displayName: String, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public struct ContinuumDevice: Equatable, Sendable {
    public var id: UUID
    public var instanceId: UUID
    public var userId: UUID
    public var sessionId: UUID
    public var label: String
    public var scopes: Scope
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public init(
        id: UUID,
        instanceId: UUID,
        userId: UUID,
        sessionId: UUID,
        label: String,
        scopes: Scope,
        createdAt: Date,
        lastSeenAt: Date?,
        revokedAt: Date?
    ) {
        self.id = id
        self.instanceId = instanceId
        self.userId = userId
        self.sessionId = sessionId
        self.label = label
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

public struct CompanionSessionRecord: Equatable, Sendable {
    public var sessionId: UUID
    public var instanceId: UUID
    public var userId: UUID
    public var deviceId: UUID
    public var scopes: Scope
    public var issuedAt: Date
    public var expiresAt: Date
    public var revokedAt: Date?

    public init(
        sessionId: UUID,
        instanceId: UUID,
        userId: UUID,
        deviceId: UUID,
        scopes: Scope,
        issuedAt: Date,
        expiresAt: Date,
        revokedAt: Date?
    ) {
        self.sessionId = sessionId
        self.instanceId = instanceId
        self.userId = userId
        self.deviceId = deviceId
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

public struct CompanionPairingExchange: Equatable, Sendable {
    public var instanceId: UUID
    public var userId: UUID
    public var device: ContinuumDevice
    public var session: AuthSession

    public init(instanceId: UUID, userId: UUID, device: ContinuumDevice, session: AuthSession) {
        self.instanceId = instanceId
        self.userId = userId
        self.device = device
        self.session = session
    }
}

public struct CompanionVerifiedSession: Equatable, Sendable {
    public var instanceId: UUID
    public var userId: UUID
    public var deviceId: UUID
    public var sessionId: UUID
    public var scopes: Scope
    public var issuedAt: Date
    public var expiresAt: Date

    public init(instanceId: UUID, userId: UUID, deviceId: UUID, sessionId: UUID, scopes: Scope, issuedAt: Date, expiresAt: Date) {
        self.instanceId = instanceId
        self.userId = userId
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public actor CompanionAuthService {
    private let clock: any Clock
    private let dbQueue: DatabaseQueue
    private let pairingStore: PairingStore
    private let sessionStore: SessionStore

    public init(
        authDirectory: URL,
        clock: any Clock = SystemClock(),
        instanceDisplayName: String = "Array"
    ) throws {
        self.clock = clock
        let databaseURL = AuthDatabase.url(in: authDirectory)
        let signingKey = try SessionStore.loadOrCreateSigningKey(in: authDirectory)
        let queue = try AuthDatabase.queue(at: databaseURL)
        try Self.prepare(queue)
        try Self.bootstrap(queue, clock: clock, instanceDisplayName: instanceDisplayName)
        self.dbQueue = queue
        self.pairingStore = try PairingStore(clock: clock, databaseURL: databaseURL)
        self.sessionStore = try SessionStore(signingKey: signingKey, clock: clock, databaseURL: databaseURL)
    }

    public func instance() throws -> ContinuumInstance {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM companion_instance LIMIT 1") else {
                throw AuthError.unknown
            }
            return try Self.instance(from: row)
        }
    }

    public func owner() throws -> ContinuumUser {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM companion_owner LIMIT 1") else {
                throw AuthError.unknown
            }
            return try Self.owner(from: row)
        }
    }

    public func issuePairingCredential(scopes: Scope = .observer, ttl: TimeInterval = 600, label: String) async throws -> PairingGrant {
        try await pairingStore.issue(scopes: scopes, ttl: ttl, label: label)
    }

    public func exchangePairingCredential(
        _ credential: String,
        requested: Scope? = nil,
        deviceLabel: String,
        ttl: TimeInterval = 7_776_000
    ) async throws -> CompanionPairingExchange {
        let instance = try instance()
        let owner = try owner()
        let deviceId = UUID()
        let subject = "device:\(deviceId.uuidString)"
        let session = try await sessionStore.exchange(
            credential: credential,
            requested: requested,
            subject: subject,
            ttl: ttl,
            pairingStore: pairingStore
        )
        let now = clock.now()
        let device = ContinuumDevice(
            id: deviceId,
            instanceId: instance.id,
            userId: owner.id,
            sessionId: session.id,
            label: deviceLabel,
            scopes: session.scopes,
            createdAt: now,
            lastSeenAt: nil,
            revokedAt: nil
        )
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO companion_devices
                    (id, instance_id, user_id, session_id, label, scopes, created_at, last_seen_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
                arguments: [
                    device.id.uuidString,
                    device.instanceId.uuidString,
                    device.userId.uuidString,
                    device.sessionId.uuidString,
                    device.label,
                    device.scopes.rawValue,
                    device.createdAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO companion_sessions
                    (session_id, instance_id, user_id, device_id, scopes, issued_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    session.id.uuidString,
                    instance.id.uuidString,
                    owner.id.uuidString,
                    device.id.uuidString,
                    session.scopes.rawValue,
                    session.issuedAt.timeIntervalSince1970,
                    session.expiresAt.timeIntervalSince1970
                ]
            )
        }
        return CompanionPairingExchange(instanceId: instance.id, userId: owner.id, device: device, session: session)
    }

    public func verifySessionToken(_ token: String) async throws -> CompanionVerifiedSession {
        let session = try await sessionStore.verify(token)
        let now = clock.now()
        let record: CompanionSessionRecord = try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM companion_sessions WHERE session_id = ?",
                arguments: [session.id.uuidString]
            ) else {
                throw AuthError.revoked
            }
            let record = try Self.sessionRecord(from: row)
            if record.revokedAt != nil { throw AuthError.revoked }
            guard let deviceRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM companion_devices WHERE id = ?",
                arguments: [record.deviceId.uuidString]
            ) else {
                throw AuthError.revoked
            }
            let device = try Self.device(from: deviceRow)
            if device.revokedAt != nil { throw AuthError.revoked }
            try db.execute(
                sql: "UPDATE companion_devices SET last_seen_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, device.id.uuidString]
            )
            return record
        }
        return CompanionVerifiedSession(
            instanceId: record.instanceId,
            userId: record.userId,
            deviceId: record.deviceId,
            sessionId: session.id,
            scopes: session.scopes,
            issuedAt: session.issuedAt,
            expiresAt: session.expiresAt
        )
    }

    public func listDevices() throws -> [ContinuumDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM companion_devices ORDER BY created_at, id")
                .map(Self.device(from:))
        }
    }

    /// Ticket 86: token+scope pairs for every active session, for relay
    /// registry re-registration. Tokens never leave the machine except to
    /// the owner's own relay.
    public func activeSessionTokens() async -> [(token: String, scopes: Scope)] {
        await sessionStore.activeSessions().map { ($0.token, $0.scopes) }
    }

    public func listSessions() throws -> [CompanionSessionRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM companion_sessions ORDER BY issued_at, session_id")
                .map(Self.sessionRecord(from:))
        }
    }

    public func revokeSession(_ sessionId: UUID) async throws {
        let now = clock.now()
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE companion_sessions SET revoked_at = ? WHERE session_id = ?",
                arguments: [now.timeIntervalSince1970, sessionId.uuidString]
            )
        }
        await sessionStore.revoke(id: sessionId)
    }

    public func revokeDevice(_ deviceId: UUID) async throws {
        let now = clock.now()
        let sessionIds: [UUID] = try await dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT session_id FROM companion_sessions WHERE device_id = ? AND revoked_at IS NULL",
                arguments: [deviceId.uuidString]
            )
            try db.execute(
                sql: "UPDATE companion_devices SET revoked_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, deviceId.uuidString]
            )
            try db.execute(
                sql: "UPDATE companion_sessions SET revoked_at = ? WHERE device_id = ?",
                arguments: [now.timeIntervalSince1970, deviceId.uuidString]
            )
            return try rows.map { row in
                guard let id = UUID(uuidString: row["session_id"] as String) else { throw AuthError.unknown }
                return id
            }
        }
        for sessionId in sessionIds {
            await sessionStore.revoke(id: sessionId)
        }
    }

    private static func prepare(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS companion_instance (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS companion_owner (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS companion_devices (
                id TEXT PRIMARY KEY NOT NULL,
                instance_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                session_id TEXT UNIQUE NOT NULL,
                label TEXT NOT NULL,
                scopes INTEGER NOT NULL,
                created_at REAL NOT NULL,
                last_seen_at REAL,
                revoked_at REAL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS companion_sessions (
                session_id TEXT PRIMARY KEY NOT NULL,
                instance_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                scopes INTEGER NOT NULL,
                issued_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                revoked_at REAL
            )
            """)
        }
    }

    private static func bootstrap(_ dbQueue: DatabaseQueue, clock: any Clock, instanceDisplayName: String) throws {
        let now = clock.now().timeIntervalSince1970
        try dbQueue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM companion_instance") == 0 {
                try db.execute(
                    sql: "INSERT INTO companion_instance (id, display_name, created_at) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, instanceDisplayName, now]
                )
            }
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM companion_owner") == 0 {
                try db.execute(
                    sql: "INSERT INTO companion_owner (id, display_name, created_at) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, "Local Owner", now]
                )
            }
        }
    }

    private static func instance(from row: Row) throws -> ContinuumInstance {
        guard let id = UUID(uuidString: row["id"] as String) else { throw AuthError.unknown }
        return ContinuumInstance(
            id: id,
            displayName: row["display_name"] as String,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
        )
    }

    private static func owner(from row: Row) throws -> ContinuumUser {
        guard let id = UUID(uuidString: row["id"] as String) else { throw AuthError.unknown }
        return ContinuumUser(
            id: id,
            displayName: row["display_name"] as String,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
        )
    }

    private static func device(from row: Row) throws -> ContinuumDevice {
        guard let id = UUID(uuidString: row["id"] as String),
              let instanceId = UUID(uuidString: row["instance_id"] as String),
              let userId = UUID(uuidString: row["user_id"] as String),
              let sessionId = UUID(uuidString: row["session_id"] as String) else {
            throw AuthError.unknown
        }
        return ContinuumDevice(
            id: id,
            instanceId: instanceId,
            userId: userId,
            sessionId: sessionId,
            label: row["label"] as String,
            scopes: Scope(rawValue: row["scopes"] as Int),
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
            lastSeenAt: (row["last_seen_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            revokedAt: (row["revoked_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func sessionRecord(from row: Row) throws -> CompanionSessionRecord {
        guard let sessionId = UUID(uuidString: row["session_id"] as String),
              let instanceId = UUID(uuidString: row["instance_id"] as String),
              let userId = UUID(uuidString: row["user_id"] as String),
              let deviceId = UUID(uuidString: row["device_id"] as String) else {
            throw AuthError.unknown
        }
        return CompanionSessionRecord(
            sessionId: sessionId,
            instanceId: instanceId,
            userId: userId,
            deviceId: deviceId,
            scopes: Scope(rawValue: row["scopes"] as Int),
            issuedAt: Date(timeIntervalSince1970: row["issued_at"] as Double),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"] as Double),
            revokedAt: (row["revoked_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}
