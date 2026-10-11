import Foundation

// T5 (`.plans/69`) — reactive stand-ins for `claude`, `codex app-server` and
// `pi --mode rpc`, for CHECKS ONLY. Each is a small python3 program installed as
// an executable named after the CLI, so a check that prepends its directory to
// PATH drives the PRODUCTION runner exactly as `liveResolvedCommand()` finds the
// real binary. Unlike the scripted fakes beside the older runner checks, these
// react: a steer or an interrupt that arrives mid-turn changes what the fake
// emits next, which is the behaviour the steering witnesses exist to watch.
//
// Every fake records what production sent it, next to itself:
//   argv.json        the argument vector of the latest spawn
//   spawn.count      how many processes were started
//   stdin.jsonl      every stdin line, verbatim, in arrival order
//   pid.txt          the pid of the latest spawn
//
// The prompt text picks the turn's shape (shared by all three):
//   TOOL        a tool call that waits ~1.5 s for a steer before finishing
//   SLOW        a tool call that waits up to 10 s, for an interrupt
//   HOLD        (claude, codex) a tool call that runs up to 10 s and takes no
//               steer until it finishes, so an interrupt finds a steer the
//               provider holds but has not consumed (live claude 2.1.291
//               lists it under `still_queued` and runs it as its next turn
//               unless the interrupt asks `cancel_queued`)
//   BACKGROUND  (claude) starts a `sleep` job in the process group, writes its
//               pid to bg.pid and reports one background task
//   PLAIN       0.6 s of text generation with no tool boundary
//   LONG        up to 10 s of text generation with no tool boundary, for an
//               interrupt — a steer sent meanwhile stays held by Array
//   CRASH       exits 3 mid-turn without a result
//   DELAYSTART  (combines with any shape) holds ~1.2 s before the provider's
//               own turn-start signal, after its session-ready signal, so a
//               check can sample the spawn window production really crosses
//               (codex: thread/started before turn/started; pi: the session
//               header before agent_start; claude: before system/init)
//   anything else: a short text reply
// `reject-resume` beside the fake makes claude fail `--resume` the way the real
// CLI does for a conversation that does not exist yet.
public enum AgentSteeringQAFakes {
    public enum Harness: String, Sendable {
        case claude
        case codex
        case pi
    }

