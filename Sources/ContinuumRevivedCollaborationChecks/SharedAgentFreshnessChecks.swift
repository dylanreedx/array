import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct FreshnessCheckFailure: Error { let message: String }
private func freshnessCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw FreshnessCheckFailure(message: label) }
    print("PASS freshness: \(label)")
}

/// COL-14. Two agents on one owning host receive different agreement revisions
/// through the real HTTP service and host dispatcher; edits, a refused resend,
/// relaunch and a rebind must each leave every agent's baseline honest.
@MainActor
func runSharedAgentFreshnessChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-freshness-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 41, count: 32)
    let service = try CollaborationStore(path: root.appendingPathComponent("service.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: service)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ name: String) async throws -> Collaboration.Credential {
            let enrollment = try await service.provisionPerson(label: name)
            return try await service.redeem(.init(code: enrollment.code, deviceLabel: name))
        }
        let a = try await person("Owner A"), b = try await person("Teammate B")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let initial = try await aa.createArea(), area = initial.document.id.rawValue
        let invitation = try await aa.invite(area: area, request: .init(person: b.identity.person))
        _ = try await bb.accept(code: invitation.code)
        let host = try await aa.registerHost()
        func agent() -> SharedArea.Item { .init(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init())) }
        let first = agent(), second = agent()
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        func rect(_ x: Double) -> SharedArea.Rect { .init(x: x, y: 0, width: 300, height: 200) }
        func edit(_ edits: [SharedArea.Edit]) async throws {
            let current = try await aa.state(area: area)
            _ = try await aa.apply(area: area, mutation: .init(epoch: current.scope.epoch,
                command: .init(area: current.document.id, expectedRevision: current.document.revision, edits: edits)))
        }
        var revisions: [SharedArea.Context] = []
        func publish(_ text: String) async throws -> SharedArea.Context {
            let context = SharedArea.Context(id: .init(), object: agreement.id, parent: revisions.last?.id, author: a.identity.person, text: text)
            try await edit([.context(context)]); revisions.append(context); return context
        }
        try await edit([.admit(first, .init(id: .init(), object: first.id, rect: rect(0))),
                        .admit(second, .init(id: .init(), object: second.id, rect: rect(350))),
                        .admit(agreement, .init(id: .init(), object: agreement.id, rect: rect(700)))])
        _ = try await publish("Revision 1: scope is the parser only.")
        let rev2 = try await publish("Revision 2: parser and its tests; no public API changes.")

        func binding(_ item: SharedArea.Item, agent: UUID = UUID()) -> SharedAreaLocalSourceBinding {
            .init(object: item.id, binding: item.source!.binding, host: host.id, projectID: UUID(), tileID: UUID(), agentID: .init(rawValue: agent))
        }
        let firstBinding = binding(first), secondBinding = binding(second)
        let hostDirectory = root.appendingPathComponent("owner-host", isDirectory: true)
        let journal = try SharedAgentHostJournal(directory: hostDirectory)
        var acceptances: [UUID] = [], refuseNext = false
        let execute: SharedAgentHostDispatcher.Execute = { _, command in
            if refuseNext { refuseNext = false; return .refused(.unknownAgent) }
            acceptances.append(command.id); return .accepted
        }
        var hostDispatcher = SharedAgentHostDispatcher(identity: a.identity, transport: SharedAgentHandoffAPI(api: aa, area: area),
            journal: journal, bootID: UUID(), execute: execute)
        await hostDispatcher.pollOnce(bindings: [firstBinding, secondBinding])
        let firstAgent = Collaboration.AgentIncarnation(object: first.id, hostGeneration: try journal.generation(for: firstBinding))
        let secondAgent = Collaboration.AgentIncarnation(object: second.id, hostGeneration: try journal.generation(for: secondBinding))

        let clientDirectory = root.appendingPathComponent("client-a", isDirectory: true)
        var client = try SharedAgentHandoffController(identity: a.identity, transport: SharedAgentHandoffAPI(api: aa, area: area), directory: clientDirectory)
        let ledgerDirectory = clientDirectory.appendingPathComponent("freshness", isDirectory: true)
        var ledger = try SharedAgentFreshnessLedger(directory: ledgerDirectory)
        func document() async throws -> SharedArea.Document { try await aa.state(area: area).document }
        /// Production path: the client records exactly the receipt it holds.
        func send(_ text: String, to object: SharedArea.Item, context: SharedArea.Context) async throws -> Collaboration.AgentDispatchReceipt {
            await client.refresh(object: object.id)
            await client.send(text: text, context: context.id)
            guard let receipt = client.receipt, receipt.command.object == object.id, receipt.command.context == context else {
                throw FreshnessCheckFailure(message: "send of \(text) produced no receipt")
            }
            try ledger.record(receipt); return receipt
        }
        func settle(_ receipt: Collaboration.AgentDispatchReceipt) async throws -> Collaboration.AgentDispatchReceipt {
            await hostDispatcher.pollOnce(bindings: [firstBinding, secondBinding])
            let unsettled = try ledger.unsettledCommands()
            guard unsettled.contains(receipt.command.id) else { throw FreshnessCheckFailure(message: "receipt not tracked as unsettled") }
            for id in unsettled { try ledger.record(try await aa.agentDispatchReceipt(area: area, id: id)) }
            guard try ledger.unsettledCommands().isEmpty, let fresh = try ledger.frozenCommand(receipt.command.id) else {
                throw FreshnessCheckFailure(message: "host outcome not recorded")
            }
            return try await aa.agentDispatchReceipt(area: area, id: fresh.id)
        }

        // 1. Revision 2 to the first agent. Queued is not received.
        let toFirst = try await send("Do the parser change.", to: first, context: rev2)
        let queued = try ledger.freshness(of: firstAgent, agreement: agreement.id, in: try await document())
        try freshnessCheck(queued.state == .notSent && queued.awaitingHost?.id == toFirst.command.id && queued.lastAccepted == nil,
            "a queued delivery is shown as awaiting the host, never as received")
        let firstAccepted = try await settle(toFirst)
        let afterFirst = try ledger.freshness(of: firstAgent, agreement: agreement.id, in: try await document())
        try freshnessCheck(firstAccepted.phase == .accepted && afterFirst.state == .current(rev2.id) && afterFirst.sentOrdinal == 2,
            "host acceptance makes revision 2 the first agent's baseline")
        try freshnessCheck(try ledger.freshness(of: secondAgent, agreement: agreement.id, in: try await document()).state == .notSent,
            "the second agent has no baseline from the first agent's delivery")

        // 2. Revision 3 goes to the second agent only.
        let rev3 = try await publish("Revision 3: parser, tests and the error type.")
        let toSecond = try await settle(try await send("Do the error type.", to: second, context: rev3))
        var doc = try await document()
        try freshnessCheck(toSecond.phase == .accepted
            && (try ledger.freshness(of: secondAgent, agreement: agreement.id, in: doc)).state == .current(rev3.id)
            && (try ledger.freshness(of: firstAgent, agreement: agreement.id, in: doc)).state == .changedSinceSent(sent: rev2.id, current: rev3.id, newerRevisions: 1),
            "two agents hold independent baselines: revision 2 and revision 3")

        // 3. Editing the agreement marks both stale and sends nothing.
        let dispatchedBeforeEdit = acceptances
        let rev4 = try await publish("Revision 4: parser, tests, error type and docs.")
        await hostDispatcher.pollOnce(bindings: [firstBinding, secondBinding])
        doc = try await document()
        let firstStale = try ledger.freshness(of: firstAgent, agreement: agreement.id, in: doc)
        let secondStale = try ledger.freshness(of: secondAgent, agreement: agreement.id, in: doc)
        try freshnessCheck(firstStale.state == .changedSinceSent(sent: rev2.id, current: rev4.id, newerRevisions: 2)
            && secondStale.state == .changedSinceSent(sent: rev3.id, current: rev4.id, newerRevisions: 1)
            && firstStale.label == "Last accepted revision 2 · Current revision 4 · Changed since sent",
            "an edit marks each agent changed-since-sent against its own baseline")
        let pendingAfterEdit = try await aa.pendingAgentDispatches(area: area, host: host.id.rawValue)
        try freshnessCheck(acceptances == dispatchedBeforeEdit && pendingAfterEdit.isEmpty,
            "editing the agreement and polling the host create no dispatch")
        let serviceCopy = try await aa.agentDispatchReceipt(area: area, id: toFirst.command.id)
        let frozen = try ledger.frozenCommand(toFirst.command.id)
        try freshnessCheck(frozen == toFirst.command && serviceCopy.command == toFirst.command
            && frozen?.context.text == rev2.text && frozen?.promptText.contains(rev2.text) == true && frozen?.promptText.contains(rev4.text) == false,
            "the accepted execution input still carries revision 2 after revision 4 is published")
        try freshnessCheck((try? journal.prepare(toFirst.command)) != nil,
            "the host journal still matches the original command byte for byte")
        let rewritten = Collaboration.AgentDispatchCommand(id: toFirst.command.id, area: toFirst.command.area, object: toFirst.command.object,
            source: toFirst.command.source, requester: toFirst.command.requester, epoch: toFirst.command.epoch,
            controlRevision: toFirst.command.controlRevision, hostGeneration: toFirst.command.hostGeneration, context: rev4, text: toFirst.command.text)
        var refusedRewrite = false
        do { try ledger.record(.init(command: rewritten, phase: .accepted)) } catch SharedAgentFreshnessError.changedIntent { refusedRewrite = true }
        try freshnessCheck(refusedRewrite && (try ledger.freshness(of: firstAgent, agreement: agreement.id, in: doc)).lastAccepted?.context == rev2,
            "a receipt that would rewrite an accepted command with a newer revision is refused")

        // 4. A refused resend of revision 4 leaves the baseline where it was.
        refuseNext = true
        let resend = try await settle(try await send("Pick up revision 4.", to: first, context: rev4))
        let afterRefusedResend = try ledger.freshness(of: firstAgent, agreement: agreement.id, in: try await document())
        try freshnessCheck(resend.phase == .refused && afterRefusedResend.lastAccepted?.id == toFirst.command.id
            && afterRefusedResend.state == .changedSinceSent(sent: rev2.id, current: rev4.id, newerRevisions: 2)
            && afterRefusedResend.unresolved?.command.id == resend.command.id && afterRefusedResend.unresolved?.phase == .refused,
            "a refused delivery is reported but does not advance the baseline")
        let stale = try ledger.record(.init(command: toFirst.command, phase: .queued))
        try freshnessCheck(stale == .accepted, "a late, older receipt cannot move an accepted delivery backwards")

        // 5. Frozen result excerpts keep their source turn, host and artifact revision.
        let artifact = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        try await edit([.admit(artifact, .init(id: .init(), object: artifact.id, rect: rect(1050)))])
        let artifactR1 = UUID(), artifactR2 = UUID()
        let excerpt = Collaboration.ResultExcerpt(area: initial.document.id, capturedBy: a.identity.person,
            source: .init(incarnation: secondAgent, host: host.id, turn: "turn-7", position: .init(generation: 1, sequence: 42), command: toSecond.command.id,
                          artifact: .init(object: artifact.id, revision: artifactR1, contentDigest: String(repeating: "a", count: 64))),
            text: "Error type added; parser tests pass.")
        try ledger.keep(excerpt)
        var oversized = false, rewrittenExcerpt = false
        do {
            try ledger.keep(.init(area: initial.document.id, capturedBy: a.identity.person, source: excerpt.source,
                                  text: String(repeating: "x", count: Collaboration.ResultExcerpt.maximumTextBytes + 1)))
        } catch SharedAgentFreshnessError.excerptRejected { oversized = true }
        do {
            try ledger.keep(.init(id: excerpt.id, area: initial.document.id, capturedBy: a.identity.person, source: excerpt.source, text: "Edited quote."))
        } catch SharedAgentFreshnessError.changedIntent { rewrittenExcerpt = true }
        try freshnessCheck(oversized && rewrittenExcerpt, "excerpts are bounded and cannot be rewritten under the same ID")

        // 6. Relaunch: client, ledger and host all reconstructed from disk.
        let beforeRestart = (try ledger.freshness(of: firstAgent, agreement: agreement.id, in: try await document()),
                             try ledger.freshness(of: secondAgent, agreement: agreement.id, in: try await document()))
        let acceptedBeforeRestart = acceptances
        ledger = try SharedAgentFreshnessLedger(directory: ledgerDirectory)
        client = try SharedAgentHandoffController(identity: a.identity, transport: SharedAgentHandoffAPI(api: aa, area: area), directory: clientDirectory)
        hostDispatcher = SharedAgentHostDispatcher(identity: a.identity, transport: SharedAgentHandoffAPI(api: aa, area: area),
            journal: try SharedAgentHostJournal(directory: hostDirectory), bootID: UUID(), execute: execute)
        await hostDispatcher.pollOnce(bindings: [firstBinding, secondBinding])
        await client.refresh(object: first.id)
        doc = try await document()
        try freshnessCheck(try ledger.freshness(of: firstAgent, agreement: agreement.id, in: doc) == beforeRestart.0
            && (try ledger.freshness(of: secondAgent, agreement: agreement.id, in: doc)) == beforeRestart.1
            && (try ledger.excerpts()) == [excerpt],
            "baselines, stale markers and excerpts survive a client, ledger and host relaunch")
        try freshnessCheck(acceptances == acceptedBeforeRestart, "relaunch dispatches nothing")

        // 7. Receipts are the requester's and owner's: a ledger rebuilt from the
        // service matches, and a third member cannot read them at all.
        let rebuilt = try SharedAgentFreshnessLedger(directory: root.appendingPathComponent("client-a-second-device/freshness", isDirectory: true))
        for id in [toFirst.command.id, toSecond.command.id, resend.command.id] { try rebuilt.record(try await aa.agentDispatchReceipt(area: area, id: id)) }
        try freshnessCheck(try rebuilt.freshness(of: firstAgent, agreement: agreement.id, in: doc) == beforeRestart.0
            && (try rebuilt.freshness(of: secondAgent, agreement: agreement.id, in: doc)) == beforeRestart.1,
            "a ledger rebuilt from the service's receipts shows the same per-agent state")
        var teammateForbidden = false
        do { _ = try await bb.agentDispatchReceipt(area: area, id: toFirst.command.id) }
        catch let CollaborationClientError.server(status, _) where status == 403 { teammateForbidden = true }
        try freshnessCheck(teammateForbidden, "a member who neither sent nor owns the agent cannot read its delivery receipts")

        // 8. Rebinding replaces the incarnation; nothing is inherited.
        let rebound = binding(second)
        await hostDispatcher.pollOnce(bindings: [firstBinding, rebound])
        let replacement = Collaboration.AgentIncarnation(object: second.id, hostGeneration: try journal.generation(for: rebound))
        doc = try await document()
        let control = try await aa.agentControl(area: area, object: second.id.rawValue)
        try freshnessCheck(replacement != secondAgent && control.hostGeneration == replacement.hostGeneration
            && (try ledger.freshness(of: replacement, agreement: agreement.id, in: doc)).state == .notSent
            && (try ledger.freshness(of: secondAgent, agreement: agreement.id, in: doc)).state == .changedSinceSent(sent: rev3.id, current: rev4.id, newerRevisions: 1),
            "a replaced binding starts with no baseline and cannot inherit revision 3")
        try freshnessCheck(excerpt.availability(in: doc, currentGeneration: replacement.hostGeneration, currentArtifactRevision: { _ in artifactR1 }) == .sourceReplaced
            && excerpt.availability(in: doc, currentGeneration: secondAgent.hostGeneration, currentArtifactRevision: { _ in artifactR1 }) == .linked
            && excerpt.availability(in: doc, currentGeneration: secondAgent.hostGeneration, currentArtifactRevision: { _ in artifactR2 }) == .artifactChanged(current: artifactR2),
            "an excerpt says honestly when its turn's incarnation or artifact revision has moved on")
        try await edit([.remove(second.id), .remove(artifact.id)])
        doc = try await document()
        try freshnessCheck(excerpt.availability(in: doc, currentGeneration: nil, currentArtifactRevision: { _ in nil }) == .sourceRemoved
            && (try ledger.excerpts()).first?.text == excerpt.text,
            "a removed source is labelled unavailable while the frozen quote stays readable")
        try await edit([.remove(agreement.id)])
        doc = try await document()
        try freshnessCheck((try ledger.freshness(of: firstAgent, agreement: agreement.id, in: doc)).state == .agreementRemoved(sent: rev2.id),
            "an agent whose agreement was removed keeps its last accepted revision, labelled as no longer shared")
        try freshnessCheck(acceptances.count == 2, "only the two deliberate sends were ever accepted")

        // 10. Excerpts in discussion over real HTTP. Only the agent's owner may
        // export its result; the post replays to the teammate unchanged.
        let discussion = SharedArea.Item(id: .init(), kind: .discussion)
        try await edit([.admit(discussion, .init(id: .init(), object: discussion.id, rect: rect(1400)))])
        let shared = Collaboration.ResultExcerpt(area: initial.document.id, capturedBy: a.identity.person,
            source: .init(incarnation: firstAgent, host: host.id, turn: "turn-3", position: .init(generation: 1, sequence: 9), command: toFirst.command.id), text: "Parser change done.")
        try await edit([.post(.init(id: .init(), object: discussion.id, author: a.identity.person, text: "Result from my agent.", excerpt: shared))])
        let teammateView = try await bb.state(area: area).document
        try freshnessCheck(teammateView.posts.last?.excerpt == shared && teammateView.posts.last?.excerpt?.source.turn == "turn-3",
            "an owner's excerpt post replays to the teammate with its exact source turn, host and session")
        let current = try await bb.state(area: area)
        let foreign = Collaboration.ResultExcerpt(area: initial.document.id, capturedBy: b.identity.person,
            source: .init(incarnation: firstAgent, host: host.id, turn: "turn-3"), text: "Parser change done.")
        var exportRefused = false
        do {
            _ = try await bb.apply(area: area, mutation: .init(epoch: current.scope.epoch, command: .init(area: current.document.id,
                expectedRevision: current.document.revision, edits: [.post(.init(id: .init(), object: discussion.id, author: b.identity.person,
                    text: "Quoting your agent.", excerpt: foreign))])))
        } catch let CollaborationClientError.server(status, _) where status == 400 { exportRefused = true }
        let afterRefusal = try await aa.state(area: area).document
        try freshnessCheck(exportRefused && afterRefusal.posts.count == teammateView.posts.count,
            "a teammate cannot export a result from an agent they do not own")
        let plain = SharedArea.Post(id: .init(), object: discussion.id, author: a.identity.person, text: "No quote.")
        let plainBytes = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        let reloaded = try JSONDecoder().decode(SharedArea.Document.self, from: try JSONEncoder().encode(teammateView))
        try freshnessCheck(!plainBytes.contains("excerpt") && reloaded == teammateView,
            "a post without an excerpt keeps its earlier bytes and a snapshot with excerpts reloads through validation")

        try await server.stop()
        print("Shared agent freshness checks passed: independent per-agent baselines through real HTTP, stale markers without dispatch, immutable accepted input, refusal and rebind honesty, provenance excerpts and relaunch.")
    } catch { try? await server.stop(); throw error }
}
