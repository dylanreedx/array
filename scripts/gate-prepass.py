#!/usr/bin/env python3
"""Gate pre-pass: what a script can catch in a merged range, before review.

    python3 scripts/gate-prepass.py BASE HEAD [--repo DIR] [--json]
    python3 scripts/gate-prepass.py --check-manifest [REV] [--repo DIR]

Reads only Git objects (never the working tree), so any range can be checked
without a checkout. Only what the range ADDS is judged: added lines, new paths,
new commits. Existing debt never turns an unrelated change red. It reports; it
blocks nothing.

Exit status (each is witnessed by scripts/check-gate-prepass.py):
  0  no hard findings (advisories and info may be present)
  1  at least one hard finding
  2  the pre-pass could not run: bad or ambiguous revision, ranges with no
     shared history, wrong arguments, invalid or unreadable JSON input, git
     failure, or an internal error. One line on stderr says why. Callers must
     fail closed on 2, not treat it as clean.

Hard rules:
  commit-subject           `type(area): description`, under 72 characters;
                           git's own `Merge branch ...` / `Revert "..."` too
  commit-attribution       a co-author trailer, an AI noreply address, or a
                           line crediting an AI tool, in the subject or body
  unregistered-check-flag  a newly dispatched `--*-check` flag that no line of
                           run-matrix.sh (or the bundle harness it runs) runs
                           against the dispatching binary in a full run, and
                           that is not declared targeted-only with a reason
  bundle-module            `Bundle.module` added outside a checks target
  manifest-stale           a coverage-manifest entry this range made stale
Advisory rules:
  uncertain-check-flag     a flag the parser cannot classify, or a matrix leg
                           whose running static reading cannot decide
  built-check-flag         a `--*-check` flag assembled at run time
  commit-ticket-id         a ticket or issue id in a commit message
  commit-hedging           hedging ("attempt to fix") in a commit message
  coverage-unmapped        changed code paths no manifest entry covers
  choice-menu              NSMenu / NSPopUpButton added (reviewer classifies)
  notification-map         a sender added or touched without a map change
  dated-path               a new path component that contains a date
  commit-subject           an area-less subject (allowed for repo-wide changes)

Known limits (what a script cannot decide, so it says so instead):
  - A flag built from pieces (`"--" + name + "-check"`, interpolation, a
    hasPrefix/hasSuffix family) cannot be enumerated: built-check-flag.
  - run-matrix.sh is read statically. A leg inside a branch on a runtime
    condition, a while loop, a case arm or after && / || is "cannot tell";
    a leg in a `*_ONLY` mode branch, a heredoc, a literally false branch, an
    uncalled function or after an unconditional exit does not count as run.
  - Coverage is only as good as the manifest: it maps a handful of legs, and a
    broad glob over-invalidates (any AgentSupervisor*.swift change recommends
    both delegation checks, whichever part of the supervisor changed).
Registration never proves execution, and listing a check never proves it ran.
"""
import argparse
import bisect
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
CODE_PREFIXES = ("Sources/", "ios/", "iOS/", "scripts/", "Packaging/", "Tools/", "Package.swift")

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "style", "chore",
         "build", "ci", "revert")
SUBJECT_LIMIT = 72  # the whole subject must be UNDER this many characters
SUBJECT_RE = re.compile(r"^(?P<type>[A-Za-z]+)(?:\((?P<area>[^)]*)\))?(?P<bang>!)?: (?P<desc>\S.*)$")
AREA_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
GIT_SUBJECT_RE = re.compile(r"^(?:Merge (?:branch|branches|pull request|remote-tracking branch|tag|commit)\b|Revert \")")

# Attribution: who wrote the change. An AI tool or model named as the object of
# a credit, never a product merely mentioned in what the change does.
AI = (r"(?:claude|codex|chatgpt|gpt(?:-?[0-9][\w.]*)?|copilot|openai|anthropic|gemini"
      r"|(?:an?\s+)?(?:ai|llm)(?:\s+(?:assistant|model|tool|agent))?)")
AI_TAIL = r"(?:\s+(?:code|cli|opus|sonnet|haiku|fable|[0-9][\w.]*))*"
CREDIT = (r"(?:co-?authored|co-?written|written|generated|created|produced|made|built|drafted|authored|assisted)"
          r"\s+(?:with|by|using|via)\s+(?:the\s+help\s+of\s+)?\[?" + AI + AI_TAIL +
          r"\]?(?:\s*\([^)]*\))?(?:\s*<[^>]*>)?\s*[.!]?\s*$")
ATTRIBUTION_RES = [
    re.compile(r"\bco-authored-by\s*:\s*\S", re.I),                      # any co-author trailer
    re.compile(r"noreply@(?:anthropic|openai)\.com", re.I),
    re.compile(r"\b[a-z]+(?:-[a-z]+)*-by\s*:.*\b" + AI + r"\b", re.I),   # Assisted-by: Codex
    re.compile(r"^\W*(?i:" + CREDIT + r")"),                             # a body line that is a credit
]
# In the subject a credit must be capitalised ("... Generated with Claude"): the
# description itself is lowercase by rule, so "keep titles written by claude"
# describes a change and passes.
SUBJECT_CREDIT_RE = re.compile(r"\b(?:Co-?[Aa]uthored|Co-?[Ww]ritten|Written|Generated|Created|Produced|Made|Built"
                               r"|Drafted|Authored|Assisted)(?i:" + CREDIT[CREDIT.index(r"\s+(?:with"):] + r")")
