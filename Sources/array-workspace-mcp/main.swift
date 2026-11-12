import Foundation
import ContinuumRevivedCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: WorkspaceMCPJSON?
    let method: String
    let params: WorkspaceMCPJSON?
}

private enum MCPError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRequest
    case unavailable(String)
    case pollTimedOut

    var description: String {
        switch self {
        case .usage(let message), .unavailable(let message): return message
        case .invalidRequest: return "invalid MCP request"
        case .pollTimedOut: return "workspace poll timed out"
        }
    }
}

/// Serializes stdout: requests are handled concurrently (a `wait_agents` call
/// or a pending approval must not hold every other call behind it), so two
/// replies must never interleave on the one stream.
private actor ResponseWriter {
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private actor RequestTasks {
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    func insert(_ task: Task<Void, Never>, id: String, token: UUID) { tasks[id] = (token, task) }
    func cancel(_ id: String) { tasks[id]?.task.cancel() }
    func remove(_ id: String, token: UUID) {
        if tasks[id]?.token == token { tasks[id] = nil }
    }
}

@main
struct ArrayWorkspaceMCP {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == WorkspaceAgentHook.subcommand {
            await HookMode.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
            Foundation.exit(0)
        }
        do {
            let server = try Server(arguments: CommandLine.arguments)
            try await server.run()
        } catch {
            fputs("array-workspace-mcp: (error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private struct Server: Sendable {
        let endpoint: URL
        let agentID: String
        let token: String
        /// One channel per recipient: `push` lists no `wait_agents`.
        let delivery: WorkspaceResultDelivery
        /// The host found standards in this agent's checkout at launch.
        let projectStandards: Bool
        /// Listed with `_meta["anthropic/alwaysLoad"]`: a Claude Managed lead's
        /// first tools, loaded up front rather than through tool search.
        let alwaysLoadedTools: Set<String>
        let session: URLSession
        let writer = ResponseWriter()
        let requests = RequestTasks()

        init(arguments: [String]) throws {
            let environment = ProcessInfo.processInfo.environment
            guard let endpointText = environment["ARRAY_WORKSPACE_MCP_ENDPOINT"],
                  let endpoint = URL(string: endpointText), !endpointText.isEmpty else {
                throw MCPError.usage("ARRAY_WORKSPACE_MCP_ENDPOINT is required")
            }
            guard let agentID = environment["ARRAY_WORKSPACE_AGENT_ID"], !agentID.isEmpty,
                  let tokenPath = environment["ARRAY_WORKSPACE_MCP_TOKEN_FILE"],
                  let tokenData = FileManager.default.contents(atPath: tokenPath),
                  case let token = String(decoding: tokenData, as: UTF8.self), !token.isEmpty else {
                throw MCPError.usage("ARRAY_WORKSPACE_AGENT_ID and ARRAY_WORKSPACE_MCP_TOKEN_FILE are required")
            }
            self.endpoint = endpoint; self.agentID = agentID; self.token = token
            self.delivery = WorkspaceResultDelivery(environmentValue: environment[WorkspaceResultDelivery.environmentKey])
            self.projectStandards = environment[ProjectStandards.environmentKey] == "1"
            self.alwaysLoadedTools = Set((environment[WorkspaceMCPConfiguration.alwaysLoadedToolsEnvironmentKey] ?? "")
                .split(separator: ",").map(String.init))
            // URLSession's default request timeout is 60 s. The host answers a
            // delegation only after the user answers its approval alert, so a
            // slow answer used to read "bridge unavailable" here while the
            // operation went on in Array.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = TimeInterval(WorkspaceMCPConfiguration.toolCallTimeoutSeconds)
            configuration.timeoutIntervalForResource = TimeInterval(WorkspaceMCPConfiguration.toolCallTimeoutSeconds)
            self.session = URLSession(configuration: configuration)
        }

        func run() async throws {
            await withTaskGroup(of: Void.self) { group in
                while let line = readLine(strippingNewline: true) {
                    guard let data = line.data(using: .utf8) else { continue }
                    let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data)
                    if request?.id == nil, request?.method == "notifications/cancelled" {
                        if case .object(let params)? = request?.params, let id = params["requestId"] {
                            await requests.cancel(id.jsonString)
                        }
                        continue
                    }
                    let task = Task {
                        let response = await handle(data)
                        await writer.write(response)
                    }
                    let key = request?.id?.jsonString
                    let token = UUID()
                    if let key { await requests.insert(task, id: key, token: token) }
                    group.addTask {
                        await task.value
                        if let key { await requests.remove(key, token: token) }
                    }
                }
            }
        }

        func handle(_ data: Data) async -> Data {
            let decoder = JSONDecoder()
            guard let request = try? decoder.decode(JSONRPCRequest.self, from: data), request.jsonrpc == "2.0" else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": .null,
                                      "error": .object(["code": .int(-32600), "message": .string("Invalid Request")])]))
            }
            // A notification carries no id and is never answered.
            if request.id == nil, request.method.hasPrefix("notifications/") { return Data() }
            switch request.method {
            case "initialize":
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null, "result": .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("array-workspace"), "version": .string("0.1")]),
                    "instructions": .string(WorkspaceMCPToolCatalog.serverInstructions(for: delivery))
                ])]))
            case "tools/list":
                var tools = WorkspaceMCPToolCatalog.tools(projectStandards: projectStandards).map { tool in
                    var listed: [String: WorkspaceMCPJSON] = [
                        "name": .string(tool.name),
                        "description": .string(WorkspaceMCPToolCatalog.mcpDescription(tool, for: delivery)),
                        "inputSchema": .object(tool.inputSchema)]
                    if alwaysLoadedTools.contains(tool.name) {
                        listed["_meta"] = .object(["anthropic/alwaysLoad": .bool(true)])
                    }
                    return WorkspaceMCPJSON.object(listed)
                }
                if delivery == .collect {
                    tools.append(.object(["name": .string(WorkspaceMCPToolCatalog.waitAgentsName),
                                          "description": .string(WorkspaceMCPToolCatalog.waitAgentsDescription),
                                          "inputSchema": .object(WorkspaceMCPToolCatalog.waitAgentsInputSchema)]))
                }
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "result": .object(["tools": .array(tools)])]))
            case "tools/call":
                return await call(request)
            case "ping":
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null, "result": .object([:])]))
            default:
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "error": .object(["code": .int(-32601), "message": .string("Method not found")])]))
            }
        }

        func call(_ request: JSONRPCRequest) async -> Data {
            guard case .object(let params) = request.params,
                  case .string(let name)? = params["name"] else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "error": .object(["code": .int(-32602), "message": .string("Unknown workspace tool")])]))
            }
            let arguments: [String: WorkspaceMCPJSON]
            if case .object(let value)? = params["arguments"] { arguments = value } else { arguments = [:] }
            let reply: WorkspaceMCPJSON
            if name == WorkspaceMCPToolCatalog.waitAgentsName, delivery == .collect {
                reply = await waitAgents(arguments)
            } else if let tool = WorkspaceMCPToolCatalog.tools(projectStandards: projectStandards).first(where: { $0.name == name }) {
                do {
                    let lookupID = Self.providerCallID(params) ?? UUID().uuidString
                    let raw = tool.operation == .operationGet
                        ? try await lookup(arguments, requestId: lookupID)
                        : try await post(op: tool.operation.rawValue, payload: .object(arguments), requestId: lookupID)
                    reply = tool.operation == .operationGet
                        ? try await acknowledgeLookup(raw, payload: arguments, requestId: lookupID) : raw
                } catch {
                    reply = Self.errorReply(code: "outcome_unknown", message: "\(error). Do not repeat the effect blindly; call array_workspace_context and read recentOperations.")
                }
            } else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "error": .object(["code": .int(-32602), "message": .string("Unknown workspace tool")])]))
            }
            // Error flag, and a reply's picture lifted into an image item
            // with its base64 kept out of the text (S1, `.plans/80`).
            let result = WorkspaceMCPToolResult.make(reply: reply)
            return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null, "result": .object(result)]))
        }

        /// The client's own id for this tool call, from the request's `_meta`:
        /// claude sends `claudecode/toolUseId` (its tool_use id), codex sends
        /// `callId` (its `mcpToolCall` item id) — both measured, claude 2.1.291
        /// and codex 0.159.3. It becomes the request id, exactly as pi's bridge
        /// sends its toolCallId, so a delegation's operationId and its chip's
        /// `sourceItemID` name the provider's call and the transcript can fold
        /// that call's row into the chip (T4b). nil leaves a fresh UUID.
        static func providerCallID(_ params: [String: WorkspaceMCPJSON]) -> String? {
            guard case .object(let meta)? = params["_meta"] else { return nil }
            for key in ["claudecode/toolUseId", "callId"] {
                if case .string(let id)? = meta[key], SpawnResultFile.validatedHandle(id) == id { return id }
            }
            return nil
        }

        func post(op: String, payload: WorkspaceMCPJSON, requestId: String? = nil, timeout: TimeInterval? = nil) async throws -> WorkspaceMCPJSON {
            let body: [String: WorkspaceMCPJSON] = [
                "schema": .string(WorkspaceAPISchema.v1),
                "kind": .string("request"),
                "requestId": .string(requestId ?? UUID().uuidString),
                "agentId": .string(agentID),
                "token": .string(token),
                "op": .string(op),
                "payload": payload
            ]
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(WorkspaceMCPJSON.object(body).jsonString.utf8)
            let data: Data
            let response: URLResponse
            if let timeout {
                try Task.checkCancellation()
                guard timeout > 0 else { throw MCPError.pollTimedOut }
                request.timeoutInterval = timeout
                let boundedRequest = request
                // URLRequest's timeout is an idle timeout. Race an absolute
                // deadline too, so trickled bytes cannot extend a helper wait.
                (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                    defer { group.cancelAll() }
                    group.addTask { try await session.data(for: boundedRequest) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw MCPError.pollTimedOut
                    }
                    return try await group.next()!
                }
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MCPError.unavailable("Array workspace bridge unavailable") }
            return try JSONDecoder().decode(WorkspaceMCPJSON.self, from: data)
        }

        /// Retries preserve the lookup id: a lost response replays the same
        /// durable offer, including after the host restarted. Acknowledgment
        /// means client custody, not proof that a model consumed stdout.
        func lookup(_ payload: [String: WorkspaceMCPJSON], requestId: String, deadline: Date? = nil) async throws -> WorkspaceMCPJSON {
            var failure: Error = MCPError.unavailable("Helper lookup unavailable")
            for _ in 0..<3 {
                do {
                    try Task.checkCancellation()
                    return try await post(op: WorkspaceAPIOp.operationGet.rawValue, payload: .object(payload),
                        requestId: requestId, timeout: deadline.map { min(0.5, $0.timeIntervalSinceNow) })
                } catch {
                    if Task.isCancelled { throw error }
                    if let deadline, Date() >= deadline { throw MCPError.pollTimedOut }
                    failure = error
                }
            }
            throw failure
        }
        func acknowledgeLookup(_ reply: WorkspaceMCPJSON, payload: [String: WorkspaceMCPJSON], requestId: String, deadline: Date? = nil) async throws -> WorkspaceMCPJSON {
            guard case .object(let fields) = reply, case .object(let operation)? = fields["result"],
                  case .object(let child)? = operation["childResult"],
                  case .string(let receipt)? = child["deliveryReceipt"],
                  child["status"] != .string("already_delivered"), child["status"] != .string("delivery_pending") else { return reply }
            var ack = payload; ack["deliveryReceipt"] = .string(receipt); ack["acknowledgeDelivery"] = .bool(true)
            let response = try await lookup(ack, requestId: requestId + "-ack", deadline: deadline)
            guard case .object(let result) = response, result["status"] == .string("ok") else {
                throw MCPError.unavailable("Helper acknowledgment failed; replay operation.get with deliveryReceipt \(receipt)")
            }
            return reply
        }

        // MARK: wait_agents

        /// Polls `operation.get` for each handle until its child is idle with a
        /// settled turn, its operation failed, or the deadline passes. Every
        /// poll is one ordinary host request, so the app never blocks on a wait.
        func waitAgents(_ arguments: [String: WorkspaceMCPJSON]) async -> WorkspaceMCPJSON {
            var handles: [String] = []
            if case .array(let values)? = arguments["handles"] {
                for case .string(let handle) in values where !handle.isEmpty && !handles.contains(handle) { handles.append(handle) }
            }
            guard !handles.isEmpty, handles.count <= WorkspaceMCPToolCatalog.waitAgentsMaxHandles else {
                return Self.errorReply(code: "invalid_request", message: "handles must list 1 to \(WorkspaceMCPToolCatalog.waitAgentsMaxHandles) operationId values from array_delegate.")
            }
            var requested = Double(WorkspaceMCPToolCatalog.waitAgentsDefaultTimeoutSeconds)
            switch arguments["timeoutSeconds"] {
            case .int(let value)?: requested = Double(value)
            case .double(let value)?: requested = value
            default: break
            }
            let range = WorkspaceMCPToolCatalog.waitAgentsTimeoutRange
            let timeout = min(max(requested, Double(range.lowerBound)), Double(range.upperBound))
            let deadline = Date().addingTimeInterval(timeout)
            let lookupIDs = Dictionary(uniqueKeysWithValues: handles.map { ($0, UUID().uuidString) })
            var settled: [String: WorkspaceMCPJSON] = [:]
            var latest: [String: WorkspaceMCPJSON] = [:]
            var interrupted: String?
            polling: while true {
                for handle in handles where settled[handle] == nil {
                    if Task.isCancelled { interrupted = "cancelled"; break polling }
                    if Date() >= deadline { break polling }
                    do {
                        // Recheck before EVERY lookup. One slow helper must not
                        // hide input behind the remaining handles in the batch.
                        let input = try await post(op: WorkspaceAPIOp.operationGet.rawValue,
                            payload: .object(["pendingInputOnly": .bool(true)]),
                            timeout: min(0.5, deadline.timeIntervalSinceNow))
                        if case .object(let fields) = input, case .object(let result)? = fields["result"],
                           case .string(let reason)? = result["pendingInput"],
                           reason == "user_steer" || reason == "inbox" {
                            interrupted = reason
                            break polling // Return cached results; never start another lookup.
                        }
                        let payload: [String: WorkspaceMCPJSON] = ["operationId": .string(handle)]
                        let raw = try await lookup(payload, requestId: lookupIDs[handle]!, deadline: deadline)
                        let reply = try await acknowledgeLookup(raw, payload: payload,
                            requestId: lookupIDs[handle]!, deadline: deadline)
                        guard case .object(let fields) = reply else { continue }
                        if fields["status"] == .string("error") {
                            settled[handle] = .object(["handle": .string(handle), "status": .string("error"), "error": fields["error"] ?? .null])
                            continue
                        }
                        guard case .object(let operation)? = fields["result"] else { continue }
                        latest[handle] = .object(operation)
                        if let entry = Self.settledEntry(handle: handle, operation: operation) { settled[handle] = entry }
                    } catch {
                        if Task.isCancelled { interrupted = "cancelled"; break polling }
                        // A read can be retried. Return partial results at the
                        // overall deadline instead of the general tool horizon.
                        if case MCPError.pollTimedOut = error { continue }
                        if (error as? URLError)?.code == .timedOut { continue }
                        return Self.errorReply(code: "outcome_unknown", message: "\(error)")
                    }
                }
                if settled.count == handles.count || Date() >= deadline { break }
                try? await Task.sleep(for: .seconds(min(0.25, max(0, deadline.timeIntervalSinceNow))))
            }
            let agents: [WorkspaceMCPJSON] = handles.map { handle in
                if let entry = settled[handle] { return entry }
                var entry: [String: WorkspaceMCPJSON] = ["handle": .string(handle), "status": .string("running")]
                if case .object(let operation)? = latest[handle], let child = operation["childAgentId"] { entry["childAgentId"] = child }
                return .object(entry)
            }
            var result: [String: WorkspaceMCPJSON] = ["agents": .array(agents),
                "timedOut": .bool(interrupted == nil && settled.count < handles.count)]
            if let interrupted { result["interrupted"] = .string(interrupted) }
            return .object(["schema": .string(WorkspaceAPISchema.v1), "status": .string("ok"),
                            "result": .object(result)])
        }

        /// A child has settled when Array says it is idle AND reports the turn
        /// it settled with; a failed or expired operation is settled too.
        static func settledEntry(handle: String, operation: [String: WorkspaceMCPJSON]) -> WorkspaceMCPJSON? {
            var entry: [String: WorkspaceMCPJSON] = ["handle": .string(handle)]
            if let child = operation["childAgentId"] { entry["childAgentId"] = child }
            if case .string(let status)? = operation["status"], status == "failed" || status == "expired" {
                entry["status"] = .string(status)
                if let message = operation["failureMessage"] { entry["reason"] = message }
                return .object(entry)
            }
            guard operation["childRunning"] == .bool(false),
                  case .object(let result)? = operation["childResult"],
                  case .string(let status)? = result["status"], status != "spawned", status != "delivery_pending" else { return nil }
            entry["status"] = .string(status)
            for key in ["deliveryReceipt", "finalText", "finalTextTruncated", "reason", "endedAt", "report"] {
                if let value = result[key] { entry[key] = value }
            }
            return .object(entry)
        }

        static func errorReply(code: String, message: String) -> WorkspaceMCPJSON {
            .object(["schema": .string(WorkspaceAPISchema.v1), "status": .string("error"),
                     "error": .object(["code": .string(code), "message": .string(message)])])
        }

        func encode(_ object: WorkspaceMCPJSON) -> Data {
            Data(object.jsonString.utf8)
        }
    }
}

