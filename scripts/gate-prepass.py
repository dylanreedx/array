#!/usr/bin/env python3
"""Gate pre-pass: what a script can catch in a merged range, before review.

    python3 scripts/gate-prepass.py BASE HEAD [--repo DIR] [--json]
    python3 scripts/gate-prepass.py --check-manifest [REV] [--repo DIR]

Reads only Git objects (never the working tree), so any range can be checked
without a checkout. Only what the range ADDS is judged: added lines, new paths,
new commits. Existing debt never turns an unrelated change red.

Exit status (each is witnessed by scripts/check-gate-prepass.py):
  0  no hard findings (advisories and info may be present)
  1  at least one hard finding
  2  the pre-pass could not run: bad or ambiguous revision, invalid manifest,
     git failure. Callers must fail closed on 2, not treat it as clean.

Hard rules:
  commit-subject           `type(area): description`, under 72 characters
  commit-attribution       Co-Authored-By or an AI-attribution line
  unregistered-check-flag  a newly dispatched `--*-check` flag that no matrix
                           leg runs and no bundle-harness self-check list holds
  bundle-module            `Bundle.module` added outside a checks target
  manifest-stale           a coverage-manifest entry this range made stale
Advisory rules:
  uncertain-check-flag     a flag the narrow parser cannot classify
  choice-menu              NSMenu / NSPopUpButton added (reviewer classifies)
  notification-map         a sender added or touched without a map change
  dated-path               a new path component that contains a date
  commit-subject           an area-less subject (allowed for repo-wide changes)

Registration never proves execution, and listing a check never proves it ran.
"""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

MATRIX = "scripts/run-matrix.sh"
# Harness script -> the bash array whose entries it runs as self-checks. Only
# that array counts; other mentions in the harness (comparisons, comments,
# messages) do not. Owner decision: a flag in one of these arrays is registered.
BUNDLE_HARNESSES = {"scripts/check-app-bundle.sh": "self_checks"}
MANIFEST = "scripts/check-coverage-manifest.json"
NOTIFY_DOC = "docs/internals/notification-paths.md"
NOTIFY_SENDERS = "docs/internals/notification-senders.json"
CODE_PREFIXES = ("Sources/", "iOS/", "scripts/", "Packaging/", "Tools/", "Package.swift")

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "style", "chore",
         "build", "ci", "revert")
SUBJECT_LIMIT = 72  # the whole subject must be UNDER this many characters
SUBJECT_RE = re.compile(r"^(?P<type>[A-Za-z]+)(?:\((?P<area>[^)]*)\))?(?P<bang>!)?: (?P<desc>\S.*)$")
AREA_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ATTRIBUTION_RES = [
    re.compile(r"^co-authored-by\s*:", re.I),
    re.compile(r"noreply@(?:anthropic|openai)\.com", re.I),
    re.compile(r"^(?:\W+\s*)?generated\s+(?:with|by)\b.*\b(?:claude|codex|chatgpt|gpt|copilot|openai|anthropic|gemini|ai)\b", re.I),
    re.compile(r"^[a-z]+(?:-[a-z]+)*-by\s*:.*\b(?:claude|codex|chatgpt|copilot|openai|anthropic|gemini)\b", re.I),
]

FLAG = r"(--[a-z0-9][a-z0-9-]*-check)"
DISPATCH_RES = [
    re.compile(r'CommandLine\.arguments\.contains\(\s*"' + FLAG + r'"\s*\)'),
    re.compile(r'CommandLine\.arguments\.firstIndex\(\s*of:\s*"' + FLAG + r'"\s*\)'),
    re.compile(r'^\s*\(\s*"' + FLAG + r'"\s*,'),  # a (flag, runner) dispatch-table row
    re.compile(r'\bcase\s+"' + FLAG + r'"'),
]
UNCERTAIN_RES = [
    re.compile(r'\b(?:let|var)\s+\w+\s*(?::\s*String\s*)?=\s*"' + FLAG + r'"'),
    re.compile(r'(?<!CommandLine\.arguments)\.contains\(\s*"' + FLAG + r'"\s*\)'),
]
MATRIX_LEG_RE = re.compile(
    r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:run|run_leg|run_app_check|run_ios_build)\s+(?P<args>.*)$")
