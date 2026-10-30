import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

private struct ServiceEndorsementFailure: Error { let message: String }
/// The store's own authoring validation: an endorsement names the caller, and
/// a viewer cannot endorse. A refused write commits nothing.
func runCollaborationEndorsementChecks() async throws {
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ServiceEndorsementFailure(message: message) }
        print("PASS endorsement authority: \(message)")
    }
    func refusal(_ action: () async throws -> Void) async -> (any Error)? {
        do { try await action(); return nil } catch { return error }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-endorsement-service-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: Data(repeating: 53, count: 32))
    func enroll(_ label: String) async throws -> Collaboration.Credential {
        let code = try await store.provisionPerson(label: label)
        return try await store.redeem(.init(code: code.code, deviceLabel: label))
    }
    let owner = try await enroll("Owner"), editor = try await enroll("Editor"), viewer = try await enroll("Viewer")
    let initial = try await store.createArea(token: owner.token), area = initial.document.id
    for (member, role) in [(editor, Collaboration.Role.editor), (viewer, .viewer)] {
        let invitation = try await store.invite(token: owner.token, area: area.rawValue, request: .init(person: member.identity.person, role: role))
        _ = try await store.accept(token: member.token, code: invitation.code)
    }
    let agreement = SharedArea.Item(id: .init(), kind: .agreement)
    let revision = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: owner.identity.person, text: "Instructions for agents.")
    _ = try await store.apply(token: owner.token, area: area.rawValue, request: .init(epoch: 1, command: .init(area: area, expectedRevision: 0, edits: [
        .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 0, y: 0, width: 300, height: 200))), .context(revision)])))
    func endorse(_ caller: Collaboration.Credential, as person: SharedArea.ID<SharedArea.Person>) async throws {
        _ = try await store.apply(token: caller.token, area: area.rawValue, request: .init(epoch: 1,
            command: .init(area: area, expectedRevision: 1, edits: [.endorse(.init(revision: revision.id, person: person))])))
    }
    let forged = await refusal { try await endorse(editor, as: owner.identity.person) }
    try expect(forged as? CollaborationStoreError == .forbidden, "an editor cannot endorse on the owner's behalf")
    let viewed = await refusal { try await endorse(viewer, as: viewer.identity.person) }
    try expect(viewed as? CollaborationStoreError == .forbidden, "a viewer cannot endorse even as themself")
    let unchanged = try await store.state(token: owner.token, area: area.rawValue).document
    try expect(unchanged.revision == 1 && unchanged.endorsements.isEmpty, "refused endorsements commit nothing")
    try await endorse(editor, as: editor.identity.person)
    let endorsed = try await store.state(token: viewer.token, area: area.rawValue).document
    try expect(endorsed.endorsements(of: revision.id) == [.init(revision: revision.id, person: editor.identity.person)],
        "an editor endorses as themself and every member reads it")
    print("Collaboration endorsement authority checks passed: caller-bound endorsements and viewer refusal against the durable store.")
}
