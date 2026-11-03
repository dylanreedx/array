import ContinuumRevivedCore
import ContinuumRevivedRelayClient
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// Plan 104 step 3: a phone message never reaches the agent twice, even when
/// the Mac dies after handing it over and before posting the result (the relay
/// then lists it again on restart). Real relay server and store over HTTP and
/// the production `DesktopCompanionSyncService` with its journal; the journal
/// file a crashed process left behind is written before the service starts.
func runCompanionMessageJournalChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    actor Agents {
        let journal: CompanionCommandJournal
        var received: [String] = []
        /// Messages the journal held as started-without-result while the
        /// agent was being handed one: the state a crash right now leaves.
        var unfinishedWhileHanding: [[UUID]] = []
        init(journal: CompanionCommandJournal) { self.journal = journal }
        func send(_ id: UUID, _ text: String) -> AgentMessageOutcome {
            unfinishedWhileHanding.append(journal.entries().filter { $0.value.result == nil }.map(\.key))
            received.append(text); return .accepted
        }
    }
    actor Freshness: CompanionLifecycleHintPublishing {
        func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {}
        func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {}
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-message-journal-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayStore(path: directory.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 7, count: 32))
    let server = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0))
    try await server.start()
    var service: DesktopCompanionSyncService?
    var transports: [RelaySyncTransport] = []
    do {
        guard let port = server.listeningPublicPort else { throw Failure(message: "no bound port") }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
        let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Mac"))
        let macAuth = try await store.authenticate(mac.credential)
        let grant = try await store.createPairingGrant(auth: macAuth, deviceLabel: "Phone")
        let phone = try await HostedRelayAPI(baseURL: base).exchangePairingGrant(code: grant.code, deviceLabel: "Phone", wantsMessages: true)
        let secret = try PairingSecret.generate()
        let channel = TranscriptSyncCrypto.derivePairingSecretChannel(secret: secret, instanceID: mac.instanceID)
        let phoneChannel = RelayCommandChannel(baseURL: base, bearerToken: phone.credential)
        let agent = UUID()
        func message(_ text: String, key: UUID = UUID()) throws -> RelayCommandRequest {
            let sealed = try TranscriptSyncCrypto.sealMessage(text, channel: channel, idempotencyKey: key, agentID: agent)
            return .init(idempotencyKey: key, kind: RelayCommandKind.agentMessage, agentID: agent, payload: try JSONEncoder().encode(sealed))
        }

        // While the Mac is offline the phone sends two messages. The previous
        // Mac process had started handing over the first and died; it had
        // finished the second (`notReady`) and died before posting it.
        let crashed = try message("CRASHED-MID-HANDOFF"), finished = try message("FINISHED-NOT-POSTED")
        _ = try await phoneChannel.submit(crashed)
        _ = try await phoneChannel.submit(finished)
        let journal = CompanionCommandJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let ancient = UUID()
        try journal.markStarted(ancient, at: Date().addingTimeInterval(-2 * RelayCommandLimits.retention))
        try journal.markStarted(crashed.idempotencyKey)
        try journal.markStarted(finished.idempotencyKey)
        try journal.record(finished.idempotencyKey, RelayCommandResult(outcome: AgentMessageOutcome.notReady.rawValue))

        let agents = Agents(journal: journal)
        let desktopTransport = RelaySyncTransport(baseURL: base, bearerToken: mac.credential, deviceLabel: "mac-desktop",
                                                  startAtHead: true, apiVersion: .hardenedV2)
        transports.append(desktopTransport)
        desktopTransport.start()
        let started = DesktopCompanionSyncService(
            configuration: .init(containerIdentifier: "relay:check"), transport: desktopTransport,
            pairingSnapshot: { .hostedRelay(instanceId: mac.instanceID, pairedDeviceCount: 1) },
            canvasSnapshot: { (CanvasState(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
                               WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil)) },
            activitySnapshot: { .empty },
            transcriptChannels: { [channel] },
            sendMessage: { await agents.send($0, $1) },
            commandChannel: RelayCommandChannel(baseURL: base, bearerToken: mac.credential),
            commandJournal: journal,
            freshnessPublisher: Freshness())
        service = started
        try await started.start()

        func answered(_ key: UUID) async throws -> RelayCommandStatus {
            let deadline = Date().addingTimeInterval(10)
            var status = try await phoneChannel.status(key)
            while status.state == .pending, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                status = try await phoneChannel.status(key)
            }
            return status
        }
        let crashedReply = try await answered(crashed.idempotencyKey)
        let finishedReply = try await answered(finished.idempotencyKey)
        let afterRestart = await agents.received
        try check(afterRestart.isEmpty, "a message the journal holds is not handed to the agent again: \(afterRestart)")
        try check(crashedReply.outcome == AgentMessageOutcome.interrupted.rawValue,
                  "a message started by a process that died reads interrupted: \(crashedReply)")
        try check(finishedReply.outcome == AgentMessageOutcome.notReady.rawValue,
                  "a message finished but not posted re-posts the journaled result: \(finishedReply)")

        // A new message: the journal marks it started before the agent gets it.
        let fresh = try message("FRESH")
        let freshReply = try await phoneChannel.send(fresh, waitingUpTo: .seconds(10))
        let afterFresh = await agents.received
        try check(freshReply.outcome == AgentMessageOutcome.accepted.rawValue && afterFresh == ["FRESH"],
                  "a new message reaches the agent once: \(freshReply) \(afterFresh)")
        let handing = await agents.unfinishedWhileHanding
        try check(handing == [[fresh.idempotencyKey]], "the started mark is on disk before the agent is handed the message: \(handing)")
        try check(journal.entry(fresh.idempotencyKey)?.result?.outcome == AgentMessageOutcome.accepted.rawValue,
                  "the journal records the result after the hand-off")
        try check(journal.entry(ancient) == nil, "entries older than the relay's retention are pruned")

        await started.stop(); service = nil
        transports.forEach { $0.stop() }
    } catch {
        await service?.stop()
        transports.forEach { $0.stop() }
        try? await server.stop()
        throw error
    }
    try await server.stop()
    print("Companion message journal checks passed: after a restart a message the journal marks started reads interrupted and is not handed to the agent, a journaled result is re-posted without running, a new message is marked started on disk before the hand-off and its result after, and old entries are pruned")
}
