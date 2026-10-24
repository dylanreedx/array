import Foundation

// M2 (`.plans/46`): the pi rpc SESSION runner -- one long-lived `pi --mode
// rpc` child serving many turns, on top of `PiRpcTransport`. Shares
// `PiAgentRunner.Config` (same model/thinking/cwd/session/extension shape) and
// the SAME `PiEventTranslator` (the whole reason rpc is a cheap change: the
// event stream is one function shared with `--mode json`).
//
// This type does NOT declare conformance to `AgentRunning` or the new
// `AgentSessionRunning` refinement -- both protocols live in the app target
// (`AgentSupervisor.swift`), which Core cannot see. It exposes exactly the
// method shapes those protocols need (`run`, `stop`, `observeSpawnRequests`,
// `observeRuntimeObservations`, `sessionCapabilities`, `steer`, `interrupt`,
// `command`); the app target's conformance is a same-signature `extension`
// with no logic of its own, matching how `PiAgentRunner`/`ClaudeAgentRunner`/
// `CodexAgentRunner` are wired to `AgentRunning` today.
//
// ASSUMPTION flagged for verification against a real `pi --mode rpc` process
// before this ships (not settled in the M0 probe): the `prompt`/`steer`
// command payload's text field is named `"message"`. The probe measured
// framing and the 31-command vocabulary but could not drive a real multi-second
// turn (see the ledger's caveat) so this one field name is inferred from
// `PiAgentRunner.promptArgumentSegments`' shape, not captured live.
#if os(macOS)

public final class PiRpcAgentRunner: @unchecked Sendable {
    public typealias Config = PiAgentRunner.Config

    public enum RunError: Error, CustomStringConvertible, AgentRunFailureDescribing {
        case launchFailed(String)
        case commandFailed(command: String, message: String)
        /// The rpc process exited with a turn or compaction in flight.
        case exitedMidTurn(operation: String, stderr: String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .commandFailed(let command, let message):
                return "commandFailed(\(command): \(SecretRedactor.redactLocalDiagnostics(message)))"
            case .exitedMidTurn(let operation, let stderr):
                return "exitedMidTurn(\(operation), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            }
        }

        public var userFacingDescription: String {
            switch self {
            case .launchFailed(let message):
                return "Pi could not start: \(SecretRedactor.redactLocalDiagnostics(message))"
            case .commandFailed(let command, let message):
                return "Pi refused \(command): \(SecretRedactor.redactLocalDiagnostics(message))"
            case .exitedMidTurn(let operation, let stderr):
                let head = "Pi exited without finishing the \(operation)"
                return AgentFailureText.stderrTail(stderr).map { "\(head): \($0)" } ?? "\(head)."
            }
        }

        public var isProcessLoss: Bool {
            if case .exitedMidTurn = self { return true }
            return false
        }
    }

    public let config: Config
    public let sessionCapabilities: PiRpcSessionCapabilities = .full
    public var compactionCapabilities: AgentCompactionCapabilities {
        let policy = queue.sync { observedAutomaticCompactionPolicy }
        return AgentCompactionCapabilities(
            supportsManual: true, supportsFocus: true, automaticPolicy: policy)
    }

    /// True only while the long-lived RPC child is available for another turn.
    /// The app uses this at the idle-session boundary so an unexpectedly exited
    /// child is never put back in the per-agent reuse pool.
    public var isSessionRunning: Bool { transport.isRunning }

    private let transport = PiRpcTransport()
    private let queue = DispatchQueue(label: "continuum.pi-rpc-agent-runner")
    private var translator: PiEventTranslator
    private var started = false
    private var stopRequested = false
    private var idleExitHandler: (@Sendable (Int32, String?, Bool) -> Void)?
    /// Signalled by the event stream when the in-flight turn reaches
    /// `.turnCompleted`. One at a time -- `run` is documented (like the other
    /// two runners) as blocking until its own turn finishes; the supervisor
    /// serializes calls to `run` today, and this runner does not attempt to
    /// widen that.
    private var turnSemaphore: DispatchSemaphore?
    private var turnOutcomeError: Error?
    private var compactionSemaphore: DispatchSemaphore?
    private var compactionOutcomeError: Error?
    private var observedAutomaticCompactionPolicy: AgentAutomaticCompactionPolicy?
    private var observedAdvertisedCommands: Set<String>?
    /// T5 — steers pi has accepted into its steering queue and not yet taken,
    /// oldest first. pi drains that queue FIFO and says so with `queue_update`.
    private var pendingSteerIDs: [UUID] = []
    private var steerDispositionHandler: (@Sendable (UUID, AgentSteerDisposition) -> Void)?

