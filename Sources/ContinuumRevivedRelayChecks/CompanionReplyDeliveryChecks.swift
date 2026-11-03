import ContinuumRevivedCore
import ContinuumRevivedRelayClient
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// Plan 104 step 3: the phone sends an agent a message. The text is sealed on
/// the phone under a key from the pairing secret and opened on the Mac; the
/// relay checks the phone's `sendMessages` capability and stores ciphertext.
/// Real relay server and store over HTTP and the production
/// `DesktopCompanionSyncService`; only the agent is a recorder.
func runCompanionReplyDeliveryChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    actor Agents {
        var received: [(UUID, String)] = []
        let idle = UUID(), busy = UUID()
        func send(_ id: UUID, _ text: String) -> AgentMessageOutcome {
            if id == busy { return .busy }
            guard id == idle else { return .notFound }
            received.append((id, text)); return .accepted
        }
    }
    actor Freshness: CompanionLifecycleHintPublishing {
        func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {}
        func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {}
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-reply-delivery-\(UUID())")
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

        // A phone that asks for messaging gets it; one that does not (every
        // phone build from before) gets exactly the set it knows.
        let replyGrant = try await store.createPairingGrant(auth: macAuth, deviceLabel: "Phone")
        let phone = try await HostedRelayAPI(baseURL: base).exchangePairingGrant(code: replyGrant.code, deviceLabel: "Phone", wantsMessages: true)
        try check(phone.capabilities == RelayWire.companionMessagingCapabilities, "a phone that asks may message: \(phone.capabilities)")
        let oldGrant = try await store.createPairingGrant(auth: macAuth, deviceLabel: "Old phone")
        let oldPhone = try await store.exchangePairingGrant(.init(code: oldGrant.code, deviceLabel: "Old phone"))
        try check(oldPhone.capabilities == RelayWire.companionCapabilities, "a phone that does not ask gets the set older builds accept")

        let secret = try PairingSecret.generate()
        let channel = TranscriptSyncCrypto.derivePairingSecretChannel(secret: secret, instanceID: mac.instanceID)
        let agents = Agents()
        let desktopTransport = RelaySyncTransport(baseURL: base, bearerToken: mac.credential, deviceLabel: "mac-desktop",
                                                  startAtHead: true, apiVersion: .hardenedV2)
        transports.append(desktopTransport)
        desktopTransport.start()
        let started = DesktopCompanionSyncService(
            configuration: .init(containerIdentifier: "relay:check"), transport: desktopTransport,
            pairingSnapshot: { .hostedRelay(instanceId: mac.instanceID, pairedDeviceCount: 2) },
            canvasSnapshot: { (CanvasState(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
                               WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil)) },
            activitySnapshot: { .empty },
            transcriptChannels: { [channel] },
            sendMessage: { await agents.send($0, $1) },
            commandChannel: RelayCommandChannel(baseURL: base, bearerToken: mac.credential),
            freshnessPublisher: Freshness())
        service = started
        try await started.start()

        let phoneChannel = RelayCommandChannel(baseURL: base, bearerToken: phone.credential)
        let sentinel = "REPLY-PLAINTEXT-SENTINEL-\(UUID().uuidString)"
        func message(_ text: String, to agent: UUID, key: UUID = UUID(), sealedFor sealAgent: UUID? = nil, sealKey: UUID? = nil,
                     channel sealing: TranscriptChannelKey = channel) throws -> RelayCommandRequest {
            let sealed = try TranscriptSyncCrypto.sealMessage(text, channel: sealing, idempotencyKey: sealKey ?? key, agentID: sealAgent ?? agent)
            return .init(idempotencyKey: key, kind: RelayCommandKind.agentMessage, agentID: agent, payload: try JSONEncoder().encode(sealed))
        }

        let idle = await agents.idle, busy = await agents.busy
        let first = try message(sentinel, to: idle)
        let sent = try await phoneChannel.send(first, waitingUpTo: .seconds(10))
        try check(sent.state == .completed && sent.outcome == AgentMessageOutcome.accepted.rawValue, "an idle agent takes the message: \(sent)")
        var received = await agents.received
        try check(received.count == 1 && received[0].0 == idle && received[0].1 == sentinel, "the agent got the phone's words: \(received)")

        // A retry or reconnect is the same message: still one prompt.
        _ = try await phoneChannel.submit(first)
        let retried = try await phoneChannel.send(first, waitingUpTo: .seconds(3))
        try await Task.sleep(for: .seconds(3))
        received = await agents.received
        try check(retried.outcome == AgentMessageOutcome.accepted.rawValue && received.count == 1, "a retried message appends one prompt: \(received.count)")

        let busyReply = try await phoneChannel.send(try message("later", to: busy), waitingUpTo: .seconds(10))
        try check(busyReply.outcome == AgentMessageOutcome.busy.rawValue, "a busy agent leaves the draft with the phone: \(busyReply)")

        // The relay cannot reuse the ciphertext for another command or agent.
        let replayed = try message("replayed", to: idle, sealKey: UUID())
        let replayedReply = try await phoneChannel.send(replayed, waitingUpTo: .seconds(10))
        try check(replayedReply.outcome == AgentMessageOutcome.invalid.rawValue, "ciphertext moved to another command does not open: \(replayedReply)")
        let redirected = try message("redirected", to: idle, sealedFor: busy)
        let redirectedReply = try await phoneChannel.send(redirected, waitingUpTo: .seconds(10))
        try check(redirectedReply.outcome == AgentMessageOutcome.invalid.rawValue, "ciphertext moved to another agent does not open: \(redirectedReply)")
        let stranger = TranscriptSyncCrypto.derivePairingSecretChannel(secret: try PairingSecret.generate(), instanceID: mac.instanceID)
        let strangerReply = try await phoneChannel.send(try message("stranger", to: idle, channel: stranger), waitingUpTo: .seconds(10))
        try check(strangerReply.outcome == AgentMessageOutcome.unknownKey.rawValue, "a key the Mac does not hold is unknownKey: \(strangerReply)")
        try check(await agents.received.count == 1, "nothing that failed to open reached the agent")

        // A phone that did not ask may not message.
        do {
            _ = try await RelayCommandChannel(baseURL: base, bearerToken: oldPhone.credential).submit(try message("nope", to: idle))
            throw Failure(message: "a phone without sendMessages was allowed to message")
        } catch RelayCommandChannel.Failure.http(let status, _) {
            try check(status == 403, "a phone without sendMessages is refused: \(status)")
        }

        var relayBytes = Data()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            relayBytes.append((try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data())
        }
        try check(!relayBytes.isEmpty && relayBytes.range(of: Data(sentinel.utf8)) == nil, "the relay never stores the message text")

        await started.stop(); service = nil
        transports.forEach { $0.stop() }
    } catch {
        await service?.stop()
        transports.forEach { $0.stop() }
        try? await server.stop()
        throw error
    }
    try await server.stop()
    print("Companion reply delivery checks passed: messaging only for a phone that asks at pairing (older phones keep their set; 403 without it), the sealed text reaches an idle agent once even when retried, busy is reported, ciphertext moved to another command or agent does not open, an unknown key is reported, and the relay never stores the text")
}
