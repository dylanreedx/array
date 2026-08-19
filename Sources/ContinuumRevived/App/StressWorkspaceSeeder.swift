import AppKit
import ContinuumRevivedCore
import Foundation

/// **`--seed-stress-workspace-check`: build a workspace-scale dogfood harness out
/// of REAL parts.**
///
/// The unbounded-canvas work was measured on fixtures and validated on a 14-tile
/// scratch canvas; the residency policy's whole value proposition is a canvas an
/// order of magnitude bigger. This seeds one: managed Pi agents with genuine chat
/// history, browser tiles, and markdown file tiles, at counts set by environment.
///
/// Everything is the production article, not a simulation:
///
/// - agents are spawned through the real `AgentSupervisor` into the real
///   channel-split `AgentStore`, so records carry the right harness, model,
///   thinking, cwd, and `tileId` binding;
/// - prompts run through the real `PiAgentRunner` — real CLI, real turns, the
///   session id derived exactly as production derives it, so the app RESUMES these
///   conversations on open;
/// - the model id is validated against pi's own live catalogue before anything
///   spawns, because `pi --model` fuzzy-matches patterns and a partial id runs the
///   wrong model silently (non-negotiable #5);
/// - tiles are appended to the project's real canvas document, in the zone its
///   existing tiles already live in.
///
/// Environment: `CONTINUUM_PROJECT_ROOT` (required), `STRESS_AGENTS` (50),
/// `STRESS_BROWSERS` (5), `STRESS_MD` (20), `STRESS_MODEL`
/// (openai-codex/gpt-5.6-luna), `STRESS_THINKING` (low), `STRESS_CONCURRENCY` (8),
/// `STRESS_SKIP_PROMPTS=1` to seed structure only.
///
/// NOT a matrix leg, deliberately: it spends real provider quota and needs a
/// logged-in pi. It is a tool with the check cascade's ergonomics, not a gate.
@MainActor
func runStressWorkspaceSeeder() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> Failure { Failure(description: message) }
    let env = ProcessInfo.processInfo.environment

    guard let rootPath = env["CONTINUUM_PROJECT_ROOT"], !rootPath.isEmpty else {
        throw fail("CONTINUUM_PROJECT_ROOT is required — the seeder refuses to guess which project to grow")
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let agentCount = Int(env["STRESS_AGENTS"] ?? "") ?? 50
    let browserCount = Int(env["STRESS_BROWSERS"] ?? "") ?? 5
    let markdownCount = Int(env["STRESS_MD"] ?? "") ?? 20
    let model = env["STRESS_MODEL"] ?? "openai-codex/gpt-5.6-luna"
    let thinking = env["STRESS_THINKING"] ?? "low"
    let concurrency = max(1, Int(env["STRESS_CONCURRENCY"] ?? "") ?? 8)
    let skipPrompts = env["STRESS_SKIP_PROMPTS"] == "1"

    // ---- The project lock. `.array/lock` is an exclusive flock and two writers on
    // one root is exactly the last-writer-wins data loss hazard 10 documents, so a
    // held lock is a hard stop, not a wait.
    let stateDir = root.appendingPathComponent(".array", isDirectory: true)
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lockPath = stateDir.appendingPathComponent("lock").path
    let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o600)
    guard lockFD >= 0 else { throw fail("could not open \(lockPath)") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw fail("\(root.path) is open in Array — quit the app on this root first (.array/lock is held)")
    }
    defer { flock(lockFD, LOCK_UN) }

    // ---- The exact model id, from pi's own catalogue. Live-probed, never assumed.
    print("seed: probing pi's catalogue for \(model) …")
    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    var piSnapshot = catalog.snapshot(for: .pi)
    let probeDeadline = Date().addingTimeInterval(30)
    while piSnapshot.readiness == .checking, Date() < probeDeadline {
        try await Task.sleep(nanoseconds: 250_000_000)
        piSnapshot = catalog.snapshot(for: .pi)
    }
    guard piSnapshot.readiness == .ready else {
        throw fail("pi is not ready (\(piSnapshot.readiness)) — run pi and /login first; the seeder never touches keys")
    }
    guard piSnapshot.models.contains(model) else {
        throw fail("'\(model)' is not in pi's catalogue verbatim. Offered ids must be exact — near matches: "
                   + piSnapshot.models.filter { $0.localizedCaseInsensitiveContains("gpt") }.joined(separator: ", "))
    }
    print("seed: pi ready, \(model) confirmed verbatim in the catalogue")

    // ---- Real stores.
    let projectStore = ProjectStore(projectRoot: root)
    let managedSessionStore = ManagedAgentSessionStore(projectRoot: root)
    let project = try? projectStore.loadProject()
    var canvas: CanvasState
    do { canvas = try projectStore.loadCanvas() } catch {
        canvas = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
    }
    let zoneId = canvas.tiles.compactMap(\.zoneId).first
    let appSupport = AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
    let agentStore = AgentStore(applicationSupportDirectory: appSupport)
    let supervisor = AgentSupervisor(store: agentStore, makeRunner: { record in
        AgentSupervisor.productionRunner(for: record)
    })

    // ---- Placement: a fresh grid strictly to the RIGHT of everything that exists,
    // so nothing already on the canvas is covered.
    let existingMaxX = canvas.tiles.map { $0.frame.x + $0.frame.width }.max() ?? 0
    let baseX = existingMaxX + 240
    let baseY = canvas.tiles.map(\.frame.y).min() ?? 0
    let gap = 60.0
    var newTiles: [Tile] = []
    func place(kind: TileKind, title: String, index: Int, perRow: Int, size: (Double, Double),
               yOffset: Double, metadata: TileMetadata, id: UUID = UUID()) -> Tile {
        let column = index % perRow
        let row = index / perRow
        let tile = Tile(
            id: id, kind: kind, title: title,
            frame: TileFrame(
                x: baseX + Double(column) * (size.0 + gap),
                y: baseY + yOffset + Double(row) * (size.1 + gap),
                width: size.0, height: size.1
            ),
            zPosition: CanvasEngine.zPositionAbove(canvas.tiles + newTiles),
            zoneId: zoneId, runtimeRef: nil, metadata: metadata
        )
        newTiles.append(tile)
        return tile
    }

    // ---- 1. Agents: record first (tileId bound at spawn), tile + session record after.
    let agentRows = (agentCount + 9) / 10
    var agents: [(id: AgentID, tileId: UUID, prompts: [String])] = []
    for index in 0..<agentCount {
        let tileId = UUID()
        // displayName is load-bearing, not cosmetic: a spawn without one starts
        // async NAME GENERATION — a pi one-shot whose timeout cleanup kills its
        // process GROUP, which in a headless seeder is the same group the chat
        // turns run in. The first smoke run lost every turn to exactly that
        // (piFailed exit 15 = SIGTERM, seconds after start).
        let agentID = supervisor.spawn(
            role: nil, prompt: nil, cwd: root, harness: .pi,
            model: model, thinking: thinking,
            projectId: project?.id, tileId: tileId,
            displayName: "Luna \(String(format: "%02d", index + 1))"
        )
        _ = place(
            kind: .managedAgent, title: "Luna \(String(format: "%02d", index + 1))", index: index,
            perRow: 10, size: (640, 520), yOffset: 0,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."),
            id: tileId
        )
        try managedSessionStore.upsert(ManagedAgentSessionRecord(
            tileId: tileId, agentKind: .managed, status: .running, lastSeenAt: Date()
        ))
        agents.append((agentID, tileId, Self_stressPrompts(agentIndex: index)))
    }

    // ---- 2. Markdown file tiles over real generated documents in the project.
    let docsDir = root.appendingPathComponent("stress-docs", isDirectory: true)
    try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
    for index in 0..<markdownCount {
        let name = String(format: "%02d-%@.md", index + 1, Self_stressDocTitles[index % Self_stressDocTitles.count]
            .lowercased().replacingOccurrences(of: " ", with: "-"))
        let fileURL = docsDir.appendingPathComponent(name)
        try Self_stressMarkdown(index: index).write(to: fileURL, atomically: true, encoding: .utf8)
        var metadata = TileMetadata()
        metadata.filePath = fileURL.path
        _ = place(
            kind: .file, title: name, index: index, perRow: 10, size: (620, 460),
            yOffset: Double(agentRows) * (520 + gap) + 160, metadata: metadata
        )
    }
    let markdownRows = (markdownCount + 9) / 10

    // ---- 3. Browser tiles.
    let urls = [
        "https://arrayapp.dev",
        "https://developer.apple.com/documentation/appkit",
        "https://news.ycombinator.com",
        "https://en.wikipedia.org/wiki/Core_Animation",
        "https://github.com/trending"
    ]
    for index in 0..<browserCount {
        var metadata = TileMetadata()
        metadata.url = urls[index % urls.count]
        _ = place(
            kind: .browser, title: URL(string: metadata.url ?? "")?.host ?? "browser",
            index: index, perRow: 5, size: (900, 600),
            yOffset: Double(agentRows) * (520 + gap) + Double(markdownRows) * (460 + gap) + 320,
            metadata: metadata
        )
    }

    // ---- Persist the structure BEFORE any chat runs: a prompt failure must not
    // cost the workspace, only that agent's history.
    canvas.tiles.append(contentsOf: newTiles)
    try projectStore.saveCanvas(canvas)
    print("seed: canvas now holds \(canvas.tiles.count) tiles "
          + "(+\(agentCount) agents, +\(markdownCount) markdown, +\(browserCount) browsers)")

    // ---- 4. Real conversations, in bounded waves.
    guard !skipPrompts else {
        print("seed: STRESS_SKIP_PROMPTS=1 — structure seeded, no turns run")
        return
    }
    let totalTurns = agents.reduce(0) { $0 + $1.prompts.count }
    print("seed: running \(totalTurns) real \(model) turns across \(agents.count) agents, \(concurrency) at a time …")
    var completedTurns = 0
    var failedTurns = 0
    var wave = 0
    for start in stride(from: 0, to: agents.count, by: concurrency) {
        wave += 1
        let slice = Array(agents[start..<min(start + concurrency, agents.count)])
        // Round-robin over the wave rather than a task group: everything here is
        // MainActor state, and the concurrency that matters is the PI PROCESSES,
        // which all run in parallel once sent. One pass sends a prompt to every
        // idle agent in the wave, then waits for any to finish.
        var remaining: [AgentID: [String]] = [:]
        var inFlight: Set<AgentID> = []
        var started: Set<AgentID> = []
        var startDeadlines: [AgentID: Date] = [:]
        for agent in slice { remaining[agent.id] = agent.prompts }
        while !remaining.isEmpty || !inFlight.isEmpty {
            // Send to every idle agent that still has prompts.
            for agent in slice where !inFlight.contains(agent.id) {
                guard var prompts = remaining[agent.id], !prompts.isEmpty else {
                    remaining.removeValue(forKey: agent.id)
                    continue
                }
                let prompt = prompts.removeFirst()
                remaining[agent.id] = prompts.isEmpty ? nil : prompts
                if supervisor.send(prompt, to: agent.id) {
                    inFlight.insert(agent.id)
                    startDeadlines[agent.id] = Date().addingTimeInterval(240)
                } else {
                    failedTurns += 1
                    print("seed: send REFUSED for \(agent.id.rawValue): "
                          + (supervisor.sendRefusal(for: agent.id) ?? "no stated refusal — prompt in flight?"))
                }
            }
            guard !inFlight.isEmpty else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
            for id in inFlight {
                let deadline = startDeadlines[id] ?? Date()
                if supervisor.isRunning(id) {
                    started.insert(id)
                    if Date() > deadline {
                        supervisor.stop(id)
                        inFlight.remove(id)
                        failedTurns += 1
                    }
                } else if started.contains(id) {
                    // Ran and stopped: the turn is done.
                    inFlight.remove(id)
                    started.remove(id)
                    completedTurns += 1
                } else if Date() > deadline.addingTimeInterval(-240 + 20) {
                    // Never seen running 20 s after send — the runner failed to
                    // start (or finished between polls, impossible for a real
                    // model turn). Count it failed and move on.
                    inFlight.remove(id)
                    failedTurns += 1
                    print("seed: agent \(id.rawValue) never entered running within 20s of send")
                }
            }
        }
        print("seed: wave \(wave) done — \(completedTurns)/\(totalTurns) turns complete, \(failedTurns) failed")
    }
    // Session records go quiet, honestly: these agents are not running any more.
    for agent in agents {
        try? managedSessionStore.upsert(ManagedAgentSessionRecord(
            tileId: agent.tileId, agentKind: .managed, status: .running, lastSeenAt: Date()
        ))
    }
    print("seed: complete — \(completedTurns) turns of real history, \(failedTurns) failed. "
          + "Open the app on \(root.path) (the boot sweep normalises session records).")
    if failedTurns > 0 {
        print("seed: NOTE — \(failedTurns) turn(s) failed or timed out; those agents simply have shorter histories")
    }
}

