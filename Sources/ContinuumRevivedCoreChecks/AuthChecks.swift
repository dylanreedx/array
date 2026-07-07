import Darwin
import Dispatch
import Foundation
import ContinuumRevivedCore

func runAuthChecks() throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedAuthResult()
    Task {
        do {
            try await runAuthChecksAsync()
            box.result = .success(())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    try box.result?.get()
}

private func runAuthChecksAsync() async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let signingKey = Data((0..<32).map { UInt8($0 + 1) })

    try await runScopeAuthSuite(clock: clock, signingKey: signingKey)
    try await runBootstrapAuthSuite(clock: clock, signingKey: signingKey)
    try await runPairingAuthSuite()
    try await runPairingTokenTicket60Suite(signingKey: signingKey)
    try await runSessionAuthSuite()
    try await runMessageScopeSuite(signingKey: signingKey)
    try await runCompanionAuthServiceSuite()
    try runPairedCompanionSessionSuite()
    try await runAuthRealPathSuite()
    try runSigningKeyRestartSuite()

    print("AuthChecks passed")
}

private final class LockedAuthResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    var result: Result<Void, Error>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class LockedValueResult<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func runScopeAuthSuite(clock: FakeClock, signingKey: Data) async throws {
    expect(Scope.observer.contains(.orchestrationRead), "Auth Scope: observer can read orchestration")
    expect(!Scope.observer.contains(.orchestrationOperate), "Auth Scope: observer cannot operate orchestration")
    expect(Scope.observer.isSubset(of: .admin), "Auth Scope: admin is a superset of observer")

    let encoded = try JSONEncoder().encode(Scope.admin)
    let decoded = try JSONDecoder().decode(Scope.self, from: encoded)
    expect(decoded == .admin, "Auth Scope: rawValue round-trips through Codable")

    let observerGrant = BootstrapGrant(credential: "observer-bootstrap", scopes: .observer)
    let observerPairing = PairingStore(clock: clock, bootstrapGrant: observerGrant)
    let sessions = SessionStore(signingKey: signingKey, clock: clock)
    await expectAuthError(
        try await sessions.exchange(
            credential: observerGrant.credential,
            requested: .admin,
            subject: "observer-device",
            pairingStore: observerPairing
        ),
        .scopeNotGranted,
        "Auth Scope: observer ceiling cannot mint admin"
    )

    let adminGrant = BootstrapGrant(credential: "admin-bootstrap", scopes: .admin)
    let adminPairing = PairingStore(clock: clock, bootstrapGrant: adminGrant)
    let observerSession = try await sessions.exchange(
        credential: adminGrant.credential,
        requested: .observer,
        subject: "phone",
        pairingStore: adminPairing
    )
    expect(observerSession.scopes == .observer, "Auth Scope: admin grant can down-scope to observer exactly")
}

private func runBootstrapAuthSuite(clock: FakeClock, signingKey: Data) async throws {
    let generated = try BootstrapGrant.seed()
    expect(generated.credential.count == 64, "Auth BootstrapGrant: seed is 64 hex characters")
    expect(generated.credential.allSatisfy { ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0)) },
           "Auth BootstrapGrant: seed uses lowercase hex only")

    let grant = BootstrapGrant(credential: "bootstrap-admin", scopes: .admin)
    let pairing = PairingStore(clock: clock, bootstrapGrant: grant)
    let sessions = SessionStore(signingKey: signingKey, clock: clock)
    let first = try await sessions.exchange(credential: grant.credential, requested: .admin, subject: "mac-local", pairingStore: pairing)
    let second = try await sessions.exchange(credential: grant.credential, requested: .admin, subject: "mac-local", pairingStore: pairing)
    expect(first.scopes == .admin && second.scopes == .admin, "Auth BootstrapGrant: repeated exchanges preserve admin scope")
    expect(first.id != second.id && first.token != second.token, "Auth BootstrapGrant: re-exchange creates a fresh session")

    let expiredGrant = BootstrapGrant(
        credential: "expired-bootstrap",
        scopes: .admin,
        expiresAt: clock.now().addingTimeInterval(-1)
    )
    let expiredPairing = PairingStore(clock: clock, bootstrapGrant: expiredGrant)
    await expectAuthError(
        try await expiredPairing.consume(expiredGrant.credential),
        .expired,
        "Auth BootstrapGrant: expired bootstrap grant is rejected by TTL"
    )

    await expectAuthError(
        try await sessions.exchange(credential: "not-a-bootstrap", requested: .admin, subject: "mac-local", pairingStore: pairing),
        .unknown,
        "Auth BootstrapGrant: random credential is unknown"
    )

    await expectAuthError(
        try await sessions.exchange(
            credential: grant.credential,
            requested: [.admin, Scope(rawValue: 1 << 10)],
            subject: "mac-local",
            pairingStore: pairing
        ),
        .scopeNotGranted,
        "Auth BootstrapGrant: request outside grant ceiling fails"
    )
}

