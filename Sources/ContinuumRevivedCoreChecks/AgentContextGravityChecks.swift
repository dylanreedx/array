import ContinuumRevivedCore
import Foundation

// Queue 91 spatial-awareness P4: provisional Home/context-gravity engine.
// These checks are pure Core and provider-neutral. They deliberately avoid App,
// real stores, persistence, baselines, and transport.
func runAgentContextGravityChecks() {
    checkContainingProjectZoneWinsOverNearbyCrossProjectTile()
    checkNearbyExternalWhatDoesNotInfluenceHome()
    checkNearbyAgreementDoesNotForceIncidentalSubdirectory()
    checkZoomIndependentWorldDistance()
    checkDraggingActiveOrPinnedTileNeverMutatesScope()
    checkFreezeEventsPreventLaterReinference()
    checkEmptyCanvasNeverFallsBackToProcessCwd()
    checkIsolatedCheckoutInheritanceUsesNewAgentPath()
    print("AgentContextGravity P4 checks passed: P4.R1-P4.R8")
}

private func checkContainingProjectZoneWinsOverNearbyCrossProjectTile() {
    let projectA = project(id: 1, root: "/tmp/continuum-p4/project-a", checkout: "/tmp/continuum-p4/project-a")
    let projectB = project(id: 2, root: "/tmp/continuum-p4/project-b", checkout: "/tmp/continuum-p4/worktrees/agent-b")
    let input = AgentContextGravityInput(
        newAgentFrame: rect(50, 50),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new-a"),
        projectZones: [
            AgentScopeSignal(provenance: .projectZone(zoneId: "zone-a"), frame: AgentWorldRect(x: 0, y: 0, width: 300, height: 300), home: projectA),
        ],
        managedAgents: [
            AgentScopeSignal(provenance: .managedAgent(agentId: "near-b"), frame: rect(52, 52), home: projectB),
        ],
        workspaceId: "workspace")

    let binding = requireProposal(input)
    expect(binding.home.projectId == projectA.projectId, "P4.R1 containing project zone wins over a nearby cross-project tile")
    expect(binding.provenance == .projectZone(zoneId: "zone-a"), "P4.R1 provenance records containing zone")
    expect(binding.home.checkoutRoot.path == "/tmp/continuum-p4/worktrees/new-a", "P4.R1 zone proposal maps to the new agent checkout")
}

private func checkNearbyExternalWhatDoesNotInfluenceHome() {
    let home = project(id: 3, root: "/tmp/continuum-p4/home", checkout: "/tmp/continuum-p4/worktrees/neighbor")
    let externalActivity = AgentObservedActivity(
        operation: .reading,
        targetPath: url("/tmp/continuum-p4/external-repo/src/router.ts"),
        startedAt: Date(timeIntervalSinceReferenceDate: 820_000_000),
        updatedAt: Date(timeIntervalSinceReferenceDate: 820_000_001),
        evidenceSource: .toolEvent)
    let snapshot = AgentLocationSnapshot(
        home: home,
        whereDirectory: home.checkoutRoot.appendingPathComponent("Sources", isDirectory: true),
        what: externalActivity)
    let input = AgentContextGravityInput(
        newAgentFrame: rect(10, 10),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new-home"),
        managedAgents: [
            AgentScopeSignal(
                provenance: .managedAgent(agentId: "reader"),
                frame: rect(12, 12),
                home: snapshot.home,
                relativeDirectory: snapshot.workingLocation.relativePath),
        ],
        workspaceId: "workspace")

    let binding = requireProposal(input)
    expect(binding.home.projectId == home.projectId, "P4.R2 nearby agent Home, not external What, supplies Home")
    expect(binding.home.projectRoot == home.projectRoot, "P4.R2 external What target does not replace projectRoot")
    expect(binding.home.projectRoot?.path != "/tmp/continuum-p4/external-repo", "P4.R2 external What never influences Home")
}

