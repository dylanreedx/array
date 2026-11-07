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
("Acceptance test"): share one agent. Before them, `kinds_journey` shares
every other tile kind the same way (`.plans/105-collaboration/SHARE-KINDS.md`):
a note edited by both, a live file, a live diff, a localhost browser streamed
as pictures and clicked by the guest, a public browser that loads on the guest,
and a terminal shared after its warning as a read-only mirror.

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
   8. no guest control can stop, approve, compact or change the host's agent; the host keeps them
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

`--mode terminal` shares one terminal (`.plans/114-terminal-sharing/README.md`):
the host's tmux runs in its own namespace, and the journey measures and
asserts what reaches the guest: the screen a late joiner lands on, a coloured
line in the host's palette, a typed command's latency, a 30/s redraw, 400
ordered lines, a 100,000-line flood, a full-screen program, vim and top as
stills, read-only input, and Stop sharing from the host's Live badge.

`--mode b` runs mode B instead: the portal (`.plans/105-collaboration/PORTAL-CONTRACT.md`).

   B1. the Share tool over an agent, two notes, a public and a localhost
       browser and a terminal: the popover lists them, the terminal marked
       private
   B2. Copy: no tile moved, no zone; the relay holds the agent, the notes and
       both browsers, and no terminal data
   B3. the guest opens it: one sharedPortal tile in the armed zone; item frames
       match the host's relative world frames within 1 pt at the portal's scale
   B4. the host moves a note: the portal follows; a private tile dragged into
       the region publishes nothing until "Add to share" is pressed
   B5. the host edits a note: it shows in the portal; the guest cannot edit it
   B6. the public browser loads its URL; the localhost one is a "Still"; the
       terminal is its "stays on" card
   B7. Open beside: a sharedAgent tile beside the portal; mode A steps 5-8
       pass through it
   B8. cursors both ways over the shared agent; the guest pans and zooms
       without moving the host's tiles, and follows the host
   B9. revoke: the portal and the agent beside it stop; nothing new arrives
  B10. the host quits: the portal dims, dashed; it recovers on relaunch
  B11. the guest relaunches: the portal is back at the same world frame

  scripts/check-multiplayer-journey.py --relay local    # a local continuum-relay from this tree
  scripts/check-multiplayer-journey.py                  # staging relay
  scripts/check-multiplayer-journey.py --skip-build     # reuse the bundles
  scripts/check-multiplayer-journey.py --relay local --only kinds --name ShareKinds   # the kinds alone
  scripts/check-multiplayer-journey.py --relay local --mode terminal --name ShareTerminal   # a shared terminal

Every run deletes the people and areas it created on the relay, through the
relay's admin port (`RELAY_ADMIN_TOKEN`). A local relay gets its own token. On
staging the admin port is reached with `fly proxy`, and the token comes from
ARRAY_RELAY_ADMIN_TOKEN or ~/.config/array/relay-staging-admin-token (0600).
A run that cannot clean up fails and prints what it left behind.

Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
the default tmux socket, a real CLI login or the Keychain, and never takes focus.
"""
from __future__ import annotations
import argparse, base64, json, os, random, shutil, socket, statistics, string, subprocess, sys, tempfile, time, urllib.error, urllib.request
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
# --tmux: terminals keep tmux session persistence, as a person's app does.
# Each app's tmux lives in its own TMUX_TMPDIR under the state folder.
TMUX_PERSISTENCE = False
# --old-guest NAME: the bundles a 0.7.38 build made under that journey name
# ("Array NAME B.app"), opened as a person whose Array predates live tiles.
OLD_GUEST = None
TMUX_DIRS: list = []


def tmux_env(folder):
    """The environment for one app's own tmux server: never the default socket."""
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    env["TMUX_TMPDIR"] = str(folder)
    return env


