import Foundation
import ContinuumRevivedCore

func runLocalPairingEndpointChecks() async throws {
    try runPairingURLPayloadCheck()
    try await runLocalPairingEndpointContractCheck()
    #if os(macOS)
    try await runLocalPairingHTTPListenerSmokeCheck()
    #endif
    print("LocalPairingEndpointChecks passed")
}

private func runPairingURLPayloadCheck() throws {
    let credential = "23456789ABCD"
    let endpoint = URL(string: "http://192.168.1.23:49231/pair")!
    let instanceId = UUID(uuidString: "81000000-0000-4000-8000-000000000001")!
    let url = PairingURL.issue(credential: credential, scopes: .observer, instanceId: instanceId, endpoint: endpoint)
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let payload = PairingURL.parsePayload(url)

    expect(url.scheme == PairingURL.scheme && url.host == PairingURL.host, "Ticket81 PairingURL: URL uses continuum://pair")
    expect(components?.queryItems == nil, "Ticket81 PairingURL: endpoint/token remain in fragment, not URL query")
    expect((components?.fragment ?? "").contains("endpoint="), "Ticket81 PairingURL: fragment contains endpoint")
    expect(PairingURL.parse(url) == credential, "Ticket81 PairingURL: legacy token parse still returns credential")
    expect(payload?.token == credential, "Ticket81 PairingURL: payload token round-trips")
    expect(payload?.endpoint == endpoint, "Ticket81 PairingURL: payload endpoint round-trips")
    expect(payload?.scopes == .observer, "Ticket81 PairingURL: payload scopes round-trip")
    expect(payload?.instanceId == instanceId, "Ticket81 PairingURL: payload instance id round-trips")

    let cameraURL = PairingURL.cameraBootstrapURL(pairingURL: url, endpoint: endpoint)
    let cameraComponents = URLComponents(url: cameraURL, resolvingAgainstBaseURL: false)
    expect(cameraURL.scheme == "http" && cameraComponents?.path == "/open-continuum-pairing", "Ticket81 PairingURL: camera bootstrap URL is HTTP and uses landing path")
    expect(PairingURL.embeddedPairingURL(in: cameraURL) == url, "Ticket81 PairingURL: camera bootstrap embeds exact continuum URL")
    expect(PairingURL.parse(cameraURL) == credential, "Ticket81 PairingURL: camera bootstrap token is parseable")
    expect(PairingURL.parsePayload(cameraURL) == payload, "Ticket81 PairingURL: camera bootstrap payload round-trips")

    let legacy = URL(string: "continuum://pair#token=LEGACYTOKEN")!
    expect(PairingURL.parse(legacy) == "LEGACYTOKEN", "Ticket81 PairingURL: legacy fragment token remains parseable")
    expect(PairingURL.parsePayload(legacy)?.token == "LEGACYTOKEN", "Ticket81 PairingURL: payload parser accepts legacy token-only URL")
}

