"""The live pilot's tasks, built from this repository's own history.

Each task is a small fixture repository holding real files of this repo: at
the base, each file as it was at the parent of its real fix; in the fix
commit, each file as the fix left it, plus the hidden checks. A task with
independent parts takes each part's file from its own commit. The hidden
checks are written here, on the host, because the real commits carry no
check the grader can run in isolation. `replay.validate` must show every
hidden check failing by assertion on the base and passing on the fix before a
task is written.

The pilot set (PILOT) is five tasks by size: two small, two medium (a change
across two files that needs real reading), one larger with three independent
parts in different files. Their requests are plain task statements and never
mention helpers. `prepass-two-parts` is separate: its request asks the lead to
give each part to its own helper, so it tests the delegation path and is never
paired with a solo run.

usage: pilot_tasks.py REPO OUT_DIR [TASK ...]   (writes OUT_DIR/<task>/task.json)"""
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import replay  # noqa: E402

FILES = ['scripts/gate-prepass.py', 'scripts/check-coverage-manifest.json', 'scripts/check-gate-prepass.py']
PILOT = ['prepass-deleted-once', 'prepass-targeted-only', 'replay-ledger-schema', 'perf-runner-interrupt',
         'three-independent-fixes']

LOAD = '''import importlib.util
spec = importlib.util.spec_from_file_location("gate_prepass", "scripts/gate-prepass.py")
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)
'''

NEIGHBOUR = LOAD + '''
assert gp.subject_problems("fix(gate): keep the report short") == []
assert gp.subject_problems("Fixed things.")
assert gp.is_checks_path("Sources/ContinuumRevivedCoreChecks/main.swift")
assert not gp.is_checks_path("Sources/ContinuumRevived/App/AgentSupervisor.swift")
'''

DELETED_ONCE = LOAD + '''
manifest = {"checks": [{"invocation": ".build/debug/Array --a-check", "owner": "o", "reason": "r",
                        "covers": ["Sources/App/**"], "checkFiles": []}]}
changes = [{"status": "D", "old": "Sources/App/Gone.swift", "path": "Sources/App/Gone.swift"},
           {"status": "R", "old": "Sources/App/Old.swift", "path": "Sources/App/New.swift"},
           {"status": "M", "old": None, "path": "Sources/App/Kept.swift"}]
ordered, unmapped = gp.coverage(manifest, changes)
paths = [(p["path"], p["status"]) for p in ordered[0]["paths"]]
assert [p for p in paths if p[0] == "Sources/App/Gone.swift"] == [("Sources/App/Gone.swift", "D")], paths
assert ("Sources/App/New.swift", "R") in paths and ("Sources/App/Old.swift", "old path of R") in paths, paths
assert [p for p in paths if p[0] == "Sources/App/Kept.swift"] == [("Sources/App/Kept.swift", "M")], paths
assert unmapped == [], unmapped
'''

