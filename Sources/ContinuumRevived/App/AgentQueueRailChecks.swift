import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Darwin
import Foundation

// T5b (`.plans/69`, D1/D2) — the steering/queue rail, driven end to end. Each
// scenario binds a REAL `ManagedAgentTileNSView` to an `AgentSupervisor` with
// the production runner factory, against `AgentSteeringQAFakes` on PATH (the
// same fakes `runAgentSteeringChecks` uses), in an offscreen window. Every
// action goes through the installed composer: its key path, the rail's own
// buttons and mouse handlers, and the tile's wiring to the supervisor — and
// every outcome is read back from the supervisor and the fake CLI, not from
// the view's own copy. Runs as part of `--agent-compaction-ui-check`.
//
// Set CONTINUUM_QUEUE_RAIL_SHOTS to a directory to also save offscreen
// screenshots (light and dark; typed while busy on each harness; working with a
// steer and three queued; one row hovered; paused).
@MainActor
func runAgentQueueRailChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: "queue rail: " + message()) }
    }
    func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 8,
                    _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "queue rail: " + message())
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let originalCodexTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
    setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
    defer {
        setenv("PATH", originalPath, 1)
        if let originalCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalCodexTransport, 1) }
        else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
    }
    let shotsDirectory = ProcessInfo.processInfo.environment["CONTINUUM_QUEUE_RAIL_SHOTS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    let steeringTitle = "Steering \u{00B7} after next tool call"
    let queuedTitle = "Queued \u{00B7} after this turn"

    for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-queue-rail-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(kind, in: bin)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        setenv("PATH", "\(bin.path):\(originalPath)", 1)
        let recoveryStore = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: root),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: recoveryStore)
        supervisor.interruptGrace = 3
        let (harness, model): (AgentHarness, String) = switch kind {
        case .claude: (.claudeCode, "anthropic/claude-haiku-4-5-20251001")
        case .codex: (.codex, "openai-codex/gpt-5.6-sol")
        case .pi: (.pi, "openai-codex/gpt-5.6-sol")
        }
        let tileID = UUID()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: model,
                                  thinking: "low", tileId: tileID)
        final class Log { var echoes: [String] = []; var events: [AgentRuntimeEvent] = [] }
        let log = Log()
        supervisor.addPromptEchoObserver(for: id) { [log] in log.echoes.append($0.text) }
        let stream = supervisor.events(for: id)
        let eventTask = Task { @MainActor [log] in for await event in stream { log.events.append(event) } }
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "queue-rail-check",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: root.appendingPathComponent("drafts", isDirectory: true),
                debounceInterval: 60),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer {
            window.orderOut(nil)
            supervisor.stopAll()
            eventTask.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        guard let composer = tile.qaComposerForChecks else { throw Failure(description: "queue rail: \(kind): no composer") }
        let rail = composer.qaQueueRail
        func settle() {
            window.layoutIfNeeded()
            tile.layoutSubtreeIfNeeded()
        }
        var frames: [[String: Any]] { AgentSteeringQAFakes.receivedFrames(in: bin) }
        var promptTexts: [String] {
            frames.compactMap { frame in
                if frame["type"] as? String == "prompt" { return frame["message"] as? String }
                if frame["method"] as? String == "turn/start" {
                    return ((frame["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String
                }
                if frame["type"] as? String == "user", let message = frame["message"] as? [String: Any] {
                    return message["content"] as? String
                }
                return nil
            }
        }
        var completedTurns: [TurnOutcome] {
            log.events.compactMap { if case let .turnCompleted(_, _, outcome, _) = $0 { return outcome } else { return nil } }
        }
        var followUps: [String] { supervisor.queuedMessages(for: id).filter { !$0.isSteer }.map(\.text) }
        func row(_ text: String) -> QueueRailItemRow? { rail.qaItemRows.first { $0.qaText == text } }
        func press(_ draft: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36,
                   characters: String = "\r") throws {
            composer.apply(.init(text: draft, selection: NSRange(location: draft.utf16.count, length: 0), revision: 1))
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else {
                throw Failure(description: "queue rail: could not mint a key event")
            }
            composer.textView.keyDown(with: event)
        }
        /// A Return chord through the key path, then the wait a person's next
        /// keystroke implies: the composer takes one submission at a time.
        func submit(_ draft: String, _ flags: NSEvent.ModifierFlags = []) async throws {
            try press(draft, flags)
            try await eventually("\(kind): the composer must accept '\(draft)', draft '\(composer.qaDraftText)'") {
                composer.qaDraftText.isEmpty
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        func shoot(_ name: String) throws {
            guard let shotsDirectory else { return }
            try FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
            let appAppearance = NSApp.appearance
            defer { NSApp.appearance = appAppearance; window.appearance = nil }
            for (label, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let appearance = NSAppearance(named: appearanceName) else { continue }
                NSApp.appearance = appearance
                window.appearance = appearance
                var rep: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    settle()
                    rep = try? UIProbe.bitmap(of: tile, id: "queueRail.\(name)")
                }
                guard let png = rep?.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "queue rail: could not render \(name) \(label)")
                }
                try png.write(to: shotsDirectory.appendingPathComponent("\(kind.rawValue)-\(name)-\(label).png"))
            }
        }

        var isWorking: Bool {
            supervisor.turnSnapshot(for: id).map { $0.executionState == .working && $0.capabilities.canSteer } == true
        }
        // 1. A working turn with nothing queued and an empty draft (2026-10-13
        //    owner review): the composer reads exactly like an idle one — no
        //    chord line, no send choice, just Stop — and the rail takes no space.
        try expect(supervisor.send("LONG first", to: id), "\(kind): the seed turn was refused")
        try await eventually("\(kind): the seed turn never became steerable") { isWorking }
        settle()
        try expect(composer.qaKeyHint == nil,
                   "\(kind): an empty busy composer must show no hint line, got '\(composer.qaKeyHint ?? "")'")
        try expect(tile.qaWorkingSendChoice == nil && tile.qaV2ActionTitle == "Stop",
                   "\(kind): an empty busy composer offers only Stop, got choice \(String(describing: tile.qaWorkingSendChoice)), action \(tile.qaV2ActionTitle ?? "nil")")
        try expect(rail.isHidden && tile.qaPendingRailSpace == 0,
                   "\(kind): an empty queue must take no space, hidden \(rail.isHidden), \(tile.qaPendingRailSpace)pt")

        // 1b. Typed while busy: Send becomes the primary action for ↩'s default
        //     (steer), with queue and force send offered beside it — each naming
        //     its chord — and still no text line under the draft.
        tile.qaSetComposerDraftForChecks("typed while busy")
        settle()
        let expectedChoice = ManagedAgentTileNSView.QAWorkingSendChoice(
            primary: "Steer",
            alternatives: ["Steer \u{2014} after the next tool call  \u{21A9}",
                           "Queue \u{2014} after this turn  \u{2325}\u{21A9}",
                           "Interrupt and send now  \u{2318}\u{21A9}"])
        try expect(tile.qaWorkingSendChoice == expectedChoice,
                   "\(kind): a typed busy composer must offer Steer with queue/force send beside it, got \(String(describing: tile.qaWorkingSendChoice))")
        try expect(composer.qaKeyHint == nil, "\(kind): a typed busy composer must not grow a hint line, got '\(composer.qaKeyHint ?? "")'")
        try expect(tile.qaStopIsCompact, "\(kind): beside the send choice Stop must collapse to its icon")
        try shoot("typed")
        tile.qaSetComposerDraftForChecks("")
        settle()
        try expect(tile.qaWorkingSendChoice == nil && !tile.qaStopIsCompact,
                   "\(kind): clearing the draft must withdraw the send choice and restore Stop")

        // 2. ↩ steers and ⌥↩ queues through the real key path; each section
        //    appears with its first item, follow-ups are numbered, and an item
        //    with an attachment says so.
        try await submit("also check the iOS build")
        try await eventually("\(kind): ↩ must hold a steer in the Steering section, got \(rail.qaSectionTitles)") {
            rail.qaSectionTitles == [steeringTitle] && rail.qaSteerTexts == ["also check the iOS build"]
        }
        // The pending rail is docked under the transcript, not inside the
        // composer: a separate view, between the two.
        settle()
        try expect(!rail.isDescendant(of: composer) && rail.window === window && !rail.isHidden,
                   "\(kind): the pending rail must be its own view outside the composer, in composer \(rail.isDescendant(of: composer))")
        if let transcript = tile.qaTranscriptForChecks {
            let railRect = rail.convert(rail.bounds, to: tile)
            let composerRect = composer.convert(composer.bounds, to: tile)
            let transcriptRect = transcript.convert(transcript.bounds, to: tile)
            let ordered = tile.isFlipped
                ? transcriptRect.maxY <= railRect.minY + 0.5 && railRect.maxY <= composerRect.minY + 0.5
                : transcriptRect.minY >= railRect.maxY - 0.5 && railRect.minY >= composerRect.maxY - 0.5
            try expect(ordered && railRect.height > 0,
                       "\(kind): the pending rail must sit between the transcript \(transcriptRect) and the composer \(composerRect), got \(railRect)")
        } else {
            throw Failure(description: "queue rail: \(kind): no transcript")
        }
        // The send choice's queue alternative goes through the same intent
        // path as ⌥↩.
        tile.qaSetComposerDraftForChecks("then write the release notes")
        try expect(tile.qaChooseWorkingSend(.queue), "\(kind): the send choice offered no queue alternative")
        try await eventually("\(kind): the send choice's Queue must queue, draft '\(composer.qaDraftText)', queue \(followUps)") {
            composer.qaDraftText.isEmpty && followUps == ["then write the release notes"]
        }
        try await Task.sleep(for: .milliseconds(50))
        try await submit("bump the version", .option)
        let attachedFile = work.appendingPathComponent("CHANGELOG.md")
        try "notes".write(to: attachedFile, atomically: true, encoding: .utf8)
        let attached = await supervisor.accept(.queue(AgentPrompt(
            text: "tidy the changelog", imageAttachments: [],
            fileReferences: [AgentPromptFileReference(displayName: "CHANGELOG.md", contentType: "text/markdown", fileURL: attachedFile)])),
            for: id)
        try expect(attached == .accepted, "\(kind): queueing with a file reference was refused: \(attached)")
        try await eventually("\(kind): both sections, three numbered follow-ups, got \(rail.qaSectionTitles) \(rail.qaQueuedTexts)") {
            rail.qaSectionTitles == [steeringTitle, queuedTitle]
                && rail.qaQueuedTexts == ["then write the release notes", "bump the version", "tidy the changelog"]
        }
        settle()
        try expect(!rail.qaHasVerticalScroller && rail.qaContentHeight <= rail.qaScrollViewHeight + 0.5,
                   "\(kind): a steer and three follow-ups must fit without scrolling")
        let order = rail.qaItemRows.filter { $0.kind == .queued }.map(\.qaText)
        try expect(order == ["then write the release notes", "bump the version", "tidy the changelog"],
                   "\(kind): follow-ups must stack in drain order, got \(order)")
        guard let steerRow = row("also check the iOS build"), let tidyRow = row("tidy the changelog") else {
            throw Failure(description: "queue rail: \(kind): rows missing")
        }
        try expect(steerRow.kind == .heldSteer && steerRow.qaOffersSendNow && steerRow.qaOffersEdit && steerRow.qaOffersRemove,
                   "\(kind): a held steer must offer send-now, edit and delete")
        try expect(tidyRow.qaShowsAttachments && row("bump the version")?.qaShowsAttachments == false,
                   "\(kind): only the item with an attachment shows the attachment glyph")
        for itemRow in rail.qaItemRows {
            try expect(itemRow.qaControlLabels.count == 3 && !(itemRow.accessibilityLabel() ?? "").isEmpty,
                       "\(kind): every row and control needs an accessibility label, got \(itemRow.qaControlLabels)")
            try expect(itemRow.qaButtonSide >= 20, "\(kind): a control is \(itemRow.qaButtonSide)pt at 100%")
            // Actions are hover-only: invisible and unpainted at rest, shown
            // under the pointer, gone again when it leaves.
            try expect(!itemRow.qaActionsVisible && itemRow.qaRestingPaintsNil,
                       "\(kind): '\(itemRow.qaText)' must show no actions and paint nothing at rest, visible \(itemRow.qaActionsVisible), nil \(itemRow.qaRestingPaintsNil)")
            itemRow.qaHover(true)
            try expect(itemRow.qaActionsVisible, "\(kind): '\(itemRow.qaText)' must show its actions under the pointer")
            if kind == .claude, itemRow.qaText == "bump the version" { try shoot("hover") }
            itemRow.qaHover(false)
            try expect(!itemRow.qaActionsVisible && itemRow.qaRestingPaintsNil,
                       "\(kind): '\(itemRow.qaText)' must hide its actions when the pointer leaves")
        }
        // Hit targets and the cap follow the page zoom.
        for percent in [80, 150] {
            let rung = AgentPageZoom(percent: percent)
            AgentPageZoomScaling.apply(rung, in: tile)
            settle()
            let side = rail.qaItemRows.first?.qaButtonSide ?? 0
            let expected = ComposerQueuedMessageRailView.railHeight(for: rail.state, zoom: rung)
            try expect(abs(side - CGFloat(rung.scaled(20))) < 0.5 && abs(rail.frame.height - expected) < 0.5,
                       "\(kind): at \(percent)% a control is \(side)pt and the rail \(rail.frame.height)pt (want \(expected))")
        }
        AgentPageZoomScaling.apply(.default, in: tile)
        settle()
        if kind == .claude { try shoot("working") }

        // 3. Drag the third follow-up to the top: the SUPERVISOR's order moves.
        try expect(rail.qaDragQueuedItem(from: 2, toGap: 0), "\(kind): the drag could not be driven")
        try await eventually("\(kind): a drag must reorder the supervisor's queue, got \(followUps)") {
            followUps == ["tidy the changelog", "then write the release notes", "bump the version"]
        }
        try expect(supervisor.pendingSteers(for: id).map(\.text) == ["also check the iOS build"],
                   "\(kind): reordering follow-ups must leave the held steer in front")

        // 4. ✕ deletes from the supervisor.
        row("bump the version")?.qaPressRemove()
        try await eventually("\(kind): ✕ must delete from the supervisor, got \(followUps)") {
            followUps == ["tidy the changelog", "then write the release notes"]
                && rail.qaQueuedTexts == followUps
        }

        // 5. ✎ never replaces a draft in progress: refused with a hint, the
        //    item stays queued, the draft stays put.
        tile.qaSetComposerDraftForChecks("my draft")
        row("then write the release notes")?.qaPressEdit()
        try await Task.sleep(for: .milliseconds(150))
        try expect(composer.qaDraftText == "my draft" && followUps.contains("then write the release notes"),
                   "\(kind): ✎ over a draft must keep both, draft '\(composer.qaDraftText)', queue \(followUps)")
        try expect(composer.qaKeyHint == "Send or clear your draft to edit a queued message",
                   "\(kind): a refused edit must say why, hint \(composer.qaKeyHint ?? "nil")")

        // 6. ✎ on an empty draft moves the item, attachment and all, into the
        //    composer and out of the queue.
        tile.qaSetComposerDraftForChecks("")
        row("tidy the changelog")?.qaPressEdit()
        try await eventually("\(kind): ✎ must move the item into the composer, draft '\(composer.qaDraftText)', queue \(followUps)") {
            composer.qaDraftText == "tidy the changelog" && followUps == ["then write the release notes"]
        }
        try expect(composer.qaFileReferences.map(\.fileURL.path) == [attachedFile.path],
                   "\(kind): ✎ must bring the item's attachment back, got \(composer.qaFileReferences)")

        // 7. ↑ on an empty draft edits the last queued item; ⌥↩ queues it back.
        tile.qaSetComposerDraftForChecks("")
        try press("", keyCode: 126, characters: "\u{F700}")
        try await eventually("\(kind): ↑ on an empty draft must edit the last queued item, draft '\(composer.qaDraftText)'") {
            composer.qaDraftText == "then write the release notes" && followUps.isEmpty
        }
        try await eventually("\(kind): with only the steer left, only its section shows") {
            rail.qaSectionTitles == [steeringTitle]
        }
        try await submit("then write the release notes", .option)
        try await eventually("\(kind): ⌥↩ must queue the edited item again") { followUps == ["then write the release notes"] }

        // 8. The rail is bounded: beyond about four items it scrolls instead of
        //    pushing the transcript off the tile. Clear takes the follow-ups
        //    only — the steer is its own section.
        for index in 1...6 {
            _ = await supervisor.accept(.queue(AgentPrompt("filler \(index)")), for: id)
        }
        try await eventually("\(kind): seven follow-ups must reach the rail") { rail.qaQueuedTexts.count == 7 }
        settle()
        let zoom = AgentPageZoom.default
        let cap = ComposerQueuedMessageRailView.headerHeight(zoom: zoom) * 2
            + CGFloat(ComposerQueuedMessageRailView.maximumVisibleRows) * ComposerQueuedMessageRailView.rowHeight(zoom: zoom)
            + ComposerQueuedMessageRailView.verticalInset(zoom: zoom) * 2
        try expect(abs(rail.frame.height - cap) < 0.5 && rail.qaHasVerticalScroller && rail.qaContentHeight > rail.qaScrollViewHeight,
                   "\(kind): the rail must clamp at \(cap)pt and scroll, got \(rail.frame.height)pt, scroller \(rail.qaHasVerticalScroller)")
        try expect(rail.qaPressClear(), "\(kind): Clear was not offered for several follow-ups")
        try await eventually("\(kind): Clear must empty the follow-ups and keep the held steer, got \(followUps)") {
            followUps.isEmpty && supervisor.pendingSteers(for: id).map(\.text) == ["also check the iOS build"]
                && rail.qaSectionTitles == [steeringTitle]
        }

        // 9. ⤒ on a follow-up is D2's force send: the running turn is
        //    interrupted (the process lives), the item runs now, the held
        //    steer runs after it, and the queue is not paused.
        try await submit("then write the release notes", .option)
        try await eventually("\(kind): requeue") { rail.qaQueuedTexts == ["then write the release notes"] }
        row("then write the release notes")?.qaPressSendNow()
        try await eventually("\(kind): ⤒ must interrupt and run the item, then the held steer, prompts \(promptTexts)", timeout: 12) {
            promptTexts == ["LONG first", "then write the release notes", "also check the iOS build"]
                && !supervisor.isRunning(id) && rail.state.isEmpty
        }
        // codex runs one app-server per turn by design, so its witness is the
        // wire: an interrupt, never a kill.
        let interruptedOnTheWire = frames.contains {
            ($0["type"] as? String) == "abort" || ($0["method"] as? String) == "turn/interrupt"
                || (($0["request"] as? [String: Any])?["subtype"] as? String) == "interrupt"
        }
        try expect(interruptedOnTheWire && (kind == .codex || AgentSteeringQAFakes.spawnCount(in: bin) == 1),
                   "\(kind): ⤒ must interrupt the turn over the wire and not kill the process, spawned \(AgentSteeringQAFakes.spawnCount(in: bin))")
        try expect(completedTurns.first == .interrupted && !supervisor.isQueuePaused(for: id),
                   "\(kind): a force send must not pause the queue, turns \(completedTurns)")
        settle()
        try expect(rail.isHidden && tile.qaPendingRailSpace == 0 && composer.qaKeyHint == nil,
                   "\(kind): an idle agent with nothing queued shows no rail and no hint, rail hidden \(rail.isHidden) \(tile.qaPendingRailSpace)pt, hint \(composer.qaKeyHint ?? "nil")")

        // 10. ⤒ on a held steer hands it over now. Once handed over it is the
        //     provider's: no edit, no delete, until the transcript shows it.
        try expect(supervisor.send("LONG second", to: id), "\(kind): second seed refused")
        try await eventually("\(kind): second turn working") { isWorking }
        // The send choice's primary action is ↩'s default: a steer.
        tile.qaSetComposerDraftForChecks("late steer")
        try expect(tile.qaChooseWorkingSend(.plain), "\(kind): the send choice offered no primary action")
        try await eventually("\(kind): the send choice's Steer must hold a steer, draft '\(composer.qaDraftText)'") {
            composer.qaDraftText.isEmpty && row("late steer")?.kind == .heldSteer
        }
        row("late steer")?.qaPressSendNow()
        if kind == .codex {
            // codex's turn/steer reply is its receipt: straight to the transcript.
            try await eventually("\(kind): a confirmed steer must leave the rail for the transcript, echoes \(log.echoes)") {
                log.echoes.contains("late steer") && rail.qaSteerTexts.isEmpty
            }
        } else {
            try await eventually("\(kind): a handed-over steer must show as delivering") {
                row("late steer")?.kind == .deliveringSteer
            }
            guard let delivering = row("late steer") else { throw Failure(description: "queue rail: \(kind): row vanished") }
            try expect(!delivering.qaOffersEdit && !delivering.qaOffersRemove && !delivering.qaOffersSendNow,
                       "\(kind): a delivering steer must not be editable or deletable")
        }
        composer.requestStop()
        if kind != .codex {
            // pi hands an unread steer back on abort, claude on an interrupt
            // that cancels what it holds (T5c — claude used to run it as its
            // own next turn after Stop): it is Array's again, held and deletable.
            try await eventually("\(kind): an aborted turn's unread steer must come back as held, got \(supervisor.pendingSteers(for: id))", timeout: 12) {
                !supervisor.isRunning(id) && supervisor.pendingSteers(for: id).map(\.state) == [.held]
                    && row("late steer")?.qaOffersRemove == true
            }
            row("late steer")?.qaPressRemove()
        }
        try await eventually("\(kind): the second turn must end with no steer left, got \(supervisor.pendingSteers(for: id))", timeout: 12) {
            !supervisor.isRunning(id) && supervisor.pendingSteers(for: id).isEmpty
        }
        supervisor.resumeQueue(for: id)

        // 11. Stop pauses the queue: the rail says why and offers Resume, and
        //     Resume drains it on the same process.
        try expect(supervisor.send("LONG third", to: id), "\(kind): third seed refused")
        try await eventually("\(kind): third turn working") { isWorking }
        try await submit("after stop", .option)
        try await eventually("\(kind): queued") { rail.qaQueuedTexts == ["after stop"] }
        let turnsBefore = completedTurns.count
        composer.requestStop()
        try await eventually("\(kind): Stop must pause the queue and the rail must say so, got \(rail.qaSectionTitles)", timeout: 12) {
            completedTurns.count > turnsBefore && !supervisor.isRunning(id)
                && rail.qaSectionTitles == ["Queued \u{00B7} Paused after Stop"] && rail.qaResumeIsOffered
        }
        try expect(!promptTexts.contains("after stop"), "\(kind): a paused queue must not drain on its own")
        if kind == .claude { try shoot("paused") }
        try expect(rail.qaPressResume(), "\(kind): Resume was not offered")
        try await eventually("\(kind): Resume must drain the paused queue, prompts \(promptTexts)", timeout: 10) {
            promptTexts.last == "after stop" && !supervisor.isRunning(id) && rail.state.isEmpty
        }
        // Hold the rail before direct fixture insertion: the prior completion
        // can still have an asynchronous drain awaiting its store hop.
        supervisor.stop(id)
        try expect(supervisor.isQueuePaused(for: id), "\(kind): stale Edit fixture must use a paused queue")
        // Async Edit must return A's exact item to A's durable queue if the
        // composer binds B during either the take or attachment-load boundary.
        for boundary in ["take", "attachments"] {
            let image = AgentComposerDraftImageAttachment(metadata: AgentImageAttachmentMetadata(
                id: AgentImageAttachmentID(rawValue: UUID().uuidString)!, displayName: "queued-edit.png"))
            let message = await recoveryStore.enqueueMessage(text: "A message \(boundary)",
                imageAttachments: boundary == "attachments" ? [image] : [], for: id)
            composer.bindAttachmentStore(AgentComposerAttachmentStore(applicationSupportDirectory: root), agentID: id)
            composer.apply(.init(text: "", selection: NSRange(location: 0, length: 0), revision: 1))
            let otherID = AgentID(rawValue: UUID())
            func rebindToB() {
                composer.bindAttachmentStore(AgentComposerAttachmentStore(applicationSupportDirectory: root), agentID: otherID)
                composer.apply(.init(text: "B draft", selection: NSRange(location: 7, length: 0), revision: 1))
            }
            var restored = false
            composer.onRestoreQueuedMessageAfterFailedEdit = { item in
                await supervisor.restoreQueuedItemAfterFailedEdit(item, for: id)
                restored = true
            }
            composer.onTakeQueuedMessageForEditing = { itemID in
                let item = await supervisor.takeQueuedItemForEditing(itemID, for: id)
                if boundary == "take" { rebindToB() }
                return item
            }
            composer.qaAfterQueuedEditAttachmentLoad = {
                if boundary == "attachments" { rebindToB() }
            }
            composer.editQueuedMessage(message.id)
            try await eventually("\(kind): stale edit after \(boundary) must restore A's queue") { restored }
            let queueAfter = await recoveryStore.queuedMessages(for: id)
            try expect(queueAfter.first == message,
                       "\(kind): stale edit after \(boundary) must restore exact item at front, got \(queueAfter)")
            try expect(composer.qaDraftText == "B draft" && composer.qaImageAttachmentCount == 0,
                       "\(kind): stale edit after \(boundary) must leave B draft untouched")
            _ = await recoveryStore.removeQueuedMessage(id: message.id, for: id)
            composer.qaAfterQueuedEditAttachmentLoad = nil
        }
        try expect(kind == .codex || AgentSteeringQAFakes.spawnCount(in: bin) == 1,
                   "\(kind): one process for the whole session, spawned \(AgentSteeringQAFakes.spawnCount(in: bin))")
    }

    print("AgentQueueRailChecks passed: on claude, codex and pi an empty busy composer shows no hint and only Stop, a typed one offers Steer with queue and force send beside it; the pending rail is docked between transcript and composer with hover-only actions; its sections follow the queue; ↩ steers and ⌥↩ (or the send choice's Queue) queue; drag reorders, ✕ deletes and ✎ moves an item (attachment included) into the composer on the supervisor's queue, refusing over a draft; ↑ edits the last queued item; the rail clamps and Clear spares steers; ⤒ on a follow-up interrupts without killing and runs it next; a handed-over steer is not editable; Stop pauses with a reason and Resume drains")
}
