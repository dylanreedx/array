import Foundation

// Ticket: codex app-server migration (.plans/46, "Codex app-server parity
// harness — the de-risking step, taken"). This is the IMPURE half of the
// app-server adapter: `CodexAppServerEventTranslator` (pure, already shipped)
// only knows how to turn one JSON-RPC line into `AgentRuntimeEvent`s. Driving
// the actual bidirectional protocol — sending a request, correlating its
// response by id, and forwarding every notification line as it streams in —
// is this file's job.
//
// `codex exec --json` is one-way: Array writes nothing to its stdin (the
// prompt is a trailing argv positional) and reads an NDJSON stream until the
// process exits. `app-server` is a real JSON-RPC-over-stdio peer: every
// `thread/start` / `thread/resume` / `turn/start` / `turn/interrupt` needs a
// reply correlated by id, while notifications (`item/started`,
// `item/agentMessage/delta`, `turn/completed`, …) arrive independently on the
// same stream and must be forwarded AS THEY ARRIVE — buffering them until
// process exit is exactly the ordering-hazard gate `.plans/46` measured and
// warned against.
//
// Blocking API, matching the rest of `CodexAgentRunner`'s synchronous design
// (`runOnce` already blocks on `spawned.wait()`): `sendRequest` blocks the
// calling thread on a semaphore until the correlated response arrives or the
// timeout elapses. `ProcessGroupChild.StandardInput.pipe` exists for exactly
// this — its doc comment says so verbatim ("Not used by any runner today; it
// is what M2's rpc transport needs").
public final class CodexAppServerTransport: @unchecked Sendable {
    public struct RPCError: Error, CustomStringConvertible {
        public let method: String
        public let code: Int
        public let message: String
        public var description: String {
            "app-server \(method) failed: \(SecretRedactor.redactLocalDiagnostics(message)) (code \(code))"
        }
    }
    public struct TimeoutError: Error, CustomStringConvertible {
        public let method: String
        public var description: String { "app-server request timed out: \(method)" }
    }
    public struct TransportClosedError: Error, CustomStringConvertible {
        public var description: String { "app-server stdin is unavailable (process not spawned with a pipe)" }
    }

    private let child: ProcessGroupChild
    private let onNotificationLine: (String) -> Void
    private let queue = DispatchQueue(label: "continuum.codex-appserver-transport")
    private var nextRequestId = 1
    private var pendingSemaphores: [Int: DispatchSemaphore] = [:]
    private var pendingResults: [Int: (result: [String: Any]?, error: [String: Any]?)] = [:]
    private var buffer = Data()

    /// `onNotificationLine` is invoked SYNCHRONOUSLY on this transport's own
    /// serial queue for every line that is not a correlated response — the
    /// caller (the runner) is responsible for its own thread-safety, exactly
    /// as `CodexAgentRunner.consume` already assumes for the exec transport's
    /// readabilityHandler.
    public init(child: ProcessGroupChild, onNotificationLine: @escaping (String) -> Void) {
        self.child = child
        self.onNotificationLine = onNotificationLine
        child.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consume(chunk)
        }
    }

    private func consume(_ chunk: Data) {
        queue.sync {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                handleLine(lineData)
            }
        }
    }

    /// Queue-confined. A frame with a matching numeric `id` and a `result`/
    /// `error` key is a response to OUR request; everything else (including a
    /// request FROM the server — out of scope here since `approval_policy=
    /// never` means codex never asks) is a notification, forwarded verbatim.
    private func handleLine(_ lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8),
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
           let id = object["id"] as? Int,
           object["result"] != nil || object["error"] != nil {
            pendingResults[id] = (object["result"] as? [String: Any], object["error"] as? [String: Any])
            pendingSemaphores[id]?.signal()
            return
        }
        onNotificationLine(line)
    }

    /// Send one JSON-RPC request and block until its correlated response
    /// arrives, or `timeout` elapses, or the response carries a JSON-RPC
    /// `error` (surfaced as `RPCError`, never as stderr text — the whole
    /// point of moving off exec's `isUnknownSessionFailure` string match).
    @discardableResult
    public func sendRequest(
        method: String,
        params: [String: Any],
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let id: Int = queue.sync {
            let value = nextRequestId
            nextRequestId += 1
            pendingSemaphores[value] = DispatchSemaphore(value: 0)
            return value
        }
        try writeLine(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let semaphore = queue.sync { pendingSemaphores[id] }
        guard let semaphore, semaphore.wait(timeout: .now() + timeout) == .success else {
            queue.sync { pendingSemaphores[id] = nil; pendingResults[id] = nil }
            throw TimeoutError(method: method)
        }
        let outcome = queue.sync { () -> (result: [String: Any]?, error: [String: Any]?)? in
            defer { pendingResults[id] = nil; pendingSemaphores[id] = nil }
            return pendingResults[id]
        }
        if let error = outcome?.error {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "unknown app-server error"
            throw RPCError(method: method, code: code, message: message)
        }
        return outcome?.result ?? [:]
    }

    public func sendNotification(method: String, params: [String: Any]) throws {
        try writeLine(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func writeLine(_ payload: [String: Any]) throws {
        guard let stdin = child.standardInput else { throw TransportClosedError() }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    /// Stop delivering notifications and release the stdin pipe. Does NOT
    /// touch the process itself — `CodexAgentRunner` owns tearing down the
    /// `ProcessGroupChild` (it needs the same group-wide SIGTERM/SIGKILL
    /// escalation every other runner uses, not a transport-local decision).
    public func shutdown() {
        child.standardOutput.readabilityHandler = nil
        try? child.standardInput?.close()
    }
}
