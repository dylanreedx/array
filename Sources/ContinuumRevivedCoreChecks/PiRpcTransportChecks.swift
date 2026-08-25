import ContinuumRevivedCore
import Foundation

// Ticket: M2 pi rpc transport (`.plans/46`). Drives the PRODUCTION
// `PiRpcTransport` and `PiRpcAgentRunner` against a SCRIPTED fake `pi --mode
// rpc` -- a small python3 process that plays back a JSON "scenario": for each
// incoming `{id, type, ...}` command line, an optional sequence of frames to
// emit BEFORE its correlated response, the response itself, and an optional
// sequence to emit AFTER. No real `pi` binary, no network, no auth, in the
// same spirit as `CodexAppServerRunnerChecks`'s fake app-server and
// `ProcessGroupChildChecks`'s `/bin/sh -c "…"` doubles. python3 is already a
// checks dependency (`main.swift`, `CodexAppServerRunnerChecks.swift`).
//
// Ground truth this pins (measured, not re-derived — see the ledger's pi rpc
// probe): commands are newline-delimited JSON `{id?, type}`; replies are
// `{id?, type:"response", command, success, data?}`; `abort` is awaited and
// leaves the connection healthy for the next `prompt`; the event stream is
// otherwise the SAME shape one-shot `--mode json` produces.
func runPiRpcTransportChecks() {
    runPiRpcTransportCorrelationChecks()
    runPiRpcAgentRunnerChecks()
    runPiEventTranslatorRpcFrameChecks()
    print("PiRpcTransport/PiRpcAgentRunner checks passed: request/response correlation survives interleaving, one process serves many turns, abort keeps the connection alive for the next prompt, steer resolves without ending the turn it landed in, a malformed/unknown frame is dropped not fatal, and the two rpc-only frame types translate to zero events")
}

/// A lock-protected mutable box, for state a `@Sendable` event callback
/// writes to from off the calling thread. Same convention as the other
/// checks files' `*Box` types (e.g. `AuthChecks.LockedValueResult`).
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - fake `pi --mode rpc`

/// python3 source for the fake. Reads its scenario from argv[1] (a JSON
/// object: `{"handlers": {<type>: <behavior>}, "default": <behavior>}`) and
/// then loops reading commands from stdin until EOF, handling each according
/// to its `type` — the loop, not a one-shot reply, is the point: ONE process
/// must serve MANY commands, which is the entire premise of M2 over
/// `PiAgentRunner`'s process-per-turn.
///
/// A `behavior` is `{"pre_events": [...], "no_response": bool,
/// "success": bool, "data": {...}, "error": {...}, "events": [...],
/// "exit_no_response": bool, "exit_after": bool, "exit_code": int}`. Each
/// entry in `pre_events`/`events` is either a JSON object emitted as an event
/// line, or `{"raw": "<literal text>"}` emitted byte-for-byte (used to inject
/// malformed / garbage lines without python re-encoding them into something
/// valid). `delay_ms` on any entry sleeps before emitting it, to force real
/// interleaving with a caller waiting on a DIFFERENT in-flight request.
private let fakePiRpcPythonSource = #"""
import json, os, sys, time

scenario_path = sys.argv[1]
scenario_dir = os.path.dirname(os.path.abspath(scenario_path))

spawn_count_path = os.path.join(scenario_dir, "spawn.count")
try:
    with open(spawn_count_path) as f:
        n = int(f.read().strip() or "0")
except FileNotFoundError:
    n = 0
with open(spawn_count_path, "w") as f:
    f.write(str(n + 1))

with open(scenario_path) as f:
    scenario = json.load(f)

handlers = scenario.get("handlers", {})
default_handler = scenario.get("default", {"events": []})

log_path = os.path.join(scenario_dir, "received.log")


def log(cmd_type):
    with open(log_path, "a") as f:
        f.write(str(cmd_type) + "\n")


import threading

emit_lock = threading.Lock()


def emit_locked(entry):
    time.sleep(entry.get("delay_ms", 0) / 1000.0)
    with emit_lock:
        if "raw" in entry:
            sys.stdout.write(entry["raw"] + "\n")
        else:
            sys.stdout.write(json.dumps(entry) + "\n")
        sys.stdout.flush()