MATRIX_ASSIGN_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*=" + FLAG)
SHELL_FLAG_RE = re.compile(FLAG + r"\b")
BUNDLE_MODULE_RE = re.compile(r"\bBundle\s*\.\s*module\b")
CHOICE_MENU_RE = re.compile(r"\b(NSMenu|NSPopUpButton)\b")
DATE_RES = [
    re.compile(r"(?<!\d)(?:19|20)\d\d-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?!\d)"),
    re.compile(r"(?<!\d)(?:19|20)\d\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)"),
]


class PrepassError(Exception):
    pass


# ---------------------------------------------------------------- git access
class Repo:
    def __init__(self, path, manifest_path=None):
        self.manifest_override = Path(manifest_path).read_text() if manifest_path else None
        self.path = path
        self._blobs = {}

    def run(self, *args, ok=(0,)):
        proc = subprocess.run(["git", "-C", self.path, "-c", "core.quotePath=false", *args],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode not in ok:
            raise PrepassError("git %s failed: %s" % (" ".join(args[:3]), proc.stderr.decode(errors="replace").strip()))
        return proc

    def text(self, *args, ok=(0,)):
        return self.run(*args, ok=ok).stdout.decode("utf-8", errors="replace")

    def resolve(self, rev):
        if not rev or rev.startswith("-"):
            raise PrepassError("invalid revision %r" % rev)
        proc = subprocess.run(["git", "-C", self.path, "rev-parse", "--verify", rev + "^{commit}"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        err = proc.stderr.decode(errors="replace")
        if "ambiguous" in err:
            raise PrepassError("ambiguous revision %r: %s" % (rev, err.strip()))
        if proc.returncode != 0:
            raise PrepassError("unknown revision %r" % rev)
        return proc.stdout.decode().strip()

    def show(self, rev, path):
        """File content at rev, or None when absent."""
        if path == MANIFEST and self.manifest_override is not None:
            return self.manifest_override
        key = (rev, path)
        if key not in self._blobs:
            proc = self.run("cat-file", "blob", "%s:%s" % (rev, path), ok=(0, 128))
            self._blobs[key] = proc.stdout.decode("utf-8", errors="replace") if proc.returncode == 0 else None
        return self._blobs[key]

    def files(self, rev):
        return self.text("ls-tree", "-r", "--name-only", "-z", rev).split("\0")[:-1]


# ------------------------------------------------------------ swift scanning
_CODE_EVENT = re.compile(r'//|/\*|(#*)("""|")')
_BLOCK_EVENT = re.compile(r"/\*|\*/")


def _blank(text):
    return re.sub(r"[^\n]", " ", text)


def strip_swift(source):
    """Return (no_comments, no_comments_or_strings), line-aligned with source.

    A narrow scanner: line and nested block comments, plain/multi-line/raw
    strings. String interpolation is treated as string text (a known gap)."""
    keep, code = [], []
    i, n = 0, len(source)
    while i < n:
        m = _CODE_EVENT.search(source, i)
        if not m:
            keep.append(source[i:]); code.append(source[i:]); break
        keep.append(source[i:m.start()]); code.append(source[i:m.start()])
        tok = m.group(0)
        if tok == "//":
            end = source.find("\n", m.end())
            end = n if end < 0 else end
            keep.append(_blank(source[m.start():end])); code.append(_blank(source[m.start():end]))
            i = end
        elif tok == "/*":
            depth, j = 1, m.end()
            while depth and j < n:
                b = _BLOCK_EVENT.search(source, j)
                if not b:
                    j = n; break
                depth += 1 if b.group(0) == "/*" else -1
                j = b.end()
            keep.append(_blank(source[m.start():j])); code.append(_blank(source[m.start():j]))
            i = j
        else:
            hashes, quote = m.group(1), m.group(2)
            close = quote + hashes
            j = m.end()
            while j < n:
                if not hashes and source[j] == "\\":
                    j += 2; continue
                if source.startswith(close, j):
                    j += len(close); break
                if quote == '"' and source[j] == "\n":
                    break  # unterminated single-line string: stop at the line end
                j += 1
            literal = source[m.start():j]
            keep.append(literal)
            code.append(m.group(0) + _blank(literal[len(m.group(0)):]))
            i = j
    return "".join(keep).split("\n"), "".join(code).split("\n")


# ------------------------------------------------------------- shell parsing
def _shell_lines(text):
    for raw in (text or "").splitlines():
        if raw.lstrip().startswith("#"):
            continue
        yield re.sub(r"\s#.*", "", raw)


def matrix_legs(text):
    """Every literal leg invocation in run-matrix.sh: args after the runner."""
    legs = []
    for line in _shell_lines(text):
        m = MATRIX_LEG_RE.match(line)
        if m:
            legs.append(m.group("args").strip())
    return legs


def matrix_assign_flags(text):
    flags = set()
    for line in _shell_lines(text):
        if not MATRIX_LEG_RE.match(line):
            flags.update(MATRIX_ASSIGN_RE.findall(line))
    return flags


def harness_flags(text, array):
    lines = list(_shell_lines(text))
    body = "\n".join(lines)
    flags = set()
    for m in re.finditer(r"(?:^|\s)" + re.escape(array) + r"\+?=\((.*?)\)", body, re.S):
        flags.update(SHELL_FLAG_RE.findall(m.group(1)))
    return flags


def registration(repo, rev):
    matrix = repo.show(rev, MATRIX)
    legs = matrix_legs(matrix)
    flags = set()
    for leg in legs:
        flags.update(SHELL_FLAG_RE.findall(leg))
    bundle = {}
    for path, array in BUNDLE_HARNESSES.items():
        if not any(leg.split()[0] == path for leg in legs):
            continue
        for flag in harness_flags(repo.show(rev, path), array):
            bundle[flag] = path
    return {"legs": legs, "matrix": flags, "bundle": bundle, "assigned": matrix_assign_flags(matrix)}


# ------------------------------------------------------------------ manifest
def glob_re(glob):
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif glob.startswith("**", i):
            out += ".*"; i += 2
        elif glob[i] == "*":
            out += "[^/]*"; i += 1
        elif glob[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(glob[i]); i += 1
    return re.compile(out + r"\Z")


def load_manifest(repo, rev, required):
    text = repo.show(rev, MANIFEST)
    if text is None:
        if required:
            raise PrepassError("%s is missing at %s" % (MANIFEST, rev[:12]))
        return None
    try:
        data = json.loads(text)
    except ValueError as error:
        raise PrepassError("%s is not valid JSON at %s: %s" % (MANIFEST, rev[:12], error))
    if not isinstance(data, dict):
        raise PrepassError("manifest must be an object")
    problems = []
    if data.get("version") != 1:
        problems.append("version must be 1")
    checks = data.get("checks")
    if not isinstance(checks, list):
        problems.append("checks must be a list")
        checks = []
    seen = set()
    for index, entry in enumerate(checks):
        where = "checks[%d]" % index
        if not isinstance(entry, dict):
            problems.append(where + " must be an object"); continue
        for key in ("invocation", "owner", "reason"):
            if not isinstance(entry.get(key), str) or not entry.get(key).strip():
                problems.append("%s.%s must be a non-empty string" % (where, key))
        if entry.get("invocation") in seen:
            problems.append("%s duplicates invocation %r" % (where, entry.get("invocation")))
        seen.add(entry.get("invocation"))
        for key in ("covers", "checkFiles"):
            value = entry.get(key, [] if key == "checkFiles" else None)
            if not isinstance(value, list) or not all(isinstance(g, str) and g for g in value) \
                    or (key == "covers" and not value):
                problems.append("%s.%s must be a %slist of globs" % (where, key, "non-empty " if key == "covers" else ""))
    exceptions = data.get("exceptions", [])
    if not isinstance(exceptions, list):
        problems.append("exceptions must be a list")
        exceptions = []
    for index, entry in enumerate(exceptions):
        where = "exceptions[%d]" % index
        if not isinstance(entry, dict):
            problems.append(where + " must be an object"); continue
        for key in ("rule", "path", "match", "reason", "owner"):
            if not isinstance(entry.get(key), str) or not entry.get(key).strip():
                problems.append("%s.%s must be a non-empty string (no silent suppressions)" % (where, key))
    if problems:
        raise PrepassError("%s is invalid at %s: %s" % (MANIFEST, rev[:12], "; ".join(problems)))
    return data


def manifest_staleness(repo, rev, manifest, reg=None):
    """Stale keys: an invocation no matrix leg runs, a glob matching no file."""
    if manifest is None:
        return set()
    reg = reg or registration(repo, rev)
    files = repo.files(rev)
    legs = set(reg["legs"])
    stale = set()
    for entry in manifest["checks"]:
        if entry["invocation"] not in legs:
            stale.add(("invocation", entry["invocation"], ""))
        for key in ("covers", "checkFiles"):
            for glob in entry.get(key, []):
                rx = glob_re(glob)
                if not any(rx.match(f) for f in files):
                    stale.add((key, entry["invocation"], glob))
    return stale


# ---------------------------------------------------------------- diff model
def changed_paths(repo, base, head):
    out = repo.run("diff", "--name-status", "-M", "-z", "--no-ext-diff", base, head).stdout.decode("utf-8", errors="replace")
    parts = out.split("\0")[:-1]
    changes, i = [], 0
    while i < len(parts):
        status = parts[i]
        if status[:1] in ("R", "C"):
            changes.append({"status": status[0], "old": parts[i + 1], "path": parts[i + 2]}); i += 3
        else:
            changes.append({"status": status[0], "old": parts[i + 1] if status[0] == "D" else None,
                            "path": parts[i + 1]}); i += 2
    return changes


def line_diff(repo, base, head, renames):
    """{path: {"added": {lineno: text}, "removed": [text]}} for the new side."""
    args = ["diff", "--unified=0", "--no-color", "--no-ext-diff", "-M" if renames else "--no-renames", base, head]
    text = repo.run(*args).stdout.decode("utf-8", errors="replace")
    result, current, new_line = {}, None, 0
    old_path = None
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            current, old_path = None, None
        elif line.startswith("--- "):
            old_path = line[6:] if line.startswith("--- a/") else None
        elif line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else old_path
            current = result.setdefault(path, {"added": {}, "removed": []}) if path else None
        elif line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            new_line = int(m.group(1)) if m else 0
        elif current is not None and line.startswith("+"):
            current["added"][new_line] = line[1:]; new_line += 1
        elif current is not None and line.startswith("-"):
            current["removed"].append(line[1:])
    return result


# ------------------------------------------------------------------- rules
def finding(rule, severity, message, **where):
    item = {"rule": rule, "severity": severity, "message": message}
    item.update({k: v for k, v in where.items() if v is not None})
    return item


def check_commits(repo, base, head):
    out = repo.text("log", "--reverse", "--format=%H%x00%P%x00%B%x1e", "%s..%s" % (base, head))
    found = []
    commits = 0
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        commits += 1
        sha, parents, body = record.split("\0", 2)
        short = sha[:9]
        merge = len(parents.split()) > 1
        lines = body.split("\n")
        subject = lines[0].strip() if lines else ""
        problems = subject_problems(subject)
        if problems:
            severity = "fail"
            note = ""
            found.append(finding("commit-subject", severity, "; ".join(problems) + note, commit=short, subject=subject))
        elif SUBJECT_RE.match(subject).group("area") is None:
            found.append(finding("commit-subject", "advisory",
                                 "no (area): allowed only for a repo-wide change", commit=short, subject=subject))
        for number, line in enumerate(lines[1:], start=2):
            stripped = line.strip()
            if any(rx.search(stripped) for rx in ATTRIBUTION_RES):
                found.append(finding("commit-attribution", "fail",
                                     "attribution line is not allowed: %s" % stripped, commit=short, line=number))
    return commits, found


def subject_problems(subject):
    if not subject:
        return ["empty subject"]
    problems = []
    if len(subject) >= SUBJECT_LIMIT:
        problems.append("subject is %d characters; it must be under %d" % (len(subject), SUBJECT_LIMIT))
    m = SUBJECT_RE.match(subject)
    if not m:
        problems.append("subject is not `type(area): description`")
        return problems
    if m.group("type") not in TYPES:
        problems.append("type %r is not one of %s" % (m.group("type"), " ".join(TYPES)))
    area = m.group("area")
    if area is not None and not AREA_RE.match(area):
        problems.append("area %r is not lowercase kebab-case" % area)
    desc = m.group("desc")
    first = desc.split()[0]
    if first != first.lower():
        problems.append("description must start with a lowercase word, not %r" % first)
    if desc.endswith("."):
        problems.append("description ends with a period")
    return problems


def is_checks_path(path):
    parts = path.split("/")
    return (len(parts) > 1 and parts[0] in ("Sources", "Tests") and
            (parts[0] == "Tests" or parts[1].endswith(("Checks", "Tests"))))


def excepted(manifest, rule, path, text):
    for entry in (manifest or {}).get("exceptions", []):
        if entry["rule"] == rule and entry["path"] == path and entry["match"].strip() == text.strip():
            return entry
    return None


def add_line_finding(found, manifest, rule, severity, message, path, line, text, **extra):
    entry = excepted(manifest, rule, path, text)
    if entry:
        found.append(finding(rule, "excepted", "%s [excepted: %s; owner %s]" % (message, entry["reason"], entry["owner"]),
                             path=path, line=line, **extra))
    else:
        found.append(finding(rule, severity, message, path=path, line=line, **extra))


def swift_views(repo, head, path, cache):
    if path not in cache:
        source = repo.show(head, path) or ""
        cache[path] = strip_swift(source)
    return cache[path]


def check_swift(repo, head, renamed_diff, unrenamed_diff, reg, manifest, notify_patterns, sender_paths):
    found, notify_hits, cache = [], [], {}
    removed_flags = set()
    for change in renamed_diff.values():
        for text in change["removed"]:
            removed_flags.update(m for rx in DISPATCH_RES for m in rx.findall(text))
    for path, change in sorted(renamed_diff.items()):
        if not path.endswith(".swift") or not change["added"]:
            continue
        keep, code = swift_views(repo, head, path, cache)
        for number in sorted(change["added"]):
            if number - 1 >= len(keep):
                continue
            kept, bare, raw = keep[number - 1], code[number - 1], change["added"][number]
            flags = [] if is_checks_path(path) else [m for rx in DISPATCH_RES for m in rx.findall(kept)]
            for flag in sorted(set(flags)):
                if flag in removed_flags or flag in reg["matrix"]:
                    continue
                if flag in reg["bundle"]:
                    continue
                if flag in reg["assigned"]:
                    add_line_finding(found, manifest, "uncertain-check-flag", "advisory",
                                     "%s appears in run-matrix.sh only as an assignment; confirm a harness runs it" % flag,
                                     path, number, raw, flag=flag)
                    continue
                add_line_finding(found, manifest, "unregistered-check-flag", "fail",
                                 "%s is dispatched but no matrix leg or bundle-harness self-check list runs it" % flag,
                                 path, number, raw, flag=flag)
            if not flags and not is_checks_path(path):
                for rx in UNCERTAIN_RES:
                    for flag in rx.findall(kept):
                        if flag in reg["matrix"] or flag in reg["bundle"] or flag in removed_flags:
                            continue
                        add_line_finding(found, manifest, "uncertain-check-flag", "advisory",
                                         "%s is held in a form the pre-pass cannot classify; confirm it is dispatched and registered" % flag,
                                         path, number, raw, flag=flag)
            menus = sorted(set(CHOICE_MENU_RE.findall(bare)))
            if menus and not is_checks_path(path):
                add_line_finding(found, manifest, "choice-menu", "advisory",
                                 "%s added: a choice menu must use ChoiceButton / ChoicePopoverController; context and app menus are fine" % "/".join(menus),
                                 path, number, raw)
            if not is_checks_path(path) and any(re.search(p, kept) for p in notify_patterns):
                notify_hits.append((path, number, raw))
    # Bundle.module: judged on the rename-blind diff, so moved code counts.
    for path, change in sorted(unrenamed_diff.items()):
        if not path.endswith(".swift") or is_checks_path(path) or path.endswith("Checks.swift"):
            continue
        _, code = swift_views(repo, head, path, cache)
        for number in sorted(change["added"]):
            if number - 1 < len(code) and BUNDLE_MODULE_RE.search(code[number - 1]):
                add_line_finding(found, manifest, "bundle-module", "fail",
                                 "Bundle.module traps in a packaged app; resolve the resource the packaged way",
                                 path, number, change["added"][number])
    return found, notify_hits


def check_notifications(changes, notify_hits, sender_paths):
    touched = {c["path"] for c in changes} | {c["old"] for c in changes if c["old"]}
    if NOTIFY_DOC in touched:
        return []
    found = []
    for path, number, _ in notify_hits:
        found.append(finding("notification-map", "advisory",
                             "notification sender added without a %s change" % NOTIFY_DOC, path=path, line=number))
    for path in sorted(touched & sender_paths):
        found.append(finding("notification-map", "advisory",
                             "known sender file changed without a %s change; confirm no path edge moved" % NOTIFY_DOC,
                             path=path))
    return found


def check_dated_paths(repo, base, changes):
    new = [c["path"] for c in changes if c["status"] in ("A", "R", "C")]
    if not new:
        return []
    existing = set()
    for f in repo.files(base):
        parts = f.split("/")
        existing.update("/".join(parts[:i + 1]) for i in range(len(parts)))
    found = []
    for path in sorted(new):
        parts = path.split("/")
        for i, part in enumerate(parts):
            prefix = "/".join(parts[:i + 1])
            if prefix in existing:
                continue
            if any(rx.search(part) for rx in DATE_RES):
                found.append(finding("dated-path", "advisory",
                                     "new name %r carries a date; name it for what it is" % part, path=path))
                break
    return found


def coverage(manifest, changes):
    checks, covered = {}, set()
    for change in changes:
        for path, role in ((change["path"], change["status"]), (change["old"] if change["old"] != change["path"] else None, "old path of " + change["status"])):
            if not path:
                continue
            for entry in (manifest or {}).get("checks", []):
                hit = [g for g in entry["covers"] if glob_re(g).match(path)]
                check_hit = [g for g in entry.get("checkFiles", []) if glob_re(g).match(path)]
                if hit or check_hit:
                    covered.add(path)
                    item = checks.setdefault(entry["invocation"], {"invocation": entry["invocation"], "owner": entry["owner"],
                                                                   "reason": entry["reason"], "paths": [], "checkFilesChanged": []})
                    if hit:
                        item["paths"].append({"path": path, "status": role, "globs": hit})
                    if check_hit:
                        item["checkFilesChanged"].append(path)
    paths = {c["path"] for c in changes} | {c["old"] for c in changes if c["old"]}
    unmapped = sorted(p for p in paths - covered if p.startswith(CODE_PREFIXES))
    ordered = []
    for key in sorted(checks):
        item = checks[key]
        item["paths"].sort(key=lambda p: (p["path"], p["status"]))
        item["checkFilesChanged"] = sorted(set(item["checkFilesChanged"]))
        ordered.append(item)
    return ordered, unmapped


def notification_patterns():
    path = Path(__file__).resolve().with_name("check-notification-map.py")
    spec = importlib.util.spec_from_file_location("check_notification_map", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(module.PATTERNS.values())


# --------------------------------------------------------------------- main
SEVERITY_ORDER = {"fail": 0, "advisory": 1, "excepted": 2, "info": 3}


def run_prepass(repo, base_rev, head_rev):
    base, head = repo.resolve(base_rev), repo.resolve(head_rev)
    merge_base = repo.text("merge-base", base, head, ok=(0, 1)).strip()
    if not merge_base:
        raise PrepassError("%s and %s share no history" % (base_rev, head_rev))
    manifest = load_manifest(repo, head, required=True)
    base_manifest = load_manifest(repo, merge_base, required=False)
    reg = registration(repo, head)
    commits, found = check_commits(repo, base, head)
    changes = changed_paths(repo, merge_base, head)
    renamed = line_diff(repo, merge_base, head, renames=True)
    unrenamed = line_diff(repo, merge_base, head, renames=False)
    senders_text = repo.show(head, NOTIFY_SENDERS)
    sender_paths = set(json.loads(senders_text)) if senders_text else set()
    swift_found, notify_hits = check_swift(repo, head, renamed, unrenamed, reg, manifest,
                                           notification_patterns(), sender_paths)
    found += swift_found
    found += check_notifications(changes, notify_hits, sender_paths)
    found += check_dated_paths(repo, merge_base, changes)
    was_stale = manifest_staleness(repo, merge_base, base_manifest)
    for kind, invocation, glob in sorted(manifest_staleness(repo, head, manifest, reg) - was_stale):
        if kind == "invocation":
            message = "manifest names %r, which no run-matrix.sh leg runs" % invocation
        else:
            message = "manifest %s glob %r for %r matches no file" % (kind, glob, invocation)
        found.append(finding("manifest-stale", "fail", message, path=MANIFEST))
    checks, unmapped = coverage(manifest, changes)
    found.sort(key=lambda f: (SEVERITY_ORDER[f["severity"]], f["rule"], f.get("commit", ""), f.get("path", ""),
                              f.get("line", 0), f["message"]))
    hard = sum(1 for f in found if f["severity"] == "fail")
    return {
        "base": base, "head": head, "mergeBase": merge_base, "commits": commits,
        "changedPaths": len(changes), "manifestVersion": manifest["version"],
        "findings": found, "checks": checks, "unmapped": unmapped,
        "exit": 1 if hard else 0,
    }


def render(report):
    out = ["gate pre-pass  base %s  head %s  commits %d  paths %d  manifest v%d" % (
        report["base"][:9], report["head"][:9], report["commits"], report["changedPaths"], report["manifestVersion"])]
    for f in report["findings"]:
        where = f.get("commit") or f.get("path", "")
        if f.get("line") and f.get("path"):
            where += ":%d" % f["line"]
        elif f.get("line"):
            where += " line %d" % f["line"]
        text = "%-9s %-24s %s  %s" % (f["severity"].upper(), f["rule"], where, f["message"])
        if f.get("subject") is not None:
            text += "  [%s]" % f["subject"]
        out.append(text)
    out.append("checks covering this change (listing is not running):" if report["checks"] else "checks covering this change: none mapped")
    for item in report["checks"]:
        out.append("  %s   (%s)" % (item["invocation"], item["reason"]))
        for p in item["paths"]:
            out.append("      %s  [%s]" % (p["path"], p["status"]))
        for p in item["checkFilesChanged"]:
            out.append("      check file changed: %s" % p)
    if report["unmapped"]:
        out.append("unmapped code paths (%d): no manifest entry names a check for these" % len(report["unmapped"]))
        out.extend("  " + p for p in report["unmapped"])
    counts = {}
    for f in report["findings"]:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    out.append("result: %d fail, %d advisory, %d excepted -> exit %d" % (
        counts.get("fail", 0), counts.get("advisory", 0), counts.get("excepted", 0), report["exit"]))
    return "\n".join(out)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("revs", nargs="*")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--manifest", help="explicit manifest file for historical replay; overrides Git manifest at both revisions")
    parser.add_argument("--json", action="store_true", help="print the machine-readable report")
    parser.add_argument("--check-manifest", action="store_true",
                        help="validate the manifest at REV (default HEAD): schema, invocations, globs")
    args = parser.parse_args(argv)
    try:
        repo = Repo(args.repo, args.manifest)
        if args.check_manifest:
            if len(args.revs) > 1:
                raise PrepassError("--check-manifest takes at most one revision")
            rev = repo.resolve(args.revs[0] if args.revs else "HEAD")
            manifest = load_manifest(repo, rev, required=True)
            stale = sorted(manifest_staleness(repo, rev, manifest))
            for kind, invocation, glob in stale:
                print("STALE %s %s %s" % (kind, invocation, glob))
            print("manifest %s: %d checks, %d stale" % ("ok" if not stale else "STALE", len(manifest["checks"]), len(stale)))
            return 1 if stale else 0
        if len(args.revs) != 2:
            raise PrepassError("usage: gate-prepass.py BASE HEAD")
        report = run_prepass(repo, args.revs[0], args.revs[1])
    except (PrepassError, OSError) as error:
        if args.json:
            print(json.dumps({"error": str(error), "exit": 2}, indent=2, sort_keys=True))
        print("gate pre-pass ERROR: %s" % error, file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True) if args.json else render(report))
    return report["exit"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
