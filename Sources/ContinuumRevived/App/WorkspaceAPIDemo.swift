import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--workspace-api-demo` — CX-01's nine operations demonstrated end to end on a
/// real mounted scene. NOT a `*-check` flag on purpose: it is a narrated
/// walkthrough, not a gate, so it stays out of the check inventory and out of the
/// matrix.
///
/// Everything here is real except the model. No pi provider is logged in
/// (`pi auth check --provider anthropic` → invalid, everything else not_ready),
/// so nothing can make a language model call the tools. What IS real:
///
///   * the production boot mount (`AppDelegate.mountWorkspaceSceneAtBoot`, never
///     `install(into:)`), which is also what wires
///     `agentSupervisor.hostToolHandler` to the workspace API;
///   * the production dispatch entry (`AppDelegate.qaWorkspaceAPI.dispatch`);
///   * a real `WorkspaceRuntime`, `CanvasNSView`, `ZoneRuntimeRegistry`, project
///     stores on disk, and a real `AgentSupervisor` with durable records;
///   * for STEP 4, a real `PiRpcAgentRunner` over a FAKE `pi` on PATH: the
///     request arrives as an actual `extension_ui_request` frame and is answered
///     with an actual `extension_ui_response`, so that step's JSON is read back
///     out of the tool-result file the pi process wrote;
///   * the exact wire JSON, encoded by the same
///     `WorkspaceAPIService.transportResponse` + `PiHostToolResponse.encodedValue`
///     the bridge uses. What is printed is literally what a model would read.
///
/// Substituted: the approval alert (an injected `approvalHandler`, because
/// AGENTS hazard 6 forbids UI at boot in a headless run) and the model itself.
///
/// The fixture is `WorkspaceAPIChecks.makeFixture()` — the acceptance scenario in
/// code: two checkouts holding the same `notes.md`, the armed zone at a non-zero
/// origin belonging to the OTHER project, the caller's zone pinned live but
/// unarmed at (3000,400), a third zone with no layer at all, and an already-open
/// dirty `notes.md` in the caller's checkout.
///
/// A demo prints and exits 0 even when a step surprises us; a result that differs
/// from what the design promises prints `UNEXPECTED:` and is counted in the
/// summary. No assertion anywhere else is weakened to make this look good.
@MainActor
func runWorkspaceAPIDemo() async throws {
    struct DemoError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    guard let appSupportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw DemoError(message: "refusing to run without CONTINUUM_APP_SUPPORT — this demo mints durable agent records and must never write a real store")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw DemoError(message: "refusing to run from the PROD bundle — dev channel only")
    }
    _ = appSupportPath

    // MARK: - Output helpers

    var unexpectedCount = 0
    var summary: [(step: String, op: String, outcome: String)] = []

    func rule() { print(String(repeating: "─", count: 78)) }
    func header(_ step: String, _ op: String, _ english: String) {
        print("")
        rule()
        print("STEP \(step)  ·  \(op)")
        print("the agent asks: \(english)")
        rule()
    }
    func note(_ text: String) { print("  · \(text)") }
    func check(_ condition: Bool, _ description: String) {
        if !condition {
            print("UNEXPECTED: \(description)")
            unexpectedCount += 1
        }
    }
    func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return text }
        return String(decoding: encoded, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
    }
    func short(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.suffix(6))
    }
    func rectText(_ value: AnyHashableJSON?) -> String {
        guard let object = value?.object,
              let x = (object["x"]?.value as? NSNumber)?.doubleValue,
              let y = (object["y"]?.value as? NSNumber)?.doubleValue,
              let w = (object["width"]?.value as? NSNumber)?.doubleValue,
              let h = (object["height"]?.value as? NSNumber)?.doubleValue
        else { return "—" }
        return "(\(Int(x)), \(Int(y)), \(Int(w))x\(Int(h)))"
    }
    func frameText(_ frame: TileFrame?) -> String {
        guard let frame else { return "—" }
        return "(\(Int(frame.x)), \(Int(frame.y)), \(Int(frame.width))x\(Int(frame.height)))"
    }

    // MARK: - A fake pi on PATH

    // Every managed runner in this demo starts THIS, never the user's real pi:
    // no model, no auth, no network. It speaks pi 0.85.0's rpc frames, and when a
    // prompt carries the BRIDGE_DEMO marker it makes one real host tool call —
    // `extension_ui_request` out, `extension_ui_response` in — exactly the way
    // `continuum-workspace-tools.ts` does through `ctx.ui.input`.
    let fileManager = FileManager.default
    let demoRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-workspace-api-demo-\(UUID().uuidString)", isDirectory: true)
    let binDir = demoRoot.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: demoRoot) }
    let executable = binDir.appendingPathComponent("pi")
    try workspaceAPIDemoFakePiSource.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(binDir.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }

    // `send` validates the persisted harness and model against the catalogue, and
    // QA never probes a provider; the snapshot says what the fake stands for.
    let demoModel = "openai-codex/gpt-5.6-sol"
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: [demoModel],
        displayNames: [demoModel: "Fixture"], contextWindows: [demoModel: 200_000]))

    // MARK: - The scene

    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let supervisor = f.delegate.qaAgentSupervisor
    defer { supervisor.stopAll() }
    let api = f.api

    // AGENTS hazard 6: the production handler is an NSAlert. Injected here, and
    // injected FIRST, so nothing can raise a panel in a headless run. Each
    // decision is scripted; every prompt is printed as the user would read it.
    var prompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    var decisions: [WorkspaceAPIService.ScopeApprovalDecision] = []
    api.approvalHandler = { prompt in
        prompts.append(prompt)
        let decision = decisions.isEmpty ? .deny : decisions.removeFirst()
        print("  ↑ APPROVAL PROMPT (the trusted host UI, injected here): agent “\(prompt.agentDisplayName)” "
            + "wants \(prompt.op.rawValue) on “\(prompt.checkoutDisplayName)”"
            + (prompt.relativePath.map { " · \($0)" } ?? "")
            + (prompt.targetAgentDisplayName.map { " · target “\($0)”" } ?? "")
            + " → user chose \(decision)")
        return decision
    }

    var requestCounter = 0
    func nextRequestId() -> String { requestCounter += 1; return "demo-req-\(requestCounter)" }

    /// Dispatch through the production entry and print the EXACT wire JSON the
    /// model would receive, encoded by the bridge's own encoder.
    @discardableResult
    func call(_ op: String, _ payload: [String: Any], requestId: String? = nil) -> WorkspaceAPIService.Reply {
        let id = requestId ?? nextRequestId()
        let reply = api.dispatch(agentId: f.agentId, requestId: id, op: op, payload: payload)
        let wire = WorkspaceAPIService.transportResponse(for: reply).encodedValue(requestId: id)
        print("  JSON the model receives:")
        print(pretty(wire))
        return reply
    }
    func object(_ reply: WorkspaceAPIService.Reply) -> [String: AnyHashableJSON] {
        if case let .result(value) = reply { return value }
        return [:]
    }
    func errorOf(_ reply: WorkspaceAPIService.Reply) -> WorkspaceAPIError? {
        if case let .error(value) = reply { return value }
        return nil
    }
    func uuid(_ value: AnyHashableJSON?) -> UUID? { value?.string.flatMap(UUID.init(uuidString:)) }
    func persistedFrame(_ tileId: UUID) -> TileFrame? {
        (try? f.storePb.loadCanvas())?.tiles.first(where: { $0.id == tileId })?.frame
    }
    func liveWorldFrame(_ tileId: UUID) -> TileFrame? {
        f.canvas.zoneId(containing: tileId)
            .flatMap { f.canvas.tilesInWorldFrames(forZoneId: $0) }?
            .first(where: { $0.id == tileId })?.frame
    }

    print("")
    rule()
    print("ARRAY WORKSPACE API (CX-01) — end-to-end demonstration")
    rule()
    print("Real: the boot mount, the runtime, the canvas, the zone layers, the project")
    print("stores on disk, the agent supervisor and its records, the dispatch pipeline,")
    print("the grants, and (STEP 4) a real pi rpc runner over a FAKE pi binary.")
    print("Not real: the language model (no provider is logged in) and the approval")
    print("alert, which is injected so a headless run raises no UI.")
    print("")
    note("caller agent            \(short(f.agentId.rawValue)) · harness Pi · checkout Pb")
    note("caller checkout handle  \(f.pbHandle.rawValue)")
    note("armed zone at boot      \(short(f.canvas.armedZoneId)) (project Pa's zone, origin 600,200)")
    note("caller's zone           \(short(f.zoneB)) — pinnedLive, NOT armed, origin 3000,400")
    note("unhydrated zone         \(short(f.zoneB2)) — origin 9000,9000, no layer at all")
    note("runtime has its canvas  \(f.runtime.qaHasCanvas) (the mount, not install(into:))")
    check(f.runtime.qaHasCanvas, "the production mount must hand the runtime its canvas")
    check(f.canvas.armedZoneId == f.zoneA, "zoneA must be armed at boot")
    check(f.canvas.installedZonePlacement(for: f.zoneB2) == nil, "zoneB2 must have no layer")

    // Workspace Tools ON for the caller — the per-agent policy, the same setter
    // the tile menu's checkmark item flips.
    let enabled = supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    note("workspace tools enabled for the caller: \(enabled)")

    // A readable name for the caller. Without this the supervisor derives one
    // from the first prompt, and STEP 7's approval alert would quote it.
    _ = supervisor.rename(agentID: f.agentId, to: "Integration Lead")

    // Three more agents so `agent.find` has something to rank and `agent.inspect`
    // has a stranger to ask about. All three live in the caller's own checkout.
    // "Refactor Helper" is the only one with evidence — its transcript is seeded
    // through the supervisor's own delivery path, so what STEP 3 returns is what
    // production ingests — and its ONLY link to the word "parser" is a referenced
    // file, which is why it ranks below the two name matches. Those two carry no
    // evidence at all, so they tie, and a tie is reported rather than resolved.
    let helper = supervisor.spawn(
        role: "coder", prompt: nil, cwd: f.pbRoot, harness: .pi, model: demoModel,
        thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot,
        displayName: "Refactor Helper")
    let second = supervisor.spawn(
        role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: demoModel,
        thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot,
        displayName: "Parser Two")
    let third = supervisor.spawn(
        role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: demoModel,
        thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot,
        displayName: "Parser Three")
    let thread = AgentSupervisor.threadId(for: helper)
    supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "turn-1"), to: helper)
    supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "item-1", kind: .fileChange, title: "src/parser.swift"), to: helper)
    supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "turn-1", streamKind: .assistant,
                                       delta: "Rewrote the parser entry point and split the token table out of it."), to: helper)
    supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "turn-1", outcome: .completed, errorMessage: nil), to: helper)
    note("three more agents in the caller's checkout: “Refactor Helper” \(short(helper.rawValue)) (transcript seeded), “Parser Two” \(short(second.rawValue)), “Parser Three” \(short(third.rawValue))")

    // The already-open, UNSAVED document. A Markdown tile edits through its
    // source view once in Edit mode; the draft lives in the tile's own
    // FileDocumentSession, which is exactly what a reveal must not touch.
    guard let fileView = f.canvas.tileView(for: f.fileTileB) as? FileTileNSView else {
        throw DemoError(message: "the persisted Pb notes.md tile must hydrate as a FileTileNSView")
    }
    fileView.setMode(.edit)
    fileView.layoutSubtreeIfNeeded()
    let draftText = f.pbSentinel + "unsaved draft: the sentence the agent must not destroy\n"
    fileView.textView.string = draftText
    fileView.textView.didChangeText()
    note("notes.md tile \(short(f.fileTileB)) is already open in zone \(short(f.zoneB)) and DIRTY (isDirty=\(fileView.isDirty))")
    check(fileView.isDirty && fileView.qaDraftText == draftText, "the fixture must hold a dirty draft before STEP 4")

    // MARK: - STEP 1 — workspace.context

    header("1", "workspace.context", "\"where am I, what is around me, and what may I do?\"")
    let contextReply = call("workspace.context", [:])
    let context = object(contextReply)
    let contextBytes = (try? JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(context)).count) ?? -1
    let capabilities = (context["capabilities"]?.array?.compactMap(\.string) ?? []).sorted()
    let coverage = context["coverage"]?.object
    note("encoded size \(contextBytes) bytes against the \(WorkspaceContextResponse.encodedByteCeiling)-byte ceiling — \(WorkspaceContextResponse.encodedByteCeiling - contextBytes) to spare")
    note("identity: agent \(short(uuid(context["agentId"]))) · project \(short(uuid(context["projectId"]))) · zone \(short(uuid(context["zoneId"]))) · tile \(short(uuid(context["tileId"])))")
    note("coverage: complete=\(coverage?["complete"]?.bool.map(String.init) ?? "—") · installed=[\((coverage?["installedZoneIds"]?.array ?? []).map { short(uuid($0)) }.joined(separator: ", "))] · unhydrated=[\((coverage?["unhydratedZoneIds"]?.array ?? []).map { short(uuid($0)) }.joined(separator: ", "))]")
    note("capabilities (\(capabilities.count)): \(capabilities.joined(separator: ", "))")
    note("presentation: nothing — a read moves no camera and takes no focus")
    check(contextBytes < WorkspaceContextResponse.encodedByteCeiling, "the context must stay under its byte ceiling, got \(contextBytes)")
    check(uuid(context["zoneId"]) == f.zoneB, "the context follows the AGENT's tile, not the armed zone")
    check(context["checkoutHandle"]?.string == f.pbHandle.rawValue, "the context names the agent's own checkout")
    check(coverage?["complete"]?.bool == false, "coverage must not claim completeness with an unhydrated zone")
    check(!capabilities.contains("canvas.apply") && !capabilities.contains("agent.delegate"),
          "the two withheld ops must not be advertised as capabilities")
    summary.append(("1", "workspace.context", "\(contextBytes)B / \(WorkspaceContextResponse.encodedByteCeiling)B, \(capabilities.count) capabilities, coverage incomplete"))

    // MARK: - STEP 2 — agent.find

    header("2", "agent.find", "\"which agents around here have anything to do with the parser?\"")
    let findReply = call("agent.find", ["query": "parser"])
    let find = object(findReply)
    let candidates = (find["candidates"]?.array ?? []).compactMap(\.object)
    for (index, candidate) in candidates.enumerated() {
        let identity = candidate["agent"]?.object ?? [:]
        let reasons = (candidate["matchReasons"]?.array ?? []).compactMap(\.string)
        note("  #\(index + 1) score \(candidate["score"]?.int ?? -1) · \(identity["displayName"]?.string ?? "—") \(short(uuid(identity["agentId"]))) · evidence=\(candidate["evidenceAvailable"]?.bool.map(String.init) ?? "—") · because: \(reasons.joined(separator: "; "))")
    }
    let topScores = candidates.compactMap { $0["score"]?.int }
    note("ambiguous=\(find["ambiguous"]?.bool.map(String.init) ?? "—") — the two leading candidates score \(topScores.prefix(2).map(String.init).joined(separator: " and ")), so the host reports the tie instead of picking one")
    note("the evidence-only match (“Refactor Helper”, whose only link to “parser” is a file it touched) ranks LAST: evidence supports a match, it does not lead one")
    let findJSON = (try? JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(find))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    note("no transcript text and no filesystem path in the payload: \(!findJSON.contains("token table") && !findJSON.contains(f.pbRoot.path))")
    note("presentation: nothing")
    check(candidates.count >= 2, "the query must match at least the two “Parser …” agents, got \(candidates.count)")
    check(topScores.count >= 2 && topScores[0] == topScores[1], "the two leading candidates must really tie, got \(topScores)")
    check(find["ambiguous"]?.bool == true, "two equally-matching names are an ambiguity, not a winner")
    check(candidates.last?["agent"]?.object?["displayName"]?.string == "Refactor Helper", "a file-evidence-only match ranks below the name matches")
    check(!findJSON.contains("token table") && !findJSON.contains(f.pbRoot.path), "discovery is metadata: no transcript text, no raw paths")
    summary.append(("2", "agent.find", "\(candidates.count) candidates, ambiguous=\(find["ambiguous"]?.bool.map(String.init) ?? "—")"))

    // MARK: - STEP 3 — agent.inspect

    header("3", "agent.inspect", "\"what am I doing? …and then: what is Refactor Helper doing?\"")
    let promptsBeforeSelf = prompts.count
    print("  (a) SELF — in the session preset, so nobody is asked")
    let selfReply = call("agent.inspect", ["agentId": f.agentId.rawValue.uuidString])
    let selfInspect = object(selfReply)
    note("isCaller=\(selfInspect["isCaller"]?.bool.map(String.init) ?? "—") · approval prompts raised: \(prompts.count - promptsBeforeSelf)")
    check(prompts.count == promptsBeforeSelf, "inspecting yourself must never ask the user")
    check(selfInspect["isCaller"]?.bool == true, "self inspection is labelled as the caller")

    print("")
    print("  (b) ANOTHER AGENT — withheld from the preset; the user is asked once")
    decisions = [.allowOnce]
    let otherReply = call("agent.inspect", ["agentId": helper.rawValue.uuidString])
    let otherInspect = object(otherReply)
    let excerpt = (otherInspect["recentEvents"]?.array ?? []).compactMap(\.object)
    let excerptJSON = (try? JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(otherInspect))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    note("prompted once for the TARGET agent: \(prompts.last?.targetAgentDisplayName ?? "—") (\(prompts.count) prompts so far)")
    note("evidenceSource=\(otherInspect["evidenceSource"]?.string ?? "—") · transcriptAvailable=\(otherInspect["transcriptAvailable"]?.bool.map(String.init) ?? "—") · recentEventsTruncated=\(otherInspect["recentEventsTruncated"]?.bool.map(String.init) ?? "—")")
    note("bounded: \(excerpt.count) recentEvents item(s) (\(excerpt.compactMap { $0["kind"]?.string }.joined(separator: ", "))), \(excerptJSON.utf8.count) bytes total, attributed to \(short(uuid(otherInspect["agent"]?.object?["agentId"]))) — never merged into the caller's own voice")
    note("the other agent's words arrive as DATA: “\(excerpt.last?["text"]?.string ?? "—")”")
    note("presentation: nothing — a read never marks the target visited or touches its runner")
    check(prompts.count == promptsBeforeSelf + 1, "exactly one prompt for the one stranger")
    check(otherInspect["isCaller"]?.bool == false, "the other agent is not the caller")
    check(otherInspect["transcriptAvailable"]?.bool == true, "the seeded transcript must be reachable as evidence")
    check(!excerpt.isEmpty, "the approved inspection must carry the seeded evidence")
    summary.append(("3", "agent.inspect", "self: 0 prompts; other: 1 prompt, \(excerpt.count) bounded item(s), \(excerptJSON.utf8.count)B"))

    // MARK: - STEP 4 — artifact.open, THROUGH THE REAL PI BRIDGE

    header("4", "artifact.open", "\"open notes.md\" — the name exists in BOTH checkouts, and mine is already open with unsaved work")
    print("  This step does NOT call dispatch directly. It goes through the real")
    print("  PiRpcAgentRunner: the fake pi emits an extension_ui_request carrying an")
    print("  array.workspace.v1 envelope, the mount's own hostToolHandler routes it to")
    print("  WorkspaceAPIService.handle, and the host's reply goes back as a real")
    print("  extension_ui_response. The JSON below is read out of the tool-result file")
    print("  the pi process itself wrote.")
    let draftBefore = fileView.qaDraftText ?? ""
    note("draft BEFORE: \(draftBefore.split(separator: "\n").last.map(String.init) ?? "—")")
    let bridgeCwd = URL(fileURLWithPath: supervisor.records[f.agentId]?.cwd ?? f.pbRoot.path, isDirectory: true)
    let toolResultURL = bridgeCwd.appendingPathComponent("tool-results/demo-open-call.json")
    let sent = supervisor.send("BRIDGE_DEMO please open notes.md", to: f.agentId)
    check(sent, "the caller's prompt must be accepted so its runner starts")
    let answered = await waitUntil(timeout: 40, pollInterval: 0.1) {
        fileManager.fileExists(atPath: toolResultURL.path)
    }
    check(answered, "the pi process must receive a tool result within 40s")
    let bridgeJSON = (try? String(contentsOf: toolResultURL, encoding: .utf8)) ?? ""
    print("  JSON the model receives (from the pi process's own tool-result file):")
    print(pretty(bridgeJSON))
    let bridgeObject = (try? JSONSerialization.jsonObject(with: Data(bridgeJSON.utf8))) as? [String: Any]
    let bridgeResult = bridgeObject?["result"] as? [String: Any]
    let uiResponses = (try? String(contentsOf: bridgeCwd.appendingPathComponent("ui-responses.log"), encoding: .utf8)) ?? ""
    let openedTileId = (bridgeResult?["tileId"] as? String).flatMap(UUID.init(uuidString:))
    let draftAfter = fileView.qaDraftText ?? ""
    note("frames: 1 extension_ui_request out, \(uiResponses.split(separator: "\n").count) extension_ui_response in (pi's own log)")
    note("resolved to the AGENT's checkout: checkoutHandle=\(bridgeResult?["checkoutHandle"] as? String ?? "—") (Pb), not the armed project Pa")
    note("document=\(bridgeResult?["document"] as? String ?? "—") placement=\(bridgeResult?["placement"] as? String ?? "—") → the already-open tile \(short(openedTileId)) was revealed, not duplicated")
    note("actual zone \(short((bridgeResult?["actualZoneId"] as? String).flatMap(UUID.init(uuidString:)))) · actual world rect \(frameText(liveWorldFrame(f.fileTileB)))")
    note("draft AFTER: \(draftAfter.split(separator: "\n").last.map(String.init) ?? "—")")
    note("draft field in the reply: \(bridgeResult?["draft"] as? String ?? "—") · tile still dirty: \(fileView.isDirty)")
    note("presentation: camera \((bridgeResult?["presentationEffects"] as? [String: Any])?["camera"] as? String ?? "—") — the request asked for preserve and the camera did not move")
    check(bridgeObject?["status"] as? String == "ok", "the bridge reply must be an ok: got \(bridgeObject?["status"] as? String ?? "nil")")
    check(openedTileId == f.fileTileB, "the open must resolve to Pb's already-open notes.md tile, not Pa's namesake")
    check(bridgeResult?["checkoutHandle"] as? String == f.pbHandle.rawValue, "identity names the agent's own checkout")
    check(draftAfter == draftBefore && fileView.isDirty, "the unsaved draft must survive the reveal byte for byte")
    check(bridgeResult?["draft"] as? String == "preserved", "the reply must say the draft was preserved")
    check(!uiResponses.isEmpty, "the reply must have travelled as a real extension_ui_response")
    summary.append(("4", "artifact.open (via pi bridge)", "revealed tile \(short(openedTileId)) in Pb; draft preserved; camera preserved"))
    // The runner has done its one job; nothing later needs it.
    supervisor.stop(f.agentId)

    // MARK: - STEP 5 — artifact.open into an unhydrated zone

    header("5", "artifact.open", "\"open hidden-target.md over there in my other zone\" — a zone the app has not hydrated")
    let refusalReply = call("artifact.open", ["relativePath": "hidden-target.md", "placement": ["targetZoneId": f.zoneB2.uuidString]])
    let refusal = errorOf(refusalReply)
    let tilesAfterRefusal = f.canvas.allWorkspaceTiles().count
    note("code=\(refusal?.code.rawValue ?? "—") reason=\(refusal?.message ?? "—")")
    note("a structured refusal, not a flat install: the zone has no layer, so there is nowhere correct to put a tile")
    note("tiles on the canvas: \(tilesAfterRefusal) (unchanged) · presentation: nothing")
    check(refusal?.code == .unsupported && refusal?.message == "zone_unhydrated", "an unhydrated destination is refused as zone_unhydrated")
    summary.append(("5", "artifact.open (unhydrated)", "\(refusal?.code.rawValue ?? "—") / \(refusal?.message ?? "—"), nothing installed"))

    // MARK: - STEP 6 — canvas.query

    header("6", "canvas.query", "\"describe my part of the canvas — zones, tiles, where they are\"")
    let queryReply = call("canvas.query", [:])
    let page = object(queryReply)
    let zones = (page["zones"]?.array ?? []).compactMap(\.object)
    let tiles = (page["tiles"]?.array ?? []).compactMap(\.object)
    let queryBytes = (try? JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(page)).count) ?? -1
    for zone in zones {
        note("zone \(short(uuid(zone["zoneId"]))) · hydrated=\(zone["hydrated"]?.bool.map(String.init) ?? "—") stale=\(zone["stale"]?.bool.map(String.init) ?? "—") · world \(rectText(zone["worldRect"]))")
    }
    for tile in tiles {
        note("tile \(short(uuid(tile["tileId"]))) · \(tile["kind"]?.string ?? "—") · world \(rectText(tile["worldRect"]))")
    }
    note("coverage complete=\(page["coverage"]?.object?["complete"]?.bool.map(String.init) ?? "—") · revision structure=\(page["revision"]?.object?["structure"]?.int ?? -1) epoch=\(String((page["revision"]?.object?["epoch"]?.string ?? "").prefix(8)))…")
    note("page size \(queryBytes) bytes against the \(CanvasQueryPage.encodedByteCeiling)-byte ceiling")
    check(Set(zones.compactMap { uuid($0["zoneId"]) }) == [f.zoneB, f.zoneB2], "the query is scoped to the caller's own project zones")
    check(tiles.allSatisfy { uuid($0["zoneId"]) == f.zoneB }, "an unhydrated zone contributes no tiles — absence is never inferred")

    print("")
    print("  …and the second page, through the cursor:")
    let firstPageReply = call("canvas.query", ["limit": 2])
    let firstPage = object(firstPageReply)
    guard let cursor = firstPage["nextCursor"]?.string else {
        throw DemoError(message: "a two-item page of six items must leave a cursor: \(firstPage)")
    }
    let secondPageReply = call("canvas.query", ["limit": 2, "cursor": cursor])
    let secondPage = object(secondPageReply)
    let firstIds = (firstPage["zones"]?.array ?? []).compactMap { short(uuid($0.object?["zoneId"])) }
        + (firstPage["tiles"]?.array ?? []).compactMap { short(uuid($0.object?["tileId"])) }
    let secondIds = (secondPage["zones"]?.array ?? []).compactMap { short(uuid($0.object?["zoneId"])) }
        + (secondPage["tiles"]?.array ?? []).compactMap { short(uuid($0.object?["tileId"])) }
    note("page 1: [\(firstIds.joined(separator: ", "))] → cursor \(String(cursor.prefix(12)))…")
    note("page 2: [\(secondIds.joined(separator: ", "))] → cursor \(secondPage["nextCursor"]?.string.map { String($0.prefix(12)) + "…" } ?? "none")")
    note("presentation: nothing")
    check(Set(firstIds).isDisjoint(with: Set(secondIds)) && secondIds.count == 2, "paging must not repeat or drop items")
    summary.append(("6", "canvas.query", "\(zones.count) zones, \(tiles.count) tiles, \(queryBytes)B, rev \(page["revision"]?.object?["structure"]?.int ?? -1), paged 2+2"))

    // MARK: - STEP 7 — canvas.apply (move)

    header("7", "canvas.apply", "\"move my own tile out of the way, to (4100, 900)\" — geometry is never in the preset")
    let revisionBeforeMove = f.runtime.structuralRevision
    let liveBeforeMove = liveWorldFrame(f.agentTileB)
    let persistedBeforeMove = persistedFrame(f.agentTileB)
    note("before: live \(frameText(liveBeforeMove)) · on disk \(frameText(persistedBeforeMove)) · structural revision \(revisionBeforeMove)")
    decisions = [.allowForSession]
    let moveReply = call("canvas.apply", [
        "op": "move", "tileId": f.agentTileB.uuidString,
        "worldFrame": ["x": 4100, "y": 900, "width": 240, "height": 160],
        "expectedRevision": ["epoch": api.epoch, "structure": revisionBeforeMove],
    ])
    let moved = object(moveReply)
    let persistedAfterMove = persistedFrame(f.agentTileB)
    note("approval prompts so far: \(prompts.count) — the FIRST canvas.apply asked, and the session grant means the next one will not")
    note("requestedWorldRect \(rectText(moved["requestedWorldRect"])) → actualWorldRect \(rectText(moved["actualWorldRect"])) · clamped=\(moved["clamped"]?.bool.map(String.init) ?? "—") · durability=\(moved["durability"]?.string ?? "—") · undoRegistered=\(moved["undoRegistered"]?.bool.map(String.init) ?? "—")")
    note("the two rects differ because the owner route is the DRAG's own path (beginGeometryEdit/commitGeometryEdit): auto-layout settled the tile against its neighbours exactly as it would under a pointer. That is why the reply carries the ACTUAL rect and the requested one, and why a model must read the actual one back.")
    note("live frame now \(frameText(liveWorldFrame(f.agentTileB))) — identical to the rect the model was told")
    note("re-read \(f.pbRoot.lastPathComponent)/.array canvas store: tile \(short(f.agentTileB)) is at \(frameText(persistedAfterMove)) — a WORLD frame, as canvas.json always holds")
    note("structural revision \(revisionBeforeMove) → \(f.runtime.structuralRevision)")
    note("presentation: camera \(moved["presentationEffects"]?.object?["camera"]?.string ?? "—") — an agent's edit does not steal the user's view")
    check(rectText(moved["actualWorldRect"]) == frameText(liveWorldFrame(f.agentTileB)), "the live world frame must equal the reported actualWorldRect")
    check(persistedAfterMove == liveWorldFrame(f.agentTileB), "the store must hold the same WORLD frame the model was told")
    check(f.runtime.structuralRevision == revisionBeforeMove + 1, "one committed geometry transaction bumps the revision once")
    check((try? f.storePb.loadCanvas().tiles.count) == 5, "cover-then-replace: the unhydrated zone's tile must survive the write")
    summary.append(("7", "canvas.apply move", "1 prompt, rect \(rectText(moved["actualWorldRect"])), persisted, rev \(revisionBeforeMove)→\(f.runtime.structuralRevision)"))

    // MARK: - STEP 8 — canvas.apply with a stale revision

    header("8", "canvas.apply", "\"move it again\" — but quoting the revision from BEFORE the last move")
    let liveBeforeStale = liveWorldFrame(f.agentTileB)
    let staleReply = call("canvas.apply", [
        "op": "move", "tileId": f.agentTileB.uuidString,
        "origin": ["x": 3200, "y": 1200],
        "expectedRevision": ["epoch": api.epoch, "structure": revisionBeforeMove],
    ])
    let stale = errorOf(staleReply)
    note("code=\(stale?.code.rawValue ?? "—") — the canvas moved under the agent, so the edit is refused rather than guessed at")
    note("live frame still \(frameText(liveWorldFrame(f.agentTileB))) · on disk still \(frameText(persistedFrame(f.agentTileB))) · revision still \(f.runtime.structuralRevision)")
    note("approval prompts: \(prompts.count) (unchanged — the session grant held; the refusal is about staleness, not permission)")
    note("presentation: nothing")
    check(stale?.code == .revisionConflict, "a stale expectedRevision is a revision_conflict")
    check(liveWorldFrame(f.agentTileB) == liveBeforeStale && persistedFrame(f.agentTileB) == persistedAfterMove, "a conflict must apply nothing, live or on disk")
    summary.append(("8", "canvas.apply stale", "\(stale?.code.rawValue ?? "—"), nothing moved"))

    // MARK: - STEP 9 — agent.delegate

    header("9", "agent.delegate", "\"spawn a helper to audit the parser, and let me see it\"")
    let childrenBefore = supervisor.children(of: f.agentId).count
    let agentTilesBefore = f.canvas.allWorkspaceTiles().filter { $0.kind == .managedAgent }.count
    decisions = [.allowForSession]
    let delegateReply = call("agent.delegate", [
        "task": "audit the parser entry point",
        "idempotencyKey": "demo-delegate-1",
        "presentation": ["camera": "preserve"],
    ], requestId: "demo-op-delegate")
    let delegated = object(delegateReply)
    let childId = uuid(delegated["childAgentId"]).map(AgentID.init(rawValue:))
    let childTileId = uuid(delegated["tileId"])
    let steps = delegated["steps"]?.object
    note("approval prompt raised for agent.delegate: \(prompts.last?.op.rawValue ?? "—") (\(prompts.count) prompts total)")
    note("child \(short(childId?.rawValue)) · provider \(delegated["provider"]?.string ?? "—") · model \(delegated["model"]?.string ?? "—") · inherited from the parent, never overridden")
    note("children of the caller: \(childrenBefore) → \(supervisor.children(of: f.agentId).count) · managed-agent tiles: \(agentTilesBefore) → \(f.canvas.allWorkspaceTiles().filter { $0.kind == .managedAgent }.count)")
    if let childTileId, let snapshot = f.canvas.navigationTileSnapshot(for: childTileId),
       let zone = f.canvas.installedZonePlacement(for: f.zoneB) {
        let childRect = CGRect(x: snapshot.worldFrame.x, y: snapshot.worldFrame.y, width: snapshot.worldFrame.width, height: snapshot.worldFrame.height)
        let zoneRect = CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
        note("child tile \(short(childTileId)) landed in zone \(short(f.canvas.zoneId(containing: childTileId))) at world (\(Int(childRect.minX)), \(Int(childRect.minY)), \(Int(childRect.width))x\(Int(childRect.height)))")
        note("the PARENT's zone rect is (\(Int(zoneRect.minX)), \(Int(zoneRect.minY)), \(Int(zoneRect.width))x\(Int(zoneRect.height))) and contains it: \(zoneRect.contains(childRect)) — NOT the armed zone at (600,200)")
        note("(the zone is wider than the 1400 STEP 6 reported: zones grow to hold their tiles, they never push a tile out)")
        check(zoneRect.contains(childRect), "the child's WORLD frame must sit inside the parent's zone")
        check(f.canvas.zoneId(containing: childTileId) == f.zoneB, "the child's tile belongs to the parent's zone")
    } else {
        check(false, "the child's tile must have a navigation snapshot so its world frame can be shown")
    }
    note("per-step status: creation=\(steps?["creation"]?.string ?? "—") attachment=\(steps?["attachment"]?.string ?? "—") durability=\(steps?["durability"]?.string ?? "—") presentation=\(steps?["presentation"]?.string ?? "—") → status=\(delegated["status"]?.string ?? "—") partial=\(delegated["partial"]?.bool.map(String.init) ?? "—")")
    note("presentation: camera \(delegated["presentationEffects"]?.object?["camera"]?.string ?? "—") (preserve was requested)")
    check(supervisor.children(of: f.agentId).count == childrenBefore + 1, "exactly one child")
    check(delegated["status"]?.string == "committed", "every step succeeded, so the delegation is committed")

    // The child is really doing the work: the fake pi received the task.
    if let childId, let childRecord = supervisor.records[childId] {
        let childCwd = URL(fileURLWithPath: childRecord.cwd, isDirectory: true)
        let taskArrived = await waitUntil(timeout: 30, pollInterval: 0.1) {
            (try? String(contentsOf: childCwd.appendingPathComponent("prompts.log"), encoding: .utf8))?
                .contains("audit the parser entry point") == true
        }
        note("the child's own runner received the task (its pi wrote prompts.log): \(taskArrived)")
        check(taskArrived, "the delegated task must actually reach the child's runner")
    }

    print("")
    print("  …the same idempotency key, replayed (a retry after a dropped answer):")
    let replayReply = call("agent.delegate", [
        "task": "audit the parser entry point",
        "idempotencyKey": "demo-delegate-1",
        "presentation": ["camera": "preserve"],
    ], requestId: "demo-op-delegate-retry")
    let replay = object(replayReply)
    note("childAgentId \(short(uuid(replay["childAgentId"]))) and tileId \(short(uuid(replay["tileId"]))) are the FIRST call's — operationId \(replay["operationId"]?.string ?? "—")")
    note("children: \(supervisor.children(of: f.agentId).count) · managed-agent tiles: \(f.canvas.allWorkspaceTiles().filter { $0.kind == .managedAgent }.count) — no second child, no second tile")
    check(uuid(replay["childAgentId"]) == childId?.rawValue, "a replay must return the first child")
    check(supervisor.children(of: f.agentId).count == childrenBefore + 1, "a replay must not create a second child")

    print("")
    print("  …the same key with a DIFFERENT task (a new intent hiding behind an old key):")
    let conflictReply = call("agent.delegate", ["task": "rewrite the parser", "idempotencyKey": "demo-delegate-1"])
    let conflict = errorOf(conflictReply)
    note("code=\(conflict?.code.rawValue ?? "—") · children still \(supervisor.children(of: f.agentId).count)")
    check(conflict?.code == .idempotencyConflict, "same key, different payload is an idempotency_conflict")
    summary.append(("9", "agent.delegate", "1 prompt, child \(short(childId?.rawValue)) in zone \(short(f.zoneB)), replay=same, conflict=\(conflict?.code.rawValue ?? "—")"))

    // MARK: - STEP 10 — agent.reveal + operation.get

    header("10", "agent.reveal / operation.get", "\"show me where that child is\" and \"what happened to my delegation?\"")
    // A camera reveal into an UNARMED zone is unavailable: targeting is not
    // arming (§16). The user clicks into the zone first, as they would.
    let armed = f.runtime.setActiveZone(f.zoneB, reason: .click)
    note("the user clicks the parent's zone first (arming it): \(armed) — a camera reveal into an unarmed zone is deliberately unavailable")
    let viewportAppliesBefore = f.canvas.qaViewportApplyCount
    let revealReply = call("agent.reveal", [
        "agentId": childId?.rawValue.uuidString ?? UUID().uuidString,
        "presentation": ["camera": "revealResult"],
    ])
    let revealed = object(revealReply)
    note("tile \(short(uuid(revealed["tileId"]))) · presentation=\(revealed["presentation"]?.string ?? "—") · camera=\(revealed["presentationEffects"]?.object?["camera"]?.string ?? "—")")
    note("camera applies \(viewportAppliesBefore) → \(f.canvas.qaViewportApplyCount) · children \(supervisor.children(of: f.agentId).count) and tiles \(f.canvas.allWorkspaceTiles().filter { $0.kind == .managedAgent }.count) unchanged — reveal creates nothing")
    check(uuid(revealed["tileId"]) == childTileId, "reveal answers with the tile the delegation created")
    check(supervisor.children(of: f.agentId).count == childrenBefore + 1, "reveal creates nothing")

    print("")
    let operationReply = call("operation.get", ["operationId": "demo-op-delegate"])
    let operation = object(operationReply)
    note("op=\(operation["op"]?.string ?? "—") status=\(operation["status"]?.string ?? "—") child=\(short(uuid(operation["childAgentId"]))) tile=\(short(uuid(operation["tileId"]))) childRunning=\(operation["childRunning"]?.bool.map(String.init) ?? "—")")
    note("presentation: nothing")
    check(operation["status"]?.string == "committed" && uuid(operation["childAgentId"]) == childId?.rawValue,
          "operation.get recovers the delegation's outcome and identity")
    summary.append(("10", "agent.reveal / operation.get", "camera \(revealed["presentationEffects"]?.object?["camera"]?.string ?? "—"), \(f.canvas.qaViewportApplyCount - viewportAppliesBefore) apply; operation \(operation["status"]?.string ?? "—")"))

    // MARK: - STEP 11 — revocation

    header("11", "workspace.context (after revocation)", "\"where am I?\" — asked one moment after the user turned Workspace Tools OFF")
    let revoked = supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, false)
    note("AgentSupervisor.setWorkspaceToolsEnabled(false) changed the record: \(revoked) — the same setter the tile menu's checkmark flips")
    let deniedReply = call("workspace.context", [:])
    let denied = errorOf(deniedReply)
    let message = denied?.message ?? ""
    let leaksPath = message.contains("/")
    let leaksIdentifier = message.range(of: "[0-9A-Fa-f]{8}-", options: .regularExpression) != nil
    note("code=\(denied?.code.rawValue ?? "—") message=\(message.debugDescription)")
    note("leaks a path: \(leaksPath) · leaks an identifier: \(leaksIdentifier) — a denial teaches the model nothing it was not already allowed to know")
    check(denied?.code == .permissionDenied, "a revoked agent gets permission_denied")
    check(!leaksPath && !leaksIdentifier, "a denial must name no path and no identifier")
    summary.append(("11", "workspace.context (revoked)", "\(denied?.code.rawValue ?? "—"), no path or id leaked"))

    // MARK: - Summary

    print("")
    rule()
    print("SUMMARY")
    rule()
    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    print("\(pad("STEP", 5))\(pad("OP", 30))OUTCOME")
    for row in summary {
        print("\(pad(row.step, 5))\(pad(row.op, 30))\(row.outcome)")
    }
    rule()
    print("approval prompts raised in total: \(prompts.count) — \(prompts.map(\.op.rawValue).joined(separator: ", "))")
    print("UNEXPECTED results: \(unexpectedCount)")
    print("what was NOT demonstrated: a real language model calling these tools. No pi")
    print("provider is logged in, so STEP 4's caller is a fake pi that speaks the real")
    print("rpc protocol; every other step is a direct dispatch, which is the same")
    print("function the bridge calls.")
    rule()
}

/// A fake `pi --mode rpc`. It answers the runner's handshake and prompts, and on
/// a prompt carrying `BRIDGE_DEMO` it makes ONE real host tool call the way
/// `continuum-workspace-tools.ts` does: `ctx.ui.input(<envelope>)` surfaces as an
/// `extension_ui_request` frame, and pi resolves the tool's promise when the
/// client writes `extension_ui_response` with the same id. Deliberately mirrors
/// `WorkspaceAPIPiBridgeChecks`'s fake (a second file cannot import its `private`
/// source) — no model, no auth, no network.
private let workspaceAPIDemoFakePiSource = #"""
#!/usr/bin/env python3
import json, os, sys, threading, time

cwd = os.getcwd()
emit_lock = threading.Lock()
state_lock = threading.Lock()
pending = {}


def emit(obj):
    with emit_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def log(name, line):
    with state_lock:
        with open(os.path.join(cwd, name), "a") as handle:
            handle.write(line + "\n")


def bridge_call():
    tool_call_id = "demo-open-call"
    payload = {"relativePath": "notes.md",
               "presentation": {"camera": "preserve"},
               "idempotencyKey": "demo-open-1"}
    envelope = json.dumps({"schema": "array.workspace.v1", "kind": "request",
                           "requestId": tool_call_id, "op": "artifact.open",
                           "payload": payload})
    emit({"type": "tool_execution_start", "toolCallId": tool_call_id,
          "toolName": "array_open_document", "args": payload})
    req_id = "pi-ui-1"
    event = threading.Event()
    with state_lock:
        pending[req_id] = {"event": event, "value": None}
    emit({"type": "extension_ui_request", "id": req_id, "method": "input",
          "title": envelope, "timeout": 45000})
    event.wait(45)
    with state_lock:
        entry = pending.pop(req_id, None)
    value = entry["value"] if entry else None
    if value is None:
        value = json.dumps({"schema": "array.workspace.v1", "requestId": tool_call_id,
                            "status": "error",
                            "error": {"code": "outcome_unknown", "message": "bridge timeout"}})
    os.makedirs(os.path.join(cwd, "tool-results"), exist_ok=True)
    with open(os.path.join(cwd, "tool-results", tool_call_id + ".json"), "w") as handle:
        handle.write(value)
    try:
        details = json.loads(value)
    except Exception:
        details = {}
    emit({"type": "tool_execution_end", "toolCallId": tool_call_id,
          "toolName": "array_open_document",
          "result": {"content": [{"type": "text", "text": value}], "details": details},
          "isError": False})


def handle(cmd):
    kind = cmd.get("type")
    if kind == "extension_ui_response":
        with state_lock:
            entry = pending.get(cmd.get("id"))
            if entry is not None:
                entry["value"] = cmd.get("value")
                entry["event"].set()
        log("ui-responses.log" if entry is not None else "unknown-ui-responses.log",
            str(cmd.get("id")))
        return
    log("received.log", str(kind))
    if kind == "prompt":
        message = json.dumps(cmd.get("message") or cmd.get("prompt") or "")
        log("prompts.log", message)
        emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
        emit({"type": "agent_start"})
        emit({"type": "turn_start"})
        if "BRIDGE_DEMO" in message:
            bridge_call()
        emit({"type": "turn_end"})
        emit({"type": "agent_end", "willRetry": False})
        emit({"type": "agent_settled"})
    elif kind == "abort":
        emit({"type": "response", "id": cmd.get("id"), "command": "abort", "success": True})
    else:
        emit({"type": "response", "id": cmd.get("id"), "command": kind, "success": True, "data": {}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    threading.Thread(target=handle, args=(obj,), daemon=True).start()

time.sleep(0.3)
"""#
