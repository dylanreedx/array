import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

/// `--long-session-memory-check`: a long working session with many agents
/// streaming must hold flat memory once it has warmed up.
///
/// Dylan's 0.7.52 grew from 1.7 GB at 34 minutes to 3.8 GB at 12 hours, almost
/// all Malloc Small: about 3–4 MB a minute while agents worked.
///
/// Driven through production: a real `AppDelegate`, supervisor and
/// `ManagedAgentTileNSView`s wired by `wireManagedAgentTile`. Every turn is a
/// real `send` that starts a scripted runner, which streams what a coding agent
/// streams — reasoning, three tool calls with output, a markdown answer, token
/// usage. Every simulated hour two tiles close through `AppDelegate.deleteTile`
/// and two new agents open in their place, and a lead spawns a helper.
/// Memory is malloc bytes in use after each hour settles.
@MainActor
enum LongSessionMemoryChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static var agentCount: Int { env("ARRAY_LONG_SESSION_AGENTS") ?? 24 }
    static var hours: Int { env("ARRAY_LONG_SESSION_HOURS") ?? 5 }
    static var turnsPerHour: Int { env("ARRAY_LONG_SESSION_TURNS") ?? 10 }

    private static func env(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init)
    }

    static func mallocBytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    // MARK: - Workload

    /// One turn of a working coding agent, deterministic in `(agent, turn)`.
    /// About 8 KB of content: reasoning, three commands with output, and a
    /// markdown answer with a list, inline code and a fenced block.
    static func turnScript(agent: Int, turn: Int) -> [AgentRuntimeEvent] {
        let thread = "thread-\(agent)"
        let turnId = "turn-\(agent)-\(turn)"
        var events: [AgentRuntimeEvent] = [.turnStarted(threadId: thread, turnId: turnId)]

        let reasoningId = "reason-\(agent)-\(turn)"
        events.append(.itemStarted(threadId: thread, itemId: reasoningId, kind: .reasoning, title: nil))
        for chunk in 0..<10 {
            events.append(.contentDelta(threadId: thread, turnId: turnId, streamKind: .reasoning,
                                        delta: "Checking how module \(turn % 7) handles case \(chunk) before I change it. "))
        }
        events.append(.itemCompleted(threadId: thread, itemId: reasoningId, kind: .reasoning, status: .completed))

        for call in 0..<3 {
            let itemId = "cmd-\(agent)-\(turn)-\(call)"
            let command = "rg -n \"handle\(call)\" Sources/Module\(turn % 7)/File\(agent % 5).swift"
            events.append(.itemStarted(threadId: thread, itemId: itemId, kind: .commandExecution, title: command))
            for line in 0..<20 {
                events.append(.contentDelta(
                    threadId: thread, turnId: turnId, streamKind: .commandOutput,
                    delta: "Sources/Module\(turn % 7)/File\(agent % 5).swift:\(line * 13 + call): let value\(line) = handle\(call)(input: items[\(line)], turn: \(turn))\n"))
            }
            events.append(.itemCompleted(threadId: thread, itemId: itemId, kind: .commandExecution, status: .completed))
        }

        let answerId = "answer-\(agent)-\(turn)"
        events.append(.itemStarted(threadId: thread, itemId: answerId, kind: .assistantMessage, title: nil))
        var answer = "I traced `handle\(turn % 3)` through **Module\(turn % 7)** and found the cause.\n\n"
        for point in 0..<6 {
            answer += "- Step \(point): the call at `File\(agent % 5).swift:\(point * 17)` keeps a reference to `items[\(point)]` after the turn ends.\n"
        }
        answer += "\n```swift\nfunc handle\(turn % 3)(input: Item, turn: Int) -> Result {\n    guard input.isValid else { return .skipped }\n    return .done(input.id)\n}\n```\n\nThat fixes turn \(turn) for agent \(agent).\n"
        var index = answer.startIndex
        while index < answer.endIndex {
            let end = answer.index(index, offsetBy: 48, limitedBy: answer.endIndex) ?? answer.endIndex
            events.append(.contentDelta(threadId: thread, turnId: turnId, streamKind: .assistant,
                                        delta: String(answer[index..<end])))
            index = end
        }
        events.append(.itemCompleted(threadId: thread, itemId: answerId, kind: .assistantMessage, status: .completed))
        events.append(.turnCompleted(threadId: thread, turnId: turnId, outcome: .completed, errorMessage: nil))
        return events
    }

    /// The text one turn streams: what a transcript legitimately keeps.
    static func contentBytes(of script: [AgentRuntimeEvent]) -> Int {
        script.reduce(0) { total, event in
            switch event {
            case let .contentDelta(_, _, _, delta): return total + delta.utf8.count
            case let .itemStarted(_, _, _, title): return total + (title?.utf8.count ?? 0)
            default: return total
            }
        }
    }

    // MARK: - Run

    static func run() async throws -> String {
        setlinebuf(stdout)
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-long-session-memory-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("checkout", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: temporary) }

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.2), tiles: [], groups: [],
            lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        // Turns are numbered per agent so every runner streams that agent's
        // next turn; the supervisor builds a runner per turn, as it does for claude.
        final class WeakRunner { weak var runner: ScriptedAgentRunner?; init(_ r: ScriptedAgentRunner) { runner = r } }
        var runnersMade: [WeakRunner] = []
        var turnByAgent: [AgentID: Int] = [:]
        var streamedContent = 0
        var slotByAgent: [AgentID: Int] = [:]
        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentsSupport),
            makeRunner: { launch in
                let id = launch.record.id
                let turn = turnByAgent[id, default: 0]
                turnByAgent[id] = turn + 1
                let script = turnScript(agent: slotByAgent[id] ?? 99, turn: turn)
                streamedContent += contentBytes(of: script)
                let runner = ScriptedAgentRunner(script: script)
                runnersMade.append(WeakRunner(runner))
                return runner
            })
        let supervisor = delegate.agentSupervisor

        var nextSlot = 0
        var live: [(tile: Tile, agent: AgentID)] = []
        func openAgent() {
            let slot = nextSlot
            nextSlot += 1
            let position = live.count
            let tile = Tile(
                id: UUID(), kind: .managedAgent, title: "agent \(slot)",
                frame: TileFrame(x: Double(40 + (position % 8) * 560), y: Double(40 + (position / 8) * 460),
                                 width: 520, height: 420),
                zPosition: .fromLegacyRank(slot + 1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            let agent = supervisor.spawn(
                role: nil, prompt: nil, cwd: projectRoot, harness: .claudeCode,
                model: "anthropic/claude-sonnet-5-5", thinking: "medium", tileId: tile.id,
                displayName: "Session witness \(slot)")
            slotByAgent[agent] = slot
            delegate.wireManagedAgentTile(tile.id, agentID: agent)
            live.append((tile, agent))
        }
        for _ in 0..<agentCount { openAgent() }
        canvas.layoutSubtreeIfNeeded()

        /// Until memory stops moving: a transcript lays out after its turn
        /// ends, so a reading taken at once misses what that layout keeps.
        func settle() async {
            var last = mallocBytesInUse()
            var quiet = 0
            let deadline = Date().addingTimeInterval(45)
            while quiet < 3, Date() < deadline {
                _ = await waitUntil(timeout: 1, pollInterval: 0.1) { false }
                let now = mallocBytesInUse()
                quiet = abs(now - last) < 512 * 1024 ? quiet + 1 : 0
                last = now
            }
        }

        var helpers: [AgentID] = []
        var samples: [Int] = []
        var contentAtHour: [Int] = []
        var turnCount = 0
        await settle()
        let baseline = mallocBytesInUse()
        let started = Date()
        for hour in 0..<hours {
            for round in 0..<turnsPerHour {
                for entry in live {
                    let accepted = supervisor.send("Keep going on step \(round) of hour \(hour).", to: entry.agent)
                    try expect(accepted,
                               "hour \(hour) round \(round): the supervisor accepts the turn")
                }
                let idle = await waitUntil(timeout: 60, pollInterval: 0.05) {
                    live.allSatisfy { !supervisor.isRunning($0.agent) }
                }
                try expect(idle, "hour \(hour) round \(round): every agent finishes its turn")
                turnCount += live.count
            }
            // The session churns: two tiles close the way their × does, two
            // agents open, and a lead spawns a helper that runs one turn.
            for _ in 0..<2 {
                let closing = live.removeFirst()
                delegate.deleteTile(id: closing.tile.id)
            }
            openAgent()
            openAgent()
            let helper = supervisor.spawn(
                role: nil, prompt: "Help with hour \(hour).", cwd: projectRoot, harness: .claudeCode,
                model: "anthropic/claude-sonnet-5-5", thinking: "medium",
                parentAgentID: live[0].agent, displayName: "Helper \(hour)")
            slotByAgent[helper] = 900 + hour
            helpers.append(helper)
            _ = await waitUntil(timeout: 30, pollInterval: 0.05) { !supervisor.isRunning(helper) }
            canvas.layoutSubtreeIfNeeded()
            await settle()
            // A finished turn's runner goes with its turn. Each runner held the
            // supervisor's side-channel closures, which held the runner: every
            // turn of every agent leaked its runner and translator (0.7.52).
            let liveRunners = runnersMade.filter { $0.runner != nil }.count
            try expect(liveRunners <= live.count + helpers.count,
                       "hour \(hour + 1): finished turns free their runners, \(liveRunners) of \(runnersMade.count) still alive")
            let bytes = mallocBytesInUse() - baseline
            samples.append(bytes)
            contentAtHour.append(streamedContent)
            print("long-session memory: hour \(hour + 1): +\(mb(bytes)) over baseline, \(turnCount) turns, \(liveRunners) runners alive, \(Int(Date().timeIntervalSince(started)))s")
            // Diagnosis only: hold still so `heap <pid>` can census this hour.
            let pauses = (ProcessInfo.processInfo.environment["ARRAY_LONG_SESSION_PAUSE_AFTER_HOURS"] ?? "")
                .split(separator: ",").compactMap { Int($0) }
            if pauses.contains(hour + 1) {
                print("long-session memory: paused after hour \(hour + 1) for a heap census, pid \(getpid())")
                _ = await waitUntil(timeout: TimeInterval(env("ARRAY_LONG_SESSION_PAUSE_SECONDS") ?? 60), pollInterval: 1) { false }
            }
        }

        // Then the session sits: every agent idle, tiles on screen, for
        // `ARRAY_LONG_SESSION_IDLE_SECONDS` of wall time. Nothing streams, so
        // nothing may grow.
        var idleGrowth = 0
        if let idleSeconds = env("ARRAY_LONG_SESSION_IDLE_SECONDS"), idleSeconds > 0 {
            let idleStart = mallocBytesInUse()
            let step = max(1, idleSeconds / 6)
            var waited = 0
            while waited < idleSeconds {
                _ = await waitUntil(timeout: TimeInterval(step), pollInterval: 0.5) { false }
                waited += step
                print("long-session memory: idle \(waited)s: +\(mb(mallocBytesInUse() - idleStart))")
            }
            idleGrowth = mallocBytesInUse() - idleStart
        }

        // Windowed history, witnessed: distant blocks are released, and a
        // copy of the whole transcript still holds its first turn (laid out
        // for the copy, and released again).
        func transcripts(in view: NSView) -> [AgentTranscriptCanvasView] {
            (view as? AgentTranscriptCanvasView).map { [$0] } ?? view.subviews.flatMap(transcripts(in:))
        }
        let canvases = live.compactMap { canvas.tileView(for: $0.tile.id) }.flatMap(transcripts(in:))
        try expect(canvases.count == live.count, "every live tile draws its transcript, \(canvases.count) of \(live.count)")
        let released = canvases.map(\.qaReleasedBlockCount).reduce(0, +)
        try expect(released > 0, "transcripts release the layout of blocks far from what they show, 0 released")
        if let oldest = canvases.first(where: { $0.qaReleasedBlockCount > 0 }) {
            let before = oldest.qaReleasedBlockCount
            oldest.selectAll(nil)
            let copied = oldest.selectedText ?? ""
            try expect(copied.contains("That fixes turn 0 for agent"),
                       "a copy of the whole transcript includes its released first turn (\(copied.count) characters copied)")
            // Straight after the copy, with no release pass in between: a
            // copy that kept what it laid out shows as fewer released blocks.
            try expect(oldest.qaReleasedBlockCount >= before,
                       "copying lays released blocks out without keeping them: \(before) released before, \(oldest.qaReleasedBlockCount) after")
            oldest.select(range: NSRange(location: 0, length: 0))
        }
        // A closed tile's hidden resting host goes with it.
        try expect(RestingHost.qaLiveWindowCount <= live.count,
                   "closed tiles free their resting hosts: \(RestingHost.qaLiveWindowCount) host windows for \(live.count) open tiles")
        print("long-session memory: \(released) blocks released across \(canvases.count) transcripts, \(RestingHost.qaLiveWindowCount) resting hosts")

        let streamed = turnByAgent.values.reduce(0, +)
        try expect(streamed >= turnCount,
                   "every turn streamed through a runner: \(streamed) runs for \(turnCount) turns")
        // Warm-up is the first two hours: the first transcripts, caches and
        // views, and what the first idle settles (resting chrome, tool detail).
        // After it, what grows must be the transcripts' own text and its
        // structure, both copies of it (the supervisor's and the tile's), and
        // a placement per block: well under 25 times the text streamed. Before the
        // fixes it was 58 times (runners, CoreText for every line ever
        // drawn, one Auto Layout engine for every resting tile).
        let warmHours = min(2, samples.count - 1)
        let warm = warmHours > 0 ? samples[warmHours - 1] : 0
        let steadyHours = max(1, samples.count - warmHours)
        let perHour = ((samples.last ?? 0) - warm) / steadyHours
        let contentPerHour = ((contentAtHour.last ?? 0) - (warmHours > 0 ? contentAtHour[warmHours - 1] : 0)) / steadyHours
        let ratio = contentPerHour > 0 ? Double(perHour) / Double(contentPerHour) : 0
        let report = "\(agentCount) agents, \(turnCount) turns over \(samples.count) simulated hours: warm-up +\(mb(warm)), then +\(mb(perHour))/hour for \(mb(contentPerHour))/hour of streamed text (\(String(format: "%.1f", ratio))x; hours: \(samples.map(mb).joined(separator: ", ")))"
        print("long-session memory: \(report)")
        try expect(ratio < steadyBudgetRatio,
                   "memory after warm-up grows with the transcripts' text, under \(steadyBudgetRatio)x what streamed: \(report)")
        if idleGrowth > 0 { print("long-session memory: idle growth +\(mb(idleGrowth))") }
        return report
    }

    /// Retained bytes per byte of streamed text, after warm-up. Fixed builds
    /// measure 9-19x run to run; every regressed build measured 52-58x. The
    /// specific regressions are asserted directly above (runners alive,
    /// blocks released, copy keeping layout, resting hosts freed).
    static let steadyBudgetRatio = 25.0
}
