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
expect(rows.map(\.displayName) == ["Shell", "Claude Code", "New Note", "Open File...", "Open File Tree..."], "palette appends note/file/file-tree actions after profiles")
expect(LaunchPaletteModel.filterRows(rows, query: "note").map(\.displayName) == ["New Note"], "note query matches New Note")
expect(LaunchPaletteModel.filterRows(rows, query: "new").map(\.displayName) == ["New Note"], "new query matches New Note")
expect(LaunchPaletteModel.filterRows(rows, query: "open file").map(\.displayName) == ["Open File...", "Open File Tree..."], "open file query matches file actions")
expect(LaunchPaletteModel.filterRows(rows, query: "tree").map(\.displayName) == ["Open File Tree..."], "tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "file tree").map(\.displayName) == ["Open File Tree..."], "file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "open file tree").map(\.displayName) == ["Open File Tree..."], "open file tree query matches Open File Tree")
expect(LaunchPaletteModel.filterRows(rows, query: "claude").map(\.displayName) == ["Claude Code"], "profile query still matches profiles")

let missingRows = LaunchPaletteModel.makeRows(profiles: [
    profile(id: "shell", displayName: "Shell", detail: "zsh not found", isSelectable: false),
    profile(id: "custom", displayName: "Custom Command", detail: "custom not configured", isSelectable: false)
])
expect(!missingRows[0].isSelectable, "missing profile rows are not selectable")
expect(!missingRows[1].isSelectable, "not-configured profile rows are not selectable")
expect(missingRows[2].isSelectable, "New Note action row is selectable")
expect(missingRows[3].isSelectable, "Open File action row is selectable")
expect(missingRows[4].isSelectable, "Open File Tree action row is selectable")

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
