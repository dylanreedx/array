#!/usr/bin/env python3
"""Which matrix legs does a change reach? Affected-legs selection for a feature gate.

    python3 scripts/leg-coverage.py select BASE HEAD [--repo DIR] [--json]
    python3 scripts/leg-coverage.py select --paths P [P ...] [--rev REV] [--repo DIR] [--json]
    python3 scripts/leg-coverage.py stats [--rev REV] [--repo DIR]

The map is derived from the source at the revision, every time, so it cannot go
stale. It reads only Git objects. For each leg run-matrix.sh runs:

  - an app or checks-executable leg (`<binary> --x-check`): the files of the
    types its dispatch block names (the check implementation), then the files of
    every type those files name, one more level (the code the check drives);
  - a flagless checks executable (`ContinuumRevivedFileTreeChecks`): its target's
    files, then the files of every type they name;
  - a script leg (`python3 scripts/check-x.py`, `scripts/check-x.sh`): the script
    and every repo path it mentions (scripts, docs, Sources files or directories);
  - every entry of scripts/check-coverage-manifest.json, as written by hand.

A resource file in Sources/ (a bundled .ts, .json, .md) belongs to the Swift files
that name it in a string, and reaches their legs.

Selection fails safe. A changed path no leg covers, run-matrix.sh itself,
Package.swift, Package.resolved and ThirdParty/ select the FULL matrix, with the
reason. Only nightly-gate.sh's release paths (.plans/, website/,
docs/VERSIONING.md) select nothing.

A mapped Sources/ file also selects the flags whose rare words its path shares
(seam names: ComposerTextView.swift selects --composer-key-routing-check).

Known limits, said rather than hidden: a type is followed one level past the
check, not transitively, so a change reached only through a longer call chain
can be missed; dynamic dispatch through a protocol finds the protocol's files,
not every conformer's; a leg whose flag is built at run time maps to nothing.
The selection is the floor of what a tier 2 or 3 gate runs, never the ceiling:
the author adds the legs of the seam they know they touched.

Exit status: 0 selected (legs or FULL); 2 could not run.
"""
import argparse
import bisect
import importlib.util
import subprocess
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("gate_prepass", HERE / "gate-prepass.py")
prepass = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(prepass)

