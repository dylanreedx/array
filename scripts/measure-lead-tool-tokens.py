#!/usr/bin/env python3
"""Measure what Array's workspace tools cost a Claude Managed lead at start-up.

See docs/internals/managed-lead-tool-loading.md for the figures and method.

  python3 -I scripts/measure-lead-tool-tokens.py count
      Offline. Starts the built array-workspace-mcp, reads tools/list and
      prints tool, word and character counts, the longest tools and the
      repeated sentences. No CLI, no network, no login.

  python3 -I scripts/measure-lead-tool-tokens.py probe [--dry-run] [--model M]
      Live. One `claude -p` request per row (CLI alone, every tool deferred,
      the lead's three tools pinned, whole server always-loaded) answering
      "Reply with the single word ok.", and prints each row's total input
      tokens and the CLI's own count of deferred tools. --dry-run prints the
      argv and MCP config of each row and runs nothing.

The probe never reads, copies or prints a credential. Claude's config writes
go to a fresh temp dir (CLAUDE_CONFIG_DIR), never ~/.claude. The CLI reads
its own login: the Keychain item of the config dir this shell already points
at (CLAUDE_SECURESTORAGE_CONFIG_DIR), or the default item when it is unset.
Run from the repository root after `swift build --product array-workspace-mcp`.
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, ".build", "debug", "array-workspace-mcp")
CONFIG_SWIFT = os.path.join(ROOT, "Sources", "ContinuumRevivedCore", "WorkspaceAPI", "WorkspaceMCPConfiguration.swift")
LEAD_STATE_SWIFT = os.path.join(ROOT, "Sources", "ContinuumRevivedCore", "WorkspaceAPI", "ManagedLeadHookState.swift")
PROMPT = "Reply with the single word ok."


def guidance():
    text = open(CONFIG_SWIFT).read()
    return re.search(r'agentGuidance =\s*\n\s*"(.*?)"\n', text, re.S).group(1)


def pinned_tools():
    text = open(LEAD_STATE_SWIFT).read()
    return re.findall(r'"(array_[a-z_]+)"', re.search(r"alwaysLoadedTools = \[(.*?)\]", text).group(1))


def server_env(token_file, pinned=None):
    env = {"ARRAY_WORKSPACE_MCP_ENDPOINT": "http://127.0.0.1:9/unused",
           "ARRAY_WORKSPACE_AGENT_ID": "00000000-0000-0000-0000-000000000001",
           "ARRAY_WORKSPACE_MCP_TOKEN_FILE": token_file,
           "ARRAY_WORKSPACE_RESULT_DELIVERY": "push"}
    if pinned:
        env["ARRAY_WORKSPACE_ALWAYS_LOADED_TOOLS"] = ",".join(pinned)
    return env


def tools_list(work):
    token = os.path.join(work, "token")
    with open(token, "w") as f:
        f.write("unused")
    requests = ('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
                '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n')
    out = subprocess.run([SERVER], input=requests, capture_output=True, text=True, check=True,
                         env={**os.environ, **server_env(token)}).stdout
    replies = {o["id"]: o for o in (json.loads(l) for l in out.splitlines() if l.strip())}
    return replies[1]["result"]["instructions"], replies[2]["result"]["tools"]


def param_words(node):
    if isinstance(node, dict):
        return sum(len(v.split()) if k == "description" and isinstance(v, str) else param_words(v)
                   for k, v in node.items())
    if isinstance(node, list):
        return sum(param_words(v) for v in node)
    return 0


def count(_args):
    work = tempfile.mkdtemp(prefix="lead-tool-count-")
    try:
        instructions, tools = tools_list(work)
    finally:
        shutil.rmtree(work)
    rows = []
    for t in tools:
        d, schema = t["description"], json.dumps(t["inputSchema"])
        rows.append((len(d) + len(schema), t["name"], len(d.split()), len(d), param_words(t["inputSchema"]), len(schema)))
    print(f"server instructions: {len(instructions.split())} words")
    print(f"tools: {len(tools)}")
    print(f"description words: {sum(r[2] for r in rows)}  characters: {sum(r[3] for r in rows)}")
    print(f"parameter description words: {sum(r[4] for r in rows)}  schema JSON characters: {sum(r[5] for r in rows)}")
    print("\nlongest (description + schema JSON characters):")
    print("tool | description words | description + schema chars")
    for r in sorted(rows, reverse=True)[:10]:
        print(f"{r[1]} | {r[2]} | {r[0]}")
    pinned = set(pinned_tools())
    print(f"\npinned tools {sorted(pinned)}: description + schema chars per tool "
          + ", ".join(f"{r[1]} {r[0]}" for r in rows if r[1] in pinned)
          + f"; total {sum(r[0] for r in rows if r[1] in pinned)}")
    # A sentence counts as repeated when it appears, verbatim, in more than one
    # tool's description; the words of every copy after the first are summed.
    seen = collections.Counter()
    for t in tools:
        parts = {p.strip() for p in re.split(r"(?<=[.!?])\s+|\n+", t["description"]) if len(p.strip()) > 30}
        seen.update(parts)
    repeated = sum(len(s.split()) * (n - 1) for s, n in seen.items() if n > 1)
    print(f"\nwords in repeated sentences beyond their first copy: {repeated}")
    for s, n in seen.most_common():
        if n < 2:
            break
        print(f"  x{n}: {s[:100]}")


def probe(args):
    rows = [("CLI alone, no Array server", None, False),
            ("every Array tool deferred", [], False),
            ("lead's tools pinned", pinned_tools(), False),
            ("whole server alwaysLoad true", [], True)]
    keychain = os.environ.get("CLAUDE_CONFIG_DIR", "")
    work = tempfile.mkdtemp(prefix="lead-tool-probe-")
    token = os.path.join(work, "token")
    with open(token, "w") as f:
        f.write("unused")
    print(f"claude {subprocess.run(['claude', '--version'], capture_output=True, text=True).stdout.strip()}, model {args.model}")
    try:
        for name, pinned, always in rows:
            run = os.path.join(work, re.sub(r"[^a-z]+", "-", name.lower()))
            os.makedirs(os.path.join(run, "cwd"))
            os.makedirs(os.path.join(run, "config"))
            argv = ["claude", "-p", "--output-format", "stream-json", "--verbose", "--model", args.model,
                    "--no-session-persistence", "--permission-mode", "bypassPermissions",
                    "--disallowed-tools", "Edit,Write,MultiEdit,NotebookEdit,ListAgents",
                    "--debug-file", os.path.join(run, "debug.log"), "--strict-mcp-config"]
            config = None
            if pinned is not None:
                server = {"command": SERVER, "env": server_env(token, pinned), "timeout": 86400000}
                if always:
                    server["alwaysLoad"] = True
                config = {"mcpServers": {"array_workspace": server}}
                path = os.path.join(run, "mcp.json")
                with open(path, "w") as f:
                    json.dump(config, f)
                argv += ["--append-system-prompt", guidance(), "--allowedTools", "mcp__array_workspace",
                         "--mcp-config", path]
            if args.dry_run:
                print(f"\n{name}\n  argv: {json.dumps(argv)}\n  mcp config: {json.dumps(config)}")
                continue
            env = {**os.environ, "CLAUDE_CONFIG_DIR": os.path.join(run, "config"),
                   "CLAUDE_SECURESTORAGE_CONFIG_DIR": keychain}
            out = subprocess.run(argv, input=PROMPT, capture_output=True, text=True, cwd=os.path.join(run, "cwd"), env=env).stdout
            total = None
            for line in out.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("type") == "result":
                    u = event.get("usage", {})
                    total = u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
            deferred = None
            try:
                found = re.search(r"Dynamic tool loading: \d+/(\d+) deferred tools included", open(os.path.join(run, "debug.log")).read())
                deferred = found and found.group(1)
            except OSError:
                pass
            print(f"{name} | total input {total} | deferred tools {deferred}")
    finally:
        shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("count").set_defaults(run=count)
    p = sub.add_parser("probe")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--model", default="claude-haiku-5-5")
    p.set_defaults(run=probe)
    args = parser.parse_args()
    if not os.access(SERVER, os.X_OK):
        sys.exit(f"{SERVER} is missing: swift build --product array-workspace-mcp")
    args.run(args)


if __name__ == "__main__":
    main()
