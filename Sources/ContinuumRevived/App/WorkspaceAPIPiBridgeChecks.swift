import AppKit
import ContinuumRevivedCore
import Foundation

/// CX-01 (`.plans/59`, §15 / CX-W30) — the bridge through the REAL supervisor:
/// `AgentSupervisor.productionRunner` builds a `PiRpcAgentRunner`, the supervisor
/// installs `observeHostToolRequests` with its generation guard, and the reply
/// the host writes lands in the TOOL RESULT the (fake) pi returns to its model.
/// Two agents share one fake `pi` on PATH; each request must be answered with the
/// SUPERVISOR's id for the runner that carried it, never the other agent's. A call
/// held across `stop` is dropped as `droppedRunnerGone` and the replacement
/// process never sees it.
///
/// Real pi cannot run in the matrix (no model, no auth offline); the manual
/// real-provider acceptance lives in the design packet. The fake's python source
/// mirrors `PiHostToolBridgeChecks` in CoreChecks — a second target cannot import
/// it — and writes its evidence under the runner's cwd.
@MainActor
func runWorkspaceAPIPiBridgeChecks() async throws {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    guard let appSupportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT — this check mints durable agent records and must never write a real store")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(message: "refusing to run from the PROD bundle — dev channel only")
    }

    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-workspace-api-bridge-\(UUID().uuidString)", isDirectory: true)
    let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
    let cwdA = tempRoot.appendingPathComponent("agent-a", isDirectory: true)
    let cwdB = tempRoot.appendingPathComponent("agent-b", isDirectory: true)
    for dir in [binDir, cwdA, cwdB] { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? fileManager.removeItem(at: tempRoot) }

    let scenario: [String: Any] = ["calls": [["toolCallId": "tc-1", "toolName": "array_open_document", "op": "artifact.open", "payload": ["relativePath": "README.md"]]]]
    let scenarioURL = tempRoot.appendingPathComponent("scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioURL)
    let wrapper = "#!/usr/bin/env python3\n" + workspaceAPIBridgeFakePiSource.replacingOccurrences(of: "__SCENARIO__", with: scenarioURL.path)
    let executable = binDir.appendingPathComponent("pi")
    try wrapper.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(binDir.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }

    func toolResult(_ cwd: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: cwd.appendingPathComponent("tool-results/tc-1.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func log(_ cwd: URL, _ name: String) -> [String] {
        guard let text = try? String(contentsOf: cwd.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // `send` refuses a harness that is not ready or a model it does not own; the
    // fake stands in for pi, so the QA catalogue says so (the strict-harness leg
    // uses the same seam).
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: ["fixture-model"],
        displayNames: ["fixture-model": "Fixture"], contextWindows: ["fixture-model": 1]))
    let store = AgentStore(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath, isDirectory: true)
        .appendingPathComponent("workspace-api-bridge-check", isDirectory: true))
    let supervisor = AgentSupervisor(store: store)
    var handled: [(AgentID, String)] = []
    var holding = false
    var held: PiHostToolCall?
    supervisor.hostToolHandler = { agentId, call in
        handled.append((agentId, call.request.requestId))
        if holding { held = call; return }
        call.respond(.ok(["agentId": agentId.rawValue.uuidString, "requestId": call.request.requestId]))
    }

    let agentA = supervisor.spawn(role: nil, prompt: nil, cwd: cwdA, harness: .pi, model: "fixture-model", thinking: "low")
    let agentB = supervisor.spawn(role: nil, prompt: nil, cwd: cwdB, harness: .pi, model: "fixture-model", thinking: "low")
    try expect(supervisor.send("hello", to: agentA) && supervisor.send("hello", to: agentB), "both prompts must be accepted")

    let bothAnswered = await waitUntil(timeout: 30, pollInterval: 0.1) {
        toolResult(cwdA) != nil && toolResult(cwdB) != nil
    }
    try expect(bothAnswered, "both fakes must receive a tool result (A: \(String(describing: toolResult(cwdA))), B: \(String(describing: toolResult(cwdB))))")
    let resultA = toolResult(cwdA)?["result"] as? [String: Any]
    let resultB = toolResult(cwdB)?["result"] as? [String: Any]
    try expect(resultA?["agentId"] as? String == agentA.rawValue.uuidString,
               "agent A's tool result must carry the SUPERVISOR's id for A, got \(String(describing: resultA))")
    try expect(resultB?["agentId"] as? String == agentB.rawValue.uuidString,
               "agent B's tool result must carry the SUPERVISOR's id for B, got \(String(describing: resultB))")
    try expect(toolResult(cwdA)?["status"] as? String == "ok" && toolResult(cwdA)?["requestId"] as? String == "tc-1",
               "the reply is the host's structured ok for the tool call id")
    try expect(handled.count == 2 && Set(handled.map(\.0)) == [agentA, agentB],
               "the handler saw exactly one bound call per agent, got \(handled)")
    let bothSettled = await waitUntil(timeout: 30, pollInterval: 0.1) {
        supervisor.records[agentA]?.runCompletedAt != nil && supervisor.records[agentB]?.runCompletedAt != nil
    }
    try expect(bothSettled, "both turns must complete")

    // Runner replacement: hold A's next call, stop A, answer late → dropped; the
    // replacement process answers its own turn and never sees the stale reply.
    holding = true
    try expect(supervisor.send("again", to: agentA), "second prompt to A accepted")
    let heldArrived = await waitUntil(timeout: 30, pollInterval: 0.1) { held != nil }
    try expect(heldArrived, "the held call must reach the host")
    supervisor.stop(agentA)
    try expect(held?.isCancelled == true, "stopping the agent cancels its pending host call")
    let delivery: PiHostToolDelivery = await withCheckedContinuation { continuation in
        held!.respond(.ok(["agentId": "late"])) { continuation.resume(returning: $0) }
    }
    try expect(delivery == .droppedRunnerGone, "a reply for a stopped runner is dropped, got \(delivery)")
    holding = false
    held = nil
    let promptsBeforeThird = log(cwdA, "received.log").filter { $0 == "prompt" }.count
    try expect(supervisor.send("third", to: agentA), "third prompt to A accepted (fresh runner)")
    let thirdAnswered = await waitUntil(timeout: 30, pollInterval: 0.1) {
        log(cwdA, "received.log").filter { $0 == "prompt" }.count == promptsBeforeThird + 1
            && log(cwdA, "ui-responses.log").count == 2
    }
    try expect(thirdAnswered, "the replacement runner's turn is answered; ui-responses so far: \(log(cwdA, "ui-responses.log"))")
    try expect(log(cwdA, "unknown-ui-responses.log").isEmpty, "the stale reply never reached any pi process")
    try expect(handled.count == 4, "four bound calls in total (A, B, A held, A third), got \(handled.count)")
    supervisor.stopAll()
}

