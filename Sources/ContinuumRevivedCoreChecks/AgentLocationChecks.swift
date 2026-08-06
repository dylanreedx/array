import ContinuumRevivedCore
import Foundation

// Queue 91 spatial-awareness P1: the provider-neutral Home / Where / What
// contract. These checks deliberately stay below AppKit and provider transport.
// They prove the first product invariant before proximity or messaging exists:
// activity outside an agent's project cannot silently redefine the project or
// checkout the agent belongs to.
func runAgentLocationContractChecks() {
    checkLegacyRecordProjection()
    checkOutsideWherePreservesHome()
    checkSymlinkEscapeIsOutsideHome()
    checkOutsideWhatPreservesHomeAndWhere()
    checkSharedProjectDistinctCheckouts()
    checkLocationSnapshotIsHostLocal()
    print("AgentLocation contract checks passed: legacy cwd compatibility, stable Home across outside Where/What, distinct checkouts in one project, component- and symlink-aware path relations, and non-Codable host-local boundary")
}

// P1.R1 — today's required `cwd` remains the effective checkout and Where when
// reading a record written before the richer location contract existed.
private func checkLegacyRecordProjection() {
    let projectId = UUID(uuidString: "A9100000-0000-4000-8000-000000000001")!
    let legacy = """
    {
      "schemaVersion": 1,
      "id": "A9100000-0000-4000-8000-000000000002",
      "displayName": "Legacy location",
      "model": "openai-codex/gpt-5.6-sol",
      "thinking": "medium",
      "cwd": "/tmp/continuum-location/project/.worktrees/legacy",
      "projectId": "\(projectId.uuidString)",
      "createdAtReferenceInterval": 806000000.25,
      "lastActivityAtReferenceInterval": 806000001.5
    }
    """

    let record: AgentRecord
    do {
        record = try JSONCodec.makeDecoder().decode(AgentRecord.self, from: Data(legacy.utf8))
    } catch {
        fputs("FAIL: a pre-location AgentRecord still decodes: \(error)\n", stderr)
        Foundation.exit(1)
    }

    let projectRoot = URL(fileURLWithPath: "/tmp/continuum-location/project", isDirectory: true)
    let snapshot = AgentLocationSnapshot.legacy(record: record, projectRoot: projectRoot)
    expect(record.cwd == "/tmp/continuum-location/project/.worktrees/legacy",
           "the location projection does not rewrite legacy AgentRecord.cwd")
    expect(snapshot.home.projectId == projectId,
           "legacy projection preserves the record's logical project identity")
    expect(snapshot.home.projectRoot == projectRoot.standardizedFileURL,
           "legacy projection carries the separately supplied logical project root")
    expect(snapshot.home.checkoutRoot.path == record.cwd,
           "legacy cwd remains the concrete checkout root")
    expect(snapshot.workingLocation.directory.path == record.cwd
            && snapshot.workingLocation.relationToHome == .root,
           "legacy cwd remains the effective Where at checkout root")
}

// P1.R2 — moving Where outside the checkout changes only Where.
private func checkOutsideWherePreservesHome() {
    let home = fixtureHome(checkout: "/tmp/continuum-location/home-a")
    let outside = URL(fileURLWithPath: "/tmp/continuum-location/external", isDirectory: true)
    let snapshot = AgentLocationSnapshot(home: home, whereDirectory: outside)

    expect(snapshot.home == home,
           "an outside Where leaves Home byte-for-byte unchanged")
    expect(snapshot.workingLocation.directory == outside.standardizedFileURL,
           "Where records the outside directory")
    expect(snapshot.workingLocation.relationToHome == .outside
            && snapshot.workingLocation.relativePath == nil,
           "an outside directory is visibly outside rather than a false Home-relative path")

    // Component boundary: `/home-a-copy` is not inside `/home-a` merely because
    // its string has the same prefix.
    let prefixCollision = AgentLocationSnapshot(
        home: home,
        whereDirectory: URL(fileURLWithPath: "/tmp/continuum-location/home-a-copy", isDirectory: true))
    expect(prefixCollision.workingLocation.relationToHome == .outside,
           "path relation uses components, not a raw string prefix")
}

