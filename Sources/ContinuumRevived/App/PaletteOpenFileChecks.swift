import AppKit
import ContinuumRevivedCore

/// ⌘K → Open file, driven through the production wiring: the app's own palette opener,
/// real key events, the real file index, the agent-made log the supervisor feeds, and the
/// one app-level open (`openProjectFile`). A harness cannot make this pass while the
/// feature is broken: the assertions read the canvas and the palette's own state.
@MainActor
enum PaletteOpenFileChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Real key events through the window, the path a keyboard takes into the field editor.
    private static func typeThroughEvents(_ text: String, in window: NSWindow) throws {
        for ch in text {
            let s = String(ch)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                               isARepeat: false, keyCode: 0) else { throw Failure(description: "could not build a key event") }
            window.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Optional: CONTINUUM_PALETTE_SHOTS=<dir> saves the real panel's pixels for a human to look at.
    private static func shot(_ palette: LaunchProfilePalette, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CONTINUUM_PALETTE_SHOTS"], let view = palette.panelViewForQA else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func pump(_ palette: LaunchProfilePalette, until condition: () -> Bool, seconds: TimeInterval = 8) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw Failure(description: "timed out waiting for the palette; query=\(palette.searchTextForQA) sections=\(palette.sectionTitlesForQA) rows=\(palette.fileRowsForQA.map(\.path))") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func run() throws {
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let delegate = f.delegate
        // `openProfilePalette` needs a window; a check must never take the screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = f.canvas
        delegate.qaAttachWindowForOfflineCheck(window)

        // Files for the step to find: a one-off an agent "made", and a plain project file.
        let outputs = f.pbRoot.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try Data("<h1>report</h1>".utf8).write(to: outputs.appendingPathComponent("q3-report.html"))
        let docs = f.pbRoot.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("handbook\n".utf8).write(to: docs.appendingPathComponent("handbook.txt"))
        let strip = outputs.appendingPathComponent("strip", isDirectory: true)
        try FileManager.default.createDirectory(at: strip, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: strip.appendingPathComponent("zbadge.svg"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: outputs.appendingPathComponent("zshot.png"))
        for n in 1...5 { try Data("x\n".utf8).write(to: docs.appendingPathComponent("zebrafile-\(n).txt")) }
        // The shape of the 0.7.63 miss: an uppercase file four folders down, among a few thousand.
        let deep = f.pbRoot.appendingPathComponent("alignment-2026-10/mapping-process/whit-compare", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("kevin\n".utf8).write(to: deep.appendingPathComponent("KEVIN-CONTEXT.md"))
        for d in 0..<30 {
            let dir = f.pbRoot.appendingPathComponent("bulk/part-\(d)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in 0..<100 { try Data().write(to: dir.appendingPathComponent("note-\(n).md")) }
        }
        delegate.qaAgentSupervisor.agentMadeFiles.record(
            [.init(action: .write, path: "outputs/q3-report.html")],
            agent: f.agentId.rawValue, checkoutRoot: f.pbRoot.path)

        // An agent makes a file with Bash (mkdir + echo >), through the supervisor's own
        // observation route: it must be offered exactly as a Write would be.
        try Data("<p>made with bash</p>".utf8).write(to: outputs.appendingPathComponent("bash-made.html"))
        delegate.qaAgentSupervisor.qaObserveSharedTranscript(
            .toolDetail(itemId: "bash-1", detail: AgentToolDetailObservation(
                phase: .ended, toolName: "Bash",
                fields: [(key: AgentToolDetailObservation.shellCommandKey, value: "mkdir -p outputs && echo '<p>made with bash</p>' > outputs/bash-made.html")],
                observedAt: Date())),
            for: f.agentId)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("palette-open-file-check-\(UUID().uuidString)"))
        delegate.paletteFilePasteboard = pasteboard
        var revealed: [URL] = []
        delegate.paletteRevealInFinder = { revealed += $0 }

        // The user is on the agent's tile in Pb's zone and presses ⌘K.
        f.runtime.setActiveZone(f.zoneB, reason: .click)
        try expect(f.focusBroker.enterScope(.tile(f.agentTileB), reason: .userClick), "precondition: focusing the agent tile")
        guard let palette = delegate.qaProfilePaletteAfterOpening() else { throw Failure(description: "⌘K did not open the palette") }
        try expect(palette.isVisible, "the palette must be visible after ⌘K")

        // Root: type the action's name, Return enters the file step.
        palette.typeForQA("open file")
        try expect(palette.selectedDisplayNameForQA == "Open File...", "root search for 'open file' must select the Open File row, got \(String(describing: palette.selectedDisplayNameForQA))")
        palette.keyForQA(keyCode: 36)
        try expect(palette.isChoosingFileForQA, "Return on Open File must enter the file step, not an open panel")
        try expect(palette.footerTextForQA.contains("⌘Return Reveal in Finder") && palette.footerTextForQA.contains("⌥Return Copy file"),
                   "the step's footer must name its keys, got \(palette.footerTextForQA)")

        // Typing through the real event path (window.sendEvent into the field editor) must
        // leave the caret collapsed: typed text is never drawn on a selection box.
        try typeThroughEvents("han", in: window)
        guard let editor = window.fieldEditor(false, for: nil) as? NSTextView, editor.string == "han" else {
            throw Failure(description: "typing through window.sendEvent did not reach the search field, editor = \(String(describing: (window.firstResponder as? NSTextView)?.string)), responder = \(String(describing: window.firstResponder))")
        }
        try expect(editor.selectedRange().length == 0, "typed text must not be selected, got \(editor.selectedRange())")
        try expect(editor.selectedRange().location == 3, "caret must sit after the typed text, got \(editor.selectedRange())")
        try typeThroughEvents("dbook", in: window)
        try expect(editor.string == "handbook" && editor.selectedRange().length == 0, "continued typing must append, got \(editor.string) \(editor.selectedRange())")
        palette.typeForQA("")

        // Empty query: files agents made lead, with the agent's identity and an age.
        try expect(palette.sectionTitlesForQA.first == "Made by agents", "the first section must be Made by agents, got \(palette.sectionTitlesForQA)")
        try expect(palette.fileRowsForQA.contains { $0.name == "bash-made.html" },
                   "a file an agent made with a Bash redirect must be under Made by agents, rows = \(palette.fileRowsForQA.map(\.path))")
        guard let made = palette.fileRowsForQA.first(where: { $0.name == "q3-report.html" }) else { throw Failure(description: "no row under Made by agents; rows = \(palette.fileRowsForQA.map(\.path))") }
        try expect(made.name == "q3-report.html" && made.folder == "outputs/", "made-by-agents row, got \(made.path)")
        try expect(made.agent?.agentID == f.agentId.rawValue && made.agent?.name.isEmpty == false && made.age != nil,
                   "the row must carry the agent that made it and an age, got \(String(describing: made.agent))")

        // Fuzzy: a short query finds the file through the real index, positions included.
        palette.typeForQA("hanbook")
        try pump(palette) { palette.fileRowsForQA.contains { $0.name == "handbook.txt" } }
        guard let hit = palette.fileRowsForQA.first(where: { $0.name == "handbook.txt" }) else { throw Failure(description: "unreachable") }
        try expect(!hit.matched.isEmpty && hit.absolutePath == docs.appendingPathComponent("handbook.txt").path,
                   "the fuzzy hit must carry match positions and its absolute path, got \(hit)")
        try expect(palette.sectionTitlesForQA == ["Files"], "search results sit under one Files header, got \(palette.sectionTitlesForQA)")

        // A short list must fit its clip view exactly, or a scroller shows with nothing to scroll.
        var heights = palette.listHeightsForQA
        try expect(heights.document <= heights.clip + 0.5, "one-result list overflows its clip view: document \(heights.document) > clip \(heights.clip)")
        // Open file searches every file, images and svg included (the composer's @ does not).
        for (query, expected) in [("zbadge", "zbadge.svg"), ("zshot", "zshot.png")] {
            palette.typeForQA(query)
            try pump(palette) { palette.fileRowsForQA.contains { $0.name == expected } }
            try expect(palette.fileRowsForQA.first { $0.name == expected }?.absolutePath?.hasSuffix(expected) == true, "\(expected) must be found by '\(query)'")
        }
        // The panel follows its rows: 5 results, then 1, then 5 again.
        palette.typeForQA("zebrafile")
        try pump(palette) { palette.fileRowsForQA.filter { $0.name.hasPrefix("zebrafile") }.count == 5 }
        let tall = palette.panelHeightForQA
        shot(palette, "live-5-rows")
        heights = palette.listHeightsForQA
        try expect(heights.document <= heights.clip + 0.5 || tall >= 520, "five-result list overflows: \(heights)")
        palette.typeForQA("hanbook")
        try pump(palette) { palette.fileRowsForQA.map(\.name) == ["handbook.txt"] }
        let short = palette.panelHeightForQA
        shot(palette, "live-1-row")
        heights = palette.listHeightsForQA
        try expect(tall - short >= 2 * 46, "panel must shrink by at least two rows from five results to one, \(tall) -> \(short)")
        try expect(abs(heights.document - heights.clip) <= 0.5, "one-result list must fit its clip exactly (no empty list, no scroller): \(heights)")
        palette.typeForQA("zebrafile")
        try pump(palette) { palette.fileRowsForQA.filter { $0.name.hasPrefix("zebrafile") }.count == 5 }
        try expect(abs(palette.panelHeightForQA - tall) < 0.5, "panel must grow back to \(tall), got \(palette.panelHeightForQA)")
        palette.typeForQA("hanbook")
        try pump(palette) { palette.fileRowsForQA.map(\.name) == ["handbook.txt"] }
        // A file at the project root is filed under the project's name, not "./".
        palette.typeForQA("notes.md")
        try pump(palette) { palette.fileRowsForQA.contains { $0.name == "notes.md" } }
        let rootFile = palette.fileRowsForQA.first { $0.name == "notes.md" }
        try expect(rootFile?.folder == f.pbRoot.lastPathComponent || rootFile?.folder != "./", "a root file's folder line is the project's name, got \(String(describing: rootFile?.folder))")
        heights = palette.listHeightsForQA
        try expect(heights.document <= heights.clip + 0.5, "root-file list overflows its clip view: document \(heights.document) > clip \(heights.clip)")
        // A query nothing matches says so, in the footer's own type.
        palette.typeForQA("qzxjwvk")
        try pump(palette) { palette.fileEmptyTextForQA?.hasPrefix("No files match") == true }
        shot(palette, "live-no-match")
        try expect(palette.fileEmptyTextForQA == "No files match “qzxjwvk”" && palette.fileRowsForQA.isEmpty,
                   "no match must say so, got \(String(describing: palette.fileEmptyTextForQA))")
        palette.typeForQA("hanbook")
        try pump(palette) { palette.fileRowsForQA.contains { $0.name == "handbook.txt" } }
        try expect(palette.fileEmptyTextForQA == nil, "the no-match line goes away when there are results")

        // ⌥Return copies the FILE, not its path.
        palette.keyForQA(keyCode: 36, modifiers: [.option])
        let copied = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        try expect(copied.map(\.path) == [docs.appendingPathComponent("handbook.txt").path], "⌥Return must put the file on the pasteboard, got \(copied)")
        try expect(!palette.isVisible, "the palette closes after a file action")

        // ⌘Return reveals in Finder.
        guard let again = delegate.qaProfilePaletteAfterOpening() else { throw Failure(description: "reopen") }
        again.typeForQA("open file"); again.keyForQA(keyCode: 36)
        again.typeForQA("hanbook")
        again.keyForQA(keyCode: 36, modifiers: [.command])
        try pump(again) { !again.isVisible }
        try expect(revealed.map(\.path) == [docs.appendingPathComponent("handbook.txt").path], "⌘Return must reveal the file, got \(revealed)")

        // Return opens it as a tile BESIDE the agent that was focused, through openProjectFile.
        try expect(f.focusBroker.enterScope(.tile(f.agentTileB), reason: .userClick), "refocus the agent tile")
        let tilesBefore = Set(f.canvas.tilesInWorldFrames(forProjectId: f.projectPb).map(\.id))
        guard let third = delegate.qaProfilePaletteAfterOpening() else { throw Failure(description: "reopen") }
        third.typeForQA("open file"); third.keyForQA(keyCode: 36)
        third.typeForQA("hanbook")
        third.keyForQA(keyCode: 36)
        try pump(third) { !third.isVisible }
        let projectTiles = f.canvas.tilesInWorldFrames(forProjectId: f.projectPb)
        let opened = projectTiles.filter { !tilesBefore.contains($0.id) }
        try expect(opened.count == 1 && opened.first?.kind == .file, "Return must open exactly one file tile, got \(opened.map(\.kind))")
        guard let tile = opened.first, let agentTile = projectTiles.first(where: { $0.id == f.agentTileB }) else { throw Failure(description: "tiles") }
        let a = CGRect(x: agentTile.frame.x, y: agentTile.frame.y, width: agentTile.frame.width, height: agentTile.frame.height)
        let b = CGRect(x: tile.frame.x, y: tile.frame.y, width: tile.frame.width, height: tile.frame.height)
        let gapX = max(0, max(a.minX - b.maxX, b.minX - a.maxX)), gapY = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        try expect(max(gapX, gapY) < 120, "the file tile must sit beside the agent tile; agent=\(a) file=\(b)")
        try expect(!third.isVisible, "the palette closes after Return")

        // Esc steps back to the root, as it does from the model step.
        guard let fourth = delegate.qaProfilePaletteAfterOpening() else { throw Failure(description: "reopen") }
        fourth.typeForQA("open file"); fourth.keyForQA(keyCode: 36)
        fourth.keyForQA(keyCode: 53)
        try expect(!fourth.isChoosingFileForQA && fourth.isVisible, "Esc in the file step goes back to the root, not out of the palette")
        fourth.close()

        // Dylan's 0.7.63 report: "Kevin-context.md" sat on the empty-query placeholder.
        // Every keystroke rescanned the whole project (a fresh cache key per query), and
        // the step said "Type to search" while those scans queued up.
        // The earlier steps' own listings finish first, so only this step's count.
        var settled = delegate.qaPaletteFileIndexScans
        for _ in 0..<50 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if delegate.qaPaletteFileIndexScans == settled { break }
            settled = delegate.qaPaletteFileIndexScans
        }
        let scansBefore = delegate.qaPaletteFileIndexScans
        guard let fifth = delegate.qaProfilePaletteAfterOpening() else { throw Failure(description: "reopen") }
        fifth.typeForQA("open file"); fifth.keyForQA(keyCode: 36)
        fifth.typeForQA("K")
        try expect(fifth.fileEmptyTextForQA == "Searching…" && fifth.fileRowsForQA.isEmpty,
                   "a search in flight must say Searching…, not the empty-query rows or placeholder; got text=\(String(describing: fifth.fileEmptyTextForQA)) rows=\(fifth.fileRowsForQA.map(\.path))")
        shot(fifth, "kevin-searching")
        fifth.typeForQA("")
        try typeThroughEvents("Kevin-context.md", in: window)
        try pump(fifth) { fifth.fileRowsForQA.contains { $0.name == "KEVIN-CONTEXT.md" } }
        shot(fifth, "kevin-found")
        try expect(fifth.fileRowsForQA.first?.path == "alignment-2026-10/mapping-process/whit-compare/KEVIN-CONTEXT.md",
                   "the exact name in another case must rank first, got \(fifth.fileRowsForQA.map(\.path))")
        let scans = delegate.qaPaletteFileIndexScans - scansBefore
        try expect(scans <= 1, "typing a 16-letter query must list the project once, not per keystroke; scans=\(scans)")
        // A whole query arriving at once (a paste) searches without another edit.
        guard let editor = window.fieldEditor(false, for: nil) as? NSTextView else { throw Failure(description: "no field editor") }
        editor.insertText("qzxjwvk-none.md", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try pump(fifth) { fifth.fileEmptyTextForQA?.hasPrefix("No files match") == true }
        shot(fifth, "kevin-no-match")
        editor.insertText("kevin-context.md", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try pump(fifth) { fifth.fileRowsForQA.contains { $0.name == "KEVIN-CONTEXT.md" } }
        try expect(fifth.fileEmptyTextForQA == nil, "results hide the empty line")
    }
}
