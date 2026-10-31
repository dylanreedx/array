#!/usr/bin/env python3
"""Two background Array peers, disposable projects/vaults/tmux and LOCAL relay.
No normal app bundle, activation, production endpoint or provider login is used.
"""
from __future__ import annotations
import argparse, base64, contextlib, hashlib, http.client, http.server, json, os
from pathlib import Path
import re, shutil, signal, socket, subprocess, tempfile, threading, time, uuid


def atomic_json(path: Path, value):
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(value, sort_keys=True)); temp.chmod(0o600); temp.replace(path)


def read_json(path: Path):
    try: return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError): return None


def wait_for(predicate, label, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(0.02)
    raise AssertionError("deadline: " + label)


def free_port():
    with socket.socket() as value:
        value.bind(("127.0.0.1", 0)); return value.getsockname()[1]


class Proxy:
    """Hold update requests before forwarding AND their in-flight responses."""
    def __init__(self, backend):
        self.backend = backend; self.release = threading.Event(); self.release.set()
        self.snapshot_release = threading.Event(); self.snapshot_release.set()
        self.lock = threading.Lock(); self.pages = []; self.commands = []; self.blocked = 0
        owner = self
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *_): pass
            def do_GET(self): self.forward()
            def do_POST(self): self.forward()
            def do_DELETE(self): self.forward()
            def do_PUT(self): self.forward()  # artifact blob uploads
            def forward(self):
                body = self.rfile.read(int(self.headers.get("content-length", 0)))
                updates = self.command == "POST" and self.path.endswith("/updates")
                snapshot = self.command == "GET" and re.fullmatch(r"/collaboration/v1/areas/[^/]+/?", self.path) is not None
                if updates and not owner.release.is_set():
                    with owner.lock: owner.blocked += 1
                    if not owner.release.wait(240): return
                if snapshot and not owner.snapshot_release.wait(240): return
                headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length")}
                headers["connection"] = "close"
                connection = http.client.HTTPConnection("127.0.0.1", owner.backend, timeout=40)
                try:
                    if self.command == "POST" and self.path.endswith("/commands"):
                        try:
                            command = json.loads(body)["command"]
                            identity = command["id"]["rawValue"]
                            with owner.lock: owner.commands.append(identity)
                        except (KeyError, ValueError, TypeError): pass
                    connection.request(self.command, self.path, body=body or None, headers=headers)
                    response = connection.getresponse(); payload = response.read()
                    if updates and not owner.release.is_set():
                        with owner.lock: owner.blocked += 1
                        if not owner.release.wait(240): return
                    if snapshot and not owner.snapshot_release.wait(240): return
                    self.send_response(response.status)
                    self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(payload)))
                    self.send_header("connection", "close"); self.end_headers()
                    self.wfile.write(payload); self.wfile.flush()
                    if updates and response.status == 200:
                        page = json.loads(payload)
                        if page.get("events"):
                            with owner.lock: owner.pages.append({"after": page["after"], "through": page["through"],
                                "next": page["nextCursor"], "revisions": [event["revision"] for event in page["events"]]})
                except (OSError, http.client.HTTPException, ValueError):
                    with contextlib.suppress(OSError):
                        self.send_response(503); self.send_header("content-length", "0"); self.send_header("connection", "close"); self.end_headers()
                finally: connection.close(); self.close_connection = True
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
    def pause(self): self.release.clear()
    def resume(self): self.release.set()
    def hold_snapshots(self): self.snapshot_release.clear()
    def resume_snapshots(self): self.snapshot_release.set()
    def close(self): self.resume(); self.resume_snapshots(); self.server.shutdown(); self.server.server_close()


