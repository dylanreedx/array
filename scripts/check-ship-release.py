#!/usr/bin/env python3
"""Drive the production gate and ship scripts end to end in a disposable repo.

nightly-gate.sh and ship-release.sh run for real against a throwaway git repo
with a bare `origin`; only the expensive or outward tools are doubles: the
matrix, the optimized bundle build, signing/notarization, the bundle audit,
Sparkle's sign_update and gh. The live-feed wait polls a local server that
serves whatever appcast `origin/main` holds, so "deployed" means "pushed".

Witnesses: a green gate builds the candidate for that commit and a re-run
skips; a red gate builds nothing; a held lock skips; a gate covers later
release-path commits and refuses a code commit or bad whitespace; the awake
pass runs at the gated commit; prepare signs the gate's candidate with the
next build, appends the feed and ledger and commits without pushing; publish
uploads both assets, fast-forwards both branches and returns only once the
feed serves the build.
"""
import fcntl
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
REAL = ["nightly-gate.sh", "ship-release.sh", "append-appcast.py", "generate-appcast.sh", "wait-live-release.py"]
for index, arg in enumerate(sys.argv[1:]):  # optional replacements: name=path, for teeth checks
    name, _, path = arg.partition("=")
    REAL[REAL.index(name)] = (name, Path(path))
STUBS = {
    # The matrix double records its mode and answers from the fixture's plan.
    "run-matrix.sh": r'''#!/bin/bash
mode=$1
case $mode in --skip-awake) ;; --awake-only) ;; *) echo "unknown mode $mode" >&2; exit 2 ;; esac
# What a leg would see: the checkout's branch, the CLIs on PATH, inherited gate state.
env | grep '^ARRAY_NIGHTLY_' >> "$SHIP_EVENTS.knobs" || true
name=$(cat "$SHIP_PLAN/build-name"); echo "$(git rev-parse HEAD) $(/bin/ps -axo comm= | grep -c "/$name\$")" >> "$SHIP_EVENTS.busy"
echo "$(git rev-parse HEAD) branch=$(git branch --show-current) first=${PATH%%:*} cli=$(command -v array-fixture-cli || echo none) ref=${ARRAY_NIGHTLY_REF:-unset}" >> "$SHIP_EVENTS.legs"
echo "matrix $mode $(git rev-parse HEAD) owner=${ARRAY_MATRIX_LOCK_OWNER:-none}" >> "$SHIP_EVENTS"
mkdir -p "$ARRAY_MATRIX_RESULTS"
status=$(cat "$SHIP_PLAN/matrix$mode" 2>/dev/null || echo pass)
printf '[{"leg": "--fixture-check", "status": "%s", "seconds": 1}, {"leg": "--load-check", "status": "retry-passed", "seconds": 1}]\n' \
  "$([[ $status == pass ]] && echo pass || echo fail)" > "$ARRAY_MATRIX_RESULTS/results.json"
[[ $status == pass ]]
''',
    "make-app-bundle.sh": r'''#!/bin/bash
echo "bundle $* owner=${ARRAY_RELEASE_LOCK_OWNER:-none}" >> "$SHIP_EVENTS"
out=${@: -1}; mkdir -p "$out/Contents"; git rev-parse HEAD > "$out/Contents/source"
''',
    "release-app.sh": r'''#!/bin/bash
echo "sign $*" >> "$SHIP_EVENTS"
while [[ $# -gt 0 ]]; do case $1 in --bundle) b=$2;; --output-dir) o=$2;; --set-version) v=$2;; esac; shift 2; done
mkdir -p "$o"; cp -R "$b" "$o/Array.app"; head -c 4096 /dev/urandom > "$o/Array-$v.dmg"
''',
    "check-app-bundle.sh": '#!/bin/bash\necho "audit $*" >> "$SHIP_EVENTS"\n',
}
SIGN = '#!/bin/sh\nprintf \'sparkle:edSignature="%s" length="%s"\\n\' "$(head -c 64 /dev/zero | base64)" "$(stat -f %z "$1")"\n'
GH = r'''#!/bin/bash
# Each release is a file listing its uploaded asset names.
echo "gh $*" >> "$SHIP_EVENTS"
release="$SHIP_PLAN/gh-$3"
if [[ $1 == release && $2 == view ]]; then
  [[ -f $release ]] || exit 1; [[ " $* " == *" --json assets "* ]] && cat "$release"; exit 0; fi
if [[ $1 == release && ( $2 == create || $2 == upload ) ]]; then
  for asset in "${@: -2}"; do [[ -s $asset ]] || exit 9; done
  [[ $2 == upload && -f "$SHIP_PLAN/gh-upload-inert" ]] && exit 0  # reports success, uploads nothing
  touch "$release"; for asset in "${@: -2}"; do basename "$asset" >> "$release"; done; fi
'''
def next_release():
    """The next version and build after the real feed this fixture copies, so the
    witness never collides with a release that has already shipped."""
    import re
    import xml.etree.ElementTree as ET
    sp = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = ET.parse(HERE.parent / "website/public/appcast.xml").findall("./channel/item")
    builds = [int(i.findtext(sp + "version")) for i in items if (i.findtext(sp + "version") or "").isdigit()]
    versions = [tuple(map(int, v.split("."))) for v in (i.findtext(sp + "shortVersionString") or "" for i in items)
                if re.fullmatch(r"\d+\.\d+\.\d+", v)]
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch + 1}", f"{major}.{minor}.{patch + 2}", max(builds) + 1