# Ticket ids and hedging are advisory: a version (0.7.46), a plan (.plans/46,
# plan 113) or a build number (build 98) is never a ticket id.
TICKET_RES = [
    re.compile(r"\b(?:ticket|issue|bug|jira)s?\s*(?:#\s*|no\.\s*)?[A-Z]{0,4}-?\d+(?:\.\d+)*\b", re.I),
    re.compile(r"(?<![\w&/#])#\d+\b"),
    re.compile(r"\b(?!(?:UTF|SHA|ISO|RFC|GPT|MAC|IOS|CAT|CMD|DEL|DEV|HOST|NEXT|NOTIFY|OUT|OWN|PUB|QA|REG|SRC|SUR)-)"
               r"[A-Z][A-Z0-9]+-\d+\b"),                                  # CX-01, ABC-123
    re.compile(r"\b[A-Z]\d+\.\d+\b"),                                     # P1.7, M1.10
]
HEDGE_RES = [
    re.compile(r"\b(?:attempt(?:s|ed|ing)?|try(?:ing)?|tries|tried)\s+to\s+(?:fix|solve|resolve|address|repair)\b", re.I),
    re.compile(r"\b(?:might|may|should|could)\s+(?:fix|solve|resolve|help)\b", re.I),
    re.compile(r"\b(?:hopefully|possibly\s+fix(?:es)?|probably\s+fix(?:es)?)\b", re.I),
    re.compile(r"\b(?:possible|potential|tentative|speculative)\s+fix\b|\bfix\s+attempt\b", re.I),
]

FLAG = r"(--[a-z0-9][a-z0-9-]*-check)"
QFLAG = r'"' + FLAG + r'"'
FLAG_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9_-])" + FLAG + r"(?![A-Za-z0-9_-])")  # --x-check, never --x-check-extra
ARGS = r"CommandLine\s*\.\s*arguments\s*\.\s*"
# Dispatch forms, matched across line breaks on the comment-free view of a file.
DISPATCH_RES = [
    re.compile(ARGS + r"contains\(\s*" + QFLAG + r"\s*\)"),
    re.compile(ARGS + r"(?:firstIndex|lastIndex)\(\s*of:\s*" + QFLAG + r"\s*\)"),
    re.compile(ARGS + r"contains\s*(?:\(\s*where:\s*)?\{(?P<body>[^{}]*)\}"),  # every flag in the closure
    re.compile(r"^[ \t]*\(\s*" + QFLAG + r"\s*,", re.M),                       # a (flag, runner) table row
    re.compile(r"\bcase\s+(?P<body>\"--[^\"\n]*\"(?:\s*,\s*\"[^\"\n]*\")*)\s*:"),  # case "--a-check", "--b-check":
]
FOR_LIST_RE = re.compile(r"\bfor\s+(?P<var>[A-Za-z_]\w*)\s+in\s+\[(?P<body>[^\[\]]*)\]")
UNCERTAIN_RES = [
    re.compile(r"\b(?:let|var)\s+\w+\s*(?::[^=\n]+)?=\s*" + QFLAG),
    re.compile(r"\b(?:let|var)\s+\w+\s*(?::[^=\n]+)?=\s*\[(?P<body>[^\[\]]*)\]"),
    re.compile(r"\.\s*(?:contains|firstIndex|lastIndex)\(\s*(?:of:\s*)?" + QFLAG + r"\s*\)"),  # another receiver
]
BUILT_RES = [
    re.compile(r'"--[^"\n]*\\\([^"\n]*-check"'),                       # "--\(name)-check"
    re.compile(r'\+\s*"[a-z0-9-]*-check"'),                            # ... + "-check"
    re.compile(r'"--[a-z0-9-]*"\s*\+[^\n]*-check'),                    # "--" + name + ...-check
    re.compile(r'hasPrefix\(\s*"--[a-z0-9][a-z0-9-]*"\s*\)[^\n]*hasSuffix\(\s*"-check"\s*\)'),
    re.compile(r'hasSuffix\(\s*"-check"\s*\)[^\n]*hasPrefix\(\s*"--[a-z0-9][a-z0-9-]*"\s*\)'),
]
RUNNERS = ("run", "run_leg", "run_app_check", "run_ios_build")
MATRIX_ASSIGN_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*=" + FLAG)
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
# A static reader for run-matrix.sh. It decides, per leg, whether a full run
# reaches it: "run", "unknown" (a runtime condition static reading cannot
# decide), "mode" (only a targeted *_ONLY mode reaches it) or "dead" (a heredoc,
# a literally false branch, an uncalled function, after an unconditional exit).
RANK = {"run": 0, "unknown": 1, "mode": 2, "dead": 3}
ASSIGN_WORD_RE = re.compile(r"""[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s"';])*""")
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def _worse(a, b):
    return a if RANK[a[0]] >= RANK[b[0]] else b