MATRIX = "scripts/run-matrix.sh"
INERT = (".plans/", "website/", "docs/VERSIONING.md")
FULL_PATHS = (MATRIX, "Package.swift", "Package.resolved", "ThirdParty/")
FLAG_RE = re.compile(r"--[a-z0-9][a-z0-9-]*-check\b")
TYPE_DECL_RE = re.compile(r"\b(?:class|struct|enum|actor|protocol|extension|typealias)\s+([A-Z][A-Za-z0-9_]*)")
TYPE_USE_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]+)\b")
FUNC_DECL_RE = re.compile(r"\bfunc\s+([a-z_][A-Za-z0-9_]*)")
FUNC_USE_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*\(")
# A function name declared in more files than this (run, check, makeView) is
# ambiguous by name alone and is not followed.
AMBIGUOUS_FUNC_FILES = 3
DISPATCH_RE = re.compile(r'"(--[a-z0-9-]+-check)"')
STRING_RE = re.compile(r'"([A-Za-z0-9_.\-]{3,})"')
PATH_MENTION_RE = re.compile(r"(?<![\w./-])((?:Sources|scripts|docs|benchmarks|Packaging|website|film)/[A-Za-z0-9_./+\-]*)")
# Where each binary's flags are dispatched; flagless binaries cover their target.
DISPATCH = {"Array": "Sources/ContinuumRevived/App/ContinuumApp.swift"}
# One level past the check: the code it drives, not everything that code drives.
DEPTH = 1
# A type named by more files than this is a hub (Tile, AgentID, AppDelegate): it
# is followed from nowhere, or every leg would reach every file. A change to a
# hub's own files is therefore usually unmapped, and selects the full matrix.
HUB_FILES = 60
# A leg covering more than this share of Sources/ is a scanner (the pre-pass,
# the inventory, colour hygiene). It runs whenever Sources/ changes, but being
# covered by scanners alone does not make a file mapped.
BROAD_SHARE = 0.25
# Seam names: a flag word of at least SEAM_MIN letters that appears in at most
# SEAM_RARE flags (composer, jelly, dictation; not agent, tile, view) and in the
# changed file's path selects that flag too. It reaches checks the bounded walk
# misses (a check driving the composer view that hosts the changed text view),
# but it only adds legs: it never makes an unmapped file mapped.
SEAM_RARE = 12
SEAM_MIN = 4
# Builds run in every selection anyway; they are not coverage.
ALWAYS = ("swift build", "swift run", "git diff --check", "npm ci ")


def leg_name(args):
    """run-matrix.sh's matrix_leg_name: the first --*-check word, else the command."""
    words = args.split()
    for word in words:
        if FLAG_RE.fullmatch(word):
            return word
    return args


class Index:
    def __init__(self, repo, rev):
        self.repo, self.rev = repo, rev
        self.files = repo.files(rev)
        self.file_set, self.sorted_files = set(self.files), sorted(self.files)
        self.swift = [f for f in self.files if f.startswith("Sources/") and f.endswith(".swift")]
        self.code, self.raw, self.strings = {}, read_blobs(repo, rev, self.swift), {}
        self.declares = {}  # type name -> files declaring or extending it
        for path in self.swift:
            raw = self.raw[path]
            self.strings[path] = set(STRING_RE.findall(raw))
            code = "\n".join(prepass.strip_swift(raw)[1])
            self.raw[path], self.code[path] = raw, code
            for name in TYPE_DECL_RE.findall(code):
                self.declares.setdefault(name, set()).add(path)
        functions = {}
        for path in self.swift:
            for name in FUNC_DECL_RE.findall(self.code[path]):
                functions.setdefault(name, set()).add(path)
        for name, files in functions.items():
            if len(files) <= AMBIGUOUS_FUNC_FILES:
                self.declares.setdefault(name, set()).update(files)
        self.names = {path: self.named(self.code[path]) for path in self.swift}
        named_by = {}
        for path, names in self.names.items():
            for name in names:
                named_by[name] = named_by.get(name, 0) + 1
        self.hubs = {name for name, count in named_by.items() if count > HUB_FILES}
        self._uses = {}

    def named(self, code):
        """The declared types and functions a piece of code names."""
        return (set(TYPE_USE_RE.findall(code)) | set(FUNC_USE_RE.findall(code))) & set(self.declares)

    def files_of(self, names):
        out = set()
        for name in names:
            if name not in self.hubs:
                out |= self.declares.get(name, set())
        return out

    def under(self, prefix):
        start = bisect.bisect_left(self.sorted_files, prefix)
        out = []
        for f in self.sorted_files[start:]:
            if not f.startswith(prefix):
                break
            out.append(f)
        return out

    def uses(self, path):
        """Files declaring the types a file names (itself excluded)."""
        if path not in self._uses:
            out = self.files_of(self.names.get(path, ()))
            out.discard(path)
            self._uses[path] = out
        return self._uses[path]

    def expand(self, seeds, depth=None):
        depth = DEPTH if depth is None else depth
        covered, frontier = set(seeds), set(seeds)
        for _ in range(depth):
            frontier = set().union(*(self.uses(f) for f in frontier)) - covered if frontier else set()
            covered |= frontier
        return covered

    def dispatch_blocks(self, path):
        """flag -> files of the types its dispatch block names. The dispatcher
        itself is not one: it names every check, and a change to it selects all."""
        raw, code = self.raw.get(path, ""), self.code.get(path, "")
        hits = list(DISPATCH_RE.finditer(raw))
        blocks = {}
        for i, hit in enumerate(hits):
            end = hits[i + 1].start() if i + 1 < len(hits) else len(code)
            files = self.files_of(self.named(code[hit.end():end]))
            files.discard(path)
            blocks.setdefault(hit.group(1), set()).update(files)
        return blocks


def read_blobs(repo, rev, paths):
    """Many files at rev through one `git cat-file --batch`."""
    proc = subprocess.run(["/usr/bin/git", "-C", repo.path, "cat-file", "--batch"],
                          input="".join("%s:%s\n" % (rev, p) for p in paths).encode(), capture_output=True)
    if proc.returncode:
        raise prepass.PrepassError("git cat-file --batch failed: " + proc.stderr.decode(errors="replace").strip())
    out, data, pos = {}, proc.stdout, 0
    for path in paths:
        end = data.index(b"\n", pos)
        header = data[pos:end].split()
        pos = end + 1
        if header[-1] == b"missing":
            out[path] = ""
            continue
        size = int(header[2])
        out[path] = data[pos:pos + size].decode("utf-8", errors="replace")
        pos += size + 1
    return out


def binary_target(binary):
    """A checks executable's target directory, when Sources/<binary>/ exists."""
    return "Sources/%s/" % binary


def build_map(repo, rev):
    index = Index(repo, rev)
    parsed = prepass.parse_shell(repo.show(rev, MATRIX) or "")
    legs = {}
    dispatch_cache, script_cache = {}, {}

    def script_covers(word):
        if word not in script_cache:
            found = {word}
            for mention in PATH_MENTION_RE.findall(repo.show(rev, word) or ""):
                mention = mention.rstrip(".")
                if mention in index.file_set:
                    found.add(mention)
                elif mention.endswith("/"):
                    found.update(index.under(mention))
            script_cache[word] = found
        return script_cache[word]

    def dispatch(binary):
        path = DISPATCH.get(binary) or binary_target(binary) + "main.swift"
        if path not in dispatch_cache:
            dispatch_cache[path] = index.dispatch_blocks(path)
        return dispatch_cache[path]

    for leg in parsed["legs"]:
        args = leg["args"]
        if leg["status"] == "dead" or not args.strip() or args.startswith(ALWAYS):
            continue
        name = leg_name(args)
        words = [w.strip("'\"") for w in args.split()]
        covers = set()
        binary = next((w.rsplit("/", 1)[-1] for w in words if w.startswith(".build/")), None)
        flag = name if FLAG_RE.fullmatch(name) else None
        if binary and flag:
            seeds = dispatch(binary).get(flag)
            if seeds:
                covers = index.expand(seeds)
        elif binary:
            target = [f for f in index.swift if f.startswith(binary_target(binary))]
            covers = index.expand(target)
        for word in words:  # script legs, the paths they mention, a directory argument
            if word in index.file_set:
                covers |= script_covers(word)
            elif not word.startswith((".build/", "-", "$")) and "/" in word:
                covers.update(index.under(word.rstrip("/") + "/"))
        if covers:
            legs.setdefault(name, set()).update(covers)
        else:
            legs.setdefault(name, set())
    # The hand-written manifest adds what it knows.
    manifest = json.loads(repo.show(rev, prepass.MANIFEST) or '{"checks": []}')
    for entry in manifest.get("checks", []):
        name = leg_name(entry["invocation"])
        for glob in entry.get("covers", []) + entry.get("checkFiles", []):
            pattern = prepass.glob_re(glob)
            legs.setdefault(name, set()).update(f for f in index.files if pattern.fullmatch(f))
    # Resources: a Sources/ file that is not Swift reaches the Swift files naming it.
    resources = {}
    for path in index.files:
        if path.startswith("Sources/") and not path.endswith(".swift"):
            stem = path.rsplit("/", 1)[-1]
            keys = {stem, stem.rsplit(".", 1)[0]}
            resources[path] = {f for f in index.swift if keys & index.strings[f]}
    return index, legs, resources


def split_broad(index, legs):
    limit = BROAD_SHARE * len(index.swift)
    broad = {name for name, files in legs.items() if sum(f in index.code for f in files) > limit}
    covering = {}
    for name, files in legs.items():
        if name not in broad:
            for f in files:
                covering.setdefault(f, set()).add(name)
    return broad, covering


HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)


