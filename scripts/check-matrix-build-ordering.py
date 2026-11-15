#!/usr/bin/env python3
"""Execute the production matrix with disposable CLI doubles; never real apps."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SOURCE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).with_name("run-matrix.sh")
REPORT = Path(os.environ["ARRAY_ORDERING_EVIDENCE"]) if "ARRAY_ORDERING_EVIDENCE" in os.environ else Path(tempfile.mkdtemp(prefix="array-matrix-ordering-evidence-"))
REPORT.mkdir(parents=True, exist_ok=True)
DOUBLE = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["ORDER_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def event(value):
    with (root / "events").open("a") as stream: stream.write(value + "\n")
def fresh(products):
    return all((root / ("built-" + product)).exists() for product in products)
if name == "python3":
    if args and args[0] == "-":
        os.execv(os.environ["ORDER_PYTHON"], [os.environ["ORDER_PYTHON"]] + args)
    event("offline:" + (args[0] if args else ""))
    if args and args[0] == "scripts/check-candidate-prepass-bundle.py":
        if not fresh(["Array", "array-workspace-mcp"]):
            event("STALE_BUNDLE"); sys.exit(91)
        event("bundle")
elif name == "swift":
    product = args[args.index("--product") + 1] if "--product" in args else "all"
    event("build:" + product)
    if os.environ.get("ORDER_FAIL_BUILD") == product: sys.exit(42)
    for target in (["Array", "ContinuumRevivedCoreChecks", "array-workspace-mcp"] if product == "all" else [product]):
        (root / ("built-" + target)).touch()
        binary = root / ".build/debug" / target
        binary.write_text((root / "cli-double").read_text())
        binary.chmod(0o755)
elif name == "Array":
    flag = next((arg for arg in args if arg.endswith("-check")), "")
    event("app:" + flag)
    products = ["Array"]
    if flag in ("--candidate-prepass-check", "--settings-usage-check"):
        products += ["ContinuumRevivedCoreChecks", "array-workspace-mcp"]
    if not fresh(products):
        event("STALE_APP:" + flag); sys.exit(92)
elif name == "ContinuumRevivedCoreChecks":
    if not fresh(["ContinuumRevivedCoreChecks"]): sys.exit(93)
elif name == "tmux":
    tmp = pathlib.Path(os.environ["TMUX_TMPDIR"]).resolve()
    assert str(tmp).startswith(("/tmp/array-matrix-tmux.", "/private/tmp/array-matrix-tmux."))
    assert "TMUX" not in os.environ and "TMUX_PANE" not in os.environ
    if args[0] == "start-server":
        socket = tmp / "fixture" / "socket"
        socket.parent.mkdir(exist_ok=True)
        event("tmux-start:" + str(tmp))
        print(socket)
    else: event("tmux-cleanup")
elif name == "lsappinfo":
    pass
else:
    event("offline:" + name)
'''

def execute(mode, stale, fail=None):
    with tempfile.TemporaryDirectory(prefix="array-ordering-") as temp:
        root = Path(temp)
        (root / "scripts").mkdir()
        shutil.copyfile(SOURCE, root / "scripts/run-matrix.sh")
        # The matrix refuses to classify without its known-failure list.
        shutil.copyfile(Path(__file__).with_name("matrix-known-failures.json"), root / "scripts/matrix-known-failures.json")
        bindir = root / "bin"
        bindir.mkdir()
        stub = "#!" + sys.executable + "\n" + DOUBLE
        for name in ("swift", "python3", "tmux", "lsappinfo"):
            path = bindir / name
            path.write_text(stub)
            path.chmod(0o755)
        debug = root / ".build/debug"
        debug.mkdir(parents=True)
        (root / "cli-double").write_text(stub)
        if stale:
            for name in ("Array", "ContinuumRevivedCoreChecks", "array-workspace-mcp"):
                path = debug / name
                path.write_text(stub)
                path.chmod(0o755)
        # Shell legs are doubles too; Python script legs go through fake python.
        for name in ("check-matrix-inventory.sh", "check-candidate-prepass.sh"):
            path = root / "scripts" / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   SDKROOT="/fixture-sdk", TERM="xterm-256color",
                   CONTINUUM_SKIP_UI_BASELINES="1", ARRAY_MATRIX_LOCK=str(root / "matrix.lock"),
                   ARRAY_MATRIX_RESULTS=str(root / "results"), ORDER_ROOT=str(root),
                   ORDER_PYTHON=sys.executable, CONTINUUM_PREPASS_ONLY="0")
        for key in ("ARRAY_AGENT_ID", "TMUX", "TMUX_PANE", "ARRAY_MATRIX_LOCK_OWNER",
                    "REPLAY_CHECKS_ONLY", "REPLAY_DRIVER_ONLY"):
            env.pop(key, None)
        if fail: env["ORDER_FAIL_BUILD"] = fail
        else: env.pop("ORDER_FAIL_BUILD", None)
        result = subprocess.run(["/bin/bash", "scripts/run-matrix.sh", mode],
                                cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        events = (root / "events").read_text().splitlines() if (root / "events").exists() else []
        label = mode[2:] + ("-stale" if stale else "-clean") + ("-failed-build" if fail else "")
        (REPORT / (label + ".log")).write_bytes(result.stdout)
        (REPORT / (label + ".json")).write_text(json.dumps(dict(exit=result.returncode, events=events), indent=2))
        assert any(item.startswith("tmux-start:") for item in events), "private fake tmux not exercised: " + result.stdout.decode(errors="replace")
        assert "tmux-cleanup" in events, "private namespace not retired"
        if fail:
            assert result.returncode != 0 and not any(item.startswith("app:") or item == "bundle" for item in events), events
        else:
            assert result.returncode == 0, f"{label}: matrix exit {result.returncode}; events={events}"
            assert not any(item.startswith("STALE_") for item in events), events
            assert "offline:scripts/check-matrix-build-ordering.py" in events, "registered witness must be no-op through fixture python, not recurse"
            if mode == "--managed-mode":
                last_build = max(events.index("build:" + product) for product in
                                 ("Array", "ContinuumRevivedCoreChecks", "array-workspace-mcp"))
                for check in ("app:--candidate-prepass-check", "bundle", "app:--settings-usage-check"):
                    assert check in events and events.index(check) > last_build, (label, check, events)
            else:
                assert "app:--candidate-prepass-check" not in events and "bundle" not in events, events
                assert events.index("app:--first-helper-isolation-check") > events.index("build:array-workspace-mcp")
        print("PASS", label)

failures = []
for mode in ("--managed-mode", "--helper-isolation"):
    for stale, fail in ((False, None), (True, None), (True, "Array")):
        try:
            execute(mode, stale, fail)
        except AssertionError as error:
            failures.append(str(error))
            print("FAIL", error)
if failures:
    raise SystemExit(1)
print("PASS production matrix build ordering; evidence:", REPORT)
