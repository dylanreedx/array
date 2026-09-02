import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import Foundation

private final class CompactionScriptRunner: AgentRunning, AgentCompactionRunning, @unchecked Sendable {
    enum Result { case succeed, fail }
    private let lock = NSLock()
    private let firstTurnGate: DispatchSemaphore?
    private let result: Result
    private let supportsFocus: Bool
    private let postTokens: Int?
    private let postPrecision: AgentCompactionTokenPrecision
    private var firstRun = true
    private(set) var operations: [String] = []

    init(
        blockFirstTurn: Bool = false,
        result: Result = .succeed,
        supportsFocus: Bool = true,
        postTokens: Int? = 20_000,
        postPrecision: AgentCompactionTokenPrecision = .exact
    ) {
        firstTurnGate = blockFirstTurn ? DispatchSemaphore(value: 0) : nil
        self.result = result
        self.supportsFocus = supportsFocus
        self.postTokens = postTokens
        self.postPrecision = postPrecision
    }

    var compactionCapabilities: AgentCompactionCapabilities {
        AgentCompactionCapabilities(supportsManual: true, supportsFocus: supportsFocus)
    }
    var keepsSessionAliveBetweenTurns: Bool { true }
    var canAcceptAnotherTurn: Bool { true }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let shouldWait = lock.withLock { () -> Bool in
            operations.append("run:\(prompt.text)")
            defer { firstRun = false }
            return firstRun
        }
        let turnID = UUID().uuidString
        onEvent(.turnStarted(threadId: "provider", turnId: turnID))
        if shouldWait { firstTurnGate?.wait() }
        onEvent(.turnCompleted(
            threadId: "provider", turnId: turnID,
            outcome: .completed, errorMessage: nil))
    }

    func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        lock.withLock { operations.append("compact") }
        onEvent(.compactionChanged(threadId: "provider", event: AgentCompactionLifecycleEvent(
            operationID: request.operationID,
            phase: .running,
            trigger: .manual,
            provider: "script")))
        let terminal = AgentCompactionLifecycleEvent(
            operationID: request.operationID,
            boundaryID: "script-boundary",
            phase: result == .succeed ? .succeeded : .failed,
            trigger: .manual,
            beforeTokens: AgentCompactionTokenReading(100_000, precision: .exact),
            afterTokens: postTokens.map { AgentCompactionTokenReading($0, precision: postPrecision) },
            provider: "script",
            errorMessage: result == .fail ? "scripted failure" : nil)
        onEvent(.compactionChanged(threadId: "provider", event: terminal))
        // A repeated provider notification must not advance the epoch twice.
        if result == .succeed {
            onEvent(.compactionChanged(threadId: "provider", event: terminal))
            // This belongs to the operation's captured pre-boundary epoch and
            // must not repaint the exact post-boundary meter.
            onEvent(.contextWindowUpdated(
                threadId: "provider",
                snapshot: AgentContextWindowSnapshot(
                    usedTokens: 90_000, maxTokens: 100_000,
                    observedAt: Date(), source: .unknown("script-stale"), freshness: .live)))
        }
        if result == .fail { throw NSError(domain: "AgentCompactionUICheck", code: 1) }
    }

    func stop() { firstTurnGate?.signal() }
    func releaseFirstTurn() { firstTurnGate?.signal() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
    func snapshotOperations() -> [String] { lock.withLock { operations } }
}

