import Foundation

// CX-01 (`.plans/59`, §15) — the pi HOST TOOL BRIDGE's value half.
//
// A pi extension tool (`continuum-workspace-tools.ts`) awaits the host by
// calling `ctx.ui.input(<JSON envelope>)`. In rpc mode pi emits that as
// `{"type":"extension_ui_request","id":<pi-minted>,"method":"input","title":<envelope>}`
// and resolves the tool's promise when the client writes
// `{"type":"extension_ui_response","id":<same>,"value":<string>}` to stdin
// (`dist/modes/rpc/rpc-mode.js`, `createDialogPromise`; pi 0.85.0). The
// extension returns `value` as the tool's result content, so what the host
// writes here IS what the model reads. Replies key on the PI-MINTED id: an
// unknown id is dropped by pi, so a late reply can never resurrect a resolved
// call or land on another invocation.
//
// Caller identity never travels in the envelope. The line arrives on the
// runner's own transport, and the runner is bound to exactly one `AgentRecord`
// by the supervisor — that binding, not any field, is who is asking.

/// One Array-owned request parsed out of an `extension_ui_request` frame.
/// `parse` returns nil for anything that is not ours (another method, a
/// non-JSON title, a foreign schema), and those frames stay dropped as before.
public struct PiHostToolRequest: @unchecked Sendable {
    public static let kind = "request"

    public let piRequestId: String
    public let requestId: String
    public let op: String
    /// Model-authored. Never `Codable`, never widened into `AgentRuntimeEvent`
    /// (the same I5 posture as `SpawnRequest`).
    public let payload: [String: Any]
    public let receivedAt: Date

    public init(piRequestId: String, requestId: String, op: String, payload: [String: Any], receivedAt: Date) {
        self.piRequestId = piRequestId
        self.requestId = requestId
        self.op = op
        self.payload = payload
        self.receivedAt = receivedAt
    }

    public static func parse(_ object: [String: Any], now: Date) -> PiHostToolRequest? {
        guard object["type"] as? String == "extension_ui_request",
              object["method"] as? String == "input",
              let piRequestId = object["id"] as? String, !piRequestId.isEmpty,
              let title = object["title"] as? String,
              let data = title.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["schema"] as? String == WorkspaceAPISchema.v1,
              envelope["kind"] as? String == kind,
              let requestId = envelope["requestId"] as? String, !requestId.isEmpty,
              let op = envelope["op"] as? String, !op.isEmpty
        else { return nil }
        return PiHostToolRequest(
            piRequestId: piRequestId,
            requestId: requestId,
            op: op,
            payload: envelope["payload"] as? [String: Any] ?? [:],
            receivedAt: now)
    }
}

/// What the host hands back. Encoded as the `value` string the extension
/// parses; structured errors are RETURNED to the model, never thrown by the
/// extension (pi flattens a thrown error to text and drops `details`).
public struct PiHostToolResponse: @unchecked Sendable {
    public enum Status: String, Sendable { case ok, error, cancelled }

    public var status: Status
    public var result: [String: Any]?
    public var errorCode: String?
    public var errorMessage: String?
    public var errorDetails: [String: Any]?

    public init(status: Status, result: [String: Any]? = nil, errorCode: String? = nil, errorMessage: String? = nil, errorDetails: [String: Any]? = nil) {
        self.status = status
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorDetails = errorDetails
    }

    public static func ok(_ result: [String: Any]) -> PiHostToolResponse {
        PiHostToolResponse(status: .ok, result: result)
    }

    public static func error(_ code: String, _ message: String, details: [String: Any]? = nil) -> PiHostToolResponse {
        PiHostToolResponse(status: .error, errorCode: code, errorMessage: message, errorDetails: details)
    }

    /// Cancelled before any effect (no result), or after a committed effect — in
    /// which case `result` carries the completed identity (§15 point 4).
    public static func cancelled(result: [String: Any]? = nil) -> PiHostToolResponse {
        PiHostToolResponse(status: .cancelled, result: result)
    }

    public static let transportTimeout = PiHostToolResponse.error(
        "outcome_unknown",
        "Array did not finish handling this request before its deadline (transport_timeout). Do not repeat the effect blindly; call array_workspace_context and read recentOperations.")

    public static let unsupportedUnbound = PiHostToolResponse.error(
        "unsupported", "Array's workspace API is not bound to this session.")

    public func encodedValue(requestId: String) -> String {
        var object: [String: Any] = [
            "schema": WorkspaceAPISchema.v1,
            "requestId": requestId,
            "status": status.rawValue,
        ]
        if let result { object["result"] = result }
        if status == .error {
            var error: [String: Any] = [
                "code": errorCode ?? "outcome_unknown",
                "message": errorMessage ?? "",
            ]
            if let errorDetails { error["details"] = errorDetails }
            object["error"] = error
        }
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        let fallback: [String: Any] = [
            "schema": WorkspaceAPISchema.v1, "requestId": requestId, "status": "error",
            "error": ["code": "outcome_unknown", "message": "Array produced an unencodable reply"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where a host reply ended up. Only `.delivered` means pi still held the id
/// when the frame was written.
public enum PiHostToolDelivery: String, Sendable {
    case delivered
    /// Written after pi was told to abort; pi has already dropped the id and the
    /// model saw `cancelled`. The identity must reach it another way
    /// (`recentOperations`).
    case sentAfterCancel
    /// The host deadline already answered `outcome_unknown`.
    case droppedAlreadyAnswered
    /// pi already emitted `tool_execution_end` for this call.
    case droppedToolReturned
    /// The runner (and its child) is gone. Never re-routed to a newer runner.
    case droppedRunnerGone
}

/// One in-flight request. A reference so the host can hold it across its own
/// asynchronous work (an approval prompt, a main-actor hop) and answer later.
public final class PiHostToolCall: @unchecked Sendable {
    public let request: PiHostToolRequest
    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []
    private let responder: @Sendable (PiHostToolResponse, (@Sendable (PiHostToolDelivery) -> Void)?) -> Void

    public init(
        request: PiHostToolRequest,
        responder: @escaping @Sendable (PiHostToolResponse, (@Sendable (PiHostToolDelivery) -> Void)?) -> Void
    ) {
        self.request = request
        self.responder = responder
    }

    /// True once pi aborted the tool, the runner stopped, or the turn ended.
    /// Checked by the host at its commit boundary: before the effect → nothing
    /// happens; after → the completed identity is reported, never undone.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Fires once, on whatever thread cancels, or immediately if already cancelled.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        cancelHandlers.append(handler)
        lock.unlock()
    }

    /// Runner-internal in spirit (the bridge state machine calls it on abort,
    /// stop, turn end and tool return); public so the checks target can drive it.
    public func markCancelled() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let handlers = cancelHandlers
        cancelHandlers.removeAll()
        lock.unlock()
        for handler in handlers { handler() }
    }

    public func respond(_ response: PiHostToolResponse, completion: (@Sendable (PiHostToolDelivery) -> Void)? = nil) {
        responder(response, completion)
    }
}

/// A runner that can bridge host tool requests. A CAPABILITY, not a widening of
/// `AgentRunning`: the one-shot and scripted runners compile untouched and the
/// supervisor asks `runner as? HostToolBridging`, as it does for the other
/// side channels.
public protocol HostToolBridging: AnyObject {
    func observeHostToolRequests(_ handler: @escaping @Sendable (PiHostToolCall) -> Void)
}
