import ContinuumRevivedCore
import Foundation

// CX-01 Phase 2a (`.plans/59` §11, §14.1): the agent.find / agent.inspect
// contracts round-trip, the pure ranker orders and explains per §11 and flags
// ties as ambiguous, the excerpt bounder keeps the newest items under a hard
// byte cap, and the agent-scope grant evaluator only admits a target the grant
// names. Pure — no processes, no filesystem.
//
// RED without the change: `WorkspaceAPIOp(rawValue: "agent.find")` is nil, the
// preset does not name the caller in `inspectableAgentIds`, and none of the
// Phase 2a types exist.
func runWorkspaceAPIAgentsContractChecks() {
    checkAgentOpsAndPreset()
    checkAgentFindRequestDecoding()
    checkRankerOrderAndReasons()
    checkRankerAmbiguityAndFilters()
    checkInspectRoundTripAndExcerptBound()
    checkAgentInspectGrantEvaluator()
    print("WorkspaceAPIAgentsContractChecks passed")
}

private let agentsEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private let agentsDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

private let agentsNow = Date(timeIntervalSince1970: 1_900_000_000)
private let ckOwn = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb")
private let ckOther = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pa")

private func agentsID(_ hex: String) -> AgentID {
    AgentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000A\(hex)")!)
}

private func identity(
    _ id: AgentID, name: String, role: String? = nil, checkout: CheckoutHandle = ckOwn, zone: UUID? = nil,
    status: AgentObservedStatus = .ready, observedAt: Date = agentsNow
) -> AgentProjectionIdentity {
    AgentProjectionIdentity(
        agentId: id, displayName: name, role: role, harness: "Pi", checkoutHandle: checkout,
        projectId: nil, zoneId: zone, tileId: zone.map { _ in UUID() }, parentAgentId: nil,
        status: status, observedAt: observedAt)
}

private func checkAgentOpsAndPreset() {
    expect(WorkspaceAPIOp(rawValue: "agent.find") == .agentFind && WorkspaceAPIOp(rawValue: "agent.inspect") == .agentInspect,
           "the two Phase 2a ops must decode from their wire names")
    expect(Array(WorkspaceAPIOp.allCases.suffix(2)) == [.agentFind, .agentInspect], "new ops are APPENDED to the enum")
    let me = agentsID("0001")
    let preset = WorkspaceToolGrant.phase1Preset(agentId: me, checkout: ckOwn, generation: 3)
    expect(preset.operations == [.workspaceContext, .artifactOpen, .agentFind, .agentInspect],
           "the preset lists its ops explicitly (find + self-inspect included), got \(preset.operations)")
    expect(preset.inspectableAgentIds == [me], "the preset lets an agent inspect only ITSELF, got \(preset.inspectableAgentIds)")
    let data = try! agentsEncoder.encode(preset)
    let back = try! agentsDecoder.decode(WorkspaceToolGrant.self, from: data)
    expect(back == preset, "a grant with agent scope round-trips")
    expect(WorkspaceToolGrantEvaluator.discoverableCheckouts(agentId: me, grants: [preset], currentGeneration: 3) == [ckOwn],
           "find is scoped to the preset's own checkout")
    expect(WorkspaceToolGrantEvaluator.discoverableCheckouts(agentId: me, grants: [preset], currentGeneration: 4).isEmpty,
           "a grant from an older generation discovers nothing")
}