/// `array-workspace-mcp hook --endpoint <url> --agent-id <id> --token-file <path>`:
/// one Claude hook event, posted to the app (`WorkspaceAgentHook`, `.plans/102`).
///
/// It prints only what the app returns as `result.hookOutput` (P2a's report
/// push-back, opt-in); otherwise nothing, because Claude reads stdout as a
/// decision. The caller always exits 0. It fails open: no marker, bad
/// arguments, an unreadable token, an app that is down or slow all print
/// nothing and end within `postTimeoutSeconds`.
private enum HookMode {
    static func run(arguments: [String]) async {
        // Inert outside Array: Array sets the marker on every managed agent.
        guard ProcessInfo.processInfo.environment[PiAgentRunner.arrayHostedEnvironmentKey] == "1" else { return }
        var options: [String: String] = [:]
        var index = arguments.startIndex
        while index + 1 < arguments.endIndex {
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let endpointText = options["--endpoint"], let endpoint = URL(string: endpointText),
              let agentID = options["--agent-id"], !agentID.isEmpty,
              let tokenPath = options["--token-file"],
              let tokenData = FileManager.default.contents(atPath: tokenPath),
              case let token = String(decoding: tokenData, as: UTF8.self), !token.isEmpty else { return }
        // A hard stop besides the request timeout: nothing here may outlive it.
        DispatchQueue.global().asyncAfter(deadline: .now() + WorkspaceAgentHook.postTimeoutSeconds + 0.5) {
            Foundation.exit(0)
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard var payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        if input.count > WorkspaceAgentHook.maxPostedPayloadBytes {
            if let message = payload["last_assistant_message"] as? String {
                payload[WorkspaceAgentHook.trimmedWordCountKey] = AgentReport.wordCount(message)
            }
            for key in WorkspaceAgentHook.bulkyFields { payload.removeValue(forKey: key) }
            payload["array_trimmed"] = true
        }
        let body: [String: Any] = [
            "schema": WorkspaceAPISchema.v1,
            "kind": "request",
            "requestId": UUID().uuidString,
            "agentId": agentID,
            "token": token,
            "op": WorkspaceAgentHook.op,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = WorkspaceAgentHook.postTimeoutSeconds
        configuration.timeoutIntervalForResource = WorkspaceAgentHook.postTimeoutSeconds
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (reply, _) = try? await URLSession(configuration: configuration).data(for: request),
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              object["status"] as? String == "ok",
              let output = (object["result"] as? [String: Any])?[WorkspaceAgentHook.hookOutputKey] as? [String: Any],
              let decision = try? JSONSerialization.data(withJSONObject: output) else { return }
        FileHandle.standardOutput.write(decision + Data("\n".utf8))
    }
}
