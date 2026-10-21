import Foundation

/// An explicit API decision for every persisted agent/tile/zone field. The
/// census comes from the models' actual Codable keys, including tile metadata;
/// adding a key forces a decision even for runtime state and legacy wire keys.
public enum WorkspaceAPIExposure {
    public enum Decision: Equatable, Sendable {
        case `internal`
        case notExposed(String)
        case exposed(WorkspaceAPIOp)
    }

    public static var fields: Set<String> {
        Set(AgentRecord.CodingKeys.allCases.map { "agent.\($0.rawValue)" }
            + Tile.CodingKeys.allCases.map { "tile.\($0.rawValue)" }
            + TileMetadata.CodingKeys.allCases.map { "tile.metadata.\($0.rawValue)" }
            + ZonePlacement.CodingKeys.allCases.map { "zone.\($0.rawValue)" })
    }

    // No fallback classification: a new field must be considered deliberately.
    public static let decisions: [String: Decision] = [
        "agent.schemaVersion": .internal,
        "agent.id": .internal,
        "agent.displayName": .notExposed("Renaming existing agents is native UI only."),
        "agent.displayNameSource": .internal,
        "agent.namingRequest": .internal,
        "agent.role": .notExposed("Changing an existing agent's role is not an API update."),
        "agent.harness": .notExposed("Changing an existing harness requires the native settings flow."),
        "agent.model": .notExposed("Existing-agent provider settings are native UI only."),
        "agent.thinking": .notExposed("Existing-agent provider settings are native UI only."),
        "agent.cwd": .notExposed("Changing an existing agent's home is native UI only."),
        "agent.projectRoot": .internal,
        "agent.checkoutRoot": .internal,
        "agent.homeRelativePath": .notExposed("Changing an existing agent's home is native UI only."),
        "agent.lastObservedWhere": .internal,
        "agent.worktreeId": .internal,
        "agent.worktreeBranch": .internal,
        "agent.projectId": .internal,
        "agent.parentAgentID": .internal,
        "agent.capabilities": .internal,
        "agent.sourceItemId": .internal,
        "agent.spawnResultHandle": .internal,
        "agent.workspaceToolsEnabled": .notExposed("Only the user may grant workspace-tool access."),
        "agent.identityColor": .exposed(.agentUpdate),
        "agent.parentRelativeOrdinal": .internal,
        "agent.nextChildOrdinal": .internal,
        "agent.createdAtReferenceInterval": .internal,
        "agent.lastActivityAtReferenceInterval": .internal,
        "agent.latestPromptAtReferenceInterval": .internal,
        "agent.latestTurnAtReferenceInterval": .internal,
        "agent.failedAtReferenceInterval": .internal,
        "agent.runCompletedAtReferenceInterval": .internal,
        "agent.latestTerminalEvent": .internal,
        "agent.acknowledgedTerminalSequence": .internal,
        "agent.lastVisitedAtReferenceInterval": .internal,
        "agent.tileId": .internal,
        "agent.lastContextWindow": .internal,
        "agent.contextEpoch": .internal,
        "agent.inFlightCompaction": .internal,
        "agent.codexThreadId": .internal,
        "agent.providerSessionId": .internal,
        "agent.resolvedModelId": .internal,
        "agent.providerContextWindows": .internal,
        "agent.pendingSessionForkFrom": .internal,
        "agent.settledOverride": .notExposed("Settling agents is a user-owned lifecycle action."),
        "agent.settledAtReferenceInterval": .internal,
        "agent.snoozedUntilReferenceInterval": .notExposed("Snoozing agents is native UI only."),
        "agent.archivedAtReferenceInterval": .notExposed("Archiving agents is native UI only."),
        "agent.snoozedAtReferenceInterval": .internal,
        "agent.closeRequestedAtReferenceInterval": .internal,

        "tile.id": .internal,
        "tile.kind": .internal,
        "tile.title": .notExposed("Renaming existing tiles is native UI only."),
        "tile.frame": .exposed(.canvasApply),
        "tile.zPosition": .notExposed("Direct stacking edits are native UI only."),
        "tile.zIndex": .internal, // Legacy decode-only rank.
        "tile.zoneId": .exposed(.canvasApply), // Membership may follow a move.
        "tile.runtimeRef": .internal,
        "tile.metadata": .internal, // Its fields are audited individually below.
        "tile.metadata.launchProfileId": .notExposed("Retargeting an existing terminal is native UI only."),
        "tile.metadata.projectRelativeCwd": .notExposed("Retargeting an existing terminal is native UI only."),
        "tile.metadata.url": .notExposed("Editing an existing browser's URL is native UI only."),
        "tile.metadata.noteId": .internal,
        "tile.metadata.filePath": .internal,
        "tile.metadata.documentLocation": .internal,
        "tile.metadata.browserProfileId": .notExposed("Browser-profile selection is native UI only."),
        "tile.metadata.linearTeamKey": .notExposed("Ticket-queue configuration is native UI only."),
        "tile.metadata.linearTeamId": .internal,
        "tile.metadata.linearQuery": .notExposed("Ticket-queue configuration is native UI only."),
        "tile.metadata.reviewId": .internal,
        "tile.metadata.diffSource": .notExposed("Diff configuration is native UI only."),
        "tile.metadata.baseBranch": .notExposed("Diff configuration is native UI only."),
        "tile.metadata.branch": .notExposed("Diff configuration is native UI only."),
        "tile.metadata.filesystemProjectId": .internal,
        "tile.metadata.filesystemCheckoutRootPath": .internal,
        "tile.metadata.filesystemHomeRelativePath": .notExposed("Changing an existing tile's home is native UI only."),
        "tile.metadata.filesystemWherePath": .internal,
        "tile.metadata.worktreeId": .internal,
        "tile.metadata.agentSoundOverrides": .notExposed("Per-agent sound preferences are native UI only."),
        "tile.metadata.agentTerminalFace": .notExposed("Switching an agent tile's face is native UI only."),
        "tile.metadata.markdownDocumentMode": .notExposed("Editor-mode selection is native UI only."),
        "tile.metadata.fileEditorViewState": .notExposed("Editor presentation and cursor state stay user-owned."),
        "tile.metadata.boardId": .internal,

        "zone.zoneId": .internal,
        "zone.projectId": .notExposed("Changing a zone's project is native UI only."),
        "zone.homeRelativePath": .notExposed("Changing a zone's home is native UI only."),
        "zone.origin": .notExposed("The API moves tiles, not zones."),
        "zone.size": .notExposed("The API resizes tiles, not zones."),
        "zone.color": .notExposed("Zone colour is deferred beyond the agent-colour release."),
        "zone.collapsed": .notExposed("Zone collapse is native UI only."),
        "zone.hydrationPolicy": .notExposed("Zone residency preferences are native UI only."),
        "zone.autoLayoutMode": .notExposed("Zone layout preferences are native UI only."),
        "zone.name": .notExposed("Zone renaming is native UI only."),
        "zone.navKey": .notExposed("Navigation-key assignment is native UI only."),
        "zone.zPosition": .notExposed("Zone stacking is native UI only."),
    ]

    public static func violations(
        fields: Set<String> = Self.fields,
        decisions: [String: Decision] = Self.decisions,
        exposedOperations: Set<WorkspaceAPIOp> = WorkspaceMCPToolCatalog.exposedOperations
    ) -> [String] {
        var failures = fields.subtracting(decisions.keys).sorted().map { "Unclassified field: \($0)" }
        failures += Set(decisions.keys).subtracting(fields).sorted().map { "Stale API decision: \($0)" }
        for (field, decision) in decisions.sorted(by: { $0.key < $1.key }) {
            switch decision {
            case .internal: break
            case let .notExposed(reason):
                if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("Missing notExposed reason: \(field)")
                }
            case let .exposed(operation):
                if !exposedOperations.contains(operation) {
                    failures.append("No published tool for \(field): \(operation.rawValue)")
                }
            }
        }
        return failures
    }
}
