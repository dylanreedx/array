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

    public enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case commandFailed(command: String, message: String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .commandFailed(let command, let message):
                return "commandFailed(\(command): \(SecretRedactor.redactLocalDiagnostics(message)))"
            }
        }
    }

    public let config: Config
    public let sessionCapabilities: PiRpcSessionCapabilities = .full

    /// True only while the long-lived RPC child is available for another turn.
    /// The app uses this at the idle-session boundary so an unexpectedly exited
    /// child is never put back in the per-agent reuse pool.
    public var isSessionRunning: Bool { transport.isRunning }

    private let transport = PiRpcTransport()
    private let queue = DispatchQueue(label: "continuum.pi-rpc-agent-runner")
    private var translator: PiEventTranslator
    private var started = false
    private var stopRequested = false
    /// Signalled by the event stream when the in-flight turn reaches
    /// `.turnCompleted`. One at a time -- `run` is documented (like the other
    /// two runners) as blocking until its own turn finishes; the supervisor
    /// serializes calls to `run` today, and this runner does not attempt to
    /// widen that.
    private var turnSemaphore: DispatchSemaphore?
    private var turnOutcomeError: Error?

    public init(config: Config) {
        self.config = config
        self.translator = PiEventTranslator(workingDirectory: config.cwd)
        transport.onEvent = { [weak self] line in
            self?.queue.sync { self?.handleEventLine(line) }
        }
        transport.onExit = { [weak self] _ in
            self?.queue.sync {
                guard let self, let semaphore = self.turnSemaphore else { return }
                self.turnOutcomeError = RunError.launchFailed("pi rpc process exited mid-turn")
                self.turnSemaphore = nil
                semaphore.signal()
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

    /// SIGTERM the group (never SIGINT, rpc has no handler for it) at the
    /// interactive grace. Unlike the one-shot runner, this does not merely
    /// end one turn -- it ends the whole session, because there is no
    /// documented `abort`-then-keep-running use here (the tile is closing).
    public func stop() {
        queue.sync { stopRequested = true }
        transport.stop(graceSeconds: ProcessGroupChild.Grace.interactive)
        queue.sync {
            if let semaphore = turnSemaphore {
                turnOutcomeError = AgentRunStopped(detail: "")
                turnSemaphore = nil
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

    // MARK: - Session-runner surface (`AgentSessionRunning`, wired in the app target)

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
                environment: PiAgentRunner.childEnvironment(),
                currentDirectory: config.cwd
            )
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync { started = true }
    }

    /// Queue-confined: translate one raw rpc line, forward each resulting
    /// event to the in-flight turn's callback, and detect turn completion.
    private func handleEventLine(_ line: String) {
        let events = translator.translate(line: line)
        for event in events {
            currentOnEvent?(event)
            if case .turnCompleted = event, let semaphore = turnSemaphore {
                turnOutcomeError = nil
                turnSemaphore = nil
                semaphore.signal()
            }
        }
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
        if !prompt.text.isEmpty { segments.append(prompt.text) }
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

    private static func inferredImageMIMEType(for url: URL) -> String {
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

#endif  // os(macOS)
