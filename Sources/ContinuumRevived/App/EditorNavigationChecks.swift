import AppKit
import ContinuumRevivedCore

@MainActor
enum EditorNavigationChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-editor-navigation-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first.swift")
        let second = root.appendingPathComponent("second.swift")
        let markdown = root.appendingPathComponent("README.md")
        try "let first = 1\r\n".write(to: first, atomically: true, encoding: .utf8)
        try "let second = 2\n".write(to: second, atomically: true, encoding: .utf8)
        try "# Preview\n".write(to: markdown, atomically: true, encoding: .utf8)
        func location(_ url: URL) -> DocumentLocation {
            DocumentLocationResolver.resolve(fileURL: url, explicitRoot: .init(rootURL: root, projectId: nil))
        }
        var metadata = TileMetadata(filePath: first.path)
        metadata.documentLocation = location(first)
        metadata.fileEditorViewState = FileEditorViewState(sidebarExpanded: false)
        let model = Tile(id: UUID(), kind: .file, title: "first.swift",
                         frame: .init(x: 20, y: 30, width: 640, height: 480),
                         zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata)
        let view = FileTileNSView(tile: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { view.prepareForRemovalFromScene(); window.orderOut(nil) }
        let mountedEditor = view.qaCodeEditor
        let initial = try snapshot(view)
        try expect(initial.text == "let first = 1\n", "real web editor must load first file")
        try expect(try navigate(view, to: location(second)), "clean switch must succeed")
        try expect(view.qaCodeEditor === mountedEditor, "switch must retain the mounted WebKit host")
        try expect(view.tile.id == model.id && view.tile.frame == model.frame, "switch must preserve tile identity and geometry")
        try expect(view.tile.metadata.fileEditorViewState?.sidebarExpanded == false, "switch must retain collapsed sidebar")
        try expect(try snapshot(view).text == "let second = 2\n", "switch must replace real web document")
        try append(view, "// draft\n")
        view.qaSetSwitchDecision = { .alertThirdButtonReturn }
        try expect(!(try navigate(view, to: location(first))), "Cancel must prevent switching")
        try expect(view.tile.metadata.filePath == second.path && view.isDirty, "Cancel must retain source and native dirty draft")
        try expect(view.qaDraftText?.contains("// draft") == true, "barrier must absorb latest web edit")
        view.qaSetSwitchDecision = { .alertSecondButtonReturn }
        try expect(!(try navigate(view, to: location(first), beforeCommit: { throw Failure(description: "fixture persistence failure") })),
                   "failed relationship persistence must prevent replacement")
        try expect(view.qaDraftText?.contains("// draft") == true && view.isDirty, "failed commit must retain discarded-but-uncommitted draft")
        try expect(try navigate(view, to: location(first)), "Discard must switch")
        try expect(try String(contentsOf: second, encoding: .utf8) == "let second = 2\n", "Discard must not write source")
        try append(view, "// saved\n")
        view.qaSetSwitchDecision = { .alertFirstButtonReturn }
        try expect(try navigate(view, to: location(second)), "Save must switch after durable write")
        try expect(try String(contentsOf: first, encoding: .utf8).contains("// saved"), "Save must include barrier snapshot")
        let savedFirst = try String(contentsOf: first, encoding: .utf8)
        try expect(savedFirst.contains("\r\n") && !savedFirst.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                   "WebKit edits and barrier saves must preserve CRLF line endings")
        try append(view, "// missing draft\n")
        try fm.removeItem(at: second)
        try expect(!(try navigate(view, to: location(first))), "missing source must prevent Save and switch")
        try expect(!fm.fileExists(atPath: second.path) && view.isDirty, "failed Save must never recreate missing source")
        view.qaSetSwitchDecision = { .alertSecondButtonReturn }
        try expect(try navigate(view, to: location(markdown)), "Discard must allow leaving missing file")
        try expect(view.mode == .preview && view.presentation == .markdown, "new Markdown document must open in Preview")
        try expect(try snapshot(view).text == "# Preview\n", "Markdown source must load alongside native preview")
        let standalone = DocumentLocation(path: first.path, scope: .standalone)
        try expect(try navigate(view, to: standalone), "standalone transition must succeed")
        try expect(view.qaSidebarRoot == nil, "standalone transition must remove checkout sidebar")
        print("Editor navigation checks passed: real WebKit switch, barrier, Save/Discard/Cancel, failed commit, missing-file protection, Markdown, sidebar scope")
    }

    private static func snapshot(_ view: FileTileNSView) throws -> CodeEditorSnapshot {
        guard let editor = view.qaCodeEditor else { throw Failure(description: "missing code editor") }
        var result: Result<CodeEditorSnapshot, CodeEditorHostError>?
        editor.requestSnapshot(documentID: view.qaDocumentID) { result = $0 }
        try wait { result != nil }
        return try result!.get()
    }

    private static func append(_ view: FileTileNSView, _ text: String) throws {
        let current = try snapshot(view)
        var result: Result<UInt64, CodeEditorHostError>?
        view.qaCodeEditor?.applyEdits(documentID: view.qaDocumentID, expectedRevision: current.revision,
            revision: current.revision + 1,
            changes: [.init(fromUTF16: current.text.utf16.count, toUTF16: current.text.utf16.count, insertedText: text)]) { result = $0 }
        try wait { result != nil }
        _ = try result!.get()
    }

    private static func navigate(_ view: FileTileNSView, to location: DocumentLocation,
                                 beforeCommit: @escaping () throws -> Void = {}) throws -> Bool {
        var completed: Bool?
        view.switchDocument(to: location, beforeCommit: beforeCommit) { completed = $0 }
        try wait { completed != nil }
        return completed!
    }

    private static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !predicate() { throw Failure(description: "timed out awaiting real WebKit bridge") }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
}