def added_legs(repo, base, rev):
    """When a range only ADDS legs (and comments) to run-matrix.sh, the names of
    those legs; otherwise None, and the change reaches every leg."""
    diff = repo.text("diff", "-U0", "--no-renames", base, rev, "--", MATRIX)
    lines = (repo.show(rev, MATRIX) or "").split("\n")
    leg_lines = {leg["line"]: leg for leg in prepass.parse_shell("\n".join(lines))["legs"]}
    names = []
    for hunk in HUNK_RE.finditer(diff):
        removed = int(hunk.group(1) if hunk.group(1) is not None else 1)
        start, count = int(hunk.group(2)), int(hunk.group(3) if hunk.group(3) is not None else 1)
        if removed:
            return None
        for number in range(start, start + count):
            text = lines[number - 1].strip()
            if not text or text.startswith("#"):
                continue
            leg = leg_lines.get(number)
            if not leg or leg["status"] == "dead":
                return None
            names.append(leg_name(leg["args"]))
    return names


def added_dispatch_arms(repo, base, rev, path):
    """When a range only ADDS hunks to a flag dispatcher and each hunk brings a
    flag the base did not dispatch, those flags; otherwise None."""
    diff = repo.text("diff", "-U0", "--no-renames", base, rev, "--", path)
    before = set(DISPATCH_RE.findall(repo.show(base, path) or ""))
    lines = (repo.show(rev, path) or "").split("\n")
    flags = []
    for hunk in HUNK_RE.finditer(diff):
        removed = int(hunk.group(1) if hunk.group(1) is not None else 1)
        start, count = int(hunk.group(2)), int(hunk.group(3) if hunk.group(3) is not None else 1)
        new = set(DISPATCH_RE.findall("\n".join(lines[start - 1:start - 1 + count]))) - before
        if removed or not new:
            return None
        flags.extend(sorted(new))
    return flags or None


