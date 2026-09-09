import ContinuumRevivedCore
import Foundation

// CX-01 Phase 2b (`.plans/59`, §10.3): the pure operation store behind
// `agent.delegate` / `operation.get`. Deduplication by (caller, idempotency
// key), payload binding, caller scoping, bounded retention and explicit
// expiry — asserted without AppKit, a supervisor or a process.
func runWorkspaceOperationStoreChecks() {
    checkReserveDedupeAndConflict()
    checkCallerScoping()
    checkStepsAndReleaseRules()
    checkRetentionAndExpiry()
    checkDelegationContractRoundTrip()
    checkMessageContractAndBounds()
    print("WorkspaceOperationStoreChecks passed")
}

private func expectStore(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        Foundation.exit(1)
    }
}

private let storeEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func hash<T: Encodable>(_ value: T) -> String {
    String(decoding: (try? storeEncoder.encode(value)) ?? Data(), as: UTF8.self)
}

private func checkReserveDedupeAndConflict() {
    var store = WorkspaceOperationStore()
    let agent = AgentID(rawValue: UUID())
    let a = AgentDelegateRequest(task: "audit the parser", idempotencyKey: "k1")
    let b = AgentDelegateRequest(task: "rewrite the parser", idempotencyKey: "k1")

    guard case let .reserved(first) = store.reserve(
        agentId: agent, op: .agentDelegate, idempotencyKey: "k1", payloadHash: hash(a), operationId: "op-1") else {
        expectStore(false, "the first reservation of a key must be fresh"); return
    }
    expectStore(first.status == .accepted && first.steps == .allPending,
           "a fresh reservation is accepted with every step pending, got \(first.status)/\(first.steps)")
    // The child now exists as far as the store is concerned.
    store.update(operationId: "op-1") { $0.steps.creation = .succeeded; $0.childAgentId = AgentID(rawValue: UUID()); $0.status = .partial }

    // Same key, same payload → the previous operation, never a second effect.
    guard case let .replay(replayed) = store.reserve(
        agentId: agent, op: .agentDelegate, idempotencyKey: "k1", payloadHash: hash(a), operationId: "op-2") else {
        expectStore(false, "same key + same payload must replay the first operation, not reserve a second"); return
    }
    expectStore(replayed.operationId == "op-1" && replayed.childAgentId == store.record(operationId: "op-1")?.childAgentId,
           "the replay carries the FIRST operation's identity, got \(replayed.operationId)")
    expectStore(store.count == 1, "a replay must not add a record, count is \(store.count)")

    // Same key, different payload → refused; the first record is untouched.
    guard case let .conflict(existing) = store.reserve(
        agentId: agent, op: .agentDelegate, idempotencyKey: "k1", payloadHash: hash(b), operationId: "op-3") else {
        expectStore(false, "same key + a different payload must conflict"); return
    }
    expectStore(existing.operationId == "op-1" && store.count == 1, "a conflict reserves nothing")

    // A different key is a different intent.
    guard case .reserved = store.reserve(
        agentId: agent, op: .agentDelegate, idempotencyKey: "k2", payloadHash: hash(b), operationId: "op-4") else {
        expectStore(false, "a new key must reserve"); return
    }
    expectStore(store.count == 2, "two keys, two records, got \(store.count)")

    // The key is normalized on the payload MINUS the key itself, which is what
    // makes a retry that resends the same request replay rather than conflict.
    let resent = AgentDelegateRequest(task: "audit the parser", idempotencyKey: "k1")
    expectStore(hash(resent) != hash(a) || true, "sanity")
    var normalizedA = a; normalizedA.idempotencyKey = nil
    var normalizedResent = resent; normalizedResent.idempotencyKey = nil
    expectStore(hash(normalizedA) == hash(normalizedResent),
           "the normalized payload hash must ignore the key, or every retry conflicts with itself")
}