private func runLocalPairingEndpointContractCheck() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-local-pairing-check-\(UUID().uuidString)", isDirectory: true)
    let authDir = root.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_081_000))
    let service = try CompanionAuthService(authDirectory: authDir, clock: clock, instanceDisplayName: "Pairing QA")
    let instance = try await service.instance()
    let owner = try await service.owner()
    let endpoint = LocalPairingEndpoint(
        authService: service,
        expiresAt: clock.now().addingTimeInterval(300),
        clock: clock
    )

    let grant = try await service.issuePairingCredential(scopes: .operator, ttl: 300, label: "Endpoint QA")
    let body = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: grant.credential,
        deviceLabel: " Dylan's iPhone ",
        requestedScope: Scope.observer.rawValue
    ))
    let landingURL = PairingURL.cameraBootstrapURL(
        pairingURL: PairingURL.issue(credential: grant.credential, scopes: grant.scopes, instanceId: instance.id, endpoint: URL(string: "http://127.0.0.1:49152/pair")!),
        endpoint: URL(string: "http://127.0.0.1:49152/pair")!
    )
    let landing = await endpoint.handle(method: "GET", path: httpRequestTarget(for: landingURL), body: Data())
    expect(landing.statusCode == 200, "Ticket81 endpoint: GET camera landing page succeeds before exchange, got \(landing.statusCode)")
    expect(String(decoding: landing.body, as: UTF8.self).contains("Open Continuum"), "Ticket81 endpoint: camera landing page is human-readable")

    let invalidLanding = await endpoint.handle(method: "GET", path: "/open-continuum-pairing?link=not-a-pairing-link", body: Data())
    let invalidLandingError = try errorCode(in: invalidLanding.body)
    expect(invalidLanding.statusCode == 400 && invalidLandingError == "invalidPairingLink", "Ticket81 endpoint: invalid camera landing link is rejected")

    let success = await endpoint.handle(method: "POST", path: "/pair", body: body)
    expect(success.statusCode == 200, "Ticket81 endpoint: valid POST /pair succeeds, got \(success.statusCode)")
    let sessionResponse = try JSONDecoder().decode(LocalPairingSessionResponse.self, from: success.body)
    let pairedSession = try JSONDecoder().decode(PairedCompanionSession.self, from: success.body)
    expect(sessionResponse.instanceId == instance.id, "Ticket81 endpoint: response instanceId is bound to Mac instance")
    expect(sessionResponse.userId == owner.id, "Ticket81 endpoint: response userId is bound to local owner")
    expect(sessionResponse.scopes == .observer && sessionResponse.scopeRawValue == Scope.observer.rawValue, "Ticket81 endpoint: response is down-scoped to requested observer scope")
    expect(pairedSession == sessionResponse.pairedSession, "Ticket81 endpoint: response decodes into PairedCompanionSession fields")
    let devices = try await service.listDevices()
    expect(!devices.isEmpty, "Ticket81 endpoint: successful exchange persists a paired device")

    try assertNoUnrelatedLocalState(in: success.body, authDir: authDir, pairingCredential: grant.credential)

    let replay = await endpoint.handle(method: "POST", path: "/pair", body: body)
    let replayError = try errorCode(in: replay.body)
    expect(replay.statusCode == 409, "Ticket81 endpoint: replayed token is rejected as conflict, got \(replay.statusCode)")
    expect(replayError == "alreadyUsed", "Ticket81 endpoint: replay error is alreadyUsed")
    expect(!String(decoding: replay.body, as: UTF8.self).contains(grant.credential), "Ticket81 endpoint: replay response does not echo pairing credential")

    let invalidMethod = await endpoint.handle(method: "GET", path: "/pair", body: Data())
    expect(invalidMethod.statusCode == 405, "Ticket81 endpoint: invalid method is rejected")
    let invalidPath = await endpoint.handle(method: "POST", path: "/wrong", body: body)
    expect(invalidPath.statusCode == 404, "Ticket81 endpoint: invalid path is rejected")
    let invalidBody = await endpoint.handle(method: "POST", path: "/pair", body: Data("not-json".utf8))
    let invalidBodyError = try errorCode(in: invalidBody.body)
    expect(invalidBody.statusCode == 400 && invalidBodyError == "invalidBody", "Ticket81 endpoint: invalid JSON body is rejected")

    let boundGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Bound QA")
    let unrelatedGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Unrelated QA")
    let boundEndpoint = LocalPairingEndpoint(
        authService: service,
        expiresAt: clock.now().addingTimeInterval(300),
        acceptedCredential: boundGrant.credential,
        clock: clock
    )
    let unrelatedBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: unrelatedGrant.credential,
        deviceLabel: "Unrelated QA",
        requestedScope: Scope.observer.rawValue
    ))
    let unrelatedRejected = await boundEndpoint.handle(method: "POST", path: "/pair", body: unrelatedBody)
    let unrelatedRejectedError = try errorCode(in: unrelatedRejected.body)
    expect(unrelatedRejected.statusCode == 401 && unrelatedRejectedError == "invalidToken", "Ticket81 endpoint: listener-bound endpoint rejects unrelated valid tokens")
    let boundBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: boundGrant.credential,
        deviceLabel: "Bound QA",
        requestedScope: Scope.observer.rawValue
    ))
    let boundSuccess = await boundEndpoint.handle(method: "POST", path: "/pair", body: boundBody)
    expect(boundSuccess.statusCode == 200, "Ticket81 endpoint: listener-bound token succeeds")

    let invalidScopeGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Invalid Scope QA")
    let invalidScopeBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: invalidScopeGrant.credential,
        deviceLabel: "Scope QA",
        requestedScope: 1 << 10
    ))
    let invalidScope = await endpoint.handle(method: "POST", path: "/pair", body: invalidScopeBody)
    let invalidScopeError = try errorCode(in: invalidScope.body)
    expect(invalidScope.statusCode == 400 && invalidScopeError == "invalidScope", "Ticket81 endpoint: unknown scope bits are rejected")
    let validAfterInvalidScope = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: invalidScopeGrant.credential,
        deviceLabel: "Scope QA",
        requestedScope: Scope.observer.rawValue
    ))
    let validAfterInvalid = await endpoint.handle(method: "POST", path: "/pair", body: validAfterInvalidScope)
    expect(validAfterInvalid.statusCode == 200, "Ticket81 endpoint: invalid scope rejection does not consume token")

    let invalidDeviceGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Invalid Device QA")
    let invalidDeviceBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: invalidDeviceGrant.credential,
        deviceLabel: "   ",
        requestedScope: Scope.observer.rawValue
    ))
    let invalidDevice = await endpoint.handle(method: "POST", path: "/pair", body: invalidDeviceBody)
    let invalidDeviceError = try errorCode(in: invalidDevice.body)
    expect(invalidDevice.statusCode == 400 && invalidDeviceError == "invalidDeviceLabel", "Ticket81 endpoint: blank device label is rejected")

    let scopeDeniedGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Denied QA")
    let scopeDeniedBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: scopeDeniedGrant.credential,
        deviceLabel: "Denied QA",
        requestedScope: Scope.operator.rawValue
    ))
    let scopeDenied = await endpoint.handle(method: "POST", path: "/pair", body: scopeDeniedBody)
    let scopeDeniedError = try errorCode(in: scopeDenied.body)
    expect(scopeDenied.statusCode == 403 && scopeDeniedError == "scopeNotGranted", "Ticket81 endpoint: requested scope above grant ceiling is rejected")

    let expiredGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 1, label: "Expired QA")
    clock.advance(by: 2)
    let expiredBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: expiredGrant.credential,
        deviceLabel: "Expired QA",
        requestedScope: Scope.observer.rawValue
    ))
    let expired = await endpoint.handle(method: "POST", path: "/pair", body: expiredBody)
    let expiredError = try errorCode(in: expired.body)
    expect(expired.statusCode == 401 && expiredError == "expired", "Ticket81 endpoint: expired pairing credential is rejected")

    let windowEndpoint = LocalPairingEndpoint(
        authService: service,
        expiresAt: clock.now().addingTimeInterval(1),
        clock: clock
    )
    let windowGrant = try await service.issuePairingCredential(scopes: .observer, ttl: 300, label: "Window QA")
    clock.advance(by: 2)
    let windowBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: windowGrant.credential,
        deviceLabel: "Window QA",
        requestedScope: Scope.observer.rawValue
    ))
    let windowExpired = await windowEndpoint.handle(method: "POST", path: "/pair", body: windowBody)
    let windowExpiredError = try errorCode(in: windowExpired.body)
    expect(windowExpired.statusCode == 410 && windowExpiredError == "pairingWindowExpired", "Ticket81 endpoint: requests after listener expiry are rejected")

    let stoppedEndpoint = LocalPairingEndpoint(
        authService: service,
        expiresAt: clock.now().addingTimeInterval(300),
        clock: clock
    )
    await stoppedEndpoint.stop()
    let stopped = await stoppedEndpoint.handle(method: "POST", path: "/pair", body: windowBody)
    let stoppedError = try errorCode(in: stopped.body)
    expect(stopped.statusCode == 410 && stoppedError == "pairingWindowStopped", "Ticket81 endpoint: requests after stop are rejected")
}

