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


def wait_value(read, accept, label, timeout=30):
    """wait_for that names the last value seen when the deadline passes."""
    last = [None]
    def probe():
        last[0] = read()
        return last[0] if accept(last[0]) else None
    try: return wait_for(probe, label, timeout)
    except AssertionError: raise AssertionError(f"deadline: {label}; last seen {str(last[0])[:600]}") from None


def gate(status, name):
    """A stage that starts with an existing op gates on its new status field."""
    if name not in status: raise Pending(f"peer status has no '{name}' yet")
    return status[name]


def stage_liveness(h, a, b):
    """COL-06: B reads A's execution host online, offline the moment A's host
    stops (its explicit end), discussion still writable, then online again."""
    def agent(): return next(x for x in field(b.call("status"), "agents") if x["owner"] == a.ready["person"])
    wait_for(lambda: agent()["hostState"] == "online", "B reads A's host online", 30)
    op(a, "hostStop")
    gone = wait_for(lambda: x if (x := agent())["hostState"] == "offline" else None, "B reads A's host offline after it stops", 20)
    assert gone["hostLine"].startswith("Host offline"), gone["hostLine"]
    b.call("edit", text="FEATURES discussion while the host is offline"); h.converge(a, b)
    assert b.call("status")["contexts"][-1]["text"] == "FEATURES discussion while the host is offline"
    op(a, "hostStart")
    back = wait_for(lambda: x if (x := agent())["hostState"] == "online" else None, "B reads A's host online again", 30)
    assert back["hostLine"] == "Host online."
    return "B reads A's host online, offline the moment it stops (agreement still editable), and online again when it restarts"


def stage_artifacts(h, a, b):
    """COL-16: A shares a file tile through the review; the head reaches B on
    the update stream and B's panel shows A's exact bytes and digest."""
    path = a.root / "project" / "pair-artifact.md"
    expected = pair.hashlib.sha256(path.read_bytes()).hexdigest()
    files_b = b.call("status")["sourceFiles"]
    op(a, "shareFile"); h.converge(a, b)
    try: head = wait_for(lambda: (x := field(b.call("status"), "artifactHeads")) and x[0], "the artifact head reaches B without B asking", 20)
    except AssertionError:
        mine = a.call("status")
        raise AssertionError(f"the artifact head never reached B; A heads {mine.get('artifactHeads')}, A review said {mine.get('lastShareMessage')!r}") from None
    b.call("select", kind="artifact", object=head["object"]); a.call("select", kind="artifact", object=head["object"])
    seen = wait_value(lambda: b.call("status")["artifactPanel"], lambda x: x["bytes"].get("pair-artifact.md") == expected, "B's panel holds A's exact file bytes", 20)
    own = wait_for(lambda: x if (x := a.call("status")["artifactPanel"])["latestDigest"] else None, "A's own panel names the published digest", 20)
    assert seen["latestDigest"] == own["latestDigest"], "B was shown a different revision"
    assert b.call("status")["sourceFiles"] == files_b, "the artifact wrote B's checkout"
    return "A's shared file arrives at B on the live update stream; B's panel shows A's exact bytes and the same content digest, and B's checkout is untouched"


def stage_live_views(h, a, b):
    """COL-15: B's live view tails A's running agent, read-only, and turns to
    history when A's host goes offline."""
    gate(b.call("status"), "liveView")
    calls = a.call("status")["runnerCalls"]
    b.call("select", kind="agentObservation")
    op(a, "localSend")
    try: wait_value(lambda: b.call("status")["liveView"], lambda x: "QA turn accepted and completed." in x["transcript"], "B's live view tails A's agent", 30)
    except AssertionError as error:
        mine = a.call("status")
        raise AssertionError(f"{error}; A projection {mine.get('projection')}, A bindings {mine.get('sourceBindingAgents')}") from None
    after = b.call("status")
    assert after["runnerConstructions"] == 0 and after["runnerCalls"] == 0 and a.call("status")["runnerCalls"] == calls + 1, "the live view executed something"
    op(a, "hostStop")
    wait_for(lambda: "host offline" in b.call("status")["liveView"]["status"], "B's live view turns to history when the host stops", 20)
    op(a, "hostStart")
    return "B's live view tails A's running agent with no executor of its own, and turns to history when A's host stops"


def stage_endorsements(h, a, b):
    """COL-12: revision-bound endorsement, then a concurrent edit that keeps
    the losing author's draft as a conflict instead of overwriting."""
    # At least two revisions, so endorsing the wrong one is distinguishable.
    a.call("edit", text="FEATURES revision before the endorsement"); h.converge(a, b)
    latest = field(b.call("status"), "currentAgreement")
    op(b, "endorse")
    h.converge(a, b)
    assert any(e["revision"] == latest and e["person"] == b.ready["person"] for e in field(a.call("status"), "endorsements")), "endorsement lost its revision"
    h.proxies[1].pause()  # B keeps its stale view of the agreement
    a.call("edit", text="FEATURES concurrent A")
    wait_for(lambda: h.proxies[1].blocked > 0, "B's updates are held")
    b.call("edit", text="FEATURES concurrent B")
    h.proxies[1].resume()
    status = wait_for(lambda: s if (s := b.call("status")).get("agreementConflict") else None, "B's concurrent edit surfaces a conflict", 30)
    assert field(status, "agreementDraft") == "FEATURES concurrent B", "the losing draft was not kept"
    left, right = h.converge(a, b)
    assert left["contexts"][-1]["text"] == right["contexts"][-1]["text"] == "FEATURES concurrent A", "the stale edit overwrote the newer revision"
    return "an endorsement names the exact agreement revision; a concurrent stale edit keeps B's draft as a conflict and never overwrites A's revision"


