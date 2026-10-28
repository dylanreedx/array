"""Summarise one --canvas-motion-probe report: screen-side camera changes, then
every late main-thread display-link tick with the work counted between ticks."""
import json, sys

r = json.load(open(sys.argv[1]))
if not r.get("summaries"):
    print("FAILED:", r.get("error") or r.get("errors")); sys.exit(0)
final = r["final"]
print("config: residency=%s farParking=%s  tiles %s visible %s" % (
    final.get("agentSurfaceResidency"), final.get("farParking"),
    final.get("installedTiles"), final.get("visibleTiles")))
if r.get("errors"): print("errors:", r["errors"])
ph = r["phases"][0]; begin, end, tail = ph["startSeconds"], ph["endSeconds"], ph["settleEndSeconds"]
s = r["summaries"][0]
iv = s["cameraChangeIntervalsMs"]
print("screen: %d camera states in %.0fs (%.0f/s), interval p50 %.1f p95 %.1f max %.1f ms; gaps >16.7: %d >33: %d >50: %d; first change %.0f ms; final camera %.0f ms after input" % (
    s["distinctCapturedCameraStates"], end - begin, s["capturedCameraStatesPerSecond"],
    iv.get("p50", 0), iv.get("p95", 0), iv.get("max", 0), s["gapsOver16_7ms"], s["gapsOver33ms"],
    s["gapsOver50ms"], s["firstCapturedChangeMs"] or -1, s["finalCameraAfterInputEndMs"] or -1))
c0, c1 = ph["before"].get("cost"), ph["afterInput"].get("cost")
if c0 and c1:
    commits = max(1, s["cameraCommitCount"])
    d = {k: c1[k] - c0[k] for k in c0}
    print("cost per camera commit (%d commits): main thread %.2f ms CPU, process %.1f M instructions, %.1f M cycles" % (
        commits, d["mainThreadCPUSeconds"] * 1000 / commits, d["processInstructions"] / 1e6 / commits, d["processCycles"] / 1e6 / commits))
lag = s["scheduledToMainMs"]
print("input: scheduled->main p50 %.1f p95 %.1f max %.1f ms" % (lag.get("p50", 0), lag.get("p95", 0), lag.get("max", 0)))

ticks = [t for t in r.get("ticks", []) if begin - 0.2 <= t["seconds"] <= tail]
late = []
for a, b in zip(ticks, ticks[1:]):
    gap = (b["seconds"] - a["seconds"]) * 1000
    if gap > 12:
        work = {k: b["work"][k] - a["work"].get(k, 0) for k in b["work"] if b["work"][k] != a["work"].get(k, 0)}
        late.append((a["seconds"] - begin, gap, b["phase"], work))
total = len(ticks) - 1
print("main thread: %d ticks, %d late (>12 ms), >16.7: %d, >33: %d, worst %.1f ms" % (
    total, len(late), sum(1 for l in late if l[1] > 16.7), sum(1 for l in late if l[1] > 33),
    max([l[1] for l in late], default=0)))
for t, gap, phase, work in late:
    print("  t=%6.0f ms %6.1f ms  %-12s %s" % (t * 1000, gap, phase,
          ", ".join("%s %+d" % kv for kv in sorted(work.items())) or "-"))
w0, w1 = r["baseline"]["work"], final["work"]
print("work over run:", ", ".join("%s %+d" % (k, w1[k] - w0.get(k, 0)) for k in sorted(w1) if w1[k] != w0.get(k, 0)))
print("gesture log:", final.get("lastGestureReport"))
for f in r.get("fidelity", []):
    print("fidelity: zoom %.2f %s  mean diff %.2f  changed %.3f%%  sharpness %.3f%s" % (
        f.get("zoom", 0), "INVALID" if f.get("invalid") else ("PASS" if f.get("pass") else "FAIL"), f.get("meanDifference", -1),
        100 * f.get("changedFraction", -1), f.get("sharpnessRatio", -1),
        ("  " + f["error"]) if "error" in f else ""))