    /// The session's own slash commands, as answered by `get_commands`, or nil
    /// when this session has not answered with a parseable list.
    ///
    /// `get_commands` is deliberately absent from `PiRpcCommand.knownTypes` --
    /// it returns the SESSION's slash commands rather than the rpc vocabulary --
    /// and nothing had ever called it. It is pi's exact counterpart to claude's
    /// `slash_commands` on `system/init`, and it is what lets the command
    /// classifier narrow instead of trusting a frozen baseline forever.
    public var advertisedCommandNames: Set<String>? {
        queue.sync { observedAdvertisedCommands }
    }

    // CX-01 host tool bridge state (`.plans/59`, §15). All `queue`-confined.
    private enum HostToolPhase { case dispatched, cancelRequested, toolReturned, answered }
    private struct HostToolEntry {
        let call: PiHostToolCall
        var phase: HostToolPhase
        let deadline: DispatchWorkItem
    }
    private var hostToolHandler: (@Sendable (PiHostToolCall) -> Void)?
    private var hostToolPending: [String: HostToolEntry] = [:]
    private var hostToolPiIdByRequestId: [String: String] = [:]
    /// Replies are written from here, never from the transport or runner queue:
    /// `transport.onEvent` runs `queue.sync`, and `transport.send` runs its own
    /// `queue.sync`, so answering synchronously inside a translator hook deadlocks.
    private let bridgeQueue = DispatchQueue(label: "continuum.pi-rpc-host-tool-bridge")
    private let scheduleHostToolDeadline: @Sendable (TimeInterval, DispatchWorkItem, DispatchQueue) -> Void
    /// How long the host may take before the model is told `outcome_unknown`.
    /// Match the MCP clients' 24-hour request horizon: the host can be holding
    /// a real user approval, which has no independent deadline. The extension
    /// waits slightly longer so this structured answer still wins. Injectable
    /// for the bridge witnesses.
    public var hostToolDeadline: TimeInterval {
        get { queue.sync { hostToolDeadlineStorage } }
        set { queue.sync { hostToolDeadlineStorage = newValue } }
    }
    private var hostToolDeadlineStorage: TimeInterval = TimeInterval(WorkspaceMCPConfiguration.toolCallTimeoutSeconds)

    public init(
        config: Config,
        hostToolDeadlineScheduler: @escaping @Sendable (TimeInterval, DispatchWorkItem, DispatchQueue) -> Void = { interval, item, queue in
            queue.asyncAfter(deadline: .now() + interval, execute: item)
        }
    ) {
        self.config = config
        self.scheduleHostToolDeadline = hostToolDeadlineScheduler
        self.translator = PiEventTranslator(workingDirectory: config.cwd)
        transport.onEvent = { [weak self] line in
            self?.queue.sync { self?.handleEventLine(line) }
        }
        // Both hooks fire INSIDE `handleEventLine`, i.e. already on `queue`.
        translator.onHostToolRequest = { [weak self] request in
            self?.receiveHostToolRequestOnQueue(request)
        }
        translator.onToolExecutionEnded = { [weak self] toolCallId in
            self?.hostToolReturnedOnQueue(toolCallId: toolCallId)
        }
        transport.onExit = { [weak self] code in
            self?.queue.sync {
                guard let self else { return }
                // S3 (N3): the session process left between turns, unasked.
                if self.turnSemaphore == nil, self.compactionSemaphore == nil, !self.stopRequested,
                   let handler = self.idleExitHandler {
                    let tail = self.transport.stderrTail.summary
                    DispatchQueue.global(qos: .utility).async { handler(code, tail, false) }
                }
                if let semaphore = self.turnSemaphore {
                    // Let the pipe's last bytes land before reading the tail.
                    Thread.sleep(forTimeInterval: 0.05)
                    self.turnOutcomeError = RunError.exitedMidTurn(operation: "turn", stderr: self.transport.stderrTail.text)
                    self.turnSemaphore = nil
                    semaphore.signal()
                }
                if let semaphore = self.compactionSemaphore {
                    self.compactionOutcomeError = RunError.exitedMidTurn(operation: "compaction", stderr: self.transport.stderrTail.text)
                    self.compactionSemaphore = nil
                    semaphore.signal()
                }
            }
        }
    }

