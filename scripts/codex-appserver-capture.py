#!/usr/bin/env python3
"""Codex app-server single-agent capture harness.

Program: docs/38-tickets Codex app-server parity ticket (.plans/46 "Codex — the
decision, settled by measurement"). De-risking step before any CodexAgentRunner
rewrite: drives ONE single-agent, non-delegating codex session over `codex
app-server`'s JSON-RPC-over-stdio protocol end to end, and records the raw
notification/response stream to a file — untouched, before any scrubbing.

Argv mirrors what Array's CodexAgentRunner already passes to `codex exec`
(CodexAgentRunner.processArguments): --skip-git-repo-check, approval_policy=
never, sandbox_mode=workspace-write, and a fully-qualified `-m` model id (never
a partial pattern — codex fuzzy-matches those and silently runs the wrong
model). app-server takes these as process-level `-c`/flag overrides same as
exec; there is no per-thread equivalent for most of them.

Usage:
    python3 scripts/codex-appserver-capture.py --out /tmp/codex-capture.ndjson \
        --model gpt-5.1-codex --prompt "Say hello in one short sentence."

Never touches ~/.codex/config.toml. Every setting here is a per-invocation
-c key=value. Run from a throwaway cwd (pass --cwd) so a real session doesn't
write into this checkout.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
import uuid


def make_argv(codex_bin, model, extra_enable):
    argv = [
        codex_bin,
        "-c", "approval_policy=never",
        "-c", "sandbox_mode=workspace-write",
        "app-server",
    ]
    for feature in extra_enable:
        argv += ["--enable", feature]
    return argv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="path to write raw NDJSON capture")
    ap.add_argument("--model", required=True, help="fully-qualified codex model id, e.g. gpt-5.1-codex")
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--cwd", default="/tmp/codex-appserver-capture-cwd")
    ap.add_argument("--codex-bin", default="codex")
    ap.add_argument("--enable", action="append", default=[], help="extra --enable FEATURE flags, e.g. multi_agent_v2")
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--drain", type=float, default=3.0, help="seconds to keep listening after the parent's turn/completed, to catch late child activity")
    ap.add_argument("--skip-git-repo-check", action="store_true", default=True)
    args = ap.parse_args()

    os.makedirs(args.cwd, exist_ok=True)

    argv = make_argv(args.codex_bin, args.model, args.enable)
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=args.cwd,
        text=True,
        bufsize=1,
    )

    raw_lines = []
    lock = threading.Lock()

    def record(direction, obj_or_text):
        with lock:
            raw_lines.append({"t": time.time(), "dir": direction, "line": obj_or_text})

    def send(obj):
        line = json.dumps(obj)
        record("send", obj)
        proc.stdin.write(line + "\n")
        proc.stdin.flush()

    responses = {}
    responses_lock = threading.Lock()

    stderr_lines = []

    def read_stderr():
        for line in proc.stderr:
            stderr_lines.append(line.rstrip("\n"))

    def read_stdout():
        for line in proc.stdout:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                record("recv_raw", line)
                continue
            record("recv", obj)
            if isinstance(obj, dict) and "id" in obj and ("result" in obj or "error" in obj):
                with responses_lock:
                    responses[obj["id"]] = obj

    def wait_response(rid, timeout=15.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with responses_lock:
                if rid in responses:
                    return responses[rid]
            time.sleep(0.1)
        return None

    t_err = threading.Thread(target=read_stderr, daemon=True)
    t_out = threading.Thread(target=read_stdout, daemon=True)
    t_err.start()
    t_out.start()

    next_id = 1

    def rpc_id():
        nonlocal next_id
        v = next_id
        next_id += 1
        return v

    # 1. initialize — experimentalApi:true is REQUIRED or thread/start's
    #    multiAgentMode field is refused -32600.
    send({
        "jsonrpc": "2.0",
        "id": rpc_id(),
        "method": "initialize",
        "params": {
            "clientInfo": {"name": "array-parity-harness", "title": "Array Parity Harness", "version": "0.0.1"},
            "capabilities": {"experimentalApi": True},
        },
    })
    time.sleep(1.0)
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    time.sleep(0.3)

    # thread/start MINTS its own thread id server-side (returned in the
    # response's thread.id) — it does not take a client-supplied one. Every
    # subsequent call must key off that returned id, not a locally generated
    # UUID (the bug that made the first probe run 100% -32600 "thread not
    # found").
    start_id = rpc_id()
    send({
        "jsonrpc": "2.0",
        "id": start_id,
        "method": "thread/start",
        "params": {
            "cwd": args.cwd,
            "model": args.model,
            "skipGitRepoCheck": True,
            "multiAgentMode": "explicitRequestOnly",
        },
    })
    start_response = wait_response(start_id, timeout=15.0)
    if not start_response or "result" not in start_response:
        sys.stderr.write(f"thread/start failed: {start_response}\n")
        thread_id = None
    else:
        thread_id = start_response["result"]["thread"]["id"]

    if thread_id is None:
        proc.terminate()
        sys.stderr.write("aborting: no thread id minted\n")
        with lock:
            lines_snapshot = list(raw_lines)
        with open(args.out, "w") as f:
            for entry in lines_snapshot:
                f.write(json.dumps(entry) + "\n")
        sys.exit(1)

    send({
        "jsonrpc": "2.0",
        "id": rpc_id(),
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": args.prompt}],
        },
    })

    # Poll stdout for a turn/completed notification ON THE PARENT THREAD (not
    # any thread — a delegating session's CHILD thread can post its own
    # turn/completed before or after the parent's, so keying on "any
    # turn/completed" conflates the two and can stop the capture on the
    # child's completion instead of the parent's).
    deadline = time.time() + args.timeout
    saw_turn_completed = False
    while time.time() < deadline:
        with lock:
            for entry in raw_lines:
                if entry["dir"] == "recv" and isinstance(entry["line"], dict):
                    obj = entry["line"]
                    if obj.get("method") == "turn/completed" and obj.get("params", {}).get("threadId") == thread_id:
                        saw_turn_completed = True
        if saw_turn_completed:
            break
        time.sleep(0.5)

    # Give any late child/thread activity a window to arrive (the ordering
    # hazard: a child's item/completed can land ~20s after the PARENT's
    # turn/completed). Keep the drain window generous for reproducibility.
    time.sleep(args.drain)

    send({
        "jsonrpc": "2.0",
        "id": rpc_id(),
        "method": "thread/read",
        "params": {"threadId": thread_id, "includeTurns": True},
    })
    time.sleep(1.5)

    try:
        proc.stdin.close()
    except Exception:
        pass
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        proc.kill()

    with lock:
        lines_snapshot = list(raw_lines)

    with open(args.out, "w") as f:
        for entry in lines_snapshot:
            f.write(json.dumps(entry) + "\n")

    sys.stderr.write(f"wrote {len(lines_snapshot)} entries to {args.out}\n")
    sys.stderr.write(f"argv: {argv}\n")
    sys.stderr.write(f"thread_id (server-minted): {thread_id}\n")
    sys.stderr.write(f"saw turn/completed: {saw_turn_completed}\n")
    if stderr_lines:
        sys.stderr.write("codex stderr tail:\n")
        for line in stderr_lines[-20:]:
            sys.stderr.write("  " + line + "\n")


if __name__ == "__main__":
    main()
