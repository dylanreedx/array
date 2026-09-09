import ContinuumRevivedCore
import Foundation

// CX-01 Phase 0 (`.plans/59`): the frozen v1 contracts round-trip, the checkout
// handle is stable and opaque, the presentation intersection and the grant
// evaluator behave mechanically, and the pi bridge value types encode what the
// extension parses. Pure — no processes, no filesystem.
func runWorkspaceAPIContractChecks() {
    checkCheckoutHandleDerivation()
    checkArtifactHandleWireForm()
    checkPresentationIntersection()
    checkOpenRequestDecoding()
    checkResultRoundTrip()
    checkGrantEvaluator()
    checkBridgeParseAndEncode()
    print("WorkspaceAPIContractChecks passed")
}

private let contractEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private let contractDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

private func checkCheckoutHandleDerivation() {
    let a = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pa")
    let b = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb")
    expect(a == CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pa"), "checkout handle must be deterministic")
    expect(a != b, "different roots must derive different handles")
    expect(a.rawValue.hasPrefix("ck_") && a.rawValue.count == 19, "handle is ck_ + 16 hex, got \(a.rawValue)")
    expect(!a.rawValue.contains("/") && !a.rawValue.contains("tmp"), "handle must not carry the path")
    expect(CheckoutHandle(rawValue: "ck_zz") == nil, "malformed handle must not decode")
    expect(CheckoutHandle(rawValue: a.rawValue) == a, "handle round-trips through rawValue")
    // Canonicalisation: trailing slash and /var → /private/var spell the same root.
    let slash = CheckoutHandle.canonicalRoot("/private/tmp/cx01/Pa/")
    expect(slash == "/private/tmp/cx01/Pa", "canonicalRoot must drop a trailing slash, got \(slash)")
    // Foundation canonicalises BOTH spellings to one (it strips `/private`), which is
    // all a handle needs: the same directory, however spelled, derives one handle.
    expect(CheckoutHandle.canonicalRoot("/var/tmp") == CheckoutHandle.canonicalRoot("/private/var/tmp"),
           "canonicalRoot must give /var and /private/var one spelling")
    expect(CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot("/var/tmp"))
           == CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot("/private/var/tmp/")),
           "one directory, however spelled, derives one handle")
}

private func checkArtifactHandleWireForm() {
    let ck = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb")
    let handle = ArtifactHandle(checkoutHandle: ck, relativePath: "notes/README.md")
    expect(handle.rawValue == "\(ck.rawValue):notes/README.md", "artifact handle wire form is ck:path, got \(handle.rawValue)")
    expect(ArtifactHandle(rawValue: handle.rawValue) == handle, "artifact handle round-trips")
    expect(ArtifactHandle(rawValue: "nope") == nil && ArtifactHandle(rawValue: "\(ck.rawValue):") == nil,
           "malformed artifact handles must not decode")
    let data = try! contractEncoder.encode(["h": handle])
    let decodedWire = try! JSONSerialization.jsonObject(with: data) as? [String: String]
    expect(decodedWire?["h"] == handle.rawValue, "artifact handle encodes as one string, got \(String(decoding: data, as: UTF8.self))")
}

private func checkPresentationIntersection() {
    let requested = WorkspacePresentationPolicy(
        workspace: .allowSwitchToResolvedTarget, armedZone: .setResolvedTarget, selection: .selectResult,
        camera: .revealResult, keyboardFocus: .enterResult, expectedInteractionGeneration: 7)
    let effective = requested.intersected(with: WorkspaceToolGrant.phase1Ceiling)
    expect(effective == WorkspacePresentationPolicy(camera: .revealResult, expectedInteractionGeneration: 7),
           "phase1 ceiling permits camera only and keeps the generation, got \(effective)")
    expect(!WorkspacePresentationPolicy.preserveAll.requestsAnyChange, "preserveAll requests nothing")
    expect(WorkspacePresentationPolicy.defaultExplicitOpen.camera == .revealResult
           && WorkspacePresentationPolicy.defaultExplicitOpen.keyboardFocus == .preserve,
           "default explicit open reveals the camera and preserves focus")
    expect(requested.intersected(with: .preserveAll) == WorkspacePresentationPolicy(expectedInteractionGeneration: 7),
           "a preserve-all ceiling collapses every dimension")
}