    deinit {
        // An idle RPC runner is intentionally retained between turns. If its
        // owner disappears without an explicit app/archive teardown, do not
        // leave Pi (or any tool subprocess in its process group) orphaned.
        transport.stop(graceSeconds: ProcessGroupChild.Grace.interactive)
    }

    // MARK: - AgentRunning-shaped surface

    /// Starts the child on first call; every subsequent call reuses the SAME
    /// process -- the entire point of M2. Blocks until the turn this `prompt`
    /// starts reaches `.turnCompleted`.
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try queue.sync {
            if stopRequested { throw AgentRunStopped(detail: "") }
        }
        try ensureStarted()
        emitObservedAutomaticCompactionPolicy(to: onEvent)

        let semaphore = DispatchSemaphore(value: 0)
        queue.sync {
            turnSemaphore = semaphore
            turnOutcomeError = nil
            self.currentOnEvent = onEvent
        }

        let payload: [String: Any]
        do {
            payload = try Self.promptPayload(prompt)
        } catch {
            queue.sync { turnSemaphore = nil; currentOnEvent = nil }
            throw RunError.commandFailed(
                command: "prompt", message: "could not prepare a local image attachment")
        }
        do {
            _ = try transport.sendAndAwait(type: "prompt", payload: payload)
        } catch {
            queue.sync { turnSemaphore = nil; currentOnEvent = nil }
            throw RunError.commandFailed(command: "prompt", message: String(describing: error))
        }