def tmux_socket(folder):
    """The socket a tmux client in this namespace reaches, or "" with no server.
    A server held on a consent prompt answers nothing: then the socket file it
    made is the answer."""
    try:
        out = subprocess.run(["tmux", "display-message", "-p", "#{socket_path}"], env=tmux_env(folder),
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0: return out.stdout.strip()
    except subprocess.TimeoutExpired:
        pass
    found = list(Path(folder).glob("tmux-*/default"))
    return str(found[0]) if found else ""


def stop_tmux_namespace(folder):
    """Ends every tmux process of this namespace, and nothing else's: a held
    server cannot answer kill-server, so its processes are matched by their
    TMUX_TMPDIR and stopped."""
    try: subprocess.run(["tmux", "kill-server"], env=tmux_env(folder), capture_output=True, timeout=10)
    except subprocess.TimeoutExpired: pass
    pids = subprocess.run(["pgrep", "-x", "tmux"], capture_output=True, text=True).stdout.split()
    for pid in pids:
        environment = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout.split()
        if f"TMUX_TMPDIR={folder}" in environment:
            try: os.kill(int(pid), 9)
            except (OSError, ValueError): pass


def configure(name: str):
    global STATE, PEOPLE
    slug = name.lower()
    STATE = Path.home() / f"array-scratch/mp-{slug}"
    PEOPLE = {"a": (f"Array {name} A", f"dev.arrayapp.macos.mp-{slug}-a", "Avery", "host"),
              "b": (f"Array {name} B", f"dev.arrayapp.macos.mp-{slug}-b", "Blake", "guest"),
              "c": (f"Array {name} C", f"dev.arrayapp.macos.mp-{slug}-c", "Casey", "guest")}
    if OLD_GUEST:
        PEOPLE["o"] = (f"Array {OLD_GUEST} B", f"dev.arrayapp.macos.mp-{OLD_GUEST.lower()}-b", "Olive", "guest")
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
# Terminal budgets on a local relay (`.plans/114-terminal-sharing/README.md`).
ECHO_MEDIAN_MS, ECHO_MAX_MS, STEADY_RATE, FLOOD_BEHIND_SECONDS = 120, 400, 20, 1.0


class Failed(AssertionError):
    pass


# What a guest must never be able to do to the host's agent. Since the guest
# draws the host's chrome (d397bc87) these controls are present but disabled,
# so the journey judges what can be pressed, not which labels exist.
HOST_ONLY_WORDS = ("stop", "approve", "allow", "deny", "compact", "interrupt", "steer",
                   "harness", "model", "reasoning effort", "rename", "workspace tools")


def guest_host_controls(snapshot):
    enabled = [c.lower() for c in snapshot.get("sharedEnabledControls", [])]
    return [c for c in enabled if any(w in c for w in HOST_ONLY_WORDS)]


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
    def __init__(self, side, endpoint, env_extra, folder=None, project=None, tmux=False):
        self.side = side
        # Terminal mode: tmux on, in this app's own TMUX_TMPDIR (never the
        # default socket), so a shared terminal streams through its pane.
        self.terminal_tmux = tmux
        self.bundle_name, self.bundle_id, self.name, self.role = PEOPLE[side]
        self.app = APPS / f"{self.bundle_name}.app"
        self.root = STATE / (folder or side)
        self.project = project or (self.root / "project")
        self.endpoint, self.env_extra = endpoint, env_extra
        self.mailbox = self.root / "mailbox"
        # With --tmux, a fresh /tmp namespace for this app's tmux server.
        self.tmux = Path(tempfile.mkdtemp(prefix="mpj-tmux-", dir="/tmp")) if TMUX_PERSISTENCE else self.root / "tmux"
        if TMUX_PERSISTENCE: TMUX_DIRS.append(self.tmux)
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
        if self.terminal_tmux:
            # The app's tmux server, started here first with no config: a user's
            # ~/.tmux.conf can block a new server's first client (a plugin
            # manager's `run`), and this namespace's server is always new.
            tenv = {**env, "TMUX_TMPDIR": str(self.tmux)}
            # A relaunch finds it running already.
            if subprocess.run(["tmux", "has-session", "-t", "journey-hold"], env=tenv, capture_output=True, timeout=10).returncode != 0:
                subprocess.run(["tmux", "-f", "/dev/null", "new-session", "-d", "-s", "journey-hold"], env=tenv, check=True, timeout=10)
            sock = subprocess.run(["tmux", "display-message", "-p", "-t", "journey-hold", "#{socket_path}"], env=tenv,
                                  capture_output=True, text=True, timeout=10).stdout.strip()
            if not os.path.realpath(sock).startswith(os.path.realpath(self.tmux) + "/"):
                raise Failed(f"the journey's tmux server is outside its namespace: {sock}")
        args = ["open", "-n", "-g",
                "--env", f"CONTINUUM_PROJECT_ROOT={self.project}",
                "--env", f"CONTINUUM_APP_SUPPORT={self.root / 'support'}",
                "--env", f"CONTINUUM_MULTIPLAYER_PREVIEW={self.root / 'preview.json'}",
                "--env", f"TMUX_TMPDIR={self.tmux}"]
        for key, value in self.env_extra.items(): args += ["--env", f"{key}={value}"]
        args += ["--stdout", str(self.root / "app.log"), "--stderr", str(self.root / "app.log"),
                 str(self.app), "--args", "-ApplePersistenceIgnoreState", "YES"]
        if self.terminal_tmux:
            args += ["-continuum.terminal.tmux.enabled", "YES", "-continuum.terminal.tmux.path", ""]
        elif not TMUX_PERSISTENCE:
            # As the matrix's app legs run: no tmux, so a terminal tile
            # (mode B shares one as a private card) restores without one.
            args += ["-continuum.terminal.tmux.enabled", "NO", "-continuum.terminal.tmux.path", ""]
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

    def post(self, op, timeout=90, **fields):
        """Sends `op` now and returns a function that waits for its answer."""
        n = self.next; self.next += 1
        request = self.mailbox / f"req-{n}.json"
        tmp = request.with_suffix(".tmp"); tmp.write_text(json.dumps({"op": op, **fields})); tmp.rename(request)
        def answer():
            response = self.mailbox / f"res-{n}.json"
            wait_for(response.exists, f"{self.name}: {op} answered", timeout)
            value = json.loads(response.read_text())
            if not value.get("ok"): raise Failed(f"{self.name}: {op} failed: {value.get('error')}")
            return value
        return answer

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


def near(a, b, tolerance=1.0):
    return all(abs(a[k] - b[k]) <= tolerance for k in ("x", "y", "width", "height") if k in a and k in b)


def mode_b(host, guest, check, eventually, endpoint, env_extra, people):
    """Mode B of SHARE-REDESIGN.md: the portal. Steps B1-B11 (see the docstring)."""
    token = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
    public_url, local_url = "https://example.com/", "http://127.0.0.1:9/"
    spawned = host.call("spawnPortalTiles", notes=[f"First note {token}", f"Second note {token}"],
                        publicURL=public_url, localURL=local_url)
    agent, notes = spawned["agent"], spawned["notes"]
    public_browser, local_browser, terminal = spawned["publicBrowser"], spawned["localBrowser"], spawned["terminal"]
    tiles = [agent, *notes, public_browser, local_browser, terminal]
    before_world = {t: host.call("snapshot", tile=t)["tileWorld"] for t in tiles}
    h0 = host.call("snapshot")

    # B1a (.plans/114). The popover's terminal row opts a terminal in, one
    # press for the warning and a second to share it live; nothing is shared
    # until Copy, and this popover is dismissed without one.
    row = host.call("portalShare", tiles=tiles, copy=False, dismiss=True, liveTerminals=[terminal], timeout=150).get("optIn", {})
    check(row.get("firstTitle") == "Share live…" and "secrets" in row.get("warning", "") and row.get("secondTitle") == "Share anyway"
          and not row.get("optedAfterFirst") and row.get("opted") and row.get("thenTitle") == "Keep private"
          and any(r.startswith("Terminal") and r.endswith("· Live") for r in row.get("rowsAfter", [])),
          "B1a: a terminal row's Share live… warns on the first press and opts it in on the second", json.dumps(row))
    check(not host.call("hostPortal").get("hosting"), "B1a: a dismissed popover shares nothing")

    # B1. The Share tool over the six tiles.
    slug = "portal-" + "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(8))
    shared = host.call("portalShare", tiles=tiles, slug=slug, timeout=150)
    rows = shared["rows"]
    terminal_rows = [r for r in rows if r.startswith("Terminal")]
    check(shared["title"] == "Share this part of your canvas" and sorted(shared["target"]) == sorted(tiles),
          "B1: the Share tool's marquee selects the six tiles and opens the popover", json.dumps(shared["target"]))
    check(len(rows) == 6 and len(terminal_rows) == 1 and terminal_rows[0].endswith("Stays private")
          and not any("Stays private" in r for r in rows if not r.startswith("Terminal")),
          "B1: the popover lists everything, the terminal marked \"Stays private\"", json.dumps(rows))

    # B2. Copy.
    url = shared["url"]
    check(bool(url) and shared["pasteboard"] == url, "B2: a link is on the pasteboard")
    after_world = {t: host.call("snapshot", tile=t)["tileWorld"] for t in tiles}
    h2 = host.call("snapshot")
    check(after_world == before_world, "B2: no tile has moved", json.dumps({t: (before_world[t], after_world[t]) for t in tiles if before_world[t] != after_world[t]}))
    check(h2["zones"] == h0["zones"] and h2["sharedZoneSessions"] == 0, "B2: no zone was created")
    hp = wait_for(lambda: (lambda v: v if v.get("hosting") and v.get("revisions") is not None else None)(host.call("hostPortal")), "host portal", 30)
    by_tile = {s["tile"]: s for s in hp["shared"]}
    kinds = sorted(i["kind"] for i in hp["areaItems"])
    check(kinds.count("agentObservation") == 1 and kinds.count("artifact") == 6,
          "B2: the relay holds the agent, two notes, two browsers, the terminal's card and the manifest", json.dumps(kinds))
    term_object = by_tile[terminal]["object"]
    check(hp["revisions"].get(term_object, -1) == 0 and not hp["payloadPaths"].get(term_object),
          "B2: the relay carries no terminal data", json.dumps({"revisions": hp["revisions"].get(term_object), "paths": hp["payloadPaths"].get(term_object)}))
    def content_on_relay():
        v = host.call("hostPortal")
        if all(v["revisions"].get(by_tile[t]["object"], 0) >= 1 for t in [*notes, public_browser, local_browser]): return v
    eventually(content_on_relay, "B2: the notes and both browsers have their content on the relay", 30,
               lambda: json.dumps(host.call("hostPortal").get("revisions")))
    check(any(p.endswith("portal.json") for p in hp["payloadPaths"].get(hp["area"], [])),
          "B2: the manifest is on the relay", json.dumps(hp["payloadPaths"].get(hp["area"])))

    # B3. Open on the guest.
    g0 = guest.call("portal")
    opened = guest.call("open", url=url, expectPortal=True, items=6, timeout=150)
    g3 = guest.call("portal")
    new_kinds = list(g3["tileKinds"]); [new_kinds.remove(k) for k in g0["tileKinds"] if k in new_kinds]
    check(opened["outcome"] == "opened" and new_kinds == ["sharedPortal"] and len(g3["portalTiles"]) == 1,
          "B3: exactly one new tile appears, of kind sharedPortal", json.dumps(new_kinds))
    world, zone_rect = g3.get("portalWorld") or {}, g3.get("portalZoneWorld") or {}
    check(g3.get("portalZone") == g3["armedZone"] and world and zone_rect and inside(world, zone_rect) and intersects(world, g3["visibleWorld"]),
          "B3: in the guest's armed zone, inside it and in view", f"{world} in {zone_rect}, view {g3['visibleWorld']}")
    check(g3["zones"] == g0["zones"] and g3["agentRecords"] == g0["agentRecords"], "B3: no zone and no AgentRecord on the guest")
    check(f"{host.name}'s canvas" in g3.get("portalTab", "") and "Live" in g3.get("portalTab", ""),
          "B3: the header names the host's canvas, live", g3.get("portalTab", ""))
    origin, camera = hp["origin"], g3["camera"]
    items = {i["object"]: i for i in g3["items"]}
    mismatches = []
    for t in tiles:
        obj, w = by_tile[t]["object"], after_world[t]
        expected_area = {"x": w["x"] - origin["x"], "y": w["y"] - origin["y"], "width": w["width"], "height": w["height"]}
        expected_shown = {k: v * camera["zoom"] for k, v in {"x": expected_area["x"] - camera["x"], "y": expected_area["y"] - camera["y"],
                                                               "width": w["width"], "height": w["height"]}.items()}
        item = items.get(obj)
        if not item or not near(item.get("area", {}), expected_area, 0.5) or not near(item.get("shown", {}), expected_shown, 1.0):
            mismatches.append({"tile": t, "item": item and {k: item.get(k) for k in ("area", "shown")}, "expected": expected_shown})
    check(not mismatches, "B3: item frames match the host's relative world frames, within 1 pt at the portal's scale", json.dumps(mismatches)[:600])

    def item_of(tile, snap=None):
        snap = snap or guest.call("portal")
        return next((i for i in snap.get("items", []) if i["object"] == by_tile[tile]["object"]), {})

    # B4. The host moves a note; a private tile dragged in publishes nothing.
    note_area = item_of(notes[0], g3)["area"]
    host.call("moveTile", tile=notes[0], dx=120.0, dy=40.0)
    eventually(lambda: near(item_of(notes[0]).get("area", {}), {**note_area, "x": note_area["x"] + 120, "y": note_area["y"] + 40}, 0.5),
               "B4: the portal's note moves by the same relative amount", DELIVERY_WINDOW, lambda: json.dumps(item_of(notes[0]).get("area")))
    late = host.call("spawnNote", title=f"Late note {token}")["tile"]
    region = {"x": min(w["x"] for w in after_world.values()), "y": min(w["y"] for w in after_world.values())}
    moved = host.call("moveTileTo", tile=late, x=region["x"] + 30, y=region["y"] + 30)
    time.sleep(5)
    h4 = host.call("hostPortal"); g4 = guest.call("portal")
    check(len(h4["areaItems"]) == len(hp["areaItems"]) and len(g4["items"]) == 6,
          "B4: a private tile dragged into the region publishes nothing; the portal is unchanged",
          f"relay {len(h4['areaItems'])} items, portal {len(g4['items'])}")
    check(moved.get("addPill", "").startswith("Add to share"), "B4: the host is offered \"Add to share\" on it", moved.get("addPill", ""))
    host.call("addToShare", tile=late)
    eventually(lambda: any(i["title"] == f"Late note {token}" for i in guest.call("portal").get("items", [])),
               "B4: \"Add to share\" adds it to the portal", DELIVERY_WINDOW, lambda: json.dumps([i["title"] for i in guest.call("portal").get("items", [])]))

    # B5. The host edits a note.
    edited = f"Edited on the host {token}"
    host.call("editNote", tile=notes[1], text=edited)
    eventually(lambda: edited in item_of(notes[1]).get("facts", {}).get("text", ""), "B5: the host's edit shows in the portal",
               DELIVERY_WINDOW, lambda: json.dumps(item_of(notes[1]).get("facts")))
    check(item_of(notes[1]).get("facts", {}).get("editable") == "false", "B5: the guest has no way to edit it",
          json.dumps(item_of(notes[1]).get("facts")))

    # B6. Browsers and the terminal.
    pub = item_of(public_browser).get("facts", {}); loc = item_of(local_browser).get("facts", {}); term = item_of(terminal).get("facts", {})
    check(pub.get("mode") == "live" and pub.get("url") == public_url, "B6: the public browser loads the same URL on the guest", json.dumps(pub))
    check(loc.get("mode") == "still" and loc.get("badge") == "Still", "B6: the localhost browser is a still marked \"Still\"", json.dumps(loc))
    check(term.get("message") == f"Terminal stays on {host.name}'s Mac", "B6: the terminal shows its \"stays on\" card", json.dumps(term))

    # B6b (.plans/114). A terminal opted in with "Add to share", pressed twice
    # past its warning, streams live inside the portal, like a terminal shared
    # on its own. The terminal above, never opted in, stays a card.
    live = host.call("spawnKind", kind="terminal")["tile"]
    eventually(lambda: host_pane_text(host, live) is not None, "B6b: the new terminal runs in the host's own tmux namespace", 45)
    host.call("termSend", tile=live, text="exec env -i HOME=\"$HOME\" TERM=\"$TERM\" PATH=/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin "
              "PS1='avery$ ' /bin/bash --noprofile --norc")
    eventually(lambda: (host_pane_text(host, live) or "").rstrip().endswith("avery$"), "B6b: a plain bash runs in it", 20)
    host.call("termSend", tile=live, text=f"printf '\033[31mP%s\033[0m\n' ORTAL-{token}")
    host.call("moveTileTo", tile=live, x=region["x"] + 60, y=region["y"] + 60)
    opted = host.call("addTerminalToShare", tile=live)
    check(opted.get("firstTitle", "").startswith("Add to share") and "secrets" in opted.get("warningTitle", "") and not opted.get("addedAfterFirst"),
          "B6b: a terminal's Add to share warns on the first press and shares on the second", json.dumps(opted))
    hb = host.call("hostPortal")
    live_object = next((x["object"] for x in hb["shared"] if x["tile"] == live), None)
    check(any(i["object"] == live_object and i["kind"] == "liveTile" for i in hb["areaItems"]),
          "B6b: the opted-in terminal is a live tile in the portal's area", json.dumps(hb["areaItems"]))
    def live_item():
        return next((i for i in guest.call("portal").get("items", []) if i["object"] == live_object), {}).get("facts", {})
    eventually(lambda: live_item().get("mode") == "live" and f"PORTAL-{token}" in live_item().get("text", ""),
               "B6b: the guest's portal shows the opted-in terminal live, with what ran before it was added", DELIVERY_WINDOW,
               lambda: json.dumps(live_item())[-400:])
    marker_sent = time.time()
    host.call("termSend", tile=live, text=f"printf 'L%s\n' IVE-{token}")
    eventually(lambda: f"LIVE-{token}" in live_item().get("text", ""), "B6b: new output reaches the portal's terminal", DELIVERY_WINDOW,
               lambda: json.dumps(live_item())[-400:])
    print(f"PORTAL TERMINAL: new output in the guest's portal {1000 * (time.time() - marker_sent):.0f} ms after the keystrokes "
          f"(polled through the driver's mailbox, so an upper bound); lane {live_item().get('lane')}")
    f = live_item()
    check(f.get("grid") and f.get("grid") == f.get("hostGrid"), "B6b: the portal's terminal has the host's grid", json.dumps(f)[-300:])
    check(same_screen(f.get("text"), host_pane_text(host, live)), "B6b: the portal's terminal is the host's pane, line for line",
          json.dumps([screen_lines(f.get("text")), screen_lines(host_pane_text(host, live))]))
    check(item_of(terminal).get("facts", {}).get("message") == f"Terminal stays on {host.name}'s Mac",
          "B6b: the terminal that was never opted in is still its card", json.dumps(item_of(terminal).get("facts")))

    # B6c (.plans/114). The opted-in terminal carries the host's Live badge;
    # its Stop sharing takes out that terminal only: the guest's item is its
    # card again, and the rest of the portal keeps going.
    h = host.call("termHost", tile=live)
    check(h.get("badge") == "Live" and h.get("stopControl"), "B6c: the opted-in terminal carries the Live badge with Stop sharing",
          json.dumps({k: h.get(k) for k in ("badge", "stopControl", "tab")}))
    check(not host.call("termHost", tile=terminal).get("badge"), "B6c: the terminal that was never opted in has no Live badge")
    stop = host.call("termStopSharing", tile=live)
    check(stop.get("pressReachedStopAtRest"), f"B6c: Stop sharing takes its own press at the resting zoom ({stop.get('restingZoom', 0):.2f})",
          json.dumps(stop))
    hs = host.call("hostPortal")
    card_object = next((x["object"] for x in hs["shared"] if x["tile"] == live), None)
    check(card_object and card_object != live_object and not any(i["kind"] == "liveTile" for i in hs["areaItems"])
          and any(i["object"] == card_object and i["kind"] == "artifact" for i in hs["areaItems"]),
          "B6c: Stop sharing replaces its live tile with a card on the relay", json.dumps(hs["areaItems"]))
    def stopped_view():
        snap = guest.call("portal")
        objects = {i["object"]: i for i in snap.get("items", [])}
        card = objects.get(card_object, {}).get("facts", {})
        return live_object not in objects and card.get("message") == f"Terminal stays on {host.name}'s Mac"
    eventually(stopped_view, "B6c: the guest's item goes back to the \"stays on\" card", DELIVERY_WINDOW,
               lambda: json.dumps([i for i in guest.call("portal").get("items", []) if i["object"] in (live_object, card_object)])[:500])
    check(not host.call("termHost", tile=live).get("badge"), "B6c: the host's Live badge is gone")
    eventually(lambda: "streamTap" not in host.call("termHost", tile=live), "B6c: this Mac stops reading the terminal's pane", DELIVERY_WINDOW,
               lambda: json.dumps({k: v for k, v in host.call("termHost", tile=live).items() if k.startswith("stream")})[:300])
    after_stop = f"Edited after one terminal stopped {token}"
    host.call("editNote", tile=notes[1], text=after_stop)
    eventually(lambda: after_stop in item_of(notes[1]).get("facts", {}).get("text", ""), "B6c: the rest of the portal keeps going: a note edit still arrives",
               DELIVERY_WINDOW, lambda: json.dumps(item_of(notes[1]).get("facts")))
    g6 = guest.call("portal")
    check(item_of(agent, g6) and "Live" in g6.get("portalTab", "") and item_of(public_browser, g6).get("facts", {}).get("mode") == "live",
          "B6c: the agent, the browsers and the portal stay live", json.dumps({"tab": g6.get("portalTab"), "agent": bool(item_of(agent, g6))}))

    # B7. Open beside.
    beside = guest.call("openBeside", kind="agent")
    g7 = guest.call("portal")
    bw, pw = g7.get("besideWorld") or {}, g7.get("portalWorld") or {}
    # Beside: in the portal's zone, next to it and not over it. The canvas's
    # own layout picks the side.
    gap = lambda a, b: max(b["x"] - (a["x"] + a["width"]), a["x"] - (b["x"] + b["width"]), b["y"] - (a["y"] + a["height"]), a["y"] - (b["y"] + b["height"]))
    check(bool(beside.get("tile")) and len(g7["sharedAgentTiles"]) == 1 and g7.get("besideZone") == g7.get("portalZone")
          and bw and not intersects(bw, pw) and gap(bw, pw) <= 200,
          "B7: a sharedAgent tile appears beside the portal", f"beside {bw}, portal {pw}")
    p1 = f"TOOL guest asks {token}"
    guest.call("prompt", text=p1)
    def host_shows_guest():
        t = host.call("transcript", tile=agent)
        text, cards = t.get("host", ""), t.get("hostSenderCards", [])
        if p1 in text and any(guest.name in c for c in cards) and "[Bash]" in text.split(p1, 1)[1]: return t
    eventually(host_shows_guest, f"B7 (A5): the host runs P1, tagged {guest.name}", DELIVERY_WINDOW,
               lambda: json.dumps(host.call("transcript", tile=agent))[-400:])
    eventually(lambda: (lambda sh: f"You: {p1}" in sh and "Command" in sh.split(p1, 1)[1])(guest.call("transcript").get("shared", "")),
               "B7 (A5): the guest's tile tags P1 \"You\", with the reply", DELIVERY_WINDOW, lambda: guest.call("transcript").get("shared", "")[-300:])
    check(host.call("transcript", tile=agent).get("host", "").count(p1) == 1, "B7 (A5): exactly one turn for P1")
    wait_for(lambda: not host.call("transcript", tile=agent).get("agentRunning", True), "P1's turn finished", 30)
    p2 = f"TOOLFAIL host says {token}"
    host.call("prompt", tile=agent, text=p2)
    eventually(lambda: (lambda sh: f"{host.name}: {p2}" in sh and "Command" in sh.split(p2, 1)[1])(guest.call("transcript").get("shared", "")),
               f"B7 (A6): the guest shows P2 tagged {host.name}, with the reply", DELIVERY_WINDOW,
               lambda: guest.call("transcript").get("shared", "")[-300:])
    retry = guest.call("resendLast"); time.sleep(6)
    check(retry["sameCommand"] and retry["firstID"] == retry["secondID"] and host.call("transcript", tile=agent).get("host", "").count(p1) == 1,
          "B7 (A7): a resend with the same request ID runs nothing new", json.dumps(retry))
    g8 = guest.call("snapshot"); usable = guest_host_controls(g8)
    check("sharedEnabledControls" in g8 and not usable,
          "B7 (A8): no guest control can stop, approve, compact or change the host's agent",
          json.dumps({"usable": usable, "enabled": g8.get("sharedEnabledControls")}))
    agent_item = item_of(agent)
    check(agent_item.get("facts", {}).get("editable") == "false" and "Open beside" in agent_item.get("hover", []),
          "B7: inside the portal the agent is watched, not typed into; it offers Open beside", json.dumps(agent_item.get("hover")))

    # B8. Cursors, the guest's own camera, and Follow.
    hovered = host.call("hostHover", tile=agent)["area"]
    def guest_sees_host_cursor():
        for peer in guest.call("portal").get("peers", []):
            c = peer.get("cursor")
            if c and abs(c["x"] - hovered["x"]) <= 2 and abs(c["y"] - hovered["y"]) <= 2: return peer
    eventually(guest_sees_host_cursor, "B8: the host's cursor over the shared agent appears in the portal at the mapped point",
               ACCESS_WINDOW, lambda: json.dumps(guest.call("portal").get("peers")))
    pointed = guest.call("portalHover", kind="agent")["area"]
    agent_area = item_of(agent).get("area", {})
    def host_sees_guest_cursor():
        for peer in host.call("hostPortal").get("peers", []):
            c = peer.get("cursor")
            if c and abs(c["x"] - pointed["x"]) <= 2 and abs(c["y"] - pointed["y"]) <= 2 \
               and agent_area["x"] <= c["x"] <= agent_area["x"] + agent_area["width"]: return peer
    eventually(host_sees_guest_cursor, "B8: the guest's cursor inside the portal appears on the host's canvas over the same tile",
               ACCESS_WINDOW, lambda: json.dumps(host.call("hostPortal").get("peers")))
    hw_before = {s["tile"]: s["world"] for s in host.call("hostPortal")["shared"]}
    cam_before = guest.call("portal")["camera"]
    panned = guest.call("portalPan", dx=80.0, dy=40.0, zoom=1.25)["camera"]
    time.sleep(3)
    g8 = guest.call("portal")
    hw_after = {s["tile"]: s["world"] for s in host.call("hostPortal")["shared"]}
    check(panned != cam_before and g8["cameraPersisted"] and abs(g8["cameraPersisted"]["zoom"] - panned["zoom"]) < 1e-6,
          "B8: the guest pans and zooms inside the portal, and it is remembered", f"{cam_before} -> {panned}; saved {g8['cameraPersisted']}")
    check(hw_after == hw_before, "B8: and none of the host's tiles moved")
    guest.call("portalFollow")
    target = {"x": origin["x"] + 100.0, "y": origin["y"] + 60.0}
    host.call("hostCamera", x=target["x"], y=target["y"])
    def follows():
        v, g = host.call("hostPortal")["viewport"], guest.call("portal")
        cam, body = g["camera"], g["bodySize"]
        host_cx = v["x"] - origin["x"] + v["width"] / 2; guest_cx = cam["x"] + body["width"] / cam["zoom"] / 2
        host_cy = v["y"] - origin["y"] + v["height"] / 2; guest_cy = cam["y"] + body["height"] / cam["zoom"] / 2
        if g["following"] and abs(host_cx - guest_cx) <= 4 and abs(host_cy - guest_cy) <= 4: return g
    eventually(follows, "B8: the guest follows the host's view inside the portal", ACCESS_WINDOW,
               lambda: json.dumps({"host": host.call("hostPortal")["viewport"], "guest": guest.call("portal")["camera"]}))

    # B9. Revoke.
    access = host.call("portalAccess", tile=agent)
    check(any(guest.name in r and "full access" in r for r in access["rows"]) and access["area"] == hp["area"],
          "B9: Share on a shared tile opens the portal's popover, listing the guest", json.dumps(access))
    host.call("remove")
    eventually(lambda: "stopped" in guest.call("portal").get("portalState", ""), "B9: the portal shows the stopped state", ACCESS_WINDOW,
               lambda: json.dumps(guest.call("portal").get("portalState")))
    eventually(lambda: "stopped" in guest.call("snapshot").get("sharedState", ""), "B9: so does the agent opened beside it", ACCESS_WINDOW,
               lambda: json.dumps(guest.call("snapshot").get("sharedState")))
    check(f"{host.name} stopped sharing" in guest.call("portal").get("portalFooter", ""), "B9: it says the host stopped sharing",
          guest.call("portal").get("portalFooter", ""))
    after_revoke = f"After revoke {token}"
    host.call("editNote", tile=notes[1], text=after_revoke)
    time.sleep(8)
    check(after_revoke not in item_of(notes[1]).get("facts", {}).get("text", ""), "B9: no further updates arrive")
    fresh = host.call("newLink", tile=agent, previous=url)
    rejoined = guest.call("open", url=fresh["url"], expectPortal=True, items=6, timeout=150)
    g9 = guest.call("portal")
    check(rejoined["outcome"] == "opened" and g9["portalTiles"] == g3["portalTiles"] and "live" in g9.get("portalState", ""),
          "B9: a new link reconnects the same portal", json.dumps({k: g9.get(k) for k in ("portalTiles", "portalState")}))

    # B10. Host offline.
    host.quit()
    eventually(lambda: "offline" in guest.call("portal").get("portalState", ""), "B10: the portal dims when the host's Mac goes offline",
               LIVENESS_WINDOW, lambda: json.dumps(guest.call("portal").get("portalState")))
    g10 = guest.call("portal")
    check(g10.get("portalOutlineDashed") and "offline" in g10.get("portalTab", ""), "B10: with a dashed edge, and its header says so",
          g10.get("portalTab", ""))
    host.launch()
    eventually(lambda: "live" in guest.call("portal").get("portalState", ""), "B10: it recovers when the host relaunches",
               DELIVERY_WINDOW + 30, lambda: json.dumps(guest.call("portal").get("portalState")))
    late_edit = f"Back online {token}"
    host.call("editNote", tile=notes[1], text=late_edit)
    eventually(lambda: late_edit in item_of(notes[1]).get("facts", {}).get("text", ""), "B10: and updates flow again",
               DELIVERY_WINDOW, lambda: json.dumps(item_of(notes[1]).get("facts")))

    # B11. Guest relaunch.
    before11 = guest.call("portal")
    guest.quit(); guest.launch()
    eventually(lambda: "live" in guest.call("portal").get("portalState", ""), "B11: after relaunch the portal reconnects",
               DELIVERY_WINDOW, lambda: json.dumps(guest.call("portal").get("portalState")))
    after11 = guest.call("portal")
    check(after11["portalTiles"] == before11["portalTiles"] and after11.get("portalWorld") == before11.get("portalWorld"),
          "B11: the portal comes back at the same world frame", f"{before11.get('portalWorld')} -> {after11.get('portalWorld')}")
    check(after11.get("cameraPersisted") == before11.get("cameraPersisted"), "B11: with the guest's own camera inside it")
    try: host.call("revoke")
    except Failed as error: print(f"note: revoking the link failed: {error}")


PAGE = """<!doctype html><html><head><title>clicks 0</title><style>
body { margin: 0; font: 16px -apple-system; background: #fff; }
#go { position: absolute; left: 40px; top: 60px; width: 220px; height: 90px; font-size: 22px; }
</style></head><body><h1 style="margin:8px 40px">Journey page %s</h1>
<button id="go" onclick="window.clicks=(window.clicks||0)+1; document.title='clicks '+window.clicks; this.textContent='clicked '+window.clicks;">Press</button>
<div style="height:3000px"></div></body></html>"""


def serve_pages(folder: Path):
    """A localhost page server: an address the guest cannot reach."""
    import http.server, threading, functools
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "page.html").write_text(PAGE % "one")
    (folder / "two.html").write_text(PAGE % "two")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(folder))
    handler.log_message = lambda *a, **k: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def git(project, *args):
    subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "Journey", "GIT_AUTHOR_EMAIL": "journey@example.invalid",
                        "GIT_COMMITTER_NAME": "Journey", "GIT_COMMITTER_EMAIL": "journey@example.invalid"})


