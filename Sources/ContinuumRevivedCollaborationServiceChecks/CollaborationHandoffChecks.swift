import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct HandoffCheckFailure: Error { let message: String }
private func handoffCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw HandoffCheckFailure(message: label) }
    print("PASS handoff HTTP: \(label)")
}
private func handoffRefuses(_ expected: Int, _ label: String, _ action: () async throws -> Void) async throws {
    do { try await action(); throw HandoffCheckFailure(message: "\(label) unexpectedly succeeded") }
    catch let error as CollaborationClientError {
        guard case .server(let code, _) = error, code == expected else { throw error }
        print("PASS handoff HTTP: \(label)")
    }
}

/// Actual A/B/C HTTP authorization, control CAS, current immutable context and
/// durable host claims. This suite does not instantiate any provider executor.
func runCollaborationHandoffChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-handoff-http-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 62, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: label)
        }
        let a = try await person("Source A"), b = try await person("Teammate B"), c = try await person("Excluded C")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let cc = try CollaborationAPI(baseURL: endpoint, credential: c.token, allowsInsecureLoopback: true)
        let state = try await aa.createArea(), area = state.document.id.rawValue
        let invite = try await aa.invite(area: area, request: .init(person: b.identity.person))
        _ = try await bb.accept(code: invite.code)
        let host = try await aa.registerHost()
        let object = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person,
            text: "Only touch the reviewed module boundary.")
        let rect = SharedArea.Rect(x: 40, y: -120, width: 400, height: 240)
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: 0, edits: [
            .admit(object, .init(id: .init(), object: object.id, rect: rect)),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 480, y: -120, width: 400, height: 240))), .context(context)
        ])))
        let generation = UUID()
        var control = try await aa.registerAgentHost(area: area, request: .init(epoch: 1, object: object.id, generation: generation))
        try handoffCheck(control.controller == a.identity.person && control.epoch == 1 && control.revision == 1,
            "only the original device registers its published source generation")
        try await tryRefuseHost()
        func makePrompt(_ value: Collaboration.AgentControlState, context chosen: SharedArea.Context? = nil, id: UUID = UUID()) -> Collaboration.AgentPromptRequest {
            let selected = chosen ?? context
            return .init(id: id, epoch: 1, controlRevision: value.revision, hostGeneration: generation, contextRevision: selected.id, text: "Implement this agreed boundary.")
        }
        try await tryRefuseUnhanded()
        func tryRefuseHost() async throws {
            try await handoffRefuses(403, "an editor cannot register another host's agent") {
                _ = try await bb.registerAgentHost(area: area, request: .init(epoch: 1, object: object.id, generation: UUID()))
            }
        }
        func tryRefuseUnhanded() async throws {
            try await handoffRefuses(404, "an excluded person cannot prompt the shared agent") {
                _ = try await cc.sendAgentPrompt(area: area, object: object.id.rawValue, request: makePrompt(control))
            }
        }
        func settle(_ receipt: Collaboration.AgentDispatchReceipt) async throws -> Collaboration.AgentDispatchReceipt {
            let claim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: receipt.command.hostGeneration)
            _ = try await aa.claimAgentDispatch(area: area, id: receipt.command.id, claim: claim)
            _ = try await aa.admitAgentDispatch(area: area, id: receipt.command.id, claim: claim)
            return try await aa.finishAgentDispatch(area: area, id: receipt.command.id, outcome: .init(claim: claim, phase: .accepted))
        }
        try await handoffRefuses(404, "excluded C learns no source-control state") { _ = try await cc.agentControl(area: area, object: object.id.rawValue) }
        // Full access: an editor prompts with no handoff and no agreement
        // revision, and the owner's own prompt queues behind it, in order.
        let unhanded = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: .init(epoch: 1,
            controlRevision: control.revision, hostGeneration: generation, text: "Teammate prompt, no handoff."))
        let ownerNext = try await aa.sendAgentPrompt(area: area, object: object.id.rawValue, request: .init(epoch: 1,
            controlRevision: control.revision, hostGeneration: generation, text: "Owner prompt after it."))
        let ordered = try await aa.pendingAgentDispatches(area: area, host: host.id.rawValue)
        try handoffCheck(unhanded.command.context == nil && unhanded.command.requester == b.identity
            && ordered.map(\.command.id) == [unhanded.command.id, ownerNext.command.id],
            "an editor prompts with no handoff or agreement revision, and two prompts queue in arrival order")
        try handoffCheck(unhanded.command.requesterName == "Teammate B" && unhanded.command.promptText.hasPrefix("From Teammate B\n")
            && !unhanded.command.promptText.contains(b.identity.person.rawValue.uuidString),
            "the service stamps the requester's display name: the prompt reads \"From Teammate B\", with no person id in the text")
        let settledUnhanded = try await settle(unhanded), settledOwner = try await settle(ownerNext)
        try handoffCheck(settledUnhanded.phase == .accepted && settledOwner.phase == .accepted,
            "both queued prompts are admitted; neither is dropped")
        let offer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: b.identity.person)
        let offerIntent = Collaboration.AgentControlMutation(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .offer(offer))
        control = try await aa.changeAgentControl(area: area, object: object.id.rawValue, request: offerIntent)
        let acceptance = Collaboration.AgentControlMutation(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .accept(offer: offer.id))
        control = try await bb.changeAgentControl(area: area, object: object.id.rawValue, request: acceptance)
        try handoffCheck(control.controller == b.identity.person && control.offer == nil, "only the invited recipient accepts the offered control revision")
        let ownerWhileHanded = try await aa.sendAgentPrompt(area: area, object: object.id.rawValue, request: makePrompt(control))
        try handoffCheck(try await settle(ownerWhileHanded).phase == .accepted,
            "handing over never locks the owner out of prompting their own agent")
        let firstPrompt = makePrompt(control)
        let first = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: firstPrompt)
        let duplicate = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: firstPrompt)
        try handoffCheck(first == duplicate && first.command.requester == b.identity && first.command.context == context,
            "duplicate prompt returns the original attributed immutable command")
        try await handoffRefuses(409, "a changed prompt cannot reuse an accepted command ID") {
            _ = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: .init(id: firstPrompt.id, epoch: 1,
                controlRevision: control.revision, hostGeneration: generation, contextRevision: context.id, text: "Different text"))
        }
        let claim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
        try await handoffRefuses(403, "recipient cannot impersonate the source host's claim") {
            _ = try await bb.claimAgentDispatch(area: area, id: first.command.id, claim: claim)
        }
        _ = try await aa.claimAgentDispatch(area: area, id: first.command.id, claim: claim)
        let newer = SharedArea.Context(id: .init(), object: agreement.id, parent: context.id, author: a.identity.person,
            text: "The current revision narrows the boundary further.")
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: 1, edits: [.context(newer)])))
        try await handoffRefuses(403, "host rechecks the latest agreement immediately before effect") {
            _ = try await aa.admitAgentDispatch(area: area, id: first.command.id, claim: claim)
        }
        _ = try await aa.finishAgentDispatch(area: area, id: first.command.id, outcome: .init(claim: claim, phase: .refused))
        let second = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: makePrompt(control, context: newer))
        let claim2 = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
        _ = try await aa.claimAgentDispatch(area: area, id: second.command.id, claim: claim2)
        let admission = try await aa.admitAgentDispatch(area: area, id: second.command.id, claim: claim2)
        try handoffCheck(admission.phase == .dispatching, "current target and context produce a durable admission before any provider call")
        let accepted = try await aa.finishAgentDispatch(area: area, id: second.command.id, outcome: .init(claim: claim2, phase: .accepted))
        try handoffCheck(accepted.phase == .accepted && accepted.command.requester.person == b.identity.person,
            "host outcome preserves the actual authenticated human attribution")
        let restarted = try CollaborationStore(path: path, masterKey: key)
        let recovered = try await restarted.agentDispatchReceipt(token: b.token, area: area, id: second.command.id)
        try handoffCheck(recovered == accepted, "service reconstruction retains accepted handoff receipts")
        control = try await aa.changeAgentControl(area: area, object: object.id.rawValue,
            request: .init(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .reclaim))
        _ = try await bb.changeAgentControl(area: area, object: object.id.rawValue, request: acceptance)
        let afterOldReceipt = try await aa.agentControl(area: area, object: object.id.rawValue)
        try handoffCheck(afterOldReceipt == control && control.controller == a.identity.person,
            "old acceptance receipt cannot take control back after the owner reclaimed it")
        let acrossReclaim = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: .init(epoch: 1,
            controlRevision: control.revision - 1, hostGeneration: generation, text: "Sent before the reclaim reached me."))
        try handoffCheck(try await settle(acrossReclaim).phase == .accepted,
            "a control change between composing and sending does not refuse a member's prompt")
        let nextOffer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: b.identity.person)
        control = try await aa.changeAgentControl(area: area, object: object.id.rawValue,
            request: .init(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .offer(nextOffer)))
        control = try await bb.changeAgentControl(area: area, object: object.id.rawValue,
            request: .init(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .accept(offer: nextOffer.id)))
        let queuedBeforeRemoval = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: makePrompt(control, context: newer))
        try await aa.removeMember(area: area, person: b.identity.person.rawValue, epoch: 1)
        let pending = try await aa.pendingAgentDispatches(area: area, host: host.id.rawValue)
        let refused = try await aa.agentDispatchReceipt(area: area, id: queuedBeforeRemoval.command.id)
        try handoffCheck(pending.isEmpty && refused.phase == .refused, "removed teammate's queued work is refused before host dispatch")
        try await handoffRefuses(404, "removed teammate cannot recover receipt content") { _ = try await bb.agentDispatchReceipt(area: area, id: second.command.id) }
        let reset = try await aa.registerAgentHost(area: area, request: .init(epoch: 2, object: object.id, generation: generation))
        try handoffCheck(reset.controller == a.identity.person && reset.revision > control.revision && reset.epoch == 2,
            "membership epoch change requires renewed handoff consent")
        let changedGeneration = try await aa.registerAgentHost(area: area, request: .init(epoch: 2, object: object.id, generation: UUID()))
        try handoffCheck(changedGeneration.controller == a.identity.person && changedGeneration.hostGeneration != generation,
            "new source generation cannot inherit a retired control grant")
        func sourcePrompt() -> Collaboration.AgentPromptRequest {
            .init(epoch: 2, controlRevision: changedGeneration.revision, hostGeneration: changedGeneration.hostGeneration,
                contextRevision: newer.id, text: "Withdraw this explicit shared request before admission.")
        }
        let withdrawnQueued = try await aa.sendAgentPrompt(area: area, object: object.id.rawValue, request: sourcePrompt())
        let withdrawnClaimed = try await aa.sendAgentPrompt(area: area, object: object.id.rawValue, request: sourcePrompt())
        let withdrawnAttempt = try await aa.sendAgentPrompt(area: area, object: object.id.rawValue, request: sourcePrompt())
        let withdrawnClaim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: changedGeneration.hostGeneration)
        let attemptedClaim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: changedGeneration.hostGeneration)
        _ = try await aa.claimAgentDispatch(area: area, id: withdrawnClaimed.command.id, claim: withdrawnClaim)
        _ = try await aa.claimAgentDispatch(area: area, id: withdrawnAttempt.command.id, claim: attemptedClaim)
        _ = try await aa.admitAgentDispatch(area: area, id: withdrawnAttempt.command.id, claim: attemptedClaim)
        let beforeWithdrawal = try await aa.state(area: area)
        _ = try await aa.apply(area: area, mutation: .init(epoch: 2, command: .init(area: state.document.id,
            expectedRevision: beforeWithdrawal.document.revision, edits: [.remove(object.id)])))
        // No pending-host poll is made: withdrawal itself must resolve these
        // receipts before that source disappears from the app's host bindings.
        let queuedAfterWithdrawal = try await aa.agentDispatchReceipt(area: area, id: withdrawnQueued.command.id)
        let claimedAfterWithdrawal = try await aa.agentDispatchReceipt(area: area, id: withdrawnClaimed.command.id)
        let admissionAfterWithdrawal = try await aa.admitAgentDispatch(area: area, id: withdrawnClaimed.command.id, claim: withdrawnClaim)
        try handoffCheck(queuedAfterWithdrawal.phase == .refused && claimedAfterWithdrawal.phase == .refused
            && admissionAfterWithdrawal.phase == .refused,
            "unpublishing atomically resolves queued/claimed receipts and cannot admit provider work without another host poll")
        let attemptingAfterWithdrawal = try await aa.agentDispatchReceipt(area: area, id: withdrawnAttempt.command.id)
        try handoffCheck(attemptingAfterWithdrawal.phase == .dispatching,
            "unpublishing preserves an already admitted attempt's honest unresolved outcome")
        let reportedAfterWithdrawal = try await aa.finishAgentDispatch(area: area, id: withdrawnAttempt.command.id,
            outcome: .init(claim: attemptedClaim, phase: .uncertain))
        try handoffCheck(reportedAfterWithdrawal.phase == .uncertain,
            "original host can report interruption uncertainty after its source was unpublished")
        try await server.stop()
        print("Collaboration handoff HTTP checks passed: A/B/C, full-access prompting in arrival order, explicit offer/accept as a courtesy, immutable context, current admission, retries, revocation and service restart; no provider execution.")
    } catch { try? await server.stop(); throw error }
}