    /// Writes the fake for `harness` into `directory` (created if needed) as an
    /// executable named `claude`, `codex` or `pi`.
    @discardableResult
    public static func install(_ harness: Harness, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(harness.rawValue)
        let body: String
        switch harness {
        case .claude: body = claudeSource
        case .codex: body = codexSource
        case .pi: body = piSource
        }
        try ("#!/usr/bin/env python3\n" + sharedPrelude + body)
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// Every stdin line the fake has received, parsed.
    public static func receivedFrames(in directory: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("stdin.jsonl"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    public static func spawnCount(in directory: URL) -> Int {
        let text = try? String(contentsOf: directory.appendingPathComponent("spawn.count"), encoding: .utf8)
        return Int(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    public static func argv(in directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("argv.json")),
              let argv = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return argv
    }

    /// The pid of the most recently spawned fake process.
    public static func latestPid(in directory: URL) -> pid_t? {
        let text = try? String(contentsOf: directory.appendingPathComponent("pid.txt"), encoding: .utf8)
        return pid_t(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// The pid the claude fake's BACKGROUND turn started, if any.
    public static func backgroundPid(in directory: URL) -> pid_t? {
        let text = try? String(contentsOf: directory.appendingPathComponent("bg.pid"), encoding: .utf8)
        return pid_t(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static let sharedPrelude = #"""
import json, os, sys, threading, time, subprocess, queue

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "argv.json"), "w") as f:
    json.dump(sys.argv[1:], f)
_count_path = os.path.join(HERE, "spawn.count")
try:
    with open(_count_path) as f:
        _n = int(f.read().strip() or "0")
except FileNotFoundError:
    _n = 0
with open(_count_path, "w") as f:
    f.write(str(_n + 1))
with open(os.path.join(HERE, "pid.txt"), "w") as f:
    f.write(str(os.getpid()))

_out_lock = threading.Lock()
def out(obj):
    with _out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

def record(line):
    with open(os.path.join(HERE, "stdin.jsonl"), "a") as f:
        f.write(line.rstrip("\n") + "\n")

def delay_start(text):
    if "DELAYSTART" in text:
        time.sleep(1.2)

def shape(text):
    for word in ("TOOL", "SLOW", "HOLD", "BACKGROUND", "PLAIN", "CRASH", "LONG"):
        if word in text:
            return word
    return "TEXT"

"""#

    private static let claudeSource = #"""
SID = "00000000-0000-4000-8000-00000000c1a0"
for i, a in enumerate(sys.argv):
    if a in ("--session-id", "--resume") and i + 1 < len(sys.argv):
        SID = sys.argv[i + 1]
if "--resume" in sys.argv and os.path.exists(os.path.join(HERE, "reject-resume")):
    sys.stderr.write("No conversation found with session ID: %s\n" % SID)
    sys.stderr.flush()
    sys.exit(1)

inbox = queue.Queue()
interrupted = threading.Event()

def text_of(msg):
    content = msg.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if b.get("type") == "text")

def reader():
    for line in sys.stdin:
        if not line.strip():
            continue
        record(line)
        obj = json.loads(line)
        if obj.get("type") == "control_request":
            request = obj.get("request", {})
            receipt = {"still_queued": []}
            if request.get("subtype") == "interrupt":
                # The live receipt: uuid-stamped messages claude holds and has
                # not consumed survive the interrupt (and later run as their own
                # turn) unless cancel_queued asks for them to be cancelled.
                held = []
                while True:
                    try:
                        held.append(inbox.get_nowait())
                    except queue.Empty:
                        break
                stamped = [m.get("uuid") for m in held if m is not None and m.get("uuid")]
                if request.get("cancel_queued"):
                    receipt["cancelled"] = stamped
                    held = [m for m in held if m is None or not m.get("uuid")]
                else:
                    receipt["still_queued"] = stamped
                for m in held:
                    inbox.put(m)
                interrupted.set()
            out({"type": "control_response", "response": {"subtype": "success", "request_id": obj.get("request_id"), "response": receipt}})
            continue
        inbox.put(obj)
    inbox.put(None)

threading.Thread(target=reader, daemon=True).start()

def replay(msg):
    frame = {"type": "user", "message": msg.get("message"), "session_id": SID, "parent_tool_use_id": None, "isReplay": True}
    if msg.get("uuid"):
        frame["uuid"] = msg["uuid"]
    out(frame)

def result(is_error=False, subtype="success"):
    out({"type": "result", "subtype": subtype, "is_error": is_error, "session_id": SID,
         "usage": {"input_tokens": 3, "output_tokens": 2}})

def say(text):
    out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None, "session_id": SID})

def run_turn(msg):
    text = text_of(msg)
    delay_start(text)
    out({"type": "system", "subtype": "init", "session_id": SID, "cwd": os.getcwd(), "model": "fake-claude", "slash_commands": ["compact"]})
    replay(msg)
    kind = shape(text)
    if kind == "CRASH":
        os._exit(3)
    if text.startswith("/compact"):
        out({"type": "system", "subtype": "compact_boundary", "session_id": SID, "compact_metadata": {"trigger": "manual", "pre_tokens": 1000, "post_tokens": 100}})
        result()
        return
    if kind == "BACKGROUND":
        job = subprocess.Popen(["sleep", "30"])
        with open(os.path.join(HERE, "bg.pid"), "w") as f:
            f.write(str(job.pid))
        out({"type": "system", "subtype": "background_tasks_changed", "tasks": [{"task_id": "bg-1", "description": "sleep"}]})
    if kind in ("TOOL", "SLOW"):
        interrupted.clear()
        out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_fake", "name": "Bash", "input": {"command": "true"}}]}, "parent_tool_use_id": None, "session_id": SID})
        deadline = time.time() + (10 if kind == "SLOW" else 1.5)
        steer = None
        while time.time() < deadline:
            if interrupted.is_set():
                out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_fake", "is_error": True, "content": "declined"}]}, "parent_tool_use_id": None, "session_id": SID})
                result(True, "error_during_execution")
                return
            try:
                steer = inbox.get(timeout=0.05)
            except queue.Empty:
                continue
            if steer is None:
                os._exit(0)
            break
        out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_fake", "is_error": False, "content": "done"}]}, "parent_tool_use_id": None, "session_id": SID})
        if steer is not None:
            replay(steer)
            say("steered: " + text_of(steer))
    if kind == "HOLD":
        interrupted.clear()
        out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_hold", "name": "Bash", "input": {"command": "true"}}]}, "parent_tool_use_id": None, "session_id": SID})
        deadline = time.time() + 10
        while time.time() < deadline:
            if interrupted.is_set():
                out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_hold", "is_error": True, "content": "declined"}]}, "parent_tool_use_id": None, "session_id": SID})
                result(True, "error_during_execution")
                return
            time.sleep(0.02)
        out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_hold", "is_error": False, "content": "done"}]}, "parent_tool_use_id": None, "session_id": SID})
    if kind == "PLAIN":
        time.sleep(0.6)
    if kind == "LONG":
        interrupted.clear()
        deadline = time.time() + 10
        while time.time() < deadline:
            if interrupted.is_set():
                result(True, "error_during_execution")
                return
            time.sleep(0.02)
    say("ok")
    result()

while True:
    msg = inbox.get()
    if msg is None:
        break
    run_turn(msg)
"""#

    private static let codexSource = #"""
THREAD = "codex-fake-thread"
state = {"turn": None, "n": 0}
steered = queue.Queue()
interrupted = threading.Event()
lock = threading.Lock()

def reply(obj, result=None, error=None):
    if obj.get("id") is None:
        return
    if error is not None:
        out({"id": obj["id"], "error": error})
    else:
        out({"id": obj["id"], "result": result or {}})

def run_turn(turn_id, text):
    delay_start(text)
    out({"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": turn_id}}})
    kind = shape(text)
    if kind == "CRASH":
        os._exit(3)
    status = "completed"
    if kind in ("TOOL", "SLOW"):
        interrupted.clear()
        out({"method": "item/started", "params": {"threadId": THREAD, "turnId": turn_id, "item": {"id": "cmd-fake", "type": "commandExecution", "command": "true"}}})
        deadline = time.time() + (10 if kind == "SLOW" else 1.5)
        while time.time() < deadline:
            if interrupted.is_set():
                status = "interrupted"
                break
            try:
                steer = steered.get(timeout=0.05)
                out({"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": turn_id, "itemId": "msg-steer", "delta": "steered: " + steer}})
                break
            except queue.Empty:
                continue
        out({"method": "item/completed", "params": {"threadId": THREAD, "turnId": turn_id, "item": {"id": "cmd-fake", "type": "commandExecution", "status": "completed"}}})
    if kind == "HOLD":
        # turn/steer is answered at once, but the steered input is only applied
        # after the command; an interrupt first leaves it unapplied.
        interrupted.clear()
        out({"method": "item/started", "params": {"threadId": THREAD, "turnId": turn_id, "item": {"id": "cmd-hold", "type": "commandExecution", "command": "true"}}})
        deadline = time.time() + 10
        while time.time() < deadline and not interrupted.is_set():
            time.sleep(0.02)
        out({"method": "item/completed", "params": {"threadId": THREAD, "turnId": turn_id, "item": {"id": "cmd-hold", "type": "commandExecution", "status": "completed"}}})
        if interrupted.is_set():
            status = "interrupted"
        else:
            while not steered.empty():
                out({"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": turn_id, "itemId": "msg-steer", "delta": "steered: " + steered.get()}})
    if kind == "PLAIN":
        time.sleep(0.6)
    if kind == "LONG":
        interrupted.clear()
        deadline = time.time() + 10
        while time.time() < deadline and not interrupted.is_set():
            time.sleep(0.02)
        if interrupted.is_set():
            status = "interrupted"
    with lock:
        state["turn"] = None
    out({"method": "turn/completed", "params": {"threadId": THREAD, "turn": {"id": turn_id, "status": status}}})

