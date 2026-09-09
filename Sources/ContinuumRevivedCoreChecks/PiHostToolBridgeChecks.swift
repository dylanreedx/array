import ContinuumRevivedCore
import Foundation

// CX-01 (`.plans/59`, §15 / CX-W30) — the pi host tool bridge, driven end to end
// against a scripted fake `pi --mode rpc` standing in on PATH (the same
// convention as `PiRpcTransportChecks`). The fake IS the extension: on `prompt`
// it emits `tool_execution_start` then an Array-owned `extension_ui_request`,
// waits for the matching `extension_ui_response`, and returns that `value`
// verbatim as the tool's result — writing it to `<cwd>/tool-results/<toolCallId>.json`
// so the assertion target is byte-for-byte what the model would read.
//
// Cases: success, structured error, cancellation (abort), host deadline, late
// reply after the runner was replaced, two concurrent calls correlated by pi id,
// foreign dialogs left alone, and an unbound runner answering `unsupported`.
func runPiHostToolBridgeChecks() {
    checkBridgeSuccessAndContext()
    checkBridgeBoardTool()
    checkBridgeStructuredError()
    checkBridgeCancellationOnAbort()
    checkBridgeHostDeadline()
    checkBridgeLateReplyAfterRunnerReplaced()
    checkBridgeConcurrentCallsCorrelateByPiId()
    checkBridgeForeignDialogsIgnored()
    checkBridgeUnboundRunnerAnswersUnsupported()
    print("PiHostToolBridgeChecks passed")
}

// MARK: - Fake pi (bridge-aware)

/// Reads its scenario from a baked-in path, then serves stdin commands for the
/// life of the process. Scenario keys: `context_request` (bool), `calls`
/// ([{toolCallId, toolName, op, payload, timeout_ms}]), `foreign_requests`
/// ([{id, method, title, timeout_ms}]). Everything it observes is written under
/// the CURRENT DIRECTORY (the runner's cwd), so two agents sharing one fake on
/// PATH still get separate evidence.
private let fakeBridgePiPythonSource = #"""
import json, os, sys, threading, time, uuid

scenario_path = "__SCENARIO__"
with open(scenario_path) as f:
    scenario = json.load(f)

cwd = os.getcwd()
os.makedirs(os.path.join(cwd, "tool-results"), exist_ok=True)
emit_lock = threading.Lock()
state_lock = threading.Lock()
pending = {}      # ui request id -> {"event": Event, "value": str|None}
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
    log("ui-requests.log", req_id + " " + tool_call_id)
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


def run_foreign(req):
    emit({"type": "extension_ui_request", "id": req["id"], "method": req.get("method", "input"),
          "title": req.get("title", "Pick one"), "timeout": req.get("timeout_ms", 300)})
    value = wait_dialog(req["id"], req.get("timeout_ms", 300) / 1000.0)
    if value is not None:
        log("foreign-answered.log", req["id"])


def handle_prompt(cmd):
    if scenario.get("context_request"):
        req_id = str(uuid.uuid4())
        emit({"type": "extension_ui_request", "id": req_id, "method": "input",
              "title": envelope("ctx-" + req_id, "workspace.context", {"compact": True}), "timeout": 2000})
        value = wait_dialog(req_id, 2.0)
        with open(os.path.join(cwd, "context-reply.json"), "w") as f:
            f.write(value if value is not None else "undefined")
    emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    threads = []
    for call in scenario.get("calls", []):
        t = threading.Thread(target=run_call, args=(call,), daemon=True)
        t.start()
        threads.append(t)
    for req in scenario.get("foreign_requests", []):
        t = threading.Thread(target=run_foreign, args=(req,), daemon=True)
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