TARGETED = LOAD + '''
import json


class Repo:
    def __init__(self, files):
        self.files_by_path = files

    def show(self, rev, path):
        return self.files_by_path.get(path)


def manifest(targeted):
    data = {"version": 1, "checks": [], "exceptions": []}
    if targeted is not None:
        data["targetedOnly"] = targeted
    return Repo({gp.MANIFEST: json.dumps(data)})


def refused(targeted):
    try:
        gp.load_manifest(manifest(targeted), "0" * 40, True)
    except gp.PrepassError:
        return True
    return False


good = [{"flag": "--brand-new-check", "reason": "requires a real display"}]
assert gp.load_manifest(manifest(good), "0" * 40, True)["targetedOnly"] == good
assert gp.load_manifest(manifest(None), "0" * 40, True) is not None
assert refused({"flag": "--brand-new-check", "reason": "x"}), "not a list"
assert refused(["--brand-new-check"]), "entry not an object"
assert refused([{"flag": "--brand-new-check"}]), "missing reason"
assert refused([{"flag": "--brand-new-check", "reason": "  "}]), "blank reason"
assert refused([{"flag": "--brand-new-check", "reason": "one\\ntwo"}]), "multi-line reason"
assert refused([{"flag": "--brand-new", "reason": "r"}]), "not a --*-check flag"
assert refused(good + good), "duplicated flag"

path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
line = '        if CommandLine.arguments.contains("--brand-new-check") { exit(0) }'
source = "import Foundation\\nfunc main() {\\n" + line + "\\n}\\n"
repo = Repo({path: source})
diff = {path: {"added": {3: line}, "removed": []}}
reg = {"matrix": set(), "bundle": set(), "assigned": set(), "legs": []}


def unregistered(manifest_data):
    found, _ = gp.check_swift(repo, "0" * 40, diff, diff, reg, manifest_data, [], set())
    return [f for f in found if f.get("rule") == "unregistered-check-flag"]


assert unregistered({"checks": [], "exceptions": []}), "an undeclared flag still fails"
declared = {"checks": [], "exceptions": [], "targetedOnly": good}
assert unregistered(declared) == [], "a declared targeted-only flag is not reported"
other = {"checks": [], "exceptions": [], "targetedOnly": [{"flag": "--other-check", "reason": "r"}]}
assert unregistered(other), "declaring another flag does not excuse this one"
'''

DELETED_REQUEST = ("In scripts/gate-prepass.py, the coverage section of the report lists a deleted file twice: "
                   "once with status D and again as 'old path of D'. A deleted file should be listed once, "
                   "with its own status. Renamed files should still list both the new path and the old path.")
TARGETED_REQUEST = ("scripts/gate-prepass.py fails every newly dispatched --*-check flag that no matrix leg and no "
                    "bundle-harness list runs. Some checks can only be run by hand, for example because they need "
                    "a real display. Let the coverage manifest (scripts/check-coverage-manifest.json) declare such "
                    "checks in an optional top-level list `targetedOnly` of objects "
                    "{\"flag\": \"--some-check\", \"reason\": \"...\"}. A declared flag must not be reported as "
                    "unregistered (or as uncertain). Validate the list in load_manifest like the rest of the "
                    "manifest: it must be a list, each entry an object, each flag an exact --*-check flag that is "
                    "not duplicated, and each reason a non-empty single line. An invalid entry is a manifest "
                    "problem, reported the same way as the others.")


LOADER = """import importlib.util


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
"""

SCHEMA = LOADER + """
import json
replay = load("replay", "benchmarks/replay/replay.py")
assert replay.TOKEN_TYPES == ("uncachedInput", "cacheRead", "cacheWrite", "output"), replay.TOKEN_TYPES
manifest = json.load(open("benchmarks/replay/manifest.json"))
assert manifest["v"] == 3, manifest["v"]
names = [field["name"] for field in manifest["recordFields"]]
assert "tokensNotReported" in names and "usageRows" in names, names
task = dict(task="t" * 64, fixture="f", base="b" * 40, requestHash="r" * 64, checksHash="c" * 64)
record = replay.new_record(task, "codex", "solo")
assert record["tokensNotReported"] == [] and record["usageRows"] == []
replay.check_record(record)


def done(mode, tokens, not_reported):
    r = dict(replay.new_record(task, "codex", mode), outcome="completed", passed=True, gradeResult="passed",
             usageComplete=True, usageProblems=[], tokens=tokens, tokensNotReported=not_reported,
             wallSeconds=10.0, activeSeconds=10.0)
    if mode == "managed":
        r.update(fannedOut=True, helperCount=2)
    return r


codex = dict(uncachedInput=100, cacheRead=50, cacheWrite=None, output=10)
replay.check_record(done("solo", codex, ["cacheWrite"]))
for tokens, not_reported, why in [(dict(codex, cacheWrite=0), ["cacheWrite"], "a not-reported type with a figure"),
                                  (codex, [], "an unknown type in complete usage")]:
    try:
        replay.check_record(done("solo", tokens, not_reported))
    except ValueError:
        continue
    raise AssertionError("accepted " + why)
solo = done("solo", codex, ["cacheWrite"])
managed = done("managed", dict(codex, uncachedInput=90, output=12), ["cacheWrite"])
other = done("managed", dict(codex, uncachedInput=90, output=12, cacheWrite=5), [])
assert replay.pair_exclusion(solo, other) == "token types reported differ", replay.pair_exclusion(solo, other)
lines = [line for line in replay.compare([solo, managed])["lines"] if line.startswith("codex ")]
assert len(lines) == 1, lines
for part in ("cacheWrite not reported", "uncachedInput -10", "output +2", "cacheRead +0"):
    assert part in lines[0], (part, lines[0])
"""

