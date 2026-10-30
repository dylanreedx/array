import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

private struct GeometryCheckFailure: Error, CustomStringConvertible { let description: String }
private func geometryExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw GeometryCheckFailure(description: message) }
    print("PASS shared geometry: \(message)")
}

func runSharedAreaGeometryChecks() throws {
    typealias S = SharedArea
    var document = S.Document()
    let a = S.Item(id: .init(), kind: .discussion), b = S.Item(id: .init(), kind: .discussion)
    let pa = S.Position(id: .init(), object: a.id, rect: .init(x: -300, y: 80, width: 240, height: 180), z: 7)
    let pb = S.Position(id: .init(), object: b.id, rect: .init(x: 100, y: -50, width: 320, height: 260), z: 9)
    let initial = S.Command(area: document.id, expectedRevision: 0, edits: [.admit(a, pa), .admit(b, pb)])
    try document.apply(initial)
    let original = document
    var history = SharedAreaGeometryHistory()
    let movedA = S.Rect(x: pa.rect.x + 70, y: pa.rect.y - 40, width: pa.rect.width, height: pa.rect.height)
    let movedB = S.Rect(x: pb.rect.x + 70, y: pb.rect.y - 40, width: pb.rect.width, height: pb.rect.height)
    let group = try history.move(in: document, frames: [pa.id: movedA, pb.id: movedB])
    try geometryExpect(group.command.edits.count == 2 && group.command.expectedRevision == 1,
        "one group gesture is one atomic two-placement command")
    try document.apply(group.command)
    try history.acknowledge(group, revision: document.revision)
    try geometryExpect(document.positions.first(where: { $0.id == pa.id })?.rect == movedA
        && document.positions.first(where: { $0.id == pb.id })?.rect == movedB
        && document.positions.map(\.z) == original.positions.map(\.z),
        "negative-origin group movement changes complete frames and preserves ordering")
    try geometryExpect(document.placementWrite(for: pa.id)?.operation == group.command.id
        && document.placementWrite(for: pa.id)?.revision == 2,
        "reducer records causal write identity beside accepted geometry")
    let roundTrip = try JSONDecoder().decode(S.Document.self, from: document.canonicalData())
    try geometryExpect(roundTrip == document, "geometry provenance survives the real snapshot codec")

    // Content on another object does not invalidate an otherwise applicable
    // geometry inverse. Whole-document rollback would erase this teammate post.
    let post = S.Post(id: .init(), object: b.id, author: .init(), text: "Teammate discussion after movement")
    try document.apply(.init(area: document.id, expectedRevision: document.revision, edits: [.post(post)]))
    let undo = try history.undo(in: document)
    try document.apply(undo.command); try history.acknowledge(undo, revision: document.revision)
    try geometryExpect(document.positions == original.positions && document.posts.last == post,
        "semantic Undo restores only its placements and preserves a newer teammate post")
    let redo = try history.redo(in: document)
    try document.apply(redo.command); try history.acknowledge(redo, revision: document.revision)
    try geometryExpect(document.positions.first(where: { $0.id == pa.id })?.rect == movedA
        && document.posts.last == post, "Redo is another conditional authorized placement operation")
    let count = history.undoCount
    try history.acknowledge(redo, revision: document.revision)
    try geometryExpect(history.undoCount == count, "duplicate delivery receipts never duplicate geometry history")

    // A teammate can move away and return to exactly the same frame. Merely
    // checking geometry equality would incorrectly revive our old inverse.
    var away = document.positions.first(where: { $0.id == pa.id })!
    away.rect = .init(x: movedA.x + 13, y: movedA.y + 21, width: movedA.width, height: movedA.height)
    try document.apply(.init(area: document.id, expectedRevision: document.revision, edits: [.place(away)]))
    var back = away; back.rect = movedA
    try document.apply(.init(area: document.id, expectedRevision: document.revision, edits: [.place(back)]))
    let beforeRefusal = try document.canonicalData()
    do {
        _ = try history.undo(in: document)
        throw GeometryCheckFailure(description: "teammate ABA made an old inverse applicable")
    } catch SharedAreaGeometryHistory.Failure.changedByCollaborator {
        try geometryExpect(try document.canonicalData() == beforeRefusal,
            "equal-frame teammate ABA invalidates Undo without overwriting either group member")
    }

    var conflicts = original
    let first = try SharedAreaGeometryHistory().move(in: conflicts, frames: [pa.id: movedA])
    let competing = try SharedAreaGeometryHistory().move(in: conflicts, frames: [pa.id: movedB, pb.id: movedA])
    try conflicts.apply(first.command)
    let accepted = try conflicts.canonicalData()
    do {
        try conflicts.apply(competing.command)
        throw GeometryCheckFailure(description: "stale competing group changed a frame")
    } catch S.Failure.conflict {
        try geometryExpect(try conflicts.canonicalData() == accepted,
            "conflicting simultaneous group is refused atomically with no mixed coordinates")
    }
    do {
        _ = try history.move(in: document, frames: [pa.id: .init(x: .nan, y: 0, width: 1, height: 1)])
        throw GeometryCheckFailure(description: "nonfinite geometry was prepared")
    } catch SharedAreaGeometryHistory.Failure.invalidGeometry {
        print("PASS shared geometry: invalid geometry cannot become a prepared command")
    }
    do {
        _ = try history.move(in: document, frames: [.init(): movedA])
        throw GeometryCheckFailure(description: "unknown placement became an implicit membership admission")
    } catch SharedAreaGeometryHistory.Failure.missingPlacement {
        print("PASS shared geometry: geometry cannot create a member from an unknown placement")
    }

    // Local multi-step lineage remains useful without blessing remote writes.
    var local = original, localHistory = SharedAreaGeometryHistory()
    let one = try localHistory.move(in: local, frames: [pa.id: movedA])
    try local.apply(one.command); try localHistory.acknowledge(one, revision: local.revision)
    let two = try localHistory.move(in: local, frames: [pa.id: movedB], kind: .resize)
    try local.apply(two.command); try localHistory.acknowledge(two, revision: local.revision)
    for _ in 0..<2 { let inverse = try localHistory.undo(in: local); try local.apply(inverse.command); try localHistory.acknowledge(inverse, revision: local.revision) }
    try geometryExpect(local.positions == original.positions && localHistory.redoCount == 2,
        "successive own Undo follows causal lineage instead of treating compensation as a teammate write")
    for _ in 0..<2 { let inverse = try localHistory.redo(in: local); try local.apply(inverse.command); try localHistory.acknowledge(inverse, revision: local.revision) }
    try geometryExpect(local.positions.first(where: { $0.id == pa.id })?.rect == movedB,
        "successive Redo restores the two accepted intentions in order")

    var oldSnapshot = try JSONSerialization.jsonObject(with: original.canonicalData()) as! [String: Any]
    oldSnapshot.removeValue(forKey: "placementWrites")
    let legacy = try JSONDecoder().decode(S.Document.self, from: JSONSerialization.data(withJSONObject: oldSnapshot))
    try geometryExpect(legacy.positions == original.positions && legacy.placementWrite(for: pa.id) == nil,
        "legacy snapshots keep geometry but do not invent causal Undo evidence")
    var malformed = try JSONSerialization.jsonObject(with: original.canonicalData()) as! [String: Any]
    var stamps = malformed["placementWrites"] as! [[String: Any]]
    stamps[0]["revision"] = 99
    malformed["placementWrites"] = stamps
    do {
        _ = try JSONDecoder().decode(S.Document.self, from: JSONSerialization.data(withJSONObject: malformed))
        throw GeometryCheckFailure(description: "snapshot forged a placement revision beyond its receipt")
    } catch S.Failure.invalidReference {
        print("PASS shared geometry: snapshot provenance requires a real matching operation receipt")
    }
    try runSharedAreaGeometryLedgerChecks()
    print("Shared geometry contracts passed: atomic groups, conditional compensation, teammate ABA, conflicting moves, strict provenance, legacy snapshots and durable inverse recovery.")
}