for line in sys.stdin:
    if not line.strip():
        continue
    record(line)
    obj = json.loads(line)
    method = obj.get("method")
    params = obj.get("params") or {}
    if method == "thread/start":
        reply(obj, {"thread": {"id": THREAD}})
        out({"method": "thread/started", "params": {"thread": {"id": THREAD}}})
    elif method == "turn/start":
        with lock:
            state["n"] += 1
            turn_id = "turn-%d" % state["n"]
            state["turn"] = turn_id
        reply(obj, {"turn": {"id": turn_id}})
        text = "".join(i.get("text", "") for i in params.get("input", []))
        threading.Thread(target=run_turn, args=(turn_id, text), daemon=True).start()
    elif method == "turn/steer":
        with lock:
            active = state["turn"]
        if active is None or params.get("expectedTurnId") != active:
            reply(obj, error={"code": -32600, "message": "no active turn to steer"})
        else:
            reply(obj, {"turnId": active})
            steered.put("".join(i.get("text", "") for i in params.get("input", [])))
    elif method == "turn/interrupt":
        interrupted.set()
        reply(obj, {})
    else:
        reply(obj, {})
time.sleep(0.2)
"""#

    private static let piSource = #"""
state = {"active": False, "steering": [], "announced": False}
lock = threading.Lock()
steer_arrived = threading.Event()
aborted = threading.Event()
idle = threading.Event()
idle.set()

