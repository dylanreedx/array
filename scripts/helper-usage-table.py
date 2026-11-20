#!/usr/bin/env python3
"""Per-run token table for helper-usage-live.sh runs and raw-cli runs.

Tokens come from the CLI's own usage fields: assistant entries of each session
transcript (deduplicated by message id), or the stream-json of a raw run.
  helper-usage-table.py RUNS_DIR [--projects DIR]
Columns: fresh input, cache read, cache write, output, turns (API calls),
first-call context of each session, wall seconds, lead wakes (finished relays)."""
import glob, json, os, re, sys

projects = os.path.expanduser("~/.claude/projects")
MSG = re.compile(r'<array-agent-message from="([^"]+)" name="([^"]*)"[^>]*>\n(.*?)</array-agent-message>', re.S)

def text_of(c):
    if isinstance(c, str): return c
    return "\n".join(b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text")

def usage_of(lines):
    calls, order, wakes = {}, [], 0
    for line in lines:
        try: e = json.loads(line)
        except Exception: continue
        m = e.get("message") or {}
        if e.get("type") == "assistant" and m.get("usage") and not e.get("isSidechain"):
            mid = m.get("id") or e.get("uuid"); u = m["usage"]
            if mid not in calls: order.append(mid); calls[mid] = u
            elif (u.get("output_tokens") or 0) >= (calls[mid].get("output_tokens") or 0): calls[mid] = u
        elif e.get("type") == "user" and not e.get("isSidechain"):
            for r in MSG.finditer(text_of(m.get("content"))):
                if " finished: " in r.group(3).split("\n", 1)[0]: wakes += 1
    us = [calls[k] for k in order]
    g = lambda k: sum(u.get(k) or 0 for u in us)
    first = (us[0].get("input_tokens") or 0) + (us[0].get("cache_creation_input_tokens") or 0) + (us[0].get("cache_read_input_tokens") or 0) if us else 0
    return dict(inp=g("input_tokens"), cr=g("cache_read_input_tokens"), cw=g("cache_creation_input_tokens"), out=g("output_tokens"),
                turns=len(us), first=first, wakes=wakes)

def session_lines(sid):
    for p in glob.glob(os.path.join(projects, "*", sid + ".jsonl")): return open(p).read().splitlines()
    return []

rows = []
base = sys.argv[1]
for d in sorted(glob.glob(os.path.join(base, "*"))):
    ev = os.path.join(d, "evidence.json")
    if os.path.exists(ev):
        e = json.load(open(ev)); ss = [usage_of(session_lines(s["sessionId"])) for s in e.get("sessions", []) if s.get("sessionId")]
        if not ss: continue
        tot = {k: sum(s[k] for s in ss) for k in ("inp", "cr", "cw", "out", "turns", "wakes")}
        rows.append((os.path.basename(d), tot, [s["first"] for s in ss], e.get("wallSeconds")))
for f in sorted(glob.glob(os.path.join(base, "raw-*.jsonl"))):
    stream = open(f).read().splitlines()
    sid = next((json.loads(l).get("session_id") for l in stream if l.startswith("{") and '"session_id"' in l), None)
    # Same source as the Array runs: the session transcript, not the stream.
    s = usage_of(session_lines(sid) if sid else stream)
    res = [json.loads(l) for l in stream if '"type":"result"' in l]
    rows.append((os.path.basename(f)[:-6], s, [s["first"]], (res[-1].get("duration_ms", 0) / 1000) if res else None))
print("run | fresh in | cache read | cache write | out | turns | wakes | first-call ctx per session | wall s")
for name, t, firsts, wall in rows:
    print(f"{name} | {t['inp']} | {t['cr']} | {t['cw']} | {t['out']} | {t['turns']} | {t['wakes']} | {firsts} | {wall and round(wall,1)}")
