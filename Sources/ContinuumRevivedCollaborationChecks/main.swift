import Foundation
import ContinuumRevivedCore

func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw CheckFailure(label: label) }
    print("PASS: \(label)")
}
struct CheckFailure: Error { let label: String }
func refuses(_ expected: SharedArea.Failure, _ action: () throws -> Void) throws {
    do { try action(); throw CheckFailure(label: "expected refusal: \(expected)") }
    catch let error as SharedArea.Failure { try require(error == expected, "refuses \(expected)") }
}
typealias S = SharedArea
if let flag = CommandLine.arguments.firstIndex(of: "--kill-child"), CommandLine.arguments.count > flag + 1 {
    await runKillChild(CommandLine.arguments[flag + 1])
}
if CommandLine.arguments.contains("--artifacts-only") {
    do { try await runSharedArtifactProducerChecks(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if CommandLine.arguments.contains("--kill-relaunch-only") {
    do { try await runCollaborationKillRelaunchChecks(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
do {
let owner = S.ID<S.Person>()
let host = S.ID<S.Host>()
let binding = S.ID<S.Binding>()
let agent = S.Item(id: S.ID(), kind: .agentObservation, source: S.Source(owner: owner, host: host, binding: binding))
let second = S.Item(id: S.ID(), kind: .artifact)
let rect = S.Rect(x: 120, y: 300, width: 640, height: 520).relative(toX: 120, y: 300)
let pos = S.Position(id: S.ID(), object: agent.id, rect: rect)
let pos2 = S.Position(id: S.ID(), object: second.id, rect: S.Rect(x: 800, y: 340, width: 640, height: 520).relative(toX: 120, y: 300))
var doc = S.Document()
let initial = S.Command(area: doc.id, expectedRevision: 0, edits: [.admit(agent, pos), .admit(second, pos2)])
try require(try doc.apply(initial) == .applied(1), "atomic capture accepted")
try require(doc.positions[0].rect.x == 0 && doc.positions[1].rect.x == 680 && doc.positions[1].rect.y == 40, "capture preserves relative layout")
let once = try doc.canonicalData()
try require(try doc.apply(initial) == .duplicate(1), "retry returns original receipt")
try require(try doc.canonicalData() == once, "retry does not mutate document")
let changed = S.Command(area: doc.id, id: initial.id, expectedRevision: 0, edits: [.remove(agent.id)])
try refuses(.changedIntent) { try doc.apply(changed) }
try refuses(.conflict) { try doc.apply(S.Command(area: doc.id, expectedRevision: 0, edits: [.remove(agent.id)])) }
let invalid = S.Position(id: pos.id, object: agent.id, rect: S.Rect(x: 20, y: 0, width: -1, height: 1))
try refuses(.invalidGeometry) {
    try doc.apply(S.Command(area: doc.id, expectedRevision: 1, edits: [.remove(second.id), .place(invalid)]))
}
try require(try doc.canonicalData() == once, "last-edit failure rolls back entire group")
try refuses(.invalidGeometry) {
    let overflow = S.Position(id: pos.id, object: agent.id, rect: S.Rect(x: Double.greatestFiniteMagnitude, y: 0, width: Double.greatestFiniteMagnitude, height: 1))
    try doc.apply(S.Command(area: doc.id, expectedRevision: 1, edits: [.place(overflow)]))
}
let discussion = S.Item(id: S.ID(), kind: .discussion)
let agreement = S.Item(id: S.ID(), kind: .agreement)
func position(_ item: S.Item) -> S.Position { S.Position(id: S.ID(), object: item.id, rect: rect) }
let context = S.Context(id: S.ID(), object: agreement.id, parent: nil, author: owner, text: "Keep changes within the agreed module.")
let post = S.Post(id: S.ID(), object: discussion.id, author: owner, text: "Ready for review.", context: context.id)
let discussionCommand = S.Command(area: doc.id, expectedRevision: 1, edits: [.admit(discussion, position(discussion)), .admit(agreement, position(agreement)), .context(context), .post(post)])
try doc.apply(discussionCommand)
let beforeConflict = try doc.canonicalData()
try refuses(.conflict) {
    let stale = S.Context(id: S.ID(), object: agreement.id, parent: nil, author: owner, text: "Stale draft")
    try doc.apply(S.Command(area: doc.id, expectedRevision: 2, edits: [.context(stale)]))
}
try require(try doc.canonicalData() == beforeConflict, "context conflict preserves accepted history")
let deletion = S.Command(area: doc.id, expectedRevision: 2, edits: [.remove(agent.id)])
try doc.apply(deletion)
let afterDelete = try doc.canonicalData()
try refuses(.duplicateIdentity) {
    // New operation and new placement must not resurrect the old object ID.
    try doc.apply(S.Command(area: doc.id, expectedRevision: 3, edits: [.admit(agent, position(agent))]))
}
try require(try doc.canonicalData() == afterDelete, "deleted identity remains reserved")
var restored = try JSONDecoder().decode(S.Document.self, from: afterDelete)
try require(try restored.apply(initial) == .duplicate(1), "receipt survives snapshot restore")
try refuses(.duplicateIdentity) { try restored.apply(S.Command(area: doc.id, expectedRevision: 3, edits: [.admit(agent, position(agent))])) }
var replay = S.Document(id: doc.id)
for command in [initial, discussionCommand, deletion] { try replay.apply(command) }
try require(try replay.canonicalData() == afterDelete, "accepted replay produces identical canonical bytes")
try refuses(.unsupportedSchema) { try doc.apply(S.Command(schema: 2, area: doc.id, expectedRevision: 3, edits: [.remove(second.id)])) }
try refuses(.wrongArea) { try doc.apply(S.Command(area: S.ID(), expectedRevision: 3, edits: [.remove(second.id)])) }
try refuses(.missingObject) {
    try doc.apply(S.Command(area: doc.id, expectedRevision: 3, edits: [.place(S.Position(id: S.ID(), object: S.ID(), rect: rect))]))
}
let replacement = S.Item(id: S.ID(), kind: .agentObservation, source: agent.source)
try refuses(.duplicateIdentity) {
    try doc.apply(S.Command(area: doc.id, expectedRevision: 3, edits: [.admit(replacement, S.Position(id: pos.id, object: replacement.id, rect: rect))]))
}
let encoded = String(decoding: afterDelete, as: UTF8.self)
for privateKey in ["rootPath", "projectId", "zoneId", "viewport", "runnerHandle", "authToken", "workingDirectory"] {
    try require(!encoded.contains("\"\(privateKey)\""), "portable payload excludes \(privateKey)")
}
// Real local Tile values carry host fields; the geometry adapter must never
// copy those records into its portable command or modify source ownership.
func localTile(x: Double, project: UUID) -> Tile {
    var metadata = TileMetadata(filePath: "/private/collab105-secret/file.swift")
    metadata.filesystemProjectId = project
    metadata.filesystemCheckoutRootPath = "/private/collab105-secret"
    return Tile(id: UUID(), kind: .managedAgent, title: "private-title-sentinel",
        frame: TileFrame(x: x, y: 300, width: 640, height: 520),
        zPosition: FracIndex(value: x / 1000), zoneId: UUID(),
        runtimeRef: RuntimeRef(kind: .terminalSession, id: UUID()), metadata: metadata)
}
let originals = [localTile(x: 120, project: UUID()), localTile(x: 800, project: UUID())]
let localEncoder = JSONEncoder(); localEncoder.outputFormatting = [.sortedKeys]
let originalBytes = try localEncoder.encode(originals)
let capture = try SharedAreaCapture.edits(entries: [
    .init(tile: originals[0], publication: agent, placement: S.ID()),
    .init(tile: originals[1], publication: second, placement: S.ID())
], originX: 120, originY: 300)
var captured = S.Document()
try captured.apply(S.Command(area: captured.id, expectedRevision: 0, edits: capture))
try require(originals[0].metadata.filesystemProjectId != originals[1].metadata.filesystemProjectId,
    "capture fixture uses distinct project owners")
try require(try localEncoder.encode(originals) == originalBytes, "capture preserves local tile records byte for byte")
try require(captured.positions.map(\.rect.x) == [0, 680], "actual Tile adapter preserves model coordinates")
let captureBytes = String(decoding: try captured.canonicalData(), as: UTF8.self)
for sentinel in ["collab105-secret", "private-title-sentinel"] + originals.flatMap({ [$0.id.uuidString, $0.zoneId!.uuidString, $0.runtimeRef!.id.uuidString, $0.metadata.filesystemProjectId!.uuidString] }) {
    try require(!captureBytes.contains(sentinel), "private source sentinel absent from shared document")
}
try refuses(.invalidGeometry) {
    try doc.apply(S.Command(area: doc.id, expectedRevision: 3, edits: [.place(S.Position(id: pos2.id, object: second.id,
        rect: S.Rect(x: .nan, y: 0, width: 1, height: 1)))]))
}
var snapshot = try JSONSerialization.jsonObject(with: afterDelete) as! [String: Any]
snapshot["schema"] = 2
try refuses(.unsupportedSchema) { _ = try JSONDecoder().decode(S.Document.self, from: JSONSerialization.data(withJSONObject: snapshot)) }
snapshot["schema"] = 1
snapshot["positions"] = []
try refuses(.invalidReference) { _ = try JSONDecoder().decode(S.Document.self, from: JSONSerialization.data(withJSONObject: snapshot)) }
try runCollaborationCredentialStoreChecks()
try runSharedAreaLocalStoreChecks()
try runSharedAreaPublicationChecks()
try runSharedAreaGeometryChecks()
try runSharedAreaUsageChecks()
try await runSharedAreaRecoveryChecks()
try await runSharedAgentHostDispatchChecks()
try await runSharedAgentFreshnessChecks()
try await runCollaborationKillRelaunchChecks()
try await runSharedAreaPublicationSubmissionChecks()
try await runSharedAreaControllerChecks()
try await runCollaborationAccountChecks()
try await runSharedAreaControllerHTTPChecks()
try runSharedAreaAgreementReducerChecks()
try await runSharedAreaAgreementHTTPChecks()
try await runCollaborationRetentionRecoveryChecks()
try await runSharedArtifactProducerChecks()
print("Collaboration contracts passed (reducer, reviewed publications, native controller and localhost HTTP; no mounted-scene or runner claims).")

} catch {
    print("FAIL: \(error)")
    exit(1)
}