class Peer:
    def __init__(self, harness, label, enrollment, proxy):
        self.harness = harness; self.label = label; self.proxy = proxy
        self.root = harness.root / label; self.root.mkdir(mode=0o700)
        for name in ("support", "project", "mailbox", "tmux", "tmp"): (self.root / name).mkdir(mode=0o700)
        self.config = {"label": label, "instance": "", "supportRoot": str(self.root / "support"),
            "projectRoot": str(self.root / "project"), "mailboxRoot": str(self.root / "mailbox"),
            "endpoint": f"http://127.0.0.1:{proxy.port}", "enrollmentCode": enrollment["code"],
            "defaultsSuite": "dev.arrayapp.macos.qa.pair." + harness.root.name + "." + label}
        self.process = None; self.log = None; self.last_marker = None
        self.tmux_env = dict(harness.env, TMUX_TMPDIR=str((self.root / "tmux").resolve()))
        harness.peers.append(self)
        assert shutil.which("tmux"), "tmux is required to verify the isolated physical socket namespace"
        result = subprocess.run(["tmux", "-f", "/dev/null", "start-server", ";", "set-option", "-g", "exit-empty", "off", ";", "display-message", "-p", "#{socket_path}"],
            env=self.tmux_env, capture_output=True, text=True, timeout=10, check=True)
        socket_path = Path(result.stdout.strip()).resolve()
        assert socket_path.is_relative_to((self.root / "tmux").resolve()), "tmux escaped disposable namespace"
    def start(self):
        assert self.process is None or self.process.poll() is not None
        self.config["instance"] = str(uuid.uuid4())
        atomic_json(self.root / "config.json", self.config)
        for name in ("ready.json", "status.json", "request.json", "fault-marker.json", "fault-release"):
            with contextlib.suppress(FileNotFoundError): (self.root / "mailbox" / name).unlink()
        env = dict(self.tmux_env, CONTINUUM_COLLABORATION_PEER_CONFIG=str(self.root / "config.json"),
            CONTINUUM_APP_SUPPORT=self.config["supportRoot"], CONTINUUM_PROJECT_ROOT=self.config["projectRoot"],
            TMPDIR=str(self.root / "tmp"), CONTINUUM_QA_FLOW="1", CONTINUUM_SMOKE_TEST="1")
        self.log = open(self.harness.artifacts / f"peer-{self.label}-{self.config['instance']}.log", "w")
        self.process = subprocess.Popen([str(self.harness.array), "--collaboration-peer-check", "-continuum.terminal.tmux.enabled", "NO", "-continuum.terminal.tmux.path", ""],
            cwd=self.harness.checkout, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        self.harness.qa_pids.add(self.process.pid)
        def ready():
            if self.process.poll() is not None: raise AssertionError(f"peer {self.label} exited {self.process.returncode} before ready")
            value = read_json(self.root / "mailbox" / "ready.json")
            return value if value and value.get("instance") == self.config["instance"] else None
        return wait_for(ready, f"peer {self.label} native ready", 75)
    def call(self, op, timeout=30, **fields):
        identity = str(uuid.uuid4())
        request = dict(fields, op=op, id=identity, instance=self.config["instance"])
        atomic_json(self.root / "mailbox" / "request.json", request)
        def response():
            if self.process.poll() is not None: raise AssertionError(f"peer {self.label} exited {self.process.returncode} during {op}")
            return read_json(self.root / "mailbox" / f"response-{identity}.json")
        result = wait_for(response, f"peer {self.label} {op}", timeout)
        assert result.get("ok"), f"peer {self.label} {op}: {result.get('error', 'failed')}"
        return result["result"]
    def send(self, op, **fields):
        identity = str(uuid.uuid4())
        atomic_json(self.root / "mailbox" / "request.json", dict(fields, op=op, id=identity, instance=self.config["instance"]))
        return identity
    def snapshot(self): return read_json(self.root / "mailbox" / "status.json") or {}
    def kill_at_boundary(self, phase):
        marker = wait_for(lambda: read_json(self.root / "mailbox" / "fault-marker.json"), f"durable {phase} marker", 30)
        assert marker.get("phase") == phase
        self.last_marker = marker
        self.kill_abrupt()
        return marker
    def kill_abrupt(self):
        assert self.process and self.process.poll() is None
        # This exact Popen handle came from the guarded isolated peer launch.
        # SIGTERM has no graceful-save handler; it is abrupt process death without
        # a deliberate SIGABRT/Core crash witness attributed to the live GUI.
        self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=10)
        self.harness.qa_pids.discard(self.process.pid)
        assert self.process.returncode != 0, "fault kill accidentally became a graceful successful save"
        self.log.close()
    def close(self):
        if self.process and self.process.poll() is None:
            with contextlib.suppress(Exception): self.call("quit", timeout=8)
            if self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(5)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(5)
            assert self.process.poll() is not None, "owned QA peer did not stop"
        if self.process: self.harness.qa_pids.discard(self.process.pid)
        if self.log and not self.log.closed: self.log.close()
        if shutil.which("tmux"):
            subprocess.run(["tmux", "kill-server"], env=self.tmux_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


class Harness:
    def __init__(self, args, root):
        self.root = Path(root).resolve(); self.checkout = Path.cwd().resolve()
        self.array = Path(args.array).resolve(); self.relay = Path(args.relay).resolve()
        self.artifacts = Path(args.artifacts).resolve(); self.artifacts.mkdir(parents=True, exist_ok=True)
        previous = self.artifacts / "report.json"
        if previous.exists(): previous.rename(self.artifacts / f"report-{time.time_ns()}.json")
        assert self.array.is_file() and self.relay.is_file(), "build Array and continuum-relay before this witness"
        assert "/Applications/Array.app" not in str(self.array) and "Desktop/Array Dev.app" not in str(self.array)
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")
            and not k.startswith(("APNS_", "RELAY_")) and k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
        self.env.update(RELAY_HOST="127.0.0.1", PORT=str(free_port()), RELAY_ADMIN_PORT=str(free_port()),
            RELAY_DATABASE_PATH=str(self.root / "relay.sqlite"), RELAY_MASTER_KEY=base64.b64encode(os.urandom(32)).decode(),
            RELAY_COLLABORATION_DATABASE_PATH=str(self.root / "collaboration.sqlite"), RELAY_COLLABORATION_MASTER_KEY=base64.b64encode(os.urandom(32)).decode())
        self.port = int(self.env["PORT"]); self.server = None; self.server_log = None
        self.proxies = []; self.peers = []; self.steps = []; self.qa_pids = set(); self.focus_violation = None; self.focus_samples = 0
        assert shutil.which("lsappinfo"), "lsappinfo is required to witness background-only focus behavior"
        self.watch_stop = threading.Event(); self.watch_thread = threading.Thread(target=self.watch_focus, daemon=True); self.watch_thread.start()
    def watch_focus(self):
        while not self.watch_stop.wait(0.1):
            try:
                front = subprocess.check_output(["lsappinfo", "front"], text=True, stderr=subprocess.DEVNULL, timeout=2).strip()
                value = subprocess.check_output(["lsappinfo", "info", "-only", "pid", front], text=True, stderr=subprocess.DEVNULL, timeout=2)
                match = re.search(r'"?pid"?\s*=\s*(\d+)', value)
                if match:
                    self.focus_samples += 1
                    if int(match.group(1)) in self.qa_pids: self.focus_violation = int(match.group(1))
            except (OSError, subprocess.SubprocessError): pass
    def pass_step(self, text):
        assert self.focus_violation is None, "QA peer took foreground focus"
        self.steps.append(text); print("PASS pair:", text, flush=True)
    def start_relay(self):
        self.server_log = open(self.artifacts / f"relay-{time.time_ns()}.log", "w")
        self.server = subprocess.Popen([str(self.relay)], cwd=self.checkout, env=self.env, stdout=self.server_log, stderr=subprocess.STDOUT)
        def available():
            if self.server.poll() is not None: raise AssertionError("local relay exited before ready")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1): return True
            except OSError: return False
        wait_for(available, "local relay ready", 15)
    def stop_relay(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            try: self.server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.server.kill(); self.server.wait(timeout=5)
        if self.server_log and not self.server_log.closed: self.server_log.close()
    def enroll(self, label):
        run = subprocess.run([str(self.relay), "--collaboration-enroll", "QA " + label], cwd=self.checkout, env=self.env,
            capture_output=True, text=True, timeout=15, check=True)
        return json.loads(run.stdout)
    def converge(self, a, b, timeout=35):
        def ready():
            left, right = a.snapshot(), b.snapshot()
            if left.get("status") == right.get("status") == "connected" and left.get("documentHash") and left.get("documentHash") == right.get("documentHash"):
                return left, right
        return wait_for(ready, "two native replicas converge", timeout)
    def run(self):
        self.start_relay()
        proxy_a, proxy_b = Proxy(self.port), Proxy(self.port); self.proxies = [proxy_a, proxy_b]
        a, b = Peer(self, "A", self.enroll("A"), proxy_a), Peer(self, "B", self.enroll("B"), proxy_b)
        ready_a, ready_b = a.start(), b.start()
        assert ready_a["person"] != ready_b["person"] and ready_a["pid"] != ready_b["pid"]
        assert ready_a["sourceRecords"] == 1 and ready_b["sourceRecords"] == 0
        self.pass_step("two real background Array processes use different human/device accounts, source roots, app support, vaults and physical tmux sockets")
        a.call("create")
        invitation = a.call("invite", person=ready_b["person"])["invitation"]
        b.call("join", invitation=invitation)
        self.converge(a, b)
        wait_for(lambda: a.snapshot().get("epoch") == b.snapshot().get("epoch"), "membership epoch reaches both native peers")
        baseline_a, baseline_b = a.call("status"), b.call("status")
        a.call("shareZone")
        first_a, first_b = self.converge(a, b)
        kinds = [item["kind"] for item in first_b["items"]]
        assert kinds.count("agreement") == kinds.count("agentObservation") == 1, f"publication duplicated or missing: {kinds}"
        assert first_a["bindings"] == 1 and first_b["bindings"] == 0
        assert first_a["runnerConstructions"] == first_b["runnerConstructions"] == 0
        self.pass_step("production-mounted source-zone review publishes real HTTP portable content/layout and exact host binding, with zero recipient executor creation")
        a.call("edit", text="PAIR A agreement revision"); self.converge(a, b)
        b.call("edit", text="PAIR B agreement revision"); edited_a, edited_b = self.converge(a, b)
        assert edited_a["contexts"][-1]["text"] == edited_b["contexts"][-1]["text"] == "PAIR B agreement revision"
        self.pass_step("both people edit immutable agreement revisions through their native shared scenes")
        before = edited_a["positions"]
        a.call("move", x=310.0, y=190.0); moved, _ = self.converge(a, b)
        assert moved["positions"] != before
        a.call("undo"); undone, _ = self.converge(a, b); assert undone["positions"] == before
        a.call("redo"); redone, _ = self.converge(a, b); assert redone["positions"] == moved["positions"]
        self.pass_step("shared drag, Undo and Redo preserve exact portable frames on both mounted native replicas")
        a.call("beginMove", x=410.0, y=290.0)
        b.call("move", x=530.0, y=370.0); peer_won, _ = self.converge(a, b)
        a.call("finishMove"); after_conflict, _ = self.converge(a, b)
        assert after_conflict["positions"] == peer_won["positions"]
        a.call("undo"); after_undo, _ = self.converge(a, b)
        assert after_undo["positions"] == peer_won["positions"]
        self.pass_step("a teammate's conflicting move cancels stale preview and semantic Undo cannot overwrite the newer placement")
        b.call("move", x=600.0, y=110.0); b_moved, _ = self.converge(a, b)
        assert b_moved["positions"] != after_undo["positions"]
        b.call("undo"); b_undone, _ = self.converge(a, b); assert b_undone["positions"] == after_undo["positions"]
        b.call("redo"); b_redone, _ = self.converge(a, b); assert b_redone["positions"] == b_moved["positions"]
        a.call("move", x=450.0, y=150.0); a_newer, _ = self.converge(a, b)
        assert a_newer["positions"] != b_moved["positions"]
        b.call("undo"); b_stale, _ = self.converge(a, b)
        assert b_stale["positions"] == a_newer["positions"], "B's Undo overwrote A's newer placement"
        a.call("undo"); settled, _ = self.converge(a, b); assert settled["positions"] == b_moved["positions"]
        self.pass_step("the second person's own Undo and Redo replicate to both peers, and their stale Undo cannot overwrite the first person's newer move")
        a.call("camera", x=-220.0, y=130.0, zoom=0.8); b.call("camera", x=620.0, y=-300.0, zoom=1.2)
        assert a.call("status")["privateCamera"] != b.call("status")["privateCamera"]
        self.pass_step("the same shared arrangement retains independent private cameras")
        # Crash at a real pre-effect durable boundary, then recover the same ID.
        a.call("armFault", phase="beforeSend"); a.send("move", x=640.0, y=420.0)
        marker = a.kill_at_boundary("beforeSend"); operation = marker["operation"]
        a.start(); recovered, _ = self.converge(a, b)
        assert recovered["pending"] == [] and proxy_a.commands.count(operation) == 1
        assert {"id": operation, "revision": marker["expectedRevision"] + 1} in recovered["acceptedOperations"]
        assert recovered["privateCamera"] == {"x": -220.0, "y": 130.0, "zoom": 0.8}
        assert any(position["x"] == 640.0 and position["y"] == 420.0 for position in recovered["positions"])
        a.call("undo"); recovered_undo, _ = self.converge(a, b)
        assert recovered_undo["positions"] == settled["positions"]
        self.pass_step("abrupt pre-send process death retains exact command and geometry history; cold relaunch submits once and Undo still works")
        # Prevent another channel from delivering the accepted receipt before kill.
        proxy_a.pause()
        a.call("armFault", phase="afterCommit"); a.send("move", x=760.0, y=490.0)
        marker = a.kill_at_boundary("afterCommit"); operation = marker["operation"]
        proxy_a.resume(); a.start(); committed, _ = self.converge(a, b)
        assert committed["pending"] == [] and proxy_a.commands.count(operation) == 1
        assert {"id": operation, "revision": marker["expectedRevision"] + 1} in committed["acceptedOperations"]
        assert committed["privateCamera"] == {"x": -220.0, "y": 130.0, "zoom": 0.8}
        assert any(position["x"] == 760.0 and position["y"] == 490.0 for position in committed["positions"])
        a.call("undo"); after_lost_ack_undo, _ = self.converge(a, b)
        assert after_lost_ack_undo["positions"] == settled["positions"]
        self.pass_step("post-commit/lost-ack process death recovers the authenticated original receipt without replaying a remote effect, and retains Undo")
        # >500 UPDATE EVENTS, not a cold snapshot reopen.
        proxy_b.hold_snapshots(); proxy_b.pause()
        a.call("edit", text="PAIR replay barrier")
        wait_for(lambda: proxy_b.blocked > 0, "B update held before forwarding")
        held = b.snapshot()["revision"]
        a.call("burst", count=550, timeout=180)
        assert b.snapshot()["revision"] <= held
        proxy_b.resume(); replay_a, replay_b = self.converge(a, b, timeout=70)
        assert replay_a["posts"] == replay_b["posts"] == 550
        assert len(set(replay_b["postIDs"])) == 550
        pages = [page for page in proxy_b.pages if page["next"] > held]
        revisions = {revision for page in pages for revision in page["revisions"] if revision > held}
        assert len(revisions) >= 550 and set(range(held + 1, replay_b["revision"] + 1)).issubset(revisions)
        assert all(0 < len(page["revisions"]) <= 128 and page["revisions"] == list(range(page["after"] + 1, page["next"] + 1)) and page["next"] <= page["through"] for page in pages)
        assert any(page["through"] > page["next"] for page in pages)
        assert not proxy_b.snapshot_release.is_set(), "snapshot fallback was accidentally allowed during the retained-event witness"
        proxy_b.resume_snapshots()
        self.pass_step("a live disconnected follower catches up more than 500 ordered retained events in bounded pages, without snapshot substitution, gaps or duplicated messages")
        self.stop_relay()
        wait_for(lambda: a.snapshot().get("status") != "connected" and b.snapshot().get("status") != "connected", "both peers observe local relay disconnect", 40)
        self.start_relay(); reconnect_a, reconnect_b = self.converge(a, b, timeout=70)
        assert reconnect_a["posts"] == reconnect_b["posts"] == 550
        self.pass_step("both live native peers reconnect after the same local relay/database restarts without replaying mutations")
        a.call("hostPoll")
        assert a.call("localSend")["localControlAccepted"], "sharing a source incorrectly blocked its ordinary owner"
        wait_for(lambda: (value := a.call("status")).get("runnerCalls") == value.get("runnerCompleted") == 1 and value.get("sourceRunningAgents") == 0,
            "source owner's ordinary prompt completes and releases its live slot", 10)
        a.call("handoffOffer", person=ready_b["person"]); b.call("handoffAccept")
        # Full access: handing over never locks the owner out of their agent.
        assert a.call("localSend")["localControlAccepted"], "a handoff incorrectly blocked the source owner's own prompt"
        wait_for(lambda: (value := a.call("status")).get("runnerCalls") == value.get("runnerCompleted") == 2 and value.get("sourceRunningAgents") == 0,
            "the owner's prompt while handed over completes and releases its live slot", 10)
        a.call("rebindSource")
        b.call("handoffSend", text="PAIR HANDOFF from B using the current shared agreement")
        for _ in range(4):
            a.call("hostPoll"); b.call("handoffRefresh")
            if a.snapshot().get("runnerCalls") == 3: break
            time.sleep(0.1)
        host = wait_for(lambda: value if (value := a.snapshot()).get("runnerCalls") == 3 else None, "original host receives exactly one handed-off prompt", 10)
        wait_for(lambda: (value := a.call("status")).get("runnerCompleted") == 3 and value.get("sourceRunningAgents") == 0,
            "handed-off prompt reaches a provider-shaped completed result", 10)
        a.call("hostPoll"); a.call("hostPoll")
        assert a.call("status")["runnerCalls"] == 3 and b.call("status")["runnerConstructions"] == 0
        assert "PAIR HANDOFF" in host["runnerPrompts"][-1] and "PAIR replay barrier" in host["runnerPrompts"][-1]
        receipt = wait_for(lambda: value if (value := b.call("handoffRefresh")).get("handoffPhase") == "accepted" else None, "recipient observes native supervisor acceptance receipt", 10)
        assert receipt["handoffRequester"] == ready_b["person"]
        self.pass_step("explicit teammate handoff keeps the owner able to prompt, survives source view rebind, and dispatches one attributed current-context prompt through the original supervisor")
        b.kill_abrupt(); b.start(); self.converge(a, b)
        restored_receipt = b.call("handoffRefresh")
        assert restored_receipt["handoffPhase"] == "accepted" and restored_receipt["handoffCommand"] == receipt["handoffCommand"]
        assert restored_receipt["handoffContext"] == receipt["handoffContext"] and restored_receipt["runnerConstructions"] == 0
        a.call("hostPoll"); assert a.call("status")["runnerCalls"] == 3
        self.pass_step("recipient abrupt relaunch restores the exact accepted handoff receipt without executing or redispatching its command")
        a.call("usage")
        usage = wait_for(lambda: value.get("usage") if (value := a.call("status")).get("usage", {}).get("input") == 300 else None, "published source token observation reaches durable accounting", 10)
        assert usage["output"] == 60
        for _ in range(3): a.call("usage"); a.call("hostPoll")
        repeated = a.call("status")["usage"]
        assert (repeated["input"], repeated["output"], repeated["todayInput"], repeated["todayOutput"]) == (300, 60, 300, 60), f"usage double-counted: {repeated}"
        b.call("camera", x=0.0, y=0.0, zoom=1.0)
        a.call("presence", x=80.0, y=80.0); b.call("presence", x=120.0, y=110.0)
        wait_for(lambda: b.snapshot().get("presence", 0) >= 2, "teammate cursor and usage presence")
        off = b.call("hover"); assert not off["hoverText"]
        hover = wait_for(lambda: text if "Reported total: 360 tokens" in (text := b.call("hover", device=ready_a["device"])["hoverText"]) else None, "hover-only live teammate tokens", 10)
        assert hover
        assert not b.call("hover")["hoverText"]
        b.kill_abrupt(); b.start(); self.converge(a, b); a.call("usage")
        b.call("camera", x=0.0, y=0.0, zoom=1.0); a.call("presence", x=80.0, y=80.0); b.call("presence", x=120.0, y=110.0)
        relaunched = wait_for(lambda: text if "Reported total:" in (text := b.call("hover", device=ready_a["device"])["hoverText"]) else None, "hover after recipient relaunch", 10)
        assert "Reported total: 360 tokens" in relaunched, f"hover double-counted after relaunch: {relaunched}"
        assert a.call("status")["usage"]["todayInput"] == 300
        self.pass_step("real source token events persist as 300 input/60 output over three turns and render only while the teammate cursor is inspected; republishing and a recipient relaunch never double-count")
        end_a, end_b = a.call("status"), b.call("status")
        assert end_a["sourceFiles"] == baseline_a["sourceFiles"] and end_b["sourceFiles"] == baseline_b["sourceFiles"]
        assert end_a["sourceWorld"] == baseline_a["sourceWorld"] and end_b["sourceWorld"] == baseline_b["sourceWorld"]
        assert end_a["sourceRecords"] == 1 and end_b["sourceRecords"] == 0
        assert self.focus_samples > 0, "no frontmost-process observations were captured"
        self.pass_step("all sharing, edits, crashes, replay and handoff preserve separate source files/WORLD membership and never create a recipient executor")
        return {"passed": True, "steps": self.steps, "replayEvents": len(revisions), "replayPages": len(pages),
            "sourceRunnerCalls": end_a["runnerCalls"], "recipientExecutors": end_b["runnerConstructions"],
            "noFocusViolation": self.focus_violation is None, "focusObservations": self.focus_samples,
            "snapshotSubstitutionPreventedDuringReplay": True}
    def close(self):
        for proxy in self.proxies: proxy.resume(); proxy.resume_snapshots()
        for peer in self.peers:
            with contextlib.suppress(Exception): peer.close()
        for proxy in self.proxies:
            with contextlib.suppress(Exception): proxy.close()
        with contextlib.suppress(Exception): self.stop_relay()
        self.watch_stop.set(); self.watch_thread.join(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--array", default=".build/debug/Array")
    parser.add_argument("--relay", default=".build/debug/continuum-relay")
    parser.add_argument("--artifacts", default="qa-runs/collaboration-pair")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="array-pair-", dir="/tmp") as directory:
        harness = Harness(args, directory)
        try:
            report = harness.run(); atomic_json(harness.artifacts / "report.json", report)
            print("Collaboration paired Array process checks passed:", len(report["steps"]), "behaviors;", report["replayEvents"], "replayed events; local-only/no activation", flush=True)
            return 0
        except Exception as error:
            report = {"passed": False, "steps": harness.steps, "error": str(error), "type": type(error).__name__}
            for peer in harness.peers:
                deliveries = []
                for path in (peer.root / "support").rglob("state.json"):
                    state = read_json(path)
                    if isinstance(state, dict) and "operations" in state:
                        deliveries.append({"scope": state.get("scope"), "epoch": state.get("observedMembershipEpoch"), "operations": state["operations"]})
                atomic_json(harness.artifacts / f"failure-{peer.label}-{peer.config['instance']}.json", {"status": peer.snapshot(), "savedDeliveries": deliveries})
            atomic_json(harness.artifacts / "report.json", report)
            print("FAIL pair:", type(error).__name__, str(error), flush=True)
            return 1
        finally: harness.close()


if __name__ == "__main__": raise SystemExit(main())
