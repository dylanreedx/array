import ContinuumRevivedCore
import Foundation

func runLocationSessionIndexP5Checks() throws {
    try runLocationSessionIndexP5R1RankingChecks()
    try runLocationSessionIndexP5R2DisambiguationPrivacyChecks()
    try runLocationSessionIndexP5R3MatchingChecks()
    try runLocationSessionIndexP5R4DiscoveryChecks()
    try runLocationSessionIndexP5R5PreviewChecks()
    try runLocationSwitcherFoundationChecks()
    print("LocationSessionIndex P5 checks passed: P5.R1-P5.R5 + LocationSwitcher foundation")
}

func runLocationSessionIndexP5R1RankingChecks() throws {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let index = LocationSessionIndex(records: [
        record("discovered", .directory, "Discovered", workspace: .init(discoverySource: .boundedDiscovery)),
        record("workspace", .project, "Workspace", workspace: .init(isWorkspaceProject: true)),
        record("active", .agent, "Active", activity: .init(activeAgentCount: 2, isActive: true)),
        record("recent", .session, "Recent", activity: .init(lastUsedAt: now.addingTimeInterval(-60))),
        record("nearby-project", .project, "Nearby Project", spatial: .init(nearbyProjectRank: 1)),
        record("nearby-context", .tile, "Nearby Context", spatial: .init(nearbyContextRank: 1)),
        record("anchor", .agent, "Anchor")
    ])

    let results = index.search("", context: LocationIndexSearchContext(mode: .globalNavigation, anchorID: "id:anchor", now: now))
    expect(results.map(\.entry.id.rawValue) == [
        "id:anchor",
        "id:nearby-context",
        "id:nearby-project",
        "id:recent",
        "id:active",
        "id:workspace",
        "id:discovered"
    ], "P5.R1 ranking order must be anchor, nearby context, nearby projects, recency, active agents, workspace projects, discovery")

    let spatialTieIndex = LocationSessionIndex(records: [
        record("nearby-context-rank2-alpha", .tile, "Alpha", spatial: .init(anchorDistance: 1, nearbyContextRank: 2)),
        record("nearby-context-rank1-zulu", .tile, "Zulu", spatial: .init(anchorDistance: 99, nearbyContextRank: 1)),
        record("nearby-project-rank2-alpha", .project, "Alpha", spatial: .init(anchorDistance: 1, nearbyProjectRank: 2)),
        record("nearby-project-rank1-zulu", .project, "Zulu", spatial: .init(anchorDistance: 99, nearbyProjectRank: 1))
    ])
    expect(spatialTieIndex.search("", context: .init(mode: .globalNavigation)).map(\.entry.id.rawValue) == [
        "id:nearby-context-rank1-zulu",
        "id:nearby-context-rank2-alpha",
        "id:nearby-project-rank1-zulu",
        "id:nearby-project-rank2-alpha"
    ], "P5.R1 nearby-context/project buckets must sort by documented spatial rank before anchor distance and labels")

    let anchorDistanceIndex = LocationSessionIndex(records: [
        record("nearby-context-far-alpha", .tile, "Alpha", spatial: .init(anchorDistance: 20, nearbyContextRank: 1)),
        record("nearby-context-near-zulu", .tile, "Zulu", spatial: .init(anchorDistance: 2, nearbyContextRank: 1))
    ])
    expect(anchorDistanceIndex.search("", context: .init(mode: .globalNavigation)).map(\.entry.id.rawValue) == [
        "id:nearby-context-near-zulu",
        "id:nearby-context-far-alpha"
    ], "P5.R1 same spatial rank should sort by anchorDistance before label tie breakers")
}