/// See `PiHostToolBridgeChecks.swift` (CoreChecks) for the annotated original.
private let workspaceAPIBridgeFakePiSource = #"""
import json, os, sys, threading, time, uuid

scenario_path = "__SCENARIO__"
with open(scenario_path) as f:
    scenario = json.load(f)

cwd = os.getcwd()
os.makedirs(os.path.join(cwd, "tool-results"), exist_ok=True)
emit_lock = threading.Lock()
state_lock = threading.Lock()
pending = {}
aborted = threading.Event()


def emit(obj):
    with emit_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def log(name, line):
    with state_lock:
        with open(os.path.join(cwd, name), "a") as f:
            f.write(line + "\n")


def wait_dialog(req_id, timeout_s):
    ev = threading.Event()
    with state_lock:
        pending[req_id] = {"event": ev, "value": None}
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if ev.wait(0.02):
            break
        if aborted.is_set():
            break
    with state_lock:
        entry = pending.pop(req_id, None)
    if entry is None:
        return None
    return entry["value"]


def envelope(request_id, op, payload):
    return json.dumps({"schema": "array.workspace.v1", "kind": "request", "requestId": request_id, "op": op, "payload": payload})


def run_call(call):
    tool_call_id = call["toolCallId"]
    tool_name = call.get("toolName", "array_open_document")
    emit({"type": "tool_execution_start", "toolCallId": tool_call_id, "toolName": tool_name, "args": call.get("payload", {})})
    req_id = str(uuid.uuid4())
    timeout_ms = call.get("timeout_ms", 45000)
    emit({"type": "extension_ui_request", "id": req_id, "method": "input",
          "title": envelope(tool_call_id, call.get("op", "artifact.open"), call.get("payload", {})),
          "timeout": timeout_ms})
    value = wait_dialog(req_id, timeout_ms / 1000.0)
    if value is None:
        if aborted.is_set():
            echo = json.dumps({"schema": "array.workspace.v1", "requestId": tool_call_id, "status": "cancelled"})
        else:
            echo = json.dumps({"schema": "array.workspace.v1", "requestId": tool_call_id, "status": "error",
                               "error": {"code": "outcome_unknown", "message": "bridge timeout"}})
    else:
        echo = value
    with open(os.path.join(cwd, "tool-results", tool_call_id + ".json"), "w") as f:
        f.write(echo)
    try:
        details = json.loads(echo)
    except Exception:
        details = {}
    emit({"type": "tool_execution_end", "toolCallId": tool_call_id, "toolName": tool_name,
          "result": {"content": [{"type": "text", "text": echo}], "details": details}, "isError": False})


def handle_prompt(cmd):
    emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    threads = []
    for call in scenario.get("calls", []):
        t = threading.Thread(target=run_call, args=(call,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    emit({"type": "turn_end"})
    emit({"type": "agent_end", "willRetry": False})
    emit({"type": "agent_settled"})


def handle(cmd):
    cmd_type = cmd.get("type")
    if cmd_type == "extension_ui_response":
        with state_lock:
            entry = pending.get(cmd.get("id"))
            if entry is not None:
                entry["value"] = cmd.get("value")
                entry["event"].set()
        log("ui-responses.log" if entry is not None else "unknown-ui-responses.log",
            str(cmd.get("id")) + " " + json.dumps(cmd.get("value")))
        return
    log("received.log", str(cmd_type))
    if cmd_type == "prompt":
        handle_prompt(cmd)
    elif cmd_type == "abort":
        aborted.set()
        with state_lock:
            for entry in pending.values():
                entry["event"].set()
        emit({"type": "response", "id": cmd.get("id"), "command": "abort", "success": True})
    else:
        emit({"type": "response", "id": cmd.get("id"), "command": cmd_type, "success": True, "data": {}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    threading.Thread(target=handle, args=(obj,), daemon=True).start()

time.sleep(0.3)
"""#