VERSION, OTHER_VERSION, BUILD = next_release()
LEDGER = "# Versioning\n\n| Version | Build | Date | Tag | Notes |\n|---|---|---|---|---|\n| 0.7.50 | 101 | 2026-11-14 | `v0.7.50` | fixture |\n"


def sh(*cmd, cwd=None, env=None, check=True):
    result = subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f"{' '.join(map(str, cmd))} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


class Fixture:
    def __init__(self, temp):
        self.root = Path(temp).resolve()  # /var is /private/var; scripts see the resolved path
        self.origin, self.repo, self.plan = self.root / "origin.git", self.root / "repo", self.root / "plan"
        self.base, self.events = self.root / "gate-base", self.root / "events"
        self.plan.mkdir()
        self.build_name = "array-fixture-build-" + uuid.uuid4().hex[:8]  # a swift-build no other agent runs
        (self.plan / "build-name").write_text(self.build_name)
        sh("git", "init", "-q", "--bare", "-b", "main", str(self.origin))
        sh("git", "init", "-q", "-b", "array/integration", str(self.repo))
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid")):
            sh("git", "-C", str(self.repo), "config", key, value)
        scripts = self.repo / "scripts"
        scripts.mkdir()
        for entry in REAL:
            name, path = entry if isinstance(entry, tuple) else (entry, HERE / entry)
            shutil.copyfile(path, scripts / name)
        for name, text in STUBS.items():
            (scripts / name).write_text(text)
        for path in scripts.iterdir():
            path.chmod(0o755)
        (self.repo / "website/public").mkdir(parents=True)
        shutil.copyfile(HERE.parent / "website/public/appcast.xml", self.repo / "website/public/appcast.xml")
        (self.repo / "docs").mkdir()
        (self.repo / "docs/VERSIONING.md").write_text(LEDGER)
        (self.repo / "ThirdParty/GhosttyKit.xcframework").mkdir(parents=True)
        (self.repo / "ThirdParty/GhosttyKit.xcframework/fixture").write_text("x")
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/App.swift").write_text("let app = 1\n")
        (self.repo / ".gitignore").write_text("qa-runs/\nreleases/\n")
        self.commit("feat(app): fixture app")
        sh("git", "-C", str(self.repo), "remote", "add", "origin", str(self.origin))
        sh("git", "-C", str(self.repo), "push", "-q", "origin", "HEAD:array/integration", "HEAD:main")
        sh("git", "-C", str(self.repo), "branch", "-q", "--set-upstream-to=origin/array/integration")
        bindir = self.root / "bin"
        bindir.mkdir()
        (bindir / "gh").write_text(GH)
        (bindir / "gh").chmod(0o755)
        (self.root / "sign_update").write_text(SIGN)
        (self.root / "sign_update").chmod(0o755)
        clis = self.root / "clis"  # stands in for ~/.local/bin (claude) and the node bin (codex, pi)
        clis.mkdir()
        (clis / "array-fixture-cli").write_text("#!/bin/sh\n")
        (clis / "array-fixture-cli").chmod(0o755)
        self.env = dict(os.environ, PATH=f"{clis}:{os.environ['PATH']}", ARRAY_NIGHTLY_BASE=str(self.base), ARRAY_NIGHTLY_NOTIFY="0",
                        ARRAY_NIGHTLY_BUILD_PROCESS=self.build_name, ARRAY_NIGHTLY_FSEVENTS_CPU_MAX="100000",
                        ARRAY_NIGHTLY_QUIET_POLL_SECONDS="0.1", ARRAY_NIGHTLY_QUIET_MAX_SECONDS="20",
                        ARRAY_MATRIX_LOCK=str(self.root / "matrix.lock"), SHIP_EVENTS=str(self.events),
                        SHIP_PLAN=str(self.plan), SPARKLE_SIGN_UPDATE=str(self.root / "sign_update"),
                        ARRAY_SHIP_GH=str(bindir / "gh"), ARRAY_SHIP_WAIT_SECONDS="20",
                        ARRAY_SHIP_WAIT_INTERVAL="0.2", GIT_AUTHOR_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture",
                        GIT_COMMITTER_EMAIL="fixture@example.invalid")
        for key in ("ARRAY_MATRIX_LOCK_OWNER", "ARRAY_RELEASE_LOCK_OWNER", "ARRAY_MATRIX_LEGS", "ARRAY_NIGHTLY_REF"):
            self.env.pop(key, None)

    def commit(self, message, files=None, push=False):
        for path, text in (files or {}).items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        sh("git", "-C", str(self.repo), "add", "-A")
        sh("git", "-C", str(self.repo), "commit", "-q", "-m", message)
        if push:
            sh("git", "-C", str(self.repo), "push", "-q", "origin", "HEAD:array/integration")
        return sh("git", "-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()

    def run(self, script, *args, env=None):
        return sh("/bin/bash", "scripts/" + script, *args, cwd=self.repo, env=dict(self.env, **(env or {})), check=False)

    def log(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def legs_saw(self):
        path = Path(str(self.events) + ".legs")
        return path.read_text().splitlines() if path.exists() else []

    def summary(self, sha):
        return json.loads((self.base / "results" / sha / "summary.json").read_text())


def expect(condition, message, result=None):
    if not condition:
        detail = f"\n--- exit {result.returncode}\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}" if result else ""
        raise AssertionError(message + detail)


class Feed(http.server.BaseHTTPRequestHandler):
    """arrayapp.dev (whatever origin/main holds) and the GitHub release downloads, on one port."""
    origin = plan = None
    lag, polls = 3, 0  # Vercel deploys late: the first polls after the push get the old feed.
    GITHUB = "https://github.com/dylanreedx/array-releases/releases/download/"

    def do_GET(self):
        Feed.polls += 1
        ref = "main~1" if Feed.polls <= Feed.lag else "main"
        body = sh("git", "--git-dir", str(self.origin), "show", ref + ":website/public/appcast.xml").stdout
        body = body.replace(self.GITHUB, f"http://127.0.0.1:{self.server.server_port}/download/")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_HEAD(self):
        # A download answers only once `gh release create` has uploaded that tag.
        parts = self.path.split("/")
        uploaded = len(parts) == 4 and parts[1] == "download" and (self.plan / f"gh-{parts[2]}").exists()
        self.send_response(200 if uploaded else 404)
        self.end_headers()

    def log_message(self, *args):
        pass


def gate_cases(fx):
    gated = sh("git", "-C", str(fx.repo), "rev-parse", "HEAD").stdout.strip()
    result = fx.run("nightly-gate.sh")
    summary = fx.summary(gated)
    expect(result.returncode == 0 and summary["green"] and summary["candidate"], "green gate builds a candidate", result)
    expect((Path(summary["candidate"]) / "Contents/source").read_text().strip() == gated, "candidate built from the gated commit")
    expect(summary["retry_passed"] == ["--load-check"] and summary["passed"] == 2, f"summary counts retry-passed: {summary}")
    events = fx.log()
    expect(events[0].startswith(f"matrix --skip-awake {gated} owner=") and "owner=none" not in events[0], f"matrix under lock: {events}")
    expect("--configuration release --channel prod" in events[1] and "owner=none" not in events[1], f"release bundle under lock: {events}")
    expect(fx.legs_saw() == [f"{gated} branch=gate/nightly-checkout first=/opt/homebrew/bin cli={fx.root / 'clis/array-fixture-cli'} ref=unset"],
           f"legs run on a named branch, system tools first, with the caller's CLIs: {fx.legs_saw()}")
    print("PASS gate-builds-candidate")

    result = fx.run("nightly-gate.sh")
    expect("already green" in result.stdout and len(fx.log()) == 2, "an already-gated head is skipped", result)
    print("PASS gate-skips-gated-head")

    with open(fx.root / "matrix.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        red_head = fx.commit("feat(app): change code", {"Sources/App.swift": "let app = 2\n"}, push=True)
        result = fx.run("nightly-gate.sh")
    expect(result.returncode == 0 and "lock held" in result.stderr and len(fx.log()) == 2, "a held lock skips", result)
    print("PASS gate-skips-held-lock")

    (fx.plan / "matrix--skip-awake").write_text("fail")
    (fx.base / "checkout/stray-leg-output.png").write_text("x")  # legs leave untracked files
    result = fx.run("nightly-gate.sh")
    red = fx.summary(red_head)
    expect(any(line.startswith(f"matrix --skip-awake {red_head}") for line in fx.log()),
           "untracked leg output does not stop the next gate", result)
    expect(result.returncode == 1 and not red["green"] and not red["candidate"], "a red gate is not green", result)
    expect(not any(line.startswith("bundle") for line in fx.log()[2:]), "a red gate builds no candidate")
    print("PASS red-gate-builds-nothing")

    result = fx.run("nightly-gate.sh", "--ship-base", red_head)
    expect(result.returncode == 1 and "Sources/App.swift" in result.stderr, "a code commit voids the gate", result)
    sh("git", "-C", str(fx.repo), "reset", "-q", "--hard", gated)
    sh("git", "-C", str(fx.repo), "push", "-q", "-f", "origin", "HEAD:array/integration")
    (fx.plan / "matrix--skip-awake").write_text("pass")
    (fx.repo / ".plans").mkdir(exist_ok=True)
    sh("git", "-C", str(fx.repo), "mv", "Sources/App.swift", ".plans/App.swift")
    moved = fx.commit("docs(plans): move the app source")
    result = fx.run("nightly-gate.sh", "--ship-base", moved)
    expect(result.returncode == 1 and "Sources/App.swift" in result.stderr, "a move out of live code voids the gate", result)
    sh("git", "-C", str(fx.repo), "reset", "-q", "--hard", gated)
    spaced = fx.commit("docs(plans): trailing space", {".plans/notes.md": "trailing \n"})
    result = fx.run("nightly-gate.sh", "--ship-base", spaced)
    expect(result.returncode == 1 and "diff --check" in result.stderr, "whitespace errors refuse the gate", result)
    sh("git", "-C", str(fx.repo), "reset", "-q", "--hard", gated)
    head = fx.commit("docs(release): prepare notes", {".plans/notes.md": "release notes\n"}, push=True)
    result = fx.run("nightly-gate.sh", "--ship-base", head)
    base = json.loads(result.stdout or "{}")
    expect(result.returncode == 0 and base.get("gate") == gated and base.get("inert_changes") == [".plans/notes.md"],
           "release-path commits keep the gate", result)
    print("PASS ship-base-inert-only")
    return gated, head


def ship_cases(fx, gated, head):
    notes = fx.root / "notes.md"
    notes.write_text("Faster shipping | fixture.\n\nMore words.\n")
    before = (fx.repo / "website/public/appcast.xml").read_bytes()
    with open(fx.root / "matrix.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = fx.run("ship-release.sh", "--version", VERSION, "--notes", str(notes))
    expect(result.returncode != 0 and "awake group" in result.stderr
           and not any(line.startswith("sign ") for line in fx.log()), "a skipped awake group stops prepare", result)
    shutil.rmtree(fx.repo / f"qa-runs/ship-{VERSION}")
    print("PASS prepare-refuses-skipped-awake")
    result = fx.run("ship-release.sh", "--version", VERSION, "--notes", str(notes))
    events = fx.log()
    expect(result.returncode == 0, "prepare succeeds", result)
    expect(any(line == f"matrix --awake-only {gated} owner=" + line.split("owner=")[-1] and "owner=none" not in line
               for line in events), f"awake group ran at the gated commit: {events}")
    sign = next(line for line in events if line.startswith("sign "))
    expect(f"--bundle {fx.summary(gated)['candidate']}" in sign and f"--set-build {BUILD}" in sign and f"--set-version {VERSION}" in sign,
           f"signs the gate's candidate as build {BUILD}: {sign}")
    expect(any(line.startswith("audit --configuration release --channel prod") for line in events), "bundle audit ran")
    expect(not any(line.startswith(("bundle", "gh release create")) for line in events[2:]), f"prepare compiles and uploads nothing: {events}")
    after = (fx.repo / "website/public/appcast.xml").read_bytes()
    index = after.find(before[:before.find(b"<item>")])
    expect(after.startswith(before[:before.find(b"<item>")]) and after.endswith(before[before.find(b"<item>"):])
           and f"<sparkle:version>{BUILD}</sparkle:version>".encode() in after, "feed gains one item, old bytes intact")
    ledger = (fx.repo / "docs/VERSIONING.md").read_text().splitlines()[-1]
    expect(ledger.startswith(f"| {VERSION} | {BUILD} |") and "Faster shipping \\| fixture." in ledger and gated[:8] in ledger,
           f"ledger row: {ledger}")
    subject = sh("git", "-C", str(fx.repo), "log", "-1", "--format=%s%n%b").stdout.strip()
    parent = sh("git", "-C", str(fx.repo), "rev-parse", "HEAD^").stdout.strip()
    expect(subject == f"chore(release): ship Array {VERSION} (build {BUILD})" and parent == head, f"one local commit: {subject!r}")
    remote = sh("git", "--git-dir", str(fx.origin), "rev-parse", "array/integration").stdout.strip()
    expect(remote == head, "prepare pushes nothing")
    print("PASS prepare-signs-candidate-and-commits")

    result = fx.run("ship-release.sh", "--version", OTHER_VERSION, "--notes", str(notes))
    expect(result.returncode != 0 and "origin/array/integration" in result.stderr, "prepare refuses off the integration head", result)
    print("PASS prepare-refuses-off-head")

    Feed.origin, Feed.plan = fx.origin, fx.plan
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Feed)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    publish_env = dict(ARRAY_SHIP_FEED_URL=f"http://127.0.0.1:{port}/appcast.xml",
                       ARRAY_SHIP_DOWNLOAD_BASE=f"http://127.0.0.1:{port}/download/v{VERSION}/")
    (fx.plan / f"gh-v{VERSION}").write_text("Array.dmg\n")  # an earlier publish died mid-upload
    (fx.plan / "gh-upload-inert").write_text("")
    result = fx.run("ship-release.sh", "--version", VERSION, "--publish", env=publish_env)
    pushed = sh("git", "--git-dir", str(fx.origin), "rev-parse", "array/integration").stdout.strip()
    expect(result.returncode != 0 and f"lacks Array-{VERSION}.dmg" in result.stderr and pushed == head,
           "a release missing an asset is never pushed", result)
    expect(any(line.startswith(f"gh release upload v{VERSION}") and "--clobber" in line for line in fx.log()),
           "a partial release is re-uploaded", result)
    (fx.plan / f"gh-v{VERSION}").unlink()
    (fx.plan / "gh-upload-inert").unlink()
    print("PASS publish-refuses-missing-asset")
    try:
        result = fx.run("ship-release.sh", "--version", VERSION, "--publish", env=publish_env)
    finally:
        server.shutdown()
    local = sh("git", "-C", str(fx.repo), "rev-parse", "HEAD").stdout.strip()
    branches = [sh("git", "--git-dir", str(fx.origin), "rev-parse", ref).stdout.strip() for ref in ("array/integration", "main")]
    create = [line for line in fx.log() if line.startswith(f"gh release create v{VERSION}")]
    expect(result.returncode == 0 and branches == [local, local] and len(create) == 1, "publish pushes and uploads", result)
    expect(create[0].endswith("release/Array.dmg " + str(fx.repo / f"qa-runs/ship-{VERSION}/release/Array-{VERSION}.dmg")),
           f"both assets uploaded: {create}")
    expect("is live" in result.stdout and Feed.polls > Feed.lag and f"has not deployed build {BUILD}" in result.stdout,
           f"publish waits through the deploy lag, then returns ({Feed.polls} feed polls)", result)
    print("PASS publish-waits-for-live-feed")


def quiet_cases(fx):
    """Before the matrix the gate waits for no other build and a calm fseventsd,
    holding the shared lock, for at most the bound; then it proceeds and records it."""
    # Stand-ins run under the build's name: ps reports argv[0], as it does for a
    # real swift-build (a copied platform binary would be killed on launch).
    # A compiling build burns CPU (yes); an idle one sleeps.
    stand_in = lambda: subprocess.Popen([str(fx.root / fx.build_name)], executable="/usr/bin/yes",
                                        stdout=subprocess.DEVNULL)
    idle_stand_in = lambda: subprocess.Popen([str(fx.root / fx.build_name), "60"], executable="/bin/sleep")

    def lock_held_within(seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            with open(fx.root / "matrix.lock", "a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                except BlockingIOError:
                    return True
            time.sleep(0.05)
        return False
    busy = lambda: dict(line.split() for line in Path(str(fx.events) + ".busy").read_text().splitlines())

    build = stand_in()
    head = fx.commit("feat(app): change while another build runs", {"Sources/App.swift": "let app = 5\n"})
    gate = subprocess.Popen(["/bin/bash", "scripts/nightly-gate.sh"], cwd=fx.repo, env=dict(fx.env, ARRAY_NIGHTLY_REF="HEAD"),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    held = lock_held_within(10)
    time.sleep(1.5)
    started_early = head in busy() if Path(str(fx.events) + ".busy").exists() else False
    build.kill(); build.wait()
    output = gate.communicate(timeout=60)[0].decode(errors="replace")
    waited = fx.summary(head).get("contention", {})
    expect(held and not started_early, f"the gate waits for another build while holding the lock (held={held}, "
           f"matrix started early={started_early}): {waited}\n{output[-1500:]}")
    expect(waited.get("quiet") is True and waited["waited_seconds"] >= 1.0 and waited["worst"]["swift_builds"] == 1
           and busy()[head] == "0", f"the matrix starts only once the build is gone: {waited} {busy()}")
    print("PASS gate-waits-for-other-build")

    build = stand_in()
    head = fx.commit("feat(app): change under a build that never ends", {"Sources/App.swift": "let app = 6\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD", ARRAY_NIGHTLY_QUIET_MAX_SECONDS="1.5"))
    build.kill(); build.wait()
    summary = fx.summary(head)
    waited = summary.get("contention", {})
    expect(result.returncode == 0 and summary["candidate"] and waited.get("quiet") is False
           and waited["waited_seconds"] >= 1.5 and waited["last"]["swift_builds"] == 1 and busy()[head] == "1",
           f"past the bound the gate proceeds and records the contention: {waited}", result)
    print("PASS gate-bounded-wait-records-contention")

    head = fx.commit("feat(app): change while fseventsd is over the ceiling", {"Sources/App.swift": "let app = 7\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD", ARRAY_NIGHTLY_FSEVENTS_CPU_MAX="-1",
                                                ARRAY_NIGHTLY_QUIET_MAX_SECONDS="0.5"))
    waited = fx.summary(head).get("contention", {})
    expect(result.returncode == 0 and waited.get("quiet") is False and waited["last"]["swift_builds"] == 0
           and waited["last"]["fseventsd_cpu"] is not None and waited["polls"] > 1,
           f"a busy fseventsd (the real daemon, read through ps) holds the gate: {waited}", result)
    print("PASS gate-waits-for-fseventsd")

    idle = idle_stand_in()
    head = fx.commit("feat(app): change beside an idle build process", {"Sources/App.swift": "let app = 8\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD", ARRAY_NIGHTLY_QUIET_MAX_SECONDS="5"))
    idle.kill(); idle.wait()
    waited = fx.summary(head).get("contention", {})
    expect(result.returncode == 0 and waited.get("quiet") is True and waited["waited_seconds"] < 2
           and waited["last"]["idle_swift_builds"] == 1, f"an idle swift-build does not hold the gate: {waited}", result)
    print("PASS gate-ignores-idle-build")

    head = fx.commit("feat(app): change with a malformed knob", {"Sources/App.swift": "let app = 9\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD", ARRAY_NIGHTLY_QUIET_MAX_SECONDS="nan",
                                                ARRAY_NIGHTLY_QUIET_SAMPLES="abc"))
    waited = fx.summary(head).get("contention", {})
    expect(result.returncode == 0 and len(waited.get("knob_errors", [])) == 2 and waited["limits"]["max_seconds"] == 1800,
           f"bad knobs fall back to defaults and are recorded: {waited}", result)
    knobs = Path(str(fx.events) + ".knobs")
    expect(not (knobs.exists() and knobs.read_text().strip()),
           f"no ARRAY_NIGHTLY_* knob reaches the matrix: {knobs.read_text() if knobs.exists() else ''}")
    print("PASS gate-knobs-safe-and-private")


def schedule_case():
    # What launchd loads: an hourly, per-change check and no fixed nightly slot
    # (the Mac's scheduled 03:00 sleep would cut that run off).
    import plistlib
    try:  # --install loads the template with plistlib, which rejects "--" inside a comment
        job = plistlib.loads((HERE / "dev.arrayapp.nightly-gate.plist").read_bytes())
    except Exception as error:
        raise AssertionError(f"--install cannot load the plist template: {error}")
    expect(job.get("StartInterval") == 3600 and "StartCalendarInterval" not in job
           and job.get("Label") == "dev.arrayapp.nightly-gate", f"hourly per-change schedule only: {job}")
    print("PASS gate-schedule-hourly-only")


def ref_case(fx):
    # A branch that has not landed can be gated by hand; the default stays integration.
    branch = fx.commit("feat(app): unlanded branch work", {"Sources/App.swift": "let app = 3\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD"))
    expect(result.returncode == 0 and fx.summary(branch)["candidate"], "ARRAY_NIGHTLY_REF gates that commit", result)
    pushed = sh("git", "--git-dir", str(fx.origin), "rev-parse", "array/integration").stdout.strip()
    expect(pushed != branch, "gating a branch pushes nothing")
    expect(fx.legs_saw()[-1].startswith(branch) and fx.legs_saw()[-1].endswith("ref=unset"),
           f"no leg inherits ARRAY_NIGHTLY_REF: {fx.legs_saw()[-1]}")
    print("PASS gate-named-ref")

    # A branch of that name living elsewhere is never moved.
    sh("git", "-C", str(fx.base / "checkout"), "checkout", "-q", "--detach")
    sh("git", "-C", str(fx.repo), "branch", "-f", "gate/nightly-checkout", "HEAD~1")
    before = sh("git", "-C", str(fx.repo), "rev-parse", "gate/nightly-checkout").stdout
    fx.commit("feat(app): another unlanded change", {"Sources/App.swift": "let app = 4\n"})
    result = fx.run("nightly-gate.sh", env=dict(ARRAY_NIGHTLY_REF="HEAD"))
    after = sh("git", "-C", str(fx.repo), "rev-parse", "gate/nightly-checkout").stdout
    expect(result.returncode == 1 and before == after and "refusing to move it" in result.stdout,
           "a foreign branch of the gate's name is left alone", result)
    sh("git", "-C", str(fx.repo), "branch", "-D", "gate/nightly-checkout")  # let later cases gate again
    print("PASS gate-leaves-foreign-branch")


failures = 0
with tempfile.TemporaryDirectory(prefix="array-ship-") as temp:
    fixture = Fixture(temp)
    try:
        ship_cases(fixture, *gate_cases(fixture))
        ref_case(fixture)
        quiet_cases(fixture)
        schedule_case()
    except AssertionError as error:
        failures += 1
        print("FAIL", error)
if failures:
    raise SystemExit(1)
print("PASS continuous gate, candidate reuse and ship pipeline")
