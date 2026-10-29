import ContinuumRevivedCore
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func runSwift(_ arguments: [String], captureOutput: Bool = false) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift"] + arguments

    let outputPipe = Pipe()
    if captureOutput {
        process.standardOutput = outputPipe
    }

    try process.run()
    process.waitUntilExit()

    let output: String
    if captureOutput {
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8) ?? ""
    } else {
        output = ""
    }

    return (process.terminationStatus, output)
}

func profile(
    id: String,
    displayName: String,
    detail: String = "/usr/bin/tool",
    isSelectable: Bool = true
) -> LaunchPaletteProfileRow {
    LaunchPaletteProfileRow(id: id, displayName: displayName, detail: detail, isSelectable: isSelectable)
}

let builtInActionNames = [
    "New Agent…", "New Agent Without a Tile…", "Fan Out Selected Tickets…",
    "New Note", "New Board", "New Browser", "New iOS Preview", "Open File...", "Open File Tree...", "New Diff Review",
    "Fit Canvas to All", "Tidy Canvas", "Focus Current Tile", "Back to Previous View",
    "Go to Previous Tile", "Go to Previous Zone", "Toggle Workspace Sidebar", "Show Processes",
    "Replay Getting Started", "New Workspace…",
    // M1.11 (`.plans/46`): the only add route a workspace with no projects has.
    "Add Project…",
]

let rows = LaunchPaletteModel.makeRows(profiles: [
    profile(id: "shell", displayName: "Shell"),
    profile(id: "claude", displayName: "Claude CLI Terminal")
])
expect(rows.map(\.displayName) == ["Shell", "Claude CLI Terminal"] + builtInActionNames + ["Create Zone…"], "palette appends every registered built-in action after profiles, then Create Zone")
expect(LaunchPaletteModel.filterRows(rows, query: "kanban").map(\.displayName) == ["New Board"], "kanban query reaches the board creation action")
expect(LaunchPaletteModel.filterRows(rows, query: "note").map(\.displayName) == ["New Note"], "note query matches New Note")
expect(LaunchPaletteModel.filterRows(rows, query: "new").map(\.displayName) == ["New Agent…", "New Agent Without a Tile…", "New Note", "New Board", "New Browser", "New iOS Preview", "New Diff Review", "New Workspace…", "Create Zone…"], "new query matches New actions including Create Zone (has 'new' token)")
expect(LaunchPaletteModel.filterRows(rows, query: "fit all").map(\.displayName) == ["Fit Canvas to All"], "fit all query matches Fit Canvas to All")
expect(LaunchPaletteModel.filterRows(rows, query: "browser").map(\.displayName) == ["New Browser"], "browser query matches New Browser")
let focusedBrowserRows = LaunchPaletteModel.makeRows(profiles: [], contextualActions: [.openInspectorForFocusedBrowser])
expect(focusedBrowserRows.contains { $0.displayName == "Open Inspector for Focused Browser" }, "focused browser context appends the inspector palette action")
expect(LaunchPaletteModel.filterRows(focusedBrowserRows, query: "inspector focused browser").map(\.displayName) == ["Open Inspector for Focused Browser"], "focused browser inspector action filters by inspector/focused/browser")
expect(!rows.contains { $0.displayName == "Open Inspector for Focused Browser" }, "inspector palette action is hidden when no focused-browser context is supplied")
expect(LaunchPaletteModel.filterRows(rows, query: "open file").map(\.displayName) == ["Open File...", "Open File Tree..."], "open file query matches file actions")
expect(LaunchPaletteModel.filterRows(rows, query: "tree").map(\.displayName) == ["Open File Tree..."], "tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "file tree").map(\.displayName) == ["Open File Tree..."], "file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "open file tree").map(\.displayName) == ["Open File Tree..."], "open file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "diff").map(\.displayName) == ["New Diff Review"], "diff query matches New Diff Review")
expect(LaunchPaletteModel.filterRows(rows, query: "agent").map(\.displayName) == ["New Agent…", "New Agent Without a Tile…", "Fan Out Selected Tickets…"], "agent query matches the three agent actions in declared order (tile-bound first, then the P2D.6 fan-out), not raw CLI profiles")
expect(LaunchPaletteModel.filterRows(rows, query: "headless").map(\.displayName) == ["New Agent Without a Tile…"], "headless query matches only the tile-less agent action (P2A.6)")
expect(LaunchPaletteModel.filterRows(rows, query: "claude").map(\.displayName) == ["Claude CLI Terminal"], "profile query still matches explicit CLI profiles")
expect(LaunchPaletteModel.filterRows(rows, query: "example.com").map(\.displayName) == ["Open \"https://example.com\"…"], "url-ish query shows normalized Open URL row")
expect(LaunchPaletteModel.filterRows(rows, query: "web.dev").first?.displayName == "Open \"https://web.dev\"…", "URL row is default before fuzzy browser matches")
expect(LaunchPaletteModel.filterRows(rows, query: "notebook.com").first?.displayName == "Open \"https://notebook.com\"…", "URL row is default before fuzzy note matches")
expect(LaunchPaletteModel.filterRows(rows, query: "open.ai").first?.displayName == "Open \"https://open.ai\"…", "URL row is default before fuzzy open matches")