func runLocationSessionIndexP5R2DisambiguationPrivacyChecks() throws {
    let index = LocationSessionIndex(records: [
        LocationIndexRecord(
            entry: LocationIndexEntry(
                id: "session:left",
                kind: .session,
                label: "Review",
                displayPath: "continuum/Sources",
                workspace: .init(projectLabel: "continuum")
            ),
            privateRouting: .init(providerSessionID: "provider-secret-1", transcriptPath: "/Users/dylan/.claude/transcript.jsonl")
        ),
        LocationIndexRecord(
            entry: LocationIndexEntry(
                id: "session:right",
                kind: .session,
                label: "Review",
                displayPath: "website/Sources",
                workspace: .init(projectLabel: "website")
            ),
            privateRouting: .init(providerSessionID: "provider-secret-2", transcriptPath: "/tmp/private/transcript.jsonl")
        )
    ])

    let results = index.search("review", context: LocationIndexSearchContext(mode: .reference))
    expect(results.count == 2, "P5.R2 same-name sessions should both match")
    expect(Set(results.map(\.disambiguatedLabel)) == ["Review — continuum", "Review — website"], "P5.R2 collision labels should be friendly and unambiguous")

    let data = try JSONEncoder().encode(index.entriesForCodableOutput())
    let json = String(decoding: data, as: UTF8.self)
    expect(!json.contains("provider-secret"), "P5 privacy: provider session IDs must not appear in shared/Codable output")
    expect(!json.contains("transcript"), "P5 privacy: transcript paths must not appear in shared/Codable output")
    expect(!json.contains("/Users/dylan"), "P5 privacy: private absolute routing paths must not appear in shared/Codable output")
}

func runLocationSessionIndexP5R3MatchingChecks() throws {
    let index = LocationSessionIndex(records: [
        LocationIndexRecord(entry: LocationIndexEntry(
            id: "project:continuum",
            kind: .project,
            label: "Continuum Revived",
            aliases: ["overnight"],
            displayPath: "personal/continuum-overnight"
        )),
        LocationIndexRecord(entry: LocationIndexEntry(
            id: "directory:core",
            kind: .directory,
            label: "ContinuumRevivedCore",
            displayPath: "continuum-overnight/Sources/ContinuumRevivedCore"
        )),
        LocationIndexRecord(entry: LocationIndexEntry(
            id: "agent:qa",
            kind: .agent,
            label: "QA Reviewer",
            aliases: ["quality"]
        ))
    ])

    expect(index.search("", context: .init(mode: .globalNavigation)).map(\.entry.id.rawValue) == [
        "project:continuum", "directory:core", "agent:qa"
    ], "P5.R3 empty query should be deterministic by normalized label/id after rank ties")
    expect(index.search("src/core", context: .init(mode: .reference)).first?.entry.id == "directory:core", "P5.R3 partial path fragments should fuzzy-match display paths")
    expect(index.search("ovrn", context: .init(mode: .location)).first?.entry.id == "project:continuum", "P5.R3 aliases should participate in deterministic fuzzy matching")
}