def _strip_comment(line):
    quote, j = None, 0
    while j < len(line):
        c = line[j]
        if quote:
            if c == "\\" and quote == '"':
                j += 1
            elif c == quote:
                quote = None
        elif c == "\\":
            j += 1
        elif c in "'\"":
            quote = c
        elif c == "#" and (j == 0 or line[j - 1].isspace()):
            return line[:j].rstrip()
        j += 1
    return line


def shell_lines(text):
    """Logical command lines: (first line number, text). Comments dropped,
    `\\` continuations and multi-line array literals joined, heredoc bodies
    dropped (a heredoc body is data, never a command)."""
    raw = (text or "").split("\n")
    out, i = [], 0
    while i < len(raw):
        start, parts = i + 1, []
        while i < len(raw):
            line = _strip_comment(raw[i]); i += 1
            trailing = len(line) - len(line.rstrip("\\"))
            if trailing % 2 == 1:
                parts.append(line[:-1]); continue
            parts.append(line)
            joined = " ".join(p.strip() for p in parts if p.strip())
            if re.match(r"\s*(?:local\s+|declare\s+(?:-\w+\s+)*)?[A-Za-z_]\w*\+?=\(", joined) \
                    and joined.count("(") > joined.count(")"):
                continue
            break
        logical = " ".join(p.strip() for p in parts if p.strip())
        for m in HEREDOC_RE.finditer(logical):
            term = m.group(3)
            while i < len(raw):
                body = raw[i]; i += 1
                if body.strip() == term:
                    break
        if logical:
            out.append((start, logical))
    return out