private func runPairingAuthSuite() async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_100_000))
    let pairing = PairingStore(clock: clock)

    let issued = try await pairing.issue(scopes: .observer, ttl: 300, label: "phone")
    expect(issued.credential.count == 12, "Auth PairingStore: credential length is 12")
    let consumed = try await pairing.consume(issued.credential)
    expect(consumed.scopes == .observer, "Auth PairingStore: first consume returns issued observer grant")
    await expectAuthError(
        try await pairing.consume(issued.credential),
        .alreadyUsed,
        "Auth PairingStore: second consume is alreadyUsed"
    )

    let expired = try await pairing.issue(scopes: .observer, ttl: 1, label: "expired")
    clock.advance(by: 2)
    await expectAuthError(
        try await pairing.consume(expired.credential),
        .expired,
        "Auth PairingStore: expired credential is rejected"
    )

    let revoked = try await pairing.issue(scopes: .observer, ttl: 300, label: "revoked")
    await pairing.revoke(id: revoked.id)
    await expectAuthError(
        try await pairing.consume(revoked.credential),
        .revoked,
        "Auth PairingStore: revoked credential is rejected"
    )

    await expectAuthError(
        try await pairing.consume("BADBADBADBAD"),
        .unknown,
        "Auth PairingStore: unknown credential is rejected"
    )
}

private func runPairingTokenTicket60Suite(signingKey: Data) async throws {
    try runPairingAlphabetBiasCheck()
    try await runPairingConcurrentConsumeCheck()
    try await runPairingBackendExchangeRaceCheck(signingKey: signingKey)
    try await runPairingDownscopeTrioCheck(signingKey: signingKey)
    try await runSessionBitFlipCheck()
    try runPairingURLRoundTripCheck()
    try runRegistryPairedDevicesDecodeCheck()
}

private func runPairingAlphabetBiasCheck() throws {
    let sampleCount = 100_000
    var frequencies = Dictionary(uniqueKeysWithValues: PairingAlphabet.symbols.map { ($0, 0) })
    for _ in 0..<sampleCount {
        let credential = try PairingAlphabet.credential()
        expect(credential.count == 12, "Ticket60 PairingAlphabet: credential length is 12")
        expect(PairingAlphabet.containsOnlySymbols(credential), "Ticket60 PairingAlphabet: credential uses only crowd-safe symbols")
        for character in credential {
            frequencies[character, default: 0] += 1
        }
    }

    let draws = sampleCount * 12
    let expected = Double(draws) / Double(PairingAlphabet.symbols.count)
    let standardDeviation = sqrt(Double(draws) * (1.0 / 32.0) * (31.0 / 32.0))
    let tolerance = 4.5 * standardDeviation
    let maxDeviation = frequencies.values.map { abs(Double($0) - expected) }.max() ?? 0
    expect(maxDeviation <= tolerance, "Ticket60 PairingAlphabet: max frequency deviation \(maxDeviation) <= \(tolerance)")
    print("Ticket60 PairingAlphabet sample draws=\(draws) maxDeviation=\(String(format: "%.2f", maxDeviation)) tolerance=\(String(format: "%.2f", tolerance))")
}

