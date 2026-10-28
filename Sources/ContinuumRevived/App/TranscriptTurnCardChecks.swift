import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `.plans/70` S8 — direction C, "turn cards with a live head".
///
/// **Why the fixture comes first.** Three transcript redesigns were received
/// as "looks the same" because the changes went into row internals nobody
/// could see, and a 5-hour session wrote 2,267 lines of transcript UI without
/// ever rendering it (memory: codex-transcript-session-postmortem). So this
/// leg renders a REAL `ManagedAgentTileNSView` the way production fills one —
/// two settled turns through the restore path (`renderRehydratedPreviousSession`
/// over claude's own session-file shape) and a third, live turn through
/// `ingest` — and asserts the rendered outcome: frames, fonts, the strip's
/// words. It also writes `facts.json` and PNGs for a human under
/// `qa-runs/<ts>/transcript-turn-cards/`; the PNGs are never compared.
///
/// **The honesty half** drives the production claude, codex and pi runners
/// against their reactive fakes (`AgentSteeringQAFakes`) and samples the live
/// work strip from Return to settle: it must never be empty while the turn is
/// open, on any harness.
@MainActor
enum TranscriptTurnCardChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func fail(_ message: String) -> Failure { Failure(description: "turn-cards: " + message) }
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw fail(message()) }
    }

    static func run() async throws {
        var summary: [String] = []
        let only = ProcessInfo.processInfo.environment["CONTINUUM_TURN_CARD_SECTIONS"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ name: String) -> Bool { only?.contains(name) ?? true }
        let artifacts = artifactDirectory()
        // The switch defaults to `.rows` until Dylan picks a direction; this leg
        // witnesses the turn-card grammar itself, so it opts in for its run.
        let previousStyle = AgentTranscriptPresentationStyle.current
        AgentTranscriptPresentationStyle.current = .turnCards
        defer { AgentTranscriptPresentationStyle.current = previousStyle }
        // Turn cards are a presentation of the ROW LIST only: the drawn transcript
        // (the default renderer since 0.7.32) has no turn-card grammar and draws
        // rows whatever this switch says, and `.rows` is what ships. So this leg,
        // which witnesses the turn-card grammar itself, pins the list for its run
        // (`ARRAY_TRANSCRIPT_RENDERER=list`, still selectable). The shipped row
        // grammar on the drawn transcript is `--transcript-canvas-check`
        // (`TranscriptCanvasChecks.runCanvasRendererInTheTile`).
        let rendererKey = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previousRenderer = ProcessInfo.processInfo.environment[rendererKey]
        setenv(rendererKey, "list", 1)
        defer { if let previousRenderer { setenv(rendererKey, previousRenderer, 1) } else { unsetenv(rendererKey) } }
        if wants("card") { summary.append(try await checkTheTileReadsAsTurnCards(artifacts: artifacts)) }
        if wants("honesty") { summary.append(try await checkTheStripIsNeverSilent()) }
        if wants("restore-timing") { summary.append(try checkRestoredProviderTimes()) }
        print("TranscriptTurnCardChecks passed: " + summary.joined(separator: "; ")
              + " (artifacts: \(artifacts.path))")
    }

    // MARK: - Fixture

    /// Replay speed and the idle time before the next prompt are neither part
    /// of a completed turn. Exercise the real session reader and tile renderer.
    private static func checkRestoredProviderTimes() throws -> String {
        let fixtures: [(String, [String])] = [
            ("claude", [
                #"{"timestamp":"2026-10-20T10:00:00.000Z","type":"user","message":{"content":"Run the slow check"}}"#,
                #"{"timestamp":"2026-10-20T10:01:00.000Z","type":"assistant","message":{"content":[{"type":"tool_use","id":"slow","name":"Bash","input":{"command":"python slow.py"}}]}}"#,
                #"{"timestamp":"2026-10-20T10:09:00.000Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"slow","content":"done"}]}}"#,
                #"{"timestamp":"2026-10-20T10:10:00.000Z","type":"assistant","message":{"content":[{"type":"text","text":"Finished"}]}}"#,
                #"{"timestamp":"2026-10-20T11:00:00.000Z","type":"user","message":{"content":"Next task"}}"#,
            ]),
            ("pi", [
                #"{"timestamp":"2026-10-20T10:00:00.000Z","type":"message","message":{"role":"user","content":"Run the slow check"}}"#,
                #"{"timestamp":"2026-10-20T10:01:00.000Z","type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"slow","name":"bash","arguments":{"command":"python slow.py"}}]}}"#,
                #"{"timestamp":"2026-10-20T10:09:00.000Z","type":"message","message":{"role":"toolResult","toolCallId":"slow","content":[{"type":"text","text":"done"}]}}"#,
                #"{"timestamp":"2026-10-20T10:10:00.000Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Finished"}]}}"#,
                #"{"timestamp":"2026-10-20T11:00:00.000Z","type":"message","message":{"role":"user","content":"Next task"}}"#,
            ]),
            ("codex", [
                #"{"timestamp":"2026-10-20T10:00:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"text":"Run the slow check"}]}}}"#,
                #"{"timestamp":"2026-10-20T10:01:00.000Z","type":"response_item","payload":{"type":"function_call","call_id":"slow","name":"exec_command","arguments":"{}"}}"#,
                #"{"timestamp":"2026-10-20T10:09:00.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"slow","output":"done"}}"#,
                #"{"timestamp":"2026-10-20T10:10:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","content":[{"text":"Finished"}]}}}"#,
                #"{"timestamp":"2026-10-20T11:00:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"text":"Next task"}]}}}"#,
            ]),
        ]
        let expectedStart = Date(timeIntervalSince1970: 1_792_490_400)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support")),
            makeRunner: { _ in ScriptedAgentRunner(script: []) },
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts")))
        for (provider, lines) in fixtures {
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "restore-timing",
                frame: TileFrame(x: 0, y: 0, width: 640, height: 520),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            let restored: RehydratedTranscript = switch provider {
            case "pi": PiSessionTranscriptReader.parse(lines: lines, threadId: tile.qaThreadIdForChecks)
            case "codex": CodexSessionTranscriptReader.parse(lines: lines, threadId: tile.qaThreadIdForChecks)
            default: ClaudeSessionTranscriptReader.parse(lines: lines, threadId: tile.qaThreadIdForChecks)
            }
            // The supervisor owns the snapshot a reopened tile installs. Its
            // outside-turn replay must preserve the same clocks as a live tile.
            for seeded in [false, true] {
                let id = supervisor.spawn(role: nil, prompt: nil, cwd: root,
                                          model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
                if seeded { supervisor.seedRehydratedTranscript(restored, for: id) }
                supervisor.appendOutsideTurns(restored, boundaryText: "In Terminal", symbolName: nil, for: id)
                let snapshot = supervisor.transcriptAttachment(for: id, reboundTo: tile.qaThreadIdForChecks).snapshot
                guard let prompt = snapshot?.document.entries.first(where: { $0.role == .user }) else {
                    throw fail("\(provider): outside history must produce a reopenable snapshot")
                }
                try expect(prompt.createdAt == expectedStart,
                           "\(provider): supervisor replay lost the original prompt time (seeded: \(seeded))")
                let following = snapshot!.document.entries.drop(while: { $0.id != prompt.id }).dropFirst().prefix(while: { $0.role != .user })
                try expect(following.compactMap(\.finishedAt).max() == expectedStart.addingTimeInterval(600),
                           "\(provider): supervisor replay lost the ten-minute turn duration (seeded: \(seeded))")
            }
            tile.renderRehydratedPreviousSession(restored)
            let entries = tile.qaDocumentForChecks.entries
            guard let prompt = entries.first(where: { $0.role == .user }) else { throw fail("\(provider): missing restored prompt") }
            try expect(prompt.createdAt == expectedStart,
                       "\(provider): restored prompt uses replay time \(String(describing: prompt.createdAt)) instead of its original time")
            let beforeNextPrompt = Array(entries.drop(while: { $0.id != prompt.id }).dropFirst().prefix(while: { $0.role != .user }))
            let end = beforeNextPrompt.compactMap(\.finishedAt).max()
            try expect(end == expectedStart.addingTimeInterval(600),
                       "\(provider): restored ten-minute turn ended at \(String(describing: end)); replay speed and the next prompt's hour of idle time must not change its span")
            settle(tile)
            let summaries = tile.qaTranscriptForChecks?.qaTurnCardFoldedModelsForChecks.map(\.outcomeText) ?? []
            try expect(summaries.contains(where: { $0.contains("10m") }),
                       "\(provider): the restored work summary must show ten minutes, got \(summaries)")
        }
        return "restored provider timestamps preserve a ten-minute shell turn and exclude the following idle gap"
    }

    private static func artifactDirectory() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = URL(fileURLWithPath: "qa-runs/\(formatter.string(from: Date()))/transcript-turn-cards",
                      isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func user(_ text: String) -> String {
        line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    private static func assistant(_ blocks: [[String: Any]]) -> String {
        line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": blocks]])
    }

    private static func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private static func toolResult(_ id: String, failed: Bool = false) -> String {
        line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [
            ["tool_use_id": id, "type": "tool_result", "is_error": failed, "content": "ok"],
        ]]])
    }

    /// Two settled turns in claude's real session-file shape: a long one
    /// (thinking, a search, a read, an edit, a build) and a short one (an edit).
    static func settledSessionLines() -> [String] {
        [
            user("Add a context-window meter to the claude tile"),
            assistant([
                ["type": "thinking", "thinking": "The meter should read usage from result events, not estimate it."],
                toolUse("toolu_t1_grep", "Grep", ["pattern": "contextWindow"]),
            ]),
            toolResult("toolu_t1_grep"),
            assistant([toolUse("toolu_t1_read", "Read", ["file_path": "/repo/Sources/AgentTile/AgentTileHeaderView.swift"])]),
            toolResult("toolu_t1_read"),
            assistant([toolUse("toolu_t1_edit", "Edit", [
                "file_path": "/repo/Sources/AgentActivity/AgentRadialContextMeterView.swift",
                "old_string": "let ring = 0", "new_string": "let ring = usage\nlet fraction = used / window\nring.update(fraction)",
            ])]),
            toolResult("toolu_t1_edit"),
            assistant([toolUse("toolu_t1_bash", "Bash", ["command": "swift build --product Array"])]),
            toolResult("toolu_t1_bash"),
            assistant([["type": "text", "text":
                "Added a ring that reads usage from result events. It refreshes on every turn and never estimates."]]),
            user("Rename the zone chrome toggle"),
            assistant([toolUse("toolu_t2_edit", "Edit", [
                "file_path": "/repo/Sources/Canvas/ZonePresentation.swift",
                "old_string": "Toggle chrome", "new_string": "Show zone chrome",
            ])]),
            toolResult("toolu_t2_edit"),
            assistant([["type": "text", "text": "Renamed it to Show zone chrome. The menu item and the shortcut both follow."]]),
        ]
    }

    static let livePrompt = "Fix the sidebar spinner reset and stagger the animations so they don't sync"
    static let liveAnswer = "The reset came from `layoutSubtreeIfNeeded` re-adding the layer on hover. Each row "
        + "now derives its phase from a shared clock offset by its agent id, so spinners stay staggered and "
        + "never restart."

    /// A real tile, offscreen, filled the two ways production fills one.
    static func makeThreeTurnTile(size: NSSize) async throws -> (tile: ManagedAgentTileNSView, window: NSWindow) {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "fix-sidebar-flicker",
            frame: TileFrame(x: 0, y: 0, width: Double(size.width), height: Double(size.height)),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        guard let transcript = tile.qaTranscriptForChecks else { throw fail("the tile has no transcript") }
        transcript.bindToolDetailAgent(AgentID(rawValue: UUID()))
        tile.renderRehydratedPreviousSession(ClaudeSessionTranscriptReader.parse(
            lines: settledSessionLines(), threadId: tile.qaThreadIdForChecks))
        await settleToolDetails(transcript)

        let thread = tile.qaThreadIdForChecks
        tile.appendUserPrompt(livePrompt)
        tile.ingest(.turnStarted(threadId: thread, turnId: "live"))
        tile.ingest(.itemStarted(threadId: thread, itemId: "live-search", kind: .commandExecution,
                                 title: "rg startAnimating Sources/"))
        tile.ingest(.itemCompleted(threadId: thread, itemId: "live-search", kind: .commandExecution, status: .completed))
        tile.ingest(.itemStarted(threadId: thread, itemId: "live-read", kind: .mcpToolCall,
                                 title: "Read AgentSidebarRowView.swift"))
        tile.ingest(.itemCompleted(threadId: thread, itemId: "live-read", kind: .mcpToolCall, status: .completed))
        tile.ingest(.itemStarted(threadId: thread, itemId: "live-edit", kind: .fileChange,
                                 title: "Edit DualPlaneGyroIndicatorView.swift"))
        tile.ingest(.itemCompleted(threadId: thread, itemId: "live-edit", kind: .fileChange, status: .completed))
        tile.ingest(.contentDelta(threadId: thread, turnId: "live", streamKind: .assistant, delta: liveAnswer))
        tile.ingest(.itemStarted(threadId: thread, itemId: "live-build", kind: .commandExecution,
                                 title: "swift build --product Array"))
        tile.qaFlushStreamingMarkupForChecks()
        await settleToolDetails(transcript)
        settle(tile)
        return (tile, window)
    }

    private static func settleToolDetails(_ transcript: AgentTranscriptListView) async {
        for _ in 0..<6 {
            await transcript.qaWaitForToolDetailRefresh()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        transcript.flushPendingVisualUpdate()
    }

    private static func settle(_ tile: ManagedAgentTileNSView) {
        tile.qaTranscriptForChecks?.flushPendingVisualUpdate()
        tile.window?.layoutIfNeeded()
        tile.needsLayout = true
        tile.layoutSubtreeIfNeeded()
        if let transcript = tile.qaTranscriptForChecks {
            transcript.needsLayout = true
            transcript.layoutSubtreeIfNeeded()
            transcript.collectionView.layoutSubtreeIfNeeded()
            transcript.layoutSubtreeIfNeeded()
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func writePNG(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - 1. The tile reads as turn cards

    static func checkTheTileReadsAsTurnCards(artifacts: URL) async throws -> String {
        var report: [String] = []
        var facts: [[String: Any]] = []
        for width in [640.0, 900.0, 360.0] {
            let size = NSSize(width: width, height: 520)
            let (tile, window) = try await makeThreeTurnTile(size: size)
            defer { window.orderOut(nil) }
            guard let transcript = tile.qaTranscriptForChecks else { throw fail("no transcript") }
            let label = "\(Int(width))"

            try expect(transcript.presentationStyle == .turnCards,
                       "\(label): the production tile does not render turn cards (style \(transcript.presentationStyle))")
            if let mismatch = transcript.qaClusterProjectionMismatch() {
                throw fail("\(label): display projection disagrees with the rows: \(mismatch)")
            }
            let items = transcript.qaTurnCardItemsForChecks
            let scopes = items.map { $0.scope }
            // 1 · Shape: two folded turns, then the live card's four parts.
            let folded = items.filter { $0.scope == .foldedTurn }
            try expect(folded.count == 2,
                       "\(label): expected the two settled turns folded to one item each, got \(folded.count) "
                       + "(scopes \(scopes.map { $0.map { "\($0)" } ?? "row" }))")
            guard let askIndex = items.firstIndex(where: { $0.scope == .ask }),
                  let stripIndex = items.firstIndex(where: { $0.scope == .workStrip }) else {
                throw fail("\(label): the live turn has no Ask heading or no work strip (scopes \(scopes))")
            }
            try expect(items.filter { $0.scope == .ask }.count == 1 && items.filter { $0.scope == .workStrip }.count == 1,
                       "\(label): exactly one open card expected (the newest turn)")
            try expect(folded.allSatisfy { fold in items.firstIndex { $0.id == fold.id }! < askIndex },
                       "\(label): a folded turn sits below the live card")
            try expect(stripIndex == askIndex + 1, "\(label): the work strip must sit directly under the Ask")
            let answerItems = items.enumerated().filter { $0.offset > stripIndex && $0.element.role == .answer }
            try expect(!answerItems.isEmpty, "\(label): the live turn shows no answer under its strip")
            guard let outcomeIndex = items.firstIndex(where: { $0.scope == .outcome }) else {
                throw fail("\(label): the live turn changed a file and has no outcome chips")
            }
            try expect(outcomeIndex == items.count - 1, "\(label): the outcome is not the last part of the card")
            try expect(!transcript.qaTailIsVirtualDocumentRow,
                       "\(label): the gyro tail is still a row at the foot of the scroll")

            // 2 · Geometry: one left edge, a reading measure.
            let ask = items[askIndex]
            let answerFrames = answerItems.map(\.element.frame)
            let column = answerFrames.map(\.width).max() ?? 0
            try expect(answerFrames.allSatisfy { abs($0.minX - ask.frame.minX) < 0.5 },
                       "\(label): Ask x=\(ask.frame.minX) and answer x=\(answerFrames.map(\.minX)) differ")
            try expect(column <= 640.5, "\(label): the answer column is \(column)pt, over the 640pt measure")
            // w is the transcript's own width (the tile's body, inside its chrome).
            let transcriptWidth = transcript.collectionView.bounds.width
            let expectedColumn = min(transcriptWidth - 2 * AgentTurnCardMetrics.columnInset, 640)
            try expect(abs(column - expectedColumn) < 1.5,
                       "\(label): the answer column is \(column)pt; min(w - 40, 640) is \(expectedColumn) at w=\(transcriptWidth)")
            // ...and the GLYPHS start on that edge: the Ask's label and the
            // answer's first text view, in the transcript's own coordinates.
            let cards = transcript.qaVisibleTurnCardItemsForChecks
            guard let askView = cards.compactMap(\.askView).first else { throw fail("\(label): the Ask is not on screen") }
            let askTextX = askView.textLabel.convert(askView.textLabel.bounds, to: transcript).minX
            let answerText = descendants(of: transcript.collectionView)
                .compactMap { $0 as? RichInlineTextView }
                .first { $0.string.contains("The reset came from") }
            guard let answerText else { throw fail("\(label): the live answer's text is not on screen") }
            let answerTextX = answerText.convert(answerText.bounds, to: transcript).minX
            // NSTextField draws its glyphs 2pt inside its frame (the cell's
            // padding); an NSTextView draws at its container inset.
            let askGlyphX = askTextX + 2
            let answerGlyphX = answerTextX + answerText.textContainerInset.width
                + (answerText.textContainer?.lineFragmentPadding ?? 0)
            try expect(abs(askGlyphX - answerGlyphX) <= 1.0,
                       "\(label): the Ask's first glyph sits at x=\(askGlyphX) and the answer's at x=\(answerGlyphX)")

            // 3 · Type: the Ask is a heading, not a row.
            let askFont = askView.textLabel.font
            try expect(askFont?.pointSize == 15, "\(label): the Ask is \(askFont?.pointSize ?? 0)pt, not 15pt")
            try expect(askView.textLabel.stringValue.isEmpty == false
                       && askView.textLabel.attributedStringValue.string == livePrompt,
                       "\(label): the Ask reads '\(askView.textLabel.attributedStringValue.string)'")

            // 4 · The live strip says what it is doing, in the present tense.
            guard let strip = cards.compactMap(\.stripView).first else { throw fail("\(label): no strip on screen") }
            try expect(strip.model.tone == .working,
                       "\(label): the live turn's strip reads \(strip.model.tone), not working")
            try expect(!strip.model.text.isEmpty, "\(label): the live strip is empty")
            try expect(strip.textLabel.stringValue == strip.model.text,
                       "\(label): the strip's label '\(strip.textLabel.stringValue)' is not its model")
            try expect(strip.model.ticks.count == 4,
                       "\(label): the barcode has \(strip.model.ticks.count) ticks for 4 steps")
            try expect(strip.qaBarcodeRect.width > 0, "\(label): the barcode was not laid out")
            try expect(strip.model.countText == "4", "\(label): the strip counts \(strip.model.countText ?? "nil")")

            // 5 · Folded turns read as Ask + one line of outcome.
            let foldedModels = transcript.qaTurnCardFoldedModelsForChecks
            try expect(foldedModels.map(\.askText) == ["Add a context-window meter to the claude tile",
                                                      "Rename the zone chrome toggle"],
                       "\(label): folded asks read \(foldedModels.map(\.askText))")
            try expect(foldedModels[0].outcomeText.contains("4 steps") && foldedModels[0].outcomeText.contains("1 file")
                       && foldedModels[0].outcomeText.contains("Added a ring that reads usage from result events."),
                       "\(label): the first folded turn's outcome reads '\(foldedModels[0].outcomeText)'")
            try expect(foldedModels[1].outcomeText.contains("Renamed it to Show zone chrome."),
                       "\(label): the second folded turn lost its answer's first sentence: '\(foldedModels[1].outcomeText)'")

            // 6 · Outcome chips name the change.
            guard let outcome = cards.compactMap(\.outcomeView).first else { throw fail("\(label): no outcome on screen") }
            try expect(outcome.model.chips.map(\.title) == ["Edit DualPlaneGyroIndicatorView.swift"],
                       "\(label): outcome chips read \(outcome.model.chips.map(\.title))")
            try expect(!outcome.qaChipFrames.isEmpty && outcome.qaChipFrames.allSatisfy { $0.maxX <= outcome.bounds.width + 0.5 },
                       "\(label): outcome chips overflow their row")

            if width == 640 {
                writePNG(tile, to: artifacts.appendingPathComponent("tile-640-live.png"))
                try checkOpeningInPlace(transcript, tile: tile, label: label, artifacts: artifacts)
            } else {
                writePNG(tile, to: artifacts.appendingPathComponent("tile-\(label)-live.png"))
            }
            facts.append([
                "width": width,
                "items": items.map { [
                    "id": $0.id.rawValue, "role": $0.role.map { "\($0)" } ?? "-",
                    "scope": $0.scope.map { "\($0)" } ?? "row",
                    "x": $0.frame.minX, "y": $0.frame.minY, "w": $0.frame.width, "h": $0.frame.height,
                ] },
                "strip": strip.model.text,
                "folded": foldedModels.map { ["ask": $0.askText, "outcome": $0.outcomeText] },
                "askGlyphX": askGlyphX, "answerGlyphX": answerGlyphX, "column": column,
            ])
            report.append("\(label)pt: column \(Int(column)), glyph edge \(askGlyphX)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: artifacts.appendingPathComponent("facts.json"))
        }
        return "a real tile reads as two folded turns and one live card (Ask, live strip, answer, chips) at 640/900/360 — "
            + report.joined(separator: ", ")
    }

    /// Opening a folded turn and the work log happen IN PLACE, through the real
    /// click paths, and fold back.
    private static func checkOpeningInPlace(
        _ transcript: AgentTranscriptListView, tile: ManagedAgentTileNSView, label: String, artifacts: URL
    ) throws {
        // The work log.
        guard let strip = transcript.qaVisibleTurnCardItemsForChecks.compactMap(\.stripView).first else {
            throw fail("\(label): no strip to open")
        }
        _ = strip.accessibilityPerformPress()
        settle(tile)
        var items = transcript.qaTurnCardItemsForChecks
        guard let stripIndex = items.firstIndex(where: { $0.scope == .workStrip }) else { throw fail("strip vanished") }
        let log = items.dropFirst(stripIndex + 1).prefix { $0.role == .log }
        try expect(log.count >= 3, "\(label): the opened work log shows \(log.count) rows under the strip")
        try expect(log.allSatisfy { abs($0.frame.minX - items[stripIndex].frame.minX) < 0.5 },
                   "\(label): work-log rows do not share the card's left edge")
        if let mismatch = transcript.qaClusterProjectionMismatch() { throw fail("\(label) log open: \(mismatch)") }
        writePNG(tile, to: artifacts.appendingPathComponent("tile-640-log-open.png"))
        guard let reopened = transcript.qaVisibleTurnCardItemsForChecks.compactMap(\.stripView).first else {
            throw fail("\(label): the strip left the screen when its log opened")
        }
        try expect(reopened.model.isExpanded, "\(label): the strip does not say its log is open")
        _ = reopened.accessibilityPerformPress()
        settle(tile)

        // A folded turn opens to its full card in place.
        transcript.jumpToLatest()
        transcript.scrollView.contentView.scroll(to: .zero)
        settle(tile)
        guard let fold = transcript.qaVisibleTurnCardItemsForChecks.compactMap(\.foldedView).first else {
            throw fail("\(label): no folded turn on screen at the top of the transcript")
        }
        _ = fold.accessibilityPerformPress()
        settle(tile)
        items = transcript.qaTurnCardItemsForChecks
        try expect(items.filter { $0.scope == .foldedTurn }.count == 1,
                   "\(label): opening a folded turn did not open exactly that turn")
        try expect(items.filter { $0.scope == .ask }.count == 2,
                   "\(label): the opened turn has no Ask heading")
        if let mismatch = transcript.qaClusterProjectionMismatch() { throw fail("\(label) fold open: \(mismatch)") }
        writePNG(tile, to: artifacts.appendingPathComponent("tile-640-turn-open.png"))
        // And folds back from its Ask.
        guard let openedAsk = transcript.qaVisibleTurnCardItemsForChecks.compactMap(\.askView)
            .first(where: { $0.model.canFold }) else {
            throw fail("\(label): the opened turn's Ask offers no way to fold it again")
        }
        openedAsk.onFold?()
        settle(tile)
        try expect(transcript.qaTurnCardItemsForChecks.filter { $0.scope == .foldedTurn }.count == 2,
                   "\(label): folding the opened turn did not fold it")
    }

    // MARK: - 2. The strip is never silent while a turn is open

    static func checkTheStripIsNeverSilent() async throws -> String {
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let originalCodexTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
        setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
        defer {
            setenv("PATH", originalPath, 1)
            if let originalCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalCodexTransport, 1) }
            else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
        }
        var lines: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try AgentPresenceChecks.Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            guard let transcript = bench.tile.qaTranscriptForChecks else { throw fail("\(kind): no transcript") }
            let completedBefore = bench.turnCompletedCount
            try bench.pressReturn("DELAYSTART TOOL turn cards \(kind)")
            var samples = 0
            var empty: [String] = []
            var phases: [String] = []
            var texts: [String] = []
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let presence = bench.tile.currentPresence
                let model = transcript.qaNewestWorkStripModelForChecks
                let phase: String = {
                    switch presence.phase {
                    case .idle: return "idle"
                    case .starting: return "starting"
                    case .thinking: return "thinking"
                    case .tool: return "tool"
                    case .writing: return "writing"
                    case .settled: return "settled"
                    case .failed: return "failed"
                    }
                }()
                if phases.last != phase { phases.append(phase) }
                if presence.isLive {
                    samples += 1
                    if let model, model.tone == .working, !model.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        if texts.last != model.text { texts.append(model.text) }
                    } else {
                        empty.append("\(phase): \(model.map { "\($0.tone) '\($0.text)'" } ?? "no strip")")
                    }
                }
                if bench.turnCompletedCount > completedBefore, presence.phase.isTerminal { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try expect(bench.turnCompletedCount > completedBefore, "\(kind): the turn never completed")
            try expect(empty.isEmpty, "\(kind): the work strip went silent while the turn was open: \(empty.prefix(4))")
            try expect(samples >= 10, "\(kind): only \(samples) live samples — the turn was not observed")
            try expect(phases.contains("starting") && phases.contains("tool"),
                       "\(kind): the sample never crossed starting and tool (\(phases))")
            // Settled, it says what the turn cost.
            try await AgentPresenceChecks.eventually("\(kind): the strip never settled to Worked") {
                transcript.qaNewestWorkStripModelForChecks?.tone == .done
                    && transcript.qaNewestWorkStripModelForChecks?.text.hasPrefix("Worked") == true
            }
            lines.append("\(kind) \(samples) samples over \(phases.joined(separator: "→"))")
        }
        return "the live strip said something on every sample from Return to settle — " + lines.joined(separator: ", ")
    }
}