SCHEMA_NEIGHBOUR = LOADER + """
replay = load("replay", "benchmarks/replay/replay.py")
assert replay.task_id("a", "b", "c") == replay.digest(b"a\\nb\\nc")
assert "solo" in replay.MODES and "codex" in replay.HARNESSES
"""

PERF_CONTRACT = '#!/usr/bin/env bash\nset -euo pipefail\n\nROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)\nRUNNER="$ROOT_DIR/scripts/run-perf-ceilings.sh"\nTEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/array-perf-runner-contract.XXXXXX")\ntrap \'rm -rf "$TEST_ROOT"\' EXIT\n\nfail() {\n  echo "FAIL: $*" >&2\n  exit 1\n}\n\nassert_contains() {\n  local file=$1\n  local expected=$2\n  grep -F -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"\n}\n\nmake_fixture() {\n  local fixture=$1\n  mkdir -p "$fixture/scripts" "$fixture/bin"\n  cp "$RUNNER" "$fixture/scripts/run-perf-ceilings.sh"\n  chmod +x "$fixture/scripts/run-perf-ceilings.sh"\n  cat >"$fixture/bin/swift" <<\'SH\'\n#!/usr/bin/env bash\nset -euo pipefail\nprintf \'%s\\n\' "$*" >>"$SWIFT_LOG"\nif [[ ${1:-} == build ]]; then\n  configuration=debug\n  while [[ $# -gt 0 ]]; do\n    if [[ $1 == -c ]]; then configuration=$2; shift 2; else shift; fi\n  done\n  mkdir -p ".build/$configuration"\n  cp "$FAKE_APP_TEMPLATE" ".build/$configuration/Array"\n  chmod +x ".build/$configuration/Array"\nfi\nSH\n  chmod +x "$fixture/bin/swift"\n  cat >"$fixture/fake-app" <<\'SH\'\n#!/usr/bin/env bash\nset -euo pipefail\nprintf \'%s\\n\' "$0" >>"$APP_LOG"\nmkdir -p "$CONTINUUM_QA_PERF"\ncat >"$CONTINUUM_QA_PERF/perf-report.json" <<\'JSON\'\n{"metrics":[\n  {"key":"launch-time","value":1,"unit":"ms"},\n  {"key":"drag-latency-p95","value":1,"unit":"ms"},\n  {"key":"memory-at-10-tiles","value":1,"unit":"bytes"},\n  {"key":"palette-leak-delta","value":0,"unit":"bytes"}\n],"findings":[]}\nJSON\nif [[ ${FAKE_APP_MODE:-} == interrupt ]]; then\n  printf \'%s\\n%s\\n\' "$CONTINUUM_PROJECT_ROOT" "$CONTINUUM_APP_SUPPORT" >"$ISOLATION_LOG"\n  : >"$APP_READY"\n  sleep 2\nelif [[ ${FAKE_APP_MODE:-} == fail ]]; then\n  printf \'%s\\n%s\\n\' "$CONTINUUM_PROJECT_ROOT" "$CONTINUUM_APP_SUPPORT" >"$ISOLATION_LOG"\n  exit 42\nfi\nSH\n  chmod +x "$fixture/fake-app"\n}\n\nrun_fixture() {\n  local fixture=$1\n  shift\n  (\n    cd "$fixture"\n    PATH="$fixture/bin:$PATH" \\\n      SWIFT_LOG="$fixture/swift.log" \\\n      APP_LOG="$fixture/app.log" \\\n      FAKE_APP_TEMPLATE="$fixture/fake-app" \\\n      CONTINUUM_PERF_FLOWS="contract" \\\n      CONTINUUM_PERF_OUT="$fixture/out" \\\n      "$@" "$fixture/scripts/run-perf-ceilings.sh"\n  )\n}\n\ndebug_fixture="$TEST_ROOT/default-debug"\nmake_fixture "$debug_fixture"\nrun_fixture "$debug_fixture" env\nassert_contains "$debug_fixture/swift.log" "run -c debug ContinuumRevivedPerfChecks"\nassert_contains "$debug_fixture/swift.log" "build -c debug"\nassert_contains "$debug_fixture/app.log" "/.build/debug/Array"\n\nrelease_fixture="$TEST_ROOT/explicit-release"\nmake_fixture "$release_fixture"\nrun_fixture "$release_fixture" env CONTINUUM_PERF_CONFIGURATION=release\nassert_contains "$release_fixture/swift.log" "run -c release ContinuumRevivedPerfChecks"\nassert_contains "$release_fixture/swift.log" "build -c release"\nassert_contains "$release_fixture/app.log" "/.build/release/Array"\n\ninvalid_fixture="$TEST_ROOT/invalid"\nmake_fixture "$invalid_fixture"\nif run_fixture "$invalid_fixture" env CONTINUUM_PERF_CONFIGURATION=profile >"$invalid_fixture/result.log" 2>&1; then\n  fail "invalid configuration was accepted"\nfi\nassert_contains "$invalid_fixture/result.log" "CONTINUUM_PERF_CONFIGURATION must be debug or release"\n\nconflict_fixture="$TEST_ROOT/conflict"\nmake_fixture "$conflict_fixture"\nmkdir -p "$conflict_fixture/.build/debug"\ncp "$conflict_fixture/fake-app" "$conflict_fixture/.build/debug/Array"\nif run_fixture "$conflict_fixture" env CONTINUUM_PERF_CONFIGURATION=release CONTINUUM_PERF_APP="$conflict_fixture/.build/debug/Array" >"$conflict_fixture/result.log" 2>&1; then\n  fail "release configuration accepted a debug app"\nfi\nassert_contains "$conflict_fixture/result.log" "conflicts with requested release configuration"\n\nsymlink_fixture="$TEST_ROOT/symlink-conflict"\nmake_fixture "$symlink_fixture"\nmkdir -p "$symlink_fixture/.build/debug" "$symlink_fixture/aliases"\ncp "$symlink_fixture/fake-app" "$symlink_fixture/.build/debug/Array"\nln -s "$symlink_fixture/.build/debug/Array" "$symlink_fixture/aliases/Array"\nif run_fixture "$symlink_fixture" env CONTINUUM_PERF_CONFIGURATION=release CONTINUUM_PERF_APP="$symlink_fixture/aliases/Array" >"$symlink_fixture/result.log" 2>&1; then\n  fail "release configuration accepted a symlink to a debug app"\nfi\nassert_contains "$symlink_fixture/result.log" "conflicts with requested release configuration"\n\ninterrupt_fixture="$TEST_ROOT/interrupt-cleanup"\nmake_fixture "$interrupt_fixture"\nmkdir -p "$interrupt_fixture/tmp"\n: >"$interrupt_fixture/outside-owned-roots"\n(\n  cd "$interrupt_fixture"\n  exec env \\\n    PATH="$interrupt_fixture/bin:$PATH" \\\n    SWIFT_LOG="$interrupt_fixture/swift.log" \\\n    APP_LOG="$interrupt_fixture/app.log" \\\n    FAKE_APP_TEMPLATE="$interrupt_fixture/fake-app" \\\n    CONTINUUM_PERF_FLOWS=contract \\\n    CONTINUUM_PERF_OUT="$interrupt_fixture/out" \\\n    TMPDIR="$interrupt_fixture/tmp" \\\n    FAKE_APP_MODE=interrupt \\\n    ISOLATION_LOG="$interrupt_fixture/isolation.log" \\\n    APP_READY="$interrupt_fixture/app-ready" \\\n    "$interrupt_fixture/scripts/run-perf-ceilings.sh"\n) >"$interrupt_fixture/result.log" 2>&1 &\nrunner_pid=$!\nfor _ in {1..100}; do\n  [[ -f "$interrupt_fixture/app-ready" ]] && break\n  kill -0 "$runner_pid" 2>/dev/null || fail "runner exited before interruption readiness"\n  sleep 0.02\ndone\n[[ -f "$interrupt_fixture/app-ready" ]] || fail "fake app did not reach interruption readiness"\nkill -TERM "$runner_pid"\nset +e\nwait "$runner_pid"\ninterrupt_status=$?\nset -e\n[[ $interrupt_status -eq 143 ]] || fail "SIGTERM exit was $interrupt_status instead of 143"\nwhile IFS= read -r owned_root; do\n  [[ "$owned_root" == "$interrupt_fixture/tmp/"* ]] || fail "isolation escaped test TMPDIR: $owned_root"\n  [[ ! -e "$owned_root" ]] || fail "interrupted runner leaked isolation root: $owned_root"\ndone <"$interrupt_fixture/isolation.log"\n[[ -f "$interrupt_fixture/outside-owned-roots" ]] || fail "cleanup deleted a path outside owned isolation roots"\n\nfailure_fixture="$TEST_ROOT/failure-cleanup"\nmake_fixture "$failure_fixture"\nmkdir -p "$failure_fixture/tmp"\n: >"$failure_fixture/outside-owned-roots"\nset +e\nrun_fixture "$failure_fixture" env \\\n  TMPDIR="$failure_fixture/tmp" \\\n  FAKE_APP_MODE=fail \\\n  ISOLATION_LOG="$failure_fixture/isolation.log" \\\n  >"$failure_fixture/result.log" 2>&1\nfailure_status=$?\nset -e\n[[ $failure_status -eq 42 ]] || fail "app failure exit was $failure_status instead of 42"\nwhile IFS= read -r owned_root; do\n  [[ "$owned_root" == "$failure_fixture/tmp/"* ]] || fail "failure isolation escaped test TMPDIR: $owned_root"\n  [[ ! -e "$owned_root" ]] || fail "failed runner leaked isolation root: $owned_root"\ndone <"$failure_fixture/isolation.log"\n[[ -f "$failure_fixture/outside-owned-roots" ]] || fail "failure cleanup deleted a path outside owned isolation roots"\n\necho "Performance runner configuration contract passed."\n'