def stage_follow(h, a, b):
    """COL-18: voluntary follow; local navigation exits without a loop.
    Compares live view centres: following never writes B's private camera
    until it ends, so privateCamera is the wrong witness while following."""
    gate(b.call("status"), "viewCentre")
    def centre(peer): return peer.call("status")["viewCentre"]
    def near(left, right): return abs(left["x"] - right["x"]) < 2 and abs(left["y"] - right["y"]) < 2
    a.call("camera", x=900.0, y=-400.0, zoom=1.0)
    wait_for(lambda: op(b, "follow", device=a.ready["device"]).get("followed"), "B starts following A's published view", 20)
    wait_for(lambda: near(centre(b), centre(a)), "B's view centres on A's", 15)
    assert b.call("status")["following"] == a.ready["device"]
    a.call("camera", x=-300.0, y=200.0, zoom=1.0)
    wait_for(lambda: near(centre(b), centre(a)), "B keeps following A's next move", 15)
    op(b, "fitView")
    assert b.call("status")["following"] is None, "local navigation did not end following"
    parked = centre(b)
    a.call("camera", x=1200.0, y=900.0, zoom=1.0); time.sleep(2.5)
    assert near(centre(b), parked) and not near(centre(b), centre(a)), "B kept following after local navigation"
    assert a.call("status")["following"] is None, "A was made to follow back"
    return "B voluntarily follows A's view through two moves; B's own navigation ends following, B stays put afterwards and A never follows back"


def stage_compaction(h, a, b):
    """COL-19: the relay compacts past a live teammate's cursor while B's
    update requests are held; released, B must resnapshot, not stall on the
    retired cursor. A newcomer joining after compaction gets all history.
    The relay runs with FeatureHarness's retention (tail 16, batch 32, age 0)."""
    before = b.call("status")["revision"]
    h.proxies[1].pause()
    a.call("edit", text="FEATURES compaction barrier")
    wait_for(lambda: h.proxies[1].blocked > 0, "B's update requests are held")
    op(a, "burst", count=120, timeout=180)
    backup = h.root / "compaction-probe.sqlite"
    run = pair.subprocess.run([str(h.relay), "--collaboration-backup", str(backup)], cwd=h.checkout, env=h.env, capture_output=True, text=True, timeout=60)
    report = pair.json.loads(run.stdout.splitlines()[0]) if run.returncode == 0 else {}
    assert report.get("compactedAreas", 0) >= 1, f"relay did not compact: {run.stdout} {run.stderr}"
    assert a.call("status")["revision"] - 16 - 32 > before, "horizon cannot have passed B's cursor"
    h.proxies[1].resume()
    left, right = h.converge(a, b, timeout=70)
    assert left["documentHash"] == right["documentHash"] and right["posts"] == left["posts"]
    proxy = pair.Proxy(h.port); h.proxies.append(proxy)
    late = pair.Peer(h, "C", h.enroll("C"), proxy); late.ready = late.start()
    try:
        late.call("join", invitation=a.call("invite", person=late.ready["person"])["invitation"])
        joined, mine = h.converge(late, a, timeout=70)
        assert joined["posts"] == mine["posts"] and set(joined["postIDs"]) == set(mine["postIDs"]), "a late joiner lost compacted history"
    finally: late.close()
    return "B, held behind the relay's compaction horizon while live, resnapshots to an identical document; a teammate joining after compaction receives every post"


