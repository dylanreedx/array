import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

private struct DatabaseKeyCheckFailure: Error { let message: String }
private func keyExpect(_ value: Bool, _ message: String) throws {
    guard value else { throw DatabaseKeyCheckFailure(message: message) }
    print("PASS database key: \(message)")
}
private func refusesKey(_ action: () throws -> Void) throws {
    do {
        try action()
        throw DatabaseKeyCheckFailure(message: "database accepted an invalid key/marker")
    } catch CollaborationStoreError.invalidDatabaseKey {
        print("PASS database key: invalid key or marker refuses before writes")
    }
}
private struct KeyFixture: Sendable {
    let path: String
    let token: String
    let states: [Collaboration.State]
}
private struct CiphertextProof: Equatable, Sendable {
    let snapshots: [Data]
    let commands: [Data]
    let heads: [Int64]
}
private func ciphertextProof(_ database: DatabaseQueue) async throws -> CiphertextProof {
    try await database.read { db in
        .init(snapshots: try Data.fetchAll(db, sql: "SELECT snapshot FROM areas ORDER BY id"),
              commands: try Data.fetchAll(db, sql: "SELECT command FROM operations ORDER BY area,revision"),
              heads: try Int64.fetchAll(db, sql: "SELECT revision FROM areas ORDER BY id"))
    }
}
private func seedKeyFixture(_ root: URL, name: String, key: Data) async throws -> KeyFixture {
    let path = root.appendingPathComponent(name + ".sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key)
    let enrollment = try await store.provisionPerson(label: "Database key fixture")
    let credential = try await store.redeem(.init(code: enrollment.code, deviceLabel: "Fixture device"))
    var states: [Collaboration.State] = []
    for index in 0..<2 {
        let created = try await store.createArea(token: credential.token)
        let item = SharedArea.Item(id: .init(), kind: .discussion)
        let position = SharedArea.Position(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 640, height: 520))
        let command = SharedArea.Command(area: created.scope.area, expectedRevision: 0,
            edits: [.admit(item, position), .post(.init(id: .init(), object: item.id, author: credential.identity.person, text: "Key adoption content \(index)"))])
        _ = try await store.apply(token: credential.token, area: created.scope.area.rawValue, request: .init(epoch: 1, command: command))
        states.append(try await store.state(token: credential.token, area: created.scope.area.rawValue))
    }
    return .init(path: path, token: credential.token, states: states)
}
private func removeMarkerForV2Fixture(_ database: DatabaseQueue) async throws {
    try await database.write { db in
        try db.execute(sql: "DROP TABLE collaboration_key_marker")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='collaboration-v3-database-key'")
    }
}
private func hasAdoptedKey(_ database: DatabaseQueue) async throws -> Bool {
    try await database.read { db in
        // Adoption happens through a different connection. GRDB's writer
        // schema cache can retain tableExists=false from the preceding failed
        // adoption, so inspect SQLite's committed schema directly here.
        let table = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='collaboration_key_marker')") == true
        let recorded = try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier='collaboration-v3-database-key'") != nil
        guard table == recorded else { throw DatabaseKeyCheckFailure(message: "partial key adoption persisted") }
        return table
    }
}

func runCollaborationDatabaseKeyChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-key-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 71, count: 32), wrongKey = Data(repeating: 72, count: 32)

    // Already migrated databases must authenticate on every open, not only when
    // a migration happens to decrypt an existing snapshot.
    let current = try await seedKeyFixture(root, name: "current", key: key)
    let currentDB = try DatabaseQueue(path: current.path)
    let initial = try await ciphertextProof(currentDB)
    try refusesKey { _ = try CollaborationStore(path: current.path, masterKey: wrongKey) }
    try keyExpect(try await ciphertextProof(currentDB) == initial, "wrong-key reopen preserves snapshots, operations and heads")
    let reopened = try CollaborationStore(path: current.path, masterKey: key)
    for state in current.states {
        let actual = try await reopened.state(token: current.token, area: state.scope.area.rawValue)
        try keyExpect(try actual.document.canonicalData() == state.document.canonicalData(), "correct-key reopen preserves exact document")
    }

    // Simulate a genuine pre-marker v2 database without rewriting ciphertext.
    let adoption = try await seedKeyFixture(root, name: "adoption", key: key)
    let adoptionDB = try DatabaseQueue(path: adoption.path)
    try await removeMarkerForV2Fixture(adoptionDB)
    let beforeAdoption = try await ciphertextProof(adoptionDB)
    try refusesKey { _ = try CollaborationStore(path: adoption.path, masterKey: wrongKey) }
    try keyExpect(!(try await hasAdoptedKey(adoptionDB)), "wrong-key v2 adoption leaves no marker or migration record")
    try keyExpect(try await ciphertextProof(adoptionDB) == beforeAdoption, "failed v2 adoption rolls back without ciphertext changes")
    let adopted = try CollaborationStore(path: adoption.path, masterKey: key)
    try keyExpect(try await hasAdoptedKey(adoptionDB), "correct key adopts an unmarked v2 database")
    try keyExpect(try await ciphertextProof(adoptionDB) == beforeAdoption, "adoption does not reencrypt or rewrite stored state")
    for state in adoption.states {
        let actual = try await adopted.state(token: adoption.token, area: state.scope.area.rawValue)
        try keyExpect(try actual.document.canonicalData() == state.document.canonicalData(), "adopted key reads original shared content")
    }

    // The last snapshot and last operation must be authenticated too. Validating
    // only the first snapshot would miss these independently damaged records.
    let allRecords = try await seedKeyFixture(root, name: "all-records", key: key)
    let recordsDB = try DatabaseQueue(path: allRecords.path)
    try await removeMarkerForV2Fixture(recordsDB)
    let intact = try await ciphertextProof(recordsDB)
    let secondArea: String = try await recordsDB.read { db in try String.fetchOne(db, sql: "SELECT id FROM areas ORDER BY id DESC LIMIT 1")! }
    try await recordsDB.write { db in
        try db.execute(sql: "UPDATE areas SET snapshot=? WHERE id=?", arguments: [Data([1, 2, 3]), secondArea])
    }
    let damagedSnapshot = try await ciphertextProof(recordsDB)
    try refusesKey { _ = try CollaborationStore(path: allRecords.path, masterKey: key) }
    try keyExpect(!(try await hasAdoptedKey(recordsDB)), "a damaged later snapshot blocks key adoption")
    try keyExpect(try await ciphertextProof(recordsDB) == damagedSnapshot, "failed snapshot validation preserves damaged evidence")
    try await recordsDB.write { db in
        try db.execute(sql: "UPDATE areas SET snapshot=? WHERE id=?", arguments: [intact.snapshots.last!, secondArea])
        try db.execute(sql: "UPDATE operations SET command=? WHERE area=?", arguments: [Data([4, 5, 6]), secondArea])
    }
    let damagedOperation = try await ciphertextProof(recordsDB)
    try refusesKey { _ = try CollaborationStore(path: allRecords.path, masterKey: key) }
    try keyExpect(!(try await hasAdoptedKey(recordsDB)), "a damaged later operation blocks key adoption")
    try keyExpect(try await ciphertextProof(recordsDB) == damagedOperation, "failed operation validation preserves damaged evidence")
    try await recordsDB.write { db in
        try db.execute(sql: "UPDATE operations SET command=? WHERE area=?", arguments: [intact.commands.last!, secondArea])
    }
    _ = try CollaborationStore(path: allRecords.path, masterKey: key)
    try keyExpect(try await ciphertextProof(recordsDB) == intact, "restored records adopt without a ciphertext rewrite")

    // A malformed marker must never be replaced with a fresh marker under a
    // supplied key; that would turn corruption or a wrong key into data loss.
    let corrupt = Data([9, 8, 7, 6])
    try await currentDB.write { db in try db.execute(sql: "UPDATE collaboration_key_marker SET sealed=? WHERE id=1", arguments: [corrupt]) }
    try refusesKey { _ = try CollaborationStore(path: current.path, masterKey: key) }
    let preserved = try await currentDB.read { db in try Data.fetchOne(db, sql: "SELECT sealed FROM collaboration_key_marker WHERE id=1") }
    try keyExpect(preserved == corrupt, "corrupt marker is preserved rather than healed")
    try keyExpect(try await ciphertextProof(currentDB) == initial, "corrupt marker refusal leaves all encrypted state unchanged")
    try await currentDB.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='collaboration-v2-head-revision'")
    }
    // A pending migration must not run first and hide the marker failure behind
    // its own SQL error (the head column deliberately still exists here).
    try refusesKey { _ = try CollaborationStore(path: current.path, masterKey: key) }
    let pending = try await currentDB.read { db in try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier='collaboration-v2-head-revision'") }
    try keyExpect(pending == nil, "marker authentication precedes even a pending migration")

    // Even an empty current database is key-bound, before its first snapshot.
    let emptyPath = root.appendingPathComponent("empty.sqlite").path
    _ = try CollaborationStore(path: emptyPath, masterKey: key)
    try refusesKey { _ = try CollaborationStore(path: emptyPath, masterKey: wrongKey) }
    print("Collaboration database key checks passed: every-open marker authentication, atomic v2 adoption, all-record validation and corruption preservation.")
}