def dispatchers(index):
    return set(DISPATCH.values()) | {f for f in index.swift if f.endswith("Checks/main.swift")}


CAMEL_RE = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+")


def seam_legs(legs, path):
    flags = [name for name in legs if FLAG_RE.fullmatch(name)]
    words = {}
    for flag in flags:
        for word in set(flag[2:-len("-check")].split("-")):
            words[word] = words.get(word, 0) + 1
    stem = path.rsplit(".", 1)[0].split("/")[2:]  # below Sources/<target>/
    named = {w.lower() for part in stem for w in CAMEL_RE.findall(part)}
    rare = {w for w in named if len(w) >= SEAM_MIN and 0 < words.get(w, 0) <= SEAM_RARE}
    return {flag for flag in flags if rare & set(flag[2:-len("-check")].split("-"))}


def select(repo, rev, paths, built=None, base=None):
    index, legs, resources = built or build_map(repo, rev)
    broad, covering = split_broad(index, legs)
    chosen, reasons, per_path = set(), [], {}
    for path in paths:
        if path.startswith(INERT):
            per_path[path] = []
            continue
        if path == MATRIX and base:
            added = added_legs(repo, base, rev)
            if added is not None:
                # The new legs, and the legs that read run-matrix.sh itself.
                hit = set(added) | set(covering.get(path, set())) | {n for n in broad if path in legs[n]}
                per_path[path] = sorted(hit)
                chosen |= hit
                continue
        if path in dispatchers(index):
            arms = added_dispatch_arms(repo, base, rev, path) if base else None
            if arms is None:
                reasons.append("%s dispatches every leg of its binary and runs before each" % path)
            else:
                per_path[path] = sorted(set(arms))
                chosen |= set(arms)
            continue
        if path.startswith(FULL_PATHS):
            reasons.append("%s reaches every leg" % path)
            continue
        hit = set(covering.get(path, set()))
        for swift in resources.get(path, set()):
            hit |= covering.get(swift, set())
        if not hit and not path.endswith(".swift"):
            # A scanner that names this exact non-Swift file does exercise it.
            hit = {name for name in broad if path in legs[name]}
        if not hit:
            # Absent at this revision (deleted) reads the same: no leg is known to cover it.
            reasons.append("%s is covered by no specific leg" % path)
            continue
        hit |= {name for name in broad if path in legs[name]}
        if path.startswith("Sources/"):
            hit |= seam_legs(legs, path)
        per_path[path] = sorted(hit)
        chosen |= hit
    # ARRAY_MATRIX_LEGS matches a leg by its expanded words; a leg written with
    # a variable or quotes cannot be named, so only the full matrix runs it.
    for name in sorted(chosen):
        if any(c in name for c in "$\"'`"):
            reasons.append("leg cannot be selected by name: %s" % name)
    return dict(full=bool(reasons), full_reasons=reasons, legs=sorted(chosen), per_path=per_path, rev=rev)