let harnessRows = LaunchPaletteModel.makeRows(
    profiles: [],
    harnessRoles: [HarnessRole(id: "qa-reviewer", displayName: "QA Reviewer", promptPath: "/repo/.pi/agents/qa-reviewer.md")]
)
expect(harnessRows.map(\.displayName) == builtInActionNames + ["Run QA Reviewer Agent…", "Create Zone…"], "palette appends harness role actions after built-in actions, then Create Zone")
expect(LaunchPaletteModel.filterRows(harnessRows, query: "run qa").map(\.displayName) == ["Run QA Reviewer Agent…"], "harness role row filters by run and role name")
expect(harnessRows.last?.isSelectable == true, "Create Zone action row is selectable (last row in harnessRows)")

// Jump-to-tile rows: appended after the built-in actions; filter by "jump" or title.
let jumpTileA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
let jumpTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
let jumpRows = LaunchPaletteModel.makeRows(
    profiles: [],
    jumpTiles: [JumpTileRow(id: jumpTileA, title: "API Server"), JumpTileRow(id: jumpTileB, title: "Notes")]
)
expect(jumpRows.map(\.displayName) == builtInActionNames + ["Jump to API Server", "Jump to Notes", "Create Zone…"], "palette appends Jump-to-tile rows after the built-in actions, then Create Zone")
expect(LaunchPaletteModel.filterRows(jumpRows, query: "jump notes").map(\.displayName) == ["Jump to Notes"], "jump row filters by 'jump' + title")
expect(LaunchPaletteModel.filterRows(jumpRows, query: "api").map(\.displayName) == ["Jump to API Server"], "jump row filters by title alone")
expect(jumpRows.last?.isSelectable == true, "Create Zone action row is selectable (last row in jumpRows)")

