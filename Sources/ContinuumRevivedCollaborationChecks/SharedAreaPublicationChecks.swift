import Foundation
import ContinuumRevivedCore

private struct PublicationCheckFailure: Error { let message: String }
private func publicationExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw PublicationCheckFailure(message: message) }
    print("PASS publication: \(message)")
}
private func publicationRefuses(_ expected: SharedAreaPublication.Failure, _ action: () throws -> Void) throws {
    do { try action(); throw PublicationCheckFailure(message: "expected \(expected)") }
    catch let error as SharedAreaPublication.Failure {
        try publicationExpect(error == expected, "refuses \(expected)")
    }
}

func runSharedAreaPublicationChecks() throws {
    typealias P = SharedAreaPublication
    let workspace = UUID(), firstProject = UUID(), secondProject = UUID(), zone = UUID()
    let area = SharedArea.ID<SharedArea.Area>(), author = SharedArea.ID<SharedArea.Person>(), host = SharedArea.ID<SharedArea.Host>()
    func tile(_ kind: TileKind, x: Double, title: String, project: UUID) -> Tile {
        Tile(id: UUID(), kind: kind, title: title, frame: .init(x: x, y: -150, width: 400, height: 320),
            zPosition: FracIndex(value: x == -400 ? 0.2 : 0.8), zoneId: zone,
            runtimeRef: .init(kind: .terminalSession, id: UUID()),
            metadata: .init(projectRelativeCwd: "private-cwd-sentinel", url: "https://private.example.test/?secret=cookie",
                noteId: UUID(), filePath: "/private/publication-host-secret/file.swift",
                filesystemProjectId: project, filesystemCheckoutRootPath: "/private/publication-host-secret"))
    }
    let agent = P.SourceTile(projectID: firstProject,
        tile: tile(.managedAgent, x: -400, title: "private-source-title", project: firstProject),
        agentID: AgentID(rawValue: UUID()), contentRevision: "captured-generation-one")
    let note = P.SourceTile(projectID: secondProject,
        tile: tile(.note, x: 100, title: "private-note-title", project: secondProject), contentRevision: "note-revision-one")
    let terminal = P.SourceTile(projectID: firstProject,
        tile: tile(.terminal, x: 700, title: "Private shell", project: firstProject))
    let all = [agent, note, terminal]
    let full = P.Inventory(workspaceID: workspace, coverage: .completeWorkspace, sources: all)
    let choices: [P.Choice] = [
        .init(source: agent.key, content: .agentObservation),
        .init(source: note.key, content: .agreement(text: "Keep changes within the selected module."))
    ]
    let originalEncoder = JSONEncoder(); originalEncoder.outputFormatting = [.sortedKeys]
    let originals = try originalEncoder.encode(all.map(\.tile))
    let review = try P.prepare(inventory: full, selection: .workspace, choices: choices,
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(review.rows.count == 3 && review.rows.contains { $0.source == terminal.key && $0.disposition == .unsupported(.tileKind) },
        "complete model inventory includes unsupported terminal as an explicit row")
    try publicationExpect(review.rows.contains { $0.source == agent.key && !$0.includesAgentHistory && $0.previewText == nil },
        "agent review truthfully includes an opaque source and no transcript history")
    try publicationExpect(review.rows.contains { $0.source == note.key && $0.previewText == "Keep changes within the selected module." },
        "agreement review shows the exact explicitly captured text")
    let confirmed = try P.confirm(review, expectedDigest: review.digest, inventory: full, choices: choices)
    var document = SharedArea.Document(id: area)
    try document.apply(confirmed.command)
    try publicationExpect(document.items.count == 2 && document.contexts.map(\.text) == ["Keep changes within the selected module."],
        "confirmed command atomically admits selected source and initial agreement content")
    try publicationExpect(document.positions.map(\.rect.x) == [0, 500] && document.positions.allSatisfy { $0.rect.y == 0 },
        "negative WORLD origin normalizes once while preserving cross-project layout")
    // A distant unshared member still appears in local review, but its private
    // geometry must not become recoverable through published relative offsets.
    var farTerminalTile = terminal.tile
    farTerminalTile.frame.x = -950_000; farTerminalTile.frame.y = -820_000
    let farTerminal = P.SourceTile(projectID: terminal.projectID, tile: farTerminalTile)
    let farInventory = P.Inventory(workspaceID: workspace, coverage: .completeWorkspace, sources: [agent, note, farTerminal])
    func admittedRects(_ manifest: P.Manifest) -> [SharedArea.Rect] {
        manifest.edits.compactMap { edit in
            if case .admit(_, let position) = edit { return position.rect }
            return nil
        }
    }
    let unsupportedFar = try P.prepare(inventory: farInventory, selection: .workspace, choices: choices,
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(admittedRects(unsupportedFar.manifest) == admittedRects(review.manifest),
        "faraway unsupported terminal cannot alter published object offsets")
    let omittedFarChoices = choices + [.init(source: terminal.key, content: .omit)]
    let omittedFar = try P.prepare(inventory: farInventory, selection: .workspace, choices: omittedFarChoices,
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(admittedRects(omittedFar.manifest) == admittedRects(review.manifest),
        "faraway explicitly omitted member cannot influence shared capture origin")
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: farInventory, choices: choices)
    }
    try publicationExpect(confirmed.sourceBindings.count == 1 && confirmed.sourceBindings[0].agentID == agent.agentID
        && confirmed.sourceBindings[0].projectID == firstProject && confirmed.sourceBindings[0].tileID == agent.tile.id,
        "only actual managed agent has a separate private local source binding")
    try publicationExpect(try originalEncoder.encode(all.map(\.tile)) == originals, "review and confirmation preserve source models byte for byte")
    let commandText = String(decoding: try originalEncoder.encode(confirmed.command), as: UTF8.self)
    let manifestText = String(decoding: try originalEncoder.encode(review.manifest), as: UTF8.self)
    let sentinels = ["publication-host-secret", "private-source-title", "private-note-title", "private-cwd-sentinel", "private.example.test",
        workspace.uuidString, firstProject.uuidString, secondProject.uuidString, zone.uuidString,
        agent.tile.id.uuidString, note.tile.id.uuidString, agent.agentID!.rawValue.uuidString, agent.tile.runtimeRef!.id.uuidString]
    for sentinel in sentinels {
        try publicationExpect(!commandText.contains(sentinel) && !manifestText.contains(sentinel), "private source sentinel absent from exact portable bytes")
    }
    let retry = try P.confirm(review, expectedDigest: review.digest, inventory: full, choices: choices)
    try publicationExpect(retry.command == confirmed.command && retry.sourceBindings == confirmed.sourceBindings,
        "same confirmed review preserves operation identity and generated source bindings")
    let reordered = P.Inventory(workspaceID: workspace, coverage: .completeWorkspace, sources: Array(all.reversed()))
    try publicationExpect(try P.confirm(review, expectedDigest: review.digest, inventory: reordered, choices: Array(choices.reversed())).command == confirmed.command,
        "enumeration ordering alone does not change selected publication intent")

    let partial = P.Inventory(workspaceID: workspace, coverage: .partial, sources: [agent])
    let incompleteSelections: [P.Selection] = [.workspace, .zone(zone), .enclosed(.init(x: -500, y: -200, width: 1800, height: 600))]
    for selection in incompleteSelections {
        try publicationRefuses(.incompleteCoverage) {
            _ = try P.prepare(inventory: partial, selection: selection, choices: [.init(source: agent.key, content: .agentObservation)],
                area: area, author: author, host: host, expectedRevision: 0)
        }
    }
    let explicit = try P.prepare(inventory: partial, selection: .tiles([agent.key]), choices: [.init(source: agent.key, content: .agentObservation)],
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(explicit.rows.count == 1 && explicit.readyToConfirm, "explicit model tile selection works without claiming workspace coverage")
    let missing = P.SourceKey(projectID: secondProject, tileID: UUID())
    try publicationRefuses(.missingSource) {
        _ = try P.prepare(inventory: partial, selection: .tiles([agent.key, missing]), choices: [], area: area, author: author, host: host, expectedRevision: 0)
    }
    let capturedZone = try P.prepare(inventory: .init(workspaceID: workspace, coverage: .zones([zone]), sources: all), selection: .zone(zone),
        choices: choices, area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(capturedZone.rows.count == 3, "zone review uses complete supplied zone models including non-live members")
    let enclosed = try P.prepare(inventory: full, selection: .enclosed(.init(x: -450, y: -175, width: 900, height: 400)),
        choices: [.init(source: agent.key, content: .agentObservation)], area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(enclosed.rows.map(\.source) == [agent.key], "capture rectangle excludes a partially overlapping note")

    let noChoice = try P.prepare(inventory: partial, selection: .tiles([agent.key]), choices: [], area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(noChoice.rows[0].disposition == .needsReview && !noChoice.readyToConfirm,
        "a selected managed agent is never implicitly approved")
    try publicationRefuses(.nothingToPublish) { _ = try P.confirm(noChoice, expectedDigest: noChoice.digest, inventory: partial, choices: []) }
    let incomplete = try P.prepare(inventory: full, selection: .workspace, choices: [choices[0]], area: area, author: author, host: host, expectedRevision: 0)
    try publicationRefuses(.reviewIncomplete) {
        _ = try P.confirm(incomplete, expectedDigest: incomplete.digest, inventory: full, choices: [choices[0]])
    }
    let digestOne = String(repeating: "1", count: 64), digestTwo = String(repeating: "2", count: 64)
    let artifact = try P.prepare(inventory: full, selection: .tiles([note.key]), choices: [.init(source: note.key, content: .artifact(digest: digestOne))],
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(artifact.rows[0].disposition == .unsupported(.requiresDiffOrFile) && artifact.manifest.edits.isEmpty,
        "artifact intent on a note is visibly unsupported rather than publishing a misleading payload")
    // COL-16: a diff tile publishes an artifact item bound to this host, and
    // confirmation refuses when the re-captured bytes differ from the review.
    let diff = P.SourceTile(projectID: firstProject, tile: tile(.diffReview, x: 1200, title: "private-diff-title", project: firstProject))
    let diffInventory = P.Inventory(workspaceID: workspace, coverage: .partial, sources: [diff])
    let undecided = try P.prepare(inventory: diffInventory, selection: .tiles([diff.key]), choices: [], area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(undecided.rows[0].disposition == .needsReview, "a diff tile asks for an explicit choice instead of being dropped")
    let diffChoice: [P.Choice] = [.init(source: diff.key, content: .artifact(digest: digestOne))]
    let diffReview = try P.prepare(inventory: diffInventory, selection: .tiles([diff.key]), choices: diffChoice, area: area, author: author, host: host, expectedRevision: 0)
    let diffConfirmed = try P.confirm(diffReview, expectedDigest: diffReview.digest, inventory: diffInventory, choices: diffChoice)
    var diffDocument = SharedArea.Document(id: area)
    try diffDocument.apply(diffConfirmed.command)
    try publicationExpect(diffDocument.items.count == 1 && diffDocument.items[0].kind == .artifact && diffDocument.items[0].source?.host == host
        && diffConfirmed.artifacts.count == 1 && diffConfirmed.artifacts[0].object == diffDocument.items[0].id
        && diffConfirmed.artifacts[0].contentDigest == digestOne && diffConfirmed.sourceBindings.map(\.object) == [diffDocument.items[0].id],
        "a confirmed diff becomes a host-sourced artifact item with a reserved revision and a private binding")
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(diffReview, expectedDigest: diffReview.digest, inventory: diffInventory,
                          choices: [.init(source: diff.key, content: .artifact(digest: digestTwo))])
    }
    let malformed = try P.prepare(inventory: diffInventory, selection: .tiles([diff.key]), choices: [.init(source: diff.key, content: .artifact(digest: ""))],
        area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(malformed.rows[0].disposition == .unsupported(.unavailableArtifact), "a diff whose capture is missing cannot be confirmed")
    let unbound = P.SourceTile(projectID: firstProject, tile: agent.tile)
    let unboundReview = try P.prepare(inventory: .init(workspaceID: workspace, coverage: .partial, sources: [unbound]), selection: .tiles([unbound.key]),
        choices: [.init(source: unbound.key, content: .agentObservation)], area: area, author: author, host: host, expectedRevision: 0)
    try publicationExpect(unboundReview.rows[0].disposition == .unsupported(.unavailableAgent), "unresolved local agent cannot become an executable fallback")

    let absentRevisions: [String?] = [nil, "   "]
    for absentRevision in absentRevisions {
        let unversioned = P.SourceTile(projectID: secondProject, tile: note.tile, contentRevision: absentRevision)
        let unversionedInventory = P.Inventory(workspaceID: workspace, coverage: .partial, sources: [unversioned])
        let unversionedChoices: [P.Choice] = [.init(source: unversioned.key, content: .agreement(text: "Previously captured note text"))]
        let unversionedReview = try P.prepare(inventory: unversionedInventory, selection: .tiles([unversioned.key]), choices: unversionedChoices,
            area: area, author: author, host: host, expectedRevision: 0)
        try publicationExpect(unversionedReview.rows[0].disposition == .unsupported(.unavailableContentRevision)
            && unversionedReview.manifest.edits.isEmpty, "note text without an owner-captured content revision cannot be admitted")
        try publicationRefuses(.nothingToPublish) {
            _ = try P.confirm(unversionedReview, expectedDigest: unversionedReview.digest, inventory: unversionedInventory, choices: unversionedChoices)
        }
    }
    // A path-independent local key includes the project owner, even if corrupt
    // or copied canvases happen to repeat the same tile UUID.
    var twinTile = agent.tile; twinTile.metadata.filesystemProjectId = secondProject
    let twin = P.SourceTile(projectID: secondProject, tile: twinTile, agentID: AgentID(rawValue: UUID()), contentRevision: "twin-generation")
    let twinInventory = P.Inventory(workspaceID: workspace, coverage: .partial, sources: [agent, twin])
    let twinChoices: [P.Choice] = [.init(source: agent.key, content: .agentObservation), .init(source: twin.key, content: .agentObservation)]
    let twinReview = try P.prepare(inventory: twinInventory, selection: .tiles([agent.key, twin.key]), choices: twinChoices,
        area: area, author: author, host: host, expectedRevision: 0)
    let twinConfirmed = try P.confirm(twinReview, expectedDigest: twinReview.digest, inventory: twinInventory, choices: twinChoices)
    try publicationExpect(twinConfirmed.sourceBindings.count == 2
        && Set(twinConfirmed.sourceBindings.map(\.projectID)) == [firstProject, secondProject]
        && Set(twinConfirmed.sourceBindings.map(\.object)).count == 2
        && twinConfirmed.sourceBindings.first { $0.projectID == firstProject }?.agentID == agent.agentID
        && twinConfirmed.sourceBindings.first { $0.projectID == secondProject }?.agentID == twin.agentID,
        "same tile UUID in separate projects retains distinct publication choices, objects and local agent bindings")
    let singleOwner = try P.prepare(inventory: twinInventory, selection: .tiles([twin.key]), choices: [.init(source: twin.key, content: .agentObservation)],
        area: area, author: author, host: host, expectedRevision: 0)
    let singleConfirmed = try P.confirm(singleOwner, expectedDigest: singleOwner.digest, inventory: twinInventory,
        choices: [.init(source: twin.key, content: .agentObservation)])
    try publicationExpect(singleConfirmed.sourceBindings.count == 1 && singleConfirmed.sourceBindings[0].projectID == secondProject
        && singleConfirmed.sourceBindings[0].agentID == twin.agentID, "explicit source key cannot select another project's repeated tile UUID")

    try publicationRefuses(.reviewChanged) { _ = try P.confirm(review, expectedDigest: String(repeating: "0", count: 64), inventory: full, choices: choices) }
    var moved = agent.tile; moved.frame.x += 1
    let changedFrame = P.SourceTile(projectID: firstProject, tile: moved, agentID: agent.agentID, contentRevision: agent.contentRevision)
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: .init(workspaceID: workspace, coverage: .completeWorkspace, sources: [changedFrame, note, terminal]), choices: choices)
    }
    let changedGeneration = P.SourceTile(projectID: firstProject, tile: agent.tile, agentID: agent.agentID, contentRevision: "captured-generation-two")
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: .init(workspaceID: workspace, coverage: .completeWorkspace, sources: [changedGeneration, note, terminal]), choices: choices)
    }
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: full, choices: [choices[0], .init(source: note.key, content: .agreement(text: "New unreviewed content"))])
    }
    let newSource = P.SourceTile(projectID: secondProject, tile: tile(.browser, x: 1500, title: "New private browser", project: secondProject))
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: .init(workspaceID: workspace, coverage: .completeWorkspace, sources: all + [newSource]), choices: choices)
    }
    try publicationRefuses(.reviewChanged) {
        _ = try P.confirm(review, expectedDigest: review.digest, inventory: .init(workspaceID: UUID(), coverage: .completeWorkspace, sources: all), choices: choices)
    }
    try publicationRefuses(.duplicateChoice) {
        _ = try P.prepare(inventory: partial, selection: .tiles([agent.key]), choices: [choices[0], choices[0]], area: area, author: author, host: host, expectedRevision: 0)
    }
    try publicationRefuses(.invalidContent) {
        _ = try P.prepare(inventory: full, selection: .tiles([note.key]), choices: [.init(source: note.key, content: .agreement(text: "  \n"))],
            area: area, author: author, host: host, expectedRevision: 0)
    }
}
