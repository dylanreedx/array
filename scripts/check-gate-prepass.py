#!/usr/bin/env python3
"""Fixture witness for scripts/gate-prepass.py.

Builds disposable Git histories under /tmp, runs the real pre-pass CLI on each
range, and asserts its exit status and its exact findings: RED on every
violation it claims to catch, GREEN on the clean and the excused cases.

    python3 scripts/check-gate-prepass.py [--prepass PATH] [--keep]

`--prepass` points at another copy of the script (a missing path or a mutated
copy must turn this witness red). Git runs with no global or system config, so
the user's hooks, signing and identity never touch the fixtures.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Assembled from parts so check-notification-map.py does not count these
# fixture strings as a real sender; the fixture files still contain the call.
BANNER_CALL = "UNNotification" + "Request("
ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
           GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
           GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
           GIT_AUTHOR_DATE="2000-01-01T00:00:00Z", GIT_COMMITTER_DATE="2000-01-01T00:00:00Z")
for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    ENV.pop(key, None)

APP = "Sources/ContinuumRevived/App/ContinuumApp.swift"
MATRIX = "scripts/run-matrix.sh"
MANIFEST = "scripts/check-coverage-manifest.json"
ALPHA = ".build/debug/Array --alpha-check"
BETA = ".build/debug/Array --beta-check"
BUNDLE = "scripts/check-app-bundle.sh --configuration debug"
CORE = ".build/debug/ContinuumRevivedCoreChecks --core-check"

BASE_APP = """import Foundation
enum ContinuumApp {
    static func main() {
        if CommandLine.arguments.contains("--alpha-check") { exit(0) }
        if CommandLine.arguments.contains("--legacy-unregistered-check") { exit(0) }
        // anchor
    }
}
"""
BASE_MATRIX = """#!/usr/bin/env bash
MATRIX_KNOWN_RED=(
  --knownred-only-check # documented red
)
# --commented-check used to run here
run_app_check .build/debug/Array --alpha-check
ARRAY_X=1 run_app_check .build/debug/Array --beta-check
run_leg .build/debug/ContinuumRevivedCoreChecks --core-check
printf '\\n==> SKIPPED (display-dependent): --skipped-only-check\\n'
export PREVIEW_ARRAY_CHECK=--assigned-only-check
run_leg scripts/check-app-bundle.sh --configuration debug
"""
BASE_BUNDLE = """#!/usr/bin/env bash
# --bundle-comment-check is documented here but not run
self_checks=(--bundle-a-check --bundle-only-check)
for check in "${self_checks[@]}"; do
  if [[ "$check" == --compared-only-check ]]; then :; fi
