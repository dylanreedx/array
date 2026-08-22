import ContinuumRevivedCore
import Foundation

func runDirectoryScopeChecks() throws {
    let projectId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let zoneId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    let explicit = CreationScope(
        projectId: projectId,
        projectRoot: "/repo",
        homeRelativePath: "Sources",
        source: .zone
    )
    let zone = CreationScope(
        projectId: projectId,
        projectRoot: "/repo",
        homeRelativePath: "App",
        source: .explicit,
        zoneId: zoneId
    )
    let focused = CreationScope(
        projectId: projectId,
        projectRoot: "/repo",
        homeRelativePath: "Focused",
        source: .explicit
    )
    let recent = CreationScope(
        projectId: projectId,
        projectRoot: "/repo",
        source: .explicit
    )

    expect(
        CreationScopeResolver.resolve(explicit: explicit, zone: zone, focusedAgent: focused, recentExplicit: recent)?.source == .explicit,
        "creation scope: explicit selection wins"
    )
    expect(
        CreationScopeResolver.resolve(explicit: nil, zone: zone, focusedAgent: focused, recentExplicit: recent)?.source == .zone,
        "creation scope: committed zone wins outside an explicit action"
    )
    expect(
        CreationScopeResolver.resolve(explicit: nil, zone: nil, focusedAgent: focused, recentExplicit: recent)?.source == .focusedAgent,
        "creation scope: focused agent is the unzoned inheritance source"
    )
    expect(
        CreationScopeResolver.resolve(explicit: nil, zone: nil, focusedAgent: nil, recentExplicit: recent)?.source == .recentExplicit,
        "creation scope: workspace-local explicit history is the final automatic source"
    )
    expect(
        CreationScopeResolver.resolve(explicit: nil, zone: nil, focusedAgent: nil, recentExplicit: nil) == nil,
        "creation scope: unresolved creation requires the picker"
    )

    expect(
        FilesystemScope.mapHome("Sources/ContinuumRevived", intoCheckoutRoot: "/tmp/worktree")
            == "/tmp/worktree/Sources/ContinuumRevived",
        "worktree mapping keeps logical Home inside the selected checkout"
    )
    let scope = FilesystemScope(
        projectId: projectId,
        projectRoot: "/repo",
        checkoutRoot: "/tmp/worktree",
        homeRelativePath: "Sources",
        wherePath: "/tmp/worktree/Tests"
    )
    expect(scope.isWhereOutsideHome, "Where outside Home is surfaced but remains representable")

    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
        .appendingPathComponent("ArrayDirectoryScopeChecks-\(UUID().uuidString)", isDirectory: true)
    let root = fixture.appendingPathComponent("project", isDirectory: true)
    let home = root.appendingPathComponent("Sources/App", isDirectory: true)
    let outside = fixture.appendingPathComponent("outside", isDirectory: true)
    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let validatedHome = try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: home)
    expect(
        validatedHome == "Sources/App",
        "Home stores a normalized project-relative path"
    )
    let validatedRoot = try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: root)
    expect(
        validatedRoot == nil,
        "project root is represented as nil Home"
    )
    do {
        _ = try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: outside)
        expect(false, "an outside folder must be rejected")
    } catch ProjectHomeValidationError.homeEscapesProject {
        // expected
    }

    let escapingLink = root.appendingPathComponent("escape", isDirectory: true)
    try fileManager.createSymbolicLink(at: escapingLink, withDestinationURL: outside)
    do {
        _ = try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: escapingLink)
        expect(false, "a symlink escaping the project must be rejected")
    } catch ProjectHomeValidationError.homeEscapesProject {
        // expected
    }

    let placement = ZonePlacement(
        zoneId: zoneId,
        projectId: projectId,
        homeRelativePath: "Sources/App",
        origin: ZonePoint(x: 0, y: 0),
        size: ZoneSize(width: 800, height: 600),
        color: "teal",
        collapsed: false,
        hydrationPolicy: .automatic
    )
    let data = try JSONEncoder().encode(placement)
    let decodedPlacement = try JSONDecoder().decode(ZonePlacement.self, from: data)
    expect(
        decodedPlacement.scope
            == ZoneScope(projectId: projectId, homeRelativePath: "Sources/App"),
        "zone project + Home persist as one scope value"
    )

    print("DirectoryScope checks passed")
}
