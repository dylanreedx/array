import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct DeletionFailure: Error { let message: String }
private func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw DeletionFailure(message: message) }
    print("PASS: deletion: \(message)")
}

private struct DeletionHTTP: Sendable {
    let base: URL
    func send(_ method: String, _ path: String, token: String?, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 10
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, bytes)
    }
    func json<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, token: String?, body: (any Encodable)? = nil, status: Int) async throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let (actual, data) = try await send(method, path, token: token, body: try body.map { try encoder.encode($0) })
        guard actual == status else { throw DeletionFailure(message: "\(method) \(path): expected \(status), got \(actual) \(String(decoding: data, as: UTF8.self))") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private struct Blocked: Decodable { let code: String; let areas: [UUID] }
private struct Code: Decodable { let code: String }

/// Every table, and which of the four owners (`areas`, `people`, `devices`,
/// `hosts`, `share_links`) each of its columns points at.
private func foreignKeys(_ db: Database) throws -> [String: [(column: String, parent: String)]] {
    var result: [String: [(column: String, parent: String)]] = [:]
    for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name<>'grdb_migrations'") {
        result[table] = try Row.fetchAll(db, sql: "SELECT \"from\" AS column, \"table\" AS parent FROM pragma_foreign_key_list(?)", arguments: [table])
            .map { (column: $0["column"], parent: $0["parent"]) }
    }
    return result
}

/// One row in every table that hangs off an area, pointing at `area` and at
/// `device`/`host`/`person`, built from the live schema so a table added later
/// gets a row too. Values that are not keys are filler of the column's type.
private func fillEveryAreaTable(_ db: Database, area: String, device: String, host: String, person: String) throws -> String {
    let keys = try foreignKeys(db)
    let link = UUID().uuidString
    let order = ["share_links"] + keys.keys.filter { $0 != "share_links" }.sorted()
    for table in order {
        let references = keys[table] ?? []
        guard references.contains(where: { $0.parent == "areas" || $0.parent == "share_links" }) else { continue }
        let columns = try Row.fetchAll(db, sql: "SELECT name, type, \"notnull\" AS required, pk FROM pragma_table_info(?)", arguments: [table])
        var names: [String] = [], values: [(any DatabaseValueConvertible)?] = []
        for column in columns {
            let name: String = column["name"], type = (column["type"] as String).uppercased()
            let parent = references.first { $0.column == name }?.parent
            let value: (any DatabaseValueConvertible)?
            switch parent {
            case "areas": value = area
            case "devices": value = device
            case "hosts": value = host
            case "people": value = person
            case "share_links": value = link
            default:
                if table == "share_links", name == "id" { value = link }
                else if type.contains("TEXT") { value = UUID().uuidString }
                else if type.contains("INT") { value = 0 }
                else if type.contains("DOUBLE") || type.contains("REAL") { value = 1.0 }
                else if type.contains("BLOB") { value = Data(UUID().uuidString.utf8) }
                else { value = (column["required"] as Int) == 1 ? UUID().uuidString : nil }
            }
            names.append(name); values.append(value)
        }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        // A row the run already made (G's membership of X) is kept as it is.
        try db.execute(sql: "INSERT OR IGNORE INTO \(table)(\(names.joined(separator: ","))) VALUES (\(placeholders))", arguments: StatementArguments(values))
        let key = references.contains { $0.parent == "areas" } ? ("area", area) : ("link", link)
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(key.0)=?", arguments: [key.1]) ?? 0 > 0 else {
            throw DeletionFailure(message: "fixture: no row in \(table) for the area")
        }
    }
    return link
}

/// Rows anywhere that still point at one of `ids` through a foreign key.
private func referencing(_ db: Database, _ ids: Set<String>) throws -> [String] {
    var found: [String] = []
    for (table, references) in try foreignKeys(db) {
        for reference in references {
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(reference.column) IN (\(ids.map { "'\($0)'" }.joined(separator: ",")))") ?? 0
            if count > 0 { found.append("\(table).\(reference.column)=\(count)") }
        }
    }
    return found
}