def split_segments(line):
    """[(separator before, segment)]: split on ; && || | & outside quotes,
    $( ), ( ) and [[ ]]. Separator "&&"/"||" means the segment is conditional."""
    segs, buf, sep = [], [], ";"
    quote, depth, brackets, i, n = None, 0, 0, 0, len(line)
    while i < n:
        c = line[i]
        if quote:
            buf.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                buf.append(line[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c in "'\"":
            quote = c; buf.append(c); i += 1; continue
        if c == "\\" and i + 1 < n:
            buf.append(line[i:i + 2]); i += 2; continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        elif line.startswith("[[", i) and (i == 0 or line[i - 1].isspace()):
            brackets += 1
        elif line.startswith("]]", i) and brackets:
            brackets -= 1
        if depth == 0 and brackets == 0:
            op = next((o for o in ("&&", "||", ";;", ";", "|", "&") if line.startswith(o, i)), None)
            if op == "&" and ((i and line[i - 1] in "<>") or line.startswith("&>", i)):
                op = None
            if op:
                segs.append((sep, "".join(buf).strip())); buf = []
                sep = op if op in ("&&", "||") else ";"
                i += len(op); continue
        buf.append(c); i += 1
    segs.append((sep, "".join(buf).strip()))
    return [(s, t) for s, t in segs if t]


def classify_condition(cond):
    c = cond.strip()
    if re.fullmatch(r"false|!\s*true|!\s*:", c):
        return "dead", "`if %s`, which is never true" % c
    m = re.fullmatch(r"\[\[?\s*(['\"]?)(-?\d+)\1\s*(-eq|-ne|-lt|-gt|-le|-ge|==|!=|=)\s*(['\"]?)(-?\d+)\4\s*\]\]?", c)
    if m:
        a, op, b = int(m.group(2)), m.group(3), int(m.group(5))
        ok = {"-eq": a == b, "==": a == b, "=": a == b, "-ne": a != b, "!=": a != b,
              "-lt": a < b, "-gt": a > b, "-le": a <= b, "-ge": a >= b}[op]
        return ("run", "") if ok else ("dead", "`if %s`, which is never true" % c)
    m = re.search(r"\$\{?([A-Z0-9_]*_ONLY)\}?\"?\s*(?:-eq|==|=)\s*\"?1\b", c)
    if m:
        return "mode", "the targeted %s branch (`if %s`)" % (m.group(1), c)
    return "unknown", "`if %s`" % c


def parse_shell(text):
    """Legs, arrays and assigned flags of a bash script, each leg with the best
    static answer to "does a full run reach this line"."""
    legs, calls, arrays, assigned = [], [], {}, set()
    stack, state = [], {"exited": None}
    lines = shell_lines(text)

    def context():
        status, func = ("run", ""), None
        if state["exited"]:
            status = ("dead", "after the unconditional exit at line %d" % state["exited"])
        for f in stack:
            if f["kind"] == "func":
                status, func = ("run", ""), f["name"]
                continue
            status = _worse(status, (f["status"], f["why"]))
            if f.get("exited"):
                status = _worse(status, ("dead", "after the exit at line %d" % f["exited"]))
        return status, func

    def nearest(kinds):
        for index in range(len(stack) - 1, -1, -1):
            if stack[index]["kind"] in kinds:
                return index
        return None

    def items_of(text_):
        out = []
        for token in re.findall(r"\"[^\"]*\"|'[^']*'|\S+", text_):
            arr = re.fullmatch(r"\"?\$\{(\w+)\[@\]\}\"?", token)
            if arr:
                if arr.group(1) not in arrays:
                    return None
                out.extend(arrays[arr.group(1)]); continue
            bare = token.strip("'\"")
            if "$" in bare or "`" in bare or re.search(r"[*?\[]", bare):
                return None
            out.append(bare)
        return out

    def command(number, sep, seg):
        (status, why), func = context()
        if sep in ("&&", "||"):
            status, why = _worse((status, why), ("unknown", "a command after %s" % sep))
        body = seg
        while True:
            m = re.match(r"(?:!|time)\s+|(?:local|export|readonly|declare(?:\s+-\w+)*)\s+(?=\w+\+?=\()", body)
            if not m:
                break
            body = body[m.end():]
        arr = re.fullmatch(r"([A-Za-z_]\w*)(\+?)=\((.*)\)", body)
        if arr:
            values = items_of(arr.group(3)) or []
            arrays[arr.group(1)] = (arrays.get(arr.group(1), []) if arr.group(2) else []) + values
            return
        while True:
            m = ASSIGN_WORD_RE.match(body)
            if not m or (m.end() < len(body) and not body[m.end()].isspace()):
                break
            body = body[m.end():].lstrip()
        word = body.split(None, 1)[0] if body else ""
        if word not in RUNNERS:
            assigned.update(MATRIX_ASSIGN_RE.findall(seg))
        if word in ("exit", "return", "exec") and sep not in ("&&", "||"):
            if stack:
                stack[-1]["exited"] = number
            else:
                state["exited"] = number
        if word in RUNNERS:
            args = body[len(word):].strip()
            variants = [(args, status, why)]
            for f in stack:
                if f["kind"] != "loop" or not f.get("var"):
                    continue
                ref = re.compile(r"\"?\$\{?%s\}?\"?" % re.escape(f["var"]))
                expanded = []
                for a, st, wh in variants:
                    if not ref.search(a):
                        expanded.append((a, st, wh))
                    elif f["items"] is None:
                        expanded.append((a,) + _worse((st, wh), ("unknown", "a loop over a list the pre-pass cannot read (line %d)" % f["line"])))
                    else:
                        expanded.extend((ref.sub(lambda _m, v=v: v, a), st, wh) for v in f["items"])
                variants = expanded
            for a, st, wh in variants:
                legs.append({"args": a, "line": number, "status": st, "why": wh, "func": func})
        elif word:
            calls.append({"name": word, "line": number, "status": status, "why": why, "func": func})

    def segment(number, sep, seg):
        top = stack[-1] if stack else None
        if top and top.get("awaiting") == "then":
            m = re.match(r"then\b\s*", seg)
            if not m:
                top["cond"] += (" %s " % sep if top["cond"] else "") + seg
                return
            top["awaiting"] = None
            top["status"], top["why"] = classify_condition(top["cond"])
            if top["arms"]:
                top["status"], top["why"] = _worse((top["status"], top["why"]),
                                                   ("unknown", "an elif after `if %s`" % top["first"]))
                if classify_condition(top["cond"])[0] == "dead":
                    top["status"], top["why"] = classify_condition(top["cond"])
            seg = seg[m.end():]
            if not seg:
                return
        if top and top.get("awaiting") == "do":
            m = re.match(r"do\b\s*", seg)
            if not m:
                return
            top["awaiting"] = None
            seg = seg[m.end():]
            if not seg:
                return
        if top and top.get("awaiting") == "{":
            if seg.startswith("{"):
                top["awaiting"] = None
                seg = seg[1:].strip()
                if not seg:
                    return
        if top and top["kind"] == "case":
            m = re.match(r"\(?[^()\s]+\)\s*", seg)
            if m:
                seg = seg[m.end():]
                if not seg:
                    return
        m = re.match(r"(if|elif|else|fi|for|while|until|do|done|case|esac)\b\s*(.*)", seg)
        key, rest = (m.group(1), m.group(2)) if m else (None, seg)
        conditional = sep in ("&&", "||")
        if key == "if":
            stack.append({"kind": "if", "awaiting": "then", "cond": rest, "first": rest, "arms": [], "line": number,
                          "status": "unknown", "why": "", "exited": None})
            return
        if key in ("elif", "else"):
            index = nearest(("if",))
            if index is None:
                return
            del stack[index + 1:]
            f = stack[index]
            f["arms"].append(f["status"]); f["exited"] = None
            if key == "elif":
                f["awaiting"], f["cond"] = "then", rest
                return
            if all(a in ("dead", "mode") for a in f["arms"]):
                f["status"], f["why"] = "run", ""
            else:
                f["status"], f["why"] = "unknown", "the else of `if %s`" % f["first"]
            if rest:
                segment(number, ";", rest)
            return
        if key == "fi":
            index = nearest(("if",))
            if index is not None:
                del stack[index:]
            return
        if key in ("for", "while", "until"):
            frame = {"kind": "loop", "awaiting": "do", "line": number, "status": "unknown",
                     "why": "a %s loop (line %d)" % (key, number), "exited": None, "var": None, "items": None}
            fm = re.match(r"([A-Za-z_]\w*)\s+in\s+(.*)$", rest) if key == "for" else None
            if fm:
                frame.update(var=fm.group(1), items=items_of(fm.group(2)), status="run", why="")
            if conditional:
                frame["status"], frame["why"] = "unknown", "a loop after %s" % sep
            stack.append(frame)
            return
        if key == "do":
            if rest:
                segment(number, ";", rest)
            return
        if key == "done":
            index = nearest(("loop",))
            if index is not None:
                del stack[index:]
            return
        if key == "case":
            stack.append({"kind": "case", "line": number, "status": "unknown",
                          "why": "a case arm (line %d)" % number, "exited": None})
            return
        if key == "esac":
            index = nearest(("case",))
            if index is not None:
                del stack[index:]
            return
        fm = re.match(r"(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*(.*)$", seg) or \
            re.match(r"function\s+([A-Za-z_][\w-]*)\s*(.*)$", seg)
        if fm:
            name, body = fm.group(1), fm.group(2).strip()
            frame = {"kind": "func", "name": name, "line": number, "status": "run", "why": "", "exited": None,
                     "awaiting": "{"}
            stack.append(frame)
            if body.startswith("{"):
                frame["awaiting"] = None
                body = body[1:].strip()
            if body:
                segment(number, ";", body)
            return
        if seg.startswith("{"):
            stack.append({"kind": "group", "line": number, "exited": None,
                          "status": "unknown" if conditional else "run",
                          "why": "a { } group after %s" % sep if conditional else ""})
            if seg[1:].strip():
                segment(number, ";", seg[1:].strip())
            return
        if seg.startswith("}"):
            index = nearest(("func", "group"))
            if index is not None:
                del stack[index:]
            return
        command(number, sep, seg)

    for number, logical in lines:
        for sep, seg in split_segments(logical):
            segment(number, sep, seg)

    # A leg in a function runs only as well as the best place that calls it.
    words = " ".join(t for _, t in lines)
    memo = {}

    def func_status(name, seen=()):
        if name in memo:
            return memo[name]
        if name in seen:
            return ("dead", "only a recursive call reaches function %s" % name)
        best = None
        sites = [c for c in calls if c["name"] == name]
        for c in sites:
            st = (c["status"], c["why"])
            if c["func"]:
                st = _worse(st, func_status(c["func"], seen + (name,)))
            if best is None or RANK[st[0]] < RANK[best[0]]:
                best = st
        if best is None:
            mentions = len(re.findall(r"(?<![\w-])%s(?![\w-])" % re.escape(name), words))
            best = ("unknown", "function %s, reached only indirectly" % name) if mentions > 1 + len(sites) \
                else ("dead", "function %s, which nothing calls" % name)
        memo[name] = best
        return best

    for leg in legs:
        if leg["func"]:
            leg["status"], leg["why"] = _worse((leg["status"], leg["why"]), func_status(leg["func"]))
    return {"legs": legs, "arrays": arrays, "assigned": assigned}


def runs_binary(args, binary):
    """True when a leg's command names the executable that dispatches a flag."""
    if binary is None:
        return True
    return any(tok.strip("'\"").rsplit("/", 1)[-1] == binary for tok in args.split())


def registration(repo, rev):
    parsed = parse_shell(repo.show(rev, MATRIX))
    legs = parsed["legs"]
    bundle = {}
    for path, array in BUNDLE_HARNESSES.items():
        reach = [l for l in legs if path in l["args"].split()]
        if not reach:
            continue
        best = min(reach, key=lambda l: RANK[l["status"]])
        for flag in parse_shell(repo.show(rev, path))["arrays"].get(array, []):
            if FLAG_TOKEN_RE.fullmatch(flag):
                bundle[flag] = {"args": "%s (%s)" % (path, array), "line": best["line"], "status": best["status"],
                                "why": best["why"], "binary": "Array"}
    return {"legs": legs, "bundle": bundle, "assigned": parsed["assigned"]}


def flag_legs(reg, flag, binary):
    """(best leg running flag against binary, a leg running it against another binary)."""
    hits = [l for l in reg["legs"] if flag in FLAG_TOKEN_RE.findall(l["args"])]
    if flag in reg["bundle"]:
        hits.append(reg["bundle"][flag])
    same = [h for h in hits if runs_binary(h["args"], binary) or h.get("binary") == binary]
    if same:
        return min(same, key=lambda l: RANK[l["status"]]), None
    return None, (hits[0] if hits else None)


def full_run_legs(reg):
    return len({leg["args"] for leg in reg["legs"] if leg["status"] == "run"})


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
        invocation = entry.get("invocation")
        if isinstance(invocation, str):
            if invocation in seen:
                problems.append("%s duplicates invocation %r" % (where, invocation))
            seen.add(invocation)
        for key in ("covers", "checkFiles"):
            value = entry.get(key, [] if key == "checkFiles" else None)
            if not isinstance(value, list) or not all(isinstance(g, str) and g for g in value) \
                    or (key == "covers" and not value):
                problems.append("%s.%s must be a %slist of globs" % (where, key, "non-empty " if key == "covers" else ""))
    targeted = data.get("targetedOnly", [])
    if not isinstance(targeted, list):
        problems.append("targetedOnly must be a list")
        targeted = []
    targeted_seen = set()
    for index, entry in enumerate(targeted):
        where = "targetedOnly[%d]" % index
        if not isinstance(entry, dict):
            problems.append(where + " must be an object"); continue
        flag = entry.get("flag")
        if not isinstance(flag, str) or not re.fullmatch(FLAG, flag):
            problems.append(where + ".flag must be an exact --*-check flag")
        elif flag in targeted_seen:
            problems.append(where + ".flag is duplicated")
        else:
            targeted_seen.add(flag)
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip() or len(reason.splitlines()) != 1:
            problems.append(where + ".reason must be a non-empty one-line reason")
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
    if "mappedLegs" in data and data["mappedLegs"] != len(checks):
        problems.append("mappedLegs says %r but checks lists %d" % (data["mappedLegs"], len(checks)))
    if problems:
        raise PrepassError("%s is invalid at %s: %s" % (MANIFEST, rev[:12], "; ".join(problems)))
    return data


def manifest_staleness(repo, rev, manifest, reg=None):
    """Stale keys: an invocation no matrix leg runs, a glob matching no file."""
    if manifest is None:
        return set()
    reg = reg or registration(repo, rev)
    files = repo.files(rev)
    legs = {leg["args"] for leg in reg["legs"] if leg["status"] != "dead"}
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
    out = repo.text("log", "--reverse", "--format=%H%x00%B%x1e", "%s..%s" % (base, head))
    found = []
    commits = 0
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        commits += 1
        sha, body = record.split("\0", 1)
        short = sha[:9]
        lines = body.split("\n")
        subject = lines[0].strip() if lines else ""
        problems = subject_problems(subject)
        if problems:
            if GIT_SUBJECT_RE.match(subject):
                problems = ["git's generated subject is not accepted: every subject is `type(area): description`, "
                            "no exceptions; write it as `chore(release): merge integration into main` or "
                            "`revert(sidebar): drop the sample-app scaffolding`"]
            found.append(finding("commit-subject", "fail", "; ".join(problems), commit=short, subject=subject))
        elif SUBJECT_RE.match(subject).group("area") is None:
            found.append(finding("commit-subject", "advisory",
                                 "no (area): allowed only for a repo-wide change", commit=short, subject=subject))
        for number, line in enumerate(lines, start=1):
            stripped = line.strip()
            credit = any(rx.search(stripped) for rx in ATTRIBUTION_RES[:3]) or \
                (SUBJECT_CREDIT_RE.search(stripped) if number == 1 else ATTRIBUTION_RES[3].search(stripped))
            if credit:
                found.append(finding("commit-attribution", "fail",
                                     "attribution is not allowed: %s" % stripped, commit=short, line=number))
        for rule, patterns, what in (("commit-ticket-id", TICKET_RES, "a ticket or issue id"),
                                     ("commit-hedging", HEDGE_RES, "hedging")):
            for number, line in enumerate(lines, start=1):
                hit = next((m.group(0) for rx in patterns for m in [rx.search(line)] if m), None)
                if hit:
                    found.append(finding(rule, "advisory", "%s in the message: %r (line %d)" % (what, hit, number),
                                         commit=short, line=number))
                    break
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


def swift_views(repo, rev, path, cache):
    if (rev, path) not in cache:
        source = repo.show(rev, path) or ""
        keep, code = strip_swift(source)
        cache[(rev, path)] = (keep, code, source.split("\n"))
    return cache[(rev, path)]


def target_binary(path):
    """The executable whose argv a source file's dispatch reads, when known."""
    parts = path.split("/")
    if len(parts) > 2 and parts[0] == "Sources":
        if parts[1] == "ContinuumRevived":
            return "Array"
        if parts[1].endswith("Checks"):
            return parts[1]
    return None


def flag_hits(keep):
    """Every `--*-check` flag form in a comment-free view of a Swift file:
    [(kind, flag, flag line, first span line, last span line)], kind one of
    dispatch / loop / uncertain / built. Matched across line breaks."""
    text = "\n".join(keep)
    starts = [0]
    for line in keep:
        starts.append(starts[-1] + len(line) + 1)

    def line_of(offset):
        return bisect.bisect_right(starts, offset)

    hits = []

    def flags_in(m):
        if "body" in m.re.groupindex:
            base = m.start("body")
            return [(f.group(1), base + f.start(1)) for f in FLAG_TOKEN_RE.finditer(m.group("body"))]
        return [(m.group(1), m.start(1))]

    def add(kind, m, flags):
        first, last = line_of(m.start()), line_of(m.end() - 1)
        for flag, offset in flags:
            hits.append((kind, flag, line_of(offset), first, last))

    for rx in DISPATCH_RES:
        for m in rx.finditer(text):
            add("dispatch", m, flags_in(m))
    for m in FOR_LIST_RE.finditer(text):
        flags = flags_in(m)
        if not flags:
            continue
        body, open_at = "", text.find("{", m.end())
        if open_at >= 0:
            depth, j = 0, open_at
            while j < len(text):
                depth += {"{": 1, "}": -1}.get(text[j], 0)
                if depth == 0:
                    break
                j += 1
            body = text[m.end():j]  # a `where` clause reads argv before the brace
        reads_argv = re.search(r"arguments\s*\.\s*(?:contains\(\s*|(?:first|last)Index\(\s*of:\s*)%s\b" % m.group("var"), body)
        add("dispatch" if reads_argv else "loop", m, flags)
    for index, rx in enumerate(UNCERTAIN_RES):
        for m in rx.finditer(text):
            if index == 2 and re.search(r"CommandLine\s*\.\s*arguments\s*$", text[max(0, m.start() - 80):m.start()]):
                continue
            add("uncertain", m, flags_in(m))
    for rx in BUILT_RES:
        for m in rx.finditer(text):
            first, last = line_of(m.start()), line_of(m.end() - 1)
            hits.append(("built", None, first, first, last))
    return hits


def check_swift(repo, base, head, changes, renamed_diff, unrenamed_diff, reg, manifest, notify_patterns):
    found, notify_hits, cache = [], [], {}
    targeted = {entry["flag"] for entry in (manifest or {}).get("targetedOnly", [])}
    # A flag dispatched before the range in a file it touches is not new: moved
    # code and edits beside old debt never count.
    base_flags = set()
    for change in changes:
        for path in {change["path"], change["old"]} - {None}:
            if path.endswith(".swift"):
                keep, _, _ = swift_views(repo, base, path, cache)
                base_flags.update(h[1] for h in flag_hits(keep) if h[0] == "dispatch")
    scanned = []
    for path, change in sorted(renamed_diff.items()):
        if path.endswith(".swift") and change["added"]:
            keep, _, _ = swift_views(repo, head, path, cache)
            added = set(change["added"])
            hits = [h for h in flag_hits(keep) if any(h[3] <= n <= h[4] for n in added)]
            scanned.append((path, change, hits))
    # A flag this range dispatches is judged at its dispatch; a copy held
    # elsewhere (a `static let flag`) adds nothing.
    range_dispatched = {h[1] for _, _, hits in scanned for h in hits if h[0] == "dispatch"}
    for path, change, hits in scanned:
        keep, code, source = swift_views(repo, head, path, cache)
        added, binary = set(change["added"]), target_binary(path)
        reported = set()
        for kind, flag, number, first, last in hits:
            if (kind, flag, number) in reported:
                continue
            reported.add((kind, flag, number))
            raw = source[number - 1] if number - 1 < len(source) else ""
            if kind == "built":
                add_line_finding(found, manifest, "built-check-flag", "advisory",
                                 "a --*-check flag is assembled at run time; no script can list which flags this "
                                 "dispatches: confirm each one is registered", path, number, raw)
                continue
            if flag in base_flags or flag in targeted:
                continue
            best, other = flag_legs(reg, flag, binary)
            if kind != "dispatch":
                if flag in range_dispatched or (best and best["status"] == "run"):
                    continue
                why = "held in a loop that does not read the arguments" if kind == "loop" else "held in a form"
                add_line_finding(found, manifest, "uncertain-check-flag", "advisory",
                                 "%s is %s the pre-pass cannot classify; confirm it is dispatched and registered"
                                 % (flag, why), path, number, raw, flag=flag)
                continue
            owner = binary or "this target"
            if best and best["status"] == "run":
                continue
            if best and best["status"] == "unknown":
                add_line_finding(found, manifest, "uncertain-check-flag", "advisory",
                                 "cannot tell whether %s runs: run-matrix.sh:%d sits inside %s"
                                 % (flag, best["line"], best["why"]), path, number, raw, flag=flag)
            elif best:
                add_line_finding(found, manifest, "unregistered-check-flag", "fail",
                                 "%s is run only at run-matrix.sh:%d, inside %s; a full run never reaches it"
                                 % (flag, best["line"], best["why"]), path, number, raw, flag=flag)
            elif other:
                add_line_finding(found, manifest, "unregistered-check-flag", "fail",
                                 "%s is dispatched by %s, but run-matrix.sh:%d runs it against another executable"
                                 % (flag, owner, other["line"]), path, number, raw, flag=flag)
            elif flag in reg["assigned"]:
                add_line_finding(found, manifest, "uncertain-check-flag", "advisory",
                                 "%s appears in run-matrix.sh only as an assignment; confirm a harness runs it" % flag,
                                 path, number, raw, flag=flag)
            else:
                add_line_finding(found, manifest, "unregistered-check-flag", "fail",
                                 "%s is undeclared: register it in the matrix or bundle harness, or declare it "
                                 "targeted-only with a reason" % flag, path, number, raw, flag=flag)
        for number in sorted(added):
            if number - 1 >= len(keep) or is_checks_path(path):
                continue
            kept, bare, raw = keep[number - 1], code[number - 1], change["added"][number]
            menus = sorted(set(CHOICE_MENU_RE.findall(bare)))
            if menus:
                add_line_finding(found, manifest, "choice-menu", "advisory",
                                 "%s added: a choice menu must use ChoiceButton / ChoicePopoverController; context and app menus are fine" % "/".join(menus),
                                 path, number, raw)
            if any(re.search(p, kept) for p in notify_patterns):
                notify_hits.append((path, number, raw))
    # Bundle.module: judged on the rename-blind diff, so moved code counts.
    for path, change in sorted(unrenamed_diff.items()):
        if not path.endswith(".swift") or is_checks_path(path) or path.endswith("Checks.swift"):
            continue
        _, code, _ = swift_views(repo, head, path, cache)
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
    sys.dont_write_bytecode = True
    path = Path(__file__).resolve().with_name("check-notification-map.py")
    try:
        spec = importlib.util.spec_from_file_location("check_notification_map", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return list(module.PATTERNS.values())
    except Exception as error:
        raise PrepassError("cannot load the sender patterns from %s: %s" % (path.name, error))


def load_senders(repo, rev):
    text = repo.show(rev, NOTIFY_SENDERS)
    if text is None:
        return set()
    try:
        data = json.loads(text)
    except ValueError as error:
        raise PrepassError("%s is not valid JSON at %s: %s" % (NOTIFY_SENDERS, rev[:12], error))
    if not isinstance(data, (dict, list)) or not all(isinstance(key, str) for key in data):
        raise PrepassError("%s must map source paths to senders at %s" % (NOTIFY_SENDERS, rev[:12]))
    return set(data)


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
    sender_paths = load_senders(repo, head)
    swift_found, notify_hits = check_swift(repo, merge_base, head, changes, renamed, unrenamed, reg, manifest,
                                           notification_patterns())
    found += swift_found
    found += check_notifications(changes, notify_hits, sender_paths)
    found += check_dated_paths(repo, merge_base, changes)
    was_stale = manifest_staleness(repo, merge_base, base_manifest)
    for kind, invocation, glob in sorted(manifest_staleness(repo, head, manifest, reg) - was_stale):
        if kind == "invocation":
            message = "manifest names %r, which no reachable run-matrix.sh leg runs" % invocation
        else:
            message = "manifest %s glob %r for %r matches no file" % (kind, glob, invocation)
        found.append(finding("manifest-stale", "fail", message, path=MANIFEST))
    checks, unmapped = coverage(manifest, changes)
    if unmapped:
        found.append(finding("coverage-unmapped", "advisory",
                             "no coverage mapped for %d changed code path(s); this is not \"nothing to rerun\": "
                             "the manifest maps %d of %d full-run legs, so pick the checks by hand"
                             % (len(unmapped), len(manifest["checks"]), full_run_legs(reg))))
    found.sort(key=lambda f: (SEVERITY_ORDER[f["severity"]], f["rule"], f.get("commit", ""), f.get("path", ""),
                              f.get("line", 0), f["message"]))
    hard = sum(1 for f in found if f["severity"] == "fail")
    return {
        "base": base, "head": head, "mergeBase": merge_base, "commits": commits,
        "changedPaths": len(changes), "manifestVersion": manifest["version"],
        "mappedLegs": len(manifest["checks"]), "fullRunLegs": full_run_legs(reg),
        "findings": found, "checks": checks, "unmapped": unmapped,
        "exit": 1 if hard else 0,
    }


def render(report):
    out = ["gate pre-pass  base %s  head %s  commits %d  paths %d  manifest v%d maps %d of %d full-run legs" % (
        report["base"][:9], report["head"][:9], report["commits"], report["changedPaths"], report["manifestVersion"],
        report["mappedLegs"], report["fullRunLegs"])]
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
    if report["checks"]:
        out.append("checks covering this change (listing is not running):")
    elif report["unmapped"]:
        out.append("checks covering this change: no coverage mapped (not the same as nothing to rerun)")
    else:
        out.append("checks covering this change: no code path changed")
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


class OneLineParser(argparse.ArgumentParser):
    def error(self, message):
        print("gate pre-pass ERROR: %s (usage: gate-prepass.py BASE HEAD [--repo DIR] [--json])" % message,
              file=sys.stderr)
        sys.exit(2)


def main(argv):
    parser = OneLineParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
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
            raise PrepassError("expected two revisions, got %d (usage: gate-prepass.py BASE HEAD)" % len(args.revs))
        report = run_prepass(repo, args.revs[0], args.revs[1])
    except Exception as error:  # every could-not-run case is exit 2, never a finding
        if not isinstance(error, (PrepassError, OSError)):
            error = "internal error: %s: %s" % (type(error).__name__, error)
        if args.json:
            print(json.dumps({"error": str(error), "exit": 2}, indent=2, sort_keys=True))
        print("gate pre-pass ERROR: %s" % error, file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True) if args.json else render(report))
    return report["exit"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
