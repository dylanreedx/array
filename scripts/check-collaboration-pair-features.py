#!/usr/bin/env python3
"""Second real two-process journey: the collaboration features after the core pair.

Reuses check-collaboration-pair.py's isolated relay, proxies and background
peers. Each stage drives mailbox ops in `--collaboration-peer-check`. A stage
whose op the peer does not implement yet is reported PENDING, never PASS, and
the run fails unless --allow-pending is given. The op contract per stage is in
.plans/105-collaboration/ACCEPTANCE.md ("Pair feature journey contract").
"""
from __future__ import annotations
import argparse, importlib.util, sys, tempfile, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("collaboration_pair", Path(__file__).with_name("check-collaboration-pair.py"))
pair = importlib.util.module_from_spec(spec); spec.loader.exec_module(pair)
wait_for = pair.wait_for


class Pending(Exception):
    pass


def op(peer, name, timeout=30, **fields):
    """Call a mailbox op; an op the peer does not know marks the stage pending."""
    try:
        return peer.call(name, timeout=timeout, **fields)
    except AssertionError as error:
        if "unknown peer command" in str(error): raise Pending(f"peer op '{name}' is not implemented")
        raise


def field(status, name):
    if name not in status: raise AssertionError(f"peer status lacks '{name}' although its op exists")
    return status[name]


def gate(status, name):
    """A stage that starts with an existing op gates on its new status field."""
    if name not in status: raise Pending(f"peer status has no '{name}' yet")
    return status[name]


def stage_liveness(h, a, b):
    """COL-06: execution-host liveness expires independently of discussion."""
    op(a, "hostSleep")
    wait_for(lambda: field(b.call("status"), "hostLiveness") == "unavailable", "B observes the sleeping host as unavailable", 90)
    before = b.call("status")["posts"]
    b.call("edit", text="FEATURES discussion while the host sleeps"); h.converge(a, b)
    assert b.call("status")["posts"] == before and b.call("status")["contexts"][-1]["text"].startswith("FEATURES discussion")
    op(a, "hostWake")
    wait_for(lambda: field(b.call("status"), "hostLiveness") == "live", "B observes the host live again", 60)
    return "a sleeping execution host reads as unavailable to the teammate while discussion stays readable and editable, then returns live"


def stage_artifacts(h, a, b):
    """COL-16/07: immutable artifact revisions; recipient checkout untouched."""
    files_b = b.call("status")["sourceFiles"]
    first = op(a, "publishArtifact", path="pair-artifact.md", text="first revision")
    h.converge(a, b)
    seen = wait_for(lambda: [x for x in field(b.call("status"), "artifacts") if x["digest"] == first["digest"]], "B receives the artifact", 20)
    op(a, "publishArtifact", path="pair-artifact.md", text="second revision")
    h.converge(a, b)
    revisions = field(b.call("status"), "artifacts")
    assert len({x["digest"] for x in revisions}) == 2, f"revisions collapsed: {revisions}"
    assert any(x["digest"] == seen[0]["digest"] and not x["latest"] for x in revisions), "the pinned first revision lost its identity"
    assert b.call("status")["sourceFiles"] == files_b, "artifact delivery wrote the recipient checkout"
    return "an artifact publishes immutable digested revisions; the earlier revision stays distinct from latest and B's checkout is byte-identical"


def stage_live_views(h, a, b):
    """COL-15: sequenced live agent snapshot/tail; late join; no executor."""
    gate(b.call("status"), "agentView")
    op(a, "localSend")
    view = wait_for(lambda: v if (v := field(b.call("status"), "agentView")) and v.get("sequence", 0) > 0 else None, "B receives the live agent view", 20)
    b.kill_abrupt(); b.start(); h.converge(a, b)
    rejoined = wait_for(lambda: v if (v := field(b.call("status"), "agentView")) and v.get("sequence", 0) >= view["sequence"] else None, "late join resnapshots", 20)
    assert rejoined["generation"] == view["generation"] and b.call("status")["runnerConstructions"] == 0
    return "B sees the source agent's sequenced live view, a late rejoin resnapshots the same generation, and no recipient executor exists"


def stage_freshness(h, a, b):
    """COL-14: per-agent delivered revision and changed-since-sent."""
    calls = a.call("status")["runnerCalls"]
    op(a, "localSendWithContext")
    sent = wait_for(lambda: field(a.call("status"), "deliveredRevision"), "A records the delivered revision", 15)
    b.call("edit", text="FEATURES newer agreement after send"); h.converge(a, b)
    assert field(b.call("status"), "changedSinceSent") is True and a.call("status")["deliveredRevision"] == sent
    a.call("hostPoll"); assert a.call("status")["runnerCalls"] == calls + 1, "editing the agreement dispatched again"
    return "the agent's delivered agreement revision is recorded, a later edit marks it changed-since-sent for both people, and nothing is redispatched"


def stage_endorsements(h, a, b):
    """COL-12: revision-bound endorsement and concurrent-edit conflict."""
    latest = b.call("status")["contexts"][-1]["id"]
    op(b, "endorse")
    h.converge(a, b)
    assert any(e["revision"] == latest and e["person"] == b.ready["person"] for e in field(a.call("status"), "endorsements"))
    h.proxies[1].pause()
    a.call("edit", text="FEATURES concurrent A"); b.send("edit", text="FEATURES concurrent B")
    h.proxies[1].resume()
    status = wait_for(lambda: s if (s := b.call("status")).get("agreementConflict") else None, "B's concurrent edit surfaces a conflict", 30)
    assert "FEATURES concurrent B" in field(status, "agreementDraft")
    return "an endorsement names the exact agreement revision, and a concurrent edit surfaces a conflict that keeps the losing draft"


