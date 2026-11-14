import AppKit
import ContinuumRevivedCore

/// Drives the shipping boot seam; counters, not the informational stopwatch, gate scaling.
@MainActor
enum RestoreScalingChecks {
    struct Failure: Error { let message: String }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static var emptyCanvas: CanvasState { .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil) }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("restore-scaling-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        if CommandLine.arguments.contains("--restore-scaling-codex-only") { try codexFixture(root); return }
        let ids = (0..<2400).map { _ in AgentID(rawValue: UUID()) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let sizes = CommandLine.arguments.contains("--restore-scaling-size-64") ? [64] : [0, 64, 674, 2000]
        for count in sizes {
            let support = root.appendingPathComponent("n\(count)")
            let store = AgentStore(applicationSupportDirectory: support)
            let project = UUID()
            for (i, id) in ids.enumerated() {
                // Direct fixture writes avoid unrelated backup work in setup.
                let record = AgentRecord(id: id, displayName: "Fixture \(i)", harness: .pi,
                    model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                    projectId: project, createdAt: date, lastActivityAt: date)
                try fm.createDirectory(at: store.layout.agentsDirectory, withIntermediateDirectories: true)
                try JSONCodec.makeEncoder().encode(record).write(to: store.layout.agentFile(id: id))
            }
            let queue = AgentComposerDraftStore(applicationSupportDirectory: support)
            let outbox = AgentMessageOutbox(applicationSupportDirectory: support)
            try fm.createDirectory(at: outbox.directory, withIntermediateDirectories: true)
            var entries: [AgentMessageOutbox.Entry] = []
            for i in 0..<count {
                let context = AgentMessageQueueContext(caller: ids[0], recipient: ids[i % 8],
                    operationId: "op\(i)", idempotencyKey: "key\(i)", payloadHash: "fixture")
                var entry = AgentMessageOutbox.Entry(context: context, message: .init(
                    text: "message \(i)", queuedAt: date.addingTimeInterval(Double(i)), agentMessageContext: context))
                entry.phase = i % 2 == 0 ? .queued : .settled
                entries.append(entry)
                try outbox.save(entry)
                try Data().write(to: outbox.directory.appendingPathComponent("unused-\(i).lock"))
            }
            // A local queue without an outbox must also pause and hydrate.
            let local = AgentComposerQueuedMessage(text: "local", queuedAt: date)
            try await queue.enqueueAgentMessage(local, for: ids[9])
            for launch in 0..<2 {
                let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                    warn: { _ in }, nameTitlerCommand: { _ in nil }, submissionRecoveryStore: queue)
                let app = AppDelegate()
                app.agentSupervisor = supervisor
                let canvas = CanvasNSView(canvasState: emptyCanvas)
                let decoded = AgentMessageOutbox.entriesDecodedForQA
                let enumerations = AgentMessageOutbox.enumerationsForQA
                let start = ContinuousClock.now
                try app.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: nil, projectStore: nil,
                    canvasState: emptyCanvas, installsGlobalEventMonitors: false)
                let elapsed = ContinuousClock.now - start
                try expect(supervisor.records.count == 2400, "boot must adopt all fixture agents")
                try expect(supervisor.isQueuePaused(for: ids[9]), "local queued message must await explicit resume")
                for id in Set(entries.filter { $0.phase == .queued }.map(\.context.recipient)) {
                    try expect(supervisor.isQueuePaused(for: id), "outbox recipient must pause before hydration")
                }
                // Let production hydration finish. No runner may start while paused.
                for _ in 0..<1000 {
                    if supervisor.qaPendingQueueHydrationCount == 0 && supervisor.queuedMessages(for: ids[9]).contains(where: { $0.id == local.id }) &&
                        entries.filter({ $0.phase == .queued }).allSatisfy({ entry in
                            supervisor.queuedMessages(for: entry.context.recipient).contains { $0.id == entry.message.id }
                        }) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try expect(supervisor.queuedMessages(for: ids[9]).contains { $0.id == local.id }, "local hydration completed")
                for entry in entries where entry.phase == .queued {
                    try expect(supervisor.queuedMessages(for: entry.context.recipient).contains { $0.id == entry.message.id }, "durable queued entry hydrated")
                    try expect(!supervisor.isRunning(entry.context.recipient), "restore must not auto resume")
                }
                for entry in entries where entry.phase == .settled {
                    try expect(try outbox.lookup(caller: entry.context.caller, key: entry.context.idempotencyKey) == entry,
                               "terminal idempotency entry unchanged")
                }
                let reads = AgentMessageOutbox.entriesDecodedForQA - decoded
                let scans = AgentMessageOutbox.enumerationsForQA - enumerations
                print("METRIC restore agents=2400 outbox=\(count) launch=\(launch) enumerations=\(scans) decodes=\(reads) seconds=\(elapsed) budget=5s (informational)")
                try expect(scans == 1 && reads <= count, "outbox=\(count): scans=\(scans) decodes=\(reads), expected 1 / <=\(count)")
                supervisor.stopAll()
            }
            // A corrupt entry preserves the old all-or-nothing fallback; local queues still recover.
            try Data("broken".utf8).write(to: outbox.directory.appendingPathComponent("corrupt.json"))
            var corruptionWarnings: [String] = []
            let corrupt = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { corruptionWarnings.append($0) },
                nameTitlerCommand: { _ in nil }, submissionRecoveryStore: queue)
            _ = corrupt.restore()
            try expect(corrupt.isQueuePaused(for: ids[9]), "corrupt outbox must not prevent local queue recovery")
            for _ in 0..<1000 {
                if corrupt.qaPendingQueueHydrationCount == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try expect(corrupt.qaPendingQueueHydrationCount == 0, "corrupt queue recovery completes")
            try expect(corruptionWarnings.contains("Agent message queue recovery could not complete."), "corrupt outbox keeps its recovery warning")
            corrupt.stopAll()
        }
        try await cancellationFixture(root)
        try codexFixture(root)
        print("PASS restore scaling: boot, fresh launches, queue hydration, terminal retention and Codex tree")
        print("MATRIX-NOTE: --restore-scaling-check passed: 2400 agents, outbox 0/64/674/2000 on two launches, one enumeration and <=B decodes; Codex two roots, 1000 unrelated files; 5s timing informational.")
    }

    static func cancellationFixture(_ root: URL) async throws {
        let support = root.appendingPathComponent("cancel-race")
        let store = AgentStore(applicationSupportDirectory: support)
        let id = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(id: id, displayName: "Race", harness: .pi, model: AgentCatalogQAFixture.pi[0],
            thinking: "none", cwd: root.path, projectId: UUID(), createdAt: Date(), lastActivityAt: Date()))
        let queue = AgentComposerDraftStore(applicationSupportDirectory: support)
        var runnerStarts = 0
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runnerStarts += 1; return ScriptedAgentRunner(script: []) }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: queue)
        let context = AgentMessageQueueContext(caller: id, recipient: id, operationId: "race", idempotencyKey: "race", payloadHash: "h")
        var entry = AgentMessageOutbox.Entry(context: context, message: .init(text: "cancel me", queuedAt: Date(), agentMessageContext: context))
        try supervisor.agentMessageOutbox.save(entry)
        var entered = false
        var release = false
        supervisor.qaBeforeRestoreQueueHydration = {
            entered = true
            while !release { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let app = AppDelegate(); app.agentSupervisor = supervisor
        try app.mountWorkspaceSceneAtBoot(canvasView: CanvasNSView(canvasState: emptyCanvas), spawner: nil,
            projectStore: nil, canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        for _ in 0..<1000 { if entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        try expect(entered, "hydration must reach the controlled suspension")
        entry.phase = .cancelled
        try supervisor.agentMessageOutbox.save(entry)
        supervisor.cancelQueuedMessage(entry.message.id, for: id)
        supervisor.resumeQueue(for: id)
        try expect(!supervisor.isQueuePaused(for: id), "explicit resume is accepted while hydration waits")
        release = true
        for _ in 0..<1000 {
            if supervisor.qaPendingQueueHydrationCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await supervisor.qaQueueWritesSettled(for: id)
        try expect(supervisor.queuedMessages(for: id).isEmpty, "cancel during hydration must not resurrect a message")
        try expect(await queue.queuedWorkItems(for: id).isEmpty, "cancelled entry stays absent on disk")
        try expect(runnerStarts == 0 && !supervisor.isRunning(id), "resume during hydration must not run the cancelled message")
        supervisor.stopAll()
    }

    static func codexFixture(_ root: URL) throws {
        let home = root.appendingPathComponent("codex")
        let fm = FileManager.default
        let ids = (0..<64).map { "thread-\($0)" }
        for (i, id) in ids.enumerated() {
            let dir = home.appendingPathComponent(i % 2 == 0 ? "sessions/2026/11" : "archived_sessions")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n"
            let usage = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":42},\"model_context_window\":1000}}}\n"
            try Data((meta + usage).utf8).write(to: dir.appendingPathComponent("rollout-\(id).jsonl"))
        }
        // Duplicate valid identity must abstain, even across roots.
        let original = home.appendingPathComponent("sessions/2026/11/rollout-thread-0.jsonl")
        try fm.copyItem(at: original, to: home.appendingPathComponent("archived_sessions/duplicate-thread-0.jsonl"))
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong\"}}\n".utf8)
            .write(to: home.appendingPathComponent("archived_sessions/mismatch-thread-1.jsonl"))
        for i in 0..<1000 {
            try Data("unrelated".utf8).write(to: home.appendingPathComponent("archived_sessions/unrelated-\(i).jsonl"))
        }
        let support = root.appendingPathComponent("codex-support")
        let store = AgentStore(applicationSupportDirectory: support)
        for id in ids {
            var record = AgentRecord(id: AgentID(rawValue: UUID()), displayName: "Codex fixture", harness: .codex,
                model: "fixture", thinking: "none", cwd: root.path, projectId: UUID(), createdAt: Date(), lastActivityAt: Date())
            record.codexThreadId = id
            try store.upsert(record)
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { _ in })
        supervisor.codexRestoreHomeForQA = home
        let metadataBefore = CodexRolloutTelemetry.metadataReadsForQA
        let before = CodexRolloutTelemetry.RestoreIndex.enumerationsForQA
        let app = AppDelegate(); app.agentSupervisor = supervisor
        try app.mountWorkspaceSceneAtBoot(canvasView: CanvasNSView(canvasState: emptyCanvas), spawner: nil,
            projectStore: nil, canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        let scans = CodexRolloutTelemetry.RestoreIndex.enumerationsForQA - before
        print("METRIC codex restore threads=64 root-enumerations=\(scans) expected=2")
        try expect(CodexRolloutTelemetry.metadataReadsForQA - metadataBefore == 66, "only 66 candidate rollout headers read; unrelated files untouched")
        try expect(scans == 2, "Codex session roots enumerated once per restore")
        for record in supervisor.records.values {
            if record.codexThreadId == "thread-0" { try expect(record.lastContextWindow == nil, "ambiguous thread abstains") }
            else { try expect(record.lastContextWindow?.usedTokens == 42 && record.lastContextWindow?.freshness == .stale, "exact telemetry restored stale") }
        }
        supervisor.stopAll()
    }
}