// P2.3 — a lexical child that traverses a symlink outside Home must not be
// presented as inside. Include a missing leaf to cover edit targets whose
// destination has not been created yet.
private func checkSymlinkEscapeIsOutsideHome() {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-location-symlink-\(UUID().uuidString)", isDirectory: true)
    let checkout = fixture.appendingPathComponent("checkout", isDirectory: true)
    let outside = fixture.appendingPathComponent("outside", isDirectory: true)
    let escape = checkout.appendingPathComponent("escape", isDirectory: true)
    do {
        try fileManager.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: escape, withDestinationURL: outside)
        defer { try? fileManager.removeItem(at: fixture) }

        let existingTarget = outside.appendingPathComponent("secret.txt")
        try Data("host-local".utf8).write(to: existingTarget)
        let throughLink = escape.appendingPathComponent("secret.txt")
        let missingThroughLink = escape.appendingPathComponent("new-file.txt")
        let home = fixtureHome(checkout: checkout.path)

        expect(AgentPathRelation.classify(throughLink, relativeTo: home.checkoutRoot) == .outside,
               "an existing target reached through an escaping symlink is outside Home")
        expect(AgentPathRelation.classify(missingThroughLink, relativeTo: home.checkoutRoot) == .outside,
               "a missing edit target beneath an escaping symlink is outside Home")
        expect(AgentLocationSnapshot(home: home, whereDirectory: escape).workingLocation.relationToHome == .outside,
               "Where reached through an escaping symlink is outside Home")
    } catch {
        fputs("FAIL: symlink-aware location fixture: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

// P1.R3 — an external activity target changes What only.
private func checkOutsideWhatPreservesHomeAndWhere() {
    let home = fixtureHome(checkout: "/tmp/continuum-location/home-b")
    let insideWhere = URL(
        fileURLWithPath: "/tmp/continuum-location/home-b/Sources/ContinuumRevived",
        isDirectory: true)
    let before = AgentLocationSnapshot(home: home, whereDirectory: insideWhere)
    let now = Date(timeIntervalSinceReferenceDate: 807_000_000.25)
    let activity = AgentObservedActivity(
        operation: .reading,
        targetPath: URL(fileURLWithPath: "/tmp/continuum-location/reference-project/src/router.ts"),
        startedAt: now,
        updatedAt: now,
        evidenceSource: .toolEvent)
    let after = AgentLocationSnapshot(home: home, whereDirectory: insideWhere, what: activity)

    expect(after.home == before.home,
           "an outside What target leaves Home unchanged")
    expect(after.workingLocation == before.workingLocation,
           "an outside What target leaves Where unchanged")
    expect(after.what?.operation == .reading
            && after.whatRelationToHome == .outside,
           "What records the external read and labels it outside Home")
    expect(after.what?.targetPath?.path == "/tmp/continuum-location/reference-project/src/router.ts",
           "What preserves the normalized observable target")
}

// P1.R4 — logical project identity and concrete checkout identity are separate.
private func checkSharedProjectDistinctCheckouts() {
    let projectId = UUID(uuidString: "A9100000-0000-4000-8000-000000000010")!
    let projectRoot = URL(fileURLWithPath: "/tmp/continuum-location/shared-project", isDirectory: true)
    let homeA = AgentHome(
        projectId: projectId,
        projectRoot: projectRoot,
        checkoutRoot: URL(fileURLWithPath: "/tmp/continuum-location/worktrees/agent-a", isDirectory: true))
    let homeB = AgentHome(
        projectId: projectId,
        projectRoot: projectRoot,
        checkoutRoot: URL(fileURLWithPath: "/tmp/continuum-location/worktrees/agent-b", isDirectory: true))
    let agentA = AgentLocationSnapshot(
        home: homeA,
        whereDirectory: homeA.checkoutRoot.appendingPathComponent("Sources", isDirectory: true))
    let agentB = AgentLocationSnapshot(
        home: homeB,
        whereDirectory: homeB.checkoutRoot.appendingPathComponent("docs", isDirectory: true))

    expect(agentA.home.projectId == agentB.home.projectId,
           "two agents can share one logical project")
    expect(agentA.home.checkoutRoot != agentB.home.checkoutRoot,
           "two agents in one project retain distinct concrete checkouts")
    expect(agentA.workingLocation.relativePath == "Sources"
            && agentB.workingLocation.relativePath == "docs",
           "each Where is relative to its own checkout")
    expect(agentA.workingLocation.relationToHome == .inside
            && agentB.workingLocation.relationToHome == .inside,
           "both checkout-relative directories classify inside their own Home")
}

// P1.R5 — this snapshot carries host paths, so it must not accidentally become
// a companion/spatial wire payload. Public-safe sync projections remain separate
// (`AgentInventory` / `AgentActivityEvent`) and already scrub host/runtime fields.
private func checkLocationSnapshotIsHostLocal() {
    let home = fixtureHome(checkout: "/Users/qa/continuum-location/private-checkout")
    let snapshot = AgentLocationSnapshot(
        home: home,
        whereDirectory: home.checkoutRoot,
        what: AgentObservedActivity(
            operation: .waiting,
            targetPath: nil,
            startedAt: Date(timeIntervalSinceReferenceDate: 807_000_010),
            updatedAt: Date(timeIntervalSinceReferenceDate: 807_000_020),
            evidenceSource: .lifecycleEvent))

    expect(!((snapshot as Any) is any Encodable),
           "the host-path AgentLocationSnapshot is deliberately not Encodable")
    let fieldNames = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
    let forbidden = Set([
        "providerSessionId", "transcriptPath", "resumeCursor", "runtimePayload",
        "tmuxWindowTarget", "worktreeBranch",
    ])
    expect(fieldNames.isDisjoint(with: forbidden),
           "the provider-neutral snapshot contains no provider/runtime routing fields — got \(fieldNames.intersection(forbidden))")
}

private func fixtureHome(checkout: String) -> AgentHome {
    AgentHome(
        projectId: UUID(uuidString: "A9100000-0000-4000-8000-000000000020")!,
        projectRoot: URL(fileURLWithPath: "/tmp/continuum-location/logical-project", isDirectory: true),
        checkoutRoot: URL(fileURLWithPath: checkout, isDirectory: true))
}