private func totalRows(_ db: Database) throws -> Int {
    try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        .reduce(0) { $0 + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($1)") ?? 0) }
}

func runCollaborationDeletionChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-deletion-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 41, count: 32), path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let adminToken = "deletion-check-admin-token-" + UUID().uuidString
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0, adminToken: adminToken), collaboration: store)
    try await server.start()
    let raw = try DatabaseQueue(path: path)
    do {
        let api = DeletionHTTP(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration/v1")!)
        let admin = DeletionHTTP(base: URL(string: "http://127.0.0.1:\(server.listeningAdminPort!)/collaboration")!)
        let publicRoot = DeletionHTTP(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration")!)
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await api.json(Collaboration.Credential.self, "POST", "enrollments/redeem", token: nil,
                                      body: Collaboration.RedeemEnrollment(code: enrollment.code, deviceLabel: label), status: 201)
        }
        func join(_ guest: Collaboration.Credential, _ area: UUID, by owner: Collaboration.Credential) async throws {
            let invite = try await api.json(Collaboration.Invitation.self, "POST", "areas/\(area)/invitations", token: owner.token,
                                            body: Collaboration.InviteRequest(person: guest.identity.person), status: 201)
            _ = try await api.json(Collaboration.Scope.self, "POST", "invitations/accept", token: guest.token, body: Collaboration.AcceptInvitation(code: invite.code), status: 200)
        }
        func post(_ who: Collaboration.Credential, _ area: UUID) async throws {
            let state = try await api.json(Collaboration.State.self, "GET", "areas/\(area)", token: who.token, status: 200)
            let thread = SharedArea.Item(id: .init(), kind: .discussion)
            let command = SharedArea.Command(area: .init(area), expectedRevision: state.document.revision, edits: [
                .admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 400, height: 300))),
                .post(.init(id: .init(), object: thread.id, author: who.identity.person, text: "deletion check"))])
            _ = try await api.json(Collaboration.Receipt.self, "POST", "areas/\(area)/commands", token: who.token,
                                   body: Collaboration.Mutation(epoch: state.scope.epoch, command: command), status: 200)
        }

        // The throwaway run: owner O and guest G in area X. A real teammate K
        // owns area Y, where G also works and H only joined.
        let o = try await person("Throwaway owner"), g = try await person("Throwaway guest")
        let k = try await person("Keeper"), h = try await person("Bystander")
        let x = try await api.json(Collaboration.State.self, "POST", "areas", token: o.token, status: 201).scope.area.rawValue
        let y = try await api.json(Collaboration.State.self, "POST", "areas", token: k.token, status: 201).scope.area.rawValue
        try await join(g, x, by: o); try await join(g, y, by: k); try await join(h, y, by: k)
        try await post(o, x); try await post(g, x); try await post(g, y)
        let gHost = try await api.json(Collaboration.Host.self, "POST", "hosts", token: g.token, status: 201)
        _ = try await api.json(Collaboration.Host.self, "POST", "hosts", token: o.token, status: 201)
        _ = try await raw.write { db in
            try fillEveryAreaTable(db, area: x.uuidString, device: g.identity.device.uuidString,
                                   host: gHost.id.rawValue.uuidString, person: g.identity.person.rawValue.uuidString)
        }

        // The lists the deletion walks cover every table that points at an
        // area, a link, a person, a device or a host. A table added later
        // without a deletion rule turns this red.
        try await raw.read { db in
            let keys = try foreignKeys(db)
            let areaTables = Set(keys.filter { $0.value.contains { $0.parent == "areas" } }.map(\.key))
            try expect(areaTables == Set(CollaborationStore.areaOwnedTables + ["share_links"]),
                       "every table that references an area is deleted with it (\(areaTables.subtracting(CollaborationStore.areaOwnedTables + ["share_links"]).sorted()))")
            let linkTables = Set(keys.filter { $0.value.contains { $0.parent == "share_links" } }.map(\.key))
            try expect(linkTables == ["share_link_admissions", "share_link_joins"], "every table that references a share link is deleted with its area")
            let personHandled: Set<String> = ["devices", "enrollments", "members", "invitations", "share_link_admissions"]
            let personTables = Set(keys.filter { $0.value.contains { $0.parent == "people" } }.map(\.key))
            try expect(personTables == personHandled, "every table that references a person is cleared with them (\(personTables.subtracting(personHandled).sorted()))")
            let history = Set(CollaborationStore.deviceHistoryColumns.map { "\($0.table).\($0.column)" })
            let deviceHandled: Set<String> = ["enrollments.issuer_device", "hosts.device", "invitations.issuer"]
            let deviceColumns = Set(keys.flatMap { table, refs in refs.filter { $0.parent == "devices" || $0.parent == "hosts" }.map { "\(table).\($0.column)" } })
            try expect(deviceColumns == history.union(deviceHandled),
                       "every device or host reference either blocks deletion as history or is cleared (\(deviceColumns.subtracting(history.union(deviceHandled)).sorted()))")
        }

        // Admission: the admin port, with the token, and nowhere else.
        try expect(try await admin.send("GET", "people", token: nil).0 == 401, "the admin routes refuse a request with no token")
        try expect(try await admin.send("GET", "people", token: adminToken + "x").0 == 401, "the admin routes refuse a wrong token")
        try expect(try await admin.send("DELETE", "areas/\(x)", token: o.token).0 == 401, "a member's own token is not an admin token")
        let fromPublic = try await publicRoot.send("DELETE", "areas/\(x)", token: adminToken)
        try expect(fromPublic.0 != 200, "the public port has no admin deletion (\(fromPublic.0))")
        let people = try await admin.json([CollaborationPersonSummary].self, "GET", "people", token: adminToken, status: 200)
        try expect(Set(people.map(\.label)) == ["Throwaway owner", "Throwaway guest", "Keeper", "Bystander"], "the operator lists people by label")
        let gDetail = try await admin.json(CollaborationPersonDetail.self, "GET", "people/\(g.identity.person.rawValue)", token: adminToken, status: 200)
        try expect(Set(gDetail.memberships.map(\.area)) == [x, y], "the operator sees every area a person is in")

        // A person whose work sits in an area that stays is refused, untouched.
        let before = try await raw.read(totalRows)
        let blocked = try await admin.json(Blocked.self, "DELETE", "people/\(g.identity.person.rawValue)", token: adminToken, status: 409)
        try expect(blocked.code == "personHasAreas" && Set(blocked.areas) == [x, y], "a person with history in kept areas is refused, naming them")
        let ownerBlocked = try await admin.json(Blocked.self, "DELETE", "people/\(k.identity.person.rawValue)", token: adminToken, status: 409)
        try expect(ownerBlocked.areas == [y], "the only owner of an area is refused")
        try expect(try await raw.read(totalRows) == before, "a refused deletion changes nothing")
        _ = try await api.json(Collaboration.State.self, "GET", "areas/\(x)", token: g.token, status: 200)

        // A waiting update request is released when its area goes, not left
        // hanging. Z is a clean area: X holds schema filler no read can decode.
        let z = try await api.json(Collaboration.State.self, "POST", "areas", token: o.token, status: 201).scope.area.rawValue
        let head = try await api.json(Collaboration.Updates.self, "POST", "areas/\(z)/updates", token: o.token,
                                      body: Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0), status: 200)
        let waitBody = try JSONEncoder().encode(Collaboration.UpdateRequest(after: head.nextCursor, presenceVersion: head.presenceVersion, waitMilliseconds: 20_000))
        let waitStart = Date()
        async let waiting = api.send("POST", "areas/\(z)/updates", token: o.token, body: waitBody)
        try await Task.sleep(for: .milliseconds(500))
        _ = try await admin.json(CollaborationDeletionReport.self, "DELETE", "areas/\(z)", token: adminToken, status: 200)
        let released = try await waiting
        try expect(released.0 == 404 && Date().timeIntervalSince(waitStart) < 10,
                   "a waiting update request on a deleted area returns at once (\(released.0) after \(String(format: "%.1f", Date().timeIntervalSince(waitStart))) s)")

        // Delete X: every row of it goes, nothing dangles, Y is untouched.
        let yBefore = try await api.json(Collaboration.State.self, "GET", "areas/\(y)", token: k.token, status: 200)
        let deleted = try await admin.json(CollaborationDeletionReport.self, "DELETE", "areas/\(x)", token: adminToken, status: 200)
        try expect(deleted.id == x && deleted.rows > 0, "the operator deletes an area (\(deleted.rows) rows)")
        let leftovers = try await raw.read { db in
            try referencing(db, [x.uuidString]) + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM areas WHERE id=?", arguments: [x.uuidString]) == 0 ? [] : ["areas"])
        }
        try expect(leftovers.isEmpty, "no row anywhere still points at the deleted area (\(leftovers))")
        try expect(try await raw.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty, "the database passes a foreign key check")
        try expect(try await api.send("GET", "areas/\(x)", token: o.token).0 == 404, "the owner no longer reaches the deleted area")
        try expect(try await admin.send("DELETE", "areas/\(x)", token: adminToken).0 == 404, "deleting it again answers 404")
        let yAfter = try await api.json(Collaboration.State.self, "GET", "areas/\(y)", token: k.token, status: 200)
        try expect(try yAfter.document.canonicalData() == yBefore.document.canonicalData() && yAfter.scope.epoch == yBefore.scope.epoch,
                   "another area is untouched")

        // G still has history in Y, a teammate's area: still refused, Y only.
        let stillBlocked = try await admin.json(Blocked.self, "DELETE", "people/\(g.identity.person.rawValue)", token: adminToken, status: 409)
        try expect(stillBlocked.areas == [y], "history in a teammate's area still blocks, and only that area")

        // Self-leave on the public port.
        try expect(try await api.send("DELETE", "areas/\(y)/membership", token: nil).0 == 401, "leaving needs the member's token")
        try expect(try await api.send("DELETE", "areas/\(y)/membership", token: o.token).0 == 404, "a non-member cannot leave")
        try expect(try await api.send("DELETE", "areas/\(y)/membership", token: k.token).0 == 403, "the only owner cannot leave")
        let left = try await api.json(Code.self, "DELETE", "areas/\(y)/membership", token: g.token, status: 200)
        try expect(left.code == "left", "a member leaves an area on their own")
        try expect(try await api.send("GET", "areas/\(y)", token: g.token).0 == 404, "after leaving, the area is out of reach")
        try expect(try await api.send("DELETE", "areas/\(y)/membership", token: g.token).0 == 404, "leaving twice answers 404")
        let afterLeave = try await api.json(Collaboration.State.self, "GET", "areas/\(y)", token: k.token, status: 200)
        try expect(afterLeave.scope.epoch == yAfter.scope.epoch + 1 && afterLeave.document.posts.contains { $0.author == g.identity.person },
                   "leaving moves the epoch on and keeps what they wrote")
        try expect(try await api.send("POST", "areas/\(y)/commands", token: g.token,
                                      body: try JSONEncoder().encode(Collaboration.Mutation(epoch: afterLeave.scope.epoch, command: .init(area: .init(y), expectedRevision: afterLeave.document.revision, edits: [])))).0 == 404,
                   "a member who left cannot write")

        // H joined Y and did nothing: deleting H takes their membership along.
        let hDeleted = try await admin.json(CollaborationDeletionReport.self, "DELETE", "people/\(h.identity.person.rawValue)", token: adminToken, status: 200)
        try expect(hDeleted.id == h.identity.person.rawValue, "a person with no kept history is deleted with their memberships")
        let afterH = try await api.json(Collaboration.State.self, "GET", "areas/\(y)", token: k.token, status: 200)
        try expect(afterH.scope.epoch == afterLeave.scope.epoch + 1, "deleting a member moves their area's epoch on")
        try expect(try await api.send("GET", "self", token: h.token).0 == 401, "a deleted person's token no longer authenticates")

        // O owned only X, now gone: O goes completely.
        _ = try await admin.json(CollaborationDeletionReport.self, "DELETE", "people/\(o.identity.person.rawValue)", token: adminToken, status: 200)
        let oDevices = Set([o.identity.device.uuidString, o.identity.person.rawValue.uuidString, h.identity.device.uuidString, h.identity.person.rawValue.uuidString])
        let oLeft = try await raw.read { db in try referencing(db, oDevices) }
        try expect(oLeft.isEmpty, "no row anywhere still points at a deleted person or their devices (\(oLeft))")
        try expect(try await raw.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty, "the database still passes a foreign key check")
        try expect(try await admin.send("GET", "people/\(o.identity.person.rawValue)", token: adminToken).0 == 404, "a deleted person is gone")
        try expect(try await admin.send("DELETE", "people/\(UUID())", token: adminToken).0 == 404, "an unknown person answers 404")
        try expect(try await admin.send("DELETE", "areas/not-a-uuid", token: adminToken).0 == 404, "a malformed id answers 404")
        let kept = try await admin.json([CollaborationPersonSummary].self, "GET", "people", token: adminToken, status: 200)
        try expect(Set(kept.map(\.label)) == ["Throwaway guest", "Keeper"], "only the deleted people are gone")

        // The existing companion admin page on the same port is unchanged.
        let page = try await DeletionHTTP(base: URL(string: "http://127.0.0.1:\(server.listeningAdminPort!)")!).send("GET", "", token: nil)
        try expect(page.0 == 200 && String(decoding: page.1, as: UTF8.self).contains("Array Relay Admin"), "the companion admin page still answers")
        try await server.stop()
    } catch { try? await server.stop(); throw error }

    // No token configured: the routes refuse rather than open up.
    let open = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await open.start()
    do {
        let admin = DeletionHTTP(base: URL(string: "http://127.0.0.1:\(open.listeningAdminPort!)/collaboration")!)
        let refused = try await admin.send("GET", "people", token: "anything-at-all-anything-at-all-anything")
        try expect(refused.0 == 403 && String(decoding: refused.1, as: UTF8.self).contains("adminTokenNotConfigured"), "with no admin token configured the routes refuse")
        try await open.stop()
    } catch { try? await open.stop(); throw error }
    print("Collaboration deletion checks passed: admin deletion of people and areas, member self-leave, real localhost HTTP.")
}