PERF = """import os, subprocess
os.makedirs("checks/tests", exist_ok=True)
with open("checks/tests/perf-contract.sh", "w") as out:
    out.write(CONTRACT)
proc = subprocess.run(["/bin/bash", "checks/tests/perf-contract.sh"], stdout=subprocess.PIPE,
                      stderr=subprocess.STDOUT, timeout=60)
assert proc.returncode == 0, proc.stdout.decode(errors="replace")[-600:]
""".replace("CONTRACT", repr(PERF_CONTRACT))

PERF_NEIGHBOUR = """import subprocess
assert subprocess.run(["/bin/bash", "-n", "scripts/run-perf-ceilings.sh"]).returncode == 0
"""

BANNERS = LOADER + """
census = load("notification_map", "scripts/check-notification-map.py").census
counts = census(open("scripts/check-gate-prepass.py").read())
assert "local-banner" not in counts, counts
fixtures = load("gate_fixtures", "scripts/check-gate-prepass.py")
assert "UNNotificationRequest(" in fixtures.BASE_FILES["Sources/ContinuumRevived/App/Notify.swift"]
"""

COST_REPORT = dict(
    summaries=[dict(distinctCapturedCameraStates=10, capturedCameraStatesPerSecond=5,
                    cameraChangeIntervalsMs=dict(p50=1, p95=2, max=3), gapsOver16_7ms=0, gapsOver33ms=0,
                    gapsOver50ms=0, firstCapturedChangeMs=5, finalCameraAfterInputEndMs=7,
                    scheduledToMainMs=dict(p50=1, p95=2, max=3), cameraCommitCount=4)],
    final=dict(work=dict(a=2)), baseline=dict(work=dict(a=1)),
    phases=[dict(startSeconds=0, endSeconds=2, settleEndSeconds=3,
                 before=dict(cost=dict(mainThreadCPUSeconds=1.0, processInstructions=1e6, processCycles=2e6)),
                 afterInput=dict(cost=dict(mainThreadCPUSeconds=1.01, processInstructions=7e6, processCycles=14e6)))])

