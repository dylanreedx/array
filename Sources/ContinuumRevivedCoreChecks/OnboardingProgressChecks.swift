import ContinuumRevivedCore
import Foundation

func runOnboardingProgressChecks() throws {
    var progress = OnboardingProgress(
        starter: StarterLayoutProgress(phase: .complete),
        milestones: [.commandCenterOpened]
    )
    expect(progress.isTaskComplete(.openCommandCenter), "real Command Center use completes its task")
    expect(!progress.isTaskComplete(.navigate), "partial navigation evidence cannot complete the task")
    progress.demonstrate(.quickJumpUsed)
    progress.demonstrate(.navigationModeEntered)
    expect(!progress.isTaskComplete(.navigate), "navigation activation remains required")
    progress.demonstrate(.navigationModeActivated)
    expect(progress.isTaskComplete(.navigate), "all three real navigation actions complete the task")

    progress.skipTask(.personalizeZone)
    expect(progress.isTaskResolved(.personalizeZone), "a task can be independently skipped")
    expect(progress.hasPendingGettingStartedTasks, "legacy completed tasks cannot invent the new launch milestones")
    let firstStarted = UUID()
    progress.demonstrateAgentStarted(firstStarted)
    progress.demonstrateAgentStarted(firstStarted)
    expect(!progress.isTaskComplete(.secondAgent), "repeated turns from one agent cannot complete second agent task")
    progress.demonstrateAgentStarted(UUID())
    expect(progress.isTaskComplete(.secondAgent), "two distinct agents really starting completes second agent task")
    progress.demonstrate(.terminalAdded)
    progress.demonstrate(.toolbarDragged)
    expect(!progress.hasPendingGettingStartedTasks, "new real creation, command and drag evidence resolves launch checklist")
    expect(GettingStartedTask.launchTasks == [.secondAgent, .addTerminal, .openCommandCenter, .dragToolbar], "launch checklist contains the requested four tasks")

    let firstProject = UUID()
    let zone = UUID()
    let agent = UUID()
    progress.firstProjectId = firstProject
    progress.starter = StarterLayoutProgress(
        phase: .complete,
        projectId: firstProject,
        zoneId: zone,
        agentTileId: agent
    )
    progress.replayEducation()
    expect(progress.startedAgentIDs.isEmpty && progress.milestones.isEmpty && progress.skippedTasks.isEmpty, "replay clears education state")
    expect(progress.educationReplayRequested, "replay explicitly reopens the live checklist")
    expect(progress.firstProjectId == firstProject, "replay preserves first-project identity")
    expect(progress.starter.zoneId == zone && progress.starter.agentTileId == agent,
           "replay never changes starter workspace content")

    // A schema-v1 payload has no task skip/replay fields. It must migrate rather
    // than being discarded as if onboarding had never existed.
    let legacyPayload: [String: Any] = [
        "schemaVersion": 1,
        "introVersion": 1,
        "explicitlyDismissedIntro": true,
        "explicitlySkippedStarter": false,
        "firstProjectId": firstProject.uuidString,
        "starter": [
            "phase": "complete",
            "projectId": firstProject.uuidString,
            "zoneId": zone.uuidString,
        ],
        "milestones": ["commandCenterOpened"],
    ]
    let migrated = try JSONDecoder().decode(
        OnboardingProgress.self,
        from: JSONSerialization.data(withJSONObject: legacyPayload, options: [.sortedKeys])
    )
    expect(migrated.schemaVersion == OnboardingProgress.currentSchemaVersion, "legacy progress upgrades its schema version")
    expect(migrated.skippedTasks.isEmpty && !migrated.educationReplayRequested,
           "new education fields get safe migration defaults")
    expect(migrated.startedAgentIDs.isEmpty, "legacy progress cannot invent agents that ran")
    expect(migrated.milestones == [.commandCenterOpened], "legacy demonstrated behavior survives migration")

    let suite = "array.onboardingProgressChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = OnboardingProgressStore(defaults: defaults)
    defaults.set(true, forKey: OnboardingProgressStore.legacyShownKey)
    let legacyDismissal = store.load()
    expect(legacyDismissal.explicitlyDismissedIntro, "the old shown bit migrates only as an intro dismissal")
    expect(legacyDismissal.milestones.isEmpty, "the old shown bit cannot invent demonstrated behavior")
    expect(legacyDismissal.starter.phase == .notStarted, "the old shown bit cannot invent starter content")

    defaults.removeObject(forKey: OnboardingProgressStore.legacyShownKey)
    store.save(progress)
    expect(store.load() == progress, "versioned onboarding progress round-trips")

    print("OnboardingProgress checks passed")
}
