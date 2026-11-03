import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// Plan 104 step 2: a phone paired through the hosted relay reads an agent's
/// transcript. The pairing secret travels in the link only; both ends derive
/// the key from it; the phone asks through the command queue (the relay
/// refuses phone-published events) and the Mac answers with an encrypted
/// event. Real relay server and store over HTTP, the production
/// `DesktopCompanionSyncService`, and the phone's real transport and receiver.
func runCompanionTranscriptDeliveryChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    actor Freshness: CompanionLifecycleHintPublishing {
        func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {}
        func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {}
    }

    let sentinel = "TRANSCRIPT-PLAINTEXT-SENTINEL-\(UUID().uuidString)"
    let agent = UUID(), missingAgent = UUID()
    let document = AgentDocument(version: 3, entries: [AgentEntry(
        id: AgentNodeID(rawValue: "phone.entry")!,
        role: .assistant,
        provenance: .providerItem(provider: "claude", itemID: "item-3"),
        lifecycle: .finished,
        blocks: [AgentBlock(id: AgentNodeID(rawValue: "phone.entry.prose")!, kind: .paragraph, payload: .paragraph([.text(sentinel)]))]
    )])

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-transcript-delivery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayStore(path: directory.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 6, count: 32))
    let server = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0))
    try await server.start()
    var service: DesktopCompanionSyncService?
    var transports: [RelaySyncTransport] = []
    do {
        guard let port = server.listeningPublicPort else { throw Failure(message: "no bound port") }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
        let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Mac"))
        let grant = try await store.createPairingGrant(auth: try await store.authenticate(mac.credential), deviceLabel: "Phone")

        // The Mac's link carries the secret in the fragment; the phone reads it back.
        let secret = try PairingSecret.generate()
        let link = PairingURL.hostedIssue(credential: grant.code, relay: base, secret: secret)
        guard let payload = PairingURL.parsePayload(link) else { throw Failure(message: "the hosted link did not parse") }
        try check(payload.secret == secret, "the phone reads the secret the Mac put in the link")
        try check(URLComponents(url: link, resolvingAgainstBaseURL: false)?.query == nil, "the secret is in the fragment, never the query")
        let phone = try await store.exchangePairingGrant(.init(code: payload.token, deviceLabel: "Phone"))

        // Links from older Macs and damaged secrets parse without one; a phone
        // paired before the secret existed still loads its stored session.
        try check(PairingURL.parsePayload(PairingURL.hostedIssue(credential: grant.code, relay: base))?.secret == nil,
                  "an old link has no secret")
        let damaged = URL(string: link.absoluteString.replacingOccurrences(of: PairingSecret.encode(secret), with: "c2hvcnQ"))!
        try check(PairingURL.parsePayload(damaged)?.token == grant.code && PairingURL.parsePayload(damaged)?.secret == nil,
                  "a damaged secret is dropped, not half-used")
        let oldSession = #"{"instanceId":"\#(phone.instanceID)","userId":"\#(phone.instanceID)","deviceId":"\#(phone.deviceID)","sessionId":"\#(phone.deviceID)","token":"t","scopes":38,"issuedAt":0,"expiresAt":0}"#
        let decodedOld = try? JSONDecoder().decode(PairedCompanionSession.self, from: Data(oldSession.utf8))
        try check(decodedOld != nil && decodedOld?.pairingSecret == nil, "a session saved before the secret existed still loads")

        let macKey = TranscriptSyncCrypto.derivePairingSecretChannel(secret: secret, instanceID: mac.instanceID)
        let phoneKey = TranscriptSyncCrypto.derivePairingSecretChannel(secret: payload.secret!, instanceID: phone.instanceID)
        try check(macKey.keyID == phoneKey.keyID, "both ends derive the same key from the shared secret")
        let otherKey = TranscriptSyncCrypto.derivePairingSecretChannel(secret: try PairingSecret.generate(), instanceID: mac.instanceID)
        try check(otherKey.keyID != macKey.keyID, "another pairing's secret names another key")

        // The Mac: production service with the secret-derived channel.
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
            transcriptChannels: { [macKey] },
            transcriptDocument: { id in id == agent ? (sessionID: "provider/session", document: document) : nil },
            commandChannel: RelayCommandChannel(baseURL: base, bearerToken: mac.credential),
            freshnessPublisher: Freshness())
        service = started
        try await started.start()

        // The phone: its real transport, demux and receiver with its own key.
        let phoneTransport = RelaySyncTransport(baseURL: base, bearerToken: phone.credential, deviceLabel: "Phone", apiVersion: .hardenedV2)
        transports.append(phoneTransport)
        phoneTransport.start()
        let receiver = TranscriptProjectionReceiver(demux: SyncMessageDemux(transport: phoneTransport), scope: .companionControl,
                                                    channelKeys: [phoneKey.keyID: phoneKey.key])
        await receiver.follow(agentIDs: [agent])
        let phoneChannel = RelayCommandChannel(baseURL: base, bearerToken: phone.credential)
        func ask(_ agentID: UUID, key: UUID, known: UInt64?) async throws -> RelayCommandStatus {
            try await phoneChannel.send(.init(idempotencyKey: UUID(), kind: RelayCommandKind.transcriptRequest, agentID: agentID,
                payload: try JSONEncoder().encode(CompanionTranscriptRequest(keyID: key, knownVersion: known))), waitingUpTo: .seconds(10))
        }

        let first = try await ask(agent, key: phoneKey.keyID, known: nil)
        try check(first.state == .completed && first.outcome == CompanionTranscriptOutcome.published.rawValue, "the Mac publishes the transcript: \(first)")
        var shown = await receiver.currentDocument(agentID: agent)
        for _ in 0..<40 where shown == nil {
            try await Task.sleep(for: .milliseconds(250)); shown = await receiver.currentDocument(agentID: agent)
        }
        try check(shown == document, "the phone opens the transcript the Mac sent: \(String(describing: await receiver.currentError()))")

        let again = try await ask(agent, key: phoneKey.keyID, known: document.version)
        try check(again.outcome == CompanionTranscriptOutcome.unchanged.rawValue, "a version the phone already shows is not sent again: \(again)")
        let missing = try await ask(missingAgent, key: phoneKey.keyID, known: nil)
        try check(missing.outcome == CompanionTranscriptOutcome.unavailable.rawValue, "an agent with no transcript is unavailable: \(missing)")

        // A phone paired before the secret existed derives from its credential,
        // which the Mac never holds for hosted pairings: honestly unknownKey.
        let legacy = TranscriptSyncCrypto.derivePairedSessionChannel(token: phone.credential, pairingID: phone.instanceID)
        let old = try await ask(agent, key: legacy.keyID, known: nil)
        try check(old.outcome == CompanionTranscriptOutcome.unknownKey.rawValue, "an old pairing's key is reported unknown: \(old)")

        // The relay holds ciphertext only: neither the transcript text nor the secret.
        var relayBytes = Data()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            relayBytes.append((try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data())
        }
        try check(!relayBytes.isEmpty, "the relay's files were read")
        try check(relayBytes.range(of: Data(sentinel.utf8)) == nil, "the relay never stores the transcript text")
        try check(relayBytes.range(of: secret) == nil && relayBytes.range(of: Data(PairingSecret.encode(secret).utf8)) == nil,
                  "the relay never stores the pairing secret")

        await receiver.stop()
        await started.stop(); service = nil
        transports.forEach { $0.stop() }
    } catch {
        await service?.stop()
        transports.forEach { $0.stop() }
        try? await server.stop()
        throw error
    }
    try await server.stop()
    print("Companion transcript delivery checks passed: the pairing secret rides the link fragment only, both ends derive one key, the phone's request crosses the command queue, the Mac's encrypted answer opens on the phone, unchanged/unavailable/old-pairing are reported, and the relay stores neither the text nor the secret")
}