private func checkNearbyAgreementDoesNotForceIncidentalSubdirectory() {
    let shared = project(id: 4, root: "/tmp/continuum-p4/shared", checkout: "/tmp/continuum-p4/worktrees/a")
    let sibling = project(id: 4, root: "/tmp/continuum-p4/shared", checkout: "/tmp/continuum-p4/worktrees/b")
    let other = project(id: 5, root: "/tmp/continuum-p4/other", checkout: "/tmp/continuum-p4/worktrees/c")
    let input = AgentContextGravityInput(
        newAgentFrame: rect(100, 100),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new-shared"),
        managedAgents: [
            AgentScopeSignal(provenance: .managedAgent(agentId: "shared-sources"), frame: rect(110, 100), home: shared, relativeDirectory: "Sources"),
            AgentScopeSignal(provenance: .managedAgent(agentId: "shared-docs"), frame: rect(115, 100), home: sibling, relativeDirectory: "docs"),
            AgentScopeSignal(provenance: .managedAgent(agentId: "single-nearer-other"), frame: rect(101, 100), home: other, relativeDirectory: "src"),
        ],
        workspaceId: "workspace")

    let binding = requireProposal(input, existing: [])
    expect(binding.home.projectId == shared.projectId, "P4.R3 agreement among nearby agents outranks a single incidental closer signal")
    expect(binding.whereDirectory.path == "/tmp/continuum-p4/worktrees/new-shared", "P4.R3 differing incidental subdirectories do not force a subdirectory")
    expect(binding.warning == nil, "P4.R3 no missing-directory warning when no subdirectory was inherited")
}

private func checkZoomIndependentWorldDistance() {
    let projectNear = project(id: 6, root: "/tmp/continuum-p4/near", checkout: "/tmp/continuum-p4/near")
    let projectFar = project(id: 7, root: "/tmp/continuum-p4/far", checkout: "/tmp/continuum-p4/far")
    let worldInput = AgentContextGravityInput(
        newAgentFrame: rect(0, 0),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new-near"),
        managedAgents: [
            AgentScopeSignal(provenance: .managedAgent(agentId: "near"), frame: rect(100, 0), home: projectNear),
            AgentScopeSignal(provenance: .managedAgent(agentId: "far"), frame: rect(250, 0), home: projectFar),
        ],
        workspaceId: "workspace")
    let zoomedViewportWouldChangePixelsButNotWorld = AgentContextGravityInput(
        newAgentFrame: rect(0, 0),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new-near"),
        managedAgents: worldInput.managedAgents,
        workspaceId: "workspace")

    let a = requireProposal(worldInput)
    let b = requireProposal(zoomedViewportWouldChangePixelsButNotWorld)
    expect(a.home.projectId == projectNear.projectId && b.home.projectId == projectNear.projectId, "P4.R4 nearest-neighbor rank uses world frames, not zoom-scaled viewport pixels")
    expect(rect(0, 0).distance(to: rect(100, 0)) < rect(0, 0).distance(to: rect(250, 0)), "P4.R4 distance oracle is world-coordinate geometry")
}

private func checkDraggingActiveOrPinnedTileNeverMutatesScope() {
    let homeA = project(id: 8, root: "/tmp/continuum-p4/a", checkout: "/tmp/continuum-p4/worktrees/new-a")
    let homeB = project(id: 9, root: "/tmp/continuum-p4/b", checkout: "/tmp/continuum-p4/worktrees/b")
    let current = AgentScopeBinding(home: homeA, whereDirectory: homeA.checkoutRoot, provenance: .managedAgent(agentId: "seed"), state: .pinned)
    let movedInput = AgentContextGravityInput(
        newAgentFrame: rect(500, 500),
        newAgentCheckoutRoot: homeA.checkoutRoot,
        managedAgents: [AgentScopeSignal(provenance: .managedAgent(agentId: "b"), frame: rect(501, 500), home: homeB)],
        workspaceId: "workspace")

    let pinnedAfterMove = AgentContextGravityEngine.updateScopeAfterSettledMove(current: current, lifecycle: .zeroTurnUntouched, input: movedInput)
    let provisional = AgentScopeBinding(home: homeA, whereDirectory: homeA.checkoutRoot, provenance: .managedAgent(agentId: "seed"), state: .provisional)
    let activeAfterMove = AgentContextGravityEngine.updateScopeAfterSettledMove(current: provisional, lifecycle: .active, input: movedInput)
    expect(pinnedAfterMove == current, "P4.R5 dragging a pinned tile never mutates Home")
    expect(activeAfterMove == provisional, "P4.R5 dragging an active tile never mutates Home")
}