func runLocationSessionIndexP5R4DiscoveryChecks() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("continuum-location-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp.appendingPathComponent("A/B/C"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temp.appendingPathComponent("D"), withIntermediateDirectories: true)

    let bounded = try LocationIndexDiscovery.discoverDirectories(options: .init(roots: [.init(url: temp, maxDepth: 1, maxEntries: 10)]))
    expect(bounded.records.map(\.entry.label) == ["A", "D"], "P5.R4 discovery should obey depth bounds deterministically")
    expect(!bounded.records.map(\.entry.label).contains("B"), "P5.R4 discovery must not descend past maxDepth")
    expect(bounded.records.map(\.entry.displayPath) == [
        "\(temp.lastPathComponent)/A",
        "\(temp.lastPathComponent)/D"
    ], "P5.R4 discovery display paths should be root-relative with a stable root label")
    let boundedJSON = String(decoding: try JSONEncoder().encode(bounded.records.map(\.entry)), as: UTF8.self)
    expect(!boundedJSON.contains(temp.path), "P5.R4 Codable discovery output must not contain absolute temp host roots")
    expect(!boundedJSON.contains("/Users"), "P5.R4 Codable discovery output must not contain private /Users host roots")
    expect(!boundedJSON.contains("/private"), "P5.R4 Codable discovery output must not contain private absolute host roots")

    let limited = try LocationIndexDiscovery.discoverDirectories(options: .init(roots: [.init(url: temp, maxDepth: 2, maxEntries: 1)]))
    expect(limited.records.count == 1, "P5.R4 discovery should obey maxEntries")

    var cancelledAfterFirstPoll = false
    let cancelled = try LocationIndexDiscovery.discoverDirectories(options: .init(roots: [.init(url: temp, maxDepth: 2, maxEntries: 10)])) {
        if cancelledAfterFirstPoll { return true }
        cancelledAfterFirstPoll = true
        return false
    }
    expect(cancelled.stats.cancelled, "P5.R4 discovery should report cancellation")
    expect(cancelled.records.isEmpty, "P5.R4 cancellation should stop before emitting later entries")

    do {
        _ = try LocationIndexDiscovery.discoverDirectories(options: .init(
            roots: [.init(url: FileManager.default.homeDirectoryForCurrentUser, maxDepth: 1)],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
        expect(false, "P5.R4 recursive HOME discovery should be rejected")
    } catch LocationDiscoveryError.recursiveHomeScanRejected {
        // expected
    }

    do {
        _ = try LocationIndexDiscovery.discoverDirectories(options: .init(roots: [.init(url: URL(fileURLWithPath: "/"), maxDepth: 1)]))
        expect(false, "P5.R4 root filesystem discovery should be rejected before scanning")
    } catch LocationDiscoveryError.unsafeBroadRootRejected {
        // expected
    }

    do {
        _ = try LocationIndexDiscovery.discoverDirectories(options: .init(roots: [.init(url: URL(fileURLWithPath: "/Users"), maxDepth: 1)]))
        expect(false, "P5.R4 /Users discovery should be rejected before scanning")
    } catch LocationDiscoveryError.unsafeBroadRootRejected {
        // expected
    }
}

func runLocationSessionIndexP5R5PreviewChecks() throws {
    final class DelayedPreviewProvider: LocationIndexPreviewProvider, @unchecked Sendable {
        func loadPreview(for request: LocationIndexPreviewRequest) async throws -> LocationIndexPreview {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return LocationIndexPreview(title: request.id.rawValue)
        }
    }

    let provider = DelayedPreviewProvider()
    let start = Date()
    let task = LocationIndexPreviewLoader.startPreview(for: .init(id: "project:slow", mode: .globalNavigation), provider: provider)
    let immediateResults = LocationSessionIndex(records: [record("fast", .project, "Fast")]).search("f", context: .init(mode: .globalNavigation))
    let elapsed = Date().timeIntervalSince(start)
    expect(immediateResults.first?.entry.id == "id:fast", "P5.R5 typing/search should continue while preview is loading")
    expect(elapsed < 0.25, "P5.R5 preview loading should not block selection/search")
    task.cancel()
    _ = awaitTaskIgnoringResult(task)
}

private func awaitTaskIgnoringResult(_ task: Task<LocationIndexPreview, Error>) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        _ = try? await task.value
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + 2) == .success
}

private func record(
    _ suffix: String,
    _ kind: LocationIndexEntityKind,
    _ label: String,
    activity: LocationIndexActivityMetadata = .init(),
    workspace: LocationIndexWorkspaceMetadata = .init(),
    spatial: LocationIndexSpatialMetadata = .init()
) -> LocationIndexRecord {
    LocationIndexRecord(entry: LocationIndexEntry(
        id: LocationIndexID(rawValue: "id:\(suffix)"),
        kind: kind,
        label: label,
        activity: activity,
        workspace: workspace,
        spatial: spatial
    ))
}
