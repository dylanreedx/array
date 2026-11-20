#!/usr/bin/env python3
"""Helper usage benchmark: what a managed helper costs, from telemetry Array already has.

Per-turn usage lives in the provider transcript, not in Array's record: each
agent record (<app-support>/agents/<id>.json) names providerSessionId, and the
Claude CLI writes <projects>/<cwd>/<providerSessionId>.jsonl whose assistant
entries carry message.usage. This reads both, read-only.

  helper-usage-bench.py --agents DIR [--projects DIR] [--label NAME]
        [--created-after ISO] [--created-before ISO] [--model-contains STR] [--json]

Reports, over Claude helpers (records with a parent) that wrote a session:
  median first-call input   input + cache_creation + cache_read of call 1
  per helper total input    sum over calls of the same, and total output
  lead wakes per task       "<helper> finished:" relays seen by the lead / helpers it ran
"""
import argparse, glob, json, os, re, statistics, datetime, sys

REF = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc).timestamp()
MSG = re.compile(r'<array-agent-message from="([^"]+)" name="([^"]*)"[^>]*>\n(.*?)</array-agent-message>', re.S)
FIN = re.compile(r'^.*? finished: ', re.M)

def iso(s):
    return datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp() - REF if s else None

def text_of(c):
    if isinstance(c, str): return c
    return "\n".join(b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text")

def read_session(path):
    calls, order, relays = {}, [], []
    for line in open(path):
        try: e = json.loads(line)
        except Exception: continue
        m = e.get("message") or {}
        if e.get("type") == "assistant" and m.get("usage") and not e.get("isSidechain"):
            mid = m.get("id") or e.get("uuid"); u = m["usage"]
            if mid not in calls: order.append(mid); calls[mid] = u
            elif (u.get("output_tokens") or 0) >= (calls[mid].get("output_tokens") or 0): calls[mid] = u
        elif e.get("type") == "user" and not e.get("isSidechain"):
            for r in MSG.finditer(text_of(m.get("content"))):
                if FIN.match(r.group(3).split("\n", 1)[0]): relays.append(r.group(1).lower())
    us = [calls[k] for k in order]
    ctx = [(u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) for u in us]
    return dict(calls=len(us), first=ctx[0] if ctx else None, total_in=sum(ctx),
                total_out=sum(u.get("output_tokens") or 0 for u in us), finished_relays=relays)

def med(xs): return int(statistics.median(xs)) if xs else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agents", required=True)
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--label", default="run")
    ap.add_argument("--created-after"); ap.add_argument("--created-before")
    ap.add_argument("--model-contains")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    lo, hi = iso(a.created_after), iso(a.created_before)
    records = {}
    for f in glob.glob(os.path.join(a.agents, "*.json")):
        try: d = json.load(open(f))
        except Exception: continue
        records[d["id"].lower()] = d
    sessions = {}
    for p in glob.glob(os.path.join(a.projects, "*", "*.jsonl")):
        sessions.setdefault(os.path.basename(p)[:-6], p)
    helpers, leads = [], {}
    for d in records.values():
        t = float(d.get("createdAtReferenceInterval", 0))
        if (lo and t < lo) or (hi and t >= hi): continue
        if d.get("harness") != "Claude Code" or not d.get("parentAgentID"): continue
        if a.model_contains and a.model_contains not in (d.get("model") or ""): continue
        p = sessions.get(d.get("providerSessionId") or "")
        if not p: continue
        s = read_session(p)
        if s["first"] is None: continue
        s.update(id=d["id"], model=d.get("model"), thinking=d.get("thinking"), parent=d["parentAgentID"].lower())
        helpers.append(s)
        leads.setdefault(s["parent"], set()).add(d["id"].lower())
    wakes = tasks = 0
    for lead, kids in leads.items():
        ld = records.get(lead); p = ld and sessions.get(ld.get("providerSessionId") or "")
        if not p: continue
        r = read_session(p)["finished_relays"]
        wakes += sum(1 for x in r if x in kids); tasks += len(kids)
    out = dict(label=a.label, helpers=len(helpers),
               median_first_call_input=med([h["first"] for h in helpers]),
               median_total_input=med([h["total_in"] for h in helpers]),
               median_total_output=med([h["total_out"] for h in helpers]),
               median_calls=med([h["calls"] for h in helpers]),
               lead_finished_wakes=wakes, helpers_with_visible_lead=tasks,
               wakes_per_task=round(wakes / tasks, 2) if tasks else None,
               models={m: sum(1 for h in helpers if h["model"] == m) for m in {h["model"] for h in helpers}},
               efforts={m: sum(1 for h in helpers if h["thinking"] == m) for m in {h["thinking"] for h in helpers}})
    if a.json: print(json.dumps(out, indent=1))
    else:
        for k, v in out.items(): print(f"{k:28} {v}")
main()
