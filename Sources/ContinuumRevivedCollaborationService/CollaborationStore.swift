import Foundation
import Crypto
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum CollaborationStoreError: Error, Equatable {
    case unauthorized, forbidden, unavailable, invalidInvitation, invalidRequest, staleEpoch, invalidCursor, tooManySubscriptions, invalidDatabaseKey
    /// The cursor predates the compacted horizon: fetch the area snapshot.
    case compacted
    /// Stored snapshot, horizon and operation tail do not reconstruct each other.
    case integrityFailure
    /// A live share link on this relay already uses the slug.
    case slugTaken
    /// Too many joins through one link, or from one address, in the window.
    case rateLimited
}

/// Separate database, credentials and namespace from companion v2. Every request
/// reauthenticates inside its transaction, including requests with old receipts.
public actor CollaborationStore {
    let database: DatabaseQueue
    let key: SymmetricKey
    let clock: @Sendable () -> Date
    let retention: CollaborationRetention
    let joinLimits: CollaborationJoinLimits
    /// Post-commit compaction that failed and left the full log in place.
    public internal(set) var compactionFailures = 0

    var cancelledUpdateRequests: [UUID: CollaborationCancelledUpdate] = [:]
    var updateWaiters: [UUID: CollaborationUpdateWaiter] = [:]
    var presenceEntries: [CollaborationPresenceKey: CollaborationPresenceEntry] = [:]
    var presenceFlushes: [CollaborationPresenceKey: Task<Void, Never>] = [:]
    var presenceVersions: [UUID: UUID] = [:]
    var hostLivenessStates: [UUID: [UUID: String]] = [:]

    public init(path: String, masterKey: Data, clock: @escaping @Sendable () -> Date = { Date() },
                retention: CollaborationRetention = .init(), joinLimits: CollaborationJoinLimits = .init()) throws {
        guard masterKey.count >= 32 else { throw CollaborationStoreError.invalidRequest }
        var config = Configuration(); config.busyMode = .timeout(2)
        database = try DatabaseQueue(path: path, configuration: config)
        let normalizedKeyData = Data(SHA256.hash(data: masterKey))
        key = SymmetricKey(data: normalizedKeyData)
        self.clock = clock; self.retention = retention; self.joinLimits = joinLimits
        // Authenticate an already adopted database before any migration can
        // write with a deployment key that merely has the right length.
        try Self.preflightDatabaseKey(database, keyData: normalizedKeyData)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("collaboration-v1") { db in
            try db.execute(sql: """
                CREATE TABLE people(id TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
                CREATE TABLE devices(id TEXT PRIMARY KEY NOT NULL, person TEXT NOT NULL REFERENCES people(id),
                  label TEXT NOT NULL, token_hash BLOB UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE enrollments(code_hash BLOB PRIMARY KEY NOT NULL, person TEXT NOT NULL REFERENCES people(id),
                  issuer_device TEXT REFERENCES devices(id), expires DOUBLE NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE hosts(id TEXT PRIMARY KEY NOT NULL, device TEXT NOT NULL REFERENCES devices(id));
                CREATE TABLE areas(id TEXT PRIMARY KEY NOT NULL, epoch INTEGER NOT NULL, snapshot BLOB NOT NULL);
                CREATE TABLE members(area TEXT NOT NULL REFERENCES areas(id), person TEXT NOT NULL REFERENCES people(id),
                  role TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(area,person));
                CREATE TABLE invitations(code_hash BLOB PRIMARY KEY NOT NULL, area TEXT NOT NULL REFERENCES areas(id),
                  person TEXT NOT NULL REFERENCES people(id), role TEXT NOT NULL, issuer TEXT NOT NULL REFERENCES devices(id),
                  epoch INTEGER NOT NULL, expires DOUBLE NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE operations(area TEXT NOT NULL REFERENCES areas(id), revision INTEGER NOT NULL,
                  actor TEXT NOT NULL REFERENCES devices(id), operation_id TEXT NOT NULL, command BLOB NOT NULL,
                  PRIMARY KEY(area,revision), UNIQUE(area,operation_id));
                """)
        }
        let migrationKeyData = normalizedKeyData
        migrator.registerMigration("collaboration-v2-head-revision") { db in
            try db.execute(sql: "ALTER TABLE areas ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            for row in try Row.fetchAll(db, sql: "SELECT id,snapshot FROM areas") {
                let sealed: Data = row["snapshot"]
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: migrationKeyData))
                let document = try JSONDecoder().decode(SharedArea.Document.self, from: data)
                guard document.revision <= UInt64(Int64.max) else { throw CollaborationStoreError.invalidRequest }
                try db.execute(sql: "UPDATE areas SET revision=? WHERE id=?", arguments: [Int64(document.revision), row["id"] as String])
            }
        }
        migrator.registerMigration("collaboration-v3-database-key") { db in
            // Existing unmarked databases must authenticate every encrypted
            // record before adopting the key. Migration rollback preserves all
            // original ciphertext when even the last record is incompatible.
            try Self.validateExistingCiphertext(db, keyData: migrationKeyData)
            let marker = try AES.GCM.seal(Self.databaseKeyMarkerPlaintext,
                using: SymmetricKey(data: migrationKeyData), authenticating: Self.databaseKeyMarkerAAD).combined!
            try db.execute(sql: "CREATE TABLE collaboration_key_marker(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, sealed BLOB NOT NULL)")
            try db.execute(sql: "INSERT INTO collaboration_key_marker(id,version,sealed) VALUES (1,1,?)", arguments: [marker])
        }
        Self.registerHandoffMigration(&migrator)
        Self.registerUsageMigration(&migrator)
        Self.registerRetentionMigration(&migrator)
        Self.registerArtifactMigration(&migrator)
        Self.registerHostLivenessMigration(&migrator)
        Self.registerAgentProjectionMigration(&migrator)
        Self.registerShareLinkMigration(&migrator)
        Self.registerShareLinkJoinLimitMigration(&migrator)
        Self.registerSelfEnrollMigration(&migrator)
        try migrator.migrate(database)
        try Self.preflightDatabaseKey(database, keyData: normalizedKeyData)
    }

    private static let databaseKeyMarkerPlaintext = Data("array.collaboration.database-key.v1".utf8)
    private static let databaseKeyMarkerAAD = Data("Array Collaboration Database Key Marker v1".utf8)

    private static func preflightDatabaseKey(_ database: DatabaseQueue, keyData: Data) throws {
        try database.read { db in
            let hasMarker = try db.tableExists("collaboration_key_marker")
            let hasMigrationTable = try db.tableExists("grdb_migrations")
            let recorded: Bool
            if hasMigrationTable {
                recorded = try String.fetchOne(db,
                    sql: "SELECT identifier FROM grdb_migrations WHERE identifier='collaboration-v3-database-key'") != nil
            } else { recorded = false }
            guard hasMarker == recorded else { throw CollaborationStoreError.invalidDatabaseKey }
            guard hasMarker else { return }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collaboration_key_marker") == 1,
                  let row = try Row.fetchOne(db, sql: "SELECT version,sealed FROM collaboration_key_marker WHERE id=1"),
                  row["version"] as Int == 1 else { throw CollaborationStoreError.invalidDatabaseKey }
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: row["sealed"] as Data),
                    using: SymmetricKey(data: keyData), authenticating: databaseKeyMarkerAAD)
            } catch { throw CollaborationStoreError.invalidDatabaseKey }
            guard plaintext == databaseKeyMarkerPlaintext else { throw CollaborationStoreError.invalidDatabaseKey }
        }
    }

    private static func validateExistingCiphertext(_ db: Database, keyData: Data) throws {
        let adoptionKey = SymmetricKey(data: keyData)
        do {
            let snapshots = try Row.fetchCursor(db, sql: "SELECT id,snapshot FROM areas")
            while let row = try snapshots.next() {
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: row["snapshot"] as Data), using: adoptionKey)
                let document = try JSONDecoder().decode(SharedArea.Document.self, from: data)
                guard UUID(uuidString: row["id"]) == document.id.rawValue else { throw CollaborationStoreError.invalidDatabaseKey }
            }
            let operations = try Row.fetchCursor(db, sql: "SELECT area,revision,operation_id,command FROM operations")
            while let row = try operations.next() {
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: row["command"] as Data), using: adoptionKey)
                let command = try JSONDecoder().decode(SharedArea.Command.self, from: data)
                let revision: Int64 = row["revision"]
                guard command.schema == 1, revision > 0,
                      UUID(uuidString: row["area"]) == command.area.rawValue,
                      UUID(uuidString: row["operation_id"]) == command.id.rawValue,
                      command.expectedRevision == UInt64(revision - 1) else { throw CollaborationStoreError.invalidDatabaseKey }
            }
            try Self.validateHandoffCiphertext(db, keyData: keyData)
        } catch { throw CollaborationStoreError.invalidDatabaseKey }
    }

    /// Operator admission seam, deliberately absent from public HTTP routes.
    public func provisionPerson(label: String, lifetime: TimeInterval = 600) throws -> Collaboration.Enrollment {
        try validate(label); try validate(lifetime)
        let person = SharedArea.ID<SharedArea.Person>(), code = Self.secret(), expires = clock().addingTimeInterval(lifetime)
        try database.write { db in
            try db.execute(sql: "INSERT INTO people(id,label) VALUES (?,?)", arguments: [person.rawValue.uuidString, label])
            try insertEnrollment(db, person: person.rawValue.uuidString, code: code, expires: expires, issuer: nil)
        }
        return .init(person: person, code: code, expiresAt: expires)
    }
    public func enrollDevice(token: String, lifetime: TimeInterval) throws -> Collaboration.Enrollment {
        try validate(lifetime)
        let code = Self.secret(), expires = clock().addingTimeInterval(lifetime)
        return try database.write { db in
            let identity = try authenticate(db, token)
            try insertEnrollment(db, person: identity.person.rawValue.uuidString, code: code, expires: expires, issuer: identity.device.uuidString)
            return .init(person: identity.person, code: code, expiresAt: expires)
        }
    }
    public func redeem(_ request: Collaboration.RedeemEnrollment) throws -> Collaboration.Credential {
        try validate(request.deviceLabel)
        let token = Self.secret(), device = UUID(), now = clock().timeIntervalSince1970
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM enrollments WHERE code_hash=? AND consumed=0 AND expires>?", arguments: [Self.hash(request.code), now]) else { throw CollaborationStoreError.invalidInvitation }
            if let issuer: String = row["issuer_device"] {
                guard try Int.fetchOne(db, sql: "SELECT revoked FROM devices WHERE id=?", arguments: [issuer]) == 0 else { throw CollaborationStoreError.invalidInvitation }
            }
            let person: String = row["person"]
            try db.execute(sql: "UPDATE enrollments SET consumed=1 WHERE code_hash=?", arguments: [Self.hash(request.code)])
            try db.execute(sql: "INSERT INTO devices(id,person,label,token_hash) VALUES (?,?,?,?)", arguments: [device.uuidString, person, request.deviceLabel, Self.hash(token)])
            return .init(identity: .init(person: SharedArea.ID(UUID(uuidString: person)!), device: device), token: token)
        }
    }
    public func identity(token: String) throws -> Collaboration.Identity {
        try database.read { try authenticate($0, token) }
    }
    public func revokeDevice(token: String, device: UUID) throws {
        try database.write { db in
            let caller = try authenticate(db, token)
            guard try String.fetchOne(db, sql: "SELECT person FROM devices WHERE id=?", arguments: [device.uuidString]) == caller.person.rawValue.uuidString else { throw CollaborationStoreError.unavailable }
            try db.execute(sql: "UPDATE devices SET revoked=1 WHERE id=?", arguments: [device.uuidString])
        }
        invalidateDevice(device)
    }
    public func registerHost(token: String) throws -> Collaboration.Host {
        try database.write { db in
            let caller = try authenticate(db, token), id = SharedArea.ID<SharedArea.Host>()
            try db.execute(sql: "INSERT INTO hosts(id,device) VALUES (?,?)", arguments: [id.rawValue.uuidString, caller.device.uuidString])
            return .init(id: id)
        }
    }
    public func createArea(token: String) throws -> Collaboration.State {
        try database.write { db in
            let caller = try authenticate(db, token), document = SharedArea.Document()
            let id = document.id.rawValue.uuidString
            try db.execute(sql: "INSERT INTO areas(id,epoch,snapshot) VALUES (?,1,?)", arguments: [id, try seal(document)])
            try db.execute(sql: "INSERT INTO members(area,person,role) VALUES (?,?,'owner')", arguments: [id, caller.person.rawValue.uuidString])
            return .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document)
        }
    }
    public func state(token: String, area: UUID) throws -> Collaboration.State {
        try database.read { db in
            let caller = try authenticate(db, token)
            let scope = try scope(db, caller, area)
            let bytes = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
            return .init(scope: scope, document: try unseal(SharedArea.Document.self, bytes))
        }
    }
    public func invite(token: String, area: UUID, request: Collaboration.InviteRequest) throws -> Collaboration.Invitation {
        try validate(request.lifetime)
        guard request.role != .owner else { throw CollaborationStoreError.invalidRequest }
        let code = Self.secret(), expires = clock().addingTimeInterval(request.lifetime)
        return try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM people WHERE id=?)", arguments: [request.person.rawValue.uuidString]) == true else { throw CollaborationStoreError.invalidRequest }
            try db.execute(sql: "INSERT INTO invitations(code_hash,area,person,role,issuer,epoch,expires) VALUES (?,?,?,?,?,?,?)", arguments: [Self.hash(code), area.uuidString, request.person.rawValue.uuidString, request.role.rawValue, caller.device.uuidString, current.epoch, expires.timeIntervalSince1970])
            return .init(code: code, expiresAt: expires)
        }
    }
    /// Full retained area history is visible on join. Links are person-targeted.
    public func accept(token: String, code: String) throws -> Collaboration.Scope {
        try database.write { db in
            let caller = try authenticate(db, token)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM invitations WHERE code_hash=? AND expires>?", arguments: [Self.hash(code), clock().timeIntervalSince1970]),
                  row["person"] as String == caller.person.rawValue.uuidString else { throw CollaborationStoreError.invalidInvitation }
            let area = UUID(uuidString: row["area"])!, epoch: Int64 = row["epoch"]
            let issuer: String = row["issuer"]
            guard let issuerRow = try Row.fetchOne(db, sql: "SELECT person FROM devices WHERE id=? AND revoked=0", arguments: [issuer]) else { throw CollaborationStoreError.invalidInvitation }
            let issuerIdentity = Collaboration.Identity(person: SharedArea.ID(UUID(uuidString: issuerRow["person"])!), device: UUID(uuidString: issuer)!)
            let authority = try scope(db, issuerIdentity, area)
            // A consumed invite can recover only its still-current membership.
            if row["consumed"] as Int == 1 {
                let current = try scope(db, caller, area)
                guard authority.allows(.manageSharing), current.epoch == epoch else { throw CollaborationStoreError.invalidInvitation }
                return current
            }
            guard authority.allows(.manageSharing), authority.epoch == epoch else { throw CollaborationStoreError.invalidInvitation }
            // Do not use an old invite to change an existing member's role.
            guard try Int.fetchOne(db, sql: "SELECT active FROM members WHERE area=? AND person=?", arguments: [area.uuidString, caller.person.rawValue.uuidString]) != 1 else { throw CollaborationStoreError.invalidInvitation }
            try db.execute(sql: "INSERT INTO members(area,person,role,active) VALUES (?,?,?,1) ON CONFLICT(area,person) DO UPDATE SET role=excluded.role,active=1", arguments: [area.uuidString, caller.person.rawValue.uuidString, row["role"] as String])
            try db.execute(sql: "UPDATE invitations SET consumed=1 WHERE code_hash=?", arguments: [Self.hash(code)])
            return try scope(db, caller, area)
        }
    }
    public func removeMember(token: String, area: UUID, person: UUID, expectedEpoch: Int64) throws {
        try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            guard current.epoch == expectedEpoch else { throw CollaborationStoreError.staleEpoch }
            guard caller.person.rawValue != person else { throw CollaborationStoreError.forbidden }
            guard try Int.fetchOne(db, sql: "SELECT active FROM members WHERE area=? AND person=?", arguments: [area.uuidString, person.uuidString]) == 1 else { throw CollaborationStoreError.unavailable }
            try db.execute(sql: "UPDATE members SET active=0 WHERE area=? AND person=?", arguments: [area.uuidString, person.uuidString])
            try closeShareLinkAdmissions(db, area: area, person: person)
            try db.execute(sql: "UPDATE areas SET epoch=epoch+1 WHERE id=?", arguments: [area.uuidString])
        }
        invalidateMember(area: area, person: person)
    }
    public func apply(token: String, area: UUID, request: Collaboration.Mutation) throws -> Collaboration.Receipt {
        let receipt: Collaboration.Receipt = try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.epoch == request.epoch else { throw CollaborationStoreError.staleEpoch }
            guard current.allows(.layout) || current.allows(.discuss) || current.allows(.publish) else { throw CollaborationStoreError.forbidden }
            guard request.command.area.rawValue == area else { throw CollaborationStoreError.unavailable }
            // Receipts outlive compaction, so an operation ID stays bound to
            // its original person after the operation row itself is retired.
            if let actorPerson = try String.fetchOne(db, sql: "SELECT d.person FROM operation_receipts r JOIN devices d ON d.id=r.actor WHERE r.area=? AND r.operation_id=?", arguments: [area.uuidString, request.command.id.rawValue.uuidString]), actorPerson != caller.person.rawValue.uuidString {
                throw SharedArea.Failure.changedIntent
            }
            let bytes = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
            var document = try unseal(SharedArea.Document.self, bytes)
            try authorize(db, caller, current, request.command, document: document)
            switch try document.apply(request.command) {
            case let .duplicate(revision): return .init(revision: revision, duplicate: true)
            case let .applied(revision):
                guard revision <= UInt64(Int64.max) else { throw CollaborationStoreError.invalidRequest }
                try refreshUsageAccess(db, area: area, document: document)
                try refreshHandoffAccess(db, area: area, document: document)
                try refreshArtifactAccess(db, area: area, document: document)
                try refreshAgentProjectionAccess(db, area: area, document: document)
                try db.execute(sql: "UPDATE areas SET snapshot=?,revision=? WHERE id=?", arguments: [try seal(document), Int64(revision), area.uuidString])
                try db.execute(sql: "INSERT INTO operations(area,revision,actor,operation_id,command,committed) VALUES (?,?,?,?,?,?)", arguments: [area.uuidString, Int64(revision), caller.device.uuidString, request.command.id.rawValue.uuidString, try seal(request.command), clock().timeIntervalSince1970])
                try db.execute(sql: "INSERT INTO operation_receipts(area,operation_id,revision,actor) VALUES (?,?,?,?)", arguments: [area.uuidString, request.command.id.rawValue.uuidString, Int64(revision), caller.device.uuidString])
                return .init(revision: revision, duplicate: false)
            }
        }
        // Notify only after the durable transaction has committed.
        if !receipt.duplicate {
            // Maintenance is its own transaction. A failed compaction keeps the
            // full log and never fails or undoes the committed command.
            do { try database.write { db in _ = try compactIfDue(db, area: area) } } catch { compactionFailures += 1 }
            wakeArea(area)
        }
        return receipt
    }
    private func authorize(_ db: Database, _ caller: Collaboration.Identity, _ current: Collaboration.Scope,
                           _ command: SharedArea.Command, document: SharedArea.Document) throws {
        // Track admissions in the same atomic command as well as already
        // published objects. Geometry does not imply ownership of a source.
        var items = Dictionary(uniqueKeysWithValues: document.items.map { ($0.id, $0) })
        func require(_ capability: Collaboration.Capability) throws {
            guard current.allows(capability) else { throw CollaborationStoreError.forbidden }
        }
        for edit in command.edits {
            for capability in Collaboration.requiredCapabilities(for: edit) { try require(capability) }
            switch edit {
            case let .admit(item, _):
                switch item.kind {
                case .agentObservation, .artifact:
                    guard item.source != nil else { throw CollaborationStoreError.invalidRequest }
                case .discussion, .agreement:
                    guard item.source == nil else { throw CollaborationStoreError.invalidRequest }
                }
                if let source = item.source {
                    guard source.owner == caller.person,
                          try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [source.host.rawValue.uuidString]) == caller.device.uuidString else { throw CollaborationStoreError.forbidden }
                }
                items[item.id] = item
            case .place: break
            case let .remove(object):
                if let item = items[object], let source = item.source {
                    // Area ownership is not ownership of a teammate's source.
                    // A person can unpublish their source from any of their
                    // authenticated devices, including while its host is down.
                    guard source.owner == caller.person else { throw CollaborationStoreError.forbidden }
                }
                items.removeValue(forKey: object)
            case let .post(post):
                guard post.author == caller.person else { throw CollaborationStoreError.forbidden }
            case let .context(context):
                guard context.author == caller.person else { throw CollaborationStoreError.forbidden }
            case let .endorse(endorsement):
                // Endorsement is a person's own statement, never one made for
                // a teammate, an agent or a host.
                guard endorsement.person == caller.person else { throw CollaborationStoreError.forbidden }
            }
        }
    }
    func authenticate(_ db: Database, _ token: String) throws -> Collaboration.Identity {
        guard let row = try Row.fetchOne(db, sql: "SELECT id,person FROM devices WHERE token_hash=? AND revoked=0", arguments: [Self.hash(token)]) else { throw CollaborationStoreError.unauthorized }
        return .init(person: SharedArea.ID(UUID(uuidString: row["person"])!), device: UUID(uuidString: row["id"])!)
    }
    func scope(_ db: Database, _ caller: Collaboration.Identity, _ area: UUID) throws -> Collaboration.Scope {
        guard let row = try Row.fetchOne(db, sql: "SELECT a.epoch,m.role FROM areas a JOIN members m ON m.area=a.id WHERE a.id=? AND m.person=? AND m.active=1", arguments: [area.uuidString, caller.person.rawValue.uuidString]),
              let role = Collaboration.Role(rawValue: row["role"]) else { throw CollaborationStoreError.unavailable }
        return .init(area: SharedArea.ID(area), epoch: row["epoch"], role: role)
    }
    func insertEnrollment(_ db: Database, person: String, code: String, expires: Date, issuer: String?) throws {
        try db.execute(sql: "INSERT INTO enrollments(code_hash,person,issuer_device,expires) VALUES (?,?,?,?)", arguments: [Self.hash(code), person, issuer, expires.timeIntervalSince1970])
    }
    private func validate(_ label: String) throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 120 else { throw CollaborationStoreError.invalidRequest }
    }
    private func validate(_ lifetime: TimeInterval) throws {
        guard lifetime.isFinite, lifetime > 0, lifetime <= 86400 else { throw CollaborationStoreError.invalidRequest }
    }
    func seal<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try AES.GCM.seal(encoder.encode(value), using: key).combined!
    }
    func unseal<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key))
    }
    static func hash(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    static func secret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    }
}