private func runPairingConcurrentConsumeCheck() async throws {
    let pairing = PairingStore(clock: FakeClock(start: Date(timeIntervalSince1970: 1_800_400_000)))
    let grant = try await pairing.issue(scopes: .observer, ttl: 300, label: "race")
    let attempts = 50
    let results = await withTaskGroup(of: Result<PairingGrant, AuthError>.self) { group in
        for _ in 0..<attempts {
            group.addTask {
                do {
                    return .success(try await pairing.consume(grant.credential))
                } catch let error as AuthError {
                    return .failure(error)
                } catch {
                    return .failure(.unknown)
                }
            }
        }
        var gathered: [Result<PairingGrant, AuthError>] = []
        for await result in group {
            gathered.append(result)
        }
        return gathered
    }
    let successes = results.filter {
        if case .success = $0 { return true }
        return false
    }
    let alreadyUsed = results.filter {
        if case .failure(.alreadyUsed) = $0 { return true }
        return false
    }
    expect(successes.count == 1, "Ticket60 PairingStore: concurrent consume has exactly one success, got \(successes.count)")
    expect(alreadyUsed.count == attempts - 1, "Ticket60 PairingStore: concurrent consume losers are alreadyUsed, got \(alreadyUsed.count)")
}

private func runPairingBackendExchangeRaceCheck(signingKey: Data) async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-pairing-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let databaseURL = tempDir.appendingPathComponent("auth.db")
    let issuingPairing = try PairingStore(databaseURL: databaseURL)
    let grant = try await issuingPairing.issue(scopes: .observer, ttl: 300, label: "backend-race")
    let attempts = 50

    let results = await withTaskGroup(of: Result<AuthSession, AuthError>.self) { group in
        for index in 0..<attempts {
            group.addTask {
                do {
                    let pairing = try PairingStore(databaseURL: databaseURL)
                    let sessions = try SessionStore(signingKey: signingKey, databaseURL: databaseURL)
                    return .success(try await sessions.exchange(
                        credential: grant.credential,
                        requested: .observer,
                        subject: "race-phone-\(index)",
                        pairingStore: pairing
                    ))
                } catch let error as AuthError {
                    return .failure(error)
                } catch {
                    return .failure(.unknown)
                }
            }
        }

        var gathered: [Result<AuthSession, AuthError>] = []
        for await result in group {
            gathered.append(result)
        }
        return gathered
    }

    let successes = results.compactMap { result -> AuthSession? in
        if case let .success(session) = result { return session }
        return nil
    }
    let alreadyUsed = results.filter {
        if case .failure(.alreadyUsed) = $0 { return true }
        return false
    }
    expect(successes.count == 1, "Ticket60 backend race: exactly one exchange succeeds across on-disk stores, got \(successes.count)")
    expect(alreadyUsed.count == attempts - 1, "Ticket60 backend race: losers are alreadyUsed across on-disk stores, got \(alreadyUsed.count)")
    expect(Set(successes.map(\.id)).count == 1, "Ticket60 backend race: only one distinct session id returned")

    let sessionRows = try sqliteScalar(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM auth_sessions")
    let consumedRows = try sqliteScalar(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM pairing_grants WHERE credential = '\(grant.credential)' AND consumed_at IS NOT NULL")
    expect(sessionRows == 1, "Ticket60 backend race: SQLite persisted exactly one auth_sessions row, got \(sessionRows)")
    expect(consumedRows == 1, "Ticket60 backend race: SQLite persisted exactly one consumed pairing row, got \(consumedRows)")
    print("Ticket60 backend race attempts=\(attempts) successes=\(successes.count) alreadyUsed=\(alreadyUsed.count) sessionRows=\(sessionRows)")
}

private func runPairingDownscopeTrioCheck(signingKey: Data) async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_500_000))
    let sessions = SessionStore(signingKey: signingKey, clock: clock)

    let rejectPairing = PairingStore(clock: clock)
    let rejectGrant = try await rejectPairing.issue(scopes: .observer, ttl: 300, label: "reject")
    await expectAuthError(
        try await sessions.exchange(
            credential: rejectGrant.credential,
            requested: [.orchestrationRead, .orchestrationOperate],
            subject: "phone",
            pairingStore: rejectPairing
        ),
        .scopeNotGranted,
        "Ticket60 Downscope: superset request is rejected"
    )

    let subsetPairing = PairingStore(clock: clock)
    let subsetGrant = try await subsetPairing.issue(scopes: .operator, ttl: 300, label: "subset")
    let subset = try await sessions.exchange(
        credential: subsetGrant.credential,
        requested: .orchestrationRead,
        subject: "phone",
        pairingStore: subsetPairing
    )
    expect(subset.scopes == .orchestrationRead, "Ticket60 Downscope: subset request mints only requested scope")

    let nilPairing = PairingStore(clock: clock)
    let nilGrant = try await nilPairing.issue(scopes: .observer, ttl: 300, label: "nil")
    let ceiling = try await sessions.exchange(
        credential: nilGrant.credential,
        requested: nil,
        subject: "phone",
        pairingStore: nilPairing
    )
    expect(ceiling.scopes == .observer, "Ticket60 Downscope: nil requested grants ceiling")
}

