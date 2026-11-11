"""The live pilot's two tasks, built from this repository's own history.

Each task is a small fixture repository: the real files of the pre-pass
script at the parent of a real fix, and, in the fix commit, the real fixed
files plus a hidden check. The hidden checks are written here, on the host,
because the real fix commits carry no check the grader can run in isolation
(their own witness needs git in the grading sandbox). `replay.validate`
must show each hidden check failing by assertion on the parent and passing on
the real fix before a task is written.

usage: pilot_tasks.py REPO OUT_DIR   (writes OUT_DIR/<task>/task.json)"""
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import replay  # noqa: E402

FILES = ['scripts/gate-prepass.py', 'scripts/check-coverage-manifest.json', 'scripts/check-gate-prepass.py']

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

TASKS = [
    dict(name='prepass-deleted-once', parent='ac055cd22~1', fix='ac055cd22',
         hidden={'checks/hidden_deleted_once.py': DELETED_ONCE},
         request=("In scripts/gate-prepass.py, the coverage section of the report lists a deleted file twice: "
                  "once with status D and again as 'old path of D'. A deleted file should be listed once, "
                  "with its own status. Renamed files should still list both the new path and the old path. "
                  "Fix it.")),
    dict(name='prepass-targeted-only', parent='2f96d775c~1', fix='2f96d775c',
         hidden={'checks/hidden_targeted_only.py': TARGETED},
         request=("scripts/gate-prepass.py fails every newly dispatched --*-check flag that no matrix leg and no "
                  "bundle-harness list runs. Some checks can only be run by hand, for example because they need "
                  "a real display. Let the coverage manifest (scripts/check-coverage-manifest.json) declare such "
                  "checks in an optional top-level list `targetedOnly` of objects "
                  "{\"flag\": \"--some-check\", \"reason\": \"...\"}. A declared flag must not be reported as "
                  "unregistered (or as uncertain). Validate the list in load_manifest like the rest of the "
                  "manifest: it must be a list, each entry an object, each flag an exact --*-check flag that is "
                  "not duplicated, and each reason a non-empty single line. An invalid entry is a manifest "
                  "problem, reported the same way as the others.")),
]


def git(repo, *args, data=None):
    return subprocess.run(['git', '-C', str(repo), *args], input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def commit(repo, message):
    git(repo, 'add', '-A')
    git(repo, '-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', message)
    return git(repo, 'rev-parse', 'HEAD').decode().strip()


def build(source_repo, out, spec):
    root = Path(out) / spec['name']
    repo = root / 'source'
    repo.mkdir(parents=True)
    git(repo, 'init', '-q')
    for rel in FILES:
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_bytes(git(source_repo, 'show', '%s:%s' % (spec['parent'], rel)))
    (repo / 'checks').mkdir()
    (repo / 'checks' / 'neighbour_prepass.py').write_text(NEIGHBOUR)
    base = commit(repo, 'fixture: pre-pass at the parent of the fix')
    for rel in FILES:
        (repo / rel).write_bytes(git(source_repo, 'show', '%s:%s' % (spec['fix'], rel)))
    for rel, text in spec['hidden'].items():
        (repo / rel).write_text(text)
    fix = commit(repo, 'fixture: the fix as it landed, with its hidden check')
    task = replay.make_task(repo, base, fix, spec['request'], spec['name'], sorted(spec['hidden']),
                            ['checks/neighbour_prepass.py'], ['checks/'])
    task['origin'] = dict(parent=git(source_repo, 'rev-parse', spec['parent']).decode().strip(),
                          fix=git(source_repo, 'rev-parse', spec['fix']).decode().strip())
    if not replay.validate(task):
        raise SystemExit('%s: hidden check does not fail on the parent and pass on the fix' % spec['name'])
    (root / 'task.json').write_text(json.dumps(task, sort_keys=True))
    return root / 'task.json'


def main(argv):
    for spec in TASKS:
        print(build(Path(argv[0]), Path(argv[1]), spec))


if __name__ == '__main__':
    main(sys.argv[1:])
