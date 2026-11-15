#!/usr/bin/env python3
"""Drive the production matrix (full path, --skip-awake) with CLI doubles.

Witnesses that pre-existing reds classify without a person: listed known-reds
and flakes stay out of the failure count, an expired entry counts again, a leg
that fails only under parallel load passes on its serial retry and is reported
as retry-passed, a real failure stays red, and a selected leg that does not
exist is red rather than silently skipped. Never starts a real app.
"""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SOURCE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).with_name("run-matrix.sh")
DOUBLE = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["KF_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "python3":
    if args and args[0] == "-":
        os.execv(os.environ["KF_PYTHON"], [os.environ["KF_PYTHON"]] + args)
    sys.exit(0)
if name == "tmux":
    if args and args[0] == "start-server":
        socket = pathlib.Path(os.environ["TMUX_TMPDIR"]).resolve() / "fixture" / "socket"
        socket.parent.mkdir(exist_ok=True)
        print(socket)
    sys.exit(0)
if name == "Array":
    flag = next((arg for arg in args if arg.endswith("-check")), "")
    runs = root / ("runs" + flag)
    count = int(runs.read_text()) + 1 if runs.exists() else 1
    runs.write_text(str(count))
    behaviour = json.loads(os.environ["KF_PLAN"]).get(flag, "pass")
    sys.exit(1 if behaviour == "fail" or (behaviour == "fail-once" and count == 1) else 0)
sys.exit(0)  # swift, xcodebuild, lsappinfo: builds and samplers succeed.
'''

today = datetime.date.today()
def entry(leg, kind, added=today, days=30):
    return dict(leg=leg, kind=kind, reason="fixture reason", evidence="fixture evidence",
                added=added.isoformat(), expires=(added + datetime.timedelta(days=days)).isoformat())

KNOWN, FLAKY, EXPIRED, LOAD, REAL, GREEN = (
    "--add-zone-check", "--agent-account-manage-check", "--agent-account-usage-check",
    "--agent-awareness-check", "--agent-compaction-ui-check", "--agent-display-name-check")

def execute(label, plan, failures, legs, retry="1"):
    with tempfile.TemporaryDirectory(prefix="array-known-failures-") as temp:
        root = Path(temp)
        (root / "scripts").mkdir()
        shutil.copyfile(SOURCE, root / "scripts/run-matrix.sh")
        (root / "scripts/matrix-known-failures.json").write_text(json.dumps(dict(failures=failures)))
        for name in ("check-ios-preview-proof.sh", "make-app-bundle.sh"):
            path = root / "scripts" / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        bindir = root / "bin"
        bindir.mkdir()
        stub = "#!" + sys.executable + "\n" + DOUBLE
        for name in ("swift", "python3", "tmux", "lsappinfo", "xcodebuild"):
            (bindir / name).write_text(stub)
            (bindir / name).chmod(0o755)
        (root / ".build/debug").mkdir(parents=True)
        (root / ".build/debug/Array").write_text(stub)
        (root / ".build/debug/Array").chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   SDKROOT="/fixture-sdk", TERM="xterm-256color", CONTINUUM_SKIP_UI_BASELINES="1",
                   ARRAY_MATRIX_LOCK=str(root / "matrix.lock"), ARRAY_MATRIX_RESULTS=str(root / "results"),
                   ARRAY_MATRIX_LEGS=",".join(legs), ARRAY_MATRIX_RETRY=retry, ARRAY_MATRIX_JOBS="4",
                   KF_ROOT=str(root), KF_PYTHON=sys.executable, KF_PLAN=json.dumps(plan))
        for key in ("ARRAY_AGENT_ID", "TMUX", "TMUX_PANE", "ARRAY_MATRIX_LOCK_OWNER",
                    "ARRAY_MATRIX_KNOWN_FAILURES", "CONTINUUM_PREPASS_ONLY", "REPLAY_CHECKS_ONLY",
                    "REPLAY_DRIVER_ONLY", "CONTINUUM_PI_ROLE_CONTEXT_ONLY"):
            env.pop(key, None)
        result = subprocess.run(["/bin/bash", "scripts/run-matrix.sh", "--skip-awake"], cwd=root, env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=120)
        output = result.stdout.decode(errors="replace")
        data = root / "results/results.json"
        rows = {row["leg"]: row["status"] for row in json.loads(data.read_text())} if data.exists() else {}
        runs = {path.name[4:]: int(path.read_text()) for path in root.glob("runs--*")}
        return result.returncode, rows, runs, output

def expect(condition, label, output, detail):
    if not condition:
        raise AssertionError(f"{label}: {detail}\n--- matrix output (tail) ---\n" + "\n".join(output.splitlines()[-60:]))

cases = []
def case(fn):
    cases.append(fn)
    return fn

@case
def mixed():
    plan = {KNOWN: "fail", FLAKY: "fail", EXPIRED: "fail", LOAD: "fail-once", REAL: "fail", GREEN: "pass"}
    failures = [entry(KNOWN, "known-red"), entry(FLAKY, "flaky"),
                entry(EXPIRED, "known-red", added=today - datetime.timedelta(days=40))]
    code, rows, runs, out = execute("mixed", plan, failures, list(plan) + ["--no-such-leg-check"])
    want = {KNOWN: "known-red", FLAKY: "known-flaky", EXPIRED: "fail", LOAD: "retry-passed",
            REAL: "fail", GREEN: "pass", "matrix-selection: --no-such-leg-check": "fail"}
    expect(code == 1, "mixed", out, f"exit {code}, want 1")
    expect({k: rows.get(k) for k in want} == want, "mixed", out, f"rows {rows}")
    expect(sum(status == "fail" for status in rows.values()) == 3, "mixed", out, f"exactly three reds: {rows}")
    expect(runs == {KNOWN: 1, FLAKY: 1, EXPIRED: 2, LOAD: 2, REAL: 2, GREEN: 1}, "mixed", out, f"launches {runs}")
    for text in ("PASSED ON SERIAL RETRY", "EXPIRED known failures", "KNOWN-FLAKY", "not a full gate"):
        expect(text in out, "mixed", out, f"report lacks {text!r}")

@case
def green():
    plan = {KNOWN: "fail", FLAKY: "pass", LOAD: "fail-once", GREEN: "pass"}
    code, rows, runs, out = execute("green", plan, [entry(KNOWN, "known-red"), entry(FLAKY, "flaky")], list(plan))
    expect(code == 0, "green", out, f"exit {code}, want 0; rows {rows}")
    expect(rows.get(FLAKY) == "pass" and rows.get(LOAD) == "retry-passed", "green", out, f"rows {rows}")

@case
def retry_off():
    code, rows, runs, out = execute("retry-off", {LOAD: "fail-once"}, [], [LOAD], retry="0")
    expect(code == 1 and rows.get(LOAD) == "fail" and runs == {LOAD: 1}, "retry-off", out, f"{code} {rows} {runs}")

@case
def stale_known_red():
    code, rows, runs, out = execute("stale", {KNOWN: "pass"}, [entry(KNOWN, "known-red")], [KNOWN])
    expect(rows.get(KNOWN) == "known-red-passed" and "is stale" in out, "stale", out, f"rows {rows}")

@case
def malformed_list():
    bad = [entry(KNOWN, "known-red", days=45), dict(leg=FLAKY, kind="flaky")]
    code, rows, runs, out = execute("malformed", {KNOWN: "fail", FLAKY: "fail"}, bad, [KNOWN, FLAKY])
    expect(code == 1 and rows.get("matrix-known-failures") == "fail", "malformed", out, f"rows {rows}")
    expect(rows.get(KNOWN) == "fail" and rows.get(FLAKY) == "fail", "malformed", out, f"invalid entries must not classify: {rows}")

@case
def committed_list_is_valid():
    path = SOURCE.with_name("matrix-known-failures.json")
    code, rows, runs, out = execute("committed", {}, json.loads(path.read_text())["failures"], [GREEN])
    expect("matrix-known-failures" not in rows and code == 0, "committed", out,
           f"{path} is rejected or expired: {rows}")

failed = 0
for fn in cases:
    try:
        fn()
        print("PASS", fn.__name__)
    except AssertionError as error:
        failed += 1
        print("FAIL", error)
if failed:
    raise SystemExit(1)
print("PASS matrix known-failure classification and serial retry")