def handle(obj):
    cmd_type = obj.get("type")
    cmd_id = obj.get("id")
    log(cmd_type)
    handler = handlers.get(cmd_type, default_handler)

    if handler.get("exit_no_response"):
        os._exit(handler.get("exit_code", 1))

    for entry in handler.get("pre_events", []):
        emit_locked(entry)

    if not handler.get("no_response"):
        time.sleep(handler.get("delay_ms", 0) / 1000.0)
        response = {
            "type": "response",
            "id": cmd_id,
            "command": cmd_type,
            "success": handler.get("success", True),
        }
        if "data" in handler:
            response["data"] = handler["data"]
        if not handler.get("success", True) and "error" in handler:
            response["error"] = handler["error"]
        emit_locked(response)

    for entry in handler.get("events", []):
        emit_locked(entry)

    if handler.get("exit_after"):
        os._exit(handler.get("exit_code", 0))


# A REAL rpc session keeps reading and answering OTHER commands (get_state,
# steer, abort, ...) while a long-running `prompt` is still generating -- it
# is one connection serving concurrent, independent request lifecycles, not a
# strict request/reply ping-pong. Each incoming line is therefore handled on
# its OWN thread so one handler's `delay_ms`/`events` sleep never blocks the
# fake from reading (and answering) the next line, mirroring that concurrency
# instead of accidentally serializing it away.
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

private func makeFakePiRpc(scenario: [String: Any]) throws -> (script: URL, scenarioFile: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-pi-rpc-fake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scenarioURL = root.appendingPathComponent("scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioURL)
    let scriptURL = root.appendingPathComponent("fake_pi_rpc.py")
    try fakePiRpcPythonSource.write(to: scriptURL, atomically: true, encoding: .utf8)
    return (scriptURL, scenarioURL, root)
}

/// Same fixture, but written as a directly-executable `pi` on disk (shebang +
/// chmod +x) so `PiRpcAgentRunner` -- which resolves `pi` off PATH exactly as
/// production does, with no constructor injection seam (matching the other
/// two runners' convention) -- finds and runs it as the real binary would be
/// found under a GUI-thin PATH.
private func makeFakePiRpcExecutable(scenario: [String: Any]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-pi-rpc-exe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scenarioURL = root.appendingPathComponent("scenario.json")
    try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioURL)
    let executableURL = root.appendingPathComponent("pi")
    let wrapper = "#!/usr/bin/env python3\n" + fakePiRpcPythonSource.replacingOccurrences(
        of: "sys.argv[1]", with: "\"\(scenarioURL.path)\"")
    try wrapper.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return root
}

