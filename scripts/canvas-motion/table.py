"""One row per motion run: on-screen camera rate, gaps, input lag, main-thread late
ticks, and the work counted during the motion phase.  table.py <run-dir>..."""
import json, sys, os
cols = ["transcriptLayouts", "transcriptApplies", "proseMeasures", "promotions", "demotions", "farReturns", "activityRebuilds", "sidebarReloads"]
print("%-26s %6s %5s %5s %6s %6s %5s %5s %6s  %s" % ("run", "cam/s", ">33", ">50", "lag50", "lag95", "t>17", "t>33", "worst", " ".join(c[:9] for c in cols)))
for d in sys.argv[1:]:
    try: r = json.load(open(os.path.join(d, "report.json")))
    except Exception as e: print(os.path.basename(d), "no report"); continue
    if not r.get("summaries"): print("%-26s FAILED %s" % (os.path.basename(d), r.get("error") or r.get("errors"))); continue
    s = r["summaries"][0]; ph = r["phases"][0]
    begin, tail = ph["startSeconds"], ph["settleEndSeconds"]
    ticks = [t for t in r.get("ticks", []) if begin <= t["seconds"] <= tail]
    gaps = [(b["seconds"] - a["seconds"]) * 1000 for a, b in zip(ticks, ticks[1:])]
    w0, w1 = ticks[0]["work"] if ticks else {}, ticks[-1]["work"] if ticks else {}
    lag = s["scheduledToMainMs"]
    print("%-26s %6.0f %5d %5d %6.1f %6.1f %5d %5d %6.1f  %s%s" % (os.path.basename(d)[:26], s["capturedCameraStatesPerSecond"],
        s["gapsOver33ms"], s["gapsOver50ms"], lag.get("p50", 0), lag.get("p95", 0),
        sum(g > 16.7 for g in gaps), sum(g > 33 for g in gaps), max(gaps or [0]),
        " ".join("%9d" % (w1.get(c, 0) - w0.get(c, 0)) for c in cols), "  ERR" if r.get("errors") else ""))