/// Writes an executable `pi` into a fresh root. The root doubles as the runner's
/// cwd, which is where the fake writes its evidence.
func makeFakeBridgePi(scenario: [String: Any]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-pi-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scenarioURL = root.appendingPathComponent("scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioURL)
    let executableURL = root.appendingPathComponent("pi")
    let wrapper = "#!/usr/bin/env python3\n" + fakeBridgePiPythonSource.replacingOccurrences(of: "__SCENARIO__", with: scenarioURL.path)
    try wrapper.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return root
}

/// Prepends `root` to PATH (the runner resolves `pi` off PATH, as production
/// does) and returns a restore closure.
func prependFakePiToPath(_ root: URL) -> () -> Void {
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(root.path):\(originalPath)", 1)
    return { _ = setenv("PATH", originalPath, 1) }
}

private func makeBridgeRunner(root: URL) -> (runner: PiRpcAgentRunner, restorePath: () -> Void) {
    let restore = prependFakePiToPath(root)
    let config = PiRpcAgentRunner.Config(model: "fixture-model", thinking: "low", cwd: root, sessionId: "bridge-session")
    return (PiRpcAgentRunner(config: config), restore)
}

func bridgeToolResult(root: URL, toolCallId: String) -> [String: Any]? {
    let url = root.appendingPathComponent("tool-results/\(toolCallId).json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func bridgeLog(root: URL, _ name: String) -> [String] {
    guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

private func waitUntilBridge(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func runTurnInBackground(_ runner: PiRpcAgentRunner, prompt: String = "hello", events: BridgeBox<[AgentRuntimeEvent]>? = nil) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        try? runner.run(prompt: AgentPrompt(prompt)) { event in events?.value.append(event) }
        done.signal()
    }
    return done
}

private func oneCall(_ toolCallId: String, op: String = "artifact.open", payload: [String: Any] = ["relativePath": "README.md"]) -> [String: Any] {
    let toolName: String
    switch op {
    case "artifact.open": toolName = "array_open_document"
    case "board.query": toolName = "array_board_query"
    case "board.apply": toolName = "array_board_apply"
    default: toolName = "array_workspace_context"
    }
    return ["toolCallId": toolCallId, "toolName": toolName, "op": op, "payload": payload]
}

// MARK: - Cases

private func checkBridgeSuccessAndContext() {
    guard let root = try? makeFakeBridgePi(scenario: ["context_request": true, "calls": [oneCall("tc-1")]]) else {
        expect(false, "bridge: failed to write fake pi"); return
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }

    let seenOps = BridgeBox<[String]>([])
    runner.observeHostToolRequests { call in
        seenOps.value.append(call.request.op)
        switch call.request.op {
        case "workspace.context":
            call.respond(.ok(["zoneId": "zone-b", "capabilities": ["workspace.context", "artifact.open"]]))
        default:
            call.respond(.ok(["tileId": "tile-1", "document": "existing", "requestId": call.request.requestId]))
        }
    }
    let events = BridgeBox<[AgentRuntimeEvent]>([])
    let done = runTurnInBackground(runner, events: events)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge success: the turn must complete")
    runner.stop()

    let result = bridgeToolResult(root: root, toolCallId: "tc-1")
    expect(result?["status"] as? String == "ok", "bridge success: the TOOL RESULT the model reads must be the host's ok reply, got \(String(describing: result))")
    expect((result?["result"] as? [String: Any])?["tileId"] as? String == "tile-1",
           "bridge success: the tool result must carry the host's tile identity")
    expect(result?["requestId"] as? String == "tc-1", "bridge success: reply requestId must be the tool call id")
    expect(seenOps.value == ["workspace.context", "artifact.open"],
           "bridge success: the host saw the context request first, then the open — got \(seenOps.value)")
    let contextReply = (try? String(contentsOf: root.appendingPathComponent("context-reply.json"), encoding: .utf8)) ?? ""
    expect(contextReply.contains("\"status\":\"ok\"") && contextReply.contains("zone-b"),
           "bridge success: before_agent_start's context request must be answered before the prompt response, got \(contextReply)")
    let started = events.value.contains { if case let .itemStarted(_, itemId, _, title) = $0 { return itemId == "tc-1" && title == "array_open_document" }; return false }
    let completed = events.value.contains { if case let .itemCompleted(_, itemId, _, status) = $0 { return itemId == "tc-1" && status == .completed }; return false }
    expect(started && completed, "bridge success: the transcript still sees the tool item start and complete")
    expect(runner.qaPendingHostToolRequestIds.isEmpty, "bridge success: nothing pending after the turn")
}

private func checkBridgeBoardTool() {
    guard let root = try? makeFakeBridgePi(scenario: [
        "calls": [oneCall("tc-board", op: "board.query", payload: ["boardId": "board-1"])]
    ]) else { expect(false, "board bridge: failed to write fake pi"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    let seen = BridgeBox<[String]>([])
    runner.observeHostToolRequests { call in
        seen.value.append(call.request.op)
        call.respond(.ok(["boardId": "board-1", "revision": 4]))
    }
    let events = BridgeBox<[AgentRuntimeEvent]>([])
    let done = runTurnInBackground(runner, events: events)
    expect(done.wait(timeout: .now() + 15) == .success, "board bridge: the turn must complete")
    runner.stop()
    let result = bridgeToolResult(root: root, toolCallId: "tc-board")
    expect(seen.value == ["board.query"] && result?["status"] as? String == "ok",
           "board bridge: Pi routes array_board_query through the authenticated host bridge")
    let started = events.value.contains {
        if case let .itemStarted(_, itemId, _, title) = $0 {
            return itemId == "tc-board" && title == "array_board_query"
        }
        return false
    }
    expect(started, "board bridge: the real Pi transport exposes the board tool in its transcript")
}

private func checkBridgeStructuredError() {
    guard let root = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-err")]]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    runner.observeHostToolRequests { call in
        call.respond(.error("not_found", "README.md is not a file in that checkout.", details: ["approvalRequestId": "ap-1"]))
    }
    let done = runTurnInBackground(runner)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge error: turn completes")
    runner.stop()
    let result = bridgeToolResult(root: root, toolCallId: "tc-err")
    let error = result?["error"] as? [String: Any]
    expect(result?["status"] as? String == "error" && error?["code"] as? String == "not_found"
           && (error?["details"] as? [String: Any])?["approvalRequestId"] as? String == "ap-1",
           "bridge error: the machine code and details must survive into the tool result, got \(String(describing: result))")
}

private func checkBridgeCancellationOnAbort() {
    guard let root = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-cancel")]]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    let held = BridgeBox<PiHostToolCall?>(nil)
    let cancelFired = BridgeBox(false)
    runner.observeHostToolRequests { call in
        call.onCancel { cancelFired.value = true }
        held.value = call
    }
    let done = runTurnInBackground(runner)
    expect(waitUntilBridge { held.value != nil }, "bridge cancel: the host must receive the call")
    do { try runner.interrupt() } catch { expect(false, "bridge cancel: abort must succeed: \(error)") }
    expect(done.wait(timeout: .now() + 15) == .success, "bridge cancel: the aborted turn completes")

    expect(held.value?.isCancelled == true && cancelFired.value, "bridge cancel: the call is marked cancelled and onCancel fired")
    let result = bridgeToolResult(root: root, toolCallId: "tc-cancel")
    expect(result?["status"] as? String == "cancelled" && result?["requestId"] as? String == "tc-cancel",
           "bridge cancel: the model sees a cancelled result for the aborted call, got \(String(describing: result))")
    expect(bridgeLog(root: root, "received.log").contains("abort"), "bridge cancel: the fake received abort")

    // A late host reply (say the open committed anyway) must not be written to
    // pi, which has already returned the tool.
    let delivery = BridgeBox<PiHostToolDelivery?>(nil)
    let answered = DispatchSemaphore(value: 0)
    held.value?.respond(.cancelled(result: ["tileId": "tile-late"])) { delivery.value = $0; answered.signal() }
    expect(answered.wait(timeout: .now() + 5) == .success, "bridge cancel: late respond completes")
    expect(delivery.value == .droppedToolReturned, "bridge cancel: a reply after tool_execution_end is dropped, got \(String(describing: delivery.value))")
    let responses = bridgeLog(root: root, "ui-responses.log") + bridgeLog(root: root, "unknown-ui-responses.log")
    expect(responses.isEmpty, "bridge cancel: no extension_ui_response was ever written for the aborted call, got \(responses)")
    runner.stop()
}

private func checkBridgeHostDeadline() {
    guard let root = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-slow")]]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    runner.hostToolDeadline = 0.3
    let held = BridgeBox<PiHostToolCall?>(nil)
    runner.observeHostToolRequests { call in held.value = call }
    let done = runTurnInBackground(runner)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge deadline: the turn completes without the host")
    let result = bridgeToolResult(root: root, toolCallId: "tc-slow")
    let error = result?["error"] as? [String: Any]
    expect(result?["status"] as? String == "error" && error?["code"] as? String == "outcome_unknown",
           "bridge deadline: the model gets a structured outcome_unknown, got \(String(describing: result))")
    let delivery = BridgeBox<PiHostToolDelivery?>(nil)
    let answered = DispatchSemaphore(value: 0)
    held.value?.respond(.ok(["tileId": "tile-late"])) { delivery.value = $0; answered.signal() }
    expect(answered.wait(timeout: .now() + 5) == .success, "bridge deadline: late respond completes")
    expect(delivery.value == .droppedAlreadyAnswered || delivery.value == .droppedToolReturned,
           "bridge deadline: a reply after the deadline is dropped, got \(String(describing: delivery.value))")
    expect(bridgeLog(root: root, "ui-responses.log").count == 1, "bridge deadline: exactly one reply (the deadline's) reached pi")
    runner.stop()
}

private func checkBridgeLateReplyAfterRunnerReplaced() {
    guard let rootA = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-a")]]),
          let rootB = try? makeFakeBridgePi(scenario: ["calls": []]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
    let (runnerA, restoreA) = makeBridgeRunner(root: rootA)
    let held = BridgeBox<PiHostToolCall?>(nil)
    runnerA.observeHostToolRequests { call in held.value = call }
    let doneA = runTurnInBackground(runnerA)
    expect(waitUntilBridge { held.value != nil }, "bridge replace: host receives the call")
    runnerA.stop()
    _ = doneA.wait(timeout: .now() + 10)
    restoreA()
    expect(held.value?.isCancelled == true, "bridge replace: stopping the runner cancels its pending call")

    let (runnerB, restoreB) = makeBridgeRunner(root: rootB)
    defer { restoreB() }
    let doneB = runTurnInBackground(runnerB)
    expect(doneB.wait(timeout: .now() + 15) == .success, "bridge replace: the new runner's turn completes")

    let delivery = BridgeBox<PiHostToolDelivery?>(nil)
    let answered = DispatchSemaphore(value: 0)
    held.value?.respond(.ok(["tileId": "tile-a"])) { delivery.value = $0; answered.signal() }
    expect(answered.wait(timeout: .now() + 5) == .success, "bridge replace: late respond completes")
    expect(delivery.value == .droppedRunnerGone, "bridge replace: a reply for a retired runner is dropped, got \(String(describing: delivery.value))")
    let bResponses = bridgeLog(root: rootB, "ui-responses.log") + bridgeLog(root: rootB, "unknown-ui-responses.log")
    expect(bResponses.isEmpty, "bridge replace: the NEW runner's pi never received the old reply, got \(bResponses)")
    runnerB.stop()
}

private func checkBridgeConcurrentCallsCorrelateByPiId() {
    guard let root = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-1"), oneCall("tc-2")]]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    let calls = BridgeBox<[PiHostToolCall]>([])
    runner.observeHostToolRequests { call in
        calls.value.append(call)
        // Answer in REVERSE arrival order once both are in hand, each tagged
        // with its own request id.
        if calls.value.count == 2 {
            for held in calls.value.reversed() {
                held.respond(.ok(["tag": held.request.requestId]))
            }
        }
    }
    let done = runTurnInBackground(runner)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge concurrency: turn completes")
    runner.stop()
    for id in ["tc-1", "tc-2"] {
        let result = bridgeToolResult(root: root, toolCallId: id)
        expect((result?["result"] as? [String: Any])?["tag"] as? String == id,
               "bridge concurrency: \(id) must receive ITS reply (correlated by pi id, not arrival order), got \(String(describing: result))")
    }
    let piIds = Set(calls.value.map(\.request.piRequestId))
    expect(piIds.count == 2, "bridge concurrency: two distinct pi ids, got \(piIds)")
}

private func checkBridgeForeignDialogsIgnored() {
    let otherSchema = "{\"schema\":\"other.v1\",\"kind\":\"request\",\"requestId\":\"x\",\"op\":\"artifact.open\",\"payload\":{}}"
    let scenario: [String: Any] = [
        "calls": [],
        "foreign_requests": [
            ["id": "foreign-plain", "method": "input", "title": "Pick one", "timeout_ms": 200],
            ["id": "foreign-schema", "method": "input", "title": otherSchema, "timeout_ms": 200],
            ["id": "foreign-confirm", "method": "confirm", "title": "Sure?", "timeout_ms": 200],
        ],
    ]
    guard let root = try? makeFakeBridgePi(scenario: scenario) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    let seen = BridgeBox(0)
    runner.observeHostToolRequests { _ in seen.value += 1 }
    let events = BridgeBox<[AgentRuntimeEvent]>([])
    let done = runTurnInBackground(runner, events: events)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge foreign: turn completes")
    runner.stop()
    expect(seen.value == 0, "bridge foreign: another extension's dialogs never reach the host handler, got \(seen.value)")
    expect(bridgeLog(root: root, "foreign-answered.log").isEmpty && bridgeLog(root: root, "unknown-ui-responses.log").isEmpty,
           "bridge foreign: Array never answers a dialog it does not own")
    expect(events.value.contains { if case .turnCompleted = $0 { return true }; return false },
           "bridge foreign: the turn still completes normally")
}

private func checkBridgeUnboundRunnerAnswersUnsupported() {
    guard let root = try? makeFakeBridgePi(scenario: ["calls": [oneCall("tc-unbound")]]) else { expect(false, "bridge: fake"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeBridgeRunner(root: root)
    defer { restorePath() }
    // No observeHostToolRequests: nothing is bound.
    let started = Date()
    let done = runTurnInBackground(runner)
    expect(done.wait(timeout: .now() + 15) == .success, "bridge unbound: turn completes")
    runner.stop()
    let result = bridgeToolResult(root: root, toolCallId: "tc-unbound")
    expect(result?["status"] as? String == "error" && (result?["error"] as? [String: Any])?["code"] as? String == "unsupported",
           "bridge unbound: an unbound runner answers unsupported promptly, got \(String(describing: result))")
    expect(Date().timeIntervalSince(started) < 10, "bridge unbound: the model never waits out a deadline for an unbound runner")
}

/// Thread-hopping cell for check assertions (the transport checks keep theirs private).
private final class BridgeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