private func checkAgentFindRequestDecoding() {
    let json = #"{"query":"parser","limit":99,"authorized":true,"zoneId":"00000000-0000-0000-0000-0000000CA107"}"#
    let request = try! agentsDecoder.decode(AgentFindRequest.self, from: Data(json.utf8))
    expect(request.query == "parser" && request.zoneId?.uuidString == "00000000-0000-0000-0000-0000000CA107", "find request decodes")
    expect(request.effectiveLimit == AgentFindRequest.maxLimit, "limit is capped at \(AgentFindRequest.maxLimit), got \(request.effectiveLimit)")
    expect(try! agentsDecoder.decode(AgentFindRequest.self, from: Data("{}".utf8)).effectiveLimit == AgentFindRequest.defaultLimit,
           "an empty find request takes the default limit")
    let inspect = try! agentsDecoder.decode(AgentInspectRequest.self, from: Data(#"{"agentId":"00000000-0000-0000-0000-0000000A0001","maxEvents":500}"#.utf8))
    expect(inspect.agentId == agentsID("0001") && inspect.effectiveMaxEvents == AgentInspectRequest.maxMaxEvents,
           "inspect request decodes a bare-UUID agentId and caps maxEvents")
    expect((try? agentsDecoder.decode(AgentInspectRequest.self, from: Data("{}".utf8))) == nil, "inspect without agentId must not decode")
}

private func checkRankerOrderAndReasons() {
    let zone = UUID()
    let refactor = agentsID("0002")
    let tests = agentsID("0003")
    let docs = agentsID("0004")
    let me = agentsID("0001")
    let candidates = [
        AgentFindCandidateFacts(identity: identity(me, name: "Array", zone: zone), evidenceAvailable: false, isCaller: true),
        AgentFindCandidateFacts(identity: identity(refactor, name: "Refactor Parser", role: "coder", status: .working),
                                taskTitle: "Refactor the parser entry point", referencedFiles: ["src/parser.swift"],
                                evidenceAvailable: true, isCaller: false),
        AgentFindCandidateFacts(identity: identity(tests, name: "Parser Tests", zone: zone, observedAt: agentsNow.addingTimeInterval(-3600)),
                                evidenceAvailable: false, isCaller: false),
        AgentFindCandidateFacts(identity: identity(docs, name: "Docs Writer", checkout: ckOther), evidenceAvailable: false, isCaller: false),
    ]
    let context = AgentFindRanker.Context(callerCheckout: ckOwn, callerZoneId: zone, now: agentsNow)

    // Exact id beats everything, and says so.
    let byId = AgentFindRanker.rank(query: tests.rawValue.uuidString.lowercased(), context: context, candidates: candidates, limit: 5)
    expect(byId.candidates.first?.agent.agentId == tests && byId.candidates.first?.matchReasons.first == "exact agentId",
           "an exact id is ranked first with an explicit reason: \(byId.candidates.map(\.matchReasons))")
    expect(byId.candidates.count == 1 && !byId.ambiguous, "an id query matches exactly one agent")

    // Exact name (case-insensitive) beats a token match.
    let byName = AgentFindRanker.rank(query: "refactor parser", context: context, candidates: candidates, limit: 5)
    expect(byName.candidates.first?.agent.agentId == refactor && byName.candidates.first?.matchReasons.contains("exact name") == true,
           "an exact name ranks first: \(byName.candidates.map { ($0.agent.displayName, $0.score, $0.matchReasons) })")
    expect(!byName.ambiguous, "exact name over a token match is not ambiguous")

    // Token query: name + task + file evidence outrank name alone; reasons name each match.
    let parser = AgentFindRanker.rank(query: "parser", context: context, candidates: candidates, limit: 5)
    expect(parser.candidates.map(\.agent.agentId) == [refactor, tests],
           "lexical misses are excluded and evidence-rich matches lead: \(parser.candidates.map(\.agent.displayName))")
    let refactorReasons = parser.candidates[0].matchReasons
    expect(refactorReasons.contains("name contains \"parser\"") && refactorReasons.contains("task mentions \"parser\"")
           && refactorReasons.contains("referenced file src/parser.swift") && refactorReasons.contains("same checkout")
           && refactorReasons.contains("working now"),
           "every reason is explainable: \(refactorReasons)")
    expect(parser.candidates[1].matchReasons.contains("same zone") && !parser.candidates[1].matchReasons.contains("active recently"),
           "supporting evidence is attributed per candidate: \(parser.candidates[1].matchReasons)")
    expect(parser.candidates[0].evidenceAvailable && !parser.candidates[1].evidenceAvailable, "evidenceAvailable is carried through")
    expect(!parser.ambiguous, "different scores are not ambiguous")

    // No query: everything is ranked on supporting evidence; the caller is labelled.
    let all = AgentFindRanker.rank(query: nil, context: context, candidates: candidates, limit: 10)
    expect(all.candidates.count == 4, "no query keeps every candidate")
    expect(all.candidates.first(where: \.isCaller)?.matchReasons.contains("this is you") == true, "the caller is labelled")
    expect(all.candidates.last?.agent.agentId == docs, "a foreign-checkout agent with no other evidence sinks to the bottom")
}

private func checkRankerAmbiguityAndFilters() {
    let helper = agentsID("0005")
    let runner = agentsID("0006")
    let candidates = [
        AgentFindCandidateFacts(identity: identity(helper, name: "Alpha Helper"), evidenceAvailable: false, isCaller: false),
        AgentFindCandidateFacts(identity: identity(runner, name: "Alpha Runner"), evidenceAvailable: false, isCaller: false),
    ]
    let context = AgentFindRanker.Context(callerCheckout: ckOwn, callerZoneId: nil, now: agentsNow)
    let tie = AgentFindRanker.rank(query: "alpha", context: context, candidates: candidates, limit: 5)
    expect(tie.candidates.count == 2 && tie.candidates[0].score == tie.candidates[1].score, "two equal matches tie")
    expect(tie.ambiguous, "a tie at the top is reported as ambiguous, never resolved silently")
    expect(tie.candidates.map(\.agent.agentId) == [helper, runner], "ties break deterministically by id")
    let limited = AgentFindRanker.rank(query: "alpha", context: context, candidates: candidates, limit: 1)
    expect(limited.candidates.count == 1 && limited.ambiguous, "the limit cuts the list but the ambiguity is still reported")
    let miss = AgentFindRanker.rank(query: "zeta", context: context, candidates: candidates, limit: 5)
    expect(miss.candidates.isEmpty && !miss.ambiguous, "a query matching nothing returns no candidates")

    var response = AgentFindResponse(query: "alpha", candidates: tie.candidates, ambiguous: true, truncated: false, observedAt: agentsNow)
    let data = try! agentsEncoder.encode(response)
    let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    expect(object["schema"] as? String == WorkspaceAPISchema.v1 && object["projection"] as? Bool == true && object["ambiguous"] as? Bool == true,
           "the response is stamped schema + projection + ambiguous")
    let firstAgent = ((object["candidates"] as! [[String: Any]])[0]["agent"] as! [String: Any])
    expect(firstAgent["checkoutHandle"] as? String == ckOwn.rawValue && !(firstAgent.values.contains { ($0 as? String)?.contains("/private/tmp") == true }),
           "candidates carry the opaque checkout handle and never a path")
    response.truncated = true
    expect(try! agentsDecoder.decode(AgentFindResponse.self, from: try! agentsEncoder.encode(response)) == response, "find response round-trips")
}

private func checkInspectRoundTripAndExcerptBound() {
    let items = (0..<20).map { i in
        AgentInspectEvidenceItem(kind: i % 2 == 0 ? "assistant" : "toolCall", at: agentsNow.addingTimeInterval(Double(i)),
                                 text: String(repeating: "x", count: 500) + "#\(i)")
    }
    // 20 items × ~504 B; a 2 KB ceiling keeps the NEWEST three whole items.
    let bounded = AgentInspectExcerpt.bound(items, maxItems: 12, byteCeiling: 2048)
    expect(bounded.truncated, "shedding marks truncated")
    expect(bounded.items.count == 4 && bounded.items.last?.text.hasSuffix("#19") == true && bounded.items.first?.text.hasSuffix("#16") == true,
           "the newest items survive, oldest first in order: \(bounded.items.map { $0.text.suffix(3) })")
    expect(bounded.items.reduce(0) { $0 + $1.text.utf8.count } <= 2048, "the kept text fits the ceiling")
    let fits = AgentInspectExcerpt.bound(Array(items.prefix(3)), maxItems: 12, byteCeiling: 4096)
    expect(!fits.truncated && fits.items.count == 3, "under both caps nothing is cut")
    let huge = AgentInspectExcerpt.bound([AgentInspectEvidenceItem(kind: "assistant", at: nil, text: String(repeating: "é", count: 5000))], maxItems: 12, byteCeiling: 100)
    expect(huge.truncated && huge.items.count == 1 && huge.items[0].text.utf8.count <= 100 && huge.items[0].text.count > 1,
           "a single oversize item is cut UNDER the ceiling on a character boundary, not dropped: \(huge.items[0].text.utf8.count) bytes")
    expect(huge.items[0].text.hasSuffix("…") && !huge.items[0].text.contains("\u{FFFD}"),
           "the cut is marked and never splits a scalar into a replacement character")
    let countCut = AgentInspectExcerpt.bound(items, maxItems: 5, byteCeiling: 1 << 20)
    expect(countCut.truncated && countCut.items.count == 5 && countCut.items.last?.text.hasSuffix("#19") == true, "maxItems alone also truncates")

    let response = AgentInspectResponse(
        agent: identity(agentsID("0002"), name: "Refactor Parser", role: "coder", status: .working),
        isCaller: false, lastActivityAt: agentsNow, latestPromptAt: agentsNow.addingTimeInterval(-60), latestTurnAt: nil,
        terminalOutcome: "succeeded", promptTitle: "Refactor the parser", transcriptAvailable: true,
        recentEvents: bounded.items, recentEventsTruncated: true, referencedFiles: ["src/parser.swift"],
        evidenceSource: "supervisor.transcriptProjection", note: nil, observedAt: agentsNow)
    let data = try! agentsEncoder.encode(response)
    expect(try! agentsDecoder.decode(AgentInspectResponse.self, from: data) == response, "inspect response round-trips")
    let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    expect(object["projection"] as? Bool == true && object["schema"] as? String == WorkspaceAPISchema.v1 && object["recentEventsTruncated"] as? Bool == true,
           "the inspect response says it is a projection and whether it was cut")
    let absent = AgentInspectResponse(
        agent: identity(agentsID("0003"), name: "Parser Tests"), isCaller: false, lastActivityAt: agentsNow, latestPromptAt: nil,
        latestTurnAt: nil, terminalOutcome: nil, promptTitle: nil, transcriptAvailable: false, recentEvents: [],
        recentEventsTruncated: false, referencedFiles: [], evidenceSource: "record",
        note: AgentInspectResponse.absentEvidenceNote, observedAt: agentsNow)
    expect(absent.note?.contains("not evidence") == true && !absent.transcriptAvailable, "absent evidence is reported as absent, with the caveat")
}

private func checkAgentInspectGrantEvaluator() {
    let me = agentsID("0001")
    let other = agentsID("0002")
    let third = agentsID("0003")
    let preset = WorkspaceToolGrant.phase1Preset(agentId: me, checkout: ckOwn, generation: 1)
    typealias E = WorkspaceToolGrantEvaluator
    expect(E.evaluateAgentInspect(agentId: me, target: me, grants: [preset], currentGeneration: 1) == .allowed(grantId: preset.grantId),
           "self-inspect is in the preset")
    expect(E.evaluateAgentInspect(agentId: me, target: other, grants: [preset], currentGeneration: 1) == .scopeApprovalRequired(target: other),
           "another agent needs scope approval, never a silent read")
    expect(E.evaluateAgentInspect(agentId: me, target: me, grants: [preset], currentGeneration: 2) == .denied,
           "a revoked generation denies even self")
    expect(E.evaluateAgentInspect(agentId: other, target: other, grants: [preset], currentGeneration: 1) == .denied,
           "a grant never authorizes a different principal")
    let noInspect = WorkspaceToolGrant(agentId: me, checkoutHandles: [ckOwn], operations: [.workspaceContext, .artifactOpen],
                                       presentationCeiling: .preserveAll, issuer: .sessionPolicy, revocationGeneration: 1)
    expect(E.evaluateAgentInspect(agentId: me, target: other, grants: [noInspect], currentGeneration: 1) == .denied,
           "without the op at all there is nothing to approve")

    let once = WorkspaceToolGrant(agentId: me, checkoutHandles: [], operations: [.agentInspect], presentationCeiling: .preserveAll,
                                  issuer: .userApprovalOnce(requestId: "p1"), revocationGeneration: 1, singleUse: true, inspectableAgentIds: [other])
    let session = WorkspaceToolGrant(agentId: me, checkoutHandles: [], operations: [.agentInspect], presentationCeiling: .preserveAll,
                                     issuer: .userApprovalSession(requestId: "p2"), revocationGeneration: 1, inspectableAgentIds: [other])
    expect(E.evaluateAgentInspect(agentId: me, target: other, grants: [preset, once], currentGeneration: 1) == .allowed(grantId: once.grantId),
           "an approval-once grant admits its target")
    expect(E.evaluateAgentInspect(agentId: me, target: other, grants: [preset, once, session], currentGeneration: 1) == .allowed(grantId: session.grantId),
           "a durable grant is preferred over a once-grant so the once-grant is not spent needlessly")
    expect(E.evaluateAgentInspect(agentId: me, target: third, grants: [preset, session], currentGeneration: 1) == .scopeApprovalRequired(target: third),
           "an approval for one agent does not cover a third")
    expect(E.inspectableAgents(agentId: me, grants: [preset, session], currentGeneration: 1) == [me, other],
           "approved targets join self in the discoverable set")
}