def stats(repo, rev):
    index, legs, resources = build_map(repo, rev)
    broad, covering = split_broad(index, legs)
    mapped = {name for name, files in legs.items() if files}
    swift_mapped = [f for f in index.swift if f in covering]
    other = [f for f in resources if f in covering or any(s in covering for s in resources[f])]
    counts = sorted(len(covering.get(f, ())) for f in swift_mapped)
    return dict(legs=len(legs), mapped_legs=len(mapped), scanner_legs=sorted(broad),
                unmapped_legs=sorted(set(legs) - mapped), swift_files=len(index.swift),
                swift_files_mapped=len(swift_mapped), resource_files=len(resources), resource_files_mapped=len(other),
                legs_per_mapped_file_median=counts[len(counts) // 2] if counts else 0,
                hub_types=len(index.hubs),
                swift_files_unmapped=sorted(set(index.swift) - set(swift_mapped)))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sel = sub.add_parser("select")
    sel.add_argument("range", nargs="*")
    sel.add_argument("--paths", nargs="+")
    sel.add_argument("--rev", default="HEAD")
    sel.add_argument("--repo", default=".")
    sel.add_argument("--json", action="store_true")
    st = sub.add_parser("stats")
    st.add_argument("--rev", default="HEAD")
    st.add_argument("--repo", default=".")
    st.add_argument("--verbose", action="store_true")
    a = parser.parse_args(argv)
    try:
        repo = prepass.Repo(a.repo)
        if a.cmd == "stats":
            data = stats(repo, repo.resolve(a.rev))
            if not a.verbose:
                for key in ("unmapped_legs", "scanner_legs", "swift_files_unmapped"):
                    data[key] = len(data[key])
            print(json.dumps(data, indent=2))
            return 0
        merge_base = None
        if a.paths:
            rev, paths = repo.resolve(a.rev), a.paths
        elif len(a.range) == 2:
            base, rev = repo.resolve(a.range[0]), repo.resolve(a.range[1])
            merge_base = repo.text("merge-base", base, rev).strip()
            paths = [p for p in repo.text("diff", "--no-renames", "--name-only", merge_base, rev).splitlines() if p]
        else:
            parser.error("select takes BASE HEAD or --paths")
        result = select(repo, rev, paths, base=merge_base if not a.paths else None)
    except prepass.PrepassError as error:
        print("leg-coverage: %s" % error, file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(result, indent=2))
    elif result["full"]:
        print("FULL")
        for reason in result["full_reasons"]:
            print("  " + reason, file=sys.stderr)
    else:
        print("\n".join(result["legs"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