done
"""
BASE_MANIFEST = {
    "version": 1,
    "checks": [
        {"invocation": ALPHA, "covers": ["Sources/ContinuumRevived/Canvas/**"],
         "checkFiles": ["Sources/ContinuumRevived/App/AlphaChecks.swift"], "owner": "canvas", "reason": "canvas"},
        {"invocation": BETA, "covers": ["Sources/ContinuumRevived/Canvas/Tile*.swift"], "owner": "canvas", "reason": "tiles"},
        {"invocation": BUNDLE, "covers": ["Package.swift", "Sources/*/Resources/**"], "owner": "packaging", "reason": "bundle"},
        {"invocation": CORE, "covers": ["Sources/ContinuumRevivedCore/**"], "owner": "core", "reason": "core"},
    ],
    "exceptions": [],
}
BASE_FILES = {
    APP: BASE_APP,
    MATRIX: BASE_MATRIX,
    "scripts/check-app-bundle.sh": BASE_BUNDLE,
    MANIFEST: json.dumps(BASE_MANIFEST, indent=2) + "\n",
    "Package.swift": "// swift-tools-version:5.9\n",
    "Sources/ContinuumRevived/Canvas/TileView.swift": "struct TileView {\n    var width = 1\n}\n",
    "Sources/ContinuumRevived/Canvas/TileModel.swift": "struct TileModel {}\n",
    "Sources/ContinuumRevived/Canvas/Board.swift": "struct Board {}\n",
    "Sources/ContinuumRevived/App/AlphaChecks.swift": "enum AlphaChecks {}\n",
    "Sources/ContinuumRevived/App/Legacy.swift":
        "import Foundation\nlet legacyURL = Bundle.module.url(forResource: \"x\", withExtension: nil)\nlet legacyName = \"a\"\n",
    "Sources/ContinuumRevived/App/Notify.swift":
        "import UserNotifications\nlet request = " + BANNER_CALL + "identifier: \"a\", content: content, trigger: nil)\nlet extra = 1\n",
    "Sources/ContinuumRevivedCore/Plain.swift": "struct Plain {}\n",
    "Sources/ContinuumRevivedCore/Resources/data.json": "{}\n",
    "docs/internals/notification-senders.json":
        json.dumps({"Sources/ContinuumRevived/App/Notify.swift": {"local-banner": {"count": 1, "paths": ["MAC-01"]}}}) + "\n",
    "docs/internals/notification-paths.md": "# Notification paths\n\n| MAC-01 | banner |\n",
    "history/2025-01-01.md": "old\n",
    "runs/2025-01-01/old.md": "old\n",
}


class Failure(Exception):
    pass


class Fixture:
    def __init__(self, root):
        self.root = Path(root)
        self.git("init", "-q", "-b", "main")

    def git(self, *args, ok=(0,)):
        proc = subprocess.run(["git", "-C", str(self.root), *args], env=ENV,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode not in ok:
            raise Failure("fixture git %s failed: %s" % (" ".join(args), proc.stderr.strip()))
        return proc.stdout.strip()

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def read(self, path):
        return (self.root / path).read_text()

    def edit(self, path, old, new):
        text = self.read(path)
        if old not in text:
            raise Failure("fixture edit: %r not in %s" % (old, path))
        self.write(path, text.replace(old, new, 1))

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "--allow-empty-message", "-m", message)
        return self.git("rev-parse", "HEAD")

    def start(self, name, at="base"):
        self.git("checkout", "-q", "-B", name, at)


def run_prepass(prepass, fixture, *args):
    proc = subprocess.run([sys.executable, str(prepass), *args, "--repo", str(fixture.root), "--json"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        report = json.loads(proc.stdout) if proc.stdout.strip() else {}
    except ValueError:
        report = {}
    return proc.returncode, report, proc.stderr


def summary(report, subjects):
    out = []
    for f in report.get("findings", []):
        locator = f.get("flag") or (("commit:" + subjects.get(f["commit"], f["commit"])) if f.get("commit") else f.get("path", ""))
        out.append((f["severity"], f["rule"], locator))
    return sorted(out)


def messages(want):
    """A check that each (flag or path, text) finding message contains text."""
    def check(report):
        for key, text in want:
            got = [f["message"] for f in report["findings"] if key in (f.get("flag"), f.get("path"))]
            if not any(text in m for m in got):
                return "no finding for %s says %r: %s" % (key, text, got)
    return check


class Witness:
    def __init__(self, prepass, fixture):
        self.prepass, self.fx = prepass, fixture
        self.passed, self.failed = 0, []

    def subjects(self):
        out = self.fx.git("log", "--all", "--format=%H%x00%s")
        mapping = {}
        for line in out.splitlines():
            sha, subject = line.split("\0", 1)
            mapping[sha[:9]] = subject
        return mapping

    def expect(self, name, args, code, findings=None, check=None):
        status, report, stderr = run_prepass(self.prepass, self.fx, *args)
        problems = []
        if status != code:
            problems.append("exit %d, expected %d (stderr: %s)" % (status, code, stderr.strip()[-300:]))
        if findings is not None:
            got = summary(report, self.subjects())
            want = sorted(findings)
            if got != want:
                problems.append("findings differ\n      got:  %s\n      want: %s" % (got, want))
        if check is not None and not problems:
            message = check(report)
            if message:
                problems.append(message)
        if problems:
            self.failed.append(name)
            print("FAIL  %s\n    %s" % (name, "\n    ".join(problems)))
        else:
            self.passed += 1
            print("ok    %s  (exit %d)" % (name, status))
        return report


def build_base(fx):
    for path, text in BASE_FILES.items():
        fx.write(path, text)
    fx.commit("chore(fixture): seed the base tree")
    fx.git("branch", "base")


def cases(w):
    fx = w.fx
    F, A, X, I = "fail", "advisory", "excepted", "info"
    U = (A, "coverage-unmapped", "")  # changed code no manifest entry covers

    # 1. Clean change: green, mapped to both overlapping globs.
    fx.start("clean")
    fx.edit("Sources/ContinuumRevived/Canvas/TileView.swift", "width = 1", "width = 2")
    fx.commit("fix(canvas): keep tiles in place")

    def clean_checks(report):
        got = [(c["invocation"], [p["path"] for p in c["paths"]]) for c in report["checks"]]
        want = [(ALPHA, ["Sources/ContinuumRevived/Canvas/TileView.swift"]),
                (BETA, ["Sources/ContinuumRevived/Canvas/TileView.swift"])]
        if got != want or report["unmapped"]:
            return "coverage %s unmapped %s" % (got, report["unmapped"])
    w.expect("clean range is green and maps overlapping globs", ["base", "clean"], 0, [], clean_checks)

    # 2. Commit subjects, one commit per violation, plus legal forms.
    fx.start("subjects")
    bad = ["Fix the canvas.", "feat(Canvas): add tiles", "feat(canvas): Add tiles", "feat(canvas): add tiles.",
           "wip(canvas): add tiles", "feat(canvas): " + "a" * (72 - len("feat(canvas): ")), "",
           'Revert "fix(canvas): keep tiles in place"', "feat(canvas):add tiles", "feat(canvas_ui): add tiles"]
    good = ["feat(canvas): " + "a" * (71 - len("feat(canvas): ")), "feat(api)!: drop the old route",
            "refactor(data-table): key rows by id"]
    for message in bad + good:
        fx.commit(message)
    fx.git("checkout", "-q", "-b", "side")
    fx.commit("fix(canvas): side work")
    fx.git("checkout", "-q", "subjects")
    fx.commit("fix(canvas): main work")
    fx.git("merge", "-q", "--no-ff", "-m", "Merge branch 'side'", "side")
    fx.commit("chore: bump everything")
    expected = [(F, "commit-subject", "commit:" + s) for s in bad]
    expected += [(F, "commit-subject", "commit:Merge branch 'side'"), (A, "commit-subject", "commit:chore: bump everything")]
    def git_subject_message(report):
        for f in report["findings"]:
            if f["subject"].startswith(("Merge branch", 'Revert "')) and not (
                    "no exceptions" in f["message"] and "chore(release): merge" in f["message"]
                    and "revert(sidebar):" in f["message"]):
                return "git-generated subject message does not explain the accepted form: %s" % f["message"]
    w.expect("every malformed subject fails; merges fail and area-less is advisory", ["base", "subjects"], 1, expected,
             git_subject_message)
    fx.start("advisory-only")
    fx.commit("chore: bump everything")
    w.expect("advisory-only range exits 0", ["base", "advisory-only"], 0,
             [(A, "commit-subject", "commit:chore: bump everything")])

    # 3. Attribution trailers.
    fx.start("trailers")
    fx.commit("fix(canvas): keep tiles\n\nThe claude runner keeps its tiles.\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
    fx.commit("fix(canvas): keep more tiles\n\n\U0001F916 Generated with [Claude Code](https://claude.com/claude-code)")
    fx.commit("feat(agents): run the claude runner headless\n\nThe Claude runner owns its auth; codex too.")
    w.expect("attribution trailers fail, prose about Claude passes", ["base", "trailers"], 1, [
        (F, "commit-attribution", "commit:fix(canvas): keep tiles"),
        (F, "commit-attribution", "commit:fix(canvas): keep more tiles")])

    # 4. A new flag registered nowhere.
    fx.start("new-flag")
    fx.edit(APP, "        // anchor", '        if CommandLine.arguments.contains("--brand-new-check") { exit(0) }\n        // anchor')
    fx.commit("test(canvas): add the brand new check")
    w.expect("new --*-check registered nowhere fails", ["base", "new-flag"], 1,
             [U, (F, "unregistered-check-flag", "--brand-new-check")])

    fx.start("targeted-only", "new-flag")
    manifest = json.loads(fx.read(MANIFEST))
    manifest["targetedOnly"] = [{"flag": "--brand-new-check", "reason": "requires a real display"}]
    fx.write(MANIFEST, json.dumps(manifest) + "\n")
    fx.commit("test(canvas): declare the targeted display check")
    w.expect("targeted-only flag with a reason passes", ["base", "targeted-only"], 0, [U])
    manifest["targetedOnly"] = []
    fx.write(MANIFEST, json.dumps(manifest) + "\n")
    fx.commit("test(canvas): remove the targeted declaration")
    w.expect("removing targeted-only declaration fails", ["base", "targeted-only"], 1,
             [U, (F, "unregistered-check-flag", "--brand-new-check")])
    manifest["targetedOnly"] = [{"flag": "--brand-new-check"}]
    fx.write(MANIFEST, json.dumps(manifest) + "\n")
    fx.commit("test(canvas): omit the targeted reason")
    w.expect("targeted-only entry without a reason fails", ["base", "targeted-only"], 2, [])

    # 5. A flag registered only in the bundle harness's self_checks.
    fx.start("bundle-only")
    fx.edit(APP, "        // anchor", '        if CommandLine.arguments.contains("--bundle-only-check") { exit(0) }\n        // anchor')
    fx.commit("test(packaging): dispatch the bundle-only check")
    w.expect("flag registered only in the bundle harness passes", ["base", "bundle-only"], 0, [U])

    fx.start("bundle-unreached", "bundle-only")
    fx.edit(MATRIX, "run_leg scripts/check-app-bundle.sh --configuration debug\n", "")
    fx.commit("test(packaging): remove the bundle invocation")
    w.expect("unreached bundle harness does not register flags", ["base", "bundle-unreached"], 1, [
        U, (F, "unregistered-check-flag", "--bundle-only-check"),
        (F, "manifest-stale", MANIFEST)])

    # 6. Mentions that are not invocations do not register a flag.
    fx.start("skip-only")
    lines = "".join('        if CommandLine.arguments.contains("%s") { exit(0) }\n' % f for f in
                    ("--skipped-only-check", "--knownred-only-check", "--commented-check",
                     "--compared-only-check", "--bundle-comment-check", "--assigned-only-check"))
    fx.edit(APP, "        // anchor", lines + "        // anchor")
    fx.commit("test(canvas): dispatch flags the matrix only mentions")
    w.expect("skip-only, known-red, comment and comparison mentions fail", ["base", "skip-only"], 1, [U,
        (F, "unregistered-check-flag", "--skipped-only-check"), (F, "unregistered-check-flag", "--knownred-only-check"),
        (F, "unregistered-check-flag", "--commented-check"), (F, "unregistered-check-flag", "--compared-only-check"),
        (F, "unregistered-check-flag", "--bundle-comment-check"),
        (A, "uncertain-check-flag", "--assigned-only-check")])

    # 7. Dispatch text inside comments is not a dispatch.
    fx.start("comment-flag")
    fx.edit(APP, "        // anchor", '        // if CommandLine.arguments.contains("--ghost-check") {\n'
            '        /* old:\n        if CommandLine.arguments.contains("--ghost-two-check") { exit(0) }\n        */\n        // anchor')
    fx.commit("docs(canvas): note the retired ghost checks")
    w.expect("dispatch text inside comments is ignored", ["base", "comment-flag"], 0, [U])

    # 8. Moving an existing (unregistered) dispatch and editing near old debt.
    fx.start("moved-debt")
    fx.edit(APP, '        if CommandLine.arguments.contains("--legacy-unregistered-check") { exit(0) }\n', "")
    fx.write("Sources/ContinuumRevived/App/LegacyDispatch.swift",
             'func legacyDispatch() {\n    if CommandLine.arguments.contains("--legacy-unregistered-check") { exit(0) }\n}\n')
    fx.edit("Sources/ContinuumRevived/App/Legacy.swift", 'legacyName = "a"', 'legacyName = "b"')
    fx.commit("refactor(canvas): move the legacy dispatch out")
    w.expect("moved dispatch and untouched debt stay green", ["base", "moved-debt"], 0, [U])

    # 9. Other dispatch forms; registering in the same range counts.
    fx.start("forms")
    fx.edit(APP, "        // anchor",
            '        if CommandLine.arguments.contains("--new-registered-check") { exit(0) }\n'
            '        for (flag, run) in [\n            ("--table-row-check", Runner.run),\n        ] { _ = (flag, run) }\n'
            '        switch CommandLine.arguments.last {\n        case "--switch-check": exit(0)\n        default: break\n        }\n'
            '        if let index = CommandLine.arguments.firstIndex(of: "--indexed-check") { _ = index }\n'
            '        // anchor')
    fx.write("Sources/ContinuumRevived/App/LiveFlag.swift", 'enum LiveFlag {\n    static let liveFlag = "--dynamic-check"\n}\n')
    fx.edit(MATRIX, "run_leg scripts/check-app-bundle.sh", "run_app_check .build/debug/Array --new-registered-check\nrun_leg scripts/check-app-bundle.sh")
    fx.commit("test(canvas): add checks in every dispatch form")
    w.expect("table-row, case and firstIndex forms are parsed; same-range registration passes", ["base", "forms"], 1, [U,
        (F, "unregistered-check-flag", "--table-row-check"), (F, "unregistered-check-flag", "--switch-check"),
        (F, "unregistered-check-flag", "--indexed-check"), (A, "uncertain-check-flag", "--dynamic-check")])

    # 10. Bundle.module: code fails; comments, strings and checks targets do not.
    fx.start("bundle-module")
    fx.write("Sources/ContinuumRevivedCore/Lookup.swift",
             'import Foundation\n// never Bundle.module here\nlet note = "Bundle.module traps"\n'
             'let url = Bundle.module.url(forResource: "x", withExtension: nil)\n')
    fx.write("Sources/ContinuumRevivedCoreChecks/Fixture.swift",
             'import Foundation\nlet fixtureURL = Bundle.module.url(forResource: "f", withExtension: nil)\n')
    fx.commit("fix(core): look the resource up")
    w.expect("added Bundle.module fails only in code outside checks", ["base", "bundle-module"], 1,
             [U, (F, "bundle-module", "Sources/ContinuumRevivedCore/Lookup.swift")])

    # 11. Moving a file that holds Bundle.module is moved code: it fails.
    fx.start("bundle-moved")
    fx.git("mv", "Sources/ContinuumRevived/App/Legacy.swift", "Sources/ContinuumRevived/App/LegacyMoved.swift")
    fx.commit("refactor(canvas): rename the legacy file")
    w.expect("moved Bundle.module code fails", ["base", "bundle-moved"], 1,
             [U, (F, "bundle-module", "Sources/ContinuumRevived/App/LegacyMoved.swift")])

    # 12. A reviewed, line-specific exception is reported, not silent.
    fx.start("excepted", "bundle-module")
    manifest = json.loads(fx.read(MANIFEST))
    manifest["exceptions"] = [{"rule": "bundle-module", "path": "Sources/ContinuumRevivedCore/Lookup.swift",
                               "match": 'let url = Bundle.module.url(forResource: "x", withExtension: nil)',
                               "reason": "runs only from the build directory", "owner": "core"}]
    fx.write(MANIFEST, json.dumps(manifest, indent=2) + "\n")
    fx.commit("chore(core): except the reviewed resource lookup")
    w.expect("excepted line is reported as excepted and exits 0", ["base", "excepted"], 0,
             [U, (X, "bundle-module", "Sources/ContinuumRevivedCore/Lookup.swift")])
    manifest["exceptions"][0]["owner"] = ""
    fx.write(MANIFEST, json.dumps(manifest, indent=2) + "\n")
    fx.commit("chore(core): drop the exception owner")
    w.expect("exception without an owner is a script error (exit 2)", ["base", "excepted"], 2, [])

    # 13. Choice menus are advisory.
    fx.start("menus")
    fx.write("Sources/ContinuumRevived/App/Picker.swift",
             'import AppKit\nlet menu = NSMenu(title: "Pick")\nlet item = NSMenuItem()\n// an NSPopUpButton was here\n')
    fx.commit("feat(settings): add a picker")
    w.expect("NSMenu is advisory; NSMenuItem and comments are not", ["base", "menus"], 0,
             [U, (A, "choice-menu", "Sources/ContinuumRevived/App/Picker.swift")])

    # 14. Notification senders without a map change are advisory.
    fx.start("notify")
    fx.write("Sources/ContinuumRevived/App/Banner.swift",
             'let banner = ' + BANNER_CALL + 'identifier: "b", content: content, trigger: nil)\n')
    fx.edit("Sources/ContinuumRevived/App/Notify.swift", "extra = 1", "extra = 2")
    fx.commit("feat(notifications): add a banner")
    w.expect("sender added or touched without the map is advisory", ["base", "notify"], 0, [U,
        (A, "notification-map", "Sources/ContinuumRevived/App/Banner.swift"),
        (A, "notification-map", "Sources/ContinuumRevived/App/Notify.swift")])
    fx.edit("docs/internals/notification-paths.md", "| MAC-01 | banner |", "| MAC-01 | banner |\n| MAC-02 | new banner |")
    fx.commit("docs(notifications): map the new banner")
    w.expect("the same change with a map edit is clean apart from coverage", ["base", "notify"], 0, [U])

    # 15. New dated names are advisory; existing ones are not rescanned.
    fx.start("dated")
    fx.write("notes/run-2026-11-10/a.md", "x\n")
    fx.write("fixtures/capture-20261110.json", "{}\n")
    fx.write("history/2025-01-01.md", "edited\n")
    fx.write("runs/2025-01-01/new.md", "inside an existing dated folder\n")
    fx.commit("docs(notes): add run notes")
    w.expect("new dated path components are advisory", ["base", "dated"], 0, [
        (A, "dated-path", "fixtures/capture-20261110.json"), (A, "dated-path", "notes/run-2026-11-10/a.md")])

    # 16. Renames, deletes, check files and unmapped paths in the coverage map.
    fx.start("coverage")
    (fx.root / "Sources/ContinuumRevived/Other").mkdir(parents=True, exist_ok=True)
    fx.git("mv", "Sources/ContinuumRevived/Canvas/Board.swift", "Sources/ContinuumRevived/Other/Board.swift")
    fx.git("rm", "-q", "Sources/ContinuumRevived/Canvas/TileView.swift")
    fx.edit("Sources/ContinuumRevived/App/AlphaChecks.swift", "{}", "{ static let v = 1 }")
    fx.write("Sources/ContinuumRevived/Other/Unmapped.swift", "struct Unmapped {}\n")
    fx.write("Package.swift", "// swift-tools-version:5.10\n")
    fx.write("docs/readme.md", "words\n")
    fx.commit("refactor(canvas): move the board out of the canvas")

    def coverage_checks(report):
        got = {c["invocation"]: (sorted((p["path"], p["status"]) for p in c["paths"]), c["checkFilesChanged"])
               for c in report["checks"]}
        want = {
            ALPHA: ([("Sources/ContinuumRevived/Canvas/Board.swift", "old path of R"),
                     ("Sources/ContinuumRevived/Canvas/TileView.swift", "D")],
                    ["Sources/ContinuumRevived/App/AlphaChecks.swift"]),
            BETA: ([("Sources/ContinuumRevived/Canvas/TileView.swift", "D")], []),
            BUNDLE: ([("Package.swift", "M")], []),
        }
        unmapped = ["Sources/ContinuumRevived/Other/Board.swift", "Sources/ContinuumRevived/Other/Unmapped.swift"]
        if got != want or report["unmapped"] != unmapped:
            return "coverage %s\n      unmapped %s" % (got, report["unmapped"])
    w.expect("renamed, deleted and check-file paths map; unmapped code is reported", ["base", "coverage"], 0, [U],
             coverage_checks)

    # 17. A manifest entry this range made stale fails; old staleness does not.
    fx.start("stale")
    fx.edit(MATRIX, "run_leg .build/debug/ContinuumRevivedCoreChecks --core-check\n", "")
    manifest = json.loads(fx.read(MANIFEST))
    manifest["checks"].append({"invocation": ALPHA.replace("alpha", "beta"), "covers": ["Sources/Nowhere/**"],
                               "owner": "canvas", "reason": "typo"})
    manifest["checks"][1]["invocation"] = ".build/debug/Array --beta-check"
    fx.write(MANIFEST, json.dumps(manifest, indent=2) + "\n")
    fx.commit("chore(matrix): drop the core leg")
    w.expect("duplicate manifest invocation is a script error", ["base", "stale"], 2, [])
    manifest["checks"][-1]["invocation"] = BETA + " --again"
    fx.write(MANIFEST, json.dumps(manifest, indent=2) + "\n")
    fx.commit("chore(matrix): name a leg that does not exist")
    w.expect("dropped leg and dead glob fail as manifest-stale", ["base", "stale"], 1, [U,
        (F, "manifest-stale", MANIFEST), (F, "manifest-stale", MANIFEST), (F, "manifest-stale", MANIFEST)])
    fx.start("stale-later", "stale")
    fx.write("Sources/ContinuumRevived/Canvas/TileView.swift", "struct TileView { var width = 3 }\n")
    fx.commit("fix(canvas): resize tiles")
    w.expect("staleness already present at base does not fail a later range", ["stale", "stale-later"], 0, [])

    # 19. Every checks target is examined, in every dispatch form, against its own binary.
    fx.start("targets")
    fx.write("Sources/ContinuumRevivedCoreChecks/main.swift",
             'import Foundation\n'
             'if CommandLine.arguments.contains("--core-new-check") { exit(0) }\n'
             'if CommandLine.arguments.contains("--core-registered-check") { exit(0) }\n'
             'if CommandLine.arguments.contains("--core-mismatch-check") { exit(0) }\n')
    fx.write("Sources/ContinuumRevivedCoreChecks/NewChecks.swift",
             'enum NewChecks {\n    static let flag = "--core-new-check"\n}\n')
    fx.write("Sources/ContinuumRevivedSyncChecks/main.swift",
             'import Foundation\nif CommandLine.arguments.contains("--sync-new-check") { exit(0) }\n')
    fx.write("Sources/ContinuumRevivedPaletteChecks/main.swift",
             'import Foundation\nfor flag in ["--palette-loop-check"] {\n    let process = Process()\n'
             '    process.arguments = [flag]\n}\n')
    fx.edit(APP, "        // anchor",
            '        if CommandLine.arguments.contains(\n            "--wrapped-check") { exit(0) }\n'
            '        if CommandLine.arguments.contains(where: { $0 == "--where-check" }) { exit(0) }\n'
            '        for flag in ["--loop-a-check"] where CommandLine.arguments.contains(flag) { exit(0) }\n'
            '        switch CommandLine.arguments.last {\n        case "--case-a-check", "--case-b-check": exit(0)\n'
            '        default: break\n        }\n'
            '        let held = ["--array-held-check"]\n'
            '        if ProcessInfo.processInfo.arguments.contains("--receiver-check") { exit(0) }\n'
            '        let built = "--\\(name)-check"\n'
            '        let suffixed = name + "-check"\n'
            '        let prefixed = "--" + name.appending("-check")\n'
            '        let family = arg.hasPrefix("--sidebar-") && arg.hasSuffix("-check")\n'
            '        let family2 = arg.hasSuffix("-check") && arg.hasPrefix("--zone-")\n'
            '        // anchor')
    fx.edit(MATRIX, "run_leg scripts/check-app-bundle.sh",
            "run_leg .build/debug/ContinuumRevivedCoreChecks --core-registered-check\n"
            "run_app_check .build/debug/Array --core-mismatch-check\nrun_leg scripts/check-app-bundle.sh")
    fx.commit("test(checks): dispatch flags from every checks target")
    built = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    w.expect("checks targets, wrapped, closure, loop, multi-case and built flags are all examined",
             ["base", "targets"], 1, [U,
        (F, "unregistered-check-flag", "--core-new-check"), (F, "unregistered-check-flag", "--sync-new-check"),
        (F, "unregistered-check-flag", "--core-mismatch-check"), (A, "uncertain-check-flag", "--palette-loop-check"),
        (F, "unregistered-check-flag", "--wrapped-check"), (F, "unregistered-check-flag", "--where-check"),
        (F, "unregistered-check-flag", "--loop-a-check"), (F, "unregistered-check-flag", "--case-a-check"),
        (F, "unregistered-check-flag", "--case-b-check"), (A, "uncertain-check-flag", "--array-held-check"),
        (A, "uncertain-check-flag", "--receiver-check")] + [(A, "built-check-flag", built)] * 5,
             messages([("--core-mismatch-check", "another executable"), ("--core-new-check", "undeclared")]))

    # 20. "Registered" means a full run reaches the leg, with that exact flag.
    fx.start("reach")
    flags = ["--heredoc-check", "--if-false-check", "--uncalled-check", "--called-check", "--mode-only-check",
             "--extra-check", "--continued-check", "--loop-one-check", "--loop-two-check", "--array-one-check",
             "--opt-in-check", "--and-check", "--after-exit-check", "--commented-heredoc-check", "--comment-tail-check"]
    fx.edit(APP, "        // anchor",
            "".join('        if CommandLine.arguments.contains("%s") { exit(0) }\n' % f for f in flags) + "        // anchor")
    fx.edit(MATRIX, "run_leg scripts/check-app-bundle.sh --configuration debug\n",
            "run_leg scripts/check-app-bundle.sh --configuration debug\n"
            ": <<'DISABLED'\nrun_app_check .build/debug/Array --heredoc-check\nDISABLED\n"
            "cat <<-EOF # --commented-heredoc-check\n\trun_app_check .build/debug/Array --commented-heredoc-check\n\tEOF\n"
            "if false; then\n  run_app_check .build/debug/Array --if-false-check\nfi\n"
            "never_called() {\n  run_app_check .build/debug/Array --uncalled-check\n}\n"
            "called() {\n  run_app_check .build/debug/Array --called-check\n}\ncalled\n"
            'if [[ "$BROWSER_SCHEDULING_ONLY" -eq 1 ]]; then\n'
            "  run_app_check .build/debug/Array --mode-only-check\n  exit $?\nfi\n"
            "run_app_check .build/debug/Array --extra-check-extra\n"
            "run_app_check .build/debug/Array --called-check # --comment-tail-check\n"
            "run_app_check .build/debug/Array \\\n  --continued-check\n"
            'for f in --loop-one-check --loop-two-check; do\n  run_app_check .build/debug/Array "$f"\ndone\n'
            "LIST=(\n  --array-one-check # listed\n)\n"
            'for f in "${LIST[@]}"; do run_app_check .build/debug/Array "$f"; done\n'
            'if [[ "${CONTINUUM_OPT_IN:-0}" == "1" ]]; then\n  run_app_check .build/debug/Array --opt-in-check\nfi\n'
            '[[ -n "${X:-}" ]] && run_app_check .build/debug/Array --and-check\n'
            "exit 0\nrun_app_check .build/debug/Array --after-exit-check\n")
    fx.commit("test(matrix): run checks from every shell construct")
    w.expect("heredoc, false, uncalled, mode-only, suffix and after-exit legs are not run; the rest are",
             ["base", "reach"], 1, [U,
        (F, "unregistered-check-flag", "--heredoc-check"), (F, "unregistered-check-flag", "--commented-heredoc-check"),
        (F, "unregistered-check-flag", "--if-false-check"), (F, "unregistered-check-flag", "--uncalled-check"),
        (F, "unregistered-check-flag", "--mode-only-check"), (F, "unregistered-check-flag", "--extra-check"),
        (F, "unregistered-check-flag", "--after-exit-check"), (F, "unregistered-check-flag", "--comment-tail-check"),
        (A, "uncertain-check-flag", "--opt-in-check"), (A, "uncertain-check-flag", "--and-check")],
             messages([("--heredoc-check", "undeclared"), ("--if-false-check", "never true"),
                       ("--uncalled-check", "nothing calls"), ("--mode-only-check", "BROWSER_SCHEDULING_ONLY"),
                       ("--after-exit-check", "unconditional exit"), ("--extra-check", "undeclared"),
                       ("--opt-in-check", "CONTINUUM_OPT_IN"), ("--and-check", "after &&")]))

    # 21. Attribution in the subject or the body, in every form; prose about a product passes.
    fx.start("attribution")
    attributed = [
        "fix(canvas): keep tiles Co-Authored-By: Claude",
        "fix(canvas): keep tiles Generated with Claude Code",
        "fix(canvas): keep tile order\n\nCo-Authored-By: Pat Example <pat@example.com>",
        "fix(canvas): keep tile size\n\nPairing: bot <noreply@anthropic.com>",
        "fix(canvas): keep tile zone\n\nAssisted-by: Codex",
        "fix(canvas): keep tile title\n\nCo-authored with Claude",
        "fix(canvas): keep tile frame\n\nCreated with Claude Code",
        "fix(canvas): keep tile focus\n\nWritten by Claude.",
        "fix(canvas): keep tile scroll\n\ngenerated with ChatGPT",
    ]
    clean_prose = [
        "fix(claude-runner): pass the effort flag",
        "fix(titles): keep titles written by claude",
        "fix(models): list what codex offers\n\nThe models are generated by codex's model/list handshake.\n"
        "Written by the Claude runner on every turn.\n\nSigned-off-by: Dylan <dylan@example.invalid>",
    ]
    for message in attributed + clean_prose:
        fx.commit(message)
    w.expect("attribution fails in subject and body; product mentions pass", ["base", "attribution"], 1,
             [(F, "commit-attribution", "commit:" + m.split("\n")[0]) for m in attributed])

    # 22. Ticket ids and hedging are advisory; versions, plans and builds are not ticket ids.
    fx.start("message-advisories")
    tickets = ["fix(canvas): keep tiles for ticket 91", "fix(canvas): keep tiles\n\nCloses #42",
               "fix(canvas): keep zones\n\nTracked in CX-01.", "fix(canvas): finish the P1.7 tiles"]
    hedges = ["fix(canvas): attempt to fix the drift", "fix(canvas): pin zones\n\nThis should fix the drift.",
              "fix(canvas): pin tiles\n\nHopefully the last one.", "fix(canvas): tentative fix for drift"]
    legit = ["chore(release): ship 0.7.46 (build 97)", "docs(plans): record plan 113 in .plans/46",
             "fix(email): keep UTF-8 and the MAC-01 path\n\nThe runner tries to resume first."]
    for message in tickets + hedges + legit:
        fx.commit(message)
    w.expect("ticket ids and hedging are advisory; version, plan and build numbers pass",
             ["base", "message-advisories"], 0,
             [(A, "commit-ticket-id", "commit:" + m.split("\n")[0]) for m in tickets] +
             [(A, "commit-hedging", "commit:" + m.split("\n")[0]) for m in hedges])

    # 23. Exceptions match rule, path and exact line, all three.
    fx.start("excepted-scope", "bundle-module")
    fx.edit("Sources/ContinuumRevivedCore/Lookup.swift", "let url = ",
            'let other = Bundle.module.url(forResource: "y", withExtension: nil)\nlet url = ')
    fx.write("Sources/ContinuumRevivedCore/Lookup2.swift",
             'import Foundation\nlet url = Bundle.module.url(forResource: "x", withExtension: nil)\n')
    manifest = json.loads(fx.read(MANIFEST))
    manifest["exceptions"] = [{"rule": "bundle-module", "path": "Sources/ContinuumRevivedCore/Lookup.swift",
                               "match": 'let url = Bundle.module.url(forResource: "x", withExtension: nil)',
                               "reason": "runs only from the build directory", "owner": "core"},
                              {"rule": "choice-menu", "path": "Sources/ContinuumRevivedCore/Lookup.swift",
                               "match": 'let other = Bundle.module.url(forResource: "y", withExtension: nil)',
                               "reason": "a different rule never excuses this line", "owner": "core"}]
    fx.write(MANIFEST, json.dumps(manifest, indent=2) + "\n")
    fx.commit("chore(core): except one reviewed resource lookup")
    w.expect("an exception covers only its rule, path and line", ["base", "excepted-scope"], 1, [U,
        (X, "bundle-module", "Sources/ContinuumRevivedCore/Lookup.swift"),
        (F, "bundle-module", "Sources/ContinuumRevivedCore/Lookup.swift"),
        (F, "bundle-module", "Sources/ContinuumRevivedCore/Lookup2.swift")])

    # 24. Could-not-run is exit 2 with one line, never a finding.
    def one_line_error(text):
        def check(report):
            error = report.get("error") or ""
            if "\n" in error or "Traceback" in error or text not in error:
                return "expected a one-line error saying %r, got %r" % (text, error)
        return check
    for name, path, text, says in (
            ("bad-senders", "docs/internals/notification-senders.json", "{not json\n", "notification-senders.json is not valid JSON"),
            ("bad-manifest-json", MANIFEST, "{not json\n", "check-coverage-manifest.json is not valid JSON"),
            ("bad-manifest-shape", MANIFEST, json.dumps(dict(BASE_MANIFEST, checks=[
                dict(BASE_MANIFEST["checks"][0], invocation=["a", "list"])])) + "\n", "invocation must be a non-empty string"),
            ("bad-mapped-count", MANIFEST, json.dumps(dict(BASE_MANIFEST, mappedLegs=99)) + "\n", "mappedLegs says 99")):
        fx.start(name)
        fx.write(path, text)
        fx.commit("chore(gate): break %s" % name)
        w.expect("%s exits 2 with a one-line reason" % name, ["base", name], 2, [], one_line_error(says))
    fx.git("checkout", "-q", "--orphan", "unrelated")
    fx.commit("chore(gate): start an unrelated history")
    w.expect("ranges with no shared history exit 2", ["base", "unrelated"], 2, [], one_line_error("share no history"))
    w.expect("one revision instead of two exits 2", ["base"], 2, [], one_line_error("expected two revisions"))
    garbled = fx.root / ".git" / "garbled-manifest.json"  # removed with the fixture, never committed
    garbled.write_bytes(b"\xff\xfe\x00 not text")
    w.expect("an unexpected internal error still exits 2 with one line", ["base", "clean", "--manifest", str(garbled)], 2,
             [], one_line_error("internal error"))

    # 18. Revisions: unknown and ambiguous are script errors; so is a missing manifest.
    w.expect("unknown revision exits 2", ["base", "no-such-branch"], 2)
    fx.git("tag", "dup", "clean")
    fx.git("branch", "dup", "subjects")
    w.expect("ambiguous revision exits 2", ["base", "dup"], 2)
    fx.start("no-manifest")
    fx.git("rm", "-q", MANIFEST)
    fx.commit("chore(gate): remove the manifest")
    w.expect("missing manifest at head exits 2 (fail closed)", ["base", "no-manifest"], 2, [],
             lambda r: None if "is missing" in r.get("error", "") else "error was %r" % r.get("error"))
    w.expect("empty range is clean", ["base", "base"], 0, [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepass", default=str(ROOT / "scripts/gate-prepass.py"))
    parser.add_argument("--keep", action="store_true", help="keep the fixture repository")
    args = parser.parse_args()
    prepass = Path(args.prepass)
    work = tempfile.mkdtemp(prefix="gate-prepass-fixture-", dir="/tmp")
    try:
        fx = Fixture(work)
        build_base(fx)
        w = Witness(prepass, fx)
        cases(w)
        # The real manifest at this checkout's HEAD must be valid and current.
        proc = subprocess.run([sys.executable, str(prepass), "--check-manifest", "HEAD", "--repo", str(ROOT)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if proc.returncode == 0:
            w.passed += 1
            print("ok    real manifest at HEAD is valid and current  (%s)" % proc.stdout.strip().splitlines()[-1])
        else:
            w.failed.append("real manifest")
            print("FAIL  real manifest at HEAD\n    %s" % proc.stdout.strip())
    except Failure as error:
        print("FAIL  fixture setup: %s" % error)
        return 1
    finally:
        if args.keep:
            print("fixture kept at %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)
    print("gate pre-pass witness: %d passed, %d failed" % (w.passed, len(w.failed)))
    return 1 if w.failed else 0


if __name__ == "__main__":
    sys.exit(main())
