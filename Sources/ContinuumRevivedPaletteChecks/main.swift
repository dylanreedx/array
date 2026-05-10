import ContinuumRevivedCore
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func annotatedProfile(
    id: String,
    displayName: String,
    detail: String = "/usr/bin/tool",
    isSelectable: Bool = true
) -> LaunchPaletteProfileRow {
    LaunchPaletteProfileRow(
        id: id,
        displayName: displayName,
        detail: detail,
        isSelectable: isSelectable
    )
}

func main() {
    do {
        let rows = LaunchPaletteModel.makeRows(profiles: [
            annotatedProfile(id: "shell", displayName: "Shell"),
            annotatedProfile(id: "claude", displayName: "Claude Code")
        ])
        expect(rows.map(\.displayName) == [
            "Shell",
            "Claude Code",
            "New Note",
            "Open File...",
            "Open File Tree..."
        ], "palette appends note, file, and file-tree actions after profiles")
    }

    do {
        let rows = LaunchPaletteModel.makeRows(profiles: [
            annotatedProfile(id: "shell", displayName: "Shell"),
            annotatedProfile(id: "claude", displayName: "Claude Code")
        ])
        expect(LaunchPaletteModel.filterRows(rows, query: "note").map(\.displayName) == ["New Note"], "note query matches New Note")
        expect(LaunchPaletteModel.filterRows(rows, query: "new").map(\.displayName) == ["New Note"], "new query matches New Note")
        expect(LaunchPaletteModel.filterRows(rows, query: "open file").map(\.displayName) == ["Open File...", "Open File Tree..."], "open file query matches file actions")
        expect(LaunchPaletteModel.filterRows(rows, query: "tree").map(\.displayName) == ["Open File Tree..."], "tree query matches Open File Tree")
        expect(LaunchPaletteModel.filterRows(rows, query: "file tree").map(\.displayName) == ["Open File Tree..."], "file tree query matches Open File Tree")
        expect(LaunchPaletteModel.filterRows(rows, query: "open file tree").map(\.displayName) == ["Open File Tree..."], "open file tree query matches Open File Tree")
        expect(LaunchPaletteModel.filterRows(rows, query: "claude").map(\.displayName) == ["Claude Code"], "profile query still matches profile")
    }

    do {
        let rows = LaunchPaletteModel.makeRows(profiles: [
            annotatedProfile(id: "shell", displayName: "Shell", detail: "zsh not found", isSelectable: false),
            annotatedProfile(id: "custom", displayName: "Custom Command", detail: "custom not configured", isSelectable: false)
        ])
        expect(!rows[0].isSelectable, "missing profile rows are not selectable")
        expect(!rows[1].isSelectable, "not-configured profile rows are not selectable")
        expect(rows[2].isSelectable, "New Note action row is selectable")
        expect(rows[3].isSelectable, "Open File action row is selectable")
        expect(rows[4].isSelectable, "Open File Tree action row is selectable")
    }

    do {
        let root = URL(fileURLWithPath: "/tmp/continuum/project")
        expect(LaunchPaletteModel.isFileURL(root.appendingPathComponent("README.md"), insideProjectRoot: root), "root child file is accepted")
        expect(LaunchPaletteModel.isFileURL(root.appendingPathComponent("Sources/App.swift"), insideProjectRoot: root), "nested root file is accepted")
        expect(!LaunchPaletteModel.isFileURL(URL(fileURLWithPath: "/tmp/continuum/project-sibling/README.md"), insideProjectRoot: root), "sibling prefix path is rejected")
        expect(!LaunchPaletteModel.isFileURL(URL(fileURLWithPath: "/tmp/continuum/other.txt"), insideProjectRoot: root), "outside project path is rejected")
    }
}

main()