/// Poll on the main actor without blocking it.
@MainActor
private func Self_stressWait(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return condition()
}

/// 1–5 prompts per agent, varying by index, pure chat by instruction: the harness
/// is for canvas load, not for exercising tool use, and a tool-using turn in the
/// project root could touch real files.
private func Self_stressPrompts(agentIndex: Int) -> [String] {
    let bank = [
        "In one short paragraph, explain what a compositor does in a desktop OS.",
        "Give three bullet points on why text shaping is expensive. Keep it tight.",
        "Write a two-line haiku-like note about zooming a canvas.",
        "Briefly: what is hysteresis, and one example outside electronics?",
        "In 3 sentences, what makes 120Hz UI rendering hard?",
        "Name four things that make a good commit message. One line each.",
        "One paragraph: why is caching by width fragile under scaling?",
        "Explain double buffering to a designer in two sentences.",
        "Give a two-sentence summary of what an entity–component system is.",
        "Three short bullets: what makes a good performance witness?"
    ]
    let count = (agentIndex % 5) + 1
    let suffix = " Answer directly in prose. Do not use tools, do not read or write files."
    return (0..<count).map { bank[(agentIndex + $0 * 3) % bank.count] + suffix }
}

private let Self_stressDocTitles = [
    "Render Pipeline Notes", "Zone Design", "Camera Math", "Residency Policy",
    "Bake Budgeting", "Input Routing", "Focus Rules", "Memory Plan",
    "Accessibility Pass", "Instrument Catalog", "Gesture Log Format", "Witness Doctrine",
    "Surface Store", "Park Semantics", "Chrome Buckets", "Hysteresis Notes",
    "Session Resume", "Catalog Probing", "Grid Layout", "Harness Design"
]

/// Deterministic, varied, realistic markdown — headings, prose, lists, fences and
/// a table, at four size tiers so the canvas carries small and heavy documents.
private func Self_stressMarkdown(index: Int) -> String {
    let title = Self_stressDocTitles[index % Self_stressDocTitles.count]
    let sections = [2, 4, 7, 12][index % 4]
    var out = "# \(title)\n\nA stress-harness document. Content is generated but shaped like real notes: prose, lists, code and tables, so text measurement costs what real documents cost.\n\n"
    for section in 1...sections {
        out += "## \(title) — part \(section)\n\n"
        out += String(repeating: "This paragraph exists to be measured. It wraps at realistic widths and it is long enough that a re-measure is never free. ", count: 2 + (section % 4)) + "\n\n"
        out += "- first point about part \(section)\n- second point, slightly longer to vary line breaks\n- third point\n\n"
        if section % 2 == 0 {
            out += "```swift\nfunc part\(section)() -> Int {\n    // representative code fence\n    return \(section) * 42\n}\n```\n\n"
        }
        if section % 3 == 0 {
            out += "| stage | cost | notes |\n|---|---:|---|\n| layout | \(section).1 ms | representative |\n| display | 0.\(section) ms | representative |\n\n"
        }
    }
    return out
}