COST = """import copy, json, os, subprocess, sys, tempfile
REPORT = json.loads(REPORT_JSON)


def run(report):
    path = os.path.join(tempfile.mkdtemp(), "report.json")
    with open(path, "w") as out:
        json.dump(report, out)
    proc = subprocess.run([sys.executable, "scripts/canvas-motion/analyze.py", path], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    return proc.stdout.decode(errors="replace")


out = run(REPORT)
want = "cost per camera commit (4 commits): main thread 2.50 ms CPU, process 1.5 M instructions, 3.0 M cycles"
assert want in out, out
lines = out.splitlines()
assert lines.index(want) == [i for i, l in enumerate(lines) if l.startswith("screen:")][0] + 1, out
zero = copy.deepcopy(REPORT)
zero["summaries"][0]["cameraCommitCount"] = 0
assert "cost per camera commit (1 commits): main thread 10.00 ms CPU" in run(zero)
missing = copy.deepcopy(REPORT)
del missing["phases"][0]["afterInput"]["cost"]
assert "cost per camera commit" not in run(missing)
""".replace("REPORT_JSON", repr(json.dumps(COST_REPORT)))

REALPATHS = LOADER + """
import json, os, tempfile
live = load("live_claude", "benchmarks/replay/live_claude.py")
top = tempfile.mkdtemp()
os.mkdir(os.path.join(top, "real"))
os.symlink(os.path.join(top, "real"), os.path.join(top, "link"))
config = os.path.join(top, "link", "mcp.json")
token = os.path.join(top, "link", "token")
with open(config, "w") as out:
    json.dump({"mcpServers": {"array_workspace": {"command": "/usr/bin/true", "env": {
        "ARRAY_WORKSPACE_MCP_ENDPOINT": "http://127.0.0.1:4321/", "ARRAY_WORKSPACE_MCP_TOKEN_FILE": token}}}}, out)
files, folders, ports = live.workspace_mcp(["-p", "--mcp-config", config])
want = [os.path.join(os.path.realpath(top), "real", "mcp.json"), os.path.join(os.path.realpath(top), "real", "token")]
assert files == want, (files, want)
assert folders == ["/usr/bin"] and ports == [4321], (folders, ports)
"""

