#!/usr/bin/env python3
"""Witness for scripts/leg-coverage.py, the affected-legs selector a tier 2 or 3
feature gate runs.

It drives the real selector over a real, immutable range: 0.7.52's sidebar fix
(1b5756af..cf3dfde2), which changed the sidebar view, added a check and its
dispatch arm, and registered the leg. That range must select its own new witness
and the sidebar legs, stay far narrower than the full matrix, and treat the new
arm and the new leg as additions. Then the fail-safe half: an unmapped file,
run-matrix.sh without a range, Package.swift and a non-additive edit to
run-matrix.sh or the dispatcher each select the FULL matrix; release paths
select nothing.

    python3 scripts/check-leg-coverage.py [leg-coverage.py=PATH]   # PATH: a mutant, for teeth
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = str(HERE.parent)
selector = HERE / "leg-coverage.py"
for arg in sys.argv[1:]:
    name, _, path = arg.partition("=")
    if name == "leg-coverage.py":
        selector = Path(path)
spec = importlib.util.spec_from_file_location("leg_coverage", selector)
lc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lc)

BASE, HEAD = "1b5756af58732c9e815d9b54ad688a291e8aa1a5", "cf3dfde2f041aaaa54a54ad692db4e08a009fbfd"
APP = "Sources/ContinuumRevived/App/ContinuumApp.swift"
failures = []


def expect(condition, message):
    print(("PASS " if condition else "FAIL ") + message)
    if not condition:
        failures.append(message)


def synthetic(repo, parent, path, edit):
    """A dangling commit on parent with one file edited; the worktree is untouched."""
    with tempfile.TemporaryDirectory(prefix="leg-coverage-") as temp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / "index"))
        git = lambda *a, **kw: subprocess.run(["git", "-C", REPO, *a], env=env, check=True,
                                              capture_output=True, text=True, **kw).stdout.strip()
        git("read-tree", parent)
        blob = git("hash-object", "-w", "--stdin", input=edit(repo.show(parent, path)))
        git("update-index", "--cacheinfo", "100644", blob, path)
        tree = git("write-tree")
        return git("-c", "user.name=leg-coverage", "-c", "user.email=leg-coverage@example.invalid",
                   "commit-tree", tree, "-p", parent, "-m", "check(leg-coverage): synthetic")


repo = lc.prepass.Repo(REPO)
built = lc.build_map(repo, HEAD)
total = len(built[1])
paths = repo.text("diff", "--no-renames", "--name-only", BASE, HEAD).split()
real = lc.select(repo, HEAD, paths, built=built, base=BASE)
expect(not real["full"], f"0.7.52's sidebar fix selects legs, not the full matrix: {real['full_reasons']}")
expect({"--sidebar-row-reveal-check", "--subagent-sidebar-open-check", "--sidebar-truth-check"} <= set(real["legs"]),
       "it selects its new witness and the sidebar legs around the changed view")
expect(0 < len(real["legs"]) < total // 2, f"it selects {len(real['legs'])} of {total} legs, under half")
expect(real["per_path"].get(APP) == ["--sidebar-row-reveal-check"],
       f"a new dispatch arm selects only its flag: {real['per_path'].get(APP, 'FULL')[:5]}")
expect("--sidebar-row-reveal-check" in real["per_path"].get("scripts/run-matrix.sh", []),
       "a leg added to run-matrix.sh selects that leg")
view = real["per_path"].get("Sources/ContinuumRevived/App/AgentInboxView.swift", [])
expect("--sidebar-row-reveal-check" not in view or len(view) < total // 2,
       f"the changed view maps to its own legs ({len(view)}), not everything")

alone = lambda *p: lc.select(repo, HEAD, list(p), built=built)
composer = alone("Sources/ContinuumRevived/Canvas/AgentComposer/ComposerTextView.swift")
expect(not composer["full"] and "--composer-key-routing-check" in composer["legs"] and len(composer["legs"]) < total // 2,
       f"the composer text view selects the key-routing check that drives it ({len(composer['legs'])} legs)")
missing = alone("Sources/ContinuumRevived/App/NoLegCoversThis.swift")
expect(missing["full"] and "covered by no specific leg" in missing["full_reasons"][0],
       f"an unmapped file forces the full matrix: {missing['full_reasons']}")
expect(alone("scripts/run-matrix.sh")["full"], "run-matrix.sh with no range to read forces the full matrix")
expect(alone("Package.swift")["full"], "Package.swift forces the full matrix")
expect(alone(APP)["full"], "the dispatcher with no range to read forces the full matrix")
inert = alone(".plans/notes.md", "docs/VERSIONING.md")
expect(not inert["full"] and not inert["legs"], "release paths select nothing")
script = alone("scripts/check-notification-map.py")
expect(not script["full"] and any(leg.startswith("python3 scripts/check-notification-map.py") for leg in script["legs"]),
       f"a script selects the leg that runs it: {script['legs'][:3]}")

drop = synthetic(repo, HEAD, "scripts/run-matrix.sh",
                 lambda text: text.replace("run_app_check .build/debug/Array --subagent-sidebar-open-check\n", "", 1))
dropped = lc.select(repo, drop, ["scripts/run-matrix.sh"], built=built, base=HEAD)
expect(dropped["full"], "removing a leg from run-matrix.sh forces the full matrix")
boot = synthetic(repo, HEAD, APP, lambda text: text.replace("import AppKit\n", "import AppKit\nlet bootTweak = 1\n", 1))
booted = lc.select(repo, boot, [APP], built=built, base=HEAD)
expect(booted["full"], "dispatcher code that adds no flag forces the full matrix")

if failures:
    print(f"FAIL {len(failures)} leg-coverage case(s)")
    sys.exit(1)
print("PASS affected-legs selection: real range narrowed, unmapped and structural changes fail safe")
