#!/usr/bin/env python3
"""Two real Array apps, one shared agent, on a real relay. The multiplayer gate.

Two dev-channel bundles with their own identities ("Array Journey A/B" in
~/array-scratch/apps), app-support dirs, project roots, credential files and
tmux namespaces, both launched in the background, their windows parked off
every display. Each is driven through `MultiplayerDriver` (a mailbox), and every
step is the production path a click takes:

  1. the host spawns a managed agent (on the check fake CLIs, no real model)
  2. the host shares it: the Share popover's Copy mints a link   [share_step]
  3. the guest opens the link
  4. the guest prompts the agent from the shared view's composer
  5. both transcripts show the guest's prompt with the guest's name, and the reply
  6. the host prompts from the tile's composer; the guest sees it with the
     host's name, and the reply
  7. a guest pointer stroke reaches the host within the latency budget, and the
     reverse; the latency numbers are printed

  scripts/check-multiplayer-journey.py                  # staging relay (default)
  scripts/check-multiplayer-journey.py --relay local    # a local continuum-relay from this tree
  scripts/check-multiplayer-journey.py --skip-build     # reuse the bundles

Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
the default tmux socket, a real CLI login or the Keychain, and never takes focus.
"""
from __future__ import annotations
import argparse, base64, json, os, random, shutil, socket, statistics, string, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = Path(subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()).parent / ".worktrees/.locks/app-build.sh"
STATE = Path.home() / "array-scratch/mp-journey"
APPS = Path.home() / "array-scratch/apps"
STAGING = "https://arrayapp-relay-staging.fly.dev"
PEOPLE = {"a": ("Array Journey A", "dev.arrayapp.macos.mp-journey-a", "Avery", "host"),
          "b": ("Array Journey B", "dev.arrayapp.macos.mp-journey-b", "Blake", "guest")}
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
        time.sleep(0.2)
    raise Failed(f"timeout: {label}")


class Person:
    def __init__(self, side, endpoint, env_extra):
        self.side = side
        self.bundle_name, self.bundle_id, self.name, self.role = PEOPLE[side]
        self.app = APPS / f"{self.bundle_name}.app"
        self.root = STATE / side
        self.mailbox = self.root / "mailbox"
        self.next = 1
        for sub in ("project", "support", "tmux", "mailbox", "exchange"): (self.root / sub).mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        config = {"label": side.upper(), "role": self.role, "endpoint": endpoint, "enrollmentCode": "",
                  "root": str(self.root), "exchange": str(self.root / "exchange"), "areaLabel": "", "side": "left",
                  "driver": str(self.mailbox), "name": self.name}
        (self.root / "preview.json").write_text(json.dumps(config))
        subprocess.run(["defaults", "delete", self.bundle_id], capture_output=True)
        env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE", "ARRAY_AGENT_ID")}
        args = ["open", "-n", "-g",
                "--env", f"CONTINUUM_PROJECT_ROOT={self.root / 'project'}",
                "--env", f"CONTINUUM_APP_SUPPORT={self.root / 'support'}",
                "--env", f"CONTINUUM_MULTIPLAYER_PREVIEW={self.root / 'preview.json'}",
                "--env", f"TMUX_TMPDIR={self.root / 'tmux'}"]
        for key, value in env_extra.items(): args += ["--env", f"{key}={value}"]
        args += ["--stdout", str(self.root / "app.log"), "--stderr", str(self.root / "app.log"),
                 str(self.app), "--args", "-ApplePersistenceIgnoreState", "YES"]
        subprocess.run(args, env=env, check=True)

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


