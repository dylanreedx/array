#if ARRAY_CHECKS
import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// The Changes card shows the files an agent made through the SHELL and through
/// a codex patch run inside codex's `exec` tool — the two ways Dylan's agents
/// really make files (2026-11-25: 26 of the 28 images and pages agents made
/// outside temp folders in two days came from the shell, and none showed).
///
/// Both fixtures are shaped like his real sessions and go through the real
/// ingestion: a claude session file and a codex rollout, parsed by their
/// readers and restored into a real agent tile, exactly as a relaunch does.
/// The live translators are driven with the same commands after that.
///
/// The fixture files live under the user Caches folder, not the temp folder:
/// a temp folder is scratch, and the rule deliberately skips it.
@MainActor
enum ShellMadeFilesChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    struct Fixture {
        let root: URL
        let claudeLines: [String]
        let codexLines: [String]
        /// What each restore must show, in order of appearance.
        let claudeShown: [URL]
        /// A very bright picture and a long name: the band must stay readable.
        let edgeLines: [String]
        let edgeShown: [URL]
        let claudeHidden: [URL]
        let codexShown: [URL]
        let claudeCommand: String
        let codexCommand: String
    }

    static func run(stillsDirectory: URL? = nil) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try restored(fixture, stillsDirectory: stillsDirectory)
        try live(fixture)
    }

    // MARK: Fixture

    static func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = caches.appendingPathComponent("array-file-strip-qa/\(UUID().uuidString)", isDirectory: true)
        let review = root.appendingPathComponent("review", isDirectory: true)
        let captures = review.appendingPathComponent("captures", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        for directory in [captures, codex] { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }

        // Named by the command but there before it ran: read, not made.
        let oldNotes = review.appendingPathComponent("old-notes.md")
        try Data("# Old notes\n".utf8).write(to: oldNotes)
        let anHourAgo = Date().addingTimeInterval(-3_600)
        try fileManager.setAttributes([.creationDate: anHourAgo, .modificationDate: anHourAgo], ofItemAtPath: oldNotes.path)
        // The picture codex resizes: an input, there long before.
        let source = review.appendingPathComponent("source.png")
        try picture(NSColor.systemGray).write(to: source)
        try fileManager.setAttributes([.creationDate: anHourAgo, .modificationDate: anHourAgo], ofItemAtPath: source.path)
        // Made in the temp folder: scratch, never shown.
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("strip-qa-crop-\(UUID().uuidString).png")

        let start = Date()
        // What the shell made: a screenshot and a heredoc report (claude), a
        // resized picture (codex). Real bytes, born now.
        let shot = captures.appendingPathComponent("now.png")
        try picture(NSColor.systemTeal).write(to: shot)
        try picture(NSColor.systemOrange).write(to: scratch)
        let report = review.appendingPathComponent("fix-round-1.md")
        try Data("# UI review, round 1\n\n## Findings\n\nThe sidebar row loses its hover state after a drag.\n".utf8).write(to: report)
        let small = codex.appendingPathComponent("shot-small.png")
        try picture(NSColor.systemPurple).write(to: small)
        // What a codex patch added, two files in one change.
        let landing = codex.appendingPathComponent("landing.html")
        let landingSource = "<html><body style='margin:0;background:#1f6feb'><h1 style='color:white;font:600 40px -apple-system;padding:24px'>Landing</h1></body></html>\n"
        try Data(landingSource.utf8).write(to: landing)
        let notes = codex.appendingPathComponent("notes.md")
        let notesSource = "# Release notes\n\n- Files made in the shell now show on the Changes card.\n"
        try Data(notesSource.utf8).write(to: notes)
        defer { try? fileManager.removeItem(at: scratch) }
        let end = Date()

        let stamp: (Date) -> String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: $0)
        }
        func json(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }

        // Claude: one Bash call, as his helpers write it.
        let claudeCommand = """
        mkdir -p \(captures.path) && screencapture -x -o \(shot.path) && cat > \(report.path) <<'EOF'
        # UI review, round 1
        EOF
        cat \(oldNotes.path); cp \(scratch.path) \(scratch.deletingLastPathComponent().appendingPathComponent("crop.png").path)
        """
        let cwd = root.path
        let claudeLines = [
            json(["type": "user", "cwd": cwd, "timestamp": stamp(start.addingTimeInterval(-3)),
                  "message": ["role": "user", "content": "Capture the sidebar and write up round one."]]),
            json(["type": "assistant", "cwd": cwd, "timestamp": stamp(start.addingTimeInterval(-1)),
                  "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_shell_made", "name": "Bash",
                     "input": ["command": claudeCommand, "description": "Capture and write the review"]]]]]),
            json(["type": "user", "cwd": cwd, "timestamp": stamp(end.addingTimeInterval(0.5)),
                  "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_shell_made", "content": "# Old notes"]]]]),
            json(["type": "assistant", "cwd": cwd, "timestamp": stamp(end.addingTimeInterval(1)),
                  "message": ["role": "assistant", "content": [["type": "text", "text": "Captured the sidebar and wrote the review."]]]]),
        ]

        // Codex 0.159+: the patch and the command both run inside `exec`, so
        // the rollout's only record of them is the completed items.
        let codexCommand = "sips -Z 800 \(source.path) --out \(small.path)"
        let codexLines = [
            json(["type": "session_meta", "timestamp": stamp(start.addingTimeInterval(-4)), "payload": ["id": "rollout-qa", "cwd": cwd]]),
            json(["type": "event_msg", "timestamp": stamp(start.addingTimeInterval(-3)), "payload": [
                "type": "item_completed", "item": ["type": "UserMessage", "id": "u1",
                                                   "content": [["type": "text", "text": "Add the landing page and notes, and a small shot."]]]]]),
            json(["type": "response_item", "timestamp": stamp(start.addingTimeInterval(-1)), "payload": [
                "type": "custom_tool_call", "call_id": "call_exec_1", "name": "exec", "status": "completed",
                "input": "await tools.apply_patch(...)"]]),
            json(["type": "event_msg", "timestamp": stamp(end), "payload": [
                "type": "item_completed", "item": ["type": "FileChange", "id": "exec-patch-1", "status": "completed",
                                                   "changes": [landing.path: ["type": "add", "content": landingSource],
                                                               notes.path: ["type": "add", "content": notesSource]]]]]),
            json(["type": "event_msg", "timestamp": stamp(end.addingTimeInterval(0.2)), "payload": [
                "type": "item_completed", "item": ["type": "CommandExecution", "id": "exec-cmd-1", "status": "completed",
                                                   "command": ["/bin/zsh", "-lc", codexCommand], "cwd": "file://\(cwd)"]]]),
            json(["type": "response_item", "timestamp": stamp(end.addingTimeInterval(0.4)), "payload": [
                "type": "custom_tool_call_output", "call_id": "call_exec_1", "output": "ok"]]),
            json(["type": "event_msg", "timestamp": stamp(end.addingTimeInterval(1)), "payload": [
                "type": "item_completed", "item": ["type": "AgentMessage", "id": "a1",
                                                   "content": [["type": "Text", "text": "The page, the notes and the small shot are in."]]]]]),
        ]
        // A white-hot capture and a long-named recap, made in one heredoc turn.
        let edgeStart = Date()
        let bright = captures.appendingPathComponent("very-bright-launch-hero-flash.png")
        try picture(NSColor(calibratedRed: 1, green: 1, blue: 0.94, alpha: 1)).write(to: bright)
        let night = captures.appendingPathComponent("night-mode-dashboard.png")
        try picture(NSColor(calibratedWhite: 0.04, alpha: 1)).write(to: night)
        let recap = review.appendingPathComponent("ufc-qatar-press-conference-and-weigh-in-recap.md")
        try Data("# UFC Qatar: press conference and weigh-in recap\n\nEvery fighter made weight on the first attempt.\n".utf8).write(to: recap)
        let edgeEnd = Date()
        let edgeCommand = "screencapture -x \(bright.path) && screencapture -x \(night.path) && cat > \(recap.path) <<'EOF'\n# UFC Qatar recap\nEOF"
        let edgeLines = [
            json(["type": "user", "cwd": cwd, "timestamp": stamp(edgeStart.addingTimeInterval(-3)),
                  "message": ["role": "user", "content": "Grab the hero and the night dashboard, and write the recap."]]),
            json(["type": "assistant", "cwd": cwd, "timestamp": stamp(edgeStart.addingTimeInterval(-1)),
                  "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_edge", "name": "Bash",
                     "input": ["command": edgeCommand, "description": "Capture the hero and write the recap"]]]]]),
            json(["type": "user", "cwd": cwd, "timestamp": stamp(edgeEnd.addingTimeInterval(0.5)),
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_edge", "content": "saved"]]]]),
            json(["type": "assistant", "cwd": cwd, "timestamp": stamp(edgeEnd.addingTimeInterval(1)),
                  "message": ["role": "assistant", "content": [["type": "text", "text": "The hero and the recap are saved."]]]]),
        ]
        return Fixture(root: root, claudeLines: claudeLines, codexLines: codexLines,
                       claudeShown: [shot, report], edgeLines: edgeLines, edgeShown: [bright, night, recap],
                       claudeHidden: [oldNotes, scratch],
                       codexShown: [landing, notes, small],
                       claudeCommand: claudeCommand, codexCommand: codexCommand)
    }

    static func picture(_ color: NSColor) throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 300, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill(); NSRect(x: 0, y: 0, width: 480, height: 300).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: 32, y: 196, width: 240, height: 28).fill(); NSRect(x: 32, y: 150, width: 380, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
        return data
    }

    // MARK: Restore through the real tile

    static func restored(_ fixture: Fixture, stillsDirectory: URL?) throws {
        // The header counts lines of text only: a picture has none to count, so it
        // never reads "· 1 file without counts".
        let cases: [(String, RehydratedTranscript, [URL], [URL], String, String)] = [
            ("edge bright", ClaudeSessionTranscriptReader.parse(lines: fixture.edgeLines, threadId: "shell-made-edge"),
             fixture.edgeShown, [], "The hero and the recap are saved.", "3 files · +3"),
            ("claude Bash", ClaudeSessionTranscriptReader.parse(lines: fixture.claudeLines, threadId: "shell-made-claude"),
             fixture.claudeShown, fixture.claudeHidden, "Captured the sidebar and wrote the review.", "2 files · +5"),
            ("codex exec", CodexSessionTranscriptReader.parse(lines: fixture.codexLines, threadId: "shell-made-codex"),
             fixture.codexShown, [], "The page, the notes and the small shot are in.", "3 files · +4"),
        ]
        for (label, transcript, shown, hidden, closing, header) in cases {
            for dark in stillsDirectory == nil ? [true] : [false, true] {
                let tile = ManagedAgentTileNSView(tile: Tile(
                    id: UUID(), kind: .managedAgent, title: label, frame: TileFrame(x: 0, y: 0, width: 640, height: 620),
                    zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
                tile.frame = NSRect(x: 0, y: 0, width: 640, height: 620)
                let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = tile
                window.orderFrontOffscreenForChecks()
                defer { window.orderOut(nil) }
                guard let canvas = tile.qaCanvasTranscript else { throw Failure(description: "\(label): the tile has no drawn transcript") }
                canvas.bindToolDetailAgent(AgentID(rawValue: UUID()))
                tile.renderRehydratedPreviousSession(transcript)
                let settle = Date().addingTimeInterval(20)
                repeat {
                    tile.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                } while (canvas.qaFileThumbs.count < shown.count || canvas.qaFileThumbs.contains { !$0.hasPicture }) && Date() < settle
                // Once made, the pictures stay. A warm preview cache (the checks
                // before this one made dozens) used to evict what a card showed,
                // so its thumbnails churned through regeneration and never
                // settled. Settled = no picture made for half a second.
                var generated = FilePreviewStore.shared.generationCount
                var quietSince = Date()
                let quietLimit = Date().addingTimeInterval(8)
                while Date() < quietLimit, Date().timeIntervalSince(quietSince) < 0.5 {
                    tile.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    if FilePreviewStore.shared.generationCount != generated {
                        generated = FilePreviewStore.shared.generationCount
                        quietSince = Date()
                    }
                }
                try expect(Date().timeIntervalSince(quietSince) >= 0.5 && canvas.qaFileThumbs.allSatisfy(\.hasPicture),
                           "\(label): the card's pictures must settle and stay; still regenerating (\(FilePreviewStore.shared.generationCount) made, \(FilePreviewStore.shared.failureCount) failed), pictures \(canvas.qaFileThumbs.map(\.hasPicture))")
                try expect(canvas.qaLaidOutText.contains(closing),
                           "\(label): the restored text must draw; drew '\(canvas.qaLaidOutText.prefix(200))'")
                let cards = canvas.qaChangesCards
                let files = cards.flatMap(\.files)
                let described = cards.map { $0.files.map { "\($0.displayName)[\($0.action.map { "\($0)" } ?? "-")]" } }
                try expect(cards.count == 1, "\(label): the turn's made files must make ONE Changes card, got \(described)")
                for url in shown {
                    try expect(files.contains { $0.fileURL?.standardizedFileURL.path == url.standardizedFileURL.path },
                               "\(label): \(url.lastPathComponent) was made by the agent and must be on the card with its real location, got \(described)")
                }
                for url in hidden {
                    try expect(!files.contains { $0.displayName.contains(url.lastPathComponent) },
                               "\(label): \(url.lastPathComponent) must not be on the card (read, or temp scratch), got \(described)")
                }
                let drawnHeader = AgentDiffSummaryView.countsText(cards[0].files)
                try expect(drawnHeader == header, "\(label): the card header must read '\(header)', got '\(drawnHeader)'")
                // The name and its facts live in each picture's frosted band, so
                // the strip carries no caption row beneath the pictures.
                try expect(AgentDiffSummaryView.stripHeight(cards[0].files, zoom: .default)
                               == AgentFileStripView.thumbHeight(zoom: .default) + CGFloat(AgentPageZoom.default.scaled(Space.s)),
                           "\(label): the strip must be the pictures alone, with no caption row under them")
                let bands = canvas.qaFileThumbText
                for url in shown {
                    guard let band = bands.first(where: { $0.name == url.lastPathComponent }) else {
                        throw Failure(description: "\(label): \(url.lastPathComponent) must be named inside its picture, got \(bands.map(\.name))")
                    }
                    let kind = AgentFileStripView.kindName(url)
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    try expect(band.facts.hasPrefix(kind + " · ") && band.facts.contains(size),
                               "\(label): \(url.lastPathComponent)'s band must read its kind and size, got '\(band.facts)'")
                    if url.pathExtension == "png" {
                        try expect(band.facts.contains("480×300"), "\(label): a picture's band must read its pixel size, got '\(band.facts)'")
                    }
                }
                try expect(canvas.qaFileThumbs.count == shown.count && canvas.qaFileThumbs.allSatisfy(\.hasPicture),
                           "\(label): every made file must have a real thumbnail, got \(canvas.qaFileThumbs.count) of \(shown.count) (pictures \(canvas.qaFileThumbs.filter(\.hasPicture).count))")
                if let stillsDirectory {
                    try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
                    let name = "\(label.split(separator: " ").first ?? "card")-\(dark ? "dark" : "light").png"
                    guard let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else { throw Failure(description: "no still") }
                    tile.cacheDisplay(in: tile.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: stillsDirectory.appendingPathComponent(name))
                }
            }
            print("shell-made files (\(label) restore): one Changes card with \(shown.count) real thumbnails; read and temp files stay off it")
        }
    }

    // MARK: The live translators

    static func live(_ fixture: Fixture) throws {
        final class Seen: @unchecked Sendable { var observations: [AgentRuntimeObservation] = [] }
        func madeItem(_ events: [AgentRuntimeEvent], _ seen: Seen, shellID: String) -> (started: Bool, files: [URL]) {
            let id = AgentShellMadeFiles.itemID(forShellItem: shellID)
            let started = events.contains {
                if case let .itemStarted(_, itemId, kind, _) = $0 { return itemId == id && kind == .fileChange }
                return false
            }
            let files = seen.observations.flatMap { observation -> [URL] in
                if case let .toolDetail(itemId, detail) = observation, itemId == id { return detail.affectedFiles }
                return []
            }
            return (started, files)
        }
        func paths(_ urls: [URL]) -> Set<String> { Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }) }

        // claude: the tool_use frame, then its result, with the files touched in between.
        let claudeSeen = Seen()
        var claude = ClaudeEventTranslator(workingDirectory: fixture.root)
        claude.onRuntimeObservation = { claudeSeen.observations.append($0) }
        let use: [String: Any] = ["type": "assistant", "message": ["id": "msg_live", "role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_live_shell", "name": "Bash", "input": ["command": fixture.claudeCommand]]]]]
        let result: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_live_shell", "content": "ok"]]]]
        var claudeEvents = claude.translate(line: String(data: try JSONSerialization.data(withJSONObject: use), encoding: .utf8)!)
        for url in fixture.claudeShown { try touchAsNew(url) }
        claudeEvents += claude.translate(line: String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        let claudeMade = madeItem(claudeEvents, claudeSeen, shellID: "toolu_live_shell")
        try expect(claudeMade.started, "live claude: a Bash call that made files must open a file-change item")
        try expect(paths(claudeMade.files) == paths(fixture.claudeShown),
                   "live claude: the made files must be \(fixture.claudeShown.map(\.lastPathComponent)), got \(claudeMade.files.map(\.lastPathComponent))")

        // codex app-server: a command, and a patch adding two files.
        let codexSeen = Seen()
        var codex = CodexAppServerEventTranslator(workingDirectory: fixture.root)
        codex.onRuntimeObservation = { codexSeen.observations.append($0) }
        func line(_ method: String, _ params: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["method": method, "params": params]), encoding: .utf8)!
        }
        let command: [String: Any] = ["type": "commandExecution", "id": "cmd-live", "command": fixture.codexCommand,
                                      "cwd": fixture.root.path, "exitCode": 0]
        var codexEvents = codex.translate(line: try line("item/started", ["threadId": "t", "turnId": "u", "item": command]))
        try touchAsNew(fixture.codexShown[2])
        codexEvents += codex.translate(line: try line("item/completed", ["threadId": "t", "turnId": "u", "item": command]))
        let codexMade = madeItem(codexEvents, codexSeen, shellID: "cmd-live")
        try expect(codexMade.started && paths(codexMade.files) == paths([fixture.codexShown[2]]),
                   "live codex: the command's made file must open a file-change item, got \(codexMade.files.map(\.lastPathComponent))")
        let patch: [String: Any] = ["type": "fileChange", "id": "patch-live", "status": "inProgress", "changes": [
            ["path": fixture.codexShown[0].path, "kind": ["type": "add"]],
            ["path": fixture.codexShown[1].path, "kind": ["type": "add"]]]]
        _ = codex.translate(line: try line("item/started", ["threadId": "t", "turnId": "u", "item": patch]))
        let patchFiles = codexSeen.observations.flatMap { observation -> [URL] in
            if case let .toolDetail(itemId, detail) = observation, itemId == "patch-live" { return detail.affectedFiles }
            return []
        }
        try expect(paths(patchFiles) == paths(Array(fixture.codexShown.prefix(2))),
                   "live codex: every file of a two-file patch must carry its location, got \(patchFiles.map(\.lastPathComponent))")
        print("shell-made files (live): claude Bash and codex commands open a file-change item; a codex patch carries every file")
    }

    /// The live translators read the clock at the frames: re-make the file now.
    static func touchAsNew(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
    }
}
#endif