def kinds_journey(host, guest, check, eventually, legs=frozenset({"note", "file", "diff", "browser", "public", "terminal", "excluded"}),
                  endpoint=None, env_extra=None, people=None):
    """`.plans/105-collaboration/SHARE-KINDS.md`: every other tile kind, shared
    from its own header Share. For each: the host shares it, the guest sees it,
    a host change reaches the guest, and the guest's action reaches the host
    (a note edit merges both ways, a browser click lands, a terminal is read
    only). Then a selection holding a kind that cannot be shared lists it with
    its reason instead of dropping it."""
    token = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
    project = Path(host.project)
    readme = project / "README.md"
    if not (project / ".git").exists():
        git(project, "init", "-q")
        readme.write_text("# Journey\n\nfirst line\n")
        git(project, "add", "README.md"); git(project, "commit", "-q", "-m", "start")
    pages, port = serve_pages(STATE / "www")
    page = f"http://127.0.0.1:{port}/page.html"

    def guest_kind(kind, **fields):
        return guest.call("guestKind", kind=kind, **fields)
    def opened(url, kind):
        result = guest.call("open", url=url, expectTile=False, timeout=150)
        check(result["outcome"] == "opened", f"{kind}: the guest opens the link", json.dumps(result))
        eventually(lambda: guest_kind(kind).get("present"), f"{kind}: exactly one shared tile lands on the guest's canvas", 60,
                   lambda: json.dumps(guest_kind(kind)))
        g = guest_kind(kind)
        check(host.name in g.get("tab", ""), f"{kind}: its tab names the host", g.get("tab", ""))
        return g
    def shared(tile, kind, **fields):
        s = host.call("shareKind", tile=tile, slug=f"kinds-{kind}-{token}", **fields)
        check(s.get("areaItems") == ["liveTile"], f"{kind}: the relay area holds exactly one live tile", json.dumps(s.get("areaItems")))
        check(s.get("selected") == [tile] and s.get("published") == [tile],
              f"{kind}: what was selected is what was published", json.dumps({k: s.get(k) for k in ("selected", "published")}))
        return s

    note = browser = None
    # Note: both people edit; both edits survive, in one order on both Macs.
    if "note" in legs:
        note = host.call("spawnKind", kind="note", title="Journey note")["tile"]
        host.call("hostKind", tile=note, type=f"Plan {token}: ")
        s = shared(note, "note")
        opened(s["url"], "note")
        host_text = lambda: host.call("hostKind", tile=note)["text"]
        eventually(lambda: guest_kind("note").get("text") == host_text(), "note: the guest sees the host's text", 45,
                   lambda: json.dumps([guest_kind("note").get("text"), host_text()]))
        check(guest_kind("note").get("editable"), "note: the guest can edit it")
        host.call("hostKind", tile=note, type=" host-edit")
        eventually(lambda: "host-edit" in guest_kind("note").get("text", ""), "note: a host edit appears on the guest", 45,
                   lambda: json.dumps(guest_kind("note")))
        guest.call("guestKind", kind="note", type="guest-edit ", at=0)
        eventually(lambda: "guest-edit" in host_text(), "note: a guest edit merges into the host's note", 45,
                   lambda: json.dumps([host_text(), guest_kind("note")]))
        # The same spot, both at once: neither edit is lost.
        at = len(f"Plan {token}")
        guest.call("guestKind", kind="note", type="[G]", at=at + len("guest-edit "))
        host.call("hostKind", tile=note, type="[H]", at=at + len("guest-edit "))
        def converged():
            h, g = host_text(), guest_kind("note").get("text", "")
            if h == g and "[G]" in h and "[H]" in h: return h
        eventually(converged, "note: two edits at the same spot both survive, identically on both Macs", 45,
                   lambda: json.dumps([host_text(), guest_kind("note").get("text")]))

    # File: live, read only on the guest.
    if "file" in legs:
        readme.write_text(f"# Journey\n\nfirst line {token}\n")
        file_tile = host.call("spawnKind", kind="file", path=str(readme))["tile"]
        s = shared(file_tile, "file")
        opened(s["url"], "file")
        eventually(lambda: f"first line {token}" in guest_kind("file").get("text", ""), "file: the guest sees its text", 45,
                   lambda: json.dumps(guest_kind("file")))
        host.call("writeFile", path=str(readme), text=f"# Journey\n\nfirst line {token}\nsaved again {token}\n")
        eventually(lambda: f"saved again {token}" in guest_kind("file").get("text", ""), "file: a save on the host appears on the guest", 45,
                   lambda: json.dumps(guest_kind("file")))
        g = guest.call("guestKind", kind="file", type="typed by guest")
        check(not g.get("editable") and "typed by guest" not in readme.read_text(), "file: the guest cannot change it", json.dumps(g))

    # Diff: re-read as the files change.
    if "diff" in legs:
        readme.write_text(f"# Journey\n\nfirst line {token}\nsaved again {token}\n")
        diff_tile = host.call("spawnKind", kind="diff")["tile"]
        s = shared(diff_tile, "diff")
        opened(s["url"], "diff")
        eventually(lambda: f"+saved again {token}" in guest_kind("diff").get("text", ""), "diff: the guest sees the host's diff", 45,
                   lambda: json.dumps(guest_kind("diff"))[-400:])
        readme.write_text(readme.read_text() + f"diff follows {token}\n")
        eventually(lambda: f"+diff follows {token}" in guest_kind("diff").get("text", ""), "diff: a change on the host re-publishes the diff", 45,
                   lambda: json.dumps(guest_kind("diff"))[-400:])

    # Browser, private: pictures, and the guest's click lands on the host's page.
    if "browser" in legs:
        page = f"http://127.0.0.1:{port}/page.html"
        browser = host.call("spawnKind", kind="browser", url=page)["tile"]
        eventually(lambda: host.call("hostKind", tile=browser, eval="document.title").get("eval") == "clicks 0", "browser: the host's page loads", 45)
        s = shared(browser, "browser (localhost)")
        g = opened(s["url"], "browser")
        eventually(lambda: guest_kind("browser").get("browserMode") == "frames" and guest_kind("browser").get("frameSequence", 0) > 0,
                   "browser (localhost): the guest sees the host's page as pictures", 45, lambda: json.dumps(guest_kind("browser")))
        g = guest_kind("browser")
        check(f"{host.name}'s browser" in g.get("tab", "") and f"{host.name}'s browser" in g.get("caption", ""),
              "browser: it is marked as the host's browser", json.dumps([g.get("tab"), g.get("caption")]))
        first = g.get("frameSequence", 0)
        rect = json.loads(host.call("hostKind", tile=browser, eval="JSON.stringify(document.getElementById('go').getBoundingClientRect())")["eval"])
        guest.call("guestKind", kind="browser", clickPage=[rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2])
        eventually(lambda: host.call("hostKind", tile=browser, eval="document.title").get("eval") == "clicks 1",
                   "browser: the guest's click lands on the host's page", 30,
                   lambda: json.dumps(host.call("hostKind", tile=browser, eval="document.title")))
        eventually(lambda: guest_kind("browser").get("frameSequence", 0) > first, "browser: the host's change reaches the guest as a new picture", 30,
                   lambda: json.dumps(guest_kind("browser")))
        host.call("hostKind", tile=browser, navigate=f"http://127.0.0.1:{port}/two.html")
        eventually(lambda: "two.html" in guest_kind("browser").get("caption", ""), "browser: the guest follows the host's navigation", 30,
                   lambda: json.dumps(guest_kind("browser")))

    # Browser, public: the guest's own browser loads the same URL and follows.
    if "public" in legs:
        public = host.call("spawnKind", kind="browser", url="https://example.com/")["tile"]
        try: wait_for(lambda: "example.com" in host.call("hostKind", tile=public).get("url", ""), "public page", 30); reachable = True
        except Failed: reachable = False
        if reachable:
            s = shared(public, "browser (public)")
            guest.call("open", url=s["url"], expectTile=False, timeout=150)
            def follows(url):
                g = [t for t in [guest_kind("browser")] if t.get("followedURL", "").startswith(url)]
                return g[0] if g and g[0].get("browserMode") == "follow" else None
            eventually(lambda: follows("https://example.com"), "browser (public): the guest's browser loads the same URL", 45,
                       lambda: json.dumps(guest_kind("browser")))
            host.call("hostKind", tile=public, navigate="https://example.org/")
            eventually(lambda: follows("https://example.org"), "browser (public): the guest follows the host's navigation", 45,
                       lambda: json.dumps(guest_kind("browser")))
        else:
            print("NOTE journey: browser (public): no network here, so the public-URL leg did not run")

    # Terminal: an explicit opt-in, then a read-only mirror.
    if "terminal" in legs:
        terminal = host.call("spawnKind", kind="terminal")["tile"]
        eventually(lambda: host.call("hostKind", tile=terminal).get("text", "").strip() != "", "terminal: the host's shell starts", 45)
        if TMUX_PERSISTENCE:
            # Whatever tmux the host started lives in its own /tmp namespace.
            sock = tmux_socket(host.tmux)
            check(not sock or os.path.realpath(sock).startswith(os.path.realpath(str(host.tmux)) + "/"),
                  "terminal: the host's tmux socket is inside its own TMUX_TMPDIR", sock)
        host.call("hostKind", tile=terminal, type=f"echo first-{token}")
        s = host.call("shareKind", tile=terminal, slug=f"kinds-terminal-{token}")
        check("secrets" in s.get("warning", "") and not s.get("publishedAfterFirstPress"),
              "terminal: the first Copy warns that output may contain secrets, and shares nothing", json.dumps(s.get("warning")))
        check(s.get("areaItems") == ["liveTile"] and s.get("published") == [terminal], "terminal: the confirm shares it",
              json.dumps({k: s.get(k) for k in ("areaItems", "published")}))
        opened(s["url"], "terminal")
        eventually(lambda: f"first-{token}" in guest_kind("terminal").get("text", ""), "terminal: the guest sees its output", 45,
                   lambda: json.dumps(guest_kind("terminal"))[-400:])
        host.call("hostKind", tile=terminal, type=f"echo second-{token}")
        eventually(lambda: f"second-{token}" in guest_kind("terminal").get("text", ""), "terminal: new output reaches the guest", 45,
                   lambda: json.dumps(guest_kind("terminal"))[-400:])
        g = guest.call("guestKind", kind="terminal", type=f"echo guest-{token}", appendDirect="terminalInput")
        time.sleep(3)
        check(not g.get("editable") and not g.get("typed"), "terminal: the guest has nowhere to type", json.dumps(g)[-300:])
        check("forbidden" in g.get("direct", "") or "403" in g.get("direct", ""), "terminal: the relay refuses input sent straight at it",
              g.get("direct", ""))
        check(f"guest-{token}" not in host.call("hostKind", tile=terminal).get("text", ""), "terminal: nothing the guest typed reached the host")

    # Kinds that cannot be shared yet are listed, never dropped.
    if "excluded" in legs:
        tree = host.call("spawnKind", kind="fileTree")["tile"]
        note = note or host.call("spawnKind", kind="note", title="Left in")["tile"]
        browser = browser or host.call("spawnKind", kind="browser", url=page)["tile"]
        t = host.call("areaShareTarget", tiles=[tree, note, browser])
        listed = {i[0] for i in t["items"]} | {e[0] for e in t["excluded"]}
        reasons = {e[0]: e[2] for e in t["excluded"]}
        check(listed == {tree, note, browser}, "every selected tile is either shared or listed as left out", json.dumps(t))
        check(bool(reasons.get(tree)), "a file tree is listed as \"can't be shared yet\", with its reason", json.dumps(reasons))
    # A Mac on 0.7.38 opens a live-tile link: it cannot read the area, so the
    # relay refuses it before admitting anyone or spending the link.
    if "oldguest" in legs:
        older = host.call("spawnKind", kind="note", title="For an older Mac")["tile"]
        host.call("hostKind", tile=older, type=f"Hello {token}")
        s = host.call("shareKind", tile=older, slug=f"kinds-old-{token}")
        old = Person("o", endpoint, env_extra); people.append(old)
        refused = old.call("open", url=s["url"], expectTile=False, timeout=150)
        print(f"NOTE journey: 0.7.38 shows: {refused.get('outcome')}")
        check("(426)" in refused.get("outcome", "") and not refused.get("outcome", "").startswith("opened"),
              "0.7.38: the relay refuses its join with 426 before admitting it", refused.get("outcome", ""))
        snap = old.call("snapshot")
        check(not snap.get("sharedAgentTiles") and snap.get("sharedZoneSessions", 0) == 0 and "sharedTile" not in snap.get("tileKinds", []),
              "0.7.38: nothing landed on its canvas", json.dumps({k: snap.get(k) for k in ("tileKinds", "sharedZoneSessions")}))
        state = host.call("linkState", tile=older)
        check(state["phase"].startswith("live") and not state["people"] and state["rows"] == ["active"],
              "0.7.38: the Works once link is not spent, and nobody was admitted", json.dumps(state))
        old.quit(); people.remove(old)
        opened_new = guest.call("open", url=s["url"], expectTile=False, timeout=150)
        eventually(lambda: f"Hello {token}" in guest_kind("note").get("text", ""),
                   "an updated Mac then opens the same link and sees the note", 45, lambda: json.dumps(opened_new))
    pages.shutdown()