private func runSessionBitFlipCheck() async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_600_000))
    let key = Data((0..<32).map { UInt8($0 + 11) })
    let store = SessionStore(signingKey: key, clock: clock)
    let session = try await store.issue(scopes: .observer, subject: "phone", ttl: 300)
    let parts = session.token.split(separator: ".", maxSplits: 1).map(String.init)
    expect(parts.count == 2, "Ticket60 Session token: token has payload and tag")

    await expectAuthError(
        try await store.verify(mutateFirstCharacter(parts[0]) + "." + parts[1]),
        .invalidToken,
        "Ticket60 Session token: flipped payload fails"
    )
    await expectAuthError(
        try await store.verify(parts[0] + "." + mutateFirstCharacter(parts[1])),
        .invalidToken,
        "Ticket60 Session token: flipped tag fails"
    )

    let wrongKeyStore = SessionStore(signingKey: Data((0..<32).map { UInt8(200 - $0) }), clock: clock)
    await expectAuthError(
        try await wrongKeyStore.verify(session.token),
        .invalidToken,
        "Ticket60 Session token: wrong signing key fails"
    )

    let verified = try await store.verify(session.token)
    expect(verified.id == session.id && verified.scopes == session.scopes, "Ticket60 Session token: valid token round-trips")
}

private func runPairingURLRoundTripCheck() throws {
    let credential = "23456789ABCD"
    let url = PairingURL.issue(credential: credential, scopes: .observer)
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    expect(url.absoluteString.contains("#token="), "Ticket60 PairingURL: URL contains #token= fragment")
    expect(components?.queryItems == nil, "Ticket60 PairingURL: URL has no query items")
    expect(!(components?.fragment ?? "").isEmpty, "Ticket60 PairingURL: fragment is non-empty")
    expect(PairingURL.parse(url) == credential, "Ticket60 PairingURL: parse returns same credential")
}

private func runRegistryPairedDevicesDecodeCheck() throws {
    let json = """
    {
      "schemaVersion": 1,
      "lastActiveWorkspaceId": null,
      "lastActiveProjectId": null,
      "workspaces": [],
      "projects": [],
      "settings": {
        "preferredEditor": "auto",
        "zoomModifier": "command",
        "openLastProjectOnLaunch": true
      }
    }
    """.data(using: .utf8)!
    let registry = try JSONDecoder().decode(Registry.self, from: json)
    expect(registry.pairedDevices == [], "Ticket60 Registry: missing pairedDevices decodes as empty")
}

