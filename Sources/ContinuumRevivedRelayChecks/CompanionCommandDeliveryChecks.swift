import ContinuumRevivedCore
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// Phone Stop and Approve reaching the Mac through the hosted relay, end to
/// end over HTTP: the relay's real server and store, the phone's client, and
/// the Mac's production `DesktopCompanionSyncService` with its command
/// receiver. Only the agent-side handlers are recorders.
func runCompanionCommandDeliveryChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    actor Recorder: ApprovalResponding {
        var stops: [UUID] = []; var approvals: [(UUID, String, ApprovalDecision)] = []
        func stop(_ id: UUID) -> AgentStopOutcome { stops.append(id); return id == Recorder.unknown ? .notFound : .stopped }
        func respond(agentId: UUID, requestId: String, decision: ApprovalDecision) async -> ApprovalRespondResult {
            approvals.append((agentId, requestId, decision)); return requestId == "open-request" ? .sent : .unknownRequest
        }
        static let unknown = UUID()
    }
    actor Freshness: CompanionLifecycleHintPublishing {
        func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {}
        func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {}
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-command-delivery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayStore(path: directory.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 5, count: 32))
    let server = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0))
    try await server.start()
    var service: DesktopCompanionSyncService?
    do {
        guard let port = server.listeningPublicPort else { throw Failure(message: "no bound port") }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
        let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Mac"))
        let grant = try await store.createPairingGrant(auth: try await store.authenticate(mac.credential), deviceLabel: "Phone")
        let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Phone"))
        let phoneChannel = RelayCommandChannel(baseURL: base, bearerToken: phone.credential)
        let agent = UUID()

        // What the phone did before: a sync event, which the relay refuses.
        let legacy = RelaySyncTransport(baseURL: base, bearerToken: phone.credential, deviceLabel: "Phone", apiVersion: .hardenedV2)
        do {
            try await legacy.send(.agentStopRequest(AgentStopRequest(agentID: agent)))
            throw Failure(message: "the relay accepted a phone-published event")
        } catch SyncTransportError.sendFailed(let reason) {
            try check(reason == "forbidden", "the old phone path is refused before the Mac: \(reason)")
        }
        legacy.stop()

        // Stop pressed while the Mac is offline.
        let offlineStop = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent)
        _ = try await phoneChannel.submit(offlineStop)
        try check(try await phoneChannel.status(offlineStop.idempotencyKey).state == .pending, "nothing runs while the Mac is away")

        // The Mac comes online: production service, real transport, real channel.
        let recorder = Recorder()
        let desktopTransport = RelaySyncTransport(baseURL: base, bearerToken: mac.credential, deviceLabel: "mac-desktop",
                                                  startAtHead: true, apiVersion: .hardenedV2)
        desktopTransport.start()
        let started = DesktopCompanionSyncService(
            configuration: .init(containerIdentifier: "relay:check"), transport: desktopTransport,
            pairingSnapshot: { .hostedRelay(instanceId: mac.instanceID, pairedDeviceCount: 1) },
            canvasSnapshot: { (CanvasState(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
                               WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil)) },
            activitySnapshot: { .empty },
            stopAgent: { await recorder.stop($0) },
            approvals: recorder,
            commandChannel: RelayCommandChannel(baseURL: base, bearerToken: mac.credential),
            freshnessPublisher: Freshness())
        service = started
        try await started.start()

        var collected = try await phoneChannel.status(offlineStop.idempotencyKey)
        for _ in 0..<40 where collected.state == .pending {
            try await Task.sleep(for: .milliseconds(250)); collected = try await phoneChannel.status(offlineStop.idempotencyKey)
        }
        try check(collected.state == .completed && collected.outcome == "stopped", "the Stop sent while offline runs when the Mac returns: \(collected)")
        try check(await recorder.stops == [agent], "the agent was stopped exactly once")

        // Approve while the Mac is online, with the phone waiting for the answer.
        let approve = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.approvalRespond, agentID: agent,
            payload: try JSONEncoder().encode(CompanionApprovalCommand(requestId: "open-request", decision: .accept)))
        let approved = try await phoneChannel.send(approve, waitingUpTo: .seconds(10))
        try check(approved.state == .completed && approved.outcome == ApprovalResponseOutcome.sent.rawValue, "approval is handed to the agent: \(approved)")
        let approvals = await recorder.approvals
        try check(approvals.count == 1 && approvals[0].0 == agent && approvals[0].1 == "open-request" && approvals[0].2 == .accept,
                  "the Mac answered the request the phone named, with the phone's decision")
        let closed = try await phoneChannel.send(.init(idempotencyKey: UUID(), kind: RelayCommandKind.approvalRespond, agentID: agent,
            payload: try JSONEncoder().encode(CompanionApprovalCommand(requestId: "gone", decision: .decline))), waitingUpTo: .seconds(10))
        try check(closed.outcome == ApprovalResponseOutcome.unknownRequest.rawValue, "a request no longer open is reported as such: \(closed)")

        // A retried Stop is the same Stop.
        _ = try await phoneChannel.submit(offlineStop)
        let unknown = try await phoneChannel.send(.init(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: Recorder.unknown), waitingUpTo: .seconds(10))
        try check(unknown.outcome == AgentStopOutcome.notFound.rawValue, "an agent the Mac does not have is notFound: \(unknown)")
        try check(await recorder.stops == [agent, Recorder.unknown], "the retried Stop did not run again")

        await started.stop(); service = nil
        desktopTransport.stop()
    } catch {
        await service?.stop()
        try? await server.stop()
        throw error
    }
    try await server.stop()
    print("Companion command delivery checks passed: phone event publish is refused (the old path), Stop sent while the Mac was offline runs once on return, Approve reaches the named request, closed and unknown targets are reported, retries do not re-run")
}