// Jump-to-zone rows: appended after jump-tile rows; filter by "jump" + title or title alone; Create Zone action appended last of this block.
let zA = UUID(uuidString: "00000000-0000-0000-0000-000000000C01")!
let zB = UUID(uuidString: "00000000-0000-0000-0000-000000000C02")!
let jumpZoneRows = LaunchPaletteModel.makeRows(
    profiles: [],
    jumpZones: [JumpZoneRow(id: zA, title: "API"), JumpZoneRow(id: zB, title: "Scratch")]
)
// Assertion 1: order — 11 built-ins + zone rows + Create Zone.
expect(jumpZoneRows.map(\.displayName) == builtInActionNames + ["Jump to API", "Jump to Scratch", "Create Zone…"], "palette appends jump-zone rows then Create Zone action after built-in actions")
// Assertion 2: filter by "jump scratch".
expect(LaunchPaletteModel.filterRows(jumpZoneRows, query: "jump scratch").map(\.displayName) == ["Jump to Scratch"], "jump zone row filters by 'jump' + title")
// Assertion 3: filter by title alone.
expect(LaunchPaletteModel.filterRows(jumpZoneRows, query: "api").map(\.displayName) == ["Jump to API"], "jump zone row filters by title alone")
// Assertion 4: filter by "create zone".
expect(LaunchPaletteModel.filterRows(jumpZoneRows, query: "create zone").map(\.displayName) == ["Create Zone…"], "create-zone action row filters by its tokens")
// Assertion 5: selectability.
let jumpZoneRow = jumpZoneRows.first(where: { $0.displayName == "Jump to API" })!
let createZoneRow = jumpZoneRows.first(where: { $0.displayName == "Create Zone…" })!
expect(jumpZoneRow.isSelectable == true, "jump-to-zone row is selectable")
expect(createZoneRow.isSelectable == true, "create-zone action row is selectable")
// Assertion 6: co-existence — tile-jump BEFORE zone-jump BEFORE Create Zone.
let coexistRows = LaunchPaletteModel.makeRows(
    profiles: [],
    jumpTiles: [JumpTileRow(id: jumpTileA, title: "TileX")],
    jumpZones: [JumpZoneRow(id: zA, title: "ZoneY")]
)
let coexistNames = coexistRows.map(\.displayName)
let tileXIdx = coexistNames.firstIndex(of: "Jump to TileX")!
let zoneYIdx = coexistNames.firstIndex(of: "Jump to ZoneY")!
let createZoneIdx = coexistNames.firstIndex(of: "Create Zone…")!
expect(tileXIdx < zoneYIdx && zoneYIdx < createZoneIdx, "tile-jump rows appear before zone-jump rows which appear before Create Zone: tile=\(tileXIdx) zone=\(zoneYIdx) create=\(createZoneIdx)")

let switchProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000000129")!
let projectRows = LaunchPaletteModel.makeRows(
    profiles: [],
    projects: [ProjectPickerRow(
        id: switchProjectId,
        name: "Work Project",
        rootPath: "/projects/work",
        lastOpenedAt: Date(timeIntervalSince1970: 1_000),
        pinned: false,
        isLastActive: false,
        availability: .available
    )]
)
expect(projectRows.map(\.displayName) == builtInActionNames + ["Create Zone…", "Add Work Project to Canvas"], "palette appends Create Zone then add-project rows")
expect(LaunchPaletteModel.filterRows(projectRows, query: "add work").map(\.displayName) == ["Add Work Project to Canvas"], "add-project row filters by add token and project name")
expect(projectRows.last?.isSelectable == true, "available add-project row is selectable")

let worktreeProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000000130")!
let worktreeRows = LaunchPaletteModel.makeRows(
    profiles: [],
    projects: [ProjectPickerRow(
        id: worktreeProjectId,
        name: "Work Project",
        rootPath: "/projects/work-wt",
        lastOpenedAt: Date(timeIntervalSince1970: 1_100),
        pinned: false,
        isLastActive: false,
        worktreeOf: switchProjectId,
        availability: .available
    )]
)
expect(worktreeRows.last?.displayName == "Add Work Project Worktree to Canvas", "palette labels worktree add-project rows distinctly")
expect(LaunchPaletteModel.filterRows(worktreeRows, query: "worktree").map(\.displayName).contains("Add Work Project Worktree to Canvas"), "palette worktree rows filter by worktree token")

let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000154")!
let workspaceRows = LaunchPaletteModel.makeRows(
    profiles: [],
    workspaces: [WorkspaceEntry(
        id: workspaceId,
        name: "Client Work",
        projectIds: [switchProjectId],
        createdAt: Date(timeIntervalSince1970: 2_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )]
)
expect(workspaceRows.map(\.displayName) == builtInActionNames + ["Create Zone…", "Switch to Client Work Workspace", "Rename Client Work Workspace…", "Delete Client Work Workspace…"], "palette appends Create Zone then workspace rows")
expect(LaunchPaletteModel.filterRows(workspaceRows, query: "switch client").map(\.displayName) == ["Switch to Client Work Workspace"], "workspace row filters by switch token and workspace name")
expect(LaunchPaletteModel.filterRows(workspaceRows, query: "new workspace").map(\.displayName) == ["New Workspace…"], "new-workspace action filters by workspace tokens")
expect(LaunchPaletteModel.filterRows(workspaceRows, query: "workspace sidebar").map(\.displayName) == ["Toggle Workspace Sidebar"], "workspace-sidebar action filters by workspace/sidebar tokens")
let emptyWorkspaceRows = LaunchPaletteModel.makeRows(
    profiles: [],
    workspaces: [WorkspaceEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000155")!,
        name: "Empty",
        projectIds: [],
        createdAt: Date(timeIntervalSince1970: 2_100),
        updatedAt: Date(timeIntervalSince1970: 2_100)
    )]
)
let emptyWorkspaceCreateZoneIndex = builtInActionNames.count
expect(emptyWorkspaceRows[emptyWorkspaceCreateZoneIndex].isSelectable == true, "Create Zone action after registered built-ins is selectable")
expect(emptyWorkspaceRows[emptyWorkspaceCreateZoneIndex + 1].isSelectable == false, "empty workspace switch rows are not selectable")

