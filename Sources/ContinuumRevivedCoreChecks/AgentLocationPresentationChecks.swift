import ContinuumRevivedCore
import Foundation

func runAgentLocationPresentationChecks() {
    let projectID = UUID(uuidString: "91000000-0000-4000-8000-000000000301")!
    let checkout = URL(fileURLWithPath: "/Users/example/continuum", isDirectory: true)
    let home = AgentHome(
        projectId: projectID,
        projectRoot: checkout,
        checkoutRoot: checkout)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let root = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: checkout),
        projectName: "Continuum")
    expect(root.locationText == "Home Continuum",
           "Agent location presentation: equivalent Home/Where must render once")
    expect(root.homeWhereCollapsed && !root.whereIsExternal,
           "Agent location presentation: root fixture did not collapse Home/Where")
    expect(root.locationAccessibilityValue == "Home and Where: Continuum, project root.",
           "Agent location presentation: collapsed accessibility value drifted")

    let insideDirectory = checkout.appendingPathComponent("Sources/ContinuumRevived", isDirectory: true)
    let inside = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: insideDirectory),
        projectName: "Continuum")
    expect(inside.locationText == "Home Continuum · Where Sources/ContinuumRevived",
           "Agent location presentation: inside Where must remain checkout-relative")
    expect(!inside.homeWhereCollapsed && !inside.whereIsExternal,
           "Agent location presentation: inside Where was collapsed or marked external")
    expect(inside.locationAccessibilityValue
            == "Home: Continuum. Where: Sources/ContinuumRevived, inside Home.",
           "Agent location presentation: inside accessibility value drifted")

    let outsideDirectory = URL(fileURLWithPath: "/tmp/reference-project", isDirectory: true)
    let outside = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: outsideDirectory),
        projectName: "Continuum")
    expect(outside.locationText == "Home Continuum · Where reference-project",
           "Agent location presentation: external Where needs a compact label")
    expect(outside.whereIsExternal && !outside.homeWhereCollapsed,
           "Agent location presentation: external Where relation was lost")
    expect(outside.locationAccessibilityValue
            == "Home: Continuum. Where: reference-project, outside Home.",
           "Agent location presentation: VoiceOver must name external Where independently")

    let insideRead = AgentObservedActivity(
        operation: .reading,
        targetPath: checkout.appendingPathComponent("Sources/Agent.swift"),
        startedAt: now,
        updatedAt: now,
        evidenceSource: .toolEvent)
    let currentInside = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: insideDirectory, what: insideRead),
        projectName: "Continuum")
    expect(currentInside.whatText == "What Reading Sources/Agent.swift",
           "Agent location presentation: current inside What is not compact and relative")
    expect(!currentInside.whatIsExternal
            && currentInside.whatAccessibilityValue
                == "What: reading Sources/Agent.swift, inside Home.",
           "Agent location presentation: current inside What accessibility drifted")

    let externalRead = AgentObservedActivity(
        operation: .reading,
        targetPath: outsideDirectory.appendingPathComponent("src/router.ts"),
        startedAt: now,
        updatedAt: now,
        evidenceSource: .toolEvent)
    let currentExternal = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(
            home: home,
            whereDirectory: outsideDirectory,
            what: externalRead,
            lastUsefulWhat: externalRead),
        projectName: "Continuum")
    expect(currentExternal.whatText == "What Reading reference-project/src/router.ts",
           "Agent location presentation: external What needs a useful compact path")
    expect(currentExternal.whatIsExternal,
           "Agent location presentation: external What relation was lost")
    expect(currentExternal.whatAccessibilityValue
            == "What: reading reference-project/src/router.ts, outside Home.",
           "Agent location presentation: VoiceOver must name external What independently")

    let recent = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(
            home: home,
            whereDirectory: checkout,
            lastUsefulWhat: insideRead),
        projectName: "Continuum")
    expect(recent.whatText == "Last Read Sources/Agent.swift",
           "Agent location presentation: stale current What must expose last useful as recent")
    expect(recent.whatAccessibilityValue
            == "Last observed activity: read Sources/Agent.swift, inside Home.",
           "Agent location presentation: recent activity must not be announced as current")

    let targetlessWaiting = AgentObservedActivity(
        operation: .waiting,
        targetPath: nil,
        startedAt: now,
        updatedAt: now,
        evidenceSource: .lifecycleEvent)
    let missingTarget = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: checkout, what: targetlessWaiting),
        projectName: "Continuum")
    expect(missingTarget.whatText == "What Waiting"
            && missingTarget.whatAccessibilityValue == "What: waiting.",
           "Agent location presentation: targetless current activity must remain distinct and truthful")

    let empty = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: checkout),
        projectName: "Continuum")
    expect(empty.whatText == "What No observed activity"
            && empty.whatAccessibilityValue == "What: no observed activity.",
           "Agent location presentation: empty activity must remain truthful")

    let hostileName = String(repeating: "Long project ", count: 80) + "\nspoofed"
    let bounded = AgentLocationStatusPresenter.present(
        AgentLocationSnapshot(home: home, whereDirectory: checkout),
        projectName: hostileName)
    expect(bounded.locationText.count <= 240
            && !bounded.locationText.contains("\n")
            && !bounded.locationAccessibilityValue.contains("\n"),
           "Agent location presentation: compact/AX text must be bounded and single-line")

    expect(currentExternal.detailText.contains("Home: Continuum")
            && currentExternal.detailText.contains(checkout.path)
            && currentExternal.detailText.contains(outsideDirectory.path)
            && currentExternal.detailText.contains(externalRead.targetPath!.path)
            && currentExternal.detailText.contains("tool event"),
           "Agent location presentation: host-local disclosure omitted full path/provenance details")
    expect(!((currentExternal as Any) is any Encodable),
           "Agent location presentation: host-local path presentation must not become Encodable")

    print("Agent location presentation checks passed: collapsed/inside/external Where, current/external/recent/empty What, independent AX values, bounded compact labels, and host-local disclosure")
}
