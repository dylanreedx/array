import Foundation

// M2 (`.plans/46`): the pi rpc transport. Owns ONE long-lived `pi --mode rpc`
// child for many turns, instead of `PiAgentRunner`'s one process per prompt.
//
// Ground truth is measured, not re-derived here -- see the "pi rpc" probe in
// `.plans/46-transcript-program-ledger.md`:
//   - Commands are newline-delimited JSON objects `{id?, type: "prompt" | ...}`.
//   - Replies are `{id?, type:"response", command, success, data?}`.
//   - The event stream is the SAME function pi uses for `--mode json`
//     (`toJsonEvent` in `modes/json-event.js`), plus two protocol-only frame
//     types this transport must not confuse with events: `response` and
//     `extension_ui_request`.
//   - `abort` is awaited and answers a response while leaving the connection
//     healthy for the next `prompt`.
//   - rpc registers SIGTERM/SIGHUP handlers only; SIGINT kills it raw. Array
//     already sends SIGTERM via `ProcessGroupChild.terminateGroup`, which stays
//     correct here -- do not switch to SIGINT.
//
// macOS-only, same convention as `PiAgentRunner`.
#if os(macOS)

/// The rpc command vocabulary, exactly as measured (31 commands; `get_commands`
/// returns the SESSION's slash commands, not this list, so it is deliberately
/// excluded from `PiRpcCommand.knownTypes` -- a caller that wants the slash
/// commands still reaches it via `command(_:payload:)`, it just is not
/// advertised as part of the rpc vocabulary itself).
public enum PiRpcCommand {
    /// The full known vocabulary, for `PiRpcSessionCapabilities.full`.
    public static let knownTypes: Set<String> = [
        "prompt", "steer", "follow_up", "abort", "new_session", "get_state",
        "set_model", "cycle_model", "get_available_models",
        "set_thinking_level", "cycle_thinking_level",
        "get_available_thinking_levels", "set_steering_mode",
        "set_follow_up_mode", "compact", "set_auto_compaction",
        "set_auto_retry", "abort_retry", "bash", "abort_bash",
        "get_session_stats", "export_html", "switch_session", "fork", "clone",
        "get_fork_messages", "get_entries", "get_tree",
        "get_last_assistant_text", "set_session_name", "get_messages",
        "get_commands"
    ]

    /// The two frame types rpc adds on top of the shared event stream.
    /// `PiEventTranslator` ignores both; this transport treats `response` as
    /// the correlation channel and forwards `extension_ui_request` through
    /// like any other event line (the translator drops it).
    public static let responseFrameType = "response"
}

/// What a bound rpc runner can do, sourced from the runner itself -- never
/// from `record.harness`, which lies for the whole migration window while
/// pi-one-shot and pi-rpc are both live in one build.
public struct PiRpcSessionCapabilities: Sendable, Equatable {
    public let supportedCommands: Set<String>

    public init(supportedCommands: Set<String>) {
        self.supportedCommands = supportedCommands
    }

    /// Every measured command. `PiRpcAgentRunner` supports the full
    /// vocabulary via `command(_:payload:)`; only `prompt`/`steer`/`abort` get
    /// dedicated call sites.
    public static let full = PiRpcSessionCapabilities(supportedCommands: PiRpcCommand.knownTypes)
}

