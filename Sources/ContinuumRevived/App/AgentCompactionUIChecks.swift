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
    private let trailingReading: Int?
    private let firstTurnContextFull: Bool
    private var observationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?
    private var firstRun = true
    private var compactionOnEvent: (@Sendable (AgentRuntimeEvent) -> Void)?
    private(set) var operations: [String] = []

    init(
        blockFirstTurn: Bool = false,
        result: Result = .succeed,
        supportsFocus: Bool = true,
        postTokens: Int? = 20_000,
        postPrecision: AgentCompactionTokenPrecision = .exact,
        trailingReading: Int? = nil,
        firstTurnContextFull: Bool = false
    ) {
        firstTurnGate = blockFirstTurn ? DispatchSemaphore(value: 0) : nil
        self.result = result
        self.supportsFocus = supportsFocus
        self.postTokens = postTokens
        self.postPrecision = postPrecision
        self.trailingReading = trailingReading
        self.firstTurnContextFull = firstTurnContextFull
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
        lock.withLock { observationHandler }?(.threadId("script-context-thread"))
        let turnID = UUID().uuidString
        onEvent(.turnStarted(threadId: "provider", turnId: turnID))
        if shouldWait { firstTurnGate?.wait() }
        onEvent(.turnCompleted(
            threadId: "provider", turnId: turnID,
            outcome: shouldWait && firstTurnContextFull ? .failed : .completed,
            errorMessage: shouldWait && firstTurnContextFull ? AgentContextFullRecovery.canonicalErrorMessage : nil))
    }

    func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        lock.withLock {
            operations.append("compact")
            compactionOnEvent = onEvent
        }
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
            // The provider's own report AFTER its boundary, from the live
            // operation. It is the newest reading and must be shown: the old
            // operation-start epoch stamp dropped exactly this (T1), which is
            // how claude's compact_boundary snapshot never reached the ring.
            if let trailingReading {
                onEvent(.contextWindowUpdated(
                    threadId: "provider",
                    snapshot: AgentContextWindowSnapshot(
                        usedTokens: trailingReading, maxTokens: 100_000,
                        observedAt: Date(), source: .providerSessionStats, freshness: .live)))
            }
        }
        if result == .fail { throw NSError(domain: "AgentCompactionUICheck", code: 1) }
    }

    func stop() { firstTurnGate?.signal() }
    func releaseFirstTurn() { firstTurnGate?.signal() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        lock.withLock { observationHandler = handler }
    }
    func snapshotOperations() -> [String] { lock.withLock { operations } }
    /// A late frame from the finished compaction operation's callback — the
    /// shape the epoch stamp used to guard. The runner-generation token must
    /// reject it on its own.
    func emitLateFromFinishedCompaction(_ event: AgentRuntimeEvent) {
        lock.withLock { compactionOnEvent }?(event)
    }
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

    // The same native error renderer must expose the same three recovery
    // choices regardless of which translator produced the canonical marker.
    var recoveryActions: [AgentRenderAction] = []
    let recoveryContext = AgentRenderContext(
        actions: AgentRenderActions { recoveryActions.append($0) },
        tokens: .transcript,
        appearance: .dark)
    let contextFullBlock = AgentBlock(
        id: AgentNodeID(rawValue: "context-full-recovery")!,
        revision: 1,
        kind: .error,
        payload: .error(.init(message: AgentContextFullRecovery.canonicalErrorMessage)))
    let contextFullRenderer = ErrorNoticeRenderer(kind: .error)
    let contextFullHeight = contextFullRenderer.measure(
        block: contextFullBlock, width: 320, context: recoveryContext)
    let contextFullView = contextFullRenderer.makeView() as! AgentErrorNoticeView
    contextFullView.frame = NSRect(x: 0, y: 0, width: 320, height: contextFullHeight)
    contextFullRenderer.update(view: contextFullView, block: contextFullBlock, context: recoveryContext)
    contextFullView.layoutSubtreeIfNeeded()
    guard !contextFullView.compactRetryButton.isHidden,
          !contextFullView.forkSummaryButton.isHidden,
          !contextFullView.copyTranscriptButton.isHidden,
          contextFullView.retryButton.isHidden,
          contextFullView.copyButton.isHidden,
          contextFullView.copyTranscriptButton.frame.maxY <= contextFullView.bounds.maxY + 0.5 else {
        throw Failure(description: "context-full error did not show the shared bounded recovery controls")
    }
    contextFullView.compactRetryButton.performClick(nil)
    contextFullView.forkSummaryButton.performClick(nil)
    contextFullView.copyTranscriptButton.performClick(nil)
    guard recoveryActions.count == 3,
          case .contextFullRecovery(blockID: contextFullBlock.id, action: .compactAndRetry) = recoveryActions[0],
          case .contextFullRecovery(blockID: contextFullBlock.id, action: .forkWithSummary) = recoveryActions[1],
          case .contextFullRecovery(blockID: contextFullBlock.id, action: .copyTranscript) = recoveryActions[2] else {
        throw Failure(description: "context-full recovery controls did not dispatch their three scoped intents")
    }

    // The ring itself becomes actionable at the same 75% warning state it
    // already renders. Keep the execution route at the tile/session boundary.
    let warningContext = AgentRadialContextMeterPresentation(
        state: .warning, fraction: 0.80, label: "80%", accessibilityLabel: "Context window 80 percent used.",
        detailText: "80 percent used", warningMarker: "⚠︎")
    let warningPresentation = AgentCompactStatusPresentation(
        location: .init(symbolName: "house", text: "project root", accessibilityLabel: "Home and Where: project root.", detailText: "project root", isExternal: false),
        activity: .silent(detailText: "Activity phase: idle."),
        context: warningContext,
        quotas: [], cost: nil,
        enabledElements: [.location, .activity, .contextMeter])
    let compactRow = AgentCompactStatusRowView()
    compactRow.frame = NSRect(x: 0, y: 0, width: 420, height: AgentCompactStatusRowView.preferredHeight)
    var compactRequested = false
    compactRow.onCompactContextRequested = { compactRequested = true }
    compactRow.apply(warningPresentation)
    compactRow.layoutSubtreeIfNeeded()
    guard compactRow.qaCompactContextButtonVisible,
          compactRow.qaCompactContextButtonEnabled else {
        throw Failure(description: "warning context reading did not expose the native Compact action")
    }
    compactRow.qaPerformCompactContextAction()
    guard compactRequested else {
        throw Failure(description: "native Compact action did not reach the row callback")
    }
    let normalPresentation = AgentCompactStatusPresentation(
        location: warningPresentation.location,
        activity: warningPresentation.activity,
        context: AgentRadialContextMeterPresentation(
            state: .known, fraction: 0.50, label: "50%", accessibilityLabel: "Context window 50 percent used.",
            detailText: "50 percent used", warningMarker: nil),
        quotas: [], cost: nil, enabledElements: warningPresentation.enabledElements)
    compactRow.apply(normalPresentation)
    guard !compactRow.qaCompactContextButtonVisible else {
        throw Failure(description: "native Compact action remained visible below the warning threshold")
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-compaction-ui-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Array's compaction meter must never promote a bundled denominator to
    // provider-stated memory. Otherwise a future table update is shadowed.
    do {
        let provenanceRoot = root.appendingPathComponent("meter-provenance")
        let bundled = AgentContextWindowResolver.bundledWindows()
        guard let model = bundled.keys.sorted().first(where: { $0.hasPrefix("anthropic/") }),
              let originalWindow = bundled[model] else {
            throw Failure(description: "meter provenance requires a shipped Claude model window")
        }
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: provenanceRoot),
            makeRunner: { _ in CompactionScriptRunner() })
        defer { supervisor.stopAll() }
        supervisor.qaContextAutoCompactionThreshold = { nil }
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root,
            harness: .claudeCode, model: model, thinking: "low")
        supervisor.qaDeliver(.contextWindowUpdated(threadId: "provenance", snapshot: AgentContextWindowSnapshot(
            usedTokens: 10_000, maxTokens: nil, observedAt: Date(),
            source: .providerSessionStats, freshness: .live)), to: id)
        guard supervisor.contextWindowSnapshot(for: id)?.windowResolutionSource == .bundled,
              supervisor.records[id]?.providerContextWindows[model] == nil else {
            throw Failure(description: "initial provider usage must resolve the shipped window without remembering a provider window")
        }
        supervisor.qaDeliver(.compactionChanged(threadId: "provenance", event: AgentCompactionLifecycleEvent(
            operationID: UUID(), boundaryID: "provenance-boundary", phase: .succeeded, trigger: .providerAutomatic,
            beforeTokens: AgentCompactionTokenReading(10_000, precision: .exact),
            afterTokens: AgentCompactionTokenReading(1_000, precision: .exact), provider: "script")), to: id)
        guard supervisor.records[id]?.providerContextWindows[model] == nil else {
            throw Failure(description: "Array's published compaction meter falsely remembered its bundled window as provider-stated")
        }
        let updatedWindow = originalWindow + 1_024
        let nextTable = AgentContextWindowResolver(applicationSupportDirectory: provenanceRoot,
            bundledWindows: [model: updatedWindow])
        let updated = nextTable.resolve(harness: .claudeCode, model: model)
        guard updated.tokens == updatedWindow, updated.source == .bundled else {
            throw Failure(description: "Array's published meter shadowed a future bundled-window update with false provider memory")
        }
        let statedWindow = originalWindow + 2_048
        supervisor.qaDeliver(.contextWindowUpdated(threadId: "provenance", snapshot: AgentContextWindowSnapshot(
            usedTokens: 2_000, maxTokens: statedWindow, observedAt: Date(),
            source: .providerSessionStats, freshness: .live)), to: id)
        guard supervisor.records[id]?.providerContextWindows[model] == statedWindow,
              nextTable.resolve(harness: .claudeCode, model: model).tokens == statedWindow,
              nextTable.resolve(harness: .claudeCode, model: model).source == .remembered else {
            throw Failure(description: "a genuine provider-stated window must remain remembered above bundled windows")
        }
    }

    for harness in AgentHarness.allCases {
        // The provider compacts in the same actor beat after a critical reading,
        // before Array's queued automatic request gets its turn. Old-epoch work
        // must not compact the freshly compacted context a second time.
        let epochRoot = root.appendingPathComponent("epoch-\(harness.rawValue)")
        let epochRunner = CompactionScriptRunner()
        let epochSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: epochRoot), makeRunner: { _ in epochRunner },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: epochRoot, debounceInterval: 0))
        epochSupervisor.qaContextAutoCompactionThreshold = { 0.90 }
        var automaticConsiderationFinished = false
        epochSupervisor.qaDidFinishAutomaticContextCompaction = { automaticConsiderationFinished = true }
        let epochConfig = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let epochID = epochSupervisor.spawn(role: nil, prompt: nil, cwd: root,
            harness: harness, model: epochConfig.model, thinking: epochConfig.thinking)
        guard epochSupervisor.send("epoch seed", to: epochID) else {
            throw Failure(description: "\(harness) epoch witness seed refused")
        }
        try await expectEventually("\(harness) epoch witness seed did not settle") {
            !epochSupervisor.isRunning(epochID) && epochRunner.snapshotOperations() == ["run:epoch seed"]
        }
        epochSupervisor.qaDeliver(.contextWindowUpdated(threadId: "epoch", snapshot: AgentContextWindowSnapshot(
            usedTokens: 95_000, maxTokens: 100_000, observedAt: Date(),
            source: .providerSessionStats, freshness: .live)), to: epochID)
        epochSupervisor.qaDeliver(.compactionChanged(threadId: "epoch", event: AgentCompactionLifecycleEvent(
            operationID: UUID(), boundaryID: "provider-epoch", phase: .succeeded, trigger: .providerAutomatic,
            beforeTokens: AgentCompactionTokenReading(95_000, precision: .exact),
            afterTokens: AgentCompactionTokenReading(20_000, precision: .exact), provider: "script")), to: epochID)
        try await expectEventually("\(harness) automatic request did not finish its actor beat") {
            automaticConsiderationFinished
        }
        guard epochSupervisor.records[epochID]?.contextEpoch == 1,
              epochRunner.snapshotOperations() == ["run:epoch seed"] else {
            throw Failure(description: "\(harness) stale automatic request compacted a new provider epoch")
        }

        let recoveryRoot = root.appendingPathComponent("recovery-\(harness.rawValue)")
        let recoveryRunner = CompactionScriptRunner(firstTurnContextFull: true)
        let recoveryStore = AgentComposerDraftStore(applicationSupportDirectory: recoveryRoot, debounceInterval: 0)
        let recoverySupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: recoveryRoot), makeRunner: { _ in recoveryRunner },
            submissionRecoveryStore: recoveryStore,
            transcriptStore: AgentTranscriptStore(root: recoveryRoot.appendingPathComponent("transcripts")))
        let configuration = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let recoveryID = recoverySupervisor.spawn(role: nil, prompt: nil, cwd: root,
            harness: harness, model: configuration.model, thinking: configuration.thinking)
        guard recoverySupervisor.send("preserve original request", to: recoveryID) else {
            throw Failure(description: "\(harness) recovery original prompt refused")
        }
        try await expectEventually("\(harness) context-full terminal never settled") {
            !recoverySupervisor.isRunning(recoveryID) && recoverySupervisor.isQueuePaused(for: recoveryID)
        }
        _ = await recoveryStore.enqueueMessage(text: "later follow-up", for: recoveryID)
        guard await recoverySupervisor.recoverContextFull(.compactAndRetry, for: recoveryID) == recoveryID else {
            throw Failure(description: "\(harness) compact and retry refused")
        }
        try await expectEventually("\(harness) compact/retry lost or reordered the original request") {
            recoveryRunner.snapshotOperations() == ["run:preserve original request", "compact",
                "run:preserve original request", "run:later follow-up"]
        }
        try await expectEventually("\(harness) compact/retry did not finish") {
            !recoverySupervisor.isRunning(recoveryID)
        }
        guard await recoverySupervisor.recoverContextFull(.compactAndRetry, for: recoveryID) == nil else {
            throw Failure(description: "\(harness) stale context-full retry ran after a later successful turn")
        }
        recoverySupervisor.qaDeliver(.turnCompleted(threadId: "recovery", turnId: "new-limit",
            outcome: .failed, errorMessage: AgentContextFullRecovery.canonicalErrorMessage), to: recoveryID)
        guard let continued = await recoverySupervisor.recoverContextFull(.forkWithSummary, for: recoveryID),
              continued != recoveryID, recoverySupervisor.records[recoveryID] != nil,
              recoverySupervisor.records[continued]?.harness == harness else {
            throw Failure(description: "\(harness) summary recovery must preserve the old session and harness")
        }
        try await expectEventually("\(harness) summary session did not finish") {
            !recoverySupervisor.isRunning(continued)
        }
        guard recoveryRunner.snapshotOperations().last?.contains("preserve original request") == true else {
            throw Failure(description: "\(harness) summary session lost the original task context")
        }
    }

    // `.plans/79`: an original request another agent sent arrived inside
    // Array's envelope. The handoff summary carries its words, never the tags.
    do {
        let envelopeRoot = root.appendingPathComponent("recovery-envelope")
        let envelopeRunner = CompactionScriptRunner(firstTurnContextFull: true)
        let envelopeSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: envelopeRoot), makeRunner: { _ in envelopeRunner },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: envelopeRoot, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: envelopeRoot.appendingPathComponent("transcripts")))
        let configuration = AgentModelConfig.resolvedFromDefaults(harness: .pi)
        let sender = envelopeSupervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .pi,
            model: configuration.model, thinking: configuration.thinking, displayName: "Lead")
        let receiver = envelopeSupervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .pi,
            model: configuration.model, thinking: configuration.thinking)
        guard envelopeSupervisor.sendAgentMessage("audit the envelope parser", from: sender, to: receiver) else {
            throw Failure(description: "the agent message that becomes the original request was refused")
        }
        try await expectEventually("the envelope request's context-full turn never settled") {
            !envelopeSupervisor.isRunning(receiver) && envelopeSupervisor.isQueuePaused(for: receiver)
        }
        guard let continued = await envelopeSupervisor.recoverContextFull(.forkWithSummary, for: receiver) else {
            throw Failure(description: "summary recovery of an agent-message request was refused")
        }
        try await expectEventually("the envelope summary session did not finish") { !envelopeSupervisor.isRunning(continued) }
        let carried = envelopeRunner.snapshotOperations().last ?? ""
        guard carried.contains("original request: audit the envelope parser"),
              !carried.contains("<\(AgentMessageEnvelope.tag)") else {
            throw Failure(description: "the handoff summary must carry the agent message's words, not its envelope: \(carried.prefix(240))")
        }
        envelopeSupervisor.stopAll()
    }

    let runner = CompactionScriptRunner(blockFirstTurn: true, trailingReading: 20_500)
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
          supervisor.contextWindowSnapshot(for: id)?.usedTokens == 20_500 else {
        throw Failure(description: "duplicate success advanced the epoch twice, or the provider's post-boundary reading was dropped (meter \(String(describing: supervisor.contextWindowSnapshot(for: id)?.usedTokens)))")
    }
    // Staleness is the runner generation's job now: the finished operation's
    // callback can still fire, and its reading must not land.
    runner.emitLateFromFinishedCompaction(.contextWindowUpdated(
        threadId: "provider",
        snapshot: AgentContextWindowSnapshot(
            usedTokens: 90_000, maxTokens: 100_000,
            observedAt: Date(), source: .providerSessionStats, freshness: .live)))
    try await Task.sleep(for: .milliseconds(100))
    guard supervisor.contextWindowSnapshot(for: id)?.usedTokens == 20_500 else {
        throw Failure(description: "a retired runner generation repainted the meter")
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
          unknownSupervisor.contextWindowSnapshot(for: unknownID)?.usedTokens == nil else {
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
    // The runner having STARTED is not the supervisor having SEEN the turn:
    // compaction is refused until `turnStarted` (or a session id) reaches the
    // record, and both arrive on a later main-queue turn. Waiting on the runner
    // alone raced, and lost as soon as `send` did any work of its own.
    try await expectEventually("failed-path seed turn never reached the supervisor") {
        failedSupervisor.records[failedID]?.latestTurnAt != nil
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

    try await runAgentContextMeterChecks(root: root.appendingPathComponent("meter", isDirectory: true))

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
