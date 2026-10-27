import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Darwin
import Foundation

// Confidence pass S3 — "throwing it into a void". Every scenario binds a REAL
// `ManagedAgentTileNSView` to an `AgentSupervisor` built with the production
// runner factory, with `AgentSteeringQAFakes` standing in for claude, codex and
// pi on PATH, so the event sequence each harness really produces is the one
// under test — never a hand-built snapshot (`AgentFirstPaintChecks` used to
// build `.starting` by hand, and stayed green while codex painted Idle). All
// three harnesses must behave the same, so each scenario runs over all three.
@MainActor
func runAgentPresenceChecks() async throws {
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let originalCodexTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
    setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
    defer {
        setenv("PATH", originalPath, 1)
        if let originalCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalCodexTransport, 1) }
        else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
    }
    var summary: [String] = []
    // CONTINUUM_PRESENCE_SECTIONS=silence,refusals… runs a subset (for a RED
    // probe against older code); the matrix runs every section.
    let only = ProcessInfo.processInfo.environment["CONTINUUM_PRESENCE_SECTIONS"]
        .map { Set($0.split(separator: ",").map(String.init)) }
    func wants(_ name: String) -> Bool { only?.contains(name) ?? true }
    if wants("spawn") { summary.append(try await AgentPresenceChecks.checkSpawnWindowNeverReadsIdle(originalPath: originalPath)) }
    if wants("refusals") { summary.append(try await AgentPresenceChecks.checkRefusalsSayWhyEveryTime(originalPath: originalPath)) }
    if wants("failures") { summary.append(try await AgentPresenceChecks.checkFailuresSayWhatHappened(originalPath: originalPath)) }
    if wants("silence") { summary.append(try await AgentPresenceChecks.checkSilenceIsModelled(originalPath: originalPath)) }
    if wants("tools") {
        summary.append(try AgentPresenceChecks.checkToolClockScopeIsTranscriptLocal())
        summary.append(try await AgentPresenceChecks.checkLongToolsStayHonest(originalPath: originalPath))
    }
    if wants("land") { summary.append(try await AgentPresenceChecks.checkOwnActionsVisiblyLand(originalPath: originalPath)) }
    if wants("n1") { summary.append(try await AgentPresenceChecks.checkUnsolicitedTurnAfterStopSettles()) }
    if wants("background") { summary.append(try await AgentPresenceChecks.checkMirroredBackgroundChildLifetime(originalPath: originalPath)) }
    if wants("activity") { summary.append(try AgentPresenceChecks.checkLastActivityMovesOnFrames()) }
    print("AgentPresenceChecks passed: " + summary.joined(separator: "; "))
}