def stage_follow(h, a, b):
    """COL-18: voluntary follow; local navigation exits without a loop."""
    op(b, "follow", device=a.ready["device"])
    a.call("camera", x=900.0, y=-400.0, zoom=1.0)
    wait_for(lambda: field(b.call("status"), "following") == a.ready["device"] and abs(b.call("status")["privateCamera"]["x"] - 900.0) < 1, "B follows A's camera", 15)
    b.call("camera", x=0.0, y=0.0, zoom=1.0)
    assert field(b.call("status"), "following") is None
    a.call("camera", x=-900.0, y=400.0, zoom=1.0); time.sleep(0.5)
    assert b.call("status")["privateCamera"]["x"] == 0.0, "B kept following after local navigation"
    return "B voluntarily follows A's camera and B's own navigation ends following without feeding back"


def stage_compaction(h, a, b):
    """COL-19: post-compaction cold rejoin loses nothing and resurrects nothing."""
    op(a, "compact")  # gate: probe before the slow burst
    op(a, "burst", count=520, timeout=180)
    before, _ = h.converge(a, b, timeout=70)
    op(a, "compact")
    b.kill_abrupt(); b.start(); after, _ = h.converge(a, b, timeout=70)
    assert after["documentHash"] == before["documentHash"] and after["posts"] == before["posts"]
    return "after server compaction a relaunched teammate rejoins over 500 events with an identical document"


def stage_harnesses(h, a, b):
    """COL-13: the handoff dispatch through each managed harness seam."""
    if "sourceHarness" not in a.ready: raise Pending("peer does not report sourceHarness; per-harness source runners not wired")
    results = []
    for harness in ("claude", "codex", "pi"):
        a.close(); a.config["sourceHarness"] = harness; a.process = None; a.ready = a.start(); h.converge(a, b)
        assert a.ready["sourceHarness"] == harness
        calls = a.call("status")["runnerCalls"]
        a.call("handoffOffer", person=b.ready["person"]); b.call("handoffAccept")
        b.call("handoffSend", text=f"FEATURES handoff through {harness}")
        wait_for(lambda: a.call("hostPoll") is not None and a.call("status")["runnerCalls"] == calls + 1, f"{harness} receives one handoff", 15)
        receipt = wait_for(lambda: v if (v := b.call("handoffRefresh")).get("handoffPhase") == "accepted" else None, f"{harness} receipt", 15)
        results.append((harness, receipt["handoffCommand"]))
        op(a, "handoffReclaim")
    assert len({command for _, command in results}) == 3
    return "a teammate handoff dispatches exactly once through the Claude, Codex and Pi source seams"


STAGES = [("liveness", stage_liveness), ("artifacts", stage_artifacts), ("liveViews", stage_live_views),
          ("freshness", stage_freshness), ("endorsements", stage_endorsements), ("follow", stage_follow),
          ("compaction", stage_compaction), ("harnesses", stage_harnesses)]


class FeatureHarness(pair.Harness):
    def run(self, selected):
        self.start_relay()
        proxy_a, proxy_b = pair.Proxy(self.port), pair.Proxy(self.port); self.proxies = [proxy_a, proxy_b]
        a, b = pair.Peer(self, "A", self.enroll("A"), proxy_a), pair.Peer(self, "B", self.enroll("B"), proxy_b)
        a.ready, b.ready = a.start(), b.start()
        a.call("create"); b.call("join", invitation=a.call("invite", person=b.ready["person"])["invitation"])
        self.converge(a, b); a.call("shareZone"); self.converge(a, b)
        baseline_b = b.call("status")
        self.pass_step("two isolated background peers share one zone through the local relay")
        pending, results = [], {}
        for name, stage in STAGES:
            if selected and name not in selected: continue
            try:
                self.pass_step(f"{name}: " + stage(self, a, b)); results[name] = "passed"
            except Pending as reason:
                print(f"PENDING pair-features: {name}: {reason}", flush=True); pending.append(name); results[name] = f"pending: {reason}"
        end_b = b.call("status")
        assert end_b["sourceFiles"] == baseline_b["sourceFiles"] and end_b["runnerConstructions"] == 0
        self.pass_step("no feature stage wrote B's checkout or created a recipient executor")
        return {"passed": not pending, "stages": results, "pending": pending, "steps": self.steps,
                "noFocusViolation": self.focus_violation is None, "focusObservations": self.focus_samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--array", default=".build/debug/Array")
    parser.add_argument("--relay", default=".build/debug/continuum-relay")
    parser.add_argument("--artifacts", default="qa-runs/collaboration-pair-features")
    parser.add_argument("--stage", action="append", choices=[name for name, _ in STAGES], help="run only these stages")
    parser.add_argument("--allow-pending", action="store_true", help="exit 0 when unimplemented stages are pending")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="array-pair-features-", dir="/tmp") as directory:
        harness = FeatureHarness(args, directory)
        try:
            report = harness.run(set(args.stage or []))
            pair.atomic_json(harness.artifacts / "report.json", report)
            print("Collaboration pair features:", sum(v == "passed" for v in report["stages"].values()), "passed,",
                  len(report["pending"]), "pending", report["pending"], flush=True)
            return 0 if report["passed"] or args.allow_pending else 2
        except Exception as error:
            pair.atomic_json(harness.artifacts / "report.json", {"passed": False, "steps": harness.steps, "error": str(error), "type": type(error).__name__})
            print("FAIL pair-features:", type(error).__name__, str(error), flush=True)
            return 1
        finally: harness.close()


if __name__ == "__main__": sys.exit(main())