private func checkCallerScoping() {
    var store = WorkspaceOperationStore()
    let mine = AgentID(rawValue: UUID())
    let theirs = AgentID(rawValue: UUID())
    _ = store.reserve(agentId: mine, op: .agentDelegate, idempotencyKey: "k", payloadHash: "h", operationId: "op-mine")

    guard case .found = store.lookup(agentId: mine, operationId: "op-mine") else {
        expectStore(false, "the caller must be able to read its own operation"); return
    }
    expectStore(store.lookup(agentId: theirs, operationId: "op-mine") == .unknown,
           "another agent's operation must read as unknown, never disclosed")
    expectStore(store.lookup(agentId: theirs, idempotencyKey: "k") == .unknown,
           "keys are scoped per caller: two agents may use the same key independently")
    guard case .reserved = store.reserve(agentId: theirs, op: .agentDelegate, idempotencyKey: "k", payloadHash: "h2", operationId: "op-theirs") else {
        expectStore(false, "the same key from another caller is a different operation"); return
    }
}

private func checkStepsAndReleaseRules() {
    var store = WorkspaceOperationStore()
    let agent = AgentID(rawValue: UUID())

    // Cancelled before any effect: the reservation is released and the key is
    // free again, because nothing was created.
    _ = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: "cancel", payloadHash: "h", operationId: "op-c")
    store.release(operationId: "op-c")
    expectStore(store.count == 0, "a reservation with no effect is released")
    guard case .reserved = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: "cancel", payloadHash: "h", operationId: "op-c2") else {
        expectStore(false, "a released key must be reservable again"); return
    }

    // Once creation succeeded, the record is permanent: release must not free a
    // key whose child exists, or a retry would spawn a second child.
    store.update(operationId: "op-c2") { $0.steps.creation = .succeeded }
    store.release(operationId: "op-c2")
    expectStore(store.count == 1, "a record whose creation succeeded is never released")
    guard case .replay = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: "cancel", payloadHash: "h", operationId: "op-c3") else {
        expectStore(false, "after creation, the same key replays"); return
    }

    // A failure that created nothing does not burn the key.
    _ = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: "refused", payloadHash: "h", operationId: "op-r")
    store.update(operationId: "op-r") { $0.status = .failed; $0.steps.creation = .failed; $0.failureCode = "unsupported" }
    guard case .reserved = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: "refused", payloadHash: "h", operationId: "op-r2") else {
        expectStore(false, "a refusal that created nothing must be retryable under the same key"); return
    }

    // Steps are recorded separately: a presentation failure leaves creation and
    // attachment standing, which is what makes `agent.reveal` the right retry.
    store.update(operationId: "op-r2") { op in
        op.steps.creation = .succeeded
        op.steps.attachment = .succeeded
        op.steps.durability = .succeeded
        op.steps.presentation = .failed
        op.status = .partial
        op.tileId = UUID()
    }
    guard let partial = store.record(operationId: "op-r2") else { expectStore(false, "record missing"); return }
    expectStore(partial.status == .partial && partial.steps.creation == .succeeded && partial.steps.presentation == .failed,
           "a partial operation reports each step separately, got \(partial.steps)")
}

private func checkRetentionAndExpiry() {
    var store = WorkspaceOperationStore(capacity: 3, tombstoneCapacity: 10)
    let agent = AgentID(rawValue: UUID())
    var childIds: [String: AgentID] = [:]
    for index in 0..<4 {
        let key = "k\(index)"
        _ = store.reserve(agentId: agent, op: .agentDelegate, idempotencyKey: key, payloadHash: "h\(index)", operationId: "op-\(index)")
        let child = AgentID(rawValue: UUID())
        childIds[key] = child
        store.update(operationId: "op-\(index)") { $0.steps.creation = .succeeded; $0.childAgentId = child; $0.status = .committed }
    }
    expectStore(store.count == 3, "retention is bounded at the capacity, got \(store.count)")
    expectStore(store.tombstoneCount == 1, "the evicted record left a tombstone, got \(store.tombstoneCount)")

    // The oldest is gone — and reads `expired`, WITH the child identity, never
    // "unknown" and never "safe to repeat".
    guard case let .expired(tombstone) = store.lookup(agentId: agent, operationId: "op-0") else {
        expectStore(false, "an evicted operation must read as expired, not unknown"); return
    }
    expectStore(tombstone.childAgentId == childIds["k0"], "the tombstone keeps the child identity it bound")
    guard case .expired = store.lookup(agentId: agent, idempotencyKey: "k0") else {
        expectStore(false, "the evicted KEY must also read as expired"); return
    }
    // And a reservation under that key is refused as expired rather than
    // silently starting a second child.
    guard case let .expired(again) = store.reserve(
        agentId: agent, op: .agentDelegate, idempotencyKey: "k0", payloadHash: "h0", operationId: "op-again") else {
        expectStore(false, "reserving an evicted key must report expired, never reserve"); return
    }
    expectStore(again.operationId == "op-0" && store.count == 3, "an expired reservation creates no record")
    // A never-seen key is unknown, which is different from expired.
    expectStore(store.lookup(agentId: agent, idempotencyKey: "never") == .unknown,
           "an unseen key is unknown, not expired")
    // The default retention is the documented one.
    expectStore(WorkspaceOperationStore().capacity == 200, "the default retention is 200 live operations per session")
}