def host_pane_text(host, tile):
    """The host's pane as tmux holds it, read in the host app's own tmux
    namespace. The socket is checked to be inside it; the default server is
    never touched."""
    env, root = tmux_env(host.tmux), os.path.realpath(host.tmux)
    for name in (f"array-view-{tile.upper()}", f"array-{tile.upper()}"):
        r = subprocess.run(["tmux", "display-message", "-p", "-t", name, "#{socket_path} #{pane_id}"], env=env, capture_output=True, text=True)
        if r.returncode != 0 or " " not in r.stdout.strip(): continue
        sock, pane = r.stdout.strip().rsplit(" ", 1)
        if not os.path.realpath(sock).startswith(root + "/"): raise Failed(f"tmux socket {sock} is outside {root}")
        # -J: a soft-wrapped line as one line, as a terminal's own text read has it.
        return subprocess.run(["tmux", "capture-pane", "-p", "-J", "-t", pane], env=env, capture_output=True, text=True).stdout
    return None


def screen_lines(text):
    lines = [line.rstrip() for line in (text or "").split("\n")]
    while lines and not lines[-1]: lines.pop()
    return lines


def same_screen(a, b):
    """The same screen, wherever a long line wraps: tmux and Ghostty disagree
    about soft wraps at the screen's top edge, never about what is on it."""
    return "".join(screen_lines(a)) == "".join(screen_lines(b))


