import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct CapabilityFailure: Error { let message: String }
private struct CapabilityEmpty: Encodable {}
private struct CapabilityHTTP: Sendable {
    let base: URL
    func send(_ method: String, _ path: String, token: String, bytes: Data = Data(), epoch: Int64? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 5
        request.httpBody = method == "POST" ? bytes : nil
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        if let epoch { request.setValue(String(epoch), forHTTPHeaderField: "if-match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }
    func value<T: Decodable, B: Encodable>(_ type: T.Type, _ method: String, _ path: String,
                                         token: String, body: B, expected: Int = 200) async throws -> T {
        let result = try await send(method, path, token: token, bytes: JSONEncoder().encode(body))
        guard result.0 == expected else { throw CapabilityFailure(message: "\(method) \(path) expected \(expected), got \(result.0)") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: result.1)
    }
}
private func capabilityCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw CapabilityFailure(message: label) }
    print("PASS capability: \(label)")
}
private func capabilityDenied(_ result: (Int, Data), status: Int, _ label: String) throws {
    try capabilityCheck(result.0 == status, label)
    let bytes = String(decoding: result.1, as: UTF8.self)
    try capabilityCheck(!bytes.contains("publication-content-allowed") && !bytes.contains("private-host-sentinel"), label + " has no content bytes")
}
private func capabilityInjectPrivateSourceFields(_ value: Any, count: inout Int) -> Any {
    if let array = value as? [Any] { return array.map { capabilityInjectPrivateSourceFields($0, count: &count) } }
    guard var object = value as? [String: Any] else { return value }
    for (key, child) in object { object[key] = capabilityInjectPrivateSourceFields(child, count: &count) }
    if object["owner"] != nil && object["host"] != nil && object["binding"] != nil {
        count += 1
        object["localProjectPath"] = "/private-host-sentinel/checkout"
        object["runnerCredential"] = "private-host-sentinel-runner-credential"
        object["camera"] = ["x": 8888, "privateContext": "private-host-sentinel-camera"]
    }
    return object
}

/// Actual service HTTP exercises scope/operation/ownership checks. No runner
/// exists in this fixture. An editor's prompts go only through the agent
/// prompt route (CollaborationHandoffChecks); a caller-provided grant never
/// creates another route.
func runCollaborationCapabilityChecks() async throws {
    for role in [Collaboration.Role.owner, .editor, .viewer] {
        try capabilityCheck(role.allows(.view), "\(role.rawValue) can view")
        // Full access: whoever a share admits as an editor prompts and stops
        // the shared agent, on its owner's Mac. Approvals and terminals do not move.
        for action in [Collaboration.Capability.promptAgent, .stopAgent] {
            try capabilityCheck(role.allows(action) == (role != .viewer),
                "\(role.rawValue) \(role == .viewer ? "does not grant" : "grants") \(action.rawValue)")
        }
        for action in [Collaboration.Capability.approveProviderRequest, .writeTerminal] {
            try capabilityCheck(!role.allows(action), "\(role.rawValue) does not grant \(action.rawValue)")
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-capability-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 44, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let http = CapabilityHTTP(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration/v1")!)
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await http.value(Collaboration.Credential.self, "POST", "enrollments/redeem", token: "",
                body: Collaboration.RedeemEnrollment(code: enrollment.code, deviceLabel: label), expected: 201)
        }
        let a = try await person("Publisher A"), b = try await person("Collaborator B"), c = try await person("Excluded C")
        let state = try await http.value(Collaboration.State.self, "POST", "areas", token: a.token, body: CapabilityEmpty(), expected: 201)
        let path = "areas/\(state.scope.area.rawValue)"
        let invitation = try await http.value(Collaboration.Invitation.self, "POST", path + "/invitations", token: a.token,
            body: Collaboration.InviteRequest(person: b.identity.person), expected: 201)
        let bScope = try await http.value(Collaboration.Scope.self, "POST", "invitations/accept", token: b.token,
            body: Collaboration.AcceptInvitation(code: invitation.code))
        try capabilityCheck(bScope.allows(.discuss) && bScope.allows(.layout) && bScope.allows(.publish) && !bScope.allows(.manageSharing),
            "editor collaboration capabilities exclude membership management")
        let host = try await http.value(Collaboration.Host.self, "POST", "hosts", token: a.token, body: CapabilityEmpty(), expected: 201)
        let observation = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let position = SharedArea.Position(id: .init(), object: observation.id, rect: .init(x: 20, y: 40, width: 640, height: 520))
        let thread = SharedArea.Item(id: .init(), kind: .discussion)
        let threadPosition = SharedArea.Position(id: .init(), object: thread.id, rect: .init(x: 700, y: 40, width: 500, height: 520))
        let publication = SharedArea.Command(area: state.scope.area, expectedRevision: 0, edits: [
            .admit(observation, position), .admit(thread, threadPosition),
            .post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "publication-content-allowed"))
        ])
        let missingSource = SharedArea.Item(id: .init(), kind: .agentObservation)
        let sourceLessCommand = SharedArea.Command(area: state.scope.area, expectedRevision: 0, edits: [
            .admit(missingSource, .init(id: .init(), object: missingSource.id, rect: position.rect))
        ])
        try capabilityDenied(try await http.send("POST", path + "/commands", token: a.token,
            bytes: JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: sourceLessCommand))), status: 400,
            "agent observation without an explicit source refuses")
        let sourcedDiscussion = SharedArea.Item(id: .init(), kind: .discussion, source: observation.source)
        let invalidKind = SharedArea.Command(area: state.scope.area, expectedRevision: 0, edits: [
            .admit(sourcedDiscussion, .init(id: .init(), object: sourcedDiscussion.id, rect: position.rect))
        ])
        try capabilityDenied(try await http.send("POST", path + "/commands", token: a.token,
            bytes: JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: invalidKind))), status: 400,
            "source binding cannot masquerade as shared discussion")
        // Add unsupported host metadata and forged authority to actual incoming
        // JSON. The typed allowlist must not retain these in snapshot or replay.
        let encoded = try JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: publication))
        var injected = 0
        var raw = capabilityInjectPrivateSourceFields(try JSONSerialization.jsonObject(with: encoded), count: &injected) as! [String: Any]
        try capabilityCheck(injected == 1, "fixture injects unsupported fields into the selected source")
        raw["authorized"] = true
        raw["grants"] = ["promptAgent", "stopAgent", "writeTerminal"]
        raw["localPath"] = "/private-host-sentinel/project"
        var rawCommand = raw["command"] as! [String: Any]
        rawCommand["providerCredential"] = "private-host-sentinel-credential"
        rawCommand["runnerRecord"] = ["agent": "private-host-sentinel-agent"]
        raw["command"] = rawCommand
        let publishResult = try await http.send("POST", path + "/commands", token: a.token, bytes: JSONSerialization.data(withJSONObject: raw))
        try capabilityCheck(publishResult.0 == 200, "explicit source publication is admitted")
        let snapshot = try await http.send("GET", path, token: b.token)
        let replay = try await http.send("POST", path + "/updates", token: b.token,
            bytes: JSONEncoder().encode(Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0)))
        for (label, response) in [("snapshot", snapshot), ("replay", replay)] {
            let bytes = String(decoding: response.1, as: UTF8.self)
            try capabilityCheck(response.0 == 200 && bytes.contains("publication-content-allowed"), "invited editor receives selected \(label)")
            try capabilityCheck(!bytes.contains("private-host-sentinel") && !bytes.contains("providerCredential") && !bytes.contains("runnerRecord") && !bytes.contains("grants"),
                "\(label) excludes unsupported host metadata and caller-supplied grants")
        }
        try capabilityDenied(try await http.send("GET", path, token: c.token), status: 404, "excluded C cannot fetch a known area")
        try capabilityDenied(try await http.send("POST", path + "/updates", token: c.token,
            bytes: JSONEncoder().encode(Collaboration.UpdateRequest(after: 0, waitMilliseconds: 0))), status: 404, "excluded C cannot replay publication")

        var moved = position; moved.rect = .init(x: 140, y: 240, width: 640, height: 520)
        let move = SharedArea.Command(area: state.scope.area, expectedRevision: 1, edits: [.place(moved)])
        try capabilityCheck(bScope.canSubmit(move), "presentation classifier permits editor layout")
        _ = try await http.value(Collaboration.Receipt.self, "POST", path + "/commands", token: b.token,
            body: Collaboration.Mutation(epoch: 1, command: move))
        let arranged = try await http.value(Collaboration.State.self, "GET", path, token: b.token, body: CapabilityEmpty())
        try capabilityCheck(arranged.document.positions.first(where: { $0.object == observation.id })?.rect == moved.rect,
            "editor arranges another owner's observation without owning its source")

        let removal = SharedArea.Command(area: state.scope.area, expectedRevision: 2, edits: [
            .post(.init(id: .init(), object: thread.id, author: b.identity.person, text: "must-not-partially-commit")), .remove(observation.id)
        ])
        var forgedGrant = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: removal))) as! [String: Any]
        forgedGrant["authorized"] = true; forgedGrant["actor"] = a.identity.person.rawValue.uuidString
        forgedGrant["grants"] = ["publish": true, "owner": true]
        try capabilityDenied(try await http.send("POST", path + "/commands", token: b.token,
            bytes: JSONSerialization.data(withJSONObject: forgedGrant)), status: 403, "forged grant cannot remove a teammate's source")
        let unchanged = try await http.value(Collaboration.State.self, "GET", path, token: a.token, body: CapabilityEmpty())
        try capabilityCheck(unchanged.document == arranged.document && !unchanged.document.posts.contains(where: { $0.text == "must-not-partially-commit" }),
            "mixed authorized and forbidden edits leave the entire document unchanged")
        try capabilityDenied(try await http.send("POST", path + "/invitations", token: b.token,
            bytes: JSONEncoder().encode(Collaboration.InviteRequest(person: c.identity.person))), status: 403, "editor cannot expand sharing")
        for action in ["promptAgent", "stopAgent", "approveProviderRequest", "writeTerminal"] {
            try capabilityDenied(try await http.send("POST", path + "/actions/\(action)", token: b.token,
                bytes: JSONSerialization.data(withJSONObject: ["object": observation.id.rawValue.uuidString, "authorized": true])), status: 404,
                "area editor does not create a \(action) endpoint")
        }
        // Owner removal is valid and remains idempotent after the source has
        // disappeared from the current snapshot.
        let ownerRemoval = SharedArea.Command(area: state.scope.area, expectedRevision: 2, edits: [.remove(observation.id)])
        let removed = try await http.value(Collaboration.Receipt.self, "POST", path + "/commands", token: a.token,
            body: Collaboration.Mutation(epoch: 1, command: ownerRemoval))
        let retried = try await http.value(Collaboration.Receipt.self, "POST", path + "/commands", token: a.token,
            body: Collaboration.Mutation(epoch: 1, command: ownerRemoval))
        try capabilityCheck(removed.revision == 3 && !removed.duplicate && retried.revision == 3 && retried.duplicate,
            "publication owner removal retries without resurrecting a source")

        let bHost = try await http.value(Collaboration.Host.self, "POST", "hosts", token: b.token, body: CapabilityEmpty(), expected: 201)
        let bSource = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: b.identity.person, host: bHost.id, binding: .init()))
        let bPublication = SharedArea.Command(area: state.scope.area, expectedRevision: 3, edits: [
            .admit(bSource, .init(id: .init(), object: bSource.id, rect: position.rect))
        ])
        _ = try await http.value(Collaboration.Receipt.self, "POST", path + "/commands", token: b.token,
            body: Collaboration.Mutation(epoch: 1, command: bPublication))
        let ownerOverride = SharedArea.Command(area: state.scope.area, expectedRevision: 4, edits: [.remove(bSource.id)])
        try capabilityDenied(try await http.send("POST", path + "/commands", token: a.token,
            bytes: JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: ownerOverride))), status: 403,
            "area ownership does not override another person's source ownership")

        let queued = SharedArea.Command(area: state.scope.area, expectedRevision: 4, edits: [
            .post(.init(id: .init(), object: thread.id, author: b.identity.person, text: "queued-before-removal"))
        ])
        let removedMember = try await http.send("DELETE", path + "/members/\(b.identity.person.rawValue)", token: a.token, epoch: 1)
        try capabilityCheck(removedMember.0 == 200, "current owner can revoke membership")
        try capabilityDenied(try await http.send("POST", path + "/commands", token: b.token,
            bytes: JSONEncoder().encode(Collaboration.Mutation(epoch: 1, command: queued))), status: 404,
            "queued mutation loses admission when collaborator is removed")
        let final = try await http.value(Collaboration.State.self, "GET", path, token: a.token, body: CapabilityEmpty())
        try capabilityCheck(final.document.revision == 4 && !final.document.posts.contains(where: { $0.text == "queued-before-removal" }),
            "removed collaborator creates no later durable effect")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
}