/// Owns one `pi --mode rpc` child: writes newline-delimited JSON commands to
/// its stdin, reads newline-delimited JSON frames from its stdout, and splits
/// those frames into two streams:
///   - `{"type":"response", "id": ..., ...}` correlates to a pending
///     `sendAndAwait` call by `id` and is never forwarded as an event.
///   - everything else (including a line that fails to parse at all -- "a
///     malformed or unknown frame is dropped, not fatal" is a witness
///     requirement) is forwarded verbatim to `onEvent`.
///
/// Thread-safety: `readabilityHandler` fires on a background queue; line
/// assembly and correlation bookkeeping are confined to `queue`. Callers of
/// `sendAndAwait` block their OWN calling thread on a semaphore -- never
/// `queue` itself -- so a response arriving while a caller waits does not
/// deadlock.
public final class PiRpcTransport: @unchecked Sendable {
    public enum TransportError: Error, CustomStringConvertible, Equatable {
        case launchFailed(String)
        case notRunning
        case timedOut(command: String)
        case childExited(exitCode: Int32)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .notRunning:
                return "notRunning"
            case .timedOut(let command):
                return "timedOut(\(command))"
            case .childExited(let code):
                return "childExited(exitCode: \(code))"
            }
        }
    }

    private let queue = DispatchQueue(label: "continuum.pi-rpc-transport")
    private var child: ProcessGroupChild?
    private var buffer = Data()
    private var nextRequestId = 0
    private var exitedCode: Int32?

    private let pendingLock = NSLock()
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]

    /// Every non-response line, forwarded verbatim (raw text, not re-encoded)
    /// so the caller's own JSON decoding stays byte-identical to one-shot's.
    /// Invoked on `queue`.
    public var onEvent: (@Sendable (String) -> Void)?
    /// Fired once, when the child's stdout hits EOF. Invoked on `queue`.
    public var onExit: (@Sendable (Int32) -> Void)?

    public init() {}

    public var isRunning: Bool { queue.sync { child != nil && exitedCode == nil } }

    // MARK: - Lifecycle

    public func start(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws {
        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                standardInput: .pipe
            )
        } catch {
            throw TransportError.launchFailed(String(describing: error))
        }

        queue.sync {
            self.child = spawned
            self.buffer.removeAll()
            self.exitedCode = nil
        }

        spawned.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                self?.handleEOF()
                return
            }
            self?.queue.sync { self?.consume(chunk) }
        }
        // Drained and discarded, same rationale as `PiAgentRunner`: an unread
        // stderr pipe fills and blocks the child. Nothing today needs rpc's
        // stderr surfaced.
        spawned.standardError.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    /// SIGTERM the whole group (never SIGINT -- rpc has no handler for it),
    /// wait out the grace, escalate to SIGKILL. Fails every still-pending
    /// `sendAndAwait` rather than hanging them.
    public func stop(graceSeconds: TimeInterval = ProcessGroupChild.Grace.interactive) {
        let running: ProcessGroupChild? = queue.sync { child }
        running?.terminateGroup(graceSeconds: graceSeconds)
        failAllPending(with: TransportError.notRunning)
        queue.sync {
            child?.standardOutput.readabilityHandler = nil
            child?.standardError.readabilityHandler = nil
            child = nil
        }
    }

    // MARK: - Sending

    /// Fire-and-forget: writes the command line, does not wait for its
    /// response. The response (when it arrives) is dropped silently -- a
    /// caller that needs the result must use `sendAndAwait`.
    @discardableResult
    public func send(type: String, payload: [String: Any] = [:], id: String? = nil) throws -> String {
        let requestId = id ?? queue.sync { () -> String in
            nextRequestId += 1
            return "rpc-\(nextRequestId)"
        }
        try writeLine(type: type, payload: payload, id: requestId)
        return requestId
    }

    /// Blocking: writes the command line, then waits (on the CALLING thread,
    /// never `queue`) for the correlated `{"type":"response", "id": ...}`
    /// frame. Times out rather than hanging forever on a wedged child.
    @discardableResult
    public func sendAndAwait(
        type: String,
        payload: [String: Any] = [:],
        timeout: TimeInterval = 30
    ) throws -> [String: Any] {
        guard isRunning else { throw TransportError.notRunning }
        let requestId = queue.sync { () -> String in
            nextRequestId += 1
            return "rpc-\(nextRequestId)"
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(TransportError.timedOut(command: type))
        pendingLock.lock()
        pending[requestId] = { r in result = r; semaphore.signal() }
        pendingLock.unlock()

        do {
            try writeLine(type: type, payload: payload, id: requestId)
        } catch {
            pendingLock.lock(); pending.removeValue(forKey: requestId); pendingLock.unlock()
            throw error
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            pendingLock.lock(); pending.removeValue(forKey: requestId); pendingLock.unlock()
            throw TransportError.timedOut(command: type)
        }
        return try result.get()
    }

    private func writeLine(type: String, payload: [String: Any], id: String) throws {
        guard let stdin = queue.sync(execute: { child?.standardInput }) else {
            throw TransportError.notRunning
        }
        var object = payload
        object["type"] = type
        object["id"] = id
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        stdin.write(line)
    }

    // MARK: - queue-confined line assembly

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            route(lineData)
        }
    }

    private func handleEOF() {
        // MUST clear the handler FIRST. `FileHandle.readabilityHandler`'s
        // dispatch source stays armed at EOF and re-fires immediately with
        // `availableData` empty forever -- leaving it set turns EOF into a
        // tight busy-spin calling this method instead of running it once.
        let running = queue.sync { () -> ProcessGroupChild? in
            let current = child
            current?.standardOutput.readabilityHandler = nil
            current?.standardError.readabilityHandler = nil
            return current
        }
        queue.sync {
            if !buffer.isEmpty {
                route(buffer[...])
                buffer.removeAll()
            }
        }
        let code = running?.wait() ?? 0
        queue.sync { exitedCode = code }
        failAllPending(with: TransportError.childExited(exitCode: code))
        onExit?(code)
    }

    /// Splits response frames (correlated and swallowed) from everything else
    /// (forwarded as an event line, raw). A line that fails to decode as JSON,
    /// or decodes but carries no recognisable `id`, is still treated as a
    /// possible event -- "malformed frame dropped, not fatal" means the
    /// TRANSPORT does not crash or wedge, not that every stray byte is an
    /// event; `PiEventTranslator` is what actually discards it.
    private func route(_ lineData: Data.SubSequence) {
        let data = Data(lineData)
        guard let line = String(data: data, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String,
           type == PiRpcCommand.responseFrameType {
            let requestId = object["id"] as? String
            deliverResponse(requestId: requestId, object: object)
            return
        }
        onEvent?(trimmed)
    }

    private func deliverResponse(requestId: String?, object: [String: Any]) {
        guard let requestId else { return }
        pendingLock.lock()
        let completion = pending.removeValue(forKey: requestId)
        pendingLock.unlock()
        guard let completion else { return }
        let success = (object["success"] as? Bool) ?? false
        if success {
            completion(.success(object))
        } else {
            let message = (object["error"] as? String) ?? "rpc command failed"
            completion(.failure(TransportError.launchFailed(message)))
        }
    }

    private func failAllPending(with error: Error) {
        pendingLock.lock()
        let all = pending
        pending.removeAll()
        pendingLock.unlock()
        for completion in all.values { completion(.failure(error)) }
    }
}

#endif  // os(macOS)
