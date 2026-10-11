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
    summary.append(try await AgentPresenceChecks.checkSpawnWindowNeverReadsIdle(originalPath: originalPath))
    summary.append(try await AgentPresenceChecks.checkRefusalsSayWhyEveryTime(originalPath: originalPath))
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
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
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
}