def stats(values):
    if not values: return "none"
    ordered = sorted(values)
    return (f"n={len(values)} median {statistics.median(values):.0f} ms, p90 {ordered[int(len(ordered) * 0.9) if len(ordered) > 1 else 0]:.0f} ms, "
            f"min {ordered[0]:.0f} ms, max {ordered[-1]:.0f} ms")


def terminal_journey(host, guest, check, eventually, stills=None):
    """`.plans/114-terminal-sharing/README.md`: a terminal shared with a
    teammate is the host's terminal, drawn on the guest's Mac. The host's
    shell, prompt and palette make the output; only the output travels.
    Measured and asserted through the real relay: the screen a late joiner
    lands on, a coloured line, a full-screen TUI, a steady redraw, an ordered
    stream, a flood, and how late each arrives."""
    token = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
    stills = Path(stills or STATE / "stills"); stills.mkdir(parents=True, exist_ok=True)
    project = Path(host.project)
    (project / "colour.swift").write_text('import Foundation\n\n/// A file for the shared vim still.\nstruct Greeting {\n'
                                          '    let name: String\n    func say() -> String { "Hello, \\(name)" }\n}\n\n'
                                          'let count = 42\nprint(Greeting(name: "Blake").say(), count)\n')
    terminal = host.call("spawnKind", kind="terminal")["tile"]
    eventually(lambda: host.call("termHost", tile=terminal).get("text", "").strip() != "", "terminal: the host's shell starts", 45)
    eventually(lambda: host_pane_text(host, terminal) is not None, "terminal: the host's terminal runs in its own tmux namespace", 30)
    # A known shell: the user's own (plugins, prompt themes) would make the
    # timings and screens theirs, and a plugin can swallow a fast Return.
    host.call("termSend", tile=terminal, text="exec env -i HOME=\"$HOME\" TERM=\"$TERM\" PATH=/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin "
              "PS1='avery$ ' /bin/bash --noprofile --norc")
    eventually(lambda: (host_pane_text(host, terminal) or "").rstrip().endswith("avery$"), "terminal: a plain bash runs in it", 20,
               lambda: json.dumps(screen_lines(host_pane_text(host, terminal))[-3:]))
    # Before the share: what a late joiner must land on.
    host.call("termSend", tile=terminal, text=f"printf 'P%s\\n' RE-{token}")
    s = host.call("shareKind", tile=terminal, slug=f"terminal-{token}")
    check(bool(s.get("warning")) and not s.get("publishedAfterFirstPress"),
          "terminal: the first Copy warns that output may contain secrets, and shares nothing", json.dumps(s.get("warning")))
    check(s.get("areaItems") == ["liveTile"] and s.get("published") == [terminal], "terminal: the confirm shares it",
          json.dumps({k: s.get(k) for k in ("areaItems", "published")}))
    opened_at = time.time()
    result = guest.call("open", url=s["url"], expectTile=False, timeout=150)
    check(result["outcome"] == "opened", "terminal: the guest opens the link", json.dumps(result))
    eventually(lambda: guest.call("termGuest").get("present"), "terminal: one shared terminal lands on the guest's canvas", 60)
    late = guest.call("termWatch", marker=f"PRE-{token}", timeout=45)
    check(late.get("seenAt") is not None, "late joiner: the guest's first picture already holds what ran before the share",
          json.dumps(late)[-300:])
    if late.get("seenAt"): print(f"TERMINAL join: first screen {1000 * (late['seenAt'] - opened_at):.0f} ms after the open began")
    g = guest.call("termGuest")
    check(g.get("tab", "").startswith(f"{host.name}'s Terminal"), "title: the guest's tab reads \"<host>'s Terminal\"", g.get("tab", ""))
    h = host.call("termHost", tile=terminal)
    check(h.get("badge") == "Live", "host: the tile carries a Live badge while shared", json.dumps({k: h.get(k) for k in ("badge", "tab")}))
    check(bool(h.get("stopControl")), "host: the badge offers Stop sharing", json.dumps(h.get("stopControl")))
    print(f"TERMINAL host: published {h.get('published')} states; " + json.dumps({k: v for k, v in h.items() if k.startswith("stream")}))

    # A coloured line, in the host's palette.
    palette = h.get("palette") or []
    red, green = (palette[1], palette[2]) if len(palette) > 2 else ("#cc0000", "#4e9a06")
    sent = host.call("termSend", tile=terminal, text=f"printf '\\033[31mR%s\\033[0m \\033[42;30mG%s\\033[0m\\n' ED-{token} REEN-{token}")["sentAt"]
    seen = guest.call("termWatch", marker=f"RED-{token}", timeout=45)
    check(seen.get("seenAt") is not None, "colour: the coloured line reaches the guest", json.dumps(seen)[-300:])
    time.sleep(0.4)
    g = guest.call("termGuest", still=str(stills / "guest-colour.png"), colours=[red, green])
    host.call("termHost", tile=terminal, still=str(stills / "host-colour.png"))
    pixels = g.get("colourPixels", {})
    print(f"TERMINAL colour: host palette red {red} green {green}; guest pixels {json.dumps(pixels)}; "
          f"arrived {1000 * (seen['seenAt'] - sent):.0f} ms after the keystrokes" if seen.get("seenAt") else "TERMINAL colour: never arrived")
    check(pixels.get(red, 0) > 20 and pixels.get(green, 0) > 200, "colour: the guest draws the line in the host's red and green",
          json.dumps(pixels))
    check(same_screen(g.get("text"), host_pane_text(host, terminal)),
          "screen: the guest's screen is the host's pane, line for line",
          json.dumps([screen_lines(g.get("text")), screen_lines(host_pane_text(host, terminal))]))

    # How late a line is: ten echoes, the guest watching before each is typed.
    delays = []
    for i in range(10):
        watch = guest.post("termWatch", marker=f"Z{i}-{token}", timeout=20)
        sent = host.call("termSend", tile=terminal, text=f"printf 'Z%s\\n' {i}-{token}")["sentAt"]
        seen = watch()
        if seen.get("seenAt"): delays.append(1000 * (seen["seenAt"] - sent))
        time.sleep(0.15)
    print(f"TERMINAL echo latency (keystrokes on the host to the line drawn on the guest): {stats(delays)}")
    check(len(delays) == 10 and statistics.median(delays) <= ECHO_MEDIAN_MS and max(delays) <= ECHO_MAX_MS,
          f"latency: a typed command's output is on the guest within {ECHO_MEDIAN_MS} ms (median) and {ECHO_MAX_MS} ms (max)", stats(delays))

    # A steady redraw: a counter rewritten in place 30 times a second for 3 s.
    record = guest.post("termRecord", seconds=4.0)
    sent = host.call("termSend", tile=terminal, text="for i in $(seq 1 90); do printf 'T%03d\\r' $i; sleep 0.033; done; echo")["sentAt"]
    changes = [t for t in record()["changes"] if t >= sent]
    span = (changes[-1] - changes[0]) if len(changes) > 1 else 0
    rate = (len(changes) - 1) / span if span > 0 else 0
    print(f"TERMINAL steady redraw (30/s on the host): the guest's picture changed {len(changes)} times, {rate:.1f}/s")
    check(rate >= STEADY_RATE, f"smooth: a 30/s redraw changes the guest's picture at least {STEADY_RATE}/s", f"{rate:.1f}/s")

    # In order: 400 numbered lines at ~200 a second, every one in the guest's
    # scrollback, in order.
    sent = host.call("termSend", tile=terminal, text=f"for i in $(seq 1 400); do echo S$i-{token}; sleep 0.004; done; printf 'E%s\\n' ND-{token}")["sentAt"]
    seen = guest.call("termWatch", marker=f"END-{token}", timeout=60)
    g = guest.call("termGuest", scrollback=True)
    numbers = [int(line[1:].split("-")[0]) for line in (g.get("scrollback") or g.get("text", "")).split("\n")
               if line.startswith("S") and line.endswith(f"-{token}") and line[1:].split("-")[0].isdigit()]
    print(f"TERMINAL ordered stream: {len(numbers)} of 400 numbered lines in the guest's scrollback; "
          f"in order: {numbers == sorted(numbers)}; arrived {1000 * (seen['seenAt'] - sent):.0f} ms after the keystrokes" if seen.get("seenAt") else
          f"TERMINAL ordered stream: the end never arrived; {len(numbers)} numbered lines seen")
    check(numbers == list(range(1, 401)), "order: all 400 lines reach the guest, in order, none twice",
          f"{len(numbers)} lines, first {numbers[:5]}, last {numbers[-5:]}")

    # A flood: 100,000 lines as fast as the host can make them.
    before = host.call("termHost", tile=terminal)
    record = guest.post("termRecord", seconds=30.0, marker=f"DONE-{token}", timeout=60)
    sent = host.call("termSend", tile=terminal, text=f"yes LOG-{token} | head -100000; printf 'D%s\\n' ONE-{token}")["sentAt"]
    # How long the host's own terminal takes: the flood runs through its tmux
    # and its Ghostty first, share or no share.
    host_done = wait_for(lambda: f"DONE-{token}" in (host_pane_text(host, terminal) or "") and time.time(), "flood: the host finishes", 60)
    # And how long the host's own terminal tile takes to draw it: what the
    # host sees, and the same app the share runs in.
    host_view_done = wait_for(lambda: f"DONE-{token}" in host.call("termHost", tile=terminal).get("text", "") and time.time(),
                              "flood: the host's tile shows the end", 60)
    recorded = record()
    seen = {"seenAt": recorded.get("seenAt")}
    changes = [t for t in recorded["changes"] if t >= sent]
    after = host.call("termHost", tile=terminal)
    took = (seen["seenAt"] - sent) if seen.get("seenAt") else None
    sent_bytes = (after.get("streamBytesSent") or 0) - (before.get("streamBytesSent") or 0)
    read_bytes = (after.get("streamBytesRead") or 0) - (before.get("streamBytesRead") or 0)
    behind = (seen["seenAt"] - host_done) if seen.get("seenAt") else None
    print(f"TERMINAL flood (yes | head -100000): the host's own pane showed the end {1000 * (host_done - sent):.0f} ms after the keystrokes; "
          f"the host's own tile {1000 * (host_view_done - sent):.0f} ms; the guest {1000 * behind:.0f} ms after the pane"
          if behind is not None else "TERMINAL flood: the guest never showed the end")
    print(f"TERMINAL flood (yes | head -100000): the end reached the guest {1000 * took:.0f} ms after the keystrokes; "
          f"the guest's picture changed {len(changes)} times; host read {read_bytes} bytes and sent {sent_bytes}" if took else
          "TERMINAL flood: the end never arrived")
    print("TERMINAL flood host log: " + json.dumps(after.get("streamLog", [])[-25:]))
    gf = guest.call("termGuest")
    print("TERMINAL flood guest: " + json.dumps({k: gf.get(k) for k in ("lane", "laneFrames", "resets", "gaps", "sequence", "grid", "hostGrid")})
          + " log " + json.dumps((gf.get("log") or [])[-25:]))
    time.sleep(0.5)
    check(behind is not None and behind <= FLOOD_BEHIND_SECONDS,
          f"flood: the end of a 100,000-line flood is on the guest within {FLOOD_BEHIND_SECONDS} s of the host's own terminal", f"{behind}")
    check(read_bytes > 0 and sent_bytes < read_bytes / 4, "flood: the host sends a fraction of what the program wrote (bounded)",
          f"read {read_bytes} sent {sent_bytes}")
    check(same_screen(guest.call("termGuest").get("text"), host_pane_text(host, terminal)),
          "flood: afterwards the guest's screen is the host's pane, line for line",
          json.dumps([screen_lines(guest.call("termGuest").get("text"))[-4:], screen_lines(host_pane_text(host, terminal))[-4:]]))

    # A full-screen program: the alternate screen, positioned and coloured.
    host.call("termSend", tile=terminal, text="printf '\\033[?1049h\\033[2J\\033[3;5H\\033[1;44;37m \\124UI-%s \\033[0m\\033[8;12Hrow8\\033[5;30H' "
              + token + "; sleep 5; printf '\\033[?1049l'")
    seen = guest.call("termWatch", marker=f"TUI-{token}", timeout=45)
    time.sleep(0.4)
    g = guest.call("termGuest")
    check(seen.get("seenAt") is not None and screen_lines(g.get("text")) == screen_lines(host_pane_text(host, terminal)),
          "TUI: the guest shows the full-screen program exactly where the host does",
          json.dumps([screen_lines(g.get("text")), screen_lines(host_pane_text(host, terminal))]))
    eventually(lambda: f"TUI-{token}" not in (host_pane_text(host, terminal) or "TUI-"), "TUI: the program exits on the host", 20)
    time.sleep(0.6)
    check(same_screen(guest.call("termGuest").get("text"), host_pane_text(host, terminal)),
          "TUI: when it exits, the guest's screen returns to the host's shell, line for line",
          json.dumps([screen_lines(guest.call("termGuest").get("text")), screen_lines(host_pane_text(host, terminal))]))
    # Real programs, for the stills: vim with syntax colours, then top.
    host.call("termSend", tile=terminal, text="vim -u NONE -N -c 'syntax on' -c 'set number' colour.swift")
    eventually(lambda: "Greeting" in (host_pane_text(host, terminal) or "") and "~" in (host_pane_text(host, terminal) or ""), "vim: opens on the host", 20)
    time.sleep(1.0)
    guest.call("termGuest", still=str(stills / "guest-vim.png")); host.call("termHost", tile=terminal, still=str(stills / "host-vim.png"))
    check(screen_lines(guest.call("termGuest").get("text")) == screen_lines(host_pane_text(host, terminal)), "vim: the guest's screen is the host's",
          json.dumps([screen_lines(guest.call("termGuest").get("text"))[:4], screen_lines(host_pane_text(host, terminal))[:4]]))
    host.call("termSend", tile=terminal, text=":qa!")
    host.call("termSend", tile=terminal, text="top -s 1 -n 12")
    eventually(lambda: "PID" in (host_pane_text(host, terminal) or ""), "top: runs on the host", 20)
    time.sleep(2.2)
    guest.call("termGuest", still=str(stills / "guest-top.png")); host.call("termHost", tile=terminal, still=str(stills / "host-top.png"))
    host.call("termSend", tile=terminal, text="q", **{"return": False})
    time.sleep(0.8)

    # Typing stays with the host.
    g = guest.call("guestKind", kind="terminal", type=f"echo guest-{token}", appendDirect="terminalInput")
    check(not g.get("editable") and not g.get("typed"), "read only: the guest has nowhere to type", json.dumps(g)[-300:])
    check("forbidden" in g.get("direct", "") or "403" in g.get("direct", ""), "read only: the relay refuses input sent straight at it",
          g.get("direct", ""))
    check(f"guest-{token}" not in (host_pane_text(host, terminal) or ""), "read only: nothing the guest typed reached the host")

    # Stop sharing, from the host's badge.
    try:
        host.call("termStopSharing", tile=terminal)
        eventually(lambda: "stopped" in guest.call("termGuest").get("state", "") or "no longer shared" in guest.call("termGuest").get("tab", ""),
                   "stop: Stop sharing on the host's badge stops the guest's view", 30, lambda: json.dumps(guest.call("termGuest")))
        h = host.call("termHost", tile=terminal)
        check(not h.get("badge"), "stop: the host's badge is gone", json.dumps(h.get("badge")))
    except Failed as error:
        check(False, "stop: Stop sharing on the host's badge stops the guest's view", str(error))
    print(f"==> stills in {stills}")


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
    parser.add_argument("--prepare-only", action="store_true", help="assemble fixtures from prebuilt binaries, then exit")
    parser.add_argument("--keep", action="store_true", help="leave the state folder for inspection")
    parser.add_argument("--hold", type=int, default=0, help="on failure, keep the apps running this many seconds")
    parser.add_argument("--name", default="Journey", help="bundle and state name, e.g. ShareJourney (letters only)")
    parser.add_argument("--mode", choices=["a", "b", "terminal"], default="a",
                        help="a: share one agent; b: the portal; terminal: a shared terminal's stream (.plans/114)")
    parser.add_argument("--stills", help="with --mode terminal: where to write the host's and guest's stills")
    parser.add_argument("--old-guest", default=None,
                        help="journey name of bundles built from 0.7.38 (b0689628); adds the oldguest leg")
    parser.add_argument("--tmux", action="store_true",
                        help="terminals keep tmux persistence, each app in its own TMUX_TMPDIR (never the default socket)")
    parser.add_argument("--no-lock", action="store_true",
                        help="build without the shared build lock: the caller (the matrix) already serialises builds")
    parser.add_argument("--kinds", default="note,file,diff,browser,public,terminal,excluded",
                        help="with --only kinds: which legs, comma-separated")
    parser.add_argument("--only", choices=["all", "agent", "kinds"], default="all",
                        help="agent: mode A's twelve steps; kinds: every other tile kind (SHARE-KINDS.md)")
    parser.add_argument("--cleanup-only", action="store_true",
                        help="delete what a kept state folder (--keep, or a failed run) left on the relay, and nothing else")
    args = parser.parse_args()
    if not args.name.isalpha(): parser.error("--name takes letters only")
    global OLD_GUEST
    OLD_GUEST = args.old_guest
    configure(args.name)
    global TMUX_PERSISTENCE
    TMUX_PERSISTENCE = args.tmux
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

    if args.prepare_only:
        for side, (bundle_name, bundle_id, _, _) in PEOPLE.items():
            if side == "o": continue
            subprocess.run(["scripts/make-app-bundle.sh", "--skip-build", "--configuration", "debug",
                            "--bundle-id", bundle_id, "--name", bundle_name,
                            "--output", str(APPS / f"{bundle_name}.app")], check=True)
        return

    if not args.skip_build:
        # /usr/bin/python3 is an xcrun shim that exports its own SDKROOT; the
        # build lock pins Xcode's SDK only when none is inherited.
        build_env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
        lock = [] if args.no_lock else [str(LOCK)]
        subprocess.run([*lock, "swift", "build", "--product", "continuum-relay"], check=True, env=build_env)
        for side, (bundle_name, bundle_id, _, _) in PEOPLE.items():
            if side == "o": continue
            subprocess.run([*lock, "scripts/make-app-bundle.sh", "--configuration", "debug", "--bundle-id", bundle_id,
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
        host = Person("a", endpoint, env_extra, tmux=args.mode in ("terminal", "b")); guest = Person("b", endpoint, env_extra)
        people = [host, guest]
        print(f"==> {host.name} (host) and {guest.name} (guest) are running, off every display")
        if args.mode == "b":
            mode_b(host, guest, check, eventually, endpoint, env_extra, people)
        if args.mode == "terminal":
            terminal_journey(host, guest, check, eventually, args.stills)
        if args.mode == "a" and args.only in ("all", "kinds"):
            legs = set(args.kinds.split(","))
            if OLD_GUEST: legs.add("oldguest")
            kinds_journey(host, guest, check, eventually, legs, endpoint=endpoint, env_extra=env_extra, people=people)
        if args.mode == "a" and args.only in ("all", "agent"):
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
            usable = guest_host_controls(g8)
            check("sharedEnabledControls" in g8 and not usable,
                  "step 8: no guest control can stop, approve, compact or change the host's agent",
                  json.dumps({"usable": usable, "enabled": g8.get("sharedEnabledControls")}))
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
        for folder in TMUX_DIRS:
            stop_tmux_namespace(folder)
            shutil.rmtree(folder, ignore_errors=True)
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