THREE_NEIGHBOUR = LOADER + """
import subprocess, sys
assert "local-banner" in load("notification_map", "scripts/check-notification-map.py").PATTERNS
assert callable(load("live_claude", "benchmarks/replay/live_claude.py").profile)
out = subprocess.run([sys.executable, "scripts/canvas-motion/analyze.py", "/dev/null"], stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT).stdout
assert b"Error" in out or b"FAILED" in out or out == b""
"""

SCHEMA_REQUEST = ("The replay benchmark's record (benchmarks/replay/replay.py, with its field list in "
                  "benchmarks/replay/manifest.json) should take its token figures from the run ledger's four token "
                  "types. Move the schema to version 3:\\n"
                  "- The token types are, in this order, uncachedInput, cacheRead, cacheWrite, output (replacing input, "
                  "output, cacheRead, cacheWrite).\\n"
                  "- Add two record fields: tokensNotReported, the token types the harness never reports (Codex never "
                  "reports cacheWrite), and usageRows, the ledger's usage rows for the task. A new record has both as "
                  "empty lists. Document both in the manifest.\\n"
                  "- A type listed in tokensNotReported must have a null figure; a figure there is an error. Such a "
                  "type does not make usage incomplete; any other null type still does.\\n"
                  "- A solo/managed pair whose tokensNotReported differ is not compared, with the reason "
                  "'token types reported differ'.\\n"
                  "- In the comparison, report every token type: '<type> <signed difference>' followed by both "
                  "verdicts when both sides have a figure, '<type> not reported' when the harness never reports it, "
                  "and '<type> unknown' otherwise.")

