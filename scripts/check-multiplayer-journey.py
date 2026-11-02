#!/usr/bin/env python3
"""Two real Array apps, one shared agent, on a real relay. The multiplayer gate.

Two dev-channel bundles with their own identities ("Array Journey A/B" in
~/array-scratch/apps), app-support dirs, project roots, credential files and
tmux namespaces, both launched in the background, their windows parked off
every display. A third ("Array Journey C") stands in for a third person and
for a second install on the guest's root. Each is driven through
`MultiplayerDriver` (a mailbox), and every step is the production path a
click takes.

The steps are mode A of `.plans/105-collaboration/SHARE-REDESIGN.md`
("Acceptance test"): share one agent.

   1. header Share: the popover opens on T; nothing published, T unmoved
   2. sidebar Share: the same popover, on T
   3. Copy: a link; the relay holds exactly T's observation; no zone; T unmoved
   4. the guest opens the link through application(_:open:): one sharedAgent
      tile in the guest's armed zone, in view; no zone, no AgentRecord; its tab
      names the host
   5. the guest prompts P1: one turn on the host; tagged with the guest's name
      on the host and "You" on the guest; the reply on both
   6. the host prompts P2: the guest shows it with the host's name, and the reply
   7. the guest resends P1 with the same request ID: nothing new runs
   8. the guest has no Stop and no approval control; the host keeps both
   9. the host's popover lists the guest with "full access"; Remove; the guest
      tile shows the stopped state; a guest prompt is refused, nothing runs
  10. a "Works once" link: the guest joins again; a third app is refused
  11. the host quits: the guest tile goes offline; a guest prompt queues; the
      host relaunches and runs it exactly once; the tile is live again
  12. the guest relaunches: the tile is back at the same world frame and
      reconnects; a second install on the guest's root with no account shows
      the placeholder, not a broken agent

Cursors are not in mode A (the spec: "None in mode A"); the cursor-latency
leg runs only when the share made a zone.

  scripts/check-multiplayer-journey.py --relay local    # a local continuum-relay from this tree
  scripts/check-multiplayer-journey.py                  # staging relay
  scripts/check-multiplayer-journey.py --skip-build     # reuse the bundles

Every run deletes the people and areas it created on the relay, through the
relay's admin port (`RELAY_ADMIN_TOKEN`). A local relay gets its own token. On
staging the admin port is reached with `fly proxy`, and the token comes from
ARRAY_RELAY_ADMIN_TOKEN or ~/.config/array/relay-staging-admin-token (0600).
A run that cannot clean up fails and prints what it left behind.

Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
the default tmux socket, a real CLI login or the Keychain, and never takes focus.
"""
from __future__ import annotations
import argparse, base64, json, os, random, shutil, socket, statistics, string, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = Path(subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()).parent / ".worktrees/.locks/app-build.sh"
APPS = Path.home() / "array-scratch/apps"
STAGING = "https://arrayapp-relay-staging.fly.dev"
STAGING_APP = "arrayapp-relay-staging"
STAGING_ADMIN_TOKEN_FILE = Path.home() / ".config/array/relay-staging-admin-token"
# Set from --name, so two benches can run journeys side by side: each gets its
# own bundles, identities and state folder.
STATE = Path.home() / "array-scratch/mp-journey"
PEOPLE: dict = {}


def configure(name: str):
    global STATE, PEOPLE
    slug = name.lower()
    STATE = Path.home() / f"array-scratch/mp-{slug}"
    PEOPLE = {"a": (f"Array {name} A", f"dev.arrayapp.macos.mp-{slug}-a", "Avery", "host"),
              "b": (f"Array {name} B", f"dev.arrayapp.macos.mp-{slug}-b", "Blake", "guest"),
              "c": (f"Array {name} C", f"dev.arrayapp.macos.mp-{slug}-c", "Casey", "guest")}
