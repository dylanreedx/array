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

let rows = LaunchPaletteModel.makeRows(profiles: [
    profile(id: "shell", displayName: "Shell"),
    profile(id: "claude", displayName: "Claude Code")
])
expect(rows.map(\.displayName) == ["Shell", "Claude Code", "New Note", "New Browser", "Open File...", "Open File Tree...", "New Workspace…"], "palette appends note/browser/file/file-tree/workspace actions after profiles")
expect(LaunchPaletteModel.filterRows(rows, query: "note").map(\.displayName) == ["New Note"], "note query matches New Note")
expect(LaunchPaletteModel.filterRows(rows, query: "new").map(\.displayName) == ["New Note", "New Browser", "New Workspace…"], "new query matches New actions")
expect(LaunchPaletteModel.filterRows(rows, query: "browser").map(\.displayName) == ["New Browser"], "browser query matches New Browser")
expect(LaunchPaletteModel.filterRows(rows, query: "open file").map(\.displayName) == ["Open File...", "Open File Tree..."], "open file query matches file actions")
expect(LaunchPaletteModel.filterRows(rows, query: "tree").map(\.displayName) == ["Open File Tree..."], "tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "file tree").map(\.displayName) == ["Open File Tree..."], "file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "open file tree").map(\.displayName) == ["Open File Tree..."], "open file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "claude").map(\.displayName) == ["Claude Code"], "profile query still matches profiles")
expect(LaunchPaletteModel.filterRows(rows, query: "example.com").map(\.displayName) == ["Open \"https://example.com\"…"], "url-ish query shows normalized Open URL row")
expect(LaunchPaletteModel.filterRows(rows, query: "web.dev").first?.displayName == "Open \"https://web.dev\"…", "URL row is default before fuzzy browser matches")
expect(LaunchPaletteModel.filterRows(rows, query: "notebook.com").first?.displayName == "Open \"https://notebook.com\"…", "URL row is default before fuzzy note matches")
expect(LaunchPaletteModel.filterRows(rows, query: "open.ai").first?.displayName == "Open \"https://open.ai\"…", "URL row is default before fuzzy open matches")

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
expect(projectRows.map(\.displayName) == ["New Note", "New Browser", "Open File...", "Open File Tree...", "New Workspace…", "Add Work Project to Canvas"], "palette appends add-project rows")
expect(LaunchPaletteModel.filterRows(projectRows, query: "add work").map(\.displayName) == ["Add Work Project to Canvas"], "add-project row filters by add token and project name")
expect(projectRows.last?.isSelectable == true, "available add-project row is selectable")

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
expect(workspaceRows.map(\.displayName) == ["New Note", "New Browser", "Open File...", "Open File Tree...", "New Workspace…", "Switch to Client Work Workspace", "Rename Client Work Workspace…", "Delete Client Work Workspace…"], "palette appends workspace rows")
expect(LaunchPaletteModel.filterRows(workspaceRows, query: "switch client").map(\.displayName) == ["Switch to Client Work Workspace"], "workspace row filters by switch token and workspace name")
expect(LaunchPaletteModel.filterRows(workspaceRows, query: "new workspace").map(\.displayName) == ["New Workspace…"], "new-workspace action filters by workspace tokens")
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
expect(emptyWorkspaceRows[5].isSelectable == false, "empty workspace switch rows are not selectable")

let missingRows = LaunchPaletteModel.makeRows(profiles: [
    profile(id: "shell", displayName: "Shell", detail: "zsh not found", isSelectable: false),
    profile(id: "custom", displayName: "Custom Command", detail: "custom not configured", isSelectable: false)
])
expect(!missingRows[0].isSelectable, "missing profile rows are not selectable")
expect(!missingRows[1].isSelectable, "not-configured profile rows are not selectable")
expect(missingRows[2].isSelectable, "New Note action row is selectable")
expect(missingRows[3].isSelectable, "New Browser action row is selectable")
expect(missingRows[4].isSelectable, "Open File action row is selectable")
expect(missingRows[5].isSelectable, "Open File Tree action row is selectable")
expect(missingRows[6].isSelectable, "New Workspace action row is selectable")

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

let build = try runSwift(["build", "--product", "continuum-revived"])
guard build.status == 0 else { Foundation.exit(build.status) }

let binPath = try runSwift(["build", "--show-bin-path"], captureOutput: true)
guard binPath.status == 0 else { Foundation.exit(binPath.status) }

let appPath = URL(fileURLWithPath: binPath.output.trimmingCharacters(in: .whitespacesAndNewlines))
    .appendingPathComponent("continuum-revived")

for flag in ["--palette-duplicate-root-check", "--palette-first-responder-restore-check"] {
    let process = Process()
    process.executableURL = appPath
    process.arguments = [flag]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { Foundation.exit(process.terminationStatus) }
}

Foundation.exit(0)