let missingRows = LaunchPaletteModel.makeRows(profiles: [
    profile(id: "shell", displayName: "Shell", detail: "zsh not found", isSelectable: false),
    profile(id: "custom", displayName: "Custom Command", detail: "custom not configured", isSelectable: false)
])
expect(!missingRows[0].isSelectable, "missing profile rows are not selectable")
expect(!missingRows[1].isSelectable, "not-configured profile rows are not selectable")
for (offset, name) in builtInActionNames.enumerated() {
    expect(missingRows[offset + 2].isSelectable, "\(name) registered action row is selectable")
}
expect(missingRows[builtInActionNames.count + 2].isSelectable, "Create Zone action row is selectable")

expect(LaunchPaletteModel.urlCandidate(from: "example.com") == "https://example.com", "bare domain defaults to https")
expect(LaunchPaletteModel.urlCandidate(from: "localhost:3000") == "http://localhost:3000", "localhost defaults to http")
expect(LaunchPaletteModel.urlCandidate(from: "127.0.0.1:5173") == "http://127.0.0.1:5173", "IP defaults to http")
expect(LaunchPaletteModel.urlCandidate(from: "https://example.com/path") == "https://example.com/path", "full https URL passes through")
expect(LaunchPaletteModel.urlCandidate(from: "https://a.b/c?d") == "https://a.b/c?d", "scheme URL with query passes through")
expect(LaunchPaletteModel.urlCandidate(from: "http://example.com") == "http://example.com", "full http URL passes through")
expect(LaunchPaletteModel.urlCandidate(from: "  example.com  ") == "https://example.com", "URL candidate trims whitespace")
expect(LaunchPaletteModel.urlCandidate(from: "note") == nil, "plain word is not URL-ish")
expect(LaunchPaletteModel.urlCandidate(from: "localhostevil") == nil, "localhost prefix alone is not URL-ish")
expect(LaunchPaletteModel.urlCandidate(from: "open example.com") == nil, "multi-word URL-ish input is rejected")
expect(LaunchPaletteModel.urlCandidate(from: "   ") == nil, "blank query is not URL-ish")

let root = URL(fileURLWithPath: "/tmp/continuum/project")
expect(LaunchPaletteModel.isFileURL(root.appendingPathComponent("README.md"), insideProjectRoot: root), "root child file is accepted")
expect(LaunchPaletteModel.isFileURL(root.appendingPathComponent("Sources/App.swift"), insideProjectRoot: root), "nested root file is accepted")
expect(!LaunchPaletteModel.isFileURL(URL(fileURLWithPath: "/tmp/continuum/project-sibling/README.md"), insideProjectRoot: root), "sibling prefix path is rejected")
expect(!LaunchPaletteModel.isFileURL(URL(fileURLWithPath: "/tmp/continuum/other.txt"), insideProjectRoot: root), "outside project path is rejected")