private func spawnCount(root: URL) -> Int {
    let path = root.appendingPathComponent("spawn.count").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

private func receivedLog(root: URL) -> [String] {
    let path = root.appendingPathComponent("received.log").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

// MARK: - 1. PiRpcTransport, driven directly: correlation survives interleaving

private func runPiRpcTransportCorrelationChecks() {
    // Two commands whose responses are DELAYED and interleaved with unrelated
    // event lines, fired near-simultaneously from two threads. Each caller
    // must receive its OWN correlated result, never the other's — the
    // request/response correlation witness the ledger calls out by name.
    let scenario: [String: Any] = [
        "handlers": [
            "get_state": [
                "pre_events": [["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "x"]]],
                "data": ["sessionId": "state-reply"],
                "delay_ms": 60,
            ],
            "get_session_stats": [
                "pre_events": [["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "y"]]],
                "data": ["sessionId": "stats-reply"],
                "delay_ms": 20,
            ],
        ],
        "default": ["events": []],
    ]
    guard let (script, scenarioFile, root) = try? makeFakePiRpc(scenario: scenario) else {
        expect(false, "pi-rpc transport: failed to write fake pi rpc fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let transport = PiRpcTransport()
    let eventLines = Box<[String]>([])
    transport.onEvent = { line in eventLines.value.append(line) }
    do {
        try transport.start(
            executable: "/usr/bin/env",
            arguments: ["python3", script.path, scenarioFile.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil)
    } catch {
        expect(false, "pi-rpc transport: fake pi failed to launch: \(error)")
        return
    }

    let stateResult = Box<[String: Any]?>(nil)
    let statsResult = Box<[String: Any]?>(nil)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        stateResult.value = try? transport.sendAndAwait(type: "get_state", timeout: 5)
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        statsResult.value = try? transport.sendAndAwait(type: "get_session_stats", timeout: 5)
        group.leave()
    }
    group.wait()

    expect((stateResult.value?["data"] as? [String: Any])?["sessionId"] as? String == "state-reply",
           "pi-rpc transport: get_state must correlate to its OWN response despite interleaving")
    expect((statsResult.value?["data"] as? [String: Any])?["sessionId"] as? String == "stats-reply",
           "pi-rpc transport: get_session_stats must correlate to its OWN response despite interleaving")
    let deltas: [String] = eventLines.value.compactMap { line in
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assistantEvent = object["assistantMessageEvent"] as? [String: Any]
        else { return nil }
        return assistantEvent["delta"] as? String
    }
    expect(deltas.contains("x") && deltas.contains("y"),
           "pi-rpc transport: event lines interleaved between the two responses must still reach onEvent (got deltas \(deltas))")

    transport.stop()
}

// MARK: - 2. PiRpcAgentRunner, driven end to end

private func runPiRpcAgentRunnerChecks() {
    checkOneProcessServesManyTurns()
    checkAbortKeepsConnectionAlive()
    checkSteerDoesNotEndTheTurn()
    checkMalformedFrameIsDroppedNotFatal()
}

/// The runner resolves `pi` itself via `PiAgentRunner.liveResolvedCommand()`,
/// which searches PATH -- so `root` (produced by `makeFakePiRpcExecutable`,
/// which puts a real executable `pi` there) is prepended to PATH, matching
/// how the runner is actually invoked in production (never a constructor
/// injection point, by design: same convention as the other two runners).
/// Callers restore PATH via `restorePath` when done.
private func makeRunner(root: URL) -> (runner: PiRpcAgentRunner, restorePath: () -> Void) {
    let config = PiRpcAgentRunner.Config(
        model: "fixture-model",
        thinking: "low",
        cwd: root,
        sessionId: "fixture-session")
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(root.path):\(originalPath)", 1)
    let restore: () -> Void = { _ = setenv("PATH", originalPath, 1) }
    return (PiRpcAgentRunner(config: config), restore)
}

/// A minimal one-turn scenario: `prompt` acks, then streams `turn_start` /
/// `turn_end` so `run()` has a real completion signal to wait on.
private func oneTurnScenario() -> [String: Any] {
    [
        "handlers": [
            "prompt": [
                "events": [["type": "turn_start"], ["type": "turn_end"]],
            ],
        ],
        "default": ["events": []],
    ]
}

private func checkOneProcessServesManyTurns() {
    guard let root = try? makeFakePiRpcExecutable(scenario: oneTurnScenario()) else {
        expect(false, "pi-rpc runner: failed to write fake pi rpc fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeRunner(root: root)
    defer { restorePath() }

    let turnsCompleted = Box(0)
    for _ in 0..<3 {
        do {
            try runner.run(prompt: AgentPrompt("hello")) { event in
                if case .turnCompleted = event { turnsCompleted.value += 1 }
            }
        } catch {
            expect(false, "pi-rpc runner: run() must not throw on a scripted success turn: \(error)")
        }
    }
    runner.stop()

    expect(turnsCompleted.value == 3, "pi-rpc runner: 3 prompts must each report turnCompleted; got \(turnsCompleted.value)")
    expect(spawnCount(root: root) == 1,
           "pi-rpc runner: ONE process must serve all 3 turns; the fake was spawned \(spawnCount(root: root)) time(s)")
}

private func checkAbortKeepsConnectionAlive() {
    var scenario = oneTurnScenario()
    var handlers = scenario["handlers"] as! [String: Any]
    handlers["abort"] = ["success": true]
    scenario["handlers"] = handlers

    guard let root = try? makeFakePiRpcExecutable(scenario: scenario) else {
        expect(false, "pi-rpc runner: failed to write fake pi rpc fixture (abort)")
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeRunner(root: root)
    defer { restorePath() }

    // A first turn to actually start the process, then an out-of-band abort.
    try? runner.run(prompt: AgentPrompt("hello")) { _ in }
    do {
        try runner.interrupt()
    } catch {
        expect(false, "pi-rpc runner: interrupt() (abort) must succeed on a healthy connection: \(error)")
    }

    // The SAME connection must still accept the next prompt afterward.
    let secondTurnCompleted = Box(false)
    do {
        try runner.run(prompt: AgentPrompt("again")) { event in
            if case .turnCompleted = event { secondTurnCompleted.value = true }
        }
    } catch {
        expect(false, "pi-rpc runner: a prompt AFTER abort must still run on the same connection: \(error)")
    }
    runner.stop()

    expect(secondTurnCompleted.value, "pi-rpc runner: the turn after abort must complete")
    expect(spawnCount(root: root) == 1, "pi-rpc runner: abort must not respawn the process")
    expect(receivedLog(root: root).contains("abort"), "pi-rpc runner: the fake must have actually received an abort command")
}

/// `steer` must be a plain correlated command on the SAME connection while a
/// turn is in flight -- it must NOT resolve or otherwise end that turn. Only
/// the turn's own `turn_end` may do that. This is the honest boundary of what
/// Array's transport can witness: pi's own turn-boundary delivery timing
/// (`agent-session.js:986`) is out of scope here (see the ledger), but "the
/// client-side steer call does not itself terminate/interrupt the run" is
/// squarely Array's to prove.
private func checkSteerDoesNotEndTheTurn() {
    // `turn_end` is held back 150ms (via its own `delay_ms`) so the steer call
    // below has time to land, get answered, and be observed as complete
    // BEFORE the turn itself completes.
    let scenario: [String: Any] = [
        "handlers": [
            "prompt": [
                "pre_events": [["type": "turn_start"]],
                "events": [["type": "turn_end", "delay_ms": 150]],
            ],
            "steer": ["success": true],
        ],
        "default": ["events": []],
    ]

    guard let root = try? makeFakePiRpcExecutable(scenario: scenario) else {
        expect(false, "pi-rpc runner: failed to write fake pi rpc fixture (steer)")
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeRunner(root: root)
    defer { restorePath() }

    let turnCompletedAt = Box<Date?>(nil)
    let runDone = DispatchSemaphore(value: 0)
    let runError = Box<Error?>(nil)
    DispatchQueue.global().async {
        do {
            try runner.run(prompt: AgentPrompt("long task")) { event in
                if case .turnCompleted = event { turnCompletedAt.value = Date() }
            }
        } catch {
            runError.value = error
        }
        runDone.signal()
    }

    // Give the prompt time to start before steering into it.
    Thread.sleep(forTimeInterval: 0.05)
    var steerCompletedAt: Date?
    do {
        try runner.steer("adjust course")
        steerCompletedAt = Date()
    } catch {
        expect(false, "pi-rpc runner: steer() must succeed mid-turn: \(error)")
    }

    _ = runDone.wait(timeout: .now() + 5)
    runner.stop()

    expect(runError.value == nil, "pi-rpc runner: the turn steer landed in must still complete cleanly: \(String(describing: runError.value))")
    if let steerCompletedAt, let completedAt = turnCompletedAt.value {
        expect(steerCompletedAt < completedAt,
               "pi-rpc runner: steer's own response must resolve BEFORE the turn it was sent into completes -- steer must not itself end the turn")
    } else {
        expect(false, "pi-rpc runner: both steer and the turn must have observably completed")
    }
}

/// A malformed line (invalid JSON) and a well-formed-but-unknown event type
/// must not crash the transport or wedge the turn; the turn must still reach
/// `turnCompleted` normally.
private func checkMalformedFrameIsDroppedNotFatal() {
    let scenario: [String: Any] = [
        "handlers": [
            "prompt": [
                "pre_events": [["type": "turn_start"]],
                "events": [
                    ["raw": "not json at all {{{"],
                    ["type": "some_future_frame_type", "whatever": true],
                    ["type": "turn_end"],
                ],
            ],
        ],
        "default": ["events": []],
    ]
    guard let root = try? makeFakePiRpcExecutable(scenario: scenario) else {
        expect(false, "pi-rpc runner: failed to write fake pi rpc fixture (malformed)")
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let (runner, restorePath) = makeRunner(root: root)
    defer { restorePath() }

    let completed = Box(false)
    do {
        try runner.run(prompt: AgentPrompt("hello")) { event in
            if case .turnCompleted = event { completed.value = true }
        }
    } catch {
        expect(false, "pi-rpc runner: a malformed/unknown frame must be dropped, not fatal: \(error)")
    }
    runner.stop()
    expect(completed.value, "pi-rpc runner: turnCompleted must still arrive after a malformed line")
}

// MARK: - 3. PiEventTranslator: the two rpc-only frame types are ignored

private func runPiEventTranslatorRpcFrameChecks() {
    var translator = PiEventTranslator()
    let responseEvents = translator.translate(line: #"{"type":"response","id":"rpc-1","command":"get_state","success":true,"data":{}}"#)
    expect(responseEvents.isEmpty, "pi translator: a rpc 'response' frame must translate to zero events")

    let uiRequestEvents = translator.translate(line: #"{"type":"extension_ui_request","id":"ui-1"}"#)
    expect(uiRequestEvents.isEmpty, "pi translator: 'extension_ui_request' must translate to zero events")
}
