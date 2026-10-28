import ContinuumRevivedCore
import Foundation

// Ticket: codex app-server migration (.plans/46, "Codex app-server parity
// harness — the de-risking step, taken"). `CodexAppServerParityChecks` pinned
// the PURE translator. This file pins the IMPURE half the parity ticket left
// unaddressed on purpose: `CodexAppServerTransport` (the JSON-RPC-over-stdio
// driver) and `CodexAgentRunner`'s app-server run path — process-per-turn
// framing, the fresh-vs-resume decision, the JSON-RPC-error self-heal, and
// `stop()`'s `turn/interrupt`.
//
// Both halves run against a SCRIPTED fake `codex app-server` — a small python3
// process that plays back a fixed conversation (a JSON "scenario": alternating
// "the client will send a request, reply like this" / "emit this notification
// unprompted" steps). No real `codex` binary, no network, no auth — fully
// offline and deterministic, in the same spirit as `ProcessGroupChildChecks`
// spawning `/bin/sh -c "…"` as its test double. python3 is already a checks
// dependency (`main.swift`, `SubstrateTests.swift`).
//
// Two levels:
//   1. `CodexAppServerTransport` driven directly against the fake — request/
//      response correlation, JSON-RPC error surfacing (not stderr text), and
//      a request that never gets a reply timing out.
//   2. `CodexAgentRunner.run(prompt:onEvent:)` — the actual PRODUCTION entry
//      point `AgentSupervisor.codexRunner(for:)` calls — driven end to end
//      with the fake standing in for `codex` on PATH and
//      `CONTINUUM_CODEX_TRANSPORT=app-server` selecting the new path. Mutating
//      real process environment (PATH, the transport switch) for the
//      duration of one check is new in this file: `CodexAgentRunner` resolves
//      both from `ProcessInfo.processInfo.environment` with no injection seam
//      (matching every other runner's `liveResolvedCommand()`), so driving the
//      REAL `run()` — not a re-derivation of what it does — has no other way
//      in. Restored via `defer` before the function returns.
func runCodexAppServerRunnerChecks() {
    runCodexAppServerTransportChecks()
    runCodexAppServerDeclineChecks()
    runCodexAgentRunnerAppServerChecks()
}

// MARK: - fake `codex app-server`

/// One step of a scripted fake app-server conversation.
private enum FakeAppServerStep {
    /// Read one incoming JSON-RPC request line (ANY method — the fake does not
    /// validate the method name, only order) and reply with `result` (or
    /// `error` when non-nil).
    case expectRequest(result: [String: Any] = [:], error: [String: Any]? = nil)
    /// Read and discard one incoming notification line (e.g. `initialized`).
    case expectNotification
    /// Emit one notification, unprompted, after `delayMs`.
    case emit(method: String, params: [String: Any], delayMs: Int = 0)
    /// Enough diagnostics to fill an undrained stderr pipe.
    case stderr(byteCount: Int)
    /// A request the fake deliberately never answers, to exercise a timeout.
    case hang
    /// A request FROM the fake to Array (it carries an id), e.g. an MCP
    /// elicitation. Array must answer it; see `expectReply`.
    case emitRequest(id: Int, method: String, params: [String: Any], delayMs: Int = 0)
    /// Read one line Array writes back and append it verbatim to `replies.log`.
    case expectReply

    var jsonValue: [String: Any] {
        switch self {
        case let .expectRequest(result, error):
            var value: [String: Any] = ["kind": "expect_request", "result": result]
            if let error { value["error"] = error }
            return value
        case .expectNotification:
            return ["kind": "expect_notification"]
        case let .emit(method, params, delayMs):
            return ["kind": "emit", "notification": ["method": method, "params": params], "delay_ms": delayMs]
        case let .stderr(byteCount):
            return ["kind": "stderr", "byte_count": byteCount]
        case .hang:
            return ["kind": "hang"]
        case let .emitRequest(id, method, params, delayMs):
            return ["kind": "emit", "notification": ["id": id, "method": method, "params": params], "delay_ms": delayMs]
        case .expectReply:
            return ["kind": "expect_reply"]
        }
    }
}

/// python3 source for the fake. Reads its scenario from argv[1] (a JSON file
/// path) so the SAME script serves every scenario in this file — the scenario
/// data, not the script, is what varies per check.
///
/// `CodexAgentRunner`'s self-heal (fresh vs. resume) spawns a SEPARATE `codex`
/// process for each attempt — `runOnceAppServer` opens and tears down its own
/// process per turn/attempt, never reusing one (see that method's doc comment
/// on why: `AgentSupervisor` builds a fresh `CodexAgentRunner` per send, so
/// there is no live connection to hold across attempts either). A scenario
/// that must span two attempts is therefore two SEPARATE conversations, not
/// one continuous one: this script picks scenario N on its Nth invocation, via
/// a counter file (`invocation.count`) sitting next to the scenario files in
/// the same directory — the directory (hence the fake `codex` executable
/// path) is shared across every spawn of the same check's runner.
private let fakeAppServerPythonSource = #"""
import json, os, select, sys, time

# One unbuffered line reader for every step: `expect_reply` needs a timeout,
# and select() on a buffered sys.stdin can miss a line already read ahead.
_pending = b""
def read_line(timeout=None):
    global _pending
    deadline = None if timeout is None else time.time() + timeout
    while b"\n" not in _pending:
        wait = None if deadline is None else max(0.0, deadline - time.time())
        ready, _, _ = select.select([0], [], [], wait)
        if not ready:
            return None
        chunk = os.read(0, 65536)
        if not chunk:
            return ""
        _pending += chunk
    line, _, _pending = _pending.partition(b"\n")
    return line.decode("utf-8") + "\n"

