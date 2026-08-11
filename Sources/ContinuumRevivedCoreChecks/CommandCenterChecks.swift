import ContinuumRevivedCore
import Foundation

func runCommandCenterChecks() {
    let tileID = UUID(uuidString: "00000000-0000-0000-0000-00000000cc01")!
    let zoneID = UUID(uuidString: "00000000-0000-0000-0000-00000000cc02")!
    let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-00000000cc03")!
    let projectID = UUID(uuidString: "00000000-0000-0000-0000-00000000cc04")!
    let workspace = WorkspaceEntry(id: workspaceID, name: "Shipping", projectIds: [projectID], createdAt: .distantPast, updatedAt: .distantPast)
    let project = ProjectPickerRow(id: projectID, name: "Array", rootPath: "/projects/array", lastOpenedAt: .distantPast, pinned: true, isLastActive: true, availability: .available)
    let rows = LaunchPaletteModel.makeRows(
        profiles: [LaunchPaletteProfileRow(id: "shell", displayName: "Shell", detail: "/bin/zsh", isSelectable: true)],
        projects: [project],
        workspaces: [workspace],
        jumpTiles: [JumpTileRow(id: tileID, title: "Fix command menu")],
        jumpZones: [JumpZoneRow(id: zoneID, title: "Polish")]
    )

    let home = LaunchPaletteModel.makeSections(rows: rows, query: "")
    expect(home.flatMap(\.items).count <= LaunchPaletteModel.defaultItemLimit, "command center caps its default home")
    expect(!home.contains(where: { $0.items.isEmpty }), "command center omits empty sections")
    expect(!home.contains(where: { $0.category == .developer }), "command center keeps developer commands off the default home")
    expect(home.first(where: { $0.category == .create })?.items.first?.title == "Terminal", "command center cleans Shell up to Terminal")

    let tile = LaunchPaletteModel.makeSections(rows: rows, query: "fix command").flatMap(\.items).first
    expect(tile?.row == .jumpToTile(JumpTileRow(id: tileID, title: "Fix command menu")), "typed command-center search preserves tile dispatch identity")
    expect(tile?.title == "Fix command menu" && tile?.subtitle == "Tile", "tile result uses entity-first copy instead of Jump to")

    let attentionTile = JumpTileRow(
        id: tileID,
        title: "Command Center polish",
        kind: .managedAgent,
        contextTitle: "Shipping · Array",
        modelID: "openai-codex/gpt-5.6-sol",
        modelDisplayName: "GPT-5.6 Sol",
        statusLabel: "Needs attention",
        attentionReason: .approval
    )
    let attentionRows = LaunchPaletteModel.makeRows(profiles: [], jumpTiles: [attentionTile])
    let attentionHome = LaunchPaletteModel.makeSections(rows: attentionRows, query: "")
    let needsYou = attentionHome.first(where: { $0.category == .needsYou })?.items.first
    expect(needsYou?.title == "Command Center polish", "Needs You keeps the session title as command identity")
    expect(needsYou?.subtitle == "Approval requested · GPT-5.6 Sol · Shipping · Array", "Needs You explains the request and carries model/context metadata")
    expect(LaunchPaletteModel.makeSections(rows: attentionRows, query: "gpt 5.6").flatMap(\.items).first?.row == .jumpToTile(attentionTile), "model metadata finds the session without becoming its title")
    expect(LaunchPaletteModel.makeSections(rows: attentionRows, query: "approval").first?.category == .needsYou, "attention reason is searchable and retains Needs You categorization")
    let crowdedNeedsYouRows = LaunchPaletteModel.makeRows(
        profiles: [],
        jumpTiles: (0..<13).map { index in
            JumpTileRow(id: UUID(), title: "Waiting agent \(index)", kind: .managedAgent, attentionReason: .input)
        }
    )
    expect(LaunchPaletteModel.makeSections(rows: crowdedNeedsYouRows, query: "").flatMap(\.items).count <= LaunchPaletteModel.defaultItemLimit, "Needs You still honors the curated home cap")

    let modelRow = AgentModelPaletteRow(
        id: "openai-codex/gpt-5.6-sol",
        displayName: "GPT-5.6 Sol",
        providerName: "OpenAI Codex · openai-codex/gpt-5.6-sol"
    )
    let modelSections = LaunchPaletteModel.makeSections(rows: [.agentModel(modelRow)], query: "")
    expect(modelSections.first?.category == .models, "agent creation presents its exact models in a dedicated child section")
    expect(modelSections.first?.items.first?.title == "GPT-5.6 Sol", "agent-model child rows keep the human model name primary")
    expect(LaunchPaletteModel.makeSections(rows: [.agentModel(modelRow)], query: "openai codex").first?.items.first?.row == .agentModel(modelRow), "agent-model child search includes provider and exact id metadata")
    expect(!LaunchPaletteModel.presentation(for: .agentModel(modelRow)).isSafeRecent, "an intermediate model choice is never persisted as a standalone recent")

    let exactAgent = LaunchPaletteModel.makeSections(rows: rows, query: "agent").flatMap(\.items).first
    expect(exactAgent?.title == "Agent", "exact typed matches outrank category defaults without a Best Match section")

    let activity = LaunchPaletteModel.makeSections(rows: rows, query: "activity dock").flatMap(\.items)
    expect(activity.first?.row == .action(.toggleWorkspaceSidebar), "clean aliases find legacy sidebar action")
    expect(activity.first?.category == .developer, "administrative chrome action is categorized as Developer")

    let recentTile = LaunchPaletteModel.recordingRecent(.jumpToTile(JumpTileRow(id: tileID, title: "Fix command menu")), in: [], succeeded: true)
    let deduped = LaunchPaletteModel.recordingRecent(.jumpToTile(JumpTileRow(id: tileID, title: "Fix command menu")), in: recentTile, succeeded: true)
    expect(deduped.count == 1, "command-center recents deduplicate stable destinations")
    expect(LaunchPaletteModel.recordingRecent(.action(.deleteWorkspace(workspaceID)), in: deduped, succeeded: true) == deduped, "destructive commands never enter recents")
    expect(LaunchPaletteModel.recordingRecent(.action(.newNote), in: deduped, succeeded: false) == deduped, "failed or cancelled actions never enter recents")
    expect(LaunchPaletteModel.sanitizeRecentIDs(["tile:\(tileID.uuidString)", "tile:stale"], rows: rows) == ["tile:\(tileID.uuidString)"], "stale recent destinations are cleaned")

    let frosted = CommandCenterAppearanceConfig.resolve(glassinessRaw: nil, customOpacityRaw: nil, reduceTransparency: false, increaseContrast: false)
    expect(frosted.glassiness == .frosted && frosted.backgroundOpacity == 0.84 && frosted.usesBlur, "command center defaults to 84% Frosted")
    let bounded = CommandCenterAppearanceConfig.resolve(glassinessRaw: "Custom", customOpacityRaw: "0.1", reduceTransparency: false, increaseContrast: false)
    expect(bounded.backgroundOpacity == CommandCenterAppearanceConfig.customOpacityRange.lowerBound, "custom command-center opacity is bounded")
    let accessible = CommandCenterAppearanceConfig.resolve(glassinessRaw: "Glass", customOpacityRaw: nil, reduceTransparency: true, increaseContrast: false)
    expect(accessible.glassiness == .solid && accessible.backgroundOpacity == 1 && !accessible.usesBlur && accessible.accessibilityForcedSolid, "Reduce Transparency forces a solid command center")
    let contrast = CommandCenterAppearanceConfig.resolve(glassinessRaw: "Glass", customOpacityRaw: nil, reduceTransparency: false, increaseContrast: true)
    expect(contrast.backgroundOpacity >= 0.92, "Increase Contrast strengthens the command-center scrim")

    let appearanceSection = SettingsSchema.sections().first(where: { $0.id == "appearance" })
    expect(appearanceSection?.fields.contains(where: { $0.key == CommandCenterAppearanceConfig.glassinessKey }) == true, "glassiness setting lives under Appearance")
    expect(appearanceSection?.fields.contains(where: { $0.key == CommandCenterAppearanceConfig.customOpacityKey }) == true, "custom command-menu opacity lives under Appearance")
    if let opacityField = appearanceSection?.fields.first(where: { $0.key == CommandCenterAppearanceConfig.customOpacityKey }) {
        let suite = "CommandCenterOpacity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(!opacityField.isVisible(in: defaults), "custom opacity stays hidden for the default Frosted preset")
        defaults.set(CommandCenterGlassiness.custom.rawValue, forKey: CommandCenterAppearanceConfig.glassinessKey)
        expect(opacityField.isVisible(in: defaults), "custom opacity appears only for the Custom preset")
        opacityField.setValue(.double(0.1), in: defaults)
        expect(opacityField.currentValue(in: defaults) == .double(CommandCenterAppearanceConfig.customOpacityRange.lowerBound), "custom opacity slider clamps before persistence")
    }

    // MARK: History · a closed agent must stay reachable
    //
    // The sidebar's History section is the only surface a closed agent has, and
    // it is being removed (.plans/10-command-center-absorbs-sidebar.md). A closed
    // agent has NO TILE, so `jumpToTile` cannot represent it — without a row of
    // its own, deleting the sidebar strands the record, its transcript and its
    // worktree permanently. These assertions are that row's teeth.
    let closedAgentID = UUID()
    let closedAgent = HistoryAgentPaletteRow(
        agentId: closedAgentID, displayName: "Rehydrate codex", detail: "GPT-5.6 Sol")
    let historyRows = LaunchPaletteModel.makeRows(profiles: [], historyAgents: [closedAgent])
    expect(historyRows.contains(.historyAgent(closedAgent)),
           "makeRows must offer a closed agent — nothing else can reach one")

    let historyPresented = LaunchPaletteModel.presentation(for: .historyAgent(closedAgent))
    expect(historyPresented.category == .history,
           "a closed agent draws in History, not among live tiles")
    expect(historyPresented.title == "Rehydrate codex",
           "History keeps the agent's own name as command identity")
    expect(historyPresented.subtitle == "Closed · GPT-5.6 Sol",
           "History says the agent is closed and carries its model as metadata")
    expect(historyPresented.stableID == "history-agent:\(closedAgentID.uuidString)",
           "History dispatch identity is the AGENT id — a closed agent has no tile id")

    // Searchable by the agent's name, by its model, and by the section's own
    // vocabulary, so it is findable without remembering what it was called.
    for query in ["rehydrate", "gpt 5.6", "history", "closed", "reopen"] {
        expect(LaunchPaletteModel.makeSections(rows: historyRows, query: query)
                .flatMap(\.items).contains(where: { $0.row == .historyAgent(closedAgent) }),
               "a closed agent must be findable by \"\(query)\"")
    }

    // Never volunteered: History is the block you go looking for, so it may not
    // displace a row you did not ask for, and reopening ends the agent's
    // membership in it — which would make a "recent" point at a stale section.
    expect(!historyPresented.isDefaultVisible,
           "History must not appear on the empty-query home")
    expect(!historyPresented.isSafeRecent,
           "reopening leaves History, so a closed agent is never a safe recent")
    expect(!LaunchPaletteModel.makeSections(rows: historyRows, query: "")
            .contains(where: { $0.category == .history }),
           "the curated home shows no History section until it is searched for")
}