@MainActor
func runAgentCompactionUIChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(
        _ message: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message)
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-compaction-ui-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = CompactionScriptRunner(blockFirstTurn: true)
    let draftStore = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0)
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { _ in runner },
        submissionRecoveryStore: draftStore)
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let id = supervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .pi, model: config.model, thinking: config.thinking)

    guard supervisor.send("first", to: id) else { throw Failure(description: "seed turn was refused") }
    try await expectEventually("first turn did not start") { runner.snapshotOperations() == ["run:first"] }
    guard await supervisor.accept(.queue(AgentPrompt("A")), for: id) == .accepted,
          await supervisor.accept(.compact(AgentCompactionRequest(focus: "retain decisions")), for: id) == .accepted,
          await supervisor.accept(.queue(AgentPrompt("B")), for: id) == .accepted else {
        throw Failure(description: "mixed FIFO submissions were refused")
    }
    guard await supervisor.accept(.compact(AgentCompactionRequest()), for: id) == .refused(.turnNotReady) else {
        throw Failure(description: "a second queued compaction was accepted")
    }
    let chips = supervisor.queuedMessages(for: id).map(\.text)
    guard chips == ["A", "Compact context with focus", "B"] else {
        throw Failure(description: "mixed queue lost exact display order: \(chips)")
    }
    runner.releaseFirstTurn()
    try await expectEventually("mixed queue did not drain in exact FIFO order") {
        runner.snapshotOperations() == ["run:first", "run:A", "compact", "run:B"]
    }
    try await expectEventually("compaction operation did not release its runner") { !supervisor.isRunning(id) }
    guard runner.snapshotOperations().filter({ $0 == "compact" }).count == 1,
          !runner.snapshotOperations().contains(where: { $0.contains("/compact") }) else {
        throw Failure(description: "compaction was duplicated or routed through run(prompt:)")
    }
    guard supervisor.records[id]?.contextEpoch == 1,
          supervisor.contextWindowSnapshot(for: id)?.usedTokens == 20_000 else {
        throw Failure(description: "duplicate success or stale telemetry corrupted the new epoch")
    }


    let unknownRoot = root.appendingPathComponent("unknown-post", isDirectory: true)
    let unknownRunner = CompactionScriptRunner(postTokens: nil)
    let unknownSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: unknownRoot),
        makeRunner: { _ in unknownRunner },
        submissionRecoveryStore: AgentComposerDraftStore(
            applicationSupportDirectory: unknownRoot, debounceInterval: 0))
    let unknownID = unknownSupervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .pi, model: config.model, thinking: config.thinking)
    guard unknownSupervisor.send("seed unknown", to: unknownID) else {
        throw Failure(description: "unknown-post seed refused")
    }
    try await expectEventually("unknown-post seed did not finish") { !unknownSupervisor.isRunning(unknownID) }
    guard await unknownSupervisor.accept(.compact(AgentCompactionRequest()), for: unknownID) == .accepted else {
        throw Failure(description: "unknown-post compaction refused")
    }
    try await expectEventually("unknown-post compaction did not finish") { !unknownSupervisor.isRunning(unknownID) }
    guard unknownSupervisor.records[unknownID]?.contextEpoch == 1,
          unknownSupervisor.contextWindowSnapshot(for: unknownID) == nil else {
        throw Failure(description: "missing post-compaction occupancy was rendered as a number")
    }

    guard var interrupted = supervisor.records[id] else {
        throw Failure(description: "agent record disappeared")
    }
    interrupted.inFlightCompaction = AgentCompactionJournal(
        operationID: UUID(), phase: .running, startedAt: Date())
    try AgentStore(applicationSupportDirectory: root).upsert(interrupted)
    let restored = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { _ in CompactionScriptRunner() },
        submissionRecoveryStore: draftStore)
    _ = restored.restore()
    guard restored.records[id]?.inFlightCompaction?.phase == .indeterminate,
          restored.isQueuePaused(for: id) else {
        throw Failure(description: "relaunch did not turn an active journal into paused indeterminate state")
    }

    // A failed queued boundary holds everything behind it and leaves both the
    // context epoch and meter unchanged.
    let failedRoot = root.appendingPathComponent("failed", isDirectory: true)
    let failedRunner = CompactionScriptRunner(blockFirstTurn: true, result: .fail)
    let failedDraftStore = AgentComposerDraftStore(applicationSupportDirectory: failedRoot, debounceInterval: 0)
    let failedSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: failedRoot),
        makeRunner: { _ in failedRunner }, submissionRecoveryStore: failedDraftStore)
    let failedID = failedSupervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .pi, model: config.model, thinking: config.thinking)
    guard failedSupervisor.send("seed", to: failedID) else { throw Failure(description: "failed-path seed refused") }
    try await expectEventually("failed-path seed did not start") {
        failedRunner.snapshotOperations() == ["run:seed"]
    }
    guard await failedSupervisor.accept(.compact(AgentCompactionRequest()), for: failedID) == .accepted,
          await failedSupervisor.accept(.queue(AgentPrompt("held")), for: failedID) == .accepted else {
        throw Failure(description: "failed-path queue setup was refused")
    }
    failedRunner.releaseFirstTurn()
    try await expectEventually("failed compaction did not pause its later work") {
        failedSupervisor.isQueuePaused(for: failedID)
    }
    guard failedRunner.snapshotOperations() == ["run:seed", "compact"],
          failedSupervisor.queuedMessages(for: failedID).map(\.text) == ["held"],
          failedSupervisor.records[failedID]?.contextEpoch == 0,
          failedSupervisor.records[failedID]?.inFlightCompaction?.phase == .failed else {
        throw Failure(description: "failed compaction drained work or changed context state")
    }

    // An agent without provider history cannot compact, and provider focus
    // capability is enforced before any native operation starts.
    let emptyRunner = CompactionScriptRunner(supportsFocus: false)
    let emptySupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("empty")),
        makeRunner: { _ in emptyRunner }, submissionRecoveryStore: draftStore)
    let emptyID = emptySupervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .codex, model: config.model, thinking: config.thinking)
    guard await emptySupervisor.accept(.compact(AgentCompactionRequest()), for: emptyID) == .refused(.unsupported),
          emptyRunner.snapshotOperations().isEmpty else {
        throw Failure(description: "no-history compaction was not refused")
    }
    guard emptySupervisor.send("establish session", to: emptyID) else {
        throw Failure(description: "focus-capability seed was refused")
    }
    try await expectEventually("focus-capability seed did not finish") { !emptySupervisor.isRunning(emptyID) }
    guard await emptySupervisor.accept(
        .compact(AgentCompactionRequest(focus: "keep decisions")), for: emptyID
    ) == .refused(.unsupported), emptyRunner.snapshotOperations() == ["run:establish session"] else {
        throw Failure(description: "unsupported focus reached the provider operation")
    }

    // Legacy prompt-only queue files decode as tagged prompt work without a
    // migration pass or rewrite of the user's transcript.
    let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
    let legacyID = AgentID(rawValue: UUID())
    let legacyLayout = AgentComposerDraftStoreLayout(applicationSupportDirectory: legacyRoot)
    try FileManager.default.createDirectory(
        at: legacyLayout.queuedMessagesDirectory, withIntermediateDirectories: true)
    let legacyMessage = AgentComposerQueuedMessage(text: "legacy prompt", queuedAt: Date())
    try JSONCodec.makeEncoder().encode([legacyMessage]).write(
        to: legacyLayout.queuedMessagesFile(for: legacyID), options: .atomic)
    let migrated = await AgentComposerDraftStore(
        applicationSupportDirectory: legacyRoot, debounceInterval: 0).queuedWorkItems(for: legacyID)
    guard migrated.count == 1,
          case .prompt(let migratedMessage) = migrated[0],
          migratedMessage.id == legacyMessage.id,
          migratedMessage.text == legacyMessage.text else {
        throw Failure(description: "legacy prompt-only queue did not decode as tagged work")
    }

    let unknownLabel = CompactionRenderer.label(AgentCompactionPayload(
        preTokens: nil, postTokens: nil, automaticCompaction: nil, phase: "indeterminate"))
    guard unknownLabel.contains("outcome unknown"), !unknownLabel.contains("? → ?") else {
        throw Failure(description: "indeterminate compaction rendering was misleading")
    }

    let commandRows = await AgentCommandCompletionProvider().suggestions(for: AgentCompletionQuery(
        trigger: "/", text: "compact", replacementRange: NSRange(location: 0, length: 8),
        context: AgentCompletionContext(
            agentID: id, backend: .pi,
            checkoutRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            gitRoot: nil, arrayProjectRoot: root, trustState: .trusted)))
    let compactRowIDs = commandRows.filter { $0.title == "compact" }.map(\.id)
    guard compactRowIDs == ["array:compact"] else {
        throw Failure(description: "legacy provider compact commands produced duplicate completion rows")
    }
}