scenario_dir = os.path.dirname(os.path.abspath(sys.argv[1]))
counter_path = os.path.join(scenario_dir, "invocation.count")
try:
    with open(counter_path, "r") as f:
        invocation = int(f.read().strip() or "0")
except FileNotFoundError:
    invocation = 0
with open(counter_path, "w") as f:
    f.write(str(invocation + 1))

scenario_path = os.path.join(scenario_dir, "scenario_%d.json" % invocation)
if not os.path.exists(scenario_path):
    scenario_path = sys.argv[1]
with open(scenario_path) as f:
    scenario = json.load(f)

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

progress_path = os.path.join(scenario_dir, "progress.log")
replies_path = os.path.join(scenario_dir, "replies.log")
with open(os.path.join(scenario_dir, "argv.log"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")

def log_received(method, thread=None):
    with open(progress_path, "a") as f:
        f.write(method + (" " + thread if thread else "") + "\n")

for action in scenario:
    kind = action["kind"]
    if kind in ("expect_request", "expect_notification"):
        line = read_line()
        if not line:
            break
        obj = json.loads(line)
        log_received(obj.get("method", ""), (obj.get("params") or {}).get("threadId"))
        if kind == "expect_request":
            reply = {"id": obj.get("id")}
            if action.get("error") is not None:
                reply["error"] = action["error"]
            else:
                reply["result"] = action.get("result", {})
            send(reply)
    elif kind == "emit":
        time.sleep(action.get("delay_ms", 0) / 1000.0)
        send(action["notification"])
    elif kind == "stderr":
        sys.stderr.write("diagnostic line\n" * (action["byte_count"] // 16 + 1))
        sys.stderr.flush()
    elif kind == "hang":
        time.sleep(30)
    elif kind == "expect_reply":
        # Bounded: an Array that never answers must fail the check, not hang it.
        line = read_line(timeout=5)
        if line is None:
            continue
        if not line:
            break
        with open(replies_path, "a") as f:
            f.write(line)

time.sleep(0.3)
"""#

/// Writes the fake script + its scenario(s) to a fresh temp dir. Each element
/// of `scenarios` serves ONE process invocation, in order (see the script's
/// own doc comment on why more than one is ever needed — the self-heal path).
/// A single-scenario call is the common case. `asExecutable` (default false)
/// also chmods the script +x and names it `codex` so it can stand in on PATH
/// for a `CodexAgentRunner` integration check; the transport-level checks
/// spawn it directly via `/usr/bin/env python3` and don't need that.
private func makeFakeAppServer(
    scenarios: [[FakeAppServerStep]],
    asExecutableNamed name: String? = nil
) throws -> (scriptURL: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-codex-appserver-fake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var firstScenarioURL: URL!
    for (index, scenario) in scenarios.enumerated() {
        let scenarioJSON = try JSONSerialization.data(withJSONObject: scenario.map(\.jsonValue))
        let scenarioURL = root.appendingPathComponent("scenario_\(index).json")
        try scenarioJSON.write(to: scenarioURL)
        if index == 0 { firstScenarioURL = scenarioURL }
    }

    if let name {
        let scriptURL = root.appendingPathComponent(name)
        let wrapper = "#!/usr/bin/env python3\n" + fakeAppServerPythonSource.replacingOccurrences(
            of: "sys.argv[1]", with: "\"\(firstScenarioURL!.path)\"")
        try wrapper.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return (scriptURL, root)
    }

    let scriptURL = root.appendingPathComponent("fake_appserver.py")
    try fakeAppServerPythonSource.write(to: scriptURL, atomically: true, encoding: .utf8)
    return (scriptURL, firstScenarioURL)
}

/// Convenience for the common single-scenario case.
private func makeFakeAppServer(
    scenario: [FakeAppServerStep],
    asExecutableNamed name: String? = nil
) throws -> (scriptURL: URL, root: URL) {
    try makeFakeAppServer(scenarios: [scenario], asExecutableNamed: name)
}

// MARK: - 1. CodexAppServerTransport, driven directly

private func runCodexAppServerTransportChecks() {
    // 1a. A normal round trip: request → correlated response, and an
    // unprompted notification forwarded independently of any request.
    do {
        let (script, scenarioOrRoot) = try! makeFakeAppServer(scenario: [
            .expectRequest(result: ["ok": true]),
            .emit(method: "thread/started", params: ["thread": ["id": "fixture-thread"]], delayMs: 20),
            .expectRequest(result: ["turn": ["id": "fixture-turn"]]),
        ])
        let child = try! ProcessGroupChild.spawn(
            executable: "/usr/bin/env",
            arguments: ["python3", script.path, scenarioOrRoot.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            standardInput: .pipe)
        var notifications: [String] = []
        let notificationsLock = NSLock()
        let transport = CodexAppServerTransport(child: child) { line in
            notificationsLock.lock(); notifications.append(line); notificationsLock.unlock()
        }
        let result = try! transport.sendRequest(method: "initialize", params: [:], timeout: 5)
        expect((result["ok"] as? Bool) == true, "transport: sendRequest must return the correlated result")
        Thread.sleep(forTimeInterval: 0.15)
        let turnResult = try! transport.sendRequest(method: "turn/start", params: [:], timeout: 5)
        expect((turnResult["turn"] as? [String: Any])?["id"] as? String == "fixture-turn",
               "transport: a SECOND request must correlate to its OWN response, not the first")
        notificationsLock.lock(); let seen = notifications; notificationsLock.unlock()
        expect(seen.contains { $0.contains("thread/started") },
               "transport: an unprompted notification must reach the handler independently of any request")
        transport.shutdown()
        _ = child.wait()
    }

    // 1b. A JSON-RPC error response must surface as `RPCError` with the CODE
    // and MESSAGE intact — never parsed from stderr text (the whole point of
    // leaving `isUnknownSessionFailure`'s stderr-matching behind).
    do {
        let (script, scenarioOrRoot) = try! makeFakeAppServer(scenario: [
            .expectRequest(error: ["code": -32600, "message": "no rollout found for thread id fixture-id"]),
        ])
        let child = try! ProcessGroupChild.spawn(
            executable: "/usr/bin/env",
            arguments: ["python3", script.path, scenarioOrRoot.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            standardInput: .pipe)
        let transport = CodexAppServerTransport(child: child) { _ in }
        do {
            _ = try transport.sendRequest(method: "thread/resume", params: [:], timeout: 5)
            expect(false, "transport: a JSON-RPC error response must throw")
        } catch let error as CodexAppServerTransport.RPCError {
            expect(error.code == -32600, "transport: RPCError must carry the real error code; got \(error.code)")
            expect(CodexCLIBackend.isUnknownSessionFailure(appServerErrorMessage: error.message),
                   "transport: the resume-failure message must match the self-heal trigger")
        } catch {
            expect(false, "transport: expected RPCError, got \(error)")
        }
        transport.shutdown()
        _ = child.wait()
    }

    // 1c. A request nobody ever answers must time out, not hang.
    do {
        let (script, scenarioOrRoot) = try! makeFakeAppServer(scenario: [.hang])
        let child = try! ProcessGroupChild.spawn(
            executable: "/usr/bin/env",
            arguments: ["python3", script.path, scenarioOrRoot.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            standardInput: .pipe)
        let transport = CodexAppServerTransport(child: child) { _ in }
        let started = Date()
        do {
            _ = try transport.sendRequest(method: "initialize", params: [:], timeout: 0.5)
            expect(false, "transport: an unanswered request must time out")
        } catch is CodexAppServerTransport.TimeoutError {
            expect(Date().timeIntervalSince(started) < 5, "transport: the timeout must be honored, not the process's own lifetime")
        } catch {
            expect(false, "transport: expected TimeoutError, got \(error)")
        }
        transport.shutdown()
        child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.harness)
    }
}

// MARK: - 1d. Requests FROM codex are always answered

/// `.plans/80-browser-computer-use` §9: codex's own computer-use plugin asks
/// permission through `mcpServer/elicitation/request`. The transport used to
/// forward every request as a notification and never answer, so each call
/// failed and the turn waited on it. RED before: no reply is ever written, so
/// `replies.log` stays empty.
private func readReplies(_ dir: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("replies.log"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}

private func runCodexAppServerDeclineChecks() {
    let (script, scenario) = try! makeFakeAppServer(scenario: [
        .emitRequest(id: 41, method: "mcpServer/elicitation/request",
                     params: ["threadId": "t", "serverName": "computer-use",
                              "message": "Allow ChatGPT to use Finder?", "mode": "form",
                              "requestedSchema": ["type": "object", "properties": [:]]]),
        .expectReply,
        .emitRequest(id: 42, method: "item/commandExecution/requestApproval", params: ["threadId": "t"]),
        .expectReply,
        .emitRequest(id: 43, method: "item/tool/call", params: ["threadId": "t"]),
        .expectReply,
    ])
    let child = try! ProcessGroupChild.spawn(
        executable: "/usr/bin/env",
        arguments: ["python3", script.path, scenario.path],
        environment: ["PATH": "/usr/bin:/bin"],
        currentDirectory: nil,
        standardInput: .pipe)
    let forwarded = ThreadIdCollector()
    let transport = CodexAppServerTransport(child: child) { forwarded.append($0) }
    _ = child.wait()
    transport.shutdown()
    let replies = readReplies(scenario.deletingLastPathComponent())
    expect(replies.count == 3, "transport: every request from codex must get exactly one reply; got \(replies.count)")
    func reply(_ id: Int) -> [String: Any]? { replies.first { ($0["id"] as? Int) == id } }
    expect((reply(41)?["result"] as? [String: Any])?["action"] as? String == "decline",
           "transport: an MCP elicitation must be answered with action=decline; got \(String(describing: reply(41)))")
    expect((reply(42)?["result"] as? [String: Any])?["decision"] as? String == "decline",
           "transport: a command approval must be answered with decision=decline; got \(String(describing: reply(42)))")
    expect((reply(43)?["error"] as? [String: Any])?["code"] as? Int == -32601,
           "transport: any other request must get a JSON-RPC error, never silence; got \(String(describing: reply(43)))")
    expect(forwarded.snapshot().count == 3,
           "transport: each request must still reach the translator so the transcript records it")
    try? FileManager.default.removeItem(at: scenario.deletingLastPathComponent())
}

// MARK: - 2. CodexAgentRunner, driven through its real `run()`

/// Mutates real process environment for the duration of `body`, restoring the
/// previous value (or absence) afterward. `CodexAgentRunner` has no injection
/// seam for either PATH resolution or the transport switch — both read
/// `ProcessInfo.processInfo.environment` directly, matching every other
/// runner's `liveResolvedCommand()` — so this is the only way to drive the
/// REAL `run()` entry point with a scripted fake instead of the real `codex`.
private func withEnvironmentOverride(_ overrides: [String: String], _ body: () throws -> Void) rethrows {
    var previous: [String: String?] = [:]
    for (key, value) in overrides {
        previous[key] = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
    }
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    try body()
}

private final class ThreadIdCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentRuntimeEvent] = []
    func append(_ event: AgentRuntimeEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    func snapshot() -> [AgentRuntimeEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class ProviderActivityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var activities: [ProviderSubagentActivity] = []
    func append(_ activity: ProviderSubagentActivity) {
        lock.lock(); activities.append(activity); lock.unlock()
    }
    func snapshot() -> [ProviderSubagentActivity] {
        lock.lock(); defer { lock.unlock() }; return activities
    }
}

private func runCodexAgentRunnerAppServerChecks() {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-codex-appserver-runner-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    // 2a. Fresh run: thread/start mints an id, one turn streams a delta and
    // completes. Asserts the events a real transcript needs arrive, AND that
    // they arrive as the turn progresses rather than being buffered — the
    // collector is polled mid-run before the fake even emits turn/completed.
    do {
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read automatic-compaction observation
                .expectRequest(result: ["thread": ["id": "fixture-fresh-thread"]]),   // thread/start
                .expectRequest(result: ["turn": ["id": "fixture-fresh-turn"]]),       // turn/start
                .emit(method: "turn/started",
                      params: ["threadId": "fixture-fresh-thread", "turn": ["id": "fixture-fresh-turn"]],
                      delayMs: 10),
                .emit(method: "item/agentMessage/delta",
                      params: ["threadId": "fixture-fresh-thread", "turnId": "fixture-fresh-turn", "delta": "hi"],
                      delayMs: 50),
                .emit(method: "turn/completed",
                      params: ["threadId": "fixture-fresh-thread",
                               "turn": ["id": "fixture-fresh-turn", "status": "completed"]],
                      delayMs: 50),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        var caught: Error?
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: nil))
            let collector = EventCollector()
            do {
                try runner.run(prompt: "hello") { collector.append($0) }
            } catch {
                caught = error
            }
            let events = collector.snapshot()
            expect(caught == nil, "runner (fresh, app-server): run() must not throw on a clean turn; threw \(String(describing: caught))")
            expect(events.contains { if case .turnStarted(_, let turnId) = $0 { return turnId == "fixture-fresh-turn" } else { return false } },
                   "runner (fresh, app-server): turn/started must translate and forward")
            expect(events.contains { if case .contentDelta(_, _, _, let delta) = $0 { return delta == "hi" } else { return false } },
                   "runner (fresh, app-server): a streamed delta must forward as contentDelta")
            expect(events.contains { if case .turnCompleted(_, let turnId, let outcome, _) = $0 { return turnId == "fixture-fresh-turn" && outcome == .completed } else { return false } },
                   "runner (fresh, app-server): turn/completed must forward as a .completed outcome")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2a′. `.plans/80-browser-computer-use` §9, through the production run():
    // a computer-use permission prompt mid-turn is declined, shows as a
    // declined row, and the turn still completes; and the spawned codex was
    // told to load neither the computer-use nor the browser-use plugins.
    do {
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read
                .expectRequest(result: ["thread": ["id": "fixture-cu-thread"]]),   // thread/start
                .expectRequest(result: ["turn": ["id": "fixture-cu-turn"]]),       // turn/start
                .emitRequest(id: 7, method: "mcpServer/elicitation/request",
                             params: ["threadId": "fixture-cu-thread", "turnId": "fixture-cu-turn",
                                      "serverName": "computer-use", "mode": "form",
                                      "message": "Allow ChatGPT to use Finder?",
                                      "requestedSchema": ["type": "object", "properties": [:]]],
                             delayMs: 10),
                .expectReply,
                .emit(method: "turn/completed",
                      params: ["threadId": "fixture-cu-thread",
                               "turn": ["id": "fixture-cu-turn", "status": "completed"]],
                      delayMs: 10),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: nil))
            let collector = EventCollector()
            var caught: Error?
            do { try runner.run(prompt: "use the browser") { collector.append($0) } } catch { caught = error }
            let events = collector.snapshot()
            expect(caught == nil, "runner (computer-use prompt): the turn must complete; threw \(String(describing: caught))")
            let replies = readReplies(fakeRoot)
            expect(replies.count == 1
                   && (replies.first?["id"] as? Int) == 7
                   && ((replies.first?["result"] as? [String: Any])?["action"] as? String) == "decline",
                   "runner (computer-use prompt): codex's elicitation must be answered with a decline; got \(replies)")
            let rowId = "array-declined-request-7"
            expect(events.contains {
                if case .itemStarted("fixture-cu-thread", rowId, .mcpToolCall, let title) = $0 {
                    return title == "Declined: Allow ChatGPT to use Finder?"
                }
                return false
            }, "runner (computer-use prompt): the declined request must show as a transcript row naming what was asked")
            expect(events.contains {
                if case .itemCompleted("fixture-cu-thread", rowId, .mcpToolCall, .declined) = $0 { return true }
                return false
            }, "runner (computer-use prompt): that row must be marked declined")
            let argv = (try? String(contentsOf: fakeRoot.appendingPathComponent("argv.log"), encoding: .utf8)) ?? ""
            for override in [
                "plugins.unified-computer-use@openai-bundled.enabled=false",
                "plugins.computer-use@openai-bundled.enabled=false",
                "plugins.browser@openai-bundled.enabled=false",
            ] {
                expect(argv.contains(override), "runner (computer-use prompt): spawned codex argv lacks \(override): \(argv)")
            }
            expect(argv.contains("mcp_servers.node_repl="), "runner (computer-use prompt): spawned codex argv must disable node_repl: \(argv)")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2b. Resume: `thread/resume` succeeds, and — the gap this ticket's own
    // probe found (app-server emits NO `thread/started` notification on a
    // resumed thread, unlike `codex exec resume`) — session-ready/running
    // events and the threadId observation must still fire, synthesized by the
    // runner rather than silently missing.
    do {
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read automatic-compaction observation
                .expectRequest(result: [:]),          // thread/resume (no thread/started notification — measured)
                .expectRequest(result: ["turn": ["id": "fixture-resume-turn"]]),  // turn/start
                .emit(method: "turn/completed",
                      params: ["threadId": "fixture-resume-thread",
                               "turn": ["id": "fixture-resume-turn", "status": "completed"]],
                      delayMs: 20),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        let observedThreadIds = ThreadIdCollector()
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: "fixture-resume-thread"))
            runner.observeRuntimeObservations { observation in
                if case .threadId(let id) = observation { observedThreadIds.append(id) }
            }
            let collector = EventCollector()
            try? runner.run(prompt: "hello again") { collector.append($0) }
            let events = collector.snapshot()
            expect(events.contains { if case .sessionStateChanged(.ready) = $0 { return true } else { return false } },
                   "runner (resume, app-server): a resumed turn must still synthesize session-ready — app-server sends no thread/started on resume")
            expect(observedThreadIds.snapshot().contains("fixture-resume-thread"),
                   "runner (resume, app-server): the resumed thread id must still reach onRuntimeObservation")
            expect(events.contains { if case .turnCompleted(_, "fixture-resume-turn", .completed, _) = $0 { return true } else { return false } },
                   "runner (resume, app-server): the resumed turn must still complete normally")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2c. Self-heal: `thread/resume` on an unknown thread id (measured
    // JSON-RPC shape: code -32600, "no rollout found for thread id …") must
    // fall back to a fresh `thread/start`, not surface the error to the
    // caller — mirroring exec's stderr-based self-heal, off a clean error
    // code instead.
    do {
        // TWO separate process spawns — the resume attempt and, after it fails,
        // the fresh attempt `runAppServer`'s self-heal launches. Each is its
        // own `codex` invocation with its own conversation (see the fake
        // script's doc comment).
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenarios: [
                [
                    .expectRequest(result: [:]),          // initialize (resume attempt)
                    .expectNotification,                  // initialized
                    .expectRequest(result: [:]),          // config/read automatic-compaction observation
                    .expectRequest(error: ["code": -32600, "message": "no rollout found for thread id stale-thread"]),  // thread/resume fails
                ],
                [
                    .expectRequest(result: [:]),          // initialize (fresh attempt)
                    .expectNotification,                  // initialized
                    .expectRequest(result: [:]),          // config/read automatic-compaction observation
                    .expectRequest(result: ["thread": ["id": "fixture-healed-thread"]]),  // thread/start
                    .expectRequest(result: ["turn": ["id": "fixture-healed-turn"]]),      // turn/start
                    .emit(method: "turn/completed",
                          params: ["threadId": "fixture-healed-thread",
                                   "turn": ["id": "fixture-healed-turn", "status": "completed"]],
                          delayMs: 20),
                ],
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        var caught: Error?
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: "stale-thread"))
            let collector = EventCollector()
            do {
                try runner.run(prompt: "hello") { collector.append($0) }
            } catch {
                caught = error
            }
            let events = collector.snapshot()
            expect(caught == nil, "runner (self-heal, app-server): an unknown-thread resume must self-heal, not throw; threw \(String(describing: caught))")
            expect(events.contains { if case .turnCompleted(_, "fixture-healed-turn", .completed, _) = $0 { return true } else { return false } },
                   "runner (self-heal, app-server): the healed fresh turn must still reach the caller")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2d. stop(): item 4's `turn/interrupt`, not just the group-wide SIGTERM.
    // The fake never sends `turn/completed` on its own — it only does so
    // after receiving a `turn/interrupt` REQUEST — so `run()` returning at
    // all (rather than hanging on the turn-completion semaphore forever)
    // proves the runner actually sent it over the live connection.
    do {
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read automatic-compaction observation
                .expectRequest(result: ["thread": ["id": "fixture-interrupt-thread"]]),  // thread/start
                .expectRequest(result: ["turn": ["id": "fixture-interrupt-turn"]]),      // turn/start
                .emit(method: "turn/started",
                      params: ["threadId": "fixture-interrupt-thread", "turn": ["id": "fixture-interrupt-turn"]]),
                .expectRequest(result: [:]),          // turn/interrupt — only reached if stop() sends it
                .emit(method: "turn/completed",
                      params: ["threadId": "fixture-interrupt-thread",
                               "turn": ["id": "fixture-interrupt-turn", "status": "interrupted"]],
                      delayMs: 10),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: nil))
            let collector = EventCollector()
            let startedSemaphore = DispatchSemaphore(value: 0)
            var caught: Error?
            let thread = Thread {
                do {
                    try runner.run(prompt: "hello") { event in
                        collector.append(event)
                        if case .turnStarted = event { startedSemaphore.signal() }
                    }
                } catch {
                    caught = error
                }
            }
            thread.start()
            guard startedSemaphore.wait(timeout: .now() + 10) == .success else {
                expect(false, "runner (stop, app-server): turn/started never arrived — stop() has nothing to interrupt")
                try? FileManager.default.removeItem(at: fakeRoot)
                return
            }
            // `appServerActiveTurn` is set on the runner's OWN thread right
            // after `turn/start`'s response, independently of the
            // `turn/started` NOTIFICATION my `startedSemaphore` above keys on
            // (a different thread, no ordering guarantee between the two) — a
            // brief settle avoids racing `stop()` ahead of that assignment so
            // this check exercises the real `turn/interrupt` send, not just
            // the SIGTERM backstop every path falls through to regardless.
            Thread.sleep(forTimeInterval: 0.05)
            runner.stop()
            let deadline = Date().addingTimeInterval(10)
            while thread.isExecuting, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            expect(!thread.isExecuting, "runner (stop, app-server): run() must return once turn/interrupt is honored, not hang")
            expect(caught is AgentRunStopped,
                   "runner (stop, app-server): a stop mid-turn must surface as AgentRunStopped; got \(String(describing: caught))")
            let progress = (try? String(contentsOf: fakeRoot.appendingPathComponent("progress.log"), encoding: .utf8)) ?? ""
            expect(progress.contains("turn/interrupt"),
                   "runner (stop, app-server): stop() must actually SEND turn/interrupt over the live connection, not just SIGTERM the process; fake saw: \(progress)")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2e. Delegation drain: the captured app-server ordering permits the
    // parent's turn/completed to arrive before a child's final transcript
    // frames. The production runner must keep the subprocess alive until the
    // announced child's own terminal event, while routing child events through
    // ProviderSubagentActivity rather than contaminating the parent stream.
    do {
        let parentThread = "fixture-parent-thread"
        let parentTurn = "fixture-parent-turn"
        let childThread = "fixture-child-thread"
        let childTurn = "fixture-child-turn"
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),
                .expectNotification,
                .expectRequest(result: [:]),          // config/read automatic-compaction observation
                .expectRequest(result: ["thread": ["id": parentThread]]),
                .expectRequest(result: ["turn": ["id": parentTurn]]),
                .emit(method: "turn/started",
                      params: ["threadId": parentThread, "turn": ["id": parentTurn]]),
                .emit(method: "item/started",
                      params: [
                        "threadId": parentThread,
                        "turnId": parentTurn,
                        "item": [
                            "id": "fixture-child-call",
                            "type": "subAgentActivity",
                            "kind": "started",
                            "agentPath": "/root/late_child",
                            "agentThreadId": childThread,
                        ],
                      ]),
                .emit(method: "turn/completed",
                      params: ["threadId": parentThread,
                               "turn": ["id": parentTurn, "status": "completed"]],
                      delayMs: 10),
                .emit(method: "item/agentMessage/delta",
                      params: ["threadId": childThread, "turnId": childTurn, "delta": "late child result"],
                      delayMs: 150),
                .emit(method: "turn/completed",
                      params: ["threadId": childThread,
                               "turn": ["id": childTurn, "status": "completed"]],
                      delayMs: 10),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: nil))
            let parentEvents = EventCollector()
            let activities = ProviderActivityCollector()
            runner.observeProviderSubagentActivity { activities.append($0) }
            var caught: Error?
            do {
                try runner.run(prompt: "delegate once") { parentEvents.append($0) }
            } catch {
                caught = error
            }

            let providerActivities = activities.snapshot()
            expect(caught == nil,
                   "runner (delegation drain): a clean parent + late child must not throw; got \(String(describing: caught))")
            expect(providerActivities.contains {
                if case .childAnnounced(parentThread, childThread, "fixture-child-call", "late child") = $0 { return true }
                return false
            }, "runner (delegation drain): the structured child announcement must preserve parent, child, item, and label identity")
            expect(providerActivities.contains {
                if case .threadEvent(childThread, .contentDelta(_, _, _, "late child result")) = $0 { return true }
                return false
            }, "runner (delegation drain): the child delta emitted after parent completion must survive teardown and route to the child")
            expect(providerActivities.contains {
                if case .threadEvent(childThread, .turnCompleted(_, childTurn, .completed, _)) = $0 { return true }
                return false
            }, "runner (delegation drain): run() must not return until the child's own terminal event is routed")
            expect(!parentEvents.snapshot().contains {
                if case .contentDelta(let threadId, _, _, "late child result") = $0 { return threadId == childThread }
                return false
            }, "runner (delegation drain): a child frame must never leak into the parent transcript stream")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2g. Stop is for the whole family (`.plans/87` Step 3.4). A child thread
    // with a turn open is interrupted with its parent, and a child the process
    // took down with it is settled as interrupted, never left working.
    do {
        let parentThread = "fixture-stop-parent-thread"
        let childThread = "fixture-stop-child-thread"
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),
                .expectNotification,
                .expectRequest(result: [:]),
                .expectRequest(result: ["thread": ["id": parentThread]]),
                .expectRequest(result: ["turn": ["id": "fixture-stop-parent-turn"]]),
                .emit(method: "turn/started",
                      params: ["threadId": parentThread, "turn": ["id": "fixture-stop-parent-turn"]]),
                .emit(method: "item/started",
                      params: [
                        "threadId": parentThread, "turnId": "fixture-stop-parent-turn",
                        "item": ["id": "fixture-stop-call", "type": "subAgentActivity", "kind": "started",
                                 "agentPath": "/root/stopped_child", "agentThreadId": childThread],
                      ]),
                .emit(method: "turn/started",
                      params: ["threadId": childThread, "turn": ["id": "fixture-stop-child-turn"]]),
                .expectRequest(result: [:]),          // turn/interrupt
                .expectRequest(result: [:]),          // turn/interrupt
                .emit(method: "turn/completed",
                      params: ["threadId": parentThread,
                               "turn": ["id": "fixture-stop-parent-turn", "status": "interrupted"]],
                      delayMs: 10),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-5.6-sol", cwd: cwd, threadId: nil))
            let activities = ProviderActivityCollector()
            runner.observeProviderSubagentActivity { activities.append($0) }
            let thread = Thread { try? runner.run(prompt: "delegate then stop") { _ in } }
            thread.start()
            let started = Date().addingTimeInterval(10)
            while Date() < started, !activities.snapshot().contains(where: {
                if case .threadEvent(childThread, .turnStarted) = $0 { return true }; return false
            }) { Thread.sleep(forTimeInterval: 0.02) }
            Thread.sleep(forTimeInterval: 0.05)
            runner.stop()
            let deadline = Date().addingTimeInterval(10)
            while thread.isExecuting, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            expect(!thread.isExecuting, "runner (family stop): run() must return after Stop")
            let progress = (try? String(contentsOf: fakeRoot.appendingPathComponent("progress.log"), encoding: .utf8)) ?? ""
            expect(progress.contains("turn/interrupt \(childThread)"),
                   "runner (family stop): Stop interrupted only the parent; the open child thread was never sent turn/interrupt. fake saw: \(progress)")
            expect(activities.snapshot().contains {
                if case .threadEvent(childThread, .turnCompleted(_, _, .interrupted, _)) = $0 { return true }
                return false
            }, "runner (family stop): a child the session ended under must be settled interrupted, not left working")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2f. Manual compaction settles (2026-10-13, preview app: a Codex tile sat
    // "Working · Thinking" forever after /compact). The frames below are the
    // REAL codex-cli 0.159.3 app-server sequence for `thread/compact/start`,
    // captured verbatim (minus `emittedAtMs`, which the fake does not carry):
    // app-server runs the compaction as its own TURN — `turn/started`, the
    // `contextCompaction` item, `turn/completed` two milliseconds later. The
    // runner used to forward that `turn/started`, then return on the item's
    // completion and shut the transport, dropping the `turn/completed` still
    // in the pipe — so the supervisor's presence armed a turn nothing ever
    // closed. Claude's `compact()` forwards only the compaction lifecycle, its
    // items and meter readings; Codex must match it. The witness replays what
    // `compact()` forwarded through the same presence reducer the tile reads.
    // Also complete AFTER the former 120s deadline: elapsed time alone must
    // neither fail the operation nor kill the provider before its boundary.
    for completionDelayMs in [100, 121_000] {
        print("Codex compaction: waiting for provider boundary (\(completionDelayMs)ms fixture)")
        let thread = "01a13824-f3a1-7281-adf7-2982d6882465"
        let turn = "01a13825-12be-7782-9fce-96d10cb8ba2f"
        let item = "01a13825-12d5-7fd0-89d6-b3e61266c758"
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read automatic-compaction observation
                .expectRequest(result: [:]),          // thread/resume
                .expectRequest(result: [:]),          // thread/compact/start -> {} (measured)
                .emit(method: "thread/status/changed",
                      params: ["threadId": thread, "status": ["type": "active", "activeFlags": [String]()]]),
                .emit(method: "turn/started",
                      params: ["threadId": thread,
                               "turn": ["id": turn, "items": [Any](), "itemsView": "notLoaded",
                                        "status": "inProgress", "error": NSNull(),
                                        "startedAt": 1791943316, "completedAt": NSNull(), "durationMs": NSNull()]]),
                .emit(method: "item/started",
                      params: ["item": ["type": "contextCompaction", "id": item],
                               "threadId": thread, "turnId": turn, "startedAtMs": 1791943316181]),
                .emit(method: "thread/tokenUsage/updated",
                      params: ["threadId": thread, "turnId": turn,
                               "tokenUsage": [
                                "total": ["totalTokens": 16155, "inputTokens": 16150, "cachedInputTokens": 13184,
                                          "cacheWriteInputTokens": 0, "outputTokens": 5, "reasoningOutputTokens": 0],
                                "last": ["totalTokens": 6072, "inputTokens": 0, "cachedInputTokens": 0,
                                         "cacheWriteInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0],
                                "modelContextWindow": 475000]],
                      delayMs: completionDelayMs),
                .emit(method: "item/completed",
                      params: ["item": ["type": "contextCompaction", "id": item],
                               "threadId": thread, "turnId": turn, "completedAtMs": 1791943325128]),
                .emit(method: "thread/status/changed",
                      params: ["threadId": thread, "status": ["type": "idle"]],
                      delayMs: 2),
                .emit(method: "turn/completed",
                      params: ["threadId": thread,
                               "turn": ["id": turn, "items": [Any](), "itemsView": "notLoaded",
                                        "status": "completed", "error": NSNull(),
                                        "startedAt": 1791943316, "completedAt": 1791943325, "durationMs": 8956]]),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-6.1-sol", cwd: cwd, threadId: thread))
            let collector = EventCollector()
            let operationID = UUID()
            var caught: Error?
            do {
                try runner.compact(AgentCompactionRequest(operationID: operationID)) { collector.append($0) }
            } catch {
                caught = error
            }
            let events = collector.snapshot()
            var presence = AgentTurnPresence()
            for event in events { presence.reduce(event, at: Date()) }

            expect(caught == nil,
                   "runner (compact, app-server): the real 0.159.3 compaction sequence must not throw; got \(String(describing: caught))")
            expect(events.contains {
                if case .compactionChanged(_, let lifecycle) = $0 {
                    return lifecycle.phase == .succeeded && lifecycle.boundaryID == item
                        && lifecycle.operationID == operationID
                }
                return false
            }, "runner (compact, app-server): the contextCompaction item's completion must settle the operation .succeeded")
            expect(!presence.isLive,
                   "runner (compact, app-server): presence fed what compact() forwarded must not be left live; phase \(presence.phase)")
            expect(!events.contains {
                switch $0 {
                case .turnStarted, .turnCompleted: return true
                default: return false
                }
            }, "runner (compact, app-server): app-server's compaction turn must not leak as a user turn — Claude's compact() forwards no turn boundary either")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2g. A compaction turn that FAILS before its item completes must end the
    // operation at once. The failed `turn/completed` shape is the measured one
    // `CodexAppServerParityChecks` pins (`turn.status == "failed"`, `turn.error`
    // inline); the run used to wait out the 120s compaction timeout instead.
    do {
        let thread = "fixture-compact-fail-thread"
        let turn = "fixture-compact-fail-turn"
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(result: [:]),          // initialize
                .expectNotification,                  // initialized
                .expectRequest(result: [:]),          // config/read
                .expectRequest(result: [:]),          // thread/resume
                .expectRequest(result: [:]),          // thread/compact/start
                .emit(method: "turn/started",
                      params: ["threadId": thread, "turn": ["id": turn, "status": "inProgress"]]),
                .emit(method: "item/started",
                      params: ["item": ["type": "contextCompaction", "id": "fixture-compact-fail-item"],
                               "threadId": thread, "turnId": turn]),
                .emit(method: "turn/completed",
                      params: ["threadId": thread,
                               "turn": ["id": turn, "status": "failed",
                                        "error": ["code": "usage_limit_exceeded",
                                                  "message": "You've hit your usage limit."]]],
                      delayMs: 20),
            ],
            asExecutableNamed: "codex")
        let fakeDir = script.deletingLastPathComponent()

        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(fakeDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-6.1-sol", cwd: cwd, threadId: thread))
            let collector = EventCollector()
            let started = Date()
            var caught: Error?
            do {
                try runner.compact(AgentCompactionRequest()) { collector.append($0) }
            } catch {
                caught = error
            }
            let elapsed = Date().timeIntervalSince(started)
            var presence = AgentTurnPresence()
            for event in collector.snapshot() { presence.reduce(event, at: Date()) }
            expect(caught != nil && elapsed < 10,
                   "runner (compact failed, app-server): a failed compaction turn must end compact() promptly with an error; threw \(String(describing: caught)) after \(elapsed)s")
            expect(String(describing: caught!).contains("usage limit"),
                   "runner (compact failed, app-server): the provider's failure text must reach the error; got \(String(describing: caught!))")
            expect(!presence.isLive,
                   "runner (compact failed, app-server): a failed compaction must not leave presence live; phase \(presence.phase)")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2h. Draining diagnostics is part of making an unbounded provider wait
    // safe. More than a pipe's capacity must not prevent the terminal frame.
    do {
        let thread = "fixture-compact-stderr-thread"
        let (script, fakeRoot) = try! makeFakeAppServer(
            scenario: [
                .expectRequest(), .expectNotification, .expectRequest(),
                .expectRequest(), .expectRequest(),
                .stderr(byteCount: 262_144),
                .emit(method: "item/completed", params: [
                    "threadId": thread, "turnId": "fixture-compact-stderr-turn",
                    "item": ["type": "contextCompaction", "id": "fixture-compact-stderr-item"],
                ]),
                .hang, // completion must release the caller while the CLI is alive
            ], asExecutableNamed: "codex")
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(script.deletingLastPathComponent().path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-6.1-sol", cwd: cwd, threadId: thread))
            let events = EventCollector()
            let started = Date()
            var caught: Error?
            do { try runner.compact(AgentCompactionRequest()) { events.append($0) } }
            catch { caught = error }
            expect(caught == nil && Date().timeIntervalSince(started) < 10,
                   "runner (compact stderr): diagnostics must drain so the provider can complete; got \(String(describing: caught))")
            expect(events.snapshot().contains {
                if case .compactionChanged(_, let lifecycle) = $0 { return lifecycle.phase == .succeeded }
                return false
            }, "runner (compact stderr): the provider's success must reach the caller")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }

    // 2i. Both Stop and an unexpected exit must release the provider wait
    // without inventing a successful compaction boundary.
    for stop in [false, true] {
        let thread = "fixture-compact-exit-thread"
        var scenario: [FakeAppServerStep] = [
            .expectRequest(), .expectNotification, .expectRequest(),
            .expectRequest(), .expectRequest(),
            .emit(method: "item/started", params: [
                "threadId": thread, "turnId": "fixture-compact-exit-turn",
                "item": ["type": "contextCompaction", "id": "fixture-compact-exit-item"],
            ]),
        ]
        if stop { scenario.append(.hang) }
        let (script, fakeRoot) = try! makeFakeAppServer(scenario: scenario, asExecutableNamed: "codex")
        withEnvironmentOverride([
            "CONTINUUM_CODEX_TRANSPORT": "app-server",
            "PATH": "\(script.deletingLastPathComponent().path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        ]) {
            let runner = CodexAgentRunner(config: .init(model: "gpt-6.1-sol", cwd: cwd, threadId: thread))
            let events = EventCollector()
            let running = DispatchSemaphore(value: 0)
            let stopped = DispatchSemaphore(value: 0)
            if stop {
                Thread {
                    _ = running.wait(timeout: .now() + 10)
                    runner.stop()
                    stopped.signal()
                }.start()
            }
            let started = Date()
            var caught: Error?
            do {
                try runner.compact(AgentCompactionRequest()) { event in
                    events.append(event)
                    if case .compactionChanged(_, let lifecycle) = event, lifecycle.phase == .running {
                        running.signal()
                    }
                }
            } catch { caught = error }
            if stop {
                expect(stopped.wait(timeout: .now() + 5) == .success,
                       "runner (compact stop): Stop must finish")
            }
            expect(caught != nil && Date().timeIntervalSince(started) < 10,
                   "runner (compact exit): Stop or process exit must release compact() promptly; got \(String(describing: caught))")
            expect((caught is AgentRunStopped) == stop,
                   "runner (compact exit): only a user Stop should report cancellation")
            expect(!events.snapshot().contains {
                if case .compactionChanged(_, let lifecycle) = $0 { return lifecycle.phase == .succeeded }
                return false
            }, "runner (compact exit): losing the process must not invent success")
        }
        try? FileManager.default.removeItem(at: fakeRoot)
    }
}
