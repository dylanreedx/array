import ContinuumRevivedCore
import Foundation

func runLocationSwitcherFoundationChecks() throws {
    try runLocationSwitcherAdapterPrivacyChecks()
    try runLocationSwitcherModeFilteringChecks()
    try runLocationSwitcherStableSelectionIDChecks()
    try runLocationSwitcherResultSelectionChecks()
    try runLocationSwitcherStalePreviewChecks()
    print("LocationSwitcher foundation checks passed: privacy, modes, stable IDs, selection, stale preview")
}

private func runLocationSwitcherAdapterPrivacyChecks() throws {
    let index = LocationSwitcherIndexAdapter.makeIndex(from: .init(
        projects: [.init(id: "project:secret", label: "/Users/dylan/private/continuum", aliases: ["/Users/dylan/private/continuum", "safe-alias"], rootPath: "/Users/dylan/private/continuum", displayPath: "/Users/dylan/private/continuum", isWorkspaceProject: true)],
        agents: [.init(id: "agent:one", label: "Agent One", providerSessionID: "provider-secret-123", transcriptPath: "/Users/dylan/.claude/transcript.jsonl", routingHandle: "tmux:%hidden", projectID: "project:secret", projectLabel: "/Users/dylan/private/continuum")],
        sessions: [.init(id: "session:one", label: "Review", aliases: ["provider-secret-123"], providerSessionID: "provider-secret-456", transcriptPath: "/tmp/provider/transcript.jsonl")]
    ))

    let entriesJSON = String(decoding: try JSONEncoder().encode(index.entriesForCodableOutput()), as: UTF8.self)
    expect(!entriesJSON.contains("/Users/dylan"), "host-local adapter must not leak /Users absolute paths through Codable entries")
    expect(!entriesJSON.contains(".claude"), "host-local adapter must not leak transcript path fragments through Codable entries")
    expect(!entriesJSON.contains("transcript.jsonl"), "host-local adapter must not leak transcript filenames through Codable entries")
    expect(!entriesJSON.contains("tmux:%hidden"), "host-local adapter must not leak routing handles through Codable entries")
    expect(!entriesJSON.contains("provider-secret-123"), "host-local adapter must filter provider session IDs even when supplied as aliases")
    expect(!entriesJSON.contains("provider-secret-456"), "host-local adapter must not leak provider session IDs through Codable entries")
    expect(entriesJSON.contains("safe-alias"), "host-local adapter should preserve non-secret aliases")

    let agentRouting = index.records.first { $0.entry.id == "agent:one" }?.privateRouting
    expect(agentRouting?.providerSessionID == "provider-secret-123", "provider session ID should remain available only in private routing")
    expect(agentRouting?.transcriptPath == "/Users/dylan/.claude/transcript.jsonl", "transcript path should remain available only in private routing")
    expect(agentRouting?.absolutePath == "tmux:%hidden", "routing handle should remain available only in private routing")
}

private func runLocationSwitcherModeFilteringChecks() throws {
    let index = LocationSwitcherIndexAdapter.makeIndex(from: .init(
        projects: [.init(id: "project:app", label: "App")],
        agents: [.init(id: "agent:worker", label: "Worker")],
        sessions: [.init(id: "session:review", label: "Review")],
        tiles: [.init(id: "tile:term", label: "Terminal")],
        zones: [.init(id: "zone:left", label: "Left Zone")]
    ))

    var model = LocationSwitcherModel(index: index, mode: .location)
    expect(Set(model.results.map(\.entry.id.rawValue)) == ["project:app", "agent:worker", "tile:term", "zone:left"], "location mode should exclude reference-only sessions and delegate filtering to the index")
    model.setMode(.reference)
    expect(Set(model.results.map(\.entry.id.rawValue)) == ["project:app", "session:review"], "reference mode should include reference-safe projects/sessions only")
    model.setMode(.global)
    expect(Set(model.results.map(\.entry.id.rawValue)) == ["project:app", "agent:worker", "session:review", "tile:term", "zone:left"], "global mode should include all adapter-supported records")
}

private func runLocationSwitcherStableSelectionIDChecks() throws {
    let index = LocationSessionIndex(records: [
        LocationIndexRecord(entry: .init(id: "project:b", kind: .project, label: "Beta")),
        LocationIndexRecord(entry: .init(id: "project:a", kind: .project, label: "Alpha"))
    ])
    var model = LocationSwitcherModel(index: index, mode: .global)
    model.select(selectionID: LocationSwitcherModel.selectionID(for: "project:b", mode: .global))
    expect(model.selectedResult?.entry.id == "project:b", "explicit selection should choose the matching stable selection ID")
    model.setQuery("be")
    expect(model.selectedResultID == "global:project:b", "selection ID should be stable across query/reranking when the result remains present")
    model.setMode(.location)
    expect(model.results.map(\.selectionID).allSatisfy { $0.hasPrefix("location:") }, "selection IDs should be mode-scoped and deterministic")
}

private func runLocationSwitcherResultSelectionChecks() throws {
    var model = LocationSwitcherModel(index: LocationSessionIndex(records: [
        LocationIndexRecord(entry: .init(id: "project:a", kind: .project, label: "Alpha")),
        LocationIndexRecord(entry: .init(id: "project:b", kind: .project, label: "Beta"))
    ]), mode: .global)
    expect(model.selectedResult?.entry.id == "project:a", "model should select first ranked result by default")
    model.select(selectionID: "global:project:b")
    expect(model.selectedResult?.entry.id == "project:b", "model should select requested result when present")
    model.setQuery("alp")
    expect(model.selectedResult?.entry.id == "project:a", "model should fall back to first result when previous selection disappears")
    model.select(selectionID: "global:missing")
    expect(model.selectedResult?.entry.id == "project:a", "missing explicit selection should not produce an invalid selected result")
}

private func runLocationSwitcherStalePreviewChecks() throws {
    var model = LocationSwitcherModel(index: LocationSessionIndex(records: [
        LocationIndexRecord(entry: .init(id: "project:a", kind: .project, label: "Alpha")),
        LocationIndexRecord(entry: .init(id: "project:b", kind: .project, label: "Beta"))
    ]), mode: .global)
    let firstSelection = model.selectedResultID!
    _ = model.beginPreviewRequest()
    let firstGeneration = model.previewGeneration
    model.select(selectionID: "global:project:b")
    _ = model.beginPreviewRequest()
    let secondGeneration = model.previewGeneration
    expect(!model.acceptPreview(.init(title: "stale alpha"), for: firstSelection, generation: firstGeneration), "stale preview result must be rejected after selection/generation changes")
    expect(model.previewState == nil, "stale preview must not mutate current preview state")
    expect(model.acceptPreview(.init(title: "fresh beta"), for: "global:project:b", generation: secondGeneration), "fresh preview for current selection/generation should be accepted")
    expect(model.previewState?.preview.title == "fresh beta", "accepted fresh preview should become visible state")
}