private func runSessionAuthSuite() async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_200_000))
    let store = SessionStore(signingKey: Data((0..<32).map { UInt8(255 - $0) }), clock: clock)
    let session = try await store.issue(scopes: .observer, subject: "phone", ttl: 300)
    let verified = try await store.verify(session.token)
    expect(verified.id == session.id && verified.scopes == .observer, "Auth SessionStore: issued token verifies through HMAC and row lookup")

    let parts = session.token.split(separator: ".", maxSplits: 1).map(String.init)
    let badToken = parts[0] + "." + mutateFirstCharacter(parts[1])
    await expectAuthError(
        try await store.verify(badToken),
        .invalidToken,
        "Auth SessionStore: mutated HMAC is invalidToken"
    )

    let short = try await store.issue(scopes: .observer, subject: "phone", ttl: 1)
    clock.advance(by: 2)
    await expectAuthError(
        try await store.verify(short.token),
        .expired,
        "Auth SessionStore: expired token is rejected"
    )

    let revoked = try await store.issue(scopes: .observer, subject: "phone", ttl: 300)
    await store.revoke(id: revoked.id)
    await expectAuthError(
        try await store.verify(revoked.token),
        .revoked,
        "Auth SessionStore: revoked token is rejected"
    )
}

private func runMessageScopeSuite(signingKey: Data) async throws {
    let store = SessionStore(signingKey: signingKey, clock: FakeClock())
    let observer = try await store.issue(scopes: .observer, subject: "phone", ttl: 300)

    for message in ControlMessage.allCases {
        expect(requiredScope[message] != nil, "Auth MessageScope: \(message.rawValue) has a required scope")
    }
    expect(ControlMessage.allCases.count == requiredScope.count, "Auth MessageScope: table covers all current control messages")

    try authorize(.subscribeActivity, session: observer)
    expect(true, "Auth MessageScope: observer can subscribe to activity")
    expectThrowsAuth(.missingScope(.orchestrationOperate), "Auth MessageScope: observer cannot move tiles") {
        try authorize(.moveTile, session: observer)
    }
    expectThrowsAuth(.missingScope(.terminalOperate), "Auth MessageScope: observer cannot send keys") {
        try authorize(.sendKeys, session: observer)
    }
}