PERF_REQUEST = ("scripts/run-perf-ceilings.sh runs the app once per performance flow, with a temporary project folder "
                "and a temporary app-support folder made under TMPDIR. If the script is interrupted (SIGINT or SIGTERM) "
                "while a flow is running, the app keeps running and both folders are left behind. Make an interruption "
                "stop the running app with the same signal, remove that flow's temporary folders, and then end the "
                "script by the same signal (so SIGTERM gives exit status 143). A flow whose app fails must still remove "
                "its folders and exit with the app's status. Never delete anything outside the folders the script "
                "made. Extend the contract test, scripts/tests/run-perf-ceilings-contract.sh, to cover the "
                "interruption and the failure.")

THREE_REQUEST = ("Three separate fixes, each in its own file.\\n\\n"
                 "1. scripts/check-notification-map.py counts notification senders, and it counts the two sample "
                 "banner calls (UNNotificationRequest) in the fixtures of scripts/check-gate-prepass.py as real "
                 "senders. Make check-gate-prepass.py stop being counted, while its fixture files still contain the "
                 "call: the pre-pass's own advisory case needs it. Change check-gate-prepass.py, not the census.\\n\\n"
                 "2. scripts/canvas-motion/analyze.py summarises a motion probe report. Each phase now records cost "
                 "counters before the gesture and after the input: phases[0].before.cost and "
                 "phases[0].afterInput.cost, each with mainThreadCPUSeconds, processInstructions and processCycles. "
                 "Right after the 'screen:' line, print 'cost per camera commit (N commits): main thread X ms CPU, "
                 "process Y M instructions, Z M cycles', where N is summaries[0].cameraCommitCount (at least 1), X is "
                 "the main-thread CPU difference in milliseconds per commit with two decimals, and Y and Z are the "
                 "instruction and cycle differences in millions per commit with one decimal. Print nothing when "
                 "either cost is missing.\\n\\n"
                 "3. In benchmarks/replay/live_claude.py, workspace_mcp returns the MCP config file and token file "
                 "paths as given. The sandbox profile matches resolved paths (on macOS /var is a link to "
                 "/private/var), so a file under /var, or under any link, cannot be read inside the sandbox. Return "
                 "both paths resolved.")