def stage_harnesses(h, a, b):
    """COL-13: one extra peer per harness runs that CLI's production runner on
    a recording fake; B's handoff reaches the fake's stdin exactly once."""
    results = []
    for name in ("claude", "codex", "pi"):
        proxy = pair.Proxy(h.port); h.proxies.append(proxy)
        peer = pair.Peer(h, "H" + name, h.enroll("H" + name), proxy)
        peer.config["sourceHarness"] = name
        peer.ready = peer.start()
        try:
            peer.call("join", invitation=a.call("invite", person=peer.ready["person"])["invitation"]); h.converge(a, peer)
            peer.call("shareZone"); h.converge(a, peer); h.converge(a, b)
            # The share lands before the peer's controller lists its source
            # binding; after a long run that gap is visible, so wait for it.
            objects = wait_value(lambda: peer.call("status")["sourceObjects"], lambda x: len(x) == 1, f"{name} lists its shared agent", 30)
            marker = f"FEATURES handoff through {name}"
            # The new host registers its agent's control on its own poll; an
            # offer before that has nothing to offer.
            def control(p, op_name="handoffRefresh"):
                p.call("hostPoll") if p is peer else None
                return p.call(op_name, object=objects[0]).get("handoffControl") or {}
            wait_value(lambda: control(peer), lambda x: x.get("controller") == peer.ready["person"], f"{name} host registers its agent's control", 30)
            peer.call("handoffOffer", person=b.ready["person"], object=objects[0])
            wait_value(lambda: control(b), lambda x: x.get("offered"), f"B sees {name}'s offer", 20)
            b.call("handoffAccept", object=objects[0])
            wait_value(lambda: control(b), lambda x: x.get("controller") == b.ready["person"], f"B holds {name}'s agent", 20)
            b.call("handoffSend", text=marker, object=objects[0])
            frames = peer.root / "support" / "fake-cli" / "stdin.jsonl"
            def received(): return [line for line in (frames.read_text().splitlines() if frames.exists() else []) if marker in line]
            wait_for(lambda: peer.call("hostPoll") is not None and received(), f"{name} CLI receives the handed-off prompt", 30)
            receipt = wait_for(lambda: x if (x := b.call("handoffRefresh", object=objects[0])).get("handoffPhase") == "accepted" else None, f"{name} receipt accepted", 20)
            peer.call("hostPoll"); time.sleep(1); peer.call("hostPoll")
            assert len(received()) == 1, f"{name} CLI received the prompt {len(received())} times"
            results.append((name, receipt["handoffCommand"]))
        finally: peer.close()
    assert len({command for _, command in results}) == 3
    return "a teammate's handoff reaches the Claude, Codex and Pi production runners' CLIs exactly once each"


STAGES = [("liveness", stage_liveness), ("artifacts", stage_artifacts), ("liveViews", stage_live_views),
          ("endorsements", stage_endorsements), ("follow", stage_follow),
          ("compaction", stage_compaction), ("harnesses", stage_harnesses)]


class FeatureHarness(pair.Harness):
    def __init__(self, args, root):
        super().__init__(args, root)
        # Small retention so the compaction stage can move the horizon.
        self.env.update(RELAY_COLLABORATION_OPERATION_TAIL="16", RELAY_COLLABORATION_OPERATION_AGE_SECONDS="0",
                        RELAY_COLLABORATION_COMPACTION_BATCH="32")

    def run(self, selected):
        self.start_relay()
        proxy_a, proxy_b = pair.Proxy(self.port), pair.Proxy(self.port); self.proxies = [proxy_a, proxy_b]
        a, b = pair.Peer(self, "A", self.enroll("A"), proxy_a), pair.Peer(self, "B", self.enroll("B"), proxy_b)
        # A's checkout is a disposable git repository holding the file it will
        # share; the artifact producer captures only from a repository.
        a.config["artifactFile"] = "pair-artifact.md"
        project = a.root / "project"
        (project / "pair-artifact.md").write_text("# Pair artifact\nShared from A's checkout.\n")
        git = ["git", "-C", str(project), "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "-c", "commit.gpgsign=false"]
        for command in (["init", "-q"], ["add", "pair-artifact.md"], ["commit", "-q", "-m", "qa fixture"]):
            pair.subprocess.run(git + command, check=True, capture_output=True, timeout=20)
        a.ready, b.ready = a.start(), b.start()
        a.call("create"); b.call("join", invitation=a.call("invite", person=b.ready["person"])["invitation"])
        self.converge(a, b); a.call("shareZone"); self.converge(a, b)
        baseline_b = b.call("status")
        self.pass_step("two isolated background peers share one zone through the local relay")
        pending, failed, results = [], [], {}
        for name, stage in STAGES:
            if selected and name not in selected: continue
            try:
                self.pass_step(f"{name}: " + stage(self, a, b)); results[name] = "passed"
            except Pending as reason:
                print(f"PENDING pair-features: {name}: {reason}", flush=True); pending.append(name); results[name] = f"pending: {reason}"
            except AssertionError as error:
                # Keep going so one run shows every stage's own outcome.
                print(f"FAIL pair-features: {name}: {error}", flush=True); failed.append(name); results[name] = f"failed: {error}"
                # A failed stage may have left A's host stopped; restore it so
                # the next stage fails, if at all, for its own reason.
                with pair.contextlib.suppress(Exception): a.call("hostStart")
        end_b = b.call("status")
        assert end_b["sourceFiles"] == baseline_b["sourceFiles"] and end_b["runnerConstructions"] == 0
        self.pass_step("no feature stage wrote B's checkout or created a recipient executor")
        return {"passed": not pending and not failed, "stages": results, "pending": pending, "failed": failed, "steps": self.steps,
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
                  len(report["pending"]), "pending", report["pending"], len(report["failed"]), "failed", report["failed"], flush=True)
            if report["failed"]: return 1
            return 0 if report["passed"] or args.allow_pending else 2
        except Exception as error:
            pair.atomic_json(harness.artifacts / "report.json", {"passed": False, "steps": harness.steps, "error": str(error), "type": type(error).__name__})
            print("FAIL pair-features:", type(error).__name__, str(error), flush=True)
            return 1
        finally: harness.close()


if __name__ == "__main__": sys.exit(main())