private func runCompanionAuthServiceSuite() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-companion-auth-\(UUID().uuidString)", isDirectory: true)
    let authDir = tempDir.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_800_000))
    let first = try CompanionAuthService(authDirectory: authDir, clock: clock, instanceDisplayName: "Continuum QA")
    let firstInstance = try await first.instance()
    let firstOwner = try await first.owner()
    expect(!firstInstance.id.uuidString.isEmpty, "Ticket79 CompanionAuthService: instance id is generated")
    expect(firstInstance.displayName == "Continuum QA", "Ticket79 CompanionAuthService: display name persists from first launch")
    expect(!firstOwner.id.uuidString.isEmpty, "Ticket79 CompanionAuthService: local owner id is generated")

    let relaunched = try CompanionAuthService(authDirectory: authDir, clock: clock, instanceDisplayName: "Ignored Relaunch Name")
    let relaunchedInstance = try await relaunched.instance()
    let relaunchedOwner = try await relaunched.owner()
    expect(relaunchedInstance.id == firstInstance.id, "Ticket79 CompanionAuthService: instance id is stable across restart")
    expect(relaunchedInstance.displayName == "Continuum QA", "Ticket79 CompanionAuthService: relaunch does not replace display name")
    expect(relaunchedOwner.id == firstOwner.id, "Ticket79 CompanionAuthService: owner id is stable across restart")

    let issued = try await relaunched.issuePairingCredential(scopes: .operator, ttl: 300, label: "Dylan iPhone")
    let exchange = try await relaunched.exchangePairingCredential(
        issued.credential,
        requested: .observer,
        deviceLabel: "Dylan iPhone 15"
    )
    expect(exchange.instanceId == firstInstance.id, "Ticket79 CompanionAuthService: exchange payload is bound to instance id")
    expect(exchange.userId == firstOwner.id, "Ticket79 CompanionAuthService: exchange payload is bound to local owner")
    expect(exchange.device.label == "Dylan iPhone 15", "Ticket79 CompanionAuthService: device label comes from exchange subject")
    expect(exchange.session.scopes == .observer, "Ticket79 CompanionAuthService: exchange can down-scope to observer")

    let devices = try await relaunched.listDevices()
    expect(devices.count == 1, "Ticket79 CompanionAuthService: exactly one persistent device after one exchange, got \(devices.count)")
    expect(devices[0].id == exchange.device.id && devices[0].sessionId == exchange.session.id,
           "Ticket79 CompanionAuthService: device row stores session id")

    let verified = try await relaunched.verifySessionToken(exchange.session.token)
    expect(verified.deviceId == exchange.device.id, "Ticket79 CompanionAuthService: verified payload retains device id")
    expect(verified.instanceId == firstInstance.id, "Ticket79 CompanionAuthService: verified payload retains instance id")
    expectThrowsAuth(.missingScope(.orchestrationOperate), "Ticket79 CompanionAuthService: observer session cannot move tile") {
        try authorize(.moveTile, grantedScopes: verified.scopes)
    }
    expectThrowsAuth(.missingScope(.orchestrationOperate), "Ticket79 CompanionAuthService: observer session cannot respond to approval") {
        try authorize(.respondToApproval, grantedScopes: verified.scopes)
    }

    let operatorGrant = try await relaunched.issuePairingCredential(scopes: .operator, ttl: 300, label: "Operator iPhone")
    let operatorExchange = try await relaunched.exchangePairingCredential(
        operatorGrant.credential,
        requested: .operator,
        deviceLabel: "Operator iPhone"
    )
    let operatorVerified = try await relaunched.verifySessionToken(operatorExchange.session.token)
    try authorize(.respondToApproval, grantedScopes: operatorVerified.scopes)
    expect(true, "Ticket79 CompanionAuthService: operator session can respond to approval")

    await expectAuthError(
        try await relaunched.exchangePairingCredential(
            issued.credential,
            requested: .observer,
            deviceLabel: "Replay iPhone"
        ),
        .alreadyUsed,
        "Ticket79 CompanionAuthService: pairing credential reuse fails"
    )

    try await relaunched.revokeDevice(exchange.device.id)
    await expectAuthError(
        try await relaunched.verifySessionToken(exchange.session.token),
        .revoked,
        "Ticket79 CompanionAuthService: revoked device makes verify fail"
    )
}

private func runPairedCompanionSessionSuite() throws {
    let session = PairedCompanionSession(
        instanceId: UUID(),
        userId: UUID(),
        deviceId: UUID(),
        sessionId: UUID(),
        token: "fixture-session-token",
        scopes: .operator,
        issuedAt: Date(timeIntervalSince1970: 1_800_900_000),
        expiresAt: Date(timeIntervalSince1970: 1_808_676_000)
    )
    let store = InMemoryPairedCompanionSessionStore()
    expect(store.loadState() == .unpaired, "Ticket79 PairedSessionStore: empty store is unpaired")
    try store.save(session)
    expect(store.loadState() == .paired(session), "Ticket79 PairedSessionStore: saved session loads as paired")
    let capability = CompanionUICapability(state: store.loadState())
    expect(capability.canStartTransport, "Ticket79 CompanionUICapability: paired session can start transport")
    expect(capability.scope == .operator, "Ticket79 CompanionUICapability: scope derives from paired session")
    expect(capability.canRespondToApproval, "Ticket79 CompanionUICapability: operator paired session can approve")
    try store.clear()
    let clearedCapability = CompanionUICapability(state: store.loadState())
    expect(!clearedCapability.canStartTransport, "Ticket79 CompanionUICapability: unpaired state does not start CloudKit")
    expect(clearedCapability.scope == [], "Ticket79 CompanionUICapability: unpaired state has no scope")
}