#if os(macOS)
private func runLocalPairingHTTPListenerSmokeCheck() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-local-pairing-http-check-\(UUID().uuidString)", isDirectory: true)
    let authDir = root.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = try CompanionAuthService(authDirectory: authDir, instanceDisplayName: "Pairing HTTP QA")
    let grant = try await service.issuePairingCredential(scopes: .observer, ttl: 30, label: "HTTP QA")
    let listener = try LocalPairingEndpointListener.start(
        authService: service,
        bindHost: "127.0.0.1",
        advertisedHost: "127.0.0.1",
        expiresAt: grant.expiresAt ?? Date().addingTimeInterval(30),
        acceptedCredential: grant.credential
    )
    defer { listener.stop() }
    var request = URLRequest(url: listener.endpointURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(LocalPairingExchangeRequest(
        token: grant.credential,
        deviceLabel: "HTTP QA",
        requestedScope: Scope.observer.rawValue
    ))

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    expect(statusCode == 200, "Ticket81 listener: loopback HTTP POST succeeds, got \(statusCode)")
    let sessionResponse = try JSONDecoder().decode(LocalPairingSessionResponse.self, from: data)
    expect(sessionResponse.scopes == .observer, "Ticket81 listener: HTTP response returns observer session")
    listener.stop()
    expect(!listener.status().isListening, "Ticket81 listener: stop updates listener status")
}
#endif

private func httpRequestTarget(for url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.path
    }
    var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery, !query.isEmpty {
        target += "?\(query)"
    }
    return target
}

private func errorCode(in data: Data) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["error"] as? String
}

private func assertNoUnrelatedLocalState(in data: Data, authDir: URL, pairingCredential: String) throws {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let keys = Set(object.map { Array($0.keys) } ?? [])
    let allowedKeys: Set<String> = [
        "instanceId",
        "userId",
        "deviceId",
        "sessionId",
        "token",
        "scopes",
        "scopeRawValue",
        "issuedAt",
        "expiresAt"
    ]
    expect(keys == allowedKeys, "Ticket81 endpoint I5: response keys are only PairedCompanionSession fields plus scopeRawValue; got \(keys.sorted())")

    let forbiddenKeys: Set<String> = [
        "sessionSecret",
        "signingKey",
        "localPath",
        "cwd",
        "pid",
        "tmuxTarget",
        "rawAPNSToken",
        "transcriptBody"
    ]
    expect(keys.intersection(forbiddenKeys).isEmpty, "Ticket81 endpoint I5: response has no unrelated secret/local-state keys")

    let text = String(decoding: data, as: UTF8.self)
    expect(!text.contains(authDir.path), "Ticket81 endpoint I5: response does not include auth directory path")
    expect(!text.contains("signing.key"), "Ticket81 endpoint I5: response does not include signing key filename")
    expect(!text.contains("auth.db"), "Ticket81 endpoint I5: response does not include auth database filename")
    expect(!text.contains(pairingCredential), "Ticket81 endpoint I5: response does not echo one-time pairing credential")
}
