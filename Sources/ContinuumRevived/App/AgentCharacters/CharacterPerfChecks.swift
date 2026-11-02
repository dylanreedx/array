import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Darwin

// Plan: .plans/110-agent-characters/README.md, slice 8.
//
// `--character-perf-check`: characters ON versus OFF at scale, offscreen, A/B/A/B in
// one process. 80 agent tiles attached to a real supervisor (60 of them working,
// fed through `deliver`) on a real canvas, and a 60-row sidebar. Three phases per
// arm: idle, pan and zoom, the gestures dispatched through the window as ⌘-less
// and ⌘ precise scroll events.
//
// Asserted (counts, per docs/internals/performance.md): tile-bar layouts and draws,
// sidebar card layouts and sprite installs are equal ON and OFF in every phase, and
// gestures install nothing. Reported (times, not gated): main-thread CPU per phase
// and Array-owned time per camera step (event + layout + display), with the CA
// commit (`CATransaction.flush`) timed separately — it is not Array CPU.
//
// Blind spot, stated: an offscreen window is never composited, so WindowServer
// and presented frames are NOT measured here.
@MainActor
enum CharacterPerfChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct Phase {
        var cpu: Double = 0              // main-thread CPU seconds
        var wall: Double = 0
        var steps: [Double] = []         // Array-owned ms per camera step
        var flush: [Double] = []         // CA commit ms per step
        var barLayouts = 0, barDraws = 0, cellLayouts = 0, installs = 0
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-character-perf-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayCharacterPerf-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }   // offscreen windows are never .visible
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        // ARRAY_CHARACTER_PERF_SIZE=medium|large: the same A/B at a bigger size.
        let size = ProcessInfo.processInfo.environment["ARRAY_CHARACTER_PERF_SIZE"]
            .flatMap(AgentCharacterConfig.Size.init(rawValue:)) ?? .small
        defaults.set(size.rawValue, forKey: AgentCharacterConfig.sizeKey)
        controller.adopt(defaults: defaults)

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }

        // The canvas: 80 agent tiles, all in view at zoom 0.45.
        // ARRAY_CHARACTER_PERF_ZOOM: the resting zoom instead (1: the few tiles in
        // view at 100%, where a bigger character size makes the bar taller).
        let restingZoom = ProcessInfo.processInfo.environment["ARRAY_CHARACTER_PERF_ZOOM"].flatMap(Double.init) ?? 0.45
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: restingZoom), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        var views: [ManagedAgentTileNSView] = []
        var workingAgents: [(AgentID, Int)] = []
        let kinds: [(ItemKind, String)] = [(.fileChange, "Sources/App.swift"), (.mcpToolCall, "Grep"),
                                           (.mcpToolCall, "Read"), (.commandExecution, "Bash"), (.reasoning, "")]
        for n in 0..<80 {
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                                      model: "anthropic/claude-haiku-4-5-20251001", thinking: "low",
                                      displayName: "Agent \(n)")
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "Agent \(n)",
                            frame: TileFrame(x: Double(n % 10) * 350 + 20, y: Double(n / 10) * 260 + 20, width: 330, height: 240),
                            zPosition: .fromLegacyRank(n + 1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            view.attach(agentID: id, supervisor: supervisor)
            if n < 60 {
                let (kind, title) = kinds[n % kinds.count]
                supervisor.qaDeliver(.turnStarted(threadId: "t\(n)", turnId: "u\(n)"), to: id)
                supervisor.qaDeliver(.itemStarted(threadId: "t\(n)", itemId: "i\(n)", kind: kind, title: title), to: id)
                workingAgents.append((id, n))
            }
            views.append(view)
        }

        // The sidebar: 60 rows, mixed states, in its own window.
        final class Clock: @unchecked Sendable { var now = Date() }
        let clock = Clock()
        var now: Date { get { clock.now } set { clock.now = newValue } }
        func makeRows() -> [AgentInboxRow] { (0..<60).map { n -> AgentInboxRow in
            let state: InboxState = [.working, .working, .approval, .ready, .failed][n % 5]
            return AgentInboxRow(
                id: UUID(), title: "Agent \(n)", projectName: "Array", directoryName: "Array", state: state,
                model: ["claude-opus-5-5", "gpt-5.5", "pi/kimi-k2"][n % 3], branch: "agent/\(n)",
                elapsedStartedAt: state == .working ? now.addingTimeInterval(-60) : nil,
                createdAt: now.addingTimeInterval(-Double(n)),
                terminalEvent: state == .ready ? AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded,
                                                                    endedAt: now.addingTimeInterval(-600)) : nil,
                characterActivity: AgentCharacterActivity(action: AgentCharacterLoop.allCases[n % 5], lastOutputAt: now))
        } }
        let rowIDs = (0..<60).map { _ in UUID() }
        func rowsNow() -> [AgentInboxRow] {
            makeRows().enumerated().map { n, row in
                AgentInboxRow(id: rowIDs[n], title: row.title, projectName: row.projectName, directoryName: row.directoryName,
                              state: row.state, model: row.model, branch: row.branch, elapsedStartedAt: row.elapsedStartedAt,
                              createdAt: row.createdAt, terminalEvent: row.terminalEvent, characterActivity: row.characterActivity)
            }
        }
        let rows = rowsNow()
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        inbox.onRowAction = { _, _ in }
        let sideWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sideWindow.contentView = inbox
        sideWindow.orderFrontOffscreenForChecks()
        defer { sideWindow.orderOut(nil) }
        inbox.reload(rows: rows)
        inbox.layoutForQA()

        func settle(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            inbox.layoutForQA(); inbox.displayIfNeeded()
            CATransaction.flush()
        }
        // Supervisor events reach the tiles asynchronously; wait for them, not a clock.
        let ready = Date().addingTimeInterval(15)
        repeat { settle(0.25) } while views.filter({ $0.qaCharacterLayer?.isAnimating == true }).count < 60 && Date() < ready
        let working = views.filter { $0.qaCharacterLayer?.isAnimating == true }.count
        guard working >= 55 else { throw Failure(description: "only \(working) tile characters animate; the fixture is not working") }
        let sidebarSprites = inbox.visibleCharacterCellsForQA.filter { $0.characterLayerForQA.isAnimating }.count
        // The rows the list's one-second elapsed clock re-lays each tick: the
        // visible working ones and the seen finished ones.
        let sidebarTimedRows = inbox.visibleCharacterCellsForQA.filter {
            $0.rowForQA?.state == .working || ($0.rowForQA?.state == .ready && $0.rowForQA?.terminalEvent != nil)
        }.count

        func counters() -> (Int, Int, Int, Int) {
            (views.reduce(0) { $0 + $1.qaTitleBarLayoutPasses }, views.reduce(0) { $0 + $1.qaTitleBarDrawCount },
             AgentInbox96CellView.qaLayoutPassCount, CharacterSpriteLayer.installCount)
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1000
        /// Every working agent says something new (the same step, so the same
        /// plan), and the sidebar's rows are rebuilt at a fresh `now`: no agent
        /// crosses the 40 s quiet line mid-measurement. Done in both arms.
        var freshness = 0
        func freshen() {
            // A completed step advances the quiet clock; the next one is the same
            // kind, so the plan (and the sprite) does not change.
            freshness += 1
            for (id, n) in workingAgents {
                let (kind, title) = kinds[n % kinds.count]
                let previous = freshness == 1 ? "i\(n)" : "i\(n).\(freshness - 1)"
                supervisor.qaDeliver(.itemCompleted(threadId: "t\(n)", itemId: previous, kind: kind, status: .completed), to: id)
                supervisor.qaDeliver(.itemStarted(threadId: "t\(n)", itemId: "i\(n).\(freshness)", kind: kind, title: title), to: id)
            }
            now = Date()
            inbox.clock = { [clock] in clock.now }
            inbox.reload(rows: rowsNow())
        }
        func measure(_ phase: String, seconds: TimeInterval) throws -> Phase {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: restingZoom))
            freshen()
            settle(0.5)
            var result = Phase()
            let before = counters()
            let cpu0 = threadCPU(), t0 = Date()
            var step = 0
            let fixedSteps = phase == "zoom" ? 24 : 240
            while phase == "idle" ? Date().timeIntervalSince(t0) < seconds : step < fixedSteps {
                if phase == "idle" {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
                } else {
                    // The same sequence in every arm: out then back in (zoom), or a
                    // back-and-forth (pan), so the totals compare exactly.
                    let delta: Int32 = phase == "zoom" ? (step < 12 ? -6 : 6) : ((step / 30) % 2 == 0 ? -4 : 4)
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: delta, wheel2: phase == "pan" ? delta : 0, wheel3: 0) else { break }
                    if phase == "zoom" { cg.flags = .maskCommand }
                    cg.location = CGPoint(x: 800, y: screenHeight - 500)
                    let a = CACurrentMediaTime()
                    if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    canvas.layoutSubtreeIfNeeded()
                    canvas.displayIfNeeded()
                    let b = CACurrentMediaTime()
                    CATransaction.flush()
                    let c = CACurrentMediaTime()
                    result.steps.append((b - a) * 1000)
                    result.flush.append((c - b) * 1000)
                    step += 1
                    // A 60 Hz cadence: the rest of the frame is idle, like a real gesture.
                    let rest = 1.0 / 60 - (c - a)
                    if rest > 0 { RunLoop.current.run(until: Date().addingTimeInterval(rest)) }
                }
            }
            result.cpu = threadCPU() - cpu0
            result.wall = Date().timeIntervalSince(t0)
            let after = counters()
            (result.barLayouts, result.barDraws, result.cellLayouts, result.installs) =
                (after.0 - before.0, after.1 - before.1, after.2 - before.2, after.3 - before.3)
            return result
        }

        func setEnabled(_ on: Bool) {
            defaults.set(on, forKey: AgentCharacterConfig.enabledKey)
            controller.reload()
            settle(0.5)
        }
        var table: [String: [Phase]] = [:]
        // Profiling only: ARRAY_CHARACTER_PERF_ONLY=on|off runs one arm, so a
        // sampler sees that arm alone. The gate below needs both and is skipped.
        let only = ProcessInfo.processInfo.environment["ARRAY_CHARACTER_PERF_ONLY"]
        let arms = [true, false, true, false].filter { only == nil || ($0 ? "on" : "off") == only }
        for (round, on) in arms.enumerated() {
            setEnabled(on)
            _ = round
            for phase in ["idle", "pan", "zoom"] {
                table["\(on ? "on" : "off").\(phase)", default: []].append(try measure(phase, seconds: 4))
            }
        }

        // Gate on counts: characters add no layout, draw or install in any phase.
        var failures: [String] = []
        var lines: [String] = []
        func p(_ values: [Double], _ q: Double) -> Double {
            let sorted = values.sorted(); guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        if let only {
            return ["idle", "pan", "zoom"].map { phase in
                let runs = table["\(only).\(phase)"] ?? []
                let steps = runs.flatMap(\.steps)
                return String(format: "%@ %@ only: step p50 %5.2f p95 %5.2f ms", phase, only, p(steps, 0.5), p(steps, 0.95))
            }.joined(separator: "\n")
        }
        for phase in ["idle", "pan", "zoom"] {
            let on = table["on.\(phase)"]!, off = table["off.\(phase)"]!
            for (a, b) in zip(on, off) {
                if a.installs != 0 { failures.append("\(phase): \(a.installs) sprite installs with characters on") }
                // The same event sequence on and off: the bar and card work must match.
                // Cards get one tick of slack: the list's elapsed clock re-lays every
                // visible timed row once a second, and a window of a few seconds
                // catches one tick more or less whatever the characters do.
                let tickSlack = sidebarTimedRows
                if a.barLayouts > b.barLayouts || a.barDraws > b.barDraws || a.cellLayouts > b.cellLayouts + tickSlack {
                    failures.append("\(phase): characters caused layout or draw (bars \(a.barLayouts)/\(a.barDraws) on vs \(b.barLayouts)/\(b.barDraws) off, cards \(a.cellLayouts) vs \(b.cellLayouts))")
                }
            }
            for arm in ["on", "off"] {
                let runs = table["\(arm).\(phase)"]!
                let cpu = runs.reduce(0) { $0 + $1.cpu } / runs.reduce(0) { $0 + $1.wall } * 100
                let steps = runs.flatMap(\.steps), flush = runs.flatMap(\.flush)
                let layouts = runs.reduce(0) { $0 + $1.barLayouts }, draws = runs.reduce(0) { $0 + $1.barDraws }
                lines.append(String(format: "%@ %-4@ main-thread CPU %5.1f%%  step p50 %5.2f p95 %5.2f ms  CA commit p50 %5.2f p95 %5.2f ms  steps %4d  bar layouts %5d draws %5d  card layouts %d  installs %d",
                                    phase, arm, cpu, p(steps, 0.5), p(steps, 0.95), p(flush, 0.5), p(flush, 0.95), steps.count,
                                    layouts, draws, runs.reduce(0) { $0 + $1.cellLayouts }, runs.reduce(0) { $0 + $1.installs }))
            }
        }
        let report = (["Character perf (offscreen; WindowServer not measured), size \(size.rawValue), zoom \(restingZoom): 80 agent tiles (\(working) characters moving), 60 sidebar rows (\(sidebarSprites) visible moving), 2 x 4 s per arm and phase, A/B/A/B"] + lines)
            .joined(separator: "\n")
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? report.write(to: out.appendingPathComponent(size == .small ? "perf.txt" : "perf-\(size.rawValue).txt"), atomically: true, encoding: .utf8)
        guard failures.isEmpty else { throw Failure(description: report + "\n" + failures.joined(separator: "\n")) }
        return report
    }

    private static func threadCPU() -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1e6
            + TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1e6
    }
}