TASKS = [
    dict(name='prepass-deleted-once', size='small', parent='ac055cd22~1', fix='ac055cd22',
         hidden={'checks/hidden_deleted_once.py': DELETED_ONCE},
         request=DELETED_REQUEST + " Fix it."),
    dict(name='prepass-targeted-only', size='small', parent='2f96d775c~1', fix='2f96d775c',
         hidden={'checks/hidden_targeted_only.py': TARGETED},
         request=TARGETED_REQUEST),
    dict(name='prepass-two-parts', size='delegation test', parent='ac055cd22~1', fix='2f96d775c',
         hidden={'checks/hidden_deleted_once.py': DELETED_ONCE, 'checks/hidden_targeted_only.py': TARGETED},
         request=("This task has two independent parts, both in scripts/gate-prepass.py. Give each part to its "
                  "own helper, one helper per part, and bring both results into this checkout.\n\n"
                  "Part 1. " + DELETED_REQUEST + "\n\nPart 2. " + TARGETED_REQUEST)),
    dict(name='replay-ledger-schema', size='medium',
         files=[('benchmarks/replay/replay.py', '0421980d8~1', '0421980d8'),
                ('benchmarks/replay/manifest.json', '0421980d8~1', '0421980d8')],
         hidden={'checks/hidden_ledger_schema.py': SCHEMA},
         neighbour=('checks/neighbour_replay.py', SCHEMA_NEIGHBOUR), request=SCHEMA_REQUEST),
    dict(name='perf-runner-interrupt', size='medium',
         files=[('scripts/run-perf-ceilings.sh', 'd7bdc7091~1', 'd7bdc7091'),
                ('scripts/tests/run-perf-ceilings-contract.sh', 'd7bdc7091~1', 'd7bdc7091')],
         hidden={'checks/hidden_perf_interrupt.py': PERF}, tools=['node'],
         neighbour=('checks/neighbour_perf.py', PERF_NEIGHBOUR), request=PERF_REQUEST),
    dict(name='three-independent-fixes', size='larger',
         files=[('scripts/check-gate-prepass.py', '9f7fc19e0~1', '9f7fc19e0'),
                ('scripts/check-notification-map.py', '9f7fc19e0', '9f7fc19e0'),
                ('scripts/canvas-motion/analyze.py', '02bb9f344~1', '02bb9f344'),
                ('benchmarks/replay/live_claude.py', '7270328f1~1', '7270328f1')],
         hidden={'checks/hidden_banners.py': BANNERS, 'checks/hidden_commit_cost.py': COST,
                 'checks/hidden_realpaths.py': REALPATHS},
         neighbour=('checks/neighbour_three.py', THREE_NEIGHBOUR), request=THREE_REQUEST),
]


def git(repo, *args, data=None):
    return subprocess.run(['git', '-C', str(repo), *args], input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def commit(repo, message):
    git(repo, 'add', '-A')
    git(repo, '-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', message)
    return git(repo, 'rev-parse', 'HEAD').decode().strip()


def files_of(spec):
    """(path, base revision, fix revision) per file."""
    return spec.get('files') or [(rel, spec['parent'], spec['fix']) for rel in FILES]


def build(source_repo, out, spec):
    root = Path(out) / spec['name']
    repo = root / 'source'
    repo.mkdir(parents=True)
    git(repo, 'init', '-q')
    for rel, parent, _ in files_of(spec):
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_bytes(git(source_repo, 'show', '%s:%s' % (parent, rel)))
    neighbour = spec.get('neighbour', ('checks/neighbour_prepass.py', NEIGHBOUR))
    (repo / neighbour[0]).parent.mkdir(parents=True, exist_ok=True)
    (repo / neighbour[0]).write_text(neighbour[1])
    base = commit(repo, 'fixture: each file at the parent of its fix')
    for rel, _, fix_rev in files_of(spec):
        (repo / rel).write_bytes(git(source_repo, 'show', '%s:%s' % (fix_rev, rel)))
    for rel, text in spec['hidden'].items():
        (repo / rel).write_text(text)
    fix = commit(repo, 'fixture: each fix as it landed, with the hidden checks')
    tools = [shutil.which(t, path='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin') for t in spec.get('tools', [])]
    if not all(tools):
        raise SystemExit('%s: a declared tool is not installed: %s' % (spec['name'], spec['tools']))
    task = replay.make_task(repo, base, fix, spec['request'], spec['name'], sorted(spec['hidden']),
                            [neighbour[0]], ['checks/'], tools)
    task['size'] = spec['size']
    task['origin'] = [dict(path=rel, parent=git(source_repo, 'rev-parse', parent).decode().strip(),
                           fix=git(source_repo, 'rev-parse', fix_rev).decode().strip())
                      for rel, parent, fix_rev in files_of(spec)]
    if not replay.validate(task):
        raise SystemExit('%s: hidden check does not fail on the parent and pass on the fix' % spec['name'])
    (root / 'task.json').write_text(json.dumps(task, sort_keys=True))
    return root / 'task.json'


def main(argv):
    for spec in TASKS:
        if argv[2:] and spec['name'] not in argv[2:]:
            continue
        print(build(Path(argv[0]), Path(argv[1]), spec))


if __name__ == '__main__':
    main(sys.argv[1:])