@MainActor
enum AgentPresenceChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: "presence: " + message()) }
    }

    static func eventually(
        _ message: @autoclosure () -> String, timeout: TimeInterval = 8,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "presence: " + message())
    }

    /// One harness, one supervisor over its own store, one attached tile in an
    /// offscreen window, and the fake CLI first on PATH.
    @MainActor
    final class Bench {
        let kind: AgentSteeringQAFakes.Harness
        let root: URL
        let bin: URL
        let supervisor: AgentSupervisor
        let id: AgentID
        let tile: ManagedAgentTileNSView
        let window: NSWindow
        var events: [AgentRuntimeEvent] = []
        private var eventTask: Task<Void, Never>?

        init(_ kind: AgentSteeringQAFakes.Harness, originalPath: String) throws {
            self.kind = kind
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("array-presence-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            try AgentSteeringQAFakes.install(kind, in: bin)
            let work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            setenv("PATH", "\(bin.path):\(originalPath)", 1)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0),
                // Production gives every supervisor a transcript store.
                transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
            supervisor.interruptGrace = 3
            let (harness, model): (AgentHarness, String) = switch kind {
            case .claude: (.claudeCode, "anthropic/claude-haiku-4-5-20251001")
            case .codex: (.codex, "openai-codex/gpt-5.6-sol")
            case .pi: (.pi, "openai-codex/gpt-5.6-sol")
            }
            let tileID = UUID()
            id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: model,
                                  thinking: "low", tileId: tileID)
            tile = ManagedAgentTileNSView(tile: Tile(
                id: tileID, kind: .managedAgent, title: "presence-check",
                frame: TileFrame(x: 0, y: 0, width: 640, height: 520),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
            tile.bindV2ComposerState(
                draftStore: AgentComposerDraftStore(
                    applicationSupportDirectory: root.appendingPathComponent("drafts", isDirectory: true),
                    debounceInterval: 60),
                promptHistory: AgentPromptHistory())
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            tile.attach(agentID: id, supervisor: supervisor)
            let stream = supervisor.events(for: id)
            eventTask = Task { @MainActor [weak self] in
                for await event in stream { self?.events.append(event) }
            }
        }

        var composer: AgentComposerView {
            get throws {
                guard let composer = tile.qaComposerForChecks else {
                    throw Failure(description: "presence: \(kind): the tile has no composer")
                }
                return composer
            }
        }

        /// Return through the composer's real key path.
        func pressReturn(_ draft: String) throws {
            let composer = try composer
            composer.apply(.init(text: draft, selection: NSRange(location: draft.utf16.count, length: 0), revision: 1))
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                throw Failure(description: "presence: could not mint a key event")
            }
            composer.textView.keyDown(with: event)
        }

        var turnStartedCount: Int {
            events.filter { if case .turnStarted = $0 { return true } else { return false } }.count
        }
        var turnCompletedCount: Int {
            events.filter { if case .turnCompleted = $0 { return true } else { return false } }.count
        }
        var readyCount: Int {
            events.filter { $0 == .sessionStateChanged(.ready) }.count
        }

        var harness: AgentHarness {
            switch kind {
            case .claude: return .claudeCode
            case .codex: return .codex
            case .pi: return .pi
            }
        }

        /// The tile document's text, entry by entry, for outcome assertions.
        func entryTexts(role: AgentEntryRole) -> [String] {
            tile.qaDocumentForChecks.entries.filter { $0.role == role }.map { String(describing: $0.blocks) }
        }

        var spawns: Int { AgentSteeringQAFakes.spawnCount(in: bin) }
        var promptTexts: [String] {
            AgentSteeringQAFakes.receivedFrames(in: bin).compactMap { frame in
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

        func tearDown() {
            window.orderOut(nil)
            supervisor.stopAll()
            eventTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - P0-1 — the spawn window is "Starting" on every surface, every turn

    /// Return → provider turn start must read Starting on the header, the
    /// supervisor snapshot, the compact status row and the transcript tail, on
    /// every harness and every turn — including the codex resume prefix
    /// (`thread/resume` + a synthetic `thread/started`, i.e. session READY,
    /// before `turn/started`) and pi's session header before `agent_start`. It
    /// used to fall to Idle with Send disabled there.
    static func checkSpawnWindowNeverReadsIdle(originalPath: String) async throws -> String {
        var sampled: [String] = []
        var allViolations: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            for turn in 1...2 {
                let startsBefore = bench.turnStartedCount
                let completedBefore = bench.turnCompletedCount
                let readyBefore = bench.readyCount
                try bench.pressReturn("DELAYSTART PLAIN turn \(turn)")
                try await eventually("\(kind) turn \(turn): the send never bound a runner") {
                    bench.supervisor.isRunning(bench.id) || bench.turnStartedCount > startsBefore
                }
                var samples = 0
                var samplesAfterReady = 0
                var violations: Set<String> = []
                while bench.turnStartedCount == startsBefore {
                    // Read the surfaces at the instant the supervisor has
                    // reduced everything delivered so far.
                    let snapshot = bench.supervisor.turnSnapshot(for: bench.id)
                    let state = snapshot?.state
                    // The supervisor reduces an event a main-queue hop before
                    // this check's own subscription sees it; a stamped turn
                    // start means the provider has started, so the window is over.
                    if state == .working, snapshot?.turnStartedAt != nil { break }
                    let header = bench.tile.qaPageZoomHeaderView.qaState
                    let tail = bench.tile.qaThinkingIndicatorVisible
                    let phase = bench.tile.qaCompactStatusPhase
                    let afterReady = bench.readyCount > readyBefore
                    // The provider may already have started; re-check before judging.
                    if bench.turnStartedCount != startsBefore { break }
                    let when = afterReady ? " after session-ready" : ""
                    if state != .starting { violations.insert("supervisor read \(String(describing: state))\(when)") }
                    if header != AgentStatusVocabulary.starting { violations.insert("header read '\(header)'\(when)") }
                    if !tail { violations.insert("transcript tail went dark\(when)") }
                    if phase != .starting { violations.insert("compact row read \(String(describing: phase))\(when)") }
                    // The canvas badge/zone rollup and the sidebar row read the
                    // tile's status when it has one, the supervisor's presence
                    // when it does not: both must say work is in progress.
                    let tileStatus = bench.tile.currentAgentStatus
                    if tileStatus != .working { violations.insert("tile status (canvas badge, sidebar row) read \(tileStatus)\(when)") }
                    let rowStatus = bench.supervisor.presenceRowStatus(for: bench.id)
                    if rowStatus != .working { violations.insert("headless row status read \(String(describing: rowStatus))\(when)") }
                    samples += 1
                    if afterReady { samplesAfterReady += 1 }
                    try await Task.sleep(for: .milliseconds(25))
                    if samples > 400 { throw Failure(description: "presence: \(kind) turn \(turn): the provider never started the turn") }
                }
                if !violations.isEmpty { allViolations.append("\(kind) turn \(turn): " + violations.sorted().joined(separator: "; ")) }
                try expect(samples >= 5, "\(kind) turn \(turn): only \(samples) samples landed in the spawn window — the DELAYSTART fake did not hold it open")
                if kind != .claude, turn == (kind == .pi ? 1 : 2) {
                    // The window the bug lived in: session READY delivered, turn not started.
                    try expect(samplesAfterReady >= 3,
                               "\(kind) turn \(turn): the provider's session-ready signal never landed inside the spawn window (\(samplesAfterReady) samples) — the witness did not cross the window it guards")
                }
                try await eventually("\(kind) turn \(turn): the turn never completed") {
                    bench.turnCompletedCount > completedBefore && !bench.supervisor.isRunning(bench.id)
                }
                // The settled tail is measured from Return; it used to read
                // nothing because the anchor was cleared before the tile looked.
                do {
                    try await eventually("", timeout: 2) { bench.tile.qaTailStatusText.hasPrefix("Worked for") }
                } catch {
                    allViolations.append("\(kind) turn \(turn): the settled tail read '\(bench.tile.qaTailStatusText)', not 'Worked for …'")
                }
                sampled.append("\(kind)#\(turn) \(samples)/\(samplesAfterReady)")
            }
        }
        try expect(allViolations.isEmpty,
                   "Return must read Starting on every surface until the provider starts the turn: "
                   + allViolations.joined(separator: " | "))
        return "the spawn window read Starting on the supervisor, header, compact row and tail through every harness's real ready-before-start prefix (\(sampled.joined(separator: ", ")) samples/after-ready)"
    }

    // MARK: - P0-2 — a refusal says why, every time, and never leaves a ghost

    /// A signed-out CLI refuses with ITS reason and its own login instruction,
    /// on every Return (the notice used to dedupe itself away after the first),
    /// and the bubble is withdrawn rather than left looking sent. A CLI that
    /// is merely still starting HOLDS the prompt and sends it once readiness
    /// lands, instead of telling the user to try again.
    static func checkRefusalsSayWhyEveryTime(originalPath: String) async throws -> String {
        let catalog = AgentModelCatalog.shared
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer {
                catalog.apply(readiness: .ready, for: bench.harness)
                bench.tearDown()
            }
            // Let the composer's draft binding finish loading the (empty)
            // persisted draft, as it has long before a person types.
            try await Task.sleep(for: .milliseconds(300))
            // Signed out: twice.
            catalog.apply(readiness: .loggedOut, for: bench.harness)
            let draft = "please fix the login page"
            for attempt in 1...2 {
                let before = bench.entryTexts(role: .system).count
                if attempt == 1 { try bench.pressReturn(draft) } else {
                    // The refused draft is still in the composer: Return again.
                    let composer = try bench.composer
                    try await eventually("\(kind): a refused draft must come back to the composer for a retry, got '\(composer.qaDraftText)'") {
                        composer.qaDraftText == draft
                    }
                    try bench.pressReturn(composer.qaDraftText)
                }
                try await eventually("\(kind) attempt \(attempt): a signed-out refusal must append a notice every time; system entries \(bench.entryTexts(role: .system))") {
                    bench.entryTexts(role: .system).count > before
                }
                let notice = bench.entryTexts(role: .system).last ?? ""
                try expect(notice.contains("Not sent") && notice.contains("signed out")
                           && notice.contains(AgentSupervisor.signInInstruction(for: bench.harness)),
                           "\(kind) attempt \(attempt): the notice must say Not sent, signed out, and how to sign in with the CLI's own login; got \(notice)")
                try expect(!bench.entryTexts(role: .user).contains { $0.contains(draft) },
                           "\(kind) attempt \(attempt): the refused bubble is still in the transcript, reading as sent")
            }
            try expect(bench.spawns == 0, "\(kind): a signed-out CLI was spawned \(bench.spawns) times")

            // Still starting: held, then sent once readiness lands.
            catalog.apply(readiness: .checking, for: bench.harness)
            try bench.pressReturn("HELD PLAIN reply")
            try await eventually("\(kind): a prompt sent while the CLI is starting must be accepted and held, draft '\((try? bench.composer.qaDraftText) ?? "?")'") {
                ((try? bench.composer.qaDraftText) ?? "x").isEmpty
            }
            let held = bench.supervisor.turnPresence(for: bench.id)
            try expect(held?.phase == .starting && held?.startupDetail?.contains("finish starting") == true,
                       "\(kind): a held prompt must read Starting and say what it waits on, got \(String(describing: held?.phase)) / \(String(describing: held?.startupDetail))")
            try expect(bench.tile.qaPageZoomHeaderView.qaState == AgentStatusVocabulary.starting,
                       "\(kind): the header read '\(bench.tile.qaPageZoomHeaderView.qaState)' for a held prompt")
            try await eventually("\(kind): the tail must say what the held prompt waits on, got '\(bench.tile.qaTailStatusText)'") {
                bench.tile.qaThinkingIndicatorVisible && bench.tile.qaTailStatusText.hasPrefix("Waiting for")
            }
            // One clock, from THIS Return: not from an earlier refused attempt.
            let tailSeconds = bench.tile.qaTailStatusText.split(separator: "·").last
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "s", with: "") }
                .flatMap { Int($0) }
            try expect((tailSeconds ?? 99) <= 2 && (held?.startedAt.map { Date().timeIntervalSince($0) < 3 } ?? false),
                       "\(kind): the held prompt's clock did not start at its own Return: tail '\(bench.tile.qaTailStatusText)', presence started \(String(describing: held?.startedAt))")
            try expect(bench.spawns == 0 && bench.promptTexts.isEmpty,
                       "\(kind): a held prompt reached the CLI before readiness (\(bench.promptTexts))")
            catalog.apply(readiness: .ready, for: bench.harness)
            NotificationCenter.default.post(name: AgentModelCatalog.didRefreshNotification, object: catalog)
            try await eventually("\(kind): the held prompt must run once readiness lands, prompts \(bench.promptTexts)") {
                bench.promptTexts == ["HELD PLAIN reply"] && bench.turnCompletedCount == 1
                    && !bench.supervisor.isRunning(bench.id)
            }
            try expect(bench.entryTexts(role: .user).filter { $0.contains("HELD PLAIN reply") }.count == 1,
                       "\(kind): the held prompt must appear exactly once in the transcript")
        }
        return "a signed-out claude, codex and pi each refused twice with two 'Not sent' notices naming their own login and withdrew the bubble; a prompt sent while each CLI was starting was held, read 'Waiting for … to finish starting', and ran once readiness landed"
    }

    // MARK: - P0-3 — a failure says what happened and who caused it

    /// The error rows a tile shows for the turn just run.
    static func errorRows(_ bench: Bench) -> [String] {
        bench.tile.qaDocumentForChecks.entries.compactMap { entry -> String? in
            for block in entry.blocks {
                if case let .error(payload) = block.payload { return payload.message }
            }
            return nil
        }
    }

    /// A provider's in-band failure (an expired login) shows the provider's
    /// own words — claude's used to read "success" — and a process that dies
    /// mid-turn shows its stderr, once, and is never "You stopped".
    static func checkFailuresSayWhatHappened(originalPath: String) async throws -> String {
        var violations: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            try await Task.sleep(for: .milliseconds(300))

            // In-band provider failure.
            var completed = bench.turnCompletedCount
            try bench.pressReturn("APIERROR please")
            try await eventually("\(kind): the APIERROR turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
            try await Task.sleep(for: .milliseconds(150))
            var rows = errorRows(bench)
            if rows.count != 1 || !(rows.first ?? "").contains("401") || (rows.first ?? "").lowercased() == "success" {
                violations.append("\(kind) in-band: error rows \(rows), expected one carrying the provider's 401")
            }
            let failedPresence = bench.supervisor.turnPresence(for: bench.id)
            if case .failed = failedPresence?.phase, failedPresence?.errorText?.contains("401") == true {} else {
                violations.append("\(kind) in-band: presence \(String(describing: failedPresence?.phase)) / \(String(describing: failedPresence?.errorText))")
            }
            if bench.tile.qaPageZoomHeaderView.qaState != AgentStatusVocabulary.failed {
                violations.append("\(kind) in-band: header read '\(bench.tile.qaPageZoomHeaderView.qaState)'")
            }

            // Process lost mid-turn.
            let rowsBefore = errorRows(bench).count
            completed = bench.turnCompletedCount
            try bench.pressReturn("CRASH please")
            try await eventually("\(kind): the CRASH turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
            try await Task.sleep(for: .milliseconds(150))
            rows = Array(errorRows(bench).dropFirst(rowsBefore))
            if rows.count != 1 || !(rows.first ?? "").contains("lost connection to the model provider") {
                violations.append("\(kind) crash: error rows \(rows), expected ONE carrying the CLI's stderr")
            }
            if rows.contains(where: { $0.contains("Failed(exitCode") || $0.contains("RunError") }) {
                violations.append("\(kind) crash: an error row shows a Swift error value: \(rows)")
            }
            if bench.tile.qaTailStatusText.hasPrefix("You stopped") {
                violations.append("\(kind) crash: the tail blames the user: '\(bench.tile.qaTailStatusText)'")
            }
            let lost = bench.supervisor.turnPresence(for: bench.id)
            if lost?.settleCause == .stoppedByUser {
                violations.append("\(kind) crash: presence recorded the user's Stop for a crash")
            }

            // A process that leaves without a word or a result.
            completed = bench.turnCompletedCount
            try bench.pressReturn("VANISH please")
            try await eventually("\(kind): the VANISH turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
            try await Task.sleep(for: .milliseconds(150))
            let vanished = bench.supervisor.turnPresence(for: bench.id)
            if bench.tile.qaTailStatusText.hasPrefix("You stopped") || vanished?.settleCause == .stoppedByUser {
                violations.append("\(kind) vanish: blamed the user: tail '\(bench.tile.qaTailStatusText)', presence \(String(describing: vanished?.phase))")
            }
            let vanishedSaysSo: Bool
            switch vanished?.phase {
            case .settled(.processLost)?: vanishedSaysSo = bench.tile.qaTailStatusText.hasPrefix("Ended after")
            case .failed?: vanishedSaysSo = errorRows(bench).last?.contains("exited without finishing") == true
            default: vanishedSaysSo = false
            }
            if !vanishedSaysSo {
                violations.append("\(kind) vanish: did not say the process left: presence \(String(describing: vanished?.phase)), tail '\(bench.tile.qaTailStatusText)', last error \(errorRows(bench).last ?? "none")")
            }
        }
        try expect(violations.isEmpty, "failures must say what happened: " + violations.joined(separator: " | "))
        return "an expired login on claude, codex and pi each showed one error row with the provider's own 401 and read Failed; a CLI that died mid-turn showed its stderr in one error row, and one that vanished without a result said the process left — neither ever read 'You stopped'"
    }

    // MARK: - P1-4 — silence, retries and a process that leaves are said out loud

    static func checkSilenceIsModelled(originalPath: String) async throws -> String {
        var violations: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            try await Task.sleep(for: .milliseconds(300))

            // A provider retry is the turn's status.
            var completed = bench.turnCompletedCount
            try bench.pressReturn("RETRY please")
            do {
                try await eventually("", timeout: 4) { bench.tile.qaTailStatusText.hasPrefix("Retrying (2/5)") }
            } catch {
                violations.append("\(kind) retry: the tail never said 'Retrying (2/5)', it read '\(bench.tile.qaTailStatusText)'")
            }
            try await eventually("\(kind): the RETRY turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }

            // A minute of silence with no tool open reads "No output for 1m".
            completed = bench.turnCompletedCount
            try bench.pressReturn("LONG think")
            try await eventually("\(kind): the LONG turn never started") {
                bench.supervisor.turnPresence(for: bench.id)?.isWorking == true
            }
            try await Task.sleep(for: .milliseconds(200))
            bench.tile.qaRefreshLocation(at: Date())
            let fresh = bench.tile.qaTailStatusText
            bench.tile.qaRefreshLocation(at: Date().addingTimeInterval(65))
            let quiet = bench.tile.qaTailStatusText
            if fresh.hasPrefix("No output") {
                violations.append("\(kind) heartbeat: a turn that just spoke already reads '\(fresh)'")
            }
            if quiet != "No output for 1m · still running" {
                violations.append("\(kind) heartbeat: after 65 s of silence the tail read '\(quiet)'")
            }
            _ = await bench.supervisor.accept(.stop, for: bench.id)
            try await eventually("\(kind): the LONG turn never stopped") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }

            // A session process that leaves between turns says so (claude and
            // pi keep one; codex starts a process per turn, so has none to lose).
            guard kind != .codex else { continue }
            completed = bench.turnCompletedCount
            let spawnsBefore = bench.spawns
            try bench.pressReturn("EXITIDLE now")
            try await eventually("\(kind): the EXITIDLE turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
            do {
                try await eventually("", timeout: 4) {
                    bench.entryTexts(role: .system).contains {
                        $0.contains("exited while idle") && $0.contains("session store is unreadable")
                    }
                }
            } catch {
                violations.append("\(kind) idle exit: no notice said the session process left; system entries \(bench.entryTexts(role: .system).suffix(2))")
            }
            completed = bench.turnCompletedCount
            try bench.pressReturn("PLAIN again")
            do {
                try await eventually("", timeout: 8) {
                    bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
                        && bench.spawns > spawnsBefore
                }
            } catch {
                violations.append("\(kind) idle exit: the next message did not start a fresh process (spawns \(bench.spawns))")
            }
        }
        try expect(violations.isEmpty, "silence must be modelled: " + violations.joined(separator: " | "))
        return "claude, codex and pi each read 'Retrying (2/5)' through a provider retry and 'No output for 1m · still running' after a quiet minute with no tool open; a claude or pi session process that left between turns said so with its stderr, and the next message started a fresh one"
    }

    /// N1 — a turn the provider starts on its own after a Stop must not inherit
    /// that Stop. It used to: the leftover flag disarmed the no-result safety
    /// net, and a runner that returned without a result left the tile Working
    /// with no runner, forever.
    static func checkUnsolicitedTurnAfterStopSettles() async throws -> String {
        // Steering, like every production session runner: Stop INTERRUPTS it
        // and the session stays in the idle pool, which is where claude's
        // promoted steer becomes an unsolicited turn.
        final class UnsolicitedAfterStopRunner: AgentUnsolicitedTurnReporting, AgentSteeringRunning, @unchecked Sendable {
            private let lock = NSLock()
            private let released = DispatchSemaphore(value: 0)
            private var pending = false
            private var unsolicitedHandler: (@Sendable () -> Void)?
            private var liveHandler: (@Sendable (AgentRuntimeEvent) -> Void)?
            var acceptsSteerNow: Bool { lock.withLock { liveHandler != nil } }
            var hasBackgroundWork: Bool { false }
            func steer(_ prompt: AgentPrompt, id: UUID) throws { throw AgentSteerNotAccepted("check") }
            func observeSteerDispositions(_ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void) {}
            func interrupt() throws {
                // The provider promoted something to its own next turn just as
                // the user stopped this one.
                let handler = lock.withLock { () -> (@Sendable (AgentRuntimeEvent) -> Void)? in
                    pending = true
                    return liveHandler
                }
                handler?(.turnCompleted(threadId: "provider", turnId: "prompted", outcome: .interrupted, errorMessage: nil))
                released.signal()
            }
            var keepsSessionAliveBetweenTurns: Bool { true }
            var canAcceptAnotherTurn: Bool { true }
            var hasUnsolicitedTurn: Bool { lock.withLock { pending } }
            func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
                lock.withLock { liveHandler = onEvent }
                onEvent(.turnStarted(threadId: "provider", turnId: "prompted"))
                released.wait()
                lock.withLock { liveHandler = nil }
            }
            func stop() { released.signal() }
            func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
            func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
            var commandCapabilities: AgentSessionCommandCapabilities { ScriptedAgentRunner(script: []).commandCapabilities }
            func observeUnsolicitedTurns(_ handler: @escaping @Sendable () -> Void) {
                lock.withLock { unsolicitedHandler = handler }
            }
            func continueUnsolicitedTurn(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
                lock.withLock { pending = false }
                onEvent(.turnStarted(threadId: "provider", turnId: "unsolicited"))
                // …and the process leaves without a result.
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-presence-n1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = UnsolicitedAfterStopRunner()
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in runner })
        let config = AgentModelConfig.resolvedFromDefaults()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
        defer { supervisor.stopAll() }
        try expect(supervisor.send("go", to: id), "N1: the prompt was refused")
        try await eventually("N1: the prompted turn never started") { supervisor.turnSnapshot(for: id)?.state == .working }
        try expect(await supervisor.accept(.stop, for: id) == .accepted, "N1: Stop was refused")
        // The interrupt lands, the session returns to the pool, the provider's
        // own next turn is adopted and ends without a result.
        try? await eventually("", timeout: 3) {
            !supervisor.isRunning(id) && supervisor.turnPresence(for: id)?.submission ?? 0 >= 2
                && supervisor.turnPresence(for: id)?.phase.isTerminal == true
        }
        let state = supervisor.turnSnapshot(for: id)?.state
        try expect(state != .working && !supervisor.isRunning(id),
                   "N1: an unsolicited turn after a Stop that ended without a result left the agent \(String(describing: state)) (running \(supervisor.isRunning(id))) — stuck Working with no runner")
        try expect(supervisor.turnPresence(for: id)?.settleCause == .processLost,
                   "N1: the unsolicited turn's end must read as the process leaving, got \(String(describing: supervisor.turnPresence(for: id)?.phase))")
        return "an unsolicited turn after a Stop that ended without a result settled as process-lost instead of Working forever"
    }


    /// A parent's result is a turn boundary, not the end of a persistent
    /// Claude session's background child.
    ///
    /// The first three sections run the PRODUCTION runner and translator
    /// against the fake claude: whether a child is still running is claude's
    /// own stream to decide (`Fixtures/claude-async-subagent.jsonl`, replayed),
    /// never a flag a test runner sets. The scripted runner after them only
    /// drives the supervisor's session-ending paths, which no stream can reach.
    static func checkMirroredBackgroundChildLifetime(originalPath: String) async throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/claude-async-subagent.jsonl")
        for mode in ["async-launch", "shell-job-holds-no-child", "shell-job-reaped"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("array-presence-stream-\(mode)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try AgentSteeringQAFakes.install(.claude, in: bin)
            try FileManager.default.copyItem(at: fixture, to: bin.appendingPathComponent("replay.jsonl"))
            let work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            setenv("PATH", "\(bin.path):\(originalPath)", 1)
            defer { setenv("PATH", originalPath, 1) }
            let supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root),
                makeRunner: AgentSupervisor.productionRunner,
                idleRunnerTimeout: mode == "shell-job-reaped" ? 0.3 : 60)
            defer { supervisor.stopAll() }
            let parent = supervisor.spawn(role: nil, prompt: nil, cwd: work,
                harness: .claudeCode, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
            switch mode {
            case "async-launch":
                try expect(supervisor.send("REPLAY", to: parent), "\(mode): parent refused")
                let child = AgentID(rawValue: AgentRecord.observedChildID(
                    parentAgentID: parent.rawValue, toolUseID: "toolu_0164hvbb7oKHD8HqnBRJVh8E"))
                try await eventually("\(mode): the background child was never adopted") { supervisor.records[child] != nil }
                try await eventually("\(mode): the parent's launching turn never ended") {
                    supervisor.records[parent]?.latestTerminalEvent != nil
                }
                try expect(supervisor.records[child]?.latestTerminalEvent == nil
                           && supervisor.turnSnapshot(for: child)?.state == .working,
                    "\(mode): the async_launched acknowledgement settled the background child at launch (\(String(describing: supervisor.records[child]?.latestTerminalEvent?.outcome)))")
                try await eventually("\(mode): the child's own notification, after the parent's result, never settled it") {
                    supervisor.records[child]?.latestTerminalEvent?.outcome == .succeeded
                }
                try expect(supervisor.lastActivity(for: child) != nil,
                    "\(mode): the headless child's frames did not move its last activity")
            case "shell-job-holds-no-child":
                try expect(supervisor.send("BACKGROUND job", to: parent), "\(mode): parent refused")
                try await eventually("\(mode): parent did not start") { supervisor.isRunning(parent) }
                guard let child = supervisor.handleSpawnRequest(SpawnRequest(
                    role: "general-purpose", prompt: "foreground child", isolated: false,
                    sourceItemID: "toolu_never_answered", observedOnly: true), from: parent) else {
                    throw Failure(description: "presence: \(mode): child was not adopted")
                }
                supervisor.qaDeliver(.turnStarted(threadId: "child", turnId: "c"), to: child)
                try await eventually("\(mode): a parent with only a shell job running left its unanswered child working") {
                    supervisor.records[child]?.latestTerminalEvent?.outcome == .interrupted
                }
            default:
                try expect(supervisor.send("BACKGROUND job", to: parent), "\(mode): parent refused")
                try await eventually("\(mode): the shell job never started") {
                    AgentSteeringQAFakes.backgroundPid(in: bin) != nil
                }
                let pid = AgentSteeringQAFakes.backgroundPid(in: bin)
                try await eventually("\(mode): a shell job alone kept the idle session from the reaper", timeout: 4) {
                    pid.map { kill($0, 0) != 0 } ?? false
                }
            }
        }
        return try await checkMirroredChildSessionEnds()
            + "; a background child stays working past its launch acknowledgement and the parent's result and settles on its own notification, and a shell job never holds a child or the session open"
    }

    /// `.plans/87` Step 3.4 — a Codex child is running only while its session
    /// is. The runner here is the provider's whole family in one process, and
    /// the process ends with a grandchild's turn still open and no word about
    /// it, as a crash leaves things.
    static func checkCodexDescendantsEndWithSession() async throws -> String {
        final class FamilyRunner: AgentRunning, ProviderSubagentActivityObserving, @unchecked Sendable {
            private let lock = NSLock()
            private var activity: (@Sendable (ProviderSubagentActivity) -> Void)?
            var keepsSessionAliveBetweenTurns: Bool { false }
            var canAcceptAnotherTurn: Bool { true }
            var commandCapabilities: AgentSessionCommandCapabilities { ScriptedAgentRunner(script: []).commandCapabilities }
            func observeProviderSubagentActivity(_ handler: @escaping @Sendable (ProviderSubagentActivity) -> Void) {
                lock.withLock { activity = handler }
            }
            func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
                let send = lock.withLock { activity }
                onEvent(.turnStarted(threadId: "root", turnId: "root-turn"))
                send?(.primaryThread(providerThreadID: "root"))
                send?(.childAnnounced(parentProviderThreadID: "root", childProviderThreadID: "child",
                                      sourceItemID: "call-child", displayLabel: "child"))
                send?(.threadEvent(providerThreadID: "child", event: .turnStarted(threadId: "child", turnId: "c")))
                send?(.childAnnounced(parentProviderThreadID: "child", childProviderThreadID: "grandchild",
                                      sourceItemID: "call-grandchild", displayLabel: "grandchild"))
                send?(.threadEvent(providerThreadID: "grandchild", event: .turnStarted(threadId: "grandchild", turnId: "g")))
                send?(.threadEvent(providerThreadID: "child", event: .turnCompleted(threadId: "child", turnId: "c", outcome: .completed, errorMessage: nil)))
                Thread.sleep(forTimeInterval: 0.2)
                onEvent(.turnCompleted(threadId: "root", turnId: "root-turn", outcome: .completed, errorMessage: nil))
            }
            func stop() {}
            func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
            func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-presence-codex-family-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
                                         makeRunner: { _ in FamilyRunner() })
        defer { supervisor.stopAll() }
        let parent = supervisor.spawn(role: nil, prompt: nil, cwd: root,
            harness: .codex, model: "openai-codex/gpt-5.6-sol", thinking: "low")
        try expect(supervisor.send("delegate", to: parent), "codex family: parent refused")
        let child = AgentID(rawValue: AgentRecord.observedChildID(parentAgentID: parent.rawValue, toolUseID: "call-child"))
        let grandchild = AgentID(rawValue: AgentRecord.observedChildID(parentAgentID: child.rawValue, toolUseID: "call-grandchild"))
        try await eventually("codex family: the grandchild was never adopted") { supervisor.records[grandchild] != nil }
        try await eventually("codex family: the session never ended") {
            !supervisor.isRunning(parent) && supervisor.records[parent]?.latestTerminalEvent != nil
        }
        try await Task.sleep(for: .milliseconds(80))
        try expect(supervisor.records[child]?.latestTerminalEvent?.outcome == .succeeded,
                   "codex family: the child's own completion must stand, got \(String(describing: supervisor.records[child]?.latestTerminalEvent?.outcome))")
        try expect(supervisor.records[grandchild]?.latestTerminalEvent?.outcome == .interrupted
                   && supervisor.turnSnapshot(for: grandchild)?.state != .working,
                   "codex family: a grandchild whose session ended was left \(String(describing: supervisor.turnSnapshot(for: grandchild)?.state)) with outcome \(String(describing: supervisor.records[grandchild]?.latestTerminalEvent?.outcome))")
        return "a Codex descendant still open when its session ends settles interrupted; a finished one keeps its outcome"
    }

    /// `.plans/87` Step 3.6 — one last-activity time per agent, owned by the
    /// supervisor: every timeline frame and streamed delta moves it, at most
    /// once a second, and a meter reading does not.
    static func checkLastActivityMovesOnFrames() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-presence-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
                                         makeRunner: { _ in ScriptedAgentRunner(script: []) })
        let config = AgentModelConfig.resolvedFromDefaults()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try expect(supervisor.lastActivity(for: id) == nil, "activity: a fresh agent has no activity yet")
        supervisor.qaDeliver(.turnStarted(threadId: "t", turnId: "a"), to: id, now: t0)
        try expect(supervisor.lastActivity(for: id) == t0, "activity: a turn frame did not stamp last activity")
        supervisor.qaDeliver(.contentDelta(threadId: "t", turnId: "a", streamKind: .assistant, delta: "x"),
                             to: id, now: t0.addingTimeInterval(0.4))
        try expect(supervisor.lastActivity(for: id) == t0, "activity: a delta inside the same second must be throttled")
        supervisor.qaDeliver(.contentDelta(threadId: "t", turnId: "a", streamKind: .assistant, delta: "y"),
                             to: id, now: t0.addingTimeInterval(1.2))
        try expect(supervisor.lastActivity(for: id) == t0.addingTimeInterval(1.2),
                   "activity: streaming a second later did not move last activity")
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: "t", snapshot: TokenUsageSnapshot(inputTokens: 1, outputTokens: 1, totalCostUsd: nil)),
                             to: id, now: t0.addingTimeInterval(5))
        try expect(supervisor.lastActivity(for: id) == t0.addingTimeInterval(1.2),
                   "activity: a meter reading is not activity")
        return "last activity moves on frames and streaming, once a second, and not on meter readings"
    }

    /// The supervisor's session-ending paths, which settle children no stream
    /// can: exit, reap, settings, /clear, dead reuse and stopAll.
    private static func checkMirroredChildSessionEnds() async throws -> String {
        final class BackgroundRunner: AgentSteeringRunning, AgentIdleExitReporting, @unchecked Sendable {
            private let lock = NSLock()
            private let gate = DispatchSemaphore(value: 0)
            private var background = true
            private var alive = true
            private var idleExitHandler: (@Sendable (Int32, String?, Bool) -> Void)?
            var acceptsSteerNow: Bool { false }
            var hasBackgroundWork: Bool { lock.withLock { background } }
            var hasRunningSubagents: Bool { lock.withLock { background } }
            var keepsSessionAliveBetweenTurns: Bool { true }
            var canAcceptAnotherTurn: Bool { lock.withLock { alive } }
            var commandCapabilities: AgentSessionCommandCapabilities { ScriptedAgentRunner(script: []).commandCapabilities }
            func steer(_ prompt: AgentPrompt, id: UUID) throws { throw AgentSteerNotAccepted("check") }
            func observeSteerDispositions(_ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void) {}
            func interrupt() throws { gate.signal() }
            func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
                onEvent(.turnStarted(threadId: "provider", turnId: "background-parent"))
                gate.wait()
                onEvent(.turnCompleted(threadId: "provider", turnId: "background-parent", outcome: .completed, errorMessage: nil))
            }
            func finishParent() { gate.signal() }
            func finishBackground() { lock.withLock { background = false } }
            func markSessionDead() { lock.withLock { alive = false } }
            func stop() { lock.withLock { alive = false }; gate.signal() }
            func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
            func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
            func observeIdleExit(_ handler: @escaping @Sendable (Int32, String?, Bool) -> Void) {
                lock.withLock { idleExitHandler = handler }
            }
            func exitWhileIdle() {
                let handler = lock.withLock { () -> (@Sendable (Int32, String?, Bool) -> Void)? in
                    alive = false
                    return idleExitHandler
                }
                handler?(0, nil, true)
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-presence-background-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func child(_ supervisor: AgentSupervisor, _ parent: AgentID, _ key: String) throws -> AgentID {
            guard let id = supervisor.handleSpawnRequest(SpawnRequest(
                role: "general-purpose", prompt: "background witness", isolated: false,
                sourceItemID: key, observedOnly: true), from: parent) else {
                throw Failure(description: "presence: background child was not adopted")
            }
            supervisor.qaDeliver(.turnStarted(threadId: "child", turnId: key), to: id)
            return id
        }
        for mode in ["child-result", "idle-exit", "idle-reap", "no-background", "settings-change", "clear", "dead-reuse", "stop-all"] {
            let runner = BackgroundRunner()
            if mode == "no-background" { runner.finishBackground() }
            let supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root.appendingPathComponent(mode)),
                makeRunner: { _ in runner }, idleRunnerTimeout: mode == "idle-reap" ? 0.08 : 60)
            defer { supervisor.stopAll() }
            let parent = supervisor.spawn(role: nil, prompt: nil, cwd: root,
                harness: .claudeCode, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
            try expect(supervisor.send("parent", to: parent), "\(mode): parent refused")
            try await eventually("\(mode): parent did not start") { supervisor.turnSnapshot(for: parent)?.state == .working }
            let id = try child(supervisor, parent, "child-\(mode)")
            runner.finishParent()
            try await eventually("\(mode): parent did not reach idle") { !supervisor.isRunning(parent) }
            if mode == "no-background" {
                try expect(supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted,
                    "parent without background work must close an unfinished mirrored child")
                continue
            }
            try expect(supervisor.turnSnapshot(for: id)?.state == .working
                       && supervisor.records[id]?.latestTerminalEvent == nil,
                "\(mode): a persistent parent's result interrupted its still-running background child")
            switch mode {
            case "child-result":
                supervisor.qaDeliver(.turnCompleted(threadId: "child", turnId: "child-\(mode)",
                    outcome: .completed, errorMessage: nil), to: id)
                try expect(supervisor.records[id]?.latestTerminalEvent?.outcome == .succeeded,
                    "the background child's real completion must remain succeeded")
            case "idle-exit":
                runner.exitWhileIdle()
                try await eventually("matching idle session exit did not interrupt the mirrored child") {
                    supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted
                }
                let newer = try child(supervisor, parent, "child-after-exit")
                runner.exitWhileIdle()
                // DispatchQueue.main delivery must have had a chance to arrive.
                try await Task.sleep(for: .milliseconds(80))
                try expect(supervisor.turnSnapshot(for: newer)?.state == .working,
                    "a stale exited session callback interrupted a newer mirrored child")
            case "settings-change":
                try expect(!supervisor.setProviderSettings(agentID: parent, thinking: "low")
                           && runner.canAcceptAnotherTurn
                           && supervisor.turnSnapshot(for: id)?.state == .working,
                    "unchanged provider settings must preserve the owning session and background child")
                try expect(supervisor.setProviderSettings(agentID: parent, thinking: "medium"),
                    "the actual provider effort change was refused")
                try expect(!runner.canAcceptAnotherTurn
                           && supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted,
                    "provider settings killed the persistent session but left its background child working")
                let newer = try child(supervisor, parent, "child-after-settings")
                try expect(supervisor.setProviderSettings(agentID: parent, thinking: "high")
                           && supervisor.turnSnapshot(for: newer)?.state == .working,
                    "a settings change with no pooled session must not interrupt a newer child")
            case "clear":
                let invocation = AgentCommandInvocation(descriptorID: "array:clear", name: "clear", surface: .array)
                try expect(await supervisor.accept(.providerCommand(invocation), for: parent) == .accepted,
                    "the actual /clear command was refused")
                try expect(!runner.canAcceptAnotherTurn
                           && supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted
                           && supervisor.records[id]?.parentAgentID == nil,
                    "/clear killed and detached the persistent session's child without interrupting it")
                let newer = try child(supervisor, parent, "child-after-clear")
                try expect(await supervisor.accept(.providerCommand(invocation), for: parent) == .accepted
                           && supervisor.turnSnapshot(for: newer)?.state == .working,
                    "/clear with no pooled session must not interrupt a newer child")
            case "dead-reuse":
                runner.markSessionDead()
                try expect(supervisor.send("replacement turn", to: parent),
                    "replacement turn after a dead idle session was refused")
                try expect(supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted,
                    "discarding an unusable pooled session left its background child working")
            case "stop-all":
                supervisor.stopAll()
                try expect(!runner.canAcceptAnotherTurn
                           && supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted,
                    "stopAll killed the pooled session but left its background child working")
            default:
                try await Task.sleep(for: .milliseconds(220))
                try expect(runner.canAcceptAnotherTurn && supervisor.turnSnapshot(for: id)?.state == .working,
                    "idle reap must defer while the runner reports background work")
                runner.finishBackground()
                try await eventually("actual idle reap did not close the unfinished mirrored child") {
                    !runner.canAcceptAnotherTurn && supervisor.records[id]?.latestTerminalEvent?.outcome == .interrupted
                }
            }
        }
        return "persistent Claude children survive a parent result, settle on their own result, and interrupt only on an owning session exit/reap or a result without background work"
    }

    // MARK: - P1-5 — the status line stays honest through long and failed tools

    static func checkToolClockScopeIsTranscriptLocal() throws -> String {
        guard let blockID = AgentNodeID(rawValue: "reused-node-after-resume") else {
            throw Failure(description: "tool clock witness needs a valid reused node ID")
        }
        let firstTranscript = AgentToolClockScope()
        let forkedTranscript = AgentToolClockScope()
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let forkedStart = Date(timeIntervalSince1970: 2_000)
        let realClock = ToolRowLiveClock.now
        ToolRowLiveClock.now = { firstStart }
        let firstRow = ToolCallView(frame: .zero)
        let forkedRow = ToolCallView(frame: .zero)
        defer {
            ToolRowLiveClock.shared.remove(firstRow)
            ToolRowLiveClock.shared.remove(forkedRow)
            ToolRowLiveClock.now = realClock
        }
        var firstContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        firstContext.toolClockScope = firstTranscript
        var forkedContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        forkedContext.toolClockScope = forkedTranscript
        let runningPayload = AgentToolCallPayload(name: "Bash", summary: "Running", status: .inProgress)

        firstRow.apply(blockID: blockID, payload: runningPayload, context: firstContext)
        try expect(firstRow.tickLiveClock(at: firstStart.addingTimeInterval(12))
                   && firstRow.statusLabel.stringValue.contains("12s"),
                   "a rendered tool clock advances from the first running observation")
        ToolRowLiveClock.now = { forkedStart }
        forkedRow.apply(blockID: blockID, payload: runningPayload, context: forkedContext)
        try expect(forkedRow.tickLiveClock(at: forkedStart.addingTimeInterval(12))
                   && forkedRow.statusLabel.stringValue.contains("12s"),
                   "the same node ID in another transcript renders its own elapsed time")

        ToolRowLiveClock.now = { firstStart.addingTimeInterval(12) }
        try expect(firstRow.tickLiveClock(at: ToolRowLiveClock.now()),
                   "the first running row remains registered with the shared ticker")
        try expect(firstRow.statusLabel.stringValue.contains("12s"),
                   "re-rendering time advances from the first transcript's start")
        let completedPayload = AgentToolCallPayload(name: "Bash", summary: "Done", status: .completed)
        firstRow.apply(blockID: blockID, payload: completedPayload, context: firstContext)
        try expect(!firstRow.tickLiveClock(at: firstStart.addingTimeInterval(24)),
                   "settling the first transcript stops its rendered clock")
        try expect(forkedRow.tickLiveClock(at: forkedStart.addingTimeInterval(12)),
                   "settling one transcript leaves the other row registered and running")
        try expect(forkedRow.statusLabel.stringValue.contains("12s"),
                   "the forked row still reads elapsed time after its sibling settles")
        return "two rendered rows with one reused node ID kept independent clocks; settling one left the other row and its elapsed time live"
    }

    static func toolRows(in view: NSView) -> [ToolCallView] {
        var found: [ToolCallView] = []
        var stack: [NSView] = [view]
        while let next = stack.popLast() {
            if let row = next as? ToolCallView { found.append(row) }
            stack.append(contentsOf: next.subviews)
        }
        return found
    }

    static func checkLongToolsStayHonest(originalPath: String) async throws -> String {
        var violations: [String] = []
        let realClock = ToolRowLiveClock.now
        defer { ToolRowLiveClock.now = realClock }
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            try await Task.sleep(for: .milliseconds(300))

            // One failed tool mid-turn is a step, not the turn's verdict.
            var completed = bench.turnCompletedCount
            try bench.pressReturn("TOOLFAIL then carry on")
            try await eventually("\(kind): the failed tool never reported") {
                bench.events.contains { if case .itemCompleted(_, _, _, .failed) = $0 { return true } else { return false } }
            }
            var failedReadings: Set<String> = []
            while bench.turnCompletedCount == completed {
                bench.tile.qaRefreshLocation(at: Date())
                if bench.supervisor.turnPresence(for: bench.id)?.isWorking == true,
                   bench.tile.qaCompactStatusPhase == .failed || bench.tile.qaCompactStatusActivityText.contains("Failed") {
                    failedReadings.insert("phase \(String(describing: bench.tile.qaCompactStatusPhase)) / '\(bench.tile.qaCompactStatusActivityText)'")
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            if !failedReadings.isEmpty {
                violations.append("\(kind) failed tool: the status line read Failed while the turn ran on: \(failedReadings.sorted())")
            }
            try await eventually("\(kind): the TOOLFAIL turn never settled") { !bench.supervisor.isRunning(bench.id) }

            // A long quiet tool keeps its verb and its clock.
            completed = bench.turnCompletedCount
            try bench.pressReturn("SLOW job")
            try await eventually("\(kind): the SLOW tool never opened") {
                if case .tool? = bench.supervisor.turnPresence(for: bench.id)?.phase { return true }
                return false
            }
            try await Task.sleep(for: .milliseconds(200))
            let later = Date().addingTimeInterval(60)
            bench.tile.qaRefreshLocation(at: later)
            let tail = bench.tile.qaTailStatusText
            if tail.hasPrefix("Responding") || tail.hasPrefix("Thinking") || tail.hasPrefix("No output") || !tail.contains("1m") {
                violations.append("\(kind) long tool: a minute into an open tool the tail read '\(tail)', phase \(String(describing: bench.tile.qaCompactStatusPhase))")
            }
            // The row itself carries a live clock.
            bench.window.layoutIfNeeded()
            bench.tile.layoutSubtreeIfNeeded()
            let running = toolRows(in: bench.tile).filter { !$0.statusLabel.stringValue.contains("✓") }
            ToolRowLiveClock.now = { realClock().addingTimeInterval(75) }
            ToolRowLiveClock.shared.tick()
            let labels = running.map(\.statusLabel.stringValue)
            if running.isEmpty || !labels.contains(where: { $0.contains("1m 15s") || $0.contains("1m 1") }) {
                violations.append("\(kind) long tool: the running row shows no live clock: \(labels)")
            }
            ToolRowLiveClock.now = realClock
            _ = await bench.supervisor.accept(.stop, for: bench.id)
            try await eventually("\(kind): the SLOW turn never stopped") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
        }
        try expect(violations.isEmpty, "long tools must stay honest: " + violations.joined(separator: " | "))
        return "on claude, codex and pi a failed tool mid-turn never turned the status line Failed, a minute into an open tool the tail kept its verb and clock, and the running row carried its own live clock"
    }

    // MARK: - P1-6 — the user's own actions visibly land

    static func userEntries(_ bench: Bench, containing text: String) -> Int {
        bench.entryTexts(role: .user).filter { $0.contains(text) }.count
    }

    static func checkOwnActionsVisiblyLand(originalPath: String) async throws -> String {
        var violations: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let bench = try Bench(kind, originalPath: originalPath)
            defer { bench.tearDown() }
            try await Task.sleep(for: .milliseconds(300))

            // 1. Return scrolls a reader who had scrolled up back to the live edge.
            let filler = (1...80).map { "Line \($0) of an earlier, long answer." }.joined(separator: "\n\n")
            bench.tile.ingest(.contentDelta(threadId: bench.tile.qaThreadIdForChecks, turnId: "earlier",
                                            streamKind: .assistant, delta: filler))
            bench.tile.ingest(.turnCompleted(threadId: bench.tile.qaThreadIdForChecks, turnId: "earlier",
                                             outcome: .completed, errorMessage: nil))
            bench.tile.qaFlushStreamingMarkupForChecks(final: true)
            try await Task.sleep(for: .milliseconds(400))
            bench.window.layoutIfNeeded()
            bench.tile.layoutSubtreeIfNeeded()
            bench.tile.qaScrollTranscript(toY: 0)
            guard bench.tile.qaTranscriptForChecks?.qaIsNearBottom == false else {
                throw Failure(description: "presence: \(kind): the filler did not make the transcript scrollable — the scroll witness would pass vacuously")
            }
            var completed = bench.turnCompletedCount
            try bench.pressReturn("PLAIN hello")
            bench.window.layoutIfNeeded()
            if bench.tile.qaTranscriptForChecks?.qaIsNearBottom != true {
                violations.append("\(kind) scroll: Return left the reader scrolled up, away from their own message")
            }
            try await eventually("\(kind): the PLAIN turn never ended") {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }

            // 2. A steer is on screen the moment it is accepted — pending, in the
            //    rail docked under the transcript (2026-10-13 owner review), or
            //    already a transcript message if the provider confirmed it that
            //    fast — and exactly once. When the provider takes it, it is a
            //    transcript message, once, and the pending rail has let it go.
            completed = bench.turnCompletedCount
            try bench.pressReturn("TOOL work")
            try await eventually("\(kind): the TOOL turn never became steerable") {
                bench.supervisor.turnSnapshot(for: bench.id)?.capabilities.canSteer == true
                    && bench.supervisor.turnPresence(for: bench.id)?.isWorking == true
            }
            try bench.pressReturn("change course")
            try await eventually("\(kind): the steer was never accepted") {
                ((try? bench.composer.qaDraftText) ?? "x").isEmpty
            }
            let pendingAtAcceptance = try bench.composer.qaQueueRail.qaSteerTexts.filter { $0 == "change course" }.count
            let shownAtAcceptance = pendingAtAcceptance + userEntries(bench, containing: "change course")
            if shownAtAcceptance != 1 {
                violations.append("\(kind) steer: an accepted steer must show exactly once at once, pending or sent — rail \(pendingAtAcceptance), transcript \(userEntries(bench, containing: "change course"))")
            }
            try await eventually("\(kind): the steered turn never ended", timeout: 10) {
                bench.turnCompletedCount > completed && !bench.supervisor.isRunning(bench.id)
            }
            try await Task.sleep(for: .milliseconds(200))
            if userEntries(bench, containing: "change course") != 1 {
                violations.append("\(kind) steer: after the provider took it the steer reads \(userEntries(bench, containing: "change course")) times")
            }
            if try bench.composer.qaQueueRail.qaSteerTexts.contains("change course") {
                violations.append("\(kind) steer: a delivered steer is still pending in the rail")
            }

            // 3. Array's own command reply reaches the live tile.
            let before = bench.entryTexts(role: .system).count
            let status = await bench.supervisor.accept(.providerCommand(AgentCommandInvocation(
                descriptorID: "array:status", name: "status", surface: .array)), for: bench.id)
            try expect(status == .accepted, "\(kind): /status was refused: \(status)")
            try await Task.sleep(for: .milliseconds(200))
            if !bench.entryTexts(role: .system).dropFirst(before).contains(where: { $0.contains("Harness:") }) {
                violations.append("\(kind) /status: the reply never reached the live tile")
            }
        }
        try expect(violations.isEmpty, "the user's own actions must visibly land: " + violations.joined(separator: " | "))
        return "on claude, codex and pi Return brought a scrolled-up reader to their own message, a steer was in the transcript the moment it was accepted and once after the provider took it, and /status answered in the live tile"
    }
}