private func checkFreezeEventsPreventLaterReinference() {
    let homeA = project(id: 10, root: "/tmp/continuum-p4/a", checkout: "/tmp/continuum-p4/worktrees/new-a")
    let homeB = project(id: 11, root: "/tmp/continuum-p4/b", checkout: "/tmp/continuum-p4/worktrees/b")
    let provisional = AgentScopeBinding(home: homeA, whereDirectory: homeA.checkoutRoot, provenance: .workspaceDefault(workspaceId: "workspace"), state: .provisional)
    let movedInput = AgentContextGravityInput(
        newAgentFrame: rect(50, 50),
        newAgentCheckoutRoot: homeA.checkoutRoot,
        managedAgents: [AgentScopeSignal(provenance: .managedAgent(agentId: "b"), frame: rect(51, 50), home: homeB)],
        workspaceId: "workspace")

    for event in [AgentScopeFreezeEvent.composerEdited, .referenceAdded, .manualLocationChosen, .turnSubmitted] {
        let frozen = provisional.applyingFreezeEvent(event)
        let afterMove = AgentContextGravityEngine.updateScopeAfterSettledMove(current: frozen, lifecycle: .zeroTurnUntouched, input: movedInput)
        expect(afterMove.home.projectId == homeA.projectId && afterMove.state == .pinned, "P4.R6 \(event.rawValue) freezes automatic reinference")
    }
}

private func checkEmptyCanvasNeverFallsBackToProcessCwd() {
    let processCwd = FileManager.default.currentDirectoryPath
    let explicitDefault = project(id: 12, root: "/tmp/continuum-p4/default", checkout: "/tmp/continuum-p4/default")
    let empty = AgentContextGravityInput(
        newAgentFrame: rect(0, 0),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new"),
        workspaceId: "workspace")
    expect(AgentContextGravityEngine.proposeScope(empty) == nil, "P4.R7 empty canvas without explicit workspace default returns nil instead of process cwd")

    let withDefault = AgentContextGravityInput(
        newAgentFrame: rect(0, 0),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/new"),
        workspaceDefault: explicitDefault,
        workspaceId: "workspace")
    let binding = requireProposal(withDefault)
    expect(binding.home.checkoutRoot.path == explicitDefault.checkoutRoot.path, "P4.R7 explicit workspace default is the only empty-canvas fallback")
    expect(binding.home.checkoutRoot.path != processCwd, "P4.R7 process cwd is not selected")
}

private func checkIsolatedCheckoutInheritanceUsesNewAgentPath() {
    let neighborHome = project(id: 13, root: "/tmp/continuum-p4/project", checkout: "/tmp/continuum-p4/worktrees/agent-a")
    let input = AgentContextGravityInput(
        newAgentFrame: rect(0, 0),
        newAgentCheckoutRoot: url("/tmp/continuum-p4/worktrees/agent-b"),
        managedAgents: [
            AgentScopeSignal(provenance: .managedAgent(agentId: "agent-a"), frame: rect(1, 0), home: neighborHome, relativeDirectory: "Sources"),
            AgentScopeSignal(provenance: .managedAgent(agentId: "agent-a-reviewer"), frame: rect(2, 0), home: neighborHome, relativeDirectory: "Sources"),
        ],
        workspaceId: "workspace")
    let binding = requireProposal(input, existing: ["/tmp/continuum-p4/worktrees/agent-b/Sources"])
    expect(binding.home.checkoutRoot.path == "/tmp/continuum-p4/worktrees/agent-b", "P4.R8 Home uses the new agent's own checkout")
    expect(binding.whereDirectory.path == "/tmp/continuum-p4/worktrees/agent-b/Sources", "P4.R8 relative directory maps into the new checkout")
    expect(binding.whereDirectory.path != "/tmp/continuum-p4/worktrees/agent-a/Sources", "P4.R8 raw neighbor worktree is never inherited")

    let missing = requireProposal(input, existing: [])
    expect(missing.whereDirectory.path == "/tmp/continuum-p4/worktrees/agent-b", "P4.R8 missing relative directory falls back to checkout root")
    expect(missing.warning == .inheritedRelativeDirectoryMissing("Sources"), "P4.R8 missing relative directory is explicit")
}

private func requireProposal(_ input: AgentContextGravityInput, existing: Set<String>? = nil) -> AgentScopeBinding {
    let result = AgentContextGravityEngine.proposeScope(input) { candidate in
        existing?.contains(candidate.path) ?? true
    }
    guard let result else {
        fputs("FAIL: expected a scope proposal\n", stderr)
        Foundation.exit(1)
    }
    return result
}

private func project(id: UInt8, root: String, checkout: String) -> AgentHome {
    AgentHome(
        projectId: UUID(uuidString: String(format: "A9100000-0000-4000-8000-%012d", Int(id)))!,
        projectRoot: url(root),
        checkoutRoot: url(checkout))
}

private func url(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}

private func rect(_ x: Double, _ y: Double) -> AgentWorldRect {
    AgentWorldRect(x: x, y: y, width: 10, height: 10)
}
