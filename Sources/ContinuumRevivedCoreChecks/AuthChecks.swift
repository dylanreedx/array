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
    try await runSessionAuthSuite()
    try await runMessageScopeSuite(signingKey: signingKey)
    try await runAuthRealPathSuite()

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
    let pairing = PairingStore(clock: clock, bootstrapGrant: bootstrap)
    let sessions = SessionStore(signingKey: key, clock: clock)
    let admin = try await sessions.exchange(credential: bootstrap.credential, requested: .admin, subject: "mac-local", pairingStore: pairing)
    let verifiedAdmin = try await sessions.verify(admin.token)
    expect(verifiedAdmin.scopes == .admin, "Auth real path: bootstrap admin token verifies")

    let oneTime = try await pairing.issue(scopes: .observer, ttl: 300, label: "phone")
    let observer = try await sessions.exchange(credential: oneTime.credential, requested: .observer, subject: "phone", pairingStore: pairing)
    let verifiedObserver = try await sessions.verify(observer.token)
    expect(verifiedObserver.scopes == .observer, "Auth real path: observer pairing token verifies")
    await expectAuthError(
        try await sessions.exchange(credential: oneTime.credential, requested: .observer, subject: "phone-2", pairingStore: pairing),
        .alreadyUsed,
        "Auth real path: double exchange is alreadyUsed"
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
        "signing_key_mode": .string(String(format: "%03o", statBuf.st_mode & 0o777))
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
