import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

private struct GeometryLedgerFailure: Error, CustomStringConvertible { let description: String }
private func ledgerExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw GeometryLedgerFailure(description: message) }
    print("PASS geometry recovery: \(message)")
}
private final class GeometryLedgerWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    func failNext() { lock.withLock { fail = true } }
    func operations() -> AtomicWriterFileOperations {
        var result = AtomicWriterFileOperations.live
        let original = result.writeTemporary
        result.writeTemporary = { [self] data, url in
            let denied = lock.withLock { let value = fail; fail = false; return value }
            if denied { throw CocoaError(.fileWriteUnknown) }
            try original(data, url)
        }
        return result
    }
}

func runSharedAreaGeometryLedgerChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-geometry-ledger-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    var document = SharedArea.Document()
    let item = SharedArea.Item(id: .init(), kind: .discussion)
    let before = SharedArea.Position(id: .init(), object: item.id, rect: .init(x: -240, y: 80, width: 300, height: 210))
    try document.apply(.init(area: document.id, expectedRevision: 0, edits: [.admit(item, before)]))
    let after = SharedArea.Rect(x: -120, y: 60, width: 380, height: 240)
    let store = try SharedAreaGeometryLedgerStore(directory: root, identity: identity, area: document.id)
    var state = SharedAreaGeometryLedger(identity: identity, area: document.id)
    let mutation = try state.history.move(in: document, frames: [before.id: after], kind: .resize)
    state.pending = mutation
    state = try store.save(state)
    let coldStore = try SharedAreaGeometryLedgerStore(directory: root, identity: identity, area: document.id)
    guard var cold = try coldStore.load(), let pending = cold.pending else { throw GeometryLedgerFailure(description: "prepared inverse was not durable") }
    try ledgerExpect(pending.command == mutation.command && pending.changes.first?.before == before
        && cold.history.undoCount == 0,
        "crash before transport retains exact command and inverse without inventing an accepted Undo")
    try document.apply(pending.command)
    // The remote effect happened; the app died before recording its response.
    var authorityProbe = document
    guard case .duplicate(let revision) = try authorityProbe.apply(pending.command) else { throw GeometryLedgerFailure(description: "accepted remote intent lost its receipt") }
    try cold.history.acknowledge(pending, revision: revision)
    cold.pending = nil; cold = try coldStore.save(cold)
    guard var restarted = try coldStore.load() else { throw GeometryLedgerFailure(description: "cold geometry history missing") }
    try ledgerExpect(restarted.pending == nil && restarted.history.canUndo(in: document),
        "remote-success/local-ack crash recovers durable Undo from the exact authoritative receipt")
    let inverse = try restarted.history.undo(in: document)
    restarted.pending = inverse; restarted = try coldStore.save(restarted)
    try document.apply(inverse.command)
    guard var afterUndoCrash = try coldStore.load(), let recoveredInverse = afterUndoCrash.pending else { throw GeometryLedgerFailure(description: "prepared inverse disappeared") }
    var inverseProbe = document
    guard case .duplicate(let inverseRevision) = try inverseProbe.apply(recoveredInverse.command) else { throw GeometryLedgerFailure(description: "inverse receipt missing") }
    try afterUndoCrash.history.acknowledge(recoveredInverse, revision: inverseRevision)
    afterUndoCrash.pending = nil; afterUndoCrash = try coldStore.save(afterUndoCrash)
    try ledgerExpect(document.positions.first == before && afterUndoCrash.history.canRedo(in: document),
        "crash after an Undo effect recovers the matching Redo stack without repeating the inverse")
    let staleBytes = try Data(contentsOf: store.file)
    let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
    try ledgerExpect((permissions?.intValue ?? 0) & 0o777 == 0o600, "device-local inverse history is written with private file permissions")
    do {
        _ = try store.save(state)
        throw GeometryLedgerFailure(description: "stale scene overwrote another geometry generation")
    } catch SharedAreaLocalStoreError.staleGeneration {
        try ledgerExpect(try Data(contentsOf: store.file) == staleBytes,
            "stale multi-view geometry history refuses without overwriting the newer receipt")
    }
    let gate = GeometryLedgerWriteGate()
    let failingStore = try SharedAreaGeometryLedgerStore(directory: root, identity: identity, area: document.id, fileOperations: gate.operations())
    var proposed = afterUndoCrash
    proposed.pending = try proposed.history.redo(in: document)
    gate.failNext()
    do {
        _ = try failingStore.save(proposed)
        throw GeometryLedgerFailure(description: "injected geometry retention failure was ignored")
    } catch is GeometryLedgerFailure { throw GeometryLedgerFailure(description: "injected geometry retention failure was ignored") }
    catch {
        try ledgerExpect(try Data(contentsOf: store.file) == staleBytes && coldStore.load()?.pending == nil,
            "pre-effect ledger failure preserves prior accepted history and retains no partial intent")
    }
    let other = Collaboration.Identity(person: .init(), device: identity.device)
    let wrongScope = try SharedAreaGeometryLedgerStore(directory: root, identity: other, area: document.id)
    do {
        _ = try wrongScope.load()
        throw GeometryLedgerFailure(description: "another principal loaded a device-local inverse")
    } catch SharedAreaLocalStoreError.scopeMismatch {
        print("PASS geometry recovery: history scope binds person, device and shared area")
    }
    var future = try JSONSerialization.jsonObject(with: staleBytes) as! [String: Any]
    future["schema"] = 2
    let futureBytes = try JSONSerialization.data(withJSONObject: future)
    try futureBytes.write(to: store.file, options: .atomic)
    do {
        _ = try store.load()
        throw GeometryLedgerFailure(description: "future geometry history was silently replaced")
    } catch SharedAreaLocalStoreError.unsupportedSchema {
        try ledgerExpect(try Data(contentsOf: store.file) == futureBytes,
            "future history schema is preserved for explicit recovery")
    }
    try staleBytes.write(to: store.file, options: .atomic)
    print("Geometry ledger recovery passed: pre-effect intent, cold authoritative receipt, inverse crash, CAS refusal, failed save and scope/schema preservation.")
}