# The windows the steps wait within. Delivery: the guest polls the projection
# every 1 s and the host flushes every 2 s, so a reply lands in a few seconds;
# 45 s covers a slow relay. Liveness: a host that quits cleanly ends its run at
# once; a lost one is offline after the relay's offlineAfter (90 s).
DELIVERY_WINDOW = 45
ACCESS_WINDOW = 30
LIVENESS_WINDOW = 105
# Cursor budget on a real relay: the last position of a stroke must land on the
# other Mac within this, and the median position within the second.
FINAL_BUDGET_MS, MEDIAN_BUDGET_MS = 700, 500


class Failed(AssertionError):
    pass


def wait_for(probe, label, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = probe()
        if last: return last
        time.sleep(0.3)
    raise Failed(f"timeout: {label}")


class Person:
    """One app. `folder` holds its support, mailbox and log; `project` is the
    root it opens (another person's, for the second-install step)."""
    def __init__(self, side, endpoint, env_extra, folder=None, project=None):
        self.side = side
        self.bundle_name, self.bundle_id, self.name, self.role = PEOPLE[side]
        self.app = APPS / f"{self.bundle_name}.app"
        self.root = STATE / (folder or side)
        self.project = project or (self.root / "project")
        self.endpoint, self.env_extra = endpoint, env_extra
        self.mailbox = self.root / "mailbox"
        self.next = 1
        self.launch()

    def launch(self):
        shutil.rmtree(self.mailbox, ignore_errors=True)
        for sub in ("support", "tmux", "mailbox", "exchange"): (self.root / sub).mkdir(parents=True, exist_ok=True)
        Path(self.project).mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.next = 1
        config = {"label": self.side.upper(), "role": self.role, "endpoint": self.endpoint, "enrollmentCode": "",
                  "root": str(self.root), "exchange": str(self.root / "exchange"), "areaLabel": "", "side": "left",
                  "driver": str(self.mailbox), "name": self.name}
        (self.root / "preview.json").write_text(json.dumps(config))
        subprocess.run(["defaults", "delete", self.bundle_id], capture_output=True)
        env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE", "ARRAY_AGENT_ID")}
        args = ["open", "-n", "-g",
                "--env", f"CONTINUUM_PROJECT_ROOT={self.project}",
                "--env", f"CONTINUUM_APP_SUPPORT={self.root / 'support'}",
                "--env", f"CONTINUUM_MULTIPLAYER_PREVIEW={self.root / 'preview.json'}",
                "--env", f"TMUX_TMPDIR={self.root / 'tmux'}"]
        for key, value in self.env_extra.items(): args += ["--env", f"{key}={value}"]
        args += ["--stdout", str(self.root / "app.log"), "--stderr", str(self.root / "app.log"),
                 str(self.app), "--args", "-ApplePersistenceIgnoreState", "YES"]
        subprocess.run(args, env=env, check=True)
        self.ready()

    def ready(self):
        wait_for(lambda: (self.mailbox / "ready.json").exists() or self._refused(), f"{self.name}'s app ready", 120)

    def _refused(self):
        log = self.root / "app.log"
        if log.exists() and "MULTIPLAYER PREVIEW REFUSED" in log.read_text(errors="replace"):
            raise Failed(f"{self.name}'s app refused to start: {log.read_text(errors='replace')[-400:]}")
        return False

    def call(self, op, timeout=90, **fields):
        n = self.next; self.next += 1
        request = self.mailbox / f"req-{n}.json"
        tmp = request.with_suffix(".tmp"); tmp.write_text(json.dumps({"op": op, **fields})); tmp.rename(request)
        response = self.mailbox / f"res-{n}.json"
        wait_for(response.exists, f"{self.name}: {op} answered", timeout)
        value = json.loads(response.read_text())
        if not value.get("ok"): raise Failed(f"{self.name}: {op} failed: {value.get('error')}")
        return value

    def pids(self):
        out = subprocess.run(["pgrep", "-f", f"{self.app}/Contents/MacOS/"], capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]

    def quit(self):
        """A clean quit, the way ⌘Q ends the app; waits for the process to go."""
        try: self.call("quit", timeout=15)
        except Failed: pass
        try: wait_for(lambda: not self.pids(), f"{self.name}'s app quit", 20)
        except Failed:
            for pid in self.pids():
                try: os.kill(pid, 9)
                except OSError: pass
            time.sleep(1)


def share_step(host, tile):
    """The share, as one swappable step: an agent in, a link out. Mode A:
    the header Share clicked, then the popover's Copy."""
    slug = "journey-" + "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(8))
    return host.call("share", tile=tile, slug=slug)


def latency(sender, receiver, direction):
    """A pointer stroke on `sender`; how long each position took to reach `receiver`."""
    receiver_before = len(receiver.call("cursors")["arrivals"])
    posted = sender.call("stroke", steps=90)["posted"]
    time.sleep(2.5)
    arrivals = receiver.call("cursors")["arrivals"][receiver_before:]
    def key(p): return (round(p["x"], 3), round(p["y"], 3))
    first_arrival = {}
    for a in arrivals: first_arrival.setdefault(key(a), a["t"])
    delays = [(first_arrival[key(p)] - p["t"]) * 1000 for p in posted if key(p) in first_arrival]
    final = posted[-1]
    final_ms = (first_arrival[key(final)] - final["t"]) * 1000 if key(final) in first_arrival else None
    stroke_s = posted[-1]["t"] - posted[0]["t"]
    distinct = len({key(a) for a in arrivals})
    median = statistics.median(delays) if delays else None
    p90 = sorted(delays)[int(len(delays) * 0.9)] if delays else None
    print(f"CURSOR {direction}: {len(posted)} positions posted over {stroke_s:.2f} s; {distinct} arrived "
          f"({distinct / stroke_s:.1f}/s); delay median {median:.0f} ms, p90 {p90:.0f} ms, max {max(delays):.0f} ms; "
          f"final position {'%.0f ms' % final_ms if final_ms is not None else 'NEVER arrived'}" if delays else
          f"CURSOR {direction}: {len(posted)} posted, none arrived")
    return median, final_ms


def inside(inner, outer, slack=0.5):
    return (inner["x"] >= outer["x"] - slack and inner["y"] >= outer["y"] - slack
            and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + slack
            and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + slack)


def intersects(a, b):
    return a["x"] < b["x"] + b["width"] and b["x"] < a["x"] + a["width"] and a["y"] < b["y"] + b["height"] and b["y"] < a["y"] + a["height"]


def free_port():
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


def created_people():
    """Every person this run's apps signed up as, from their credential files."""
    people = set()
    for path in STATE.rglob("*.credential"):
        try: person = json.loads(path.read_text())["identity"]["person"]
        except (OSError, ValueError, KeyError, TypeError): continue
        people.add(person["rawValue"] if isinstance(person, dict) else person)
    return sorted(people)


def admin_call(base, token, method, path):
    request = urllib.request.Request(f"{base}/collaboration/{path}", method=method, headers={"authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response: return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        body = error.read()
        try: return error.code, json.loads(body)
        except ValueError: return error.code, body.decode(errors="replace")


def clean_relay(base, token, people):
    """Deletes every area these people are in, then the people. Returns what is
    left behind, as lines to print; empty means the relay holds nothing of the run."""
    left = []
    areas = set()
    for person in people:
        status, detail = admin_call(base, token, "GET", f"people/{person}")
        if status == 404: continue
        if status != 200: left.append(f"person {person}: lookup {status} {detail}"); continue
        areas.update(m["area"] for m in detail["memberships"])
    for area in sorted(areas):
        status, detail = admin_call(base, token, "DELETE", f"areas/{area}")
        if status not in (200, 404): left.append(f"area {area}: delete {status} {detail}")
    for person in people:
        status, detail = admin_call(base, token, "DELETE", f"people/{person}")
        if status not in (200, 404): left.append(f"person {person}: delete {status} {detail}")
    print(f"==> cleanup: {len(areas)} area(s) and {len(people)} person(s) deleted from the relay" if not left else
          f"==> cleanup left {len(left)} thing(s) on the relay", flush=True)
    return left


def staging_admin(token_file=STAGING_ADMIN_TOKEN_FILE):
    """(base URL, token, proxy process) for staging's admin port, or a reason."""
    token = os.environ.get("ARRAY_RELAY_ADMIN_TOKEN", "").strip()
    if not token and token_file.exists(): token = token_file.read_text().strip()
    if not token: return None, f"no admin token (set ARRAY_RELAY_ADMIN_TOKEN or write {token_file})"
    port = free_port()
    proxy = subprocess.Popen(["fly", "proxy", f"{port}:9090", "-a", STAGING_APP], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    try: wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, "fly proxy to the staging admin port", 30)
    except Failed:
        proxy.terminate(); return None, "fly proxy to the staging admin port did not come up"
    return (f"http://127.0.0.1:{port}", token, proxy), None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--relay", choices=["staging", "local"], default="staging")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep", action="store_true", help="leave the state folder for inspection")
    parser.add_argument("--hold", type=int, default=0, help="on failure, keep the apps running this many seconds")
    parser.add_argument("--name", default="Journey", help="bundle and state name, e.g. ShareJourney (letters only)")
    parser.add_argument("--cleanup-only", action="store_true",
                        help="delete what a kept state folder (--keep, or a failed run) left on the relay, and nothing else")
    args = parser.parse_args()
    if not args.name.isalpha(): parser.error("--name takes letters only")
    configure(args.name)
    os.chdir(ROOT)
    if args.cleanup_only:
        if args.relay == "local": parser.error("--cleanup-only is for staging; a local relay's data goes with its state folder")
        people = created_people()
        admin, reason = staging_admin()
        if not admin: print(f"cleanup: {reason}; {len(people)} person(s) remain: {people}"); sys.exit(1)
        try: left = clean_relay(admin[0], admin[1], people)
        finally: admin[2].terminate()
        for line in left: print(f"  {line}")
        sys.exit(1 if left else 0)
    if args.relay == "staging" and created_people():
        # A failed earlier run kept its state folder; clean the relay of it
        # before that folder, and the only record of those people, goes.
        print("==> an earlier run left people on staging; cleaning them first", flush=True)
        admin, reason = staging_admin()
        if not admin: print(f"note: cannot clean the earlier run ({reason}); its people stay on staging", flush=True)
        else:
            try: clean_relay(admin[0], admin[1], created_people())
            finally: admin[2].terminate()

    if not args.skip_build:
        # /usr/bin/python3 is an xcrun shim that exports its own SDKROOT; the
        # build lock pins Xcode's SDK only when none is inherited.
        build_env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
        subprocess.run([str(LOCK), "swift", "build", "--product", "continuum-relay"], check=True, env=build_env)
        for bundle_name, bundle_id, _, _ in PEOPLE.values():
            subprocess.run([str(LOCK), "scripts/make-app-bundle.sh", "--configuration", "debug", "--bundle-id", bundle_id,
                            "--name", bundle_name, "--output", str(APPS / f"{bundle_name}.app")], check=True, env=build_env)

    shutil.rmtree(STATE, ignore_errors=True); STATE.mkdir(parents=True)
    relay, env_extra, endpoint, local_admin = None, {}, STAGING, None
    if args.relay == "local":
        port, admin_port, data = free_port(), free_port(), STATE / "relay"; data.mkdir()
        local_admin = (f"http://127.0.0.1:{admin_port}", base64.urlsafe_b64encode(os.urandom(32)).decode())
        renv = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE") and not k.startswith(("APNS_", "RELAY_"))}
        renv.update(RELAY_HOST="127.0.0.1", PORT=str(port), RELAY_ADMIN_PORT=str(admin_port), RELAY_ADMIN_TOKEN=local_admin[1],
                    RELAY_DATABASE_PATH=str(data / "relay.sqlite"), RELAY_MASTER_KEY=base64.b64encode(os.urandom(32)).decode(),
                    RELAY_COLLABORATION_DATABASE_PATH=str(data / "collaboration.sqlite"),
                    RELAY_COLLABORATION_MASTER_KEY=base64.b64encode(os.urandom(32)).decode())
        binary = str(ROOT / ".build/debug/continuum-relay")
        relay = subprocess.Popen([binary], env=renv, stdout=open(data / "relay.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, "local relay ready", 15)
        endpoint = f"http://127.0.0.1:{port}"
        env_extra["CONTINUUM_COLLABORATION_ENDPOINT"] = endpoint
    print(f"==> relay {endpoint}")

    people = []
    failures = []
    def check(condition, label, detail=""):
        print(("PASS" if condition else "FAIL") + f" journey: {label}" + ("" if condition or not detail else f" — {detail}"), flush=True)
        if not condition: failures.append(label)
    def eventually(probe, label, timeout, detail=lambda: ""):
        try: wait_for(probe, label, timeout); check(True, label); return True
        except Failed: check(False, label, detail()); return False
    try:
        host = Person("a", endpoint, env_extra); guest = Person("b", endpoint, env_extra)
        people = [host, guest]
        print(f"==> {host.name} (host) and {guest.name} (guest) are running, off every display")

        tile = host.call("spawnAgent")["tile"]
        before = host.call("snapshot", tile=tile)

        # 1. Header share.
        s1 = host.call("headerShare", tile=tile)
        after1 = host.call("snapshot", tile=tile)
        check(s1["presented"] and s1["anchoredToTile"], "step 1: the header Share opens the popover, anchored to T")
        check(not s1["published"] and after1["tileWorld"] == before["tileWorld"] and after1["tileZone"] == before["tileZone"],
              "step 1: nothing is published, and T has not moved")

        # 2. Sidebar share.
        s2 = host.call("sidebarShare", tile=tile)
        check(s2["presented"] and s2["anchoredToTile"] and s2["target"] == [tile],
              "step 2: the sidebar row's Share opens the same popover, anchored to T on the canvas", json.dumps(s2))

        # 3. Copy.
        shared = share_step(host, tile)
        url = shared["url"]
        after3 = host.call("snapshot", tile=tile)
        check(bool(url) and shared["pasteboard"] == url, "step 3: a link is on the pasteboard")
        check(shared["areaItems"] == ["agentObservation"], "step 3: the relay area holds exactly one item, T's agent observation",
              json.dumps(shared["areaItems"]))
        check(after3["tileWorld"] == before["tileWorld"] and after3["tileZone"] == before["tileZone"],
              "step 3: T's zone and world frame are unchanged", f"{before['tileWorld']} -> {after3['tileWorld']}")
        check(after3["zones"] == before["zones"] and after3["sharedZoneSessions"] == 0, "step 3: the workspace document has no new zone")
        check(after3.get("tab") == "Yours · shared", "the host's tile says it is shared", after3.get("tab", ""))

        # 4. Open on the guest.
        g0 = guest.call("snapshot")
        opened = guest.call("open", url=url, timeout=150)
        g4 = guest.call("snapshot")
        new_kinds = list(g4["tileKinds"]); [new_kinds.remove(k) for k in g0["tileKinds"] if k in new_kinds]
        check(opened["outcome"] == "opened" and new_kinds == ["sharedAgent"] and len(g4["sharedAgentTiles"]) == 1,
              "step 4: exactly one new tile appears, of kind sharedAgent", json.dumps(new_kinds))
        world, zone_rect = g4.get("sharedTileWorld") or {}, g4.get("sharedTileZoneWorld") or {}
        check(g4.get("sharedTileZone") == g4["armedZone"] and world and zone_rect and inside(world, zone_rect)
              and intersects(world, g4["visibleWorld"]),
              "step 4: in the guest's armed zone, its world frame inside that zone and in view",
              f"zone {g4.get('sharedTileZone')} armed {g4['armedZone']} frame {world} zone {zone_rect} view {g4['visibleWorld']}")
        check(g4["zones"] == g0["zones"] and g4["sharedZoneSessions"] == 0, "step 4: no zone is created")
        check(g4["agentRecords"] == g0["agentRecords"], "step 4: no AgentRecord is created on the guest",
              f"{g0['agentRecords']} -> {g4['agentRecords']}")
        check(host.name in g4.get("sharedTab", ""), "step 4: the tile's tab names the host", g4.get("sharedTab", ""))

        token = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
        # 5. Guest prompts.
        # The fake answers a plain prompt with one whole message, which the
        # Claude runner (partial-message deltas) does not render. TOOL and
        # TOOLFAIL turns render a tool step on both sides: that is the reply.
        p1 = f"TOOL guest asks {token}"
        guest.call("prompt", text=p1)
        def host_shows_guest():
            t = host.call("transcript", tile=tile)
            text, cards = t.get("host", ""), t.get("hostSenderCards", [])
            if p1 in text and any(guest.name in c for c in cards) and "[Bash]" in text.split(p1, 1)[1]: return t
        def guest_shows_own():
            shared = guest.call("transcript").get("shared", "")
            if f"You: {p1}" in shared and "Command" in shared.split(p1, 1)[1]: return shared
        eventually(host_shows_guest, f"step 5: the host transcript tags P1 with {guest.name}'s name, and the reply follows",
                   DELIVERY_WINDOW, lambda: json.dumps(host.call("transcript", tile=tile))[-500:])
        eventually(guest_shows_own, "step 5: the guest's transcript tags P1 \"You\", and the reply follows", DELIVERY_WINDOW,
                   lambda: json.dumps(guest.call("transcript"))[-500:])
        host_text = host.call("transcript", tile=tile).get("host", "")
        check(host_text.count(p1) == 1, "step 5: the host runs exactly one turn for P1", f"seen {host_text.count(p1)} times")

        # 6. Host prompts.
        p2 = f"TOOLFAIL host says {token}"
        # After P1's turn, so P2 is an ordinary send, not a steer (the fakes
        # answer a steer only with text; --collaboration-full-access-check
        # witnesses steers reaching teammates).
        wait_for(lambda: not host.call("transcript", tile=tile).get("agentRunning", True), "P1's turn finished", 30)
        host.call("prompt", tile=tile, text=p2)
        def guest_shows_host():
            shared = guest.call("transcript").get("shared", "")
            if f"{host.name}: {p2}" in shared and "Command" in shared.split(p2, 1)[1]: return shared
        eventually(guest_shows_host, f"step 6: the guest shows P2 tagged {host.name}, then its reply", DELIVERY_WINDOW,
                   lambda: json.dumps(guest.call("transcript"))[-500:])
        def host_shows_both():
            text = host.call("transcript", tile=tile).get("host", "")
            if p1 in text and p2 in text and "[Bash]" in text.split(p2, 1)[1]: return text
        eventually(host_shows_both, "the host's tile still shows P1, then its own P2 and the reply", 30,
                   lambda: host.call("transcript", tile=tile).get("host", "")[-300:])

        # 7. A retry runs once.
        retry = guest.call("resendLast")
        time.sleep(6)
        host_text = host.call("transcript", tile=tile).get("host", "")
        check(retry["sameCommand"] and retry["firstID"] == retry["secondID"] and host_text.count(p1) == 1,
              "step 7: resending P1 with the same request ID runs nothing new; the receipt matches the first",
              f"{json.dumps(retry)}; P1 seen {host_text.count(p1)} times")

        # 8. Controls.
        g8 = guest.call("snapshot"); h8 = host.call("snapshot", tile=tile)
        controls = [c.lower() for c in g8.get("sharedControls", [])]
        check(not any("stop" in c or "approve" in c or "allow" in c or "deny" in c for c in controls)
              and "Approvals stay with its owner" in g8.get("controlsText", ""),
              "step 8: the guest has no Stop and no approval control", json.dumps(controls))
        check(h8.get("hostIsManagedAgentTile") and h8.get("hostHasRunner"),
              "step 8: the host's own agent tile, with its runner, keeps Stop and approvals")

        # 9. Access list and Remove.
        access = host.call("access", tile=tile)
        check(any(guest.name in r and "full access" in r for r in access["rows"]) and access["removeButtons"] >= 1,
              f"step 9: the host's popover lists {guest.name} with \"full access\" and Remove", json.dumps(access["rows"]))
        h9 = host.call("snapshot", tile=tile)
        check(h9.get("tab") == f"Yours · shared with {guest.name}", "the host's tab names who it is shared with", h9.get("tab", ""))
        host.call("remove")
        eventually(lambda: "stopped" in guest.call("snapshot").get("sharedState", ""),
                   "step 9: within the window the guest's tile shows the stopped state", ACCESS_WINDOW,
                   lambda: json.dumps(guest.call("snapshot"))[-400:])
        g9 = guest.call("snapshot")
        check(f"{host.name} stopped sharing" in g9.get("sharedFooter", ""), "step 9: it says the host stopped sharing",
              g9.get("sharedFooter", ""))
        p_refused = f"PLAIN refused {token}"
        refused = guest.call("promptDirect", text=p_refused)
        time.sleep(4)
        host_text = host.call("transcript", tile=tile).get("host", "")
        check(refused["outcome"] == "refused" and p_refused not in host_text,
              "step 9: a guest prompt is refused, and nothing runs on the host", json.dumps(refused))

        # 10. Works once.
        fresh = host.call("newLink", tile=tile, previous=url)
        check(fresh["lifetime"] == "once", "step 10: the host re-shares with a Works once link")
        rejoined = guest.call("open", url=fresh["url"], timeout=150)
        g10 = guest.call("snapshot")
        check(rejoined["outcome"] == "opened" and len(g10["sharedAgentTiles"]) == 1 and "live" in g10.get("sharedState", ""),
              "step 10: the guest joins again, into the same tile, live", json.dumps({k: g10.get(k) for k in ("sharedAgentTiles", "sharedState")}))
        third = Person("c", endpoint, env_extra); people.append(third)
        refusal = third.call("open", url=fresh["url"], expectTile=False, timeout=150)
        t10 = third.call("snapshot")
        check(refusal["outcome"] != "opened" and not t10["sharedAgentTiles"],
              f"step 10: a third app opening the same link is refused", json.dumps(refusal))
        third.quit(); people.remove(third)

        # 11. Host offline.
        host.quit()
        quit_at = time.monotonic()
        eventually(lambda: "offline" in guest.call("snapshot").get("sharedState", ""),
                   "step 11: within the liveness window the guest's tile shows the offline state", LIVENESS_WINDOW,
                   lambda: json.dumps(guest.call("snapshot"))[-400:])
        print(f"    offline shown {time.monotonic() - quit_at:.1f} s after the host quit")
        g11 = guest.call("snapshot")
        check(g11.get("sharedOutlineDashed") and f"{host.name}'s Mac is offline" in g11.get("sharedFooter", ""),
              "step 11: dimmed, with a dashed edge and the offline footer", g11.get("sharedFooter", ""))
        p3 = f"TOOL while away {token}"
        guest.call("prompt", text=p3)
        g11b = guest.call("snapshot")
        check("Queued" in g11b.get("controlsText", ""), "step 11: a guest prompt is accepted as queued", g11b.get("controlsText", ""))
        host.launch()
        def host_ran_queued():
            text = host.call("transcript", tile=tile).get("host", "")
            if p3 in text and "[Bash]" in text.split(p3, 1)[1]: return text
        eventually(host_ran_queued, "step 11: the relaunched host runs the queued prompt", DELIVERY_WINDOW + 30,
                   lambda: json.dumps(host.call("transcript", tile=tile))[-500:])
        time.sleep(4)
        host_text = host.call("transcript", tile=tile).get("host", "")
        check(host_text.count(p3) == 1, "step 11: exactly once", f"seen {host_text.count(p3)} times")
        eventually(lambda: "live" in guest.call("snapshot").get("sharedState", ""), "step 11: the guest's tile is live again",
                   DELIVERY_WINDOW, lambda: json.dumps(guest.call("snapshot"))[-400:])

        # 12. Guest relaunch.
        before12 = guest.call("snapshot")
        guest.quit(); guest.launch()
        eventually(lambda: "live" in guest.call("snapshot").get("sharedState", ""), "step 12: after relaunch the tile reconnects",
                   DELIVERY_WINDOW, lambda: json.dumps(guest.call("snapshot"))[-400:])
        after12 = guest.call("snapshot")
        check(after12["sharedAgentTiles"] == before12["sharedAgentTiles"] and after12.get("sharedTileWorld") == before12.get("sharedTileWorld"),
              "step 12: the tile comes back at the same world frame", f"{before12.get('sharedTileWorld')} -> {after12.get('sharedTileWorld')}")
        guest.quit(); people.remove(guest)
        # Another install that knows this root's workspace but has no
        # collaboration account: the guest's app state without its account
        # list or credential vault. (A fresh install has its own workspace, whose
        # zones do not include the tile's, and leaves the tile alone entirely.)
        second_root = STATE / "b-second-install"
        shutil.copytree(guest.root / "support", second_root / "support",
                        ignore=shutil.ignore_patterns("collaboration-support"), symlinks=True)
        second = Person("b", endpoint, env_extra, folder="b-second-install", project=guest.project); people.append(second)
        def placeholder():
            snap = second.call("snapshot")
            if snap.get("sharedPlaceholder"): return snap
        eventually(placeholder, "step 12: a second install on the guest's root with no account shows the placeholder", 30,
                   lambda: json.dumps(second.call("snapshot"))[-400:])
        s12 = second.call("snapshot")
        check(s12["agentRecords"] == 0 and "sharedAgent" in s12["tileKinds"] and "managedAgent" not in s12["tileKinds"]
              and host.name in s12.get("sharedPlaceholder", ""),
              "step 12: not a broken agent: no record, still a sharedAgent tile, naming whose it is", s12.get("sharedPlaceholder", ""))
        check(not s12.get("sharedHasSession"), "step 12: and it opens no connection without the account")

        if after3["sharedZoneSessions"]:
            for sender, receiver in [(guest, host), (host, guest)]:
                direction = f"{sender.name} -> {receiver.name}"
                median, final = latency(sender, receiver, direction)
                check(median is not None and median <= MEDIAN_BUDGET_MS, f"{direction}: median cursor delay within {MEDIAN_BUDGET_MS} ms",
                      f"median {median}")
                check(final is not None and final <= FINAL_BUDGET_MS, f"{direction}: the final cursor position lands within {FINAL_BUDGET_MS} ms",
                      f"final {final}")
        else:
            print("NOTE journey: no cursor leg: mode A shares one agent with no zone, and the spec gives it no cursors")
        try: host.call("revoke")
        except Failed as error: print(f"note: revoking the link failed: {error}")
    except Failed as error:
        failures.append(str(error)); print(f"FAIL journey: {error}", flush=True)
    finally:
        if failures and args.hold: print(f"==> holding the apps for {args.hold} s"); time.sleep(args.hold)
        for person in people:
            try: person.call("quit", timeout=10)
            except Exception: pass
        time.sleep(1)
        for bundle_name, _, _, _ in PEOPLE.values():
            out = subprocess.run(["pgrep", "-f", f"{APPS / (bundle_name + '.app')}/Contents/MacOS/"], capture_output=True, text=True).stdout
            for pid in out.split():
                try: os.kill(int(pid), 9)
                except OSError: pass
        for folder in STATE.glob("*"):
            subprocess.run(["pkill", "-f", str(folder / "bin")], capture_output=True)
            if (folder / "tmux").exists():
                subprocess.run(["tmux", "kill-server"], env={**{k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")},
                               "TMUX_TMPDIR": str(folder / "tmux")}, capture_output=True)
        # Delete what this run created on the relay, apps already quit so
        # nothing re-creates it. A run that cannot is a failed run.
        people = created_people()
        if local_admin: admin, reason = (*local_admin, None), None
        else: admin, reason = staging_admin()
        if not admin:
            failures.append("cleanup"); print(f"FAIL journey: cleanup: {reason}; {len(people)} person(s) remain: {people}", flush=True)
        else:
            try: left = clean_relay(admin[0], admin[1], people)
            except OSError as error: left = [f"admin port unreachable: {error}"]
            finally:
                if admin[2]: admin[2].terminate()
            check(not left, "cleanup: the relay holds none of this run's people or areas", "; ".join(left))
            if left: print(f"==> rerun with --cleanup-only --name {args.name} once fixed; the state folder is kept", flush=True)
        if relay: relay.terminate()
        if not failures and not args.keep: shutil.rmtree(STATE, ignore_errors=True)
        elif failures: print(f"==> logs kept in {STATE}/*/app.log")
    if failures:
        print(f"Multiplayer journey: {len(failures)} failed: {failures}")
        sys.exit(1)
    print("Multiplayer journey passed")


if __name__ == "__main__":
    main()