def share_step(host, tile):
    """The share, as one swappable step: tiles in, a link out. The share
    redesign replaces the driver's `share` op (MultiplayerDriver.share) and,
    if its gesture differs, this function; the rest of the journey stays."""
    slug = "journey-" + "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(8))
    return host.call("share", tiles=[tile], slug=slug)["url"]


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--relay", choices=["staging", "local"], default="staging")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep", action="store_true", help="leave the state folder for inspection")
    parser.add_argument("--hold", type=int, default=0, help="on failure, keep both apps running this many seconds")
    args = parser.parse_args()
    os.chdir(ROOT)

    if not args.skip_build:
        # /usr/bin/python3 is an xcrun shim that exports its own SDKROOT; the
        # build lock pins Xcode's SDK only when none is inherited.
        build_env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
        subprocess.run([str(LOCK), "swift", "build", "--product", "continuum-relay"], check=True, env=build_env)
        for bundle_name, bundle_id, _, _ in PEOPLE.values():
            subprocess.run([str(LOCK), "scripts/make-app-bundle.sh", "--configuration", "debug", "--bundle-id", bundle_id,
                            "--name", bundle_name, "--output", str(APPS / f"{bundle_name}.app")], check=True, env=build_env)

    shutil.rmtree(STATE, ignore_errors=True); STATE.mkdir(parents=True)
    relay, env_extra, endpoint = None, {}, STAGING
    if args.relay == "local":
        def free_port():
            with socket.socket() as s: s.bind(("127.0.0.1", 0)); return s.getsockname()[1]
        port, data = free_port(), STATE / "relay"; data.mkdir()
        renv = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE") and not k.startswith(("APNS_", "RELAY_"))}
        renv.update(RELAY_HOST="127.0.0.1", PORT=str(port), RELAY_ADMIN_PORT=str(free_port()),
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
    try:
        host = Person("a", endpoint, env_extra); guest = Person("b", endpoint, env_extra)
        people = [host, guest]
        host.ready(); guest.ready()
        print(f"==> {host.name} (host) and {guest.name} (guest) are running, off every display")

        tile = host.call("spawnAgent")["tile"]
        url = share_step(host, tile)
        check(bool(url), f"{host.name} shared the agent and got a link")
        guest.call("open", url=url, timeout=120)
        check(True, f"{guest.name} opened the link and sees the shared agent")

        token = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
        guest_prompt = f"TOOL guest asks {token}"
        guest.call("prompt", text=guest_prompt)

        def host_shows_guest():
            t = host.call("transcript", tile=tile)
            host_text = t.get("host", ""); cards = t.get("hostSenderCards", [])
            if guest_prompt in host_text and any(guest.name in c for c in cards) and "[Bash]" in host_text.split(guest_prompt, 1)[1]: return t
        def guest_shows_own():
            t = guest.call("transcript")
            shared = t.get("shared", "")
            if f"You: {guest_prompt}" in shared and "Command" in shared.split(guest_prompt, 1)[1]: return t
        for label, probe in [(f"the host's tile shows {guest.name}'s prompt as {guest.name}'s card, then the agent's reply", host_shows_guest),
                             (f"{guest.name}'s shared view shows 'You: <prompt>', then the agent's reply", guest_shows_own)]:
            try: wait_for(probe, label, 45); check(True, label)
            except Failed:
                seen = host.call("transcript", tile=tile) if probe is host_shows_guest else guest.call("transcript")
                check(False, label, "last seen " + json.dumps(seen)[-500:])

        host_prompt = f"TOOLFAIL host says {token}"
        # The guest's turn ends first, so this is an ordinary send with a reply
        # of its own. A prompt typed mid-turn is a steer: the fakes answer a
        # steer only with text these runners do not render, and teammates
        # seeing a steer is witnessed in --collaboration-full-access-check.
        wait_for(lambda: not host.call("transcript", tile=tile).get("agentRunning", True), "the guest's turn finished", 30)
        host.call("prompt", tile=tile, text=host_prompt)
        def guest_shows_host():
            shared = guest.call("transcript").get("shared", "")
            if f"{host.name}: {host_prompt}" in shared and "Command" in shared.split(host_prompt, 1)[1]: return shared
        label = f"{guest.name}'s shared view shows '{host.name}: <prompt>', then the agent's reply"
        try: wait_for(guest_shows_host, label, 45); check(True, label)
        except Failed: check(False, label, "last seen " + json.dumps(guest.call("transcript"))[-500:])
        label = f"the host's tile still shows {guest.name}'s prompt, then its own prompt and the reply"
        def host_shows_both():
            t = host.call("transcript", tile=tile); text = t.get("host", "")
            if guest_prompt in text and host_prompt in text and "[Bash]" in text.split(host_prompt, 1)[1]: return t
        try: wait_for(host_shows_both, label, 30); check(True, label)
        except Failed: check(False, label, "last seen " + json.dumps(host.call("transcript", tile=tile))[-500:])

        for sender, receiver in [(guest, host), (host, guest)]:
            direction = f"{sender.name} -> {receiver.name}"
            median, final = latency(sender, receiver, direction)
            check(median is not None and median <= MEDIAN_BUDGET_MS, f"{direction}: median cursor delay within {MEDIAN_BUDGET_MS} ms",
                  f"median {median}")
            check(final is not None and final <= FINAL_BUDGET_MS, f"{direction}: the final cursor position lands within {FINAL_BUDGET_MS} ms",
                  f"final {final}")
        try: host.call("revoke")
        except Failed as error: print(f"note: revoking the link failed: {error}")
    except Failed as error:
        failures.append(str(error)); print(f"FAIL journey: {error}", flush=True)
    finally:
        if failures and args.hold: print(f"==> holding both apps for {args.hold} s"); time.sleep(args.hold)
        for person in people:
            try: person.call("quit", timeout=10)
            except Exception: pass
        time.sleep(1)
        for person in people:
            for pid in person.pids():
                try: os.kill(pid, 9)
                except OSError: pass
            subprocess.run(["pkill", "-f", str(person.root / "bin")], capture_output=True)
            if (person.root / "tmux").exists():
                subprocess.run(["tmux", "kill-server"], env={**{k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")},
                               "TMUX_TMPDIR": str(person.root / "tmux")}, capture_output=True)
        if relay: relay.terminate()
        if not failures and not args.keep: shutil.rmtree(STATE, ignore_errors=True)
        elif failures: print(f"==> logs kept in {STATE}/{{a,b}}/app.log")
    if failures:
        print(f"Multiplayer journey: {len(failures)} failed: {failures}")
        sys.exit(1)
    print("Multiplayer journey passed")


if __name__ == "__main__":
    main()