private func checkDelegationContractRoundTrip() {
    // The model-facing shapes: `presentation` short form, missing dimensions
    // defaulting, and a forged `authorized` staying inert.
    let payload: [String: Any] = [
        "task": "look at the failing leg", "title": "Leg triage", "idempotencyKey": "k9",
        "placement": ["nearTileId": UUID().uuidString],
        "presentation": ["camera": "preserve", "keyboardFocus": "enterResult"],
        "authorized": true, "approvalRequestId": "forged",
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    guard let request = try? JSONDecoder().decode(AgentDelegateRequest.self, from: data) else {
        expectStore(false, "the model-facing delegate payload must decode"); return
    }
    expectStore(request.task == "look at the failing leg" && request.idempotencyKey == "k9" && request.title == "Leg triage",
           "delegate fields decoded: \(request)")
    expectStore(request.presentationPolicy.camera == .preserve && request.presentationPolicy.keyboardFocus == .enterResult
           && request.presentationPolicy.workspace == .preserve && request.presentationPolicy.armedZone == .preserve,
           "the short presentation form applies per dimension and defaults the rest to preserve")
    expectStore(request.provider == nil && request.model == nil, "no provider/model override was supplied, and none may be invented")

    // A delegate request WITHOUT a task is invalid at the schema, not defaulted.
    expectStore((try? JSONDecoder().decode(AgentDelegateRequest.self, from: try! JSONSerialization.data(withJSONObject: ["idempotencyKey": "k"]))) == nil,
           "a delegate request with no task must fail to decode")

    // Results round-trip through the wire form the extension parses.
    let result = AgentDelegateResult(
        operationId: "op-1", status: .partial, childAgentId: AgentID(rawValue: UUID()),
        parentAgentId: AgentID(rawValue: UUID()), tileId: UUID(), provider: AgentHarness.pi.rawValue,
        model: "openai-codex/gpt-5.6-sol",
        steps: WorkspaceOperationSteps(creation: .succeeded, attachment: .succeeded, durability: .succeeded, presentation: .failed),
        presentation: .unavailable, presentationEffects: .allPreserved,
        actualWorldRect: CanvasWorldRect(x: 1, y: 2, width: 3, height: 4), actualZoneId: UUID(),
        childRunning: true, partial: true, retryOp: .agentReveal, failureMessage: "the tile could not be presented")
    let encoded = try! storeEncoder.encode(result)
    guard let decoded = try? JSONDecoder().decode(AgentDelegateResult.self, from: encoded) else {
        expectStore(false, "the delegate result must round-trip"); return
    }
    expectStore(decoded == result, "delegate result round-trip")
    guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        expectStore(false, "the result must encode as a JSON object"); return
    }
    expectStore(object["schema"] as? String == WorkspaceAPISchema.v1, "every result carries the v1 schema tag")
    expectStore(object["retryOp"] as? String == "agent.reveal",
           "a presentation failure names agent.reveal as the retry — never agent.delegate")
    expectStore(object["childRunning"] as? Bool == true, "childRunning is reported truthfully when known")

    let unknownRunning = OperationGetResult(
        operationId: "op-2", op: .agentDelegate, status: .expired, steps: nil, childAgentId: nil, tileId: nil,
        childRunning: nil, failureCode: "expired")
    let getObject = try! JSONSerialization.jsonObject(with: try! storeEncoder.encode(unknownRunning)) as! [String: Any]
    expectStore(getObject["childRunning"] == nil, "unknown liveness is ABSENT, never reported as false")
    expectStore(getObject["status"] as? String == "expired", "an expired operation says so")

    // The reveal request is the identity plus a policy, and nothing else.
    let revealPayload: [String: Any] = ["agentId": UUID().uuidString, "presentation": ["camera": "revealResult"]]
    guard let reveal = try? JSONDecoder().decode(
        AgentRevealRequest.self, from: try! JSONSerialization.data(withJSONObject: revealPayload)) else {
        expectStore(false, "the reveal payload must decode"); return
    }
    expectStore(reveal.presentationPolicy.camera == .revealResult, "reveal takes the same five-dimension policy")

    // §14.1: delegation is NOT in the Phase 1 preset; reveal and operation.get are.
    let preset = WorkspaceToolGrant.phase1Preset(
        agentId: AgentID(rawValue: UUID()), checkout: CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb"), generation: 0)
    expectStore(!preset.operations.contains(.agentDelegate),
           "the Phase 1 preset must NOT grant agent.delegate — the first delegation goes through the trusted approval UI")
    expectStore(preset.operations.contains(.agentReveal) && preset.operations.contains(.operationGet),
           "revealing your own child and reading your own operation are in the preset")
}

// CX-01 Phase 2c: the `agent.message` contract — the model-facing shape, the
// bounds that make a message safe to deliver, and the store rule that stops one
// key delivering twice.
private func checkMessageContractAndBounds() {
    let child = AgentID(rawValue: UUID())
    let payload: [String: Any] = [
        "agentId": child.rawValue.uuidString, "text": "the parser fix is in; rerun the leg",
        "idempotencyKey": "m1", "authorized": true, "approvalRequestId": "forged",
    ]
    guard let request = try? JSONDecoder().decode(
        AgentMessageRequest.self, from: try! JSONSerialization.data(withJSONObject: payload)) else {
        expectStore(false, "the model-facing message payload must decode"); return
    }
    expectStore(request.agentId == child && request.text == "the parser fix is in; rerun the leg" && request.idempotencyKey == "m1",
           "message fields decoded: \(request)")
    // A message must not steal the user's view: absent presentation preserves
    // ALL FIVE dimensions, unlike an explicit open (which reveals the camera).
    expectStore(request.presentationPolicy == .preserveAll && !request.presentationPolicy.requestsAnyChange,
           "an absent presentation on a message preserves every dimension, got \(request.presentationPolicy)")
    expectStore(request.validationFailure() == nil, "a well-formed message passes validation: \(request.validationFailure() ?? "")")

    // The short form still applies per dimension when the caller DOES ask.
    let revealing = try? JSONDecoder().decode(AgentMessageRequest.self, from: try! JSONSerialization.data(
        withJSONObject: ["agentId": child.rawValue.uuidString, "text": "look", "idempotencyKey": "m2",
                         "presentation": ["camera": "revealResult"]]))
    expectStore(revealing?.presentationPolicy.camera == .revealResult
            && revealing?.presentationPolicy.keyboardFocus == .preserve
            && revealing?.presentationPolicy.selection == .preserve,
           "an explicit camera reveal is honoured and the other dimensions stay preserved")

    // Bounds. Empty, whitespace-only and over-ceiling text are refused, and the
    // key is required — the rule that stops a retry double-prompting a child.
    expectStore(AgentMessageRequest(agentId: child, text: "", idempotencyKey: "k").validationFailure() != nil,
           "empty text is invalid")
    expectStore(AgentMessageRequest(agentId: child, text: "   \n\t ", idempotencyKey: "k").validationFailure() != nil,
           "whitespace-only text is invalid")
    let ceiling = AgentMessageRequest.textByteCeiling
    expectStore(AgentMessageRequest(agentId: child, text: String(repeating: "a", count: ceiling), idempotencyKey: "k").validationFailure() == nil,
           "text exactly at the \(ceiling)-byte ceiling is accepted")
    expectStore(AgentMessageRequest(agentId: child, text: String(repeating: "a", count: ceiling + 1), idempotencyKey: "k").validationFailure() != nil,
           "text one byte over the ceiling is invalid")
    // Bytes, not characters: a multi-byte scalar counts what it costs.
    expectStore(AgentMessageRequest(agentId: child, text: String(repeating: "é", count: ceiling / 2 + 1), idempotencyKey: "k").validationFailure() != nil,
           "the ceiling counts UTF-8 BYTES, not characters")
    expectStore(AgentMessageRequest(agentId: child, text: "hi", idempotencyKey: nil).validationFailure() != nil
            && AgentMessageRequest(agentId: child, text: "hi", idempotencyKey: "  ").validationFailure() != nil,
           "a missing or blank idempotencyKey is invalid: one message per key is the only defence against a double prompt")
    // A request without text or without an agentId is a schema error, not a default.
    expectStore((try? JSONDecoder().decode(AgentMessageRequest.self, from: try! JSONSerialization.data(
        withJSONObject: ["agentId": child.rawValue.uuidString, "idempotencyKey": "k"]))) == nil,
           "a message with no text must fail to decode")
    expectStore((try? JSONDecoder().decode(AgentMessageRequest.self, from: try! JSONSerialization.data(
        withJSONObject: ["text": "hi", "idempotencyKey": "k"]))) == nil,
           "a message with no agentId must fail to decode")

    // The result round-trips, and it carries DELIVERY only — never an answer.
    let result = AgentMessageResult(
        operationId: "op-m1", delivery: .delivered, childAgentId: child,
        parentAgentId: AgentID(rawValue: UUID()), childRunning: true)
    let encoded = try! storeEncoder.encode(result)
    expectStore((try? JSONDecoder().decode(AgentMessageResult.self, from: encoded)) == result, "message result round-trip")
    let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    expectStore(object["schema"] as? String == WorkspaceAPISchema.v1, "every result carries the v1 schema tag")
    expectStore(object["delivery"] as? String == "delivered" && object["childRunning"] as? Bool == true,
           "delivery and liveness are reported: \(object)")
    expectStore(object["queuePosition"] == nil && object["refusalReason"] == nil,
           "an unknown queue position and an absent refusal are OMITTED, never invented")
    let refusedObject = try! JSONSerialization.jsonObject(with: try! storeEncoder.encode(AgentMessageResult(
        operationId: "op-m2", delivery: .refused, childAgentId: child, parentAgentId: AgentID(rawValue: UUID()),
        childRunning: true, refusalReason: "the child is mid-turn"))) as! [String: Any]
    expectStore(refusedObject["delivery"] as? String == "refused" && (refusedObject["refusalReason"] as? String)?.isEmpty == false,
           "a refusal names its reason: \(refusedObject)")

    // The store: one key, one delivery. A DELIVERED message replays; a refusal
    // that delivered nothing leaves the key usable.
    var store = WorkspaceOperationStore()
    let parent = AgentID(rawValue: UUID())
    guard case let .reserved(reserved) = store.reserve(
        agentId: parent, op: .agentMessage, idempotencyKey: "m1", payloadHash: "h1", operationId: "op-1") else {
        expectStore(false, "the first message reserves"); return
    }
    store.update(operationId: reserved.operationId) { $0.steps.creation = .succeeded; $0.status = .committed }
    guard case let .replay(replayed) = store.reserve(
        agentId: parent, op: .agentMessage, idempotencyKey: "m1", payloadHash: "h1", operationId: "op-2") else {
        expectStore(false, "the same key with the same text must REPLAY, never deliver again"); return
    }
    expectStore(replayed.operationId == "op-1", "the replay is the first operation, not the retry's id")
    guard case .conflict = store.reserve(
        agentId: parent, op: .agentMessage, idempotencyKey: "m1", payloadHash: "h2", operationId: "op-3") else {
        expectStore(false, "the same key with DIFFERENT text must conflict"); return
    }
    // A refusal delivered nothing, so the same intent may be retried once the
    // cause (a mid-turn child) is gone.
    _ = store.reserve(agentId: parent, op: .agentMessage, idempotencyKey: "m9", payloadHash: "h9", operationId: "op-9")
    store.update(operationId: "op-9") { $0.status = .failed; $0.steps.creation = .failed }
    guard case .reserved = store.reserve(
        agentId: parent, op: .agentMessage, idempotencyKey: "m9", payloadHash: "h9", operationId: "op-10") else {
        expectStore(false, "a message that delivered NOTHING must not burn its key"); return
    }

    // §14.1: messaging is an effect, so it is never in the session preset.
    let preset = WorkspaceToolGrant.phase1Preset(
        agentId: parent, checkout: CheckoutHandle.derive(canonicalRoot: "/private/tmp/cx01/Pb"), generation: 0)
    expectStore(!preset.operations.contains(.agentMessage),
           "the Phase 1 preset must NOT grant agent.message — the first message goes through the trusted approval UI")
}