private func runAuthRealPathSuite() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-auth-\(UUID().uuidString)")
    let authDir = tempDir.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let key = try SessionStore.loadOrCreateSigningKey(in: authDir)
    expect(key.count == 32, "Auth real path: signing key is 32 bytes")
    let keyURL = authDir.appendingPathComponent("signing.key")
    var statBuf = stat()
    expect(stat(keyURL.path, &statBuf) == 0, "Auth real path: signing.key can be stat'd")
    expect((statBuf.st_mode & 0o777) == 0o600, "Auth real path: signing.key permissions are 0600")

    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_300_000))
    let bootstrap = BootstrapGrant(credential: "realpath-bootstrap", scopes: .admin)
    let dbURL = authDir.appendingPathComponent("auth.db")
    let pairing = try PairingStore(clock: clock, bootstrapGrant: bootstrap, databaseURL: dbURL)
    let sessions = try SessionStore(signingKey: key, clock: clock, databaseURL: dbURL)
    let admin = try await sessions.exchange(credential: bootstrap.credential, requested: .admin, subject: "mac-local", pairingStore: pairing)
    let verifiedAdmin = try await sessions.verify(admin.token)
    expect(verifiedAdmin.scopes == .admin, "Auth real path: bootstrap admin token verifies")

    let oneTime = try await pairing.issue(scopes: .observer, ttl: 300, label: "phone")
    let observer = try await sessions.exchange(credential: oneTime.credential, requested: .observer, subject: "phone", pairingStore: pairing)
    let verifiedObserver = try await sessions.verify(observer.token)
    expect(verifiedObserver.scopes == .observer, "Auth real path: observer pairing token verifies")
    var dbStat = stat()
    expect(stat(dbURL.path, &dbStat) == 0, "Auth real path: auth.db can be stat'd")
    expect((dbStat.st_mode & 0o777) == 0o600, "Auth real path: auth.db permissions are 0600")

    let relaunchedSessions = try SessionStore(signingKey: key, clock: clock, databaseURL: dbURL)
    let relaunchedObserver = try await relaunchedSessions.verify(observer.token)
    expect(relaunchedObserver.id == observer.id && relaunchedObserver.scopes == .observer,
           "Auth real path: fresh SessionStore verifies persisted observer session")

    let relaunchedPairing = try PairingStore(clock: clock, bootstrapGrant: bootstrap, databaseURL: dbURL)
    await expectAuthError(
        try await relaunchedSessions.exchange(
            credential: oneTime.credential,
            requested: .observer,
            subject: "phone-2",
            pairingStore: relaunchedPairing
        ),
        .alreadyUsed,
        "Auth real path: consumed pairing state survives fresh PairingStore"
    )
    expectThrowsAuth(.missingScope(.orchestrationOperate), "Auth real path: observer moveTile denied") {
        try authorize(.moveTile, session: observer)
    }
    try authorize(.subscribeActivity, session: observer)

    let measurements: [String: JSONValue] = [
        "token_length": .int(admin.token.count),
        "scopes_rawValue": .int(admin.scopes.rawValue),
        "session_id": .string(admin.id.uuidString),
        "credential_length": .int(oneTime.credential.count),
        "exchange_ok": .bool(true),
        "double_exchange_error": .string(AuthError.alreadyUsed.description),
        "move_tile_denied": .bool(true),
        "subscribe_activity_allowed": .bool(true),
        "signing_key_mode": .string(String(format: "%03o", statBuf.st_mode & 0o777)),
        "auth_db_mode": .string(String(format: "%03o", dbStat.st_mode & 0o777)),
        "fresh_session_store_verified": .bool(true),
        "fresh_pairing_store_rejected_reuse": .bool(true)
    ]
    let manifest = InvariantManifest(
        invariantId: "ticket54-auth",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: clock.now()),
        measurements: measurements,
        outcome: InvariantOutcome.pass.rawValue
    )
    try writeAndVerify(manifest)
}

