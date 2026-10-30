import Foundation
import ContinuumRevivedCore

private struct LocalStoreCheckFailure: Error { let message: String }
private func localStoreExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw LocalStoreCheckFailure(message: message) }
    print("PASS local store: \(message)")
}
private func localStoreRefuses(_ expected: SharedAreaLocalStoreError, _ action: () throws -> Void) throws {
    do { try action(); throw LocalStoreCheckFailure(message: "expected \(expected)") }
    catch let error as SharedAreaLocalStoreError {
        try localStoreExpect(error == expected, "refuses \(expected)")
    }
}

func runSharedAreaLocalStoreChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-local-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://collaboration.example.test/")!)
    let canonicalAlias = try CollaborationServiceEndpoint(URL(string: "https://COLLABORATION.example.test:443")!)
    let person = SharedArea.ID<SharedArea.Person>(), otherPerson = SharedArea.ID<SharedArea.Person>()
    let area = SharedArea.ID<SharedArea.Area>(), host = SharedArea.ID<SharedArea.Host>()
    let own = SharedArea.Item(id: .init(), kind: .agentObservation,
        source: .init(owner: person, host: host, binding: .init()))
    let remote = SharedArea.Item(id: .init(), kind: .agentObservation,
        source: .init(owner: otherPerson, host: .init(), binding: .init()))
    let rect = SharedArea.Rect(x: 0, y: 0, width: 640, height: 520)
    let ownPosition = SharedArea.Position(id: .init(), object: own.id, rect: rect)
    var document = SharedArea.Document(id: area)
    try document.apply(.init(area: area, expectedRevision: 0, edits: [
        .admit(own, ownPosition), .admit(remote, .init(id: .init(), object: remote.id, rect: rect))
    ]))
    let store = try SharedAreaLocalStore(applicationSupportRoot: support, bundleIdentifier: nil, endpoint: endpoint, person: person, area: area)
    let scope = SharedAreaLocalScope(endpoint: endpoint, person: person, area: area)
    let binding = SharedAreaLocalSourceBinding(object: own.id, binding: own.source!.binding, host: host,
        projectID: UUID(), tileID: UUID(), agentID: AgentID(rawValue: UUID()))
    let draft = SharedAreaLocalDraft(object: own.id, text: "private-draft-sentinel")
    var state = SharedAreaLocalState(scope: scope, document: document, observedMembershipEpoch: 1,
        sourceBindings: [binding], view: .init(x: 75, y: -100, zoom: 1.25), drafts: [draft])
    try localStoreExpect(try store.load() == nil, "missing cache is empty only without recovery history")
    state = try store.save(state)
    try localStoreExpect(try store.load() == state, "document, cursor, binding, view and private draft survive save/load")
    let restored = try SharedAreaLocalStore(applicationSupportRoot: support, bundleIdentifier: nil, endpoint: endpoint, person: person, area: area)
    try localStoreExpect(try restored.load()?.appliedRevision == 1, "fresh store restores applied cursor with its document")
    try localStoreExpect(state.resolution(for: own.id) == .localReference(binding), "own source resolves only to explicit local IDs")
    try localStoreExpect(state.resolution(for: remote.id) == .remoteSource(remote.source!), "remote source remains a projection reference")
    try localStoreExpect(state.resolution(for: .init()) == .unavailable, "missing object remains unavailable")

    let prod = try SharedAreaLocalStore(applicationSupportRoot: support, bundleIdentifier: AppChannel.prodBundleIdentifier, endpoint: endpoint, person: person, area: area)
    let account = try SharedAreaLocalStore(applicationSupportRoot: support, endpoint: endpoint, person: otherPerson, area: area)
    let server = try SharedAreaLocalStore(applicationSupportRoot: support, endpoint: .init(URL(string: "https://other.example.test/")!), person: person, area: area)
    let otherArea = try SharedAreaLocalStore(applicationSupportRoot: support, endpoint: endpoint, person: person, area: .init())
    for isolated in [prod, account, server, otherArea] {
        try localStoreExpect(try isolated.load() == nil, "channel/person/endpoint/area scope cannot load another cache")
        try localStoreRefuses(.scopeMismatch) { try isolated.save(state) }
    }
    // Directory separation alone is insufficient: a copied valid dev record
    // must not become a prod cache merely because its remote identity matches.
    try FileManager.default.createDirectory(at: prod.layout.areaDirectory, withIntermediateDirectories: true)
    let devBytes = try Data(contentsOf: store.layout.stateFile)
    try devBytes.write(to: prod.layout.stateFile)
    try localStoreRefuses(.scopeMismatch) { _ = try prod.load() }
    try localStoreExpect(try Data(contentsOf: prod.layout.stateFile) == devBytes,
        "cross-channel cache refusal preserves displaced bytes")
    try FileManager.default.removeItem(at: prod.layout.stateFile)
    let alias = try SharedAreaLocalStore(applicationSupportRoot: support, endpoint: canonicalAlias, person: person, area: area)
    try localStoreExpect(alias.layout.stateFile == store.layout.stateFile && (try alias.load()) == state, "canonical endpoint aliases resolve the same private cache")
    let mode = try FileManager.default.attributesOfItem(atPath: store.layout.stateFile.path)[.posixPermissions] as! NSNumber
    try localStoreExpect(mode.intValue == 0o600, "cached shared content and drafts are owner-readable only")

    var bad = state
    bad.sourceBindings.append(.init(object: remote.id, binding: remote.source!.binding, host: remote.source!.host,
        projectID: UUID(), agentID: AgentID(rawValue: UUID())))
    try localStoreExpect(bad.resolution(for: remote.id) == .unavailable, "forged local binding cannot resolve a remote source before save")
    try localStoreRefuses(.invalidState) { try store.save(bad) }
    bad = state; bad.view.zoom = 0
    try localStoreRefuses(.invalidState) { try store.save(bad) }
    bad = state; bad.drafts.append(draft)
    try localStoreRefuses(.invalidState) { try store.save(bad) }

    let source = root.appendingPathComponent("source-project/.array", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceFiles = ["canvas.json", "agents.json", "registry.json"].map { source.appendingPathComponent($0) }
    for file in sourceFiles { try Data("local-owner-sentinel".utf8).write(to: file) }
    let sourceBytes = try sourceFiles.map { try Data(contentsOf: $0) }
    state.sourceBindings = []
    state.view.x = 200
    state = try store.save(state)
    try localStoreExpect(state.resolution(for: own.id) == .remoteSource(own.source!), "removing a local view binding does not turn a projection into an executor")
    try localStoreExpect(try sourceFiles.map { try Data(contentsOf: $0) } == sourceBytes, "cache/view changes leave source project records byte-identical")
    let portable = String(decoding: try state.document.canonicalData(), as: UTF8.self)
    try localStoreExpect(!portable.contains(draft.text) && !portable.contains(binding.projectID.uuidString)
        && !portable.contains(binding.agentID!.rawValue.uuidString), "portable document excludes private draft and source-local IDs")

    let beforeFault = try Data(contentsOf: store.layout.stateFile)
    var changed = state; changed.view.x = 500; changed.drafts[0].text = "not-yet-committed"
    StoreFileWriter.install(.init(fault: .failWrite(1), scope: support))
    do {
        try store.save(changed)
        StoreFileWriter.uninstall()
        throw LocalStoreCheckFailure(message: "faulted commit reported success")
    } catch is StoreFileWriter.InjectedFailure {
        let trace = StoreFileWriter.uninstall()
        try localStoreExpect(trace.count == 1 && trace[0].outcome == .failed, "atomic cache write participates in the real store fault seam")
    } catch { StoreFileWriter.uninstall(); throw error }
    try localStoreExpect(try Data(contentsOf: store.layout.stateFile) == beforeFault, "failed commit preserves prior cache bytes")
    try localStoreExpect(try store.load() == state, "failed commit does not advance draft/view/cursor")

    // Two views/controllers can share a server revision while editing different
    // private fields. The second must reload/merge explicitly, not erase a draft.
    let baseForWinner = try store.load()!
    var winner = baseForWinner
    var loser = baseForWinner
    winner.drafts[0].text = "winning-private-draft"
    loser.view.x = 900
    state = try store.save(winner)
    try localStoreExpect(state.localGeneration == baseForWinner.localGeneration + 1,
        "save returns an incremented local generation")
    let winningBytes = try Data(contentsOf: store.layout.stateFile)
    try localStoreRefuses(.staleGeneration) { try restored.save(loser) }
    try localStoreExpect(try Data(contentsOf: store.layout.stateFile) == winningBytes,
        "stale same-server-revision private save preserves winning draft bytes")
    try localStoreExpect(try store.load()?.drafts.first?.text == "winning-private-draft",
        "private draft survives a racing view edit")
    var rebased = try restored.load()!
    rebased.view = loser.view
    state = try restored.save(rebased)
    try localStoreExpect(state.drafts.first?.text == "winning-private-draft" && state.view.x == 900,
        "explicit reload/merge preserves both private edits")

    var advanced = document
    try advanced.apply(.init(area: area, expectedRevision: 1,
        edits: [.place(.init(id: ownPosition.id, object: own.id, rect: .init(x: 20, y: 0, width: 640, height: 520)))]))
    var next = state; next.document = advanced; next.observedMembershipEpoch = 2
    next = try store.save(next)
    try localStoreRefuses(.staleGeneration) { try restored.save(state) }
    var backwards = next; backwards.document = document
    try localStoreRefuses(.staleState) { try store.save(backwards) }
    try localStoreExpect(try store.load()?.appliedRevision == 2, "another store cannot roll back the accepted document cursor")
    var loweredEpoch = next; loweredEpoch.observedMembershipEpoch = 1
    try localStoreRefuses(.staleState) { try store.save(loweredEpoch) }

    let currentBytes = try Data(contentsOf: store.layout.stateFile)
    let backupFiles = try FileManager.default.contentsOfDirectory(at: store.layout.backupsDirectory, includingPropertiesForKeys: nil)
    let backupsBefore = try backupFiles.map { try Data(contentsOf: $0) }
    var future = try JSONSerialization.jsonObject(with: currentBytes) as! [String: Any]
    future["schema"] = 999
    let futureBytes = try JSONSerialization.data(withJSONObject: future)
    try futureBytes.write(to: store.layout.stateFile)
    try localStoreRefuses(.unsupportedSchema) { _ = try store.load() }
    try localStoreRefuses(.unsupportedSchema) { try store.save(next) }
    try localStoreExpect(try Data(contentsOf: store.layout.stateFile) == futureBytes, "future schema stays intact despite valid older backups")
    try localStoreExpect(try backupFiles.map { try Data(contentsOf: $0) } == backupsBefore, "schema refusal preserves recovery generations")
    let corrupt = Data("{truncated".utf8)
    try corrupt.write(to: store.layout.stateFile)
    try localStoreRefuses(.corruptState) { _ = try store.load() }
    try localStoreRefuses(.corruptState) { try store.save(next) }
    try localStoreExpect(try Data(contentsOf: store.layout.stateFile) == corrupt, "corrupt primary is never silently replaced by older content")
    try FileManager.default.removeItem(at: store.layout.stateFile)
    try localStoreRefuses(.recoveryRequired) { _ = try store.load() }
    try localStoreRefuses(.recoveryRequired) { try store.save(next) }
    try currentBytes.write(to: store.layout.stateFile)

    let protected = root.appendingPathComponent("protected-file")
    let protectedBytes = Data("outside-cache-sentinel".utf8)
    try protectedBytes.write(to: protected)
    try FileManager.default.removeItem(at: store.layout.stateFile)
    try FileManager.default.createSymbolicLink(at: store.layout.stateFile, withDestinationURL: protected)
    try localStoreRefuses(.invalidRoot) { _ = try store.load() }
    try localStoreRefuses(.invalidRoot) { try store.save(next) }
    try localStoreExpect(try Data(contentsOf: protected) == protectedBytes, "symlinked cache target cannot touch another file")
    try FileManager.default.removeItem(at: store.layout.stateFile)
    try currentBytes.write(to: store.layout.stateFile)
    print("Shared area local store checks passed: isolated cache/bindings/drafts, atomic persistence and refusal preservation; no native scene or runner claim.")
}
