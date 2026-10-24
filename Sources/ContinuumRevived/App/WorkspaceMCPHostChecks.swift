import AppKit
import ContinuumRevivedCore
import Foundation

private struct WorkspaceMCPHostCheckError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// The real `array-workspace-mcp` helper against a real `WorkspaceMCPHost`,
/// three calls at once:
/// - `board.query` answers at once, as every op did before S1;
/// - `canvas.query` answers 0.6 s later, from a main-queue callback, the way a
///   browser action answers when WebKit calls back. The main thread must keep
///   running meanwhile: the host used to answer with `DispatchQueue.main.sync`,
///   which held main for the whole call and had no way to answer later;
/// - `workspace.context` answers with a picture at `result.image`, which must
///   leave as an MCP image item with no base64 in the text or
///   `structuredContent` (`.plans/80-browser-computer-use`, S1).
@MainActor
func runWorkspaceMCPHostCheck() throws {
    let host = WorkspaceMCPHost()
    let agentID = AgentID(rawValue: UUID())
    var receivedAgentIDs: Set<String> = []
    var receivedOperations: [String] = []
    // A distinctive payload, so a leak into the text is unmistakable.
    let pictureBase64 = Data("ARRAY-S1-PICTURE-BYTES".utf8).base64EncodedString()
    var delayedPending = false
    var mainTicksWhileDelayed = 0
    host.setHandler { request, reply in
        receivedAgentIDs.insert(request["agentId"] as? String ?? "")
        let op = request["op"] as? String ?? ""
        receivedOperations.append(op)
        var answer: [String: Any] = [
            "schema": WorkspaceAPISchema.v1,
            "requestId": request["requestId"] as? String ?? "",
            "status": "ok",
            "result": ["accepted": true]
        ]
        switch op {
        case WorkspaceAPIOp.canvasQuery.rawValue:
            delayedPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                delayedPending = false
                answer["result"] = ["accepted": true, "answeredLater": true]
                reply(answer)
            }
        case WorkspaceAPIOp.workspaceContext.rawValue:
            answer["result"] = ["accepted": true, "image": ["mimeType": "image/png", "data": pictureBase64]]
            reply(answer)
        default:
            reply(answer)
        }
    }
    let ticker = Timer(timeInterval: 0.02, repeats: true) { _ in
        MainActor.assumeIsolated { if delayedPending { mainTicksWhileDelayed += 1 } }
    }
    RunLoop.main.add(ticker, forMode: .default)
    defer { ticker.invalidate() }

    let helper = ProcessInfo.processInfo.environment["CONTINUUM_WORKSPACE_MCP_BINARY"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/array-workspace-mcp").path
    guard FileManager.default.isExecutableFile(atPath: helper) else {
        throw WorkspaceMCPHostCheckError("workspace MCP helper is missing at \(helper)")
    }
    guard let config = host.configuration(for: agentID, serverExecutable: helper) else {
        throw WorkspaceMCPHostCheckError("workspace MCP host did not issue a registration")
    }

    let process = Process()
    let input = Pipe(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: helper)
    process.standardInput = input; process.standardOutput = output
    var environment = ProcessInfo.processInfo.environment
    environment.merge(config.environment) { _, new in new }
    process.environment = environment
    try process.run()
    func call(_ id: Int, _ tool: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":{}}}\n"
    }
    let lines = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n"
        + "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n"
        + call(3, "array_board_query") + call(4, "array_canvas_query") + call(5, "array_workspace_context")
    input.fileHandleForWriting.write(Data(lines.utf8))
    try input.fileHandleForWriting.close()
    // Read concurrently: a full stdout pipe would stall the helper.
    let collected = HostCheckOutput()
    output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    output.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate(); throw WorkspaceMCPHostCheckError("workspace MCP helper did not finish within 30 s") }
    collected.append(output.fileHandleForReading.readDataToEndOfFile())
    let text = String(decoding: collected.data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw WorkspaceMCPHostCheckError("workspace MCP helper exited \(process.terminationStatus): \(text)")
    }
    var byID: [Int: [String: Any]] = [:]
    for line in text.split(separator: "\n") {
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let id = object["id"] as? Int { byID[id] = object }
    }
    func result(_ id: Int) -> [String: Any]? { byID[id]?["result"] as? [String: Any] }
    func content(_ id: Int) -> [[String: Any]] { result(id)?["content"] as? [[String: Any]] ?? [] }

    // 1. Discovery and an immediate, authenticated answer.
    guard text.contains("\"protocolVersion\":\"2024-11-05\""),
          text.contains("\"name\":\"array_board_query\"") && text.contains("\"name\":\"array_board_apply\""),
          receivedAgentIDs == [agentID.rawValue.uuidString],
          Set(receivedOperations) == [WorkspaceAPIOp.boardQuery.rawValue, WorkspaceAPIOp.canvasQuery.rawValue,
                                      WorkspaceAPIOp.workspaceContext.rawValue],
          (content(3).first?["text"] as? String)?.contains("\"status\":\"ok\"") == true else {
        throw WorkspaceMCPHostCheckError("workspace MCP child/host exchange was incomplete: output=\(text) agents=\(receivedAgentIDs) ops=\(receivedOperations)")
    }
    // 2. Answered later, with main free meanwhile.
    guard (content(4).first?["text"] as? String)?.contains("answeredLater") == true else {
        throw WorkspaceMCPHostCheckError("a reply delivered after the handler returned never reached the helper: \(String(describing: byID[4]))")
    }
    guard mainTicksWhileDelayed >= 10 else {
        throw WorkspaceMCPHostCheckError("the main thread was held while a reply was pending: \(mainTicksWhileDelayed) timer ticks in 0.6 s")
    }
    // 3. The picture is an image item, and nowhere else.
    let items = content(5)
    let image = items.first { $0["type"] as? String == "image" }
    guard items.count == 2, image?["mimeType"] as? String == "image/png", image?["data"] as? String == pictureBase64 else {
        throw WorkspaceMCPHostCheckError("a reply's result.image must leave as one MCP image item: \(items)")
    }
    let replyText = items.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    let structured = result(5)?["structuredContent"] ?? [:]
    let structuredText = String(decoding: (try? JSONSerialization.data(withJSONObject: structured)) ?? Data(), as: UTF8.self)
    guard !replyText.contains(pictureBase64), !structuredText.contains(pictureBase64),
          replyText.contains("\"attached\":true") else {
        throw WorkspaceMCPHostCheckError("the picture's base64 leaked into the text or structuredContent: text=\(replyText) structured=\(structuredText)")
    }
    print("Workspace MCP host check passed: authenticated calls routed with bound identity; a reply answered 0.6 s later arrived while main ran \(mainTicksWhileDelayed) timer ticks; a reply's picture left as an MCP image item with no base64 in the text or structuredContent")
}

private final class HostCheckOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
