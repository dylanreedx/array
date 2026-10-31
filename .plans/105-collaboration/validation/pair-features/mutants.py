"""apply|revert <group>: one product mutation per pair-features stage."""
import sys, json, pathlib
R = pathlib.Path("/Users/dylan/Documents/personal/Array/.worktrees/mp-w10-acceptance/Sources")
M = {
 "liveness": ("ContinuumRevived/App/Collaboration/SharedAreaHostSession.swift",
   "collector?.stop(); handoff.stopHosting(); heartbeat?.end()", "collector?.stop(); handoff.stopHosting() /* MUTANT */"),
 "artifacts": ("ContinuumRevivedCore/Collaboration/SharedAreaController.swift",
   "artifactHeads = replica.artifactHeads", "artifactHeads = [] /* MUTANT */"),
 "liveViews": ("ContinuumRevived/App/Collaboration/SharedAreaAgentProjectionHost.swift",
   "do { try await controller.publishAgentProjection(object: object, batch: batch) }",
   "do { if object.rawValue != UUID() { return } /* MUTANT */; try await controller.publishAgentProjection(object: object, batch: batch) }"),
 "freshness": ("ContinuumRevivedCore/Collaboration/SharedAgentHandoffController.swift",
   "if let delivered { try freshness.record(delivered) }", "if let delivered { _ = delivered /* MUTANT */ }"),
 "freshness2": ("ContinuumRevivedCore/Collaboration/SharedAgentHandoffController.swift",
   "                try freshness.record(fresh)\n", "                _ = fresh /* MUTANT */\n"),
 "freshness3": ("ContinuumRevivedCore/Collaboration/SharedAgentHandoffController.swift",
   "{ try freshness.record(settled) }", "{ _ = settled /* MUTANT */ }"),
 "endorsements": ("ContinuumRevivedCore/Collaboration/SharedAreaController.swift",
   "edits: [.endorse(.init(revision: revision, person: credentialScope.identity.person))]",
   "edits: [.endorse(.init(revision: document.contexts.first(where: { $0.id != revision })?.id ?? revision /* MUTANT */, person: credentialScope.identity.person))]"),
 "follow": ("ContinuumRevived/App/Collaboration/SharedAreaPresencePublisher.swift",
   "if followedDevice != nil { stopFollowing(notice: nil) } else { overlay.followBanner = nil }",
   "if followedDevice == UUID() /* MUTANT */ { stopFollowing(notice: nil) } else { overlay.followBanner = nil }"),
 "compaction": ("ContinuumRevivedCollaborationClient/CollaborationSession.swift",
   "case .invalidSequence, .server(status: 409, code: _):\n                replica = nil; through = nil",
   "case .invalidSequence, .server(status: 409, code: _):\n                break /* MUTANT */"),
 "harnesses": ("ContinuumRevivedCore/Collaboration/SharedAgentHandoffTransport.swift",
   "let accepted = await execute(binding, command)", "_ = await execute(binding, command); let accepted = await execute(binding, command) /* MUTANT */"),
}
G = {"m3": ["endorsements", "compaction"], "m1": ["liveness", "artifacts", "liveViews", "freshness", "freshness2", "freshness3", "endorsements", "follow", "compaction"], "m2": ["harnesses"]}
mode, group = sys.argv[1], sys.argv[2]
for key in G[group]:
    path, old, new = M[key]; f = R / path; s = f.read_text()
    a, b = (old, new) if mode == "apply" else (new, old)
    assert s.count(a) == 1, (mode, key, s.count(a)); f.write_text(s.replace(a, b)); print(mode, key)