func runAuthSigningKeyRestartSubprocessIfRequested() throws -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment["CONTINUUM_AUTH_RESTART_MODE"] else { return false }
    guard let authDirectoryPath = environment["CONTINUUM_AUTH_RESTART_AUTH_DIR"] else {
        throw NSError(domain: "AuthRestart", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing CONTINUUM_AUTH_RESTART_AUTH_DIR"])
    }
    guard let databasePath = environment["CONTINUUM_AUTH_RESTART_DATABASE_URL"] else {
        throw NSError(domain: "AuthRestart", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing CONTINUUM_AUTH_RESTART_DATABASE_URL"])
    }
    let authDirectory = URL(fileURLWithPath: authDirectoryPath, isDirectory: true)
    let databaseURL = URL(fileURLWithPath: databasePath)
    let tokenURL = authDirectory.appendingPathComponent("session.token")
    let sessionIDURL = authDirectory.appendingPathComponent("session.id")
    let key = try SessionStore.loadOrCreateSigningKey(in: authDirectory)
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_700_000))

    switch mode {
    case "sign":
        let store = try SessionStore(signingKey: key, clock: clock, databaseURL: databaseURL)
        let session = try awaitSync { try await store.issue(scopes: .observer, subject: "restart-phone", ttl: 300) }
        try session.token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try session.id.uuidString.write(to: sessionIDURL, atomically: true, encoding: .utf8)
    case "verify":
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
        let sessionID = try String(contentsOf: sessionIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store = try SessionStore(signingKey: key, clock: clock, databaseURL: databaseURL)
        let verified = try awaitSync { try await store.verify(token) }
        expect(verified.id.uuidString == sessionID, "Ticket60 signing restart: SessionStore.verify accepts token issued before restart")
        expect(verified.scopes == .observer, "Ticket60 signing restart: verified session preserves scopes")
    default:
        throw NSError(domain: "AuthRestart", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown CONTINUUM_AUTH_RESTART_MODE \(mode)"])
    }
    return true
}

private func runSigningKeyRestartSuite() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-auth-restart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try runRestartChild(mode: "sign", authDirectory: tempDir)
    try runRestartChild(mode: "verify", authDirectory: tempDir)
}

private func runRestartChild(mode: String, authDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = []
    var environment = ProcessInfo.processInfo.environment
    environment["CONTINUUM_AUTH_RESTART_MODE"] = mode
    environment["CONTINUUM_AUTH_RESTART_AUTH_DIR"] = authDirectory.path
    environment["CONTINUUM_AUTH_RESTART_DATABASE_URL"] = authDirectory.appendingPathComponent("auth.db").path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    expect(process.terminationStatus == 0, "Ticket60 signing restart: child \(mode) exited \(process.terminationStatus)")
}

private func sqliteScalar(databaseURL: URL, sql: String) throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]

    let output = Pipe()
    let errorOutput = Pipe()
    process.standardOutput = output
    process.standardError = errorOutput
    try process.run()
    process.waitUntilExit()

    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "AuthSQLiteCheck",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "sqlite3 failed: \(stderr)"]
        )
    }
    guard let value = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw NSError(
            domain: "AuthSQLiteCheck",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "sqlite3 returned non-integer output: \(stdout)"]
        )
    }
    return value
}

private func awaitSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedValueResult<T>()
    Task {
        do {
            box.result = Result<T, Error>.success(try await body())
        } catch {
            box.result = Result<T, Error>.failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

private func expectAuthError<T>(_ expression: @autoclosure () async throws -> T, _ expected: AuthError, _ message: String) async {
    do {
        _ = try await expression()
        expect(false, message)
    } catch let error as AuthError {
        expect(error == expected, "\(message): expected \(expected), got \(error)")
    } catch {
        expect(false, "\(message): expected \(expected), got non-auth error \(error)")
    }
}

private func expectThrowsAuth(_ expected: AuthError, _ message: String, _ body: () throws -> Void) {
    do {
        try body()
        expect(false, message)
    } catch let error as AuthError {
        expect(error == expected, "\(message): expected \(expected), got \(error)")
    } catch {
        expect(false, "\(message): expected \(expected), got non-auth error \(error)")
    }
}

private func mutateFirstCharacter(_ value: String) -> String {
    guard let first = value.first else { return "A" }
    let replacement: Character = first == "A" ? "B" : "A"
    return String(replacement) + String(value.dropFirst())
}