def respond(obj, success=True, data=None, error=None):
    frame = {"type": "response", "id": obj.get("id"), "command": obj.get("type"), "success": success}
    if data is not None:
        frame["data"] = data
    if error is not None:
        frame["error"] = error
    out(frame)

def queue_update():
    with lock:
        steering = list(state["steering"])
    out({"type": "queue_update", "steering": steering, "followUp": []})

def finish(reason):
    out({"type": "turn_end", "message": {"role": "assistant", "stopReason": reason}})
    out({"type": "agent_end", "willRetry": False})
    with lock:
        state["active"] = False
    out({"type": "agent_settled"})
    idle.set()

def run_turn(text):
    delay_start(text)
    out({"type": "agent_start"})
    out({"type": "turn_start"})
    kind = shape(text)
    if kind == "CRASH":
        os._exit(3)
    if kind in ("TOOL", "SLOW"):
        out({"type": "tool_execution_start", "toolCallId": "tc-fake", "toolName": "bash", "args": {"command": "true"}})
        deadline = time.time() + (10 if kind == "SLOW" else 1.5)
        # A SLOW tool keeps a steer waiting in pi's queue, so an abort finds it.
        while time.time() < deadline and not aborted.is_set() and not (kind == "TOOL" and steer_arrived.is_set()):
            time.sleep(0.02)
        if aborted.is_set():
            finish("aborted")
            return
        out({"type": "tool_execution_end", "toolCallId": "tc-fake", "toolName": "bash", "isError": False})
        with lock:
            taken = list(state["steering"])
            state["steering"] = []
        if taken:
            queue_update()
            for steer in taken:
                out({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "steered: " + steer}})
    if kind == "PLAIN":
        time.sleep(0.6)
    if kind == "LONG":
        deadline = time.time() + 10
        while time.time() < deadline and not aborted.is_set():
            time.sleep(0.02)
        if aborted.is_set():
            finish("aborted")
            return
    finish("stop")

for line in sys.stdin:
    if not line.strip():
        continue
    record(line)
    obj = json.loads(line)
    kind = obj.get("type")
    if kind == "prompt":
        with lock:
            announce = not state["announced"]
            state["announced"] = True
            state["active"] = True
        if announce:
            # pi's session header: the session-ready signal production reads
            # before the first agent_start.
            out({"type": "session", "id": "pi-fake-session", "cwd": os.getcwd()})
        idle.clear()
        aborted.clear()
        steer_arrived.clear()
        respond(obj)
        threading.Thread(target=run_turn, args=(obj.get("message", ""),), daemon=True).start()
    elif kind == "steer":
        with lock:
            active = state["active"]
            if active:
                state["steering"].append(obj.get("message", ""))
        if not active:
            respond(obj, False, error="no active run")
            continue
        queue_update()
        respond(obj)
        steer_arrived.set()
    elif kind == "abort":
        aborted.set()
        idle.wait(5)
        respond(obj)
    elif kind == "clear_queue":
        with lock:
            cleared = list(state["steering"])
            state["steering"] = []
        queue_update()
        respond(obj, data={"steering": cleared, "followUp": []})
    elif kind == "get_commands":
        respond(obj, data={"commands": []})
    else:
        respond(obj, data={})
time.sleep(0.2)
"""#
}