// New <Harness> Agent rows: one per CLI, straight after plain New Agent…, in the
// order given (the app puts the Settings default first); a harness that cannot
// run is listed but unselectable, with its reason as the subtitle.
let harnessAgentRows = LaunchPaletteModel.makeRows(profiles: [], agentHarnesses: [
    AgentHarnessPaletteRow(harness: .codex, isDefault: true),
    AgentHarnessPaletteRow(harness: .claudeCode, isDefault: false),
    AgentHarnessPaletteRow(harness: .pi, isDefault: false, unavailableReason: "Pi is signed out — run `pi` and use /login, then try again."),
])
expect(harnessAgentRows.map(\.displayName) == ["New Agent…", "New Codex Agent…", "New Claude Code Agent…", "New Pi Agent…"] + builtInActionNames.dropFirst() + ["Create Zone…"],
       "harness rows sit straight after New Agent…, in the given order, and nothing else moves")
expect(harnessAgentRows.first(where: { $0.displayName == "New Pi Agent…" })?.isSelectable == false, "a harness with a reason is unselectable")
expect(LaunchPaletteModel.filterRows(harnessAgentRows, query: "codex").map(\.displayName) == ["New Codex Agent…"], "codex query finds only the Codex row")
expect(LaunchPaletteModel.filterRows(harnessAgentRows, query: "anthropic").map(\.displayName) == ["New Claude Code Agent…"], "anthropic finds the Claude Code row")
expect(LaunchPaletteModel.filterRows(harnessAgentRows, query: "agent").map(\.displayName) == ["New Agent…", "New Codex Agent…", "New Claude Code Agent…", "New Pi Agent…", "New Agent Without a Tile…", "Fan Out Selected Tickets…"],
       "agent query reaches every harness row after New Agent…")
let harnessItems = harnessAgentRows.compactMap { row -> CommandCenterItem? in
    if case .agentHarness = row { return LaunchPaletteModel.presentation(for: row) }
    return nil
}
expect(harnessItems.map(\.stableID) == ["action:new-agent:codex", "action:new-agent:claude-code", "action:new-agent:pi"], "harness rows keep stable ids")
expect(harnessItems[0].subtitle?.hasPrefix("Default · ") == true && harnessItems[1].subtitle?.hasPrefix("Default") == false, "only the default row says Default")
expect(harnessItems[2].subtitle == "Pi is signed out — run `pi` and use /login, then try again.", "an unavailable harness shows its reason")
let searchedAgentIDs = LaunchPaletteModel.makeSections(rows: harnessAgentRows, query: "agent").flatMap(\.items).map(\.stableID)
let harnessOrder = ["action:new-agent:codex", "action:new-agent:claude-code", "action:new-agent:pi"].compactMap { searchedAgentIDs.firstIndex(of: $0) }
expect(harnessOrder.count == 3 && harnessOrder == harnessOrder.sorted() && searchedAgentIDs.first == "action:new-agent",
       "searching 'agent' ranks New Agent… first, then the harness rows default first, not alphabetically: \(searchedAgentIDs)")
let homeIDs = LaunchPaletteModel.makeSections(rows: harnessAgentRows, query: "").flatMap(\.items).map(\.stableID)
// The empty ⌘K offers every OTHER CLI that can run, straight under plain New
// Agent (which is the default's): it was search-only, so a person whose default
// was Claude could only start Claude agents without knowing to type "codex".
// The default's own row stays off (plain New Agent is it), and so does a CLI
// that cannot run.
expect(Array(homeIDs.prefix(2)) == ["action:new-agent", "action:new-agent:claude-code"]
           && !homeIDs.contains("action:new-agent:codex") && !homeIDs.contains("action:new-agent:pi"),
       "the empty-query home offers each ready non-default CLI under New Agent: \(homeIDs)")

let build = try runSwift(["build", "--product", "Array"])
guard build.status == 0 else { Foundation.exit(build.status) }

let binPath = try runSwift(["build", "--show-bin-path"], captureOutput: true)
guard binPath.status == 0 else { Foundation.exit(binPath.status) }

let appPath = URL(fileURLWithPath: binPath.output.trimmingCharacters(in: .whitespacesAndNewlines))
    .appendingPathComponent("Array")

for flag in ["--palette-duplicate-root-check", "--palette-first-responder-restore-check", "--palette-zone-check"] {
    let process = Process()
    process.executableURL = appPath
    process.arguments = [flag]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { Foundation.exit(process.terminationStatus) }
}

Foundation.exit(0)