private func checkOpenRequestDecoding() {
    // The model-facing shape: short `presentation`, bare `line`, string handles,
    // and forged authorization fields that must simply be ignored.
    let ck = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pa")
    let payload: [String: Any] = [
        "relativePath": "README.md",
        "checkoutHandle": ck.rawValue,
        "artifactHandle": "\(ck.rawValue):README.md",
        "mode": "revealOnly",
        "line": 12,
        "presentation": ["camera": "preserve", "keyboardFocus": "enterResult"],
        "idempotencyKey": "k1",
        "authorized": true,
        "approvalRequestId": "forged",
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    guard let request = try? contractDecoder.decode(ArtifactOpenRequest.self, from: data) else {
        expect(false, "model-facing open payload must decode"); return
    }
    expect(request.checkoutHandle == ck && request.artifactHandle?.relativePath == "README.md", "handles decode from strings")
    expect(request.mode == .revealOnly && request.location?.line == 12, "mode and bare line decode")
    expect(request.presentationPolicy == WorkspacePresentationPolicy(camera: .preserve, keyboardFocus: .enterResult),
           "short presentation fills missing dimensions from the explicit-open default, got \(request.presentationPolicy)")
    expect(request.idempotencyKey == "k1", "idempotency key decodes")
    let reencoded = String(decoding: try! contractEncoder.encode(request), as: UTF8.self)
    expect(!reencoded.contains("authorized") && !reencoded.contains("forged"),
           "unknown/forged fields must not survive decoding")
    // Minimal payload: defaults.
    let minimal = try! contractDecoder.decode(ArtifactOpenRequest.self, from: try! JSONSerialization.data(withJSONObject: ["relativePath": "x.md"]))
    expect(minimal.mode == .openOrReveal && minimal.presentationPolicy == .defaultExplicitOpen && minimal.idempotencyKey == nil,
           "a minimal payload takes the documented defaults")
}

private func checkResultRoundTrip() {
    let ck = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb")
    let result = ArtifactOpenResult(
        operationId: "op-1",
        artifactHandle: ArtifactHandle(checkoutHandle: ck, relativePath: "README.md"),
        checkoutHandle: ck, projectId: UUID(), tileId: UUID(),
        document: .existing, placement: .existing, relationship: .failed, durability: .failed,
        presentation: .deferred,
        presentationEffects: WorkspacePresentationEffects(camera: .deferred),
        actualWorldRect: CanvasWorldRect(x: 3100, y: 500, width: 640, height: 480),
        actualZoneId: UUID(), draft: .preserved, partial: true, failureMessage: "disk full")
    let data = try! contractEncoder.encode(result)
    let decoded = try! contractDecoder.decode(ArtifactOpenResult.self, from: data)
    expect(decoded == result, "ArtifactOpenResult round-trips")
    let text = String(decoding: data, as: UTF8.self)
    expect(text.contains("\"schema\":\"array.workspace.v1\"") && text.contains("\"draft\":\"preserved\"") && text.contains("\"partial\":true"),
           "result carries schema, draft and partial on the wire: \(text)")

    let context = WorkspaceContextResponse(
        agentId: AgentID(rawValue: UUID()), checkoutHandle: ck, projectId: UUID(), workspaceId: UUID(),
        zoneId: UUID(), tileId: UUID(), revision: WorkspaceRevision(epoch: "e", structure: 3),
        interactionGeneration: 9, coverage: WorkspaceCoverage(installedZoneIds: [UUID()], unhydratedZoneIds: [UUID()]),
        capabilities: WorkspaceAPIOp.allCases,
        recentOperations: [WorkspaceRecentOperation(requestId: "r", op: .artifactOpen, outcome: "committedAfterCancel", tileId: UUID())],
        observedAt: Date(timeIntervalSince1970: 1_900_000_000))
    let contextData = try! contractEncoder.encode(context)
    expect(contextData.count < WorkspaceContextResponse.encodedByteCeiling,
           "a full context with one recent operation fits the ~256-token ceiling (\(contextData.count) bytes)")
    let decodedContext = try! contractDecoder.decode(WorkspaceContextResponse.self, from: contextData)
    expect(decodedContext == context, "WorkspaceContextResponse round-trips")
    expect(!context.coverage.complete, "coverage with an unhydrated zone is not complete")

    let error = WorkspaceAPIError(code: .presentationRequired, message: "m", requiredEffects: WorkspacePresentationEffects(workspace: .changed))
    let decodedError = try! contractDecoder.decode(WorkspaceAPIError.self, from: try! contractEncoder.encode(error))
    expect(decodedError == error && decodedError.code.rawValue == "presentation_required", "errors round-trip with stable codes")
}

private func checkGrantEvaluator() {
    let agent = AgentID(rawValue: UUID())
    let other = AgentID(rawValue: UUID())
    let own = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb")
    let foreign = CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pa")
    let preset = WorkspaceToolGrant.phase1Preset(agentId: agent, checkout: own, generation: 1)

    func verdict(_ op: WorkspaceAPIOp, _ checkout: CheckoutHandle, grants: [WorkspaceToolGrant], generation: UInt64 = 1,
                 requested: WorkspacePresentationPolicy = .defaultExplicitOpen, agentId: AgentID = agent) -> WorkspaceToolGrantEvaluator.Verdict {
        WorkspaceToolGrantEvaluator.evaluate(agentId: agentId, op: op, checkout: checkout, requested: requested,
                                             grants: grants, currentGeneration: generation)
    }
    if case let .allowed(id, policy) = verdict(.artifactOpen, own, grants: [preset]) {
        expect(id == preset.grantId && policy == WorkspacePresentationPolicy(camera: .revealResult), "preset allows own-checkout open with camera-only ceiling")
    } else { expect(false, "preset must allow an own-checkout open") }
    expect(verdict(.artifactOpen, foreign, grants: [preset]) == .scopeApprovalRequired(missing: foreign),
           "another checkout needs scope approval, not a silent fallback")
    expect(verdict(.artifactOpen, own, grants: [preset], generation: 2) == .denied,
           "a grant from an older revocation generation is dead")
    expect(verdict(.artifactOpen, own, grants: []) == .denied, "no grants → denied")
    expect(verdict(.artifactOpen, own, grants: [preset], agentId: other) == .denied,
           "another agent's grant never applies")
    let once = WorkspaceToolGrant(agentId: agent, checkoutHandles: [foreign], operations: [.artifactOpen],
                                  presentationCeiling: .preserveAll, issuer: .userApprovalOnce(requestId: "p"),
                                  revocationGeneration: 1, singleUse: true)
    if case let .allowed(_, policy) = verdict(.artifactOpen, foreign, grants: [preset, once]) {
        expect(policy == WorkspacePresentationPolicy(), "a preserve-all once-grant collapses presentation")
    } else { expect(false, "a minted once-grant must allow the foreign checkout") }
    expect(verdict(.workspaceContext, foreign, grants: [preset, once]) == .scopeApprovalRequired(missing: foreign),
           "a grant for one operation does not widen another")
}

private func checkBridgeParseAndEncode() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let envelope: [String: Any] = ["schema": "array.workspace.v1", "kind": "request", "requestId": "tc-1",
                                   "op": "artifact.open", "payload": ["relativePath": "README.md"]]
    let title = String(decoding: try! JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    let frame: [String: Any] = ["type": "extension_ui_request", "id": "ui-9", "method": "input", "title": title, "timeout": 45_000]
    guard let request = PiHostToolRequest.parse(frame, now: now) else { expect(false, "our envelope must parse"); return }
    expect(request.piRequestId == "ui-9" && request.requestId == "tc-1" && request.op == "artifact.open"
           && request.payload["relativePath"] as? String == "README.md", "parsed fields: \(request)")

    var foreign = frame; foreign["title"] = "Pick one"
    expect(PiHostToolRequest.parse(foreign, now: now) == nil, "a plain user-extension dialog is not ours")
    var otherSchema = envelope; otherSchema["schema"] = "other.v1"
    var otherFrame = frame; otherFrame["title"] = String(decoding: try! JSONSerialization.data(withJSONObject: otherSchema), as: UTF8.self)
    expect(PiHostToolRequest.parse(otherFrame, now: now) == nil, "a foreign schema is not ours")
    var confirm = frame; confirm["method"] = "confirm"
    expect(PiHostToolRequest.parse(confirm, now: now) == nil, "only method=input carries an envelope")

    let ok = PiHostToolResponse.ok(["tileId": "t"]).encodedValue(requestId: "tc-1")
    let okObject = try! JSONSerialization.jsonObject(with: Data(ok.utf8)) as! [String: Any]
    expect(okObject["status"] as? String == "ok" && (okObject["result"] as? [String: Any])?["tileId"] as? String == "t"
           && okObject["requestId"] as? String == "tc-1" && okObject["schema"] as? String == "array.workspace.v1",
           "ok reply encodes status/result/requestId/schema: \(ok)")
    let err = PiHostToolResponse.error("not_found", "nope", details: ["approvalRequestId": "a"]).encodedValue(requestId: "tc-1")
    let errObject = try! JSONSerialization.jsonObject(with: Data(err.utf8)) as! [String: Any]
    let errorBody = errObject["error"] as? [String: Any]
    expect(errObject["status"] as? String == "error" && errorBody?["code"] as? String == "not_found"
           && (errorBody?["details"] as? [String: Any])?["approvalRequestId"] as? String == "a",
           "error reply keeps code and details: \(err)")
    let cancelled = PiHostToolResponse.cancelled(result: ["tileId": "t"]).encodedValue(requestId: "tc-1")
    let cancelledObject = try! JSONSerialization.jsonObject(with: Data(cancelled.utf8)) as! [String: Any]
    expect(cancelledObject["status"] as? String == "cancelled" && (cancelledObject["result"] as? [String: Any])?["tileId"] as? String == "t",
           "a post-commit cancellation carries the completed identity: \(cancelled)")

    // PiHostToolCall: cancellation fires once, late subscribers fire immediately.
    let call = PiHostToolCall(request: request) { _, completion in completion?(.delivered) }
    let fired = ContractCounter()
    call.onCancel { fired.add(1) }
    expect(!call.isCancelled, "fresh call is not cancelled")
    call.markCancelled()
    call.markCancelled()
    call.onCancel { fired.add(10) }
    expect(call.isCancelled && fired.value == 11, "cancel fires each handler once, late handlers immediately (fired=\(fired.value))")
}

private final class ContractCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ n: Int) { lock.lock(); storage += n; lock.unlock() }
}