        semaphore.wait()
        let outcomeError = queue.sync { () -> Error? in
            let error = turnOutcomeError
            currentOnEvent = nil
            return error
        }
        if let outcomeError {
            if queue.sync { stopRequested } { throw AgentRunStopped(detail: String(describing: outcomeError)) }
            throw outcomeError
        }
    }

    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    public func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        try queue.sync {
            if stopRequested { throw AgentRunStopped(detail: "") }
            if turnSemaphore != nil || compactionSemaphore != nil {
                throw RunError.commandFailed(command: "compact", message: "another operation is active")
            }
        }
        try ensureStarted()
        emitObservedAutomaticCompactionPolicy(to: onEvent)
        let semaphore = DispatchSemaphore(value: 0)
        queue.sync {
            compactionSemaphore = semaphore
            compactionOutcomeError = nil
            currentOnEvent = { event in
                if case .compactionChanged(let threadId, var lifecycle) = event {
                    lifecycle.operationID = request.operationID
                    lifecycle.trigger = .manual
                    onEvent(.compactionChanged(threadId: threadId, event: lifecycle))
                } else {
                    onEvent(event)
                }
            }
        }
        var payload: [String: Any] = [:]
        if let focus = request.focus?.trimmingCharacters(in: .whitespacesAndNewlines), !focus.isEmpty {
            payload["customInstructions"] = focus
        }
        do {
            _ = try transport.sendAndAwait(type: "compact", payload: payload)
        } catch {
            queue.sync { compactionSemaphore = nil; currentOnEvent = nil }
            throw RunError.commandFailed(command: "compact", message: String(describing: error))
        }
        semaphore.wait()
        let outcome = queue.sync { () -> Error? in
            defer { currentOnEvent = nil }
            return compactionOutcomeError
        }
        if let outcome { throw outcome }
    }

    /// SIGTERM the group (never SIGINT, rpc has no handler for it) at the
    /// interactive grace. Unlike the one-shot runner, this does not merely
    /// end one turn -- it ends the whole session, because there is no
    /// documented `abort`-then-keep-running use here (the tile is closing).
    public func stop() {
        queue.sync { stopRequested = true }
        transport.stop(graceSeconds: ProcessGroupChild.Grace.interactive)
        queue.sync {
            // The child is gone: every pending host call is cancelled AND can no
            // longer be answered on this transport.
            for (piId, var entry) in hostToolPending {
                entry.deadline.cancel()
                entry.phase = .answered
                hostToolPending[piId] = entry
                entry.call.markCancelled()
            }
            hostToolPending.removeAll()
            hostToolPiIdByRequestId.removeAll()
            if let semaphore = turnSemaphore {
                turnOutcomeError = AgentRunStopped(detail: "")
                turnSemaphore = nil
                semaphore.signal()
            }
            if let semaphore = compactionSemaphore {
                compactionOutcomeError = AgentRunStopped(detail: "")
                compactionSemaphore = nil
                semaphore.signal()
            }
        }
    }

    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        queue.sync { translator.onSpawnRequest = handler }
    }

    public func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        queue.sync { translator.onRuntimeObservation = handler }
    }

    // MARK: - CX-01 host tool bridge (`HostToolBridging`)

    /// The supervisor installs this per runner instance and hops to the main
    /// actor itself, exactly like `observeSpawnRequests`. A request arriving with
    /// no handler bound is answered `unsupported` immediately so the model never
    /// hangs on an unbound runner.
    public func observeHostToolRequests(_ handler: @escaping @Sendable (PiHostToolCall) -> Void) {
        queue.sync { hostToolHandler = handler }
    }

    /// QA: the pi ids still awaiting an answer.
    public var qaPendingHostToolRequestIds: [String] {
        queue.sync { hostToolPending.filter { $0.value.phase != .answered }.keys.sorted() }
    }

    /// `queue`-confined (called from the translator hook inside `handleEventLine`).
    private func receiveHostToolRequestOnQueue(_ request: PiHostToolRequest) {
        let piId = request.piRequestId
        guard hostToolPending[piId] == nil else { return }
        let deadline = DispatchWorkItem { [weak self] in
            self?.completeHostToolRequest(piId: piId, response: .transportTimeout, completion: nil)
        }
        let call = PiHostToolCall(request: request) { [weak self] response, completion in
            guard let self else { completion?(.droppedRunnerGone); return }
            self.bridgeQueue.async {
                self.completeHostToolRequest(piId: piId, response: response, completion: completion)
            }
        }
        hostToolPending[piId] = HostToolEntry(call: call, phase: .dispatched, deadline: deadline)
        hostToolPiIdByRequestId[request.requestId] = piId
        scheduleHostToolDeadline(hostToolDeadlineStorage, deadline, bridgeQueue)
        if let hostToolHandler {
            hostToolHandler(call)
        } else {
            bridgeQueue.async { [weak self] in
                self?.completeHostToolRequest(piId: piId, response: .unsupportedUnbound, completion: nil)
            }
        }
    }

    /// `queue`-confined. pi already has this call's answer (it aborted, or its own
    /// timeout fired); a host reply from now on is recorded, not written.
    private func hostToolReturnedOnQueue(toolCallId: String) {
        guard let piId = hostToolPiIdByRequestId[toolCallId], var entry = hostToolPending[piId] else { return }
        entry.deadline.cancel()
        if entry.phase != .answered { entry.phase = .toolReturned }
        hostToolPending[piId] = entry
        entry.call.markCancelled()
    }

    /// `queue`-confined. Abort, or the turn ending, means pi has dropped (or is
    /// about to drop) every pending dialog; the host may still be working, and if
    /// it commits it must say so through `recentOperations`.
    private func cancelAllHostToolCallsOnQueue() {
        for (piId, var entry) in hostToolPending where entry.phase == .dispatched {
            entry.phase = .cancelRequested
            hostToolPending[piId] = entry
            entry.call.markCancelled()
        }
    }

    /// `bridgeQueue`-confined: the ONLY writer of `extension_ui_response`.
    private func completeHostToolRequest(
        piId: String,
        response: PiHostToolResponse,
        completion: (@Sendable (PiHostToolDelivery) -> Void)?
    ) {
        let decision: (PiHostToolDelivery?, PiHostToolCall?) = queue.sync {
            guard var entry = hostToolPending[piId] else { return (.droppedRunnerGone, nil) }
            switch entry.phase {
            case .answered:
                return (.droppedAlreadyAnswered, nil)
            case .toolReturned:
                entry.phase = .answered
                hostToolPending[piId] = entry
                hostToolPiIdByRequestId[entry.call.request.requestId] = nil
                return (.droppedToolReturned, nil)
            case .dispatched, .cancelRequested:
                entry.deadline.cancel()
                let wasCancelled = entry.phase == .cancelRequested
                entry.phase = .answered
                hostToolPending[piId] = entry
                hostToolPiIdByRequestId[entry.call.request.requestId] = nil
                return (wasCancelled ? .sentAfterCancel : nil, entry.call)
            }
        }
        guard let call = decision.1 else {
            completion?(decision.0 ?? .droppedRunnerGone)
            return
        }
        let value = response.encodedValue(requestId: call.request.requestId)
        do {
            _ = try transport.send(type: "extension_ui_response", payload: ["value": value], id: piId)
            completion?(decision.0 ?? .delivered)
        } catch {
            completion?(.droppedRunnerGone)
        }
    }

    // MARK: - Session-runner surface (`AgentSessionRunning`, wired in the app target)

    /// True while a `run` is waiting on its turn, i.e. while a steer lands in it.
    public var acceptsSteerNow: Bool {
        queue.sync { started && !stopRequested && turnSemaphore != nil }
    }

    /// T5 — a steer with an id, images included, into the turn in flight.
    /// Delivered after the current assistant turn finishes its tool calls,
    /// before the next LLM call; `queue_update` reports when pi took it.
    /// pi refuses an extension slash command here, which surfaces as
    /// `AgentSteerNotAccepted` so the supervisor keeps the message.
    public func steer(_ prompt: AgentPrompt, id: UUID) throws {
        let payload: [String: Any]
        do {
            payload = try Self.promptPayload(prompt)
        } catch {
            throw AgentSteerNotAccepted("could not prepare a local image attachment")
        }
        try queue.sync {
            guard started, !stopRequested, turnSemaphore != nil else {
                throw AgentSteerNotAccepted("no pi turn is in flight")
            }
            // Recorded before the send: pi emits its `queue_update` before the
            // command's response.
            pendingSteerIDs.append(id)
        }
        do {
            _ = try transport.sendAndAwait(type: "steer", payload: payload)
        } catch {
            queue.sync { pendingSteerIDs.removeAll { $0 == id } }
            throw AgentSteerNotAccepted(String(describing: error))
        }
    }

    public func observeSteerDispositions(
        _ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void
    ) {
        queue.sync { steerDispositionHandler = handler }
    }

    /// Turn-boundary steering (`agent-session.js:986`): delivered after the
    /// current assistant turn finishes its tool calls, before the next LLM
    /// call. NOT mid-tool interruption -- callers must not describe it as one.
    public func steer(_ text: String) throws {
        guard queue.sync(execute: { started }) else { throw RunError.launchFailed("session not started") }
        do {
            _ = try transport.sendAndAwait(type: "steer", payload: ["message": text])
        } catch {
            throw RunError.commandFailed(command: "steer", message: String(describing: error))
        }
    }

    /// `abort`: awaited, answers a success response, and leaves the
    /// connection healthy for the next `prompt` -- unlike `stop()`, this does
    /// NOT kill the process.
    public func interrupt() throws {
        guard queue.sync(execute: { started }) else { throw RunError.launchFailed("session not started") }
        do {
            _ = try transport.sendAndAwait(type: "abort")
        } catch {
            throw RunError.commandFailed(command: "abort", message: String(describing: error))
        }
        // pi resolves every pending dialog `undefined` on abort; tell the host
        // before it commits anything else for this turn.
        queue.sync { cancelAllHostToolCallsOnQueue() }
        // T5 — `abort` leaves pi's steering queue armed for whatever prompt
        // comes next. Clear it, and hand back what it held: a steer pi never
        // read is the user's message again, not something already sent.
        let unread = queue.sync { () -> [UUID] in
            defer { pendingSteerIDs.removeAll() }
            return pendingSteerIDs
        }
        guard !unread.isEmpty else { return }
        _ = try? transport.sendAndAwait(type: "clear_queue")
        let handler = queue.sync { steerDispositionHandler }
        for id in unread { handler?(id, .returned) }
    }

    /// Escape hatch onto the raw vocabulary (`get_state`, `set_model`,
    /// `fork`, ...) for callers `run`/`steer`/`interrupt`/`stop` do not cover.
    @discardableResult
    public func command(_ type: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        guard queue.sync(execute: { started }) else { throw RunError.launchFailed("session not started") }
        do {
            return try transport.sendAndAwait(type: type, payload: payload)
        } catch {
            throw RunError.commandFailed(command: type, message: String(describing: error))
        }
    }

    // MARK: - Private

    /// Set only while a `run` call is in flight, so `handleEventLine` knows
    /// where to forward translated events. `steer`/`interrupt` events during
    /// an in-flight turn land on this same callback, matching one-shot
    /// behaviour where all of a turn's events go to that turn's `onEvent`.
    private var currentOnEvent: (@Sendable (AgentRuntimeEvent) -> Void)?

    private func ensureStarted() throws {
        let alreadyStarted = queue.sync { started }
        guard !alreadyStarted else { return }

        let command = PiAgentRunner.liveResolvedCommand()
        let arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            thinking: config.thinking,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            extensionPaths: config.extensionPaths
        )
        do {
            try transport.start(
                executable: command.executable,
                arguments: arguments,
                environment: PiAgentRunner.childEnvironment(processOwner: config.processOwner),
                currentDirectory: config.cwd
            )
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync { started = true }
        if let state = try? transport.sendAndAwait(type: "get_state") {
            let enabled = (state["autoCompactionEnabled"] as? Bool)
                ?? (state["state"] as? [String: Any])?["autoCompactionEnabled"] as? Bool
            if enabled != nil {
                queue.sync {
                    observedAutomaticCompactionPolicy = AgentAutomaticCompactionPolicy(enabled: enabled)
                }
            }
        }
        if let response = try? transport.sendAndAwait(type: "get_commands"),
           let names = Self.parseAdvertisedCommands(response), !names.isEmpty {
            queue.sync { observedAdvertisedCommands = names }
        }
    }

    /// `get_commands`' response shape is NOT measured -- unlike every other
    /// command in `PiRpcCommand.knownTypes`, which were probed live. So this
    /// reads the plausible shapes and, crucially, **fails open**: an
    /// unrecognised or empty response leaves `observedAdvertisedCommands` nil,
    /// which the classifier reads as "not discovered yet" and answers from the
    /// baseline catalogue.
    ///
    /// Getting that direction wrong is the whole risk here. Adopting an empty
    /// set on a shape we guessed wrong would disable EVERY pi slash command,
    /// which is strictly worse than the frozen baseline it replaces. Widen this
    /// only against a captured fixture.
    public static func parseAdvertisedCommands(_ response: [String: Any]) -> Set<String>? {
        let candidates: [Any]?
        if let direct = response["commands"] as? [Any] {
            candidates = direct
        } else if let nested = (response["result"] as? [String: Any])?["commands"] as? [Any] {
            candidates = nested
        } else if let bare = response["result"] as? [Any] {
            candidates = bare
        } else {
            candidates = nil
        }
        guard let candidates else { return nil }
        let names = candidates.compactMap { entry -> String? in
            if let text = entry as? String { return text }
            if let object = entry as? [String: Any] {
                return (object["name"] as? String) ?? (object["command"] as? String)
            }
            return nil
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        return names.isEmpty ? nil : Set(names)
    }

    /// Queue-confined: translate one raw rpc line, forward each resulting
    /// event to the in-flight turn's callback, and detect turn completion.
    private func handleEventLine(_ line: String) {
        if !pendingSteerIDs.isEmpty, line.contains("\"queue_update\""),
           let data = line.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (object["type"] as? String) == "queue_update" {
            // pi drains its steering queue oldest first, so a shorter list means
            // that many of the oldest steers were taken into the conversation.
            let waiting = (object["steering"] as? [Any])?.count ?? 0
            while pendingSteerIDs.count > waiting {
                steerDispositionHandler?(pendingSteerIDs.removeFirst(), .consumed)
            }
        }
        let events = translator.translate(line: line)
        for event in events {
            currentOnEvent?(event)
            if case .turnCompleted = event { cancelAllHostToolCallsOnQueue() }
            if case .turnCompleted = event, let semaphore = turnSemaphore {
                turnOutcomeError = nil
                turnSemaphore = nil
                semaphore.signal()
            }
            if case .compactionChanged(_, let lifecycle) = event,
               [.succeeded, .failed, .cancelled, .indeterminate].contains(lifecycle.phase),
               let semaphore = compactionSemaphore {
                if lifecycle.phase == .failed {
                    compactionOutcomeError = RunError.commandFailed(
                        command: "compact", message: lifecycle.errorMessage ?? "compaction failed")
                } else if lifecycle.phase == .cancelled {
                    compactionOutcomeError = AgentRunStopped(detail: "")
                }
                compactionSemaphore = nil
                semaphore.signal()
            }
        }
    }

    private func emitObservedAutomaticCompactionPolicy(
        to onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) {
        guard let policy = queue.sync(execute: { observedAutomaticCompactionPolicy }) else { return }
        onEvent(.contextWindowUpdated(
            threadId: config.sessionId ?? "pi-session",
            snapshot: AgentContextWindowSnapshot(
                automaticCompactionPolicy: policy,
                observedAt: Date(),
                source: .unknown("pi-get-state"),
                freshness: .live)))
    }

    // MARK: - Pure argument/text shaping

    /// rpc mode takes no positional prompt argv -- turns are driven entirely
    /// by commands over the pipe. No `-p`, no prompt segments here.
    public static func processArguments(model: String, thinking: String, sessionId: String?, extraArgs: [String], extensionPaths: [String] = []) -> [String] {
        let sessionArgs = sessionId.map { ["--session-id", $0] } ?? ["--no-session"]
        let extensionArgs = extensionPaths.flatMap { ["-e", $0] }
        return ["--mode", "rpc", "--model", model, "--thinking", thinking]
            + sessionArgs
            + extensionArgs
            + extraArgs
    }

    /// RPC carries images in Pi's native `ImageContent` array. File references
    /// remain explicit `@path` message segments so Pi can hand them to its Read
    /// tool without copying arbitrary project bytes into JSON.
    public static func promptPayloadText(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.providerText.isEmpty { segments.append(prompt.providerText) }
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: " ")
    }

    public static func promptPayload(_ prompt: AgentPrompt) throws -> [String: Any] {
        var payload: [String: Any] = ["message": promptPayloadText(prompt)]
        if !prompt.imageAttachments.isEmpty {
            payload["images"] = try prompt.imageAttachments.map { attachment in
                let data = try Data(contentsOf: attachment.fileURL, options: [.mappedIfSafe])
                return [
                    "type": "image",
                    "data": data.base64EncodedString(),
                    "mimeType": attachment.metadata.contentType ?? inferredImageMIMEType(
                        for: attachment.fileURL),
                ]
            }
        }
        return payload
    }

    static func inferredImageMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

extension PiRpcAgentRunner: ObservedRunReporting {
    /// Where a `delegate_agent` child's transcript will be. Same confinement as
    /// `observeSpawnRequests`: set before `run`, delivered on the runner's serial
    /// queue, so a caller needing the main actor hops itself.
    public func observeObservedRuns(_ handler: @escaping @Sendable (ObservedRunHandle) -> Void) {
        queue.sync { translator.onObservedRun = handler }
    }
}

extension PiRpcAgentRunner: HostToolBridging {}

#endif  // os(macOS)

#if os(macOS)
extension PiRpcAgentRunner: AgentIdleExitReporting {
    public func observeIdleExit(_ handler: @escaping @Sendable (Int32, String?, Bool) -> Void) {
        queue.sync { idleExitHandler = handler }
    }
}
#endif
