import ContinuumRevivedCore
import Foundation

private let testToolDetailScope = AgentToolDetailScope(agentID: "checks-agent", threadID: "checks-thread", turnID: "checks-turn", provider: "checks")!
private func testToolDetailKey(_ id: AgentToolDetailID) -> AgentToolDetailKey { AgentToolDetailKey(scope: testToolDetailScope, providerItemID: id) }

func runAgentToolDetailStoreChecks() async throws {
    try await runAgentToolDetailPrivacyChecks()
    try await runAgentToolDetailIdentityCollisionChecks()
    try await runAgentToolDetailImplicitSensitivityChecks()
    try await runAgentToolDetailTruncationChecks()
    try await runAgentToolDetailAssociationAndExpiryChecks()
    try await runAgentToolDetailConcurrencyChecks()
    try await runAgentToolDetailPresentationChecks()
    try await runAgentToolDetailDisclosureCollisionChecks()
    try await runAgentToolDetailSemanticFileChecks()
    runAgentToolDetailSourceBoundaryChecks()
    try runAgentToolDetailCompileNegativeBoundaryCheck()
    print("Agent tool detail store checks passed: privacy redaction/fail-closed output, scoped cross-agent/turn identity, path-title retention/AX witnesses, implicit-path and compound-argv secret witnesses, cross-store reversed-arrival ties, provider ID bounds, argument/file bounds, truncation caps, start/end ordering, local expiry, same-ID concurrency, compact summaries, and source boundaries")
}

private func runAgentToolDetailSemanticFileChecks() async throws {
    let store = AgentToolDetailStore(limits: AgentToolDetailLimits(maxOutputBytes: 128, maxOutputLines: 4))
    let identity = testToolDetailKey("semantic-files")
    _ = await store.recordStart(.init(
        identity: identity,
        toolName: "Edit",
        fileChanges: [
            .init(action: .rename, path: "Sources/Before.swift", renamePath: "Sources/After.swift", diffPreview: "-before\n+after"),
            .init(action: .unknown, path: "/Users/private/secret.txt")
        ],
        parentItemID: "parent-explicit"
    ))
    let record = await store.detail(for: identity)
    expect(record?.fileChanges.map(\.action) == [.rename, .unknown], "typed file actions must survive the host-local store")
    expect(record?.fileChanges.first?.renamePath == "Sources/After.swift" && record?.fileChanges.first?.diffPreview == "-before\n+after",
           "explicit rename endpoints and bounded diff must survive the host-local store: \(String(describing: record?.fileChanges))")
    expect(record?.fileChanges.last?.path == "secret.txt", "absolute private paths must be reduced before retention")
    expect(record?.parentItemID == "parent-explicit", "explicit parent linkage must survive; absent linkage remains nil")
    let disclosure = record.map(AgentToolDetailPresenter.observableDisclosureText) ?? ""
    expect(disclosure.contains("Rename: Sources/Before.swift → Sources/After.swift") && disclosure.contains("-before"),
           "the shipped transcript presenter must expose stored semantic detail")

    let hostilePaths = [
        #"C:\Users\Alice\Secrets\token.txt"#,
        #"\\server\private\share\token.txt"#,
        "../../.ssh/id_rsa",
        "https://user:password@example.invalid/private/remote.swift",
        "file:///Users/alice/private/local.swift",
        "%2FUsers%2Falice%2Fprivate%2Fencoded.swift",
        "..%252F..%252Fsecret%252Fnested.swift",
        "Sources/evil\u{202E}txt.swift",
        String(repeating: "界", count: 300) + ".swift"
    ]
    let normalized = hostilePaths.map {
        AgentToolDetailObservation.FileChange(action: .edit, path: $0).path
    }
    expect(normalized.allSatisfy { !$0.contains("Alice") && !$0.contains("alice") && !$0.contains("server")
        && !$0.contains("..") && !$0.contains(":") && !$0.contains("@") && !$0.contains("\\")
        && !$0.unicodeScalars.contains(where: { $0.value == 0x202E }) && $0.utf8.count <= 240 },
        "file-change construction must reduce hostile path syntaxes to bounded non-private display forms: \(normalized)")
    expect(AgentToolDetailObservation.FileChange(action: .edit, path: "Sources/Foo.swift").path == "Sources/Foo.swift",
           "ordinary safe repository-relative paths must remain explicit")
    expect(AgentToolDetailObservation.FileChange(action: .edit, path: "Sources/user@host.swift").path == "Sources/user@host.swift",
           "a harmless @ in a repository-relative filename is not URL userinfo")

    let hostileIdentity = testToolDetailKey("semantic-hostile")
    _ = await store.recordStart(.init(identity: hostileIdentity, toolName: "Edit", fileChanges: [
        .init(action: .rename, path: #"C:\Users\Alice\Secrets\token.txt"#,
              renamePath: #"\\server\private\renamed.txt"#,
              diffPreview: "+ Authorization: Bearer credential-secret\n+ /Users/alice/private/file"),
        .init(action: .edit, path: "Sources/Safe.swift", diffPreview: "-old\n+new")
    ], parentItemID: "file:///Users/alice/private/parent", explicitSecrets: ["credential-secret"]))
    let hostileRecord = await store.detail(for: hostileIdentity)
    let hostileDisclosure = hostileRecord.map(AgentToolDetailPresenter.observableDisclosureText) ?? ""
    expect(!hostileDisclosure.contains("Alice") && !hostileDisclosure.contains("server")
        && !hostileDisclosure.contains("credential-secret") && !hostileDisclosure.contains("/Users/")
        && hostileDisclosure.contains("Safe.swift"),
        "store/presenter must redact hostile source, rename and diff while preserving safe explicit facts: \(hostileDisclosure) record=\(String(describing: hostileRecord))")
    expect(hostileRecord?.parentItemID == nil, "path/URL-shaped parent IDs must be dropped")

    // A direct provider closure bypasses the store; presenter defense-in-depth
    // must enforce the identical policy for disclosure and accessibility.
    var direct = AgentToolDetailRecord(identity: hostileIdentity, toolName: "Edit", updatedAt: Date(),
        fileChanges: [
            .init(action: .edit, path: #"C:\Users\Alice\Secrets\direct.swift"#,
                  diffPreview: "+ token=direct-secret\n+ /Users/alice/private"),
            .init(action: .write, path: "Sources/DirectSafe.swift", diffPreview: "+safe")
        ], parentItemID: #"\\server\private\parent"#)
    // Model a provider-owned mutable record that did not cross construction's
    // sanitizer. The final presenter boundary must independently neutralize it.
    direct.fileChanges = [
        .init(action: .edit, path: #"C:\Users\Alice\Secrets\direct.swift"#,
              diffPreview: "+ token%3Ddirect-secret\n+ %2FUsers%2Falice%2Fprivate"),
        .init(action: .write, path: "Sources/DirectSafe.swift", diffPreview: "+safe")
    ]
    direct.parentItemID = "token%3Ddirect-secret"
    let safeDirect = AgentToolDetailPresenter.sanitizedProviderRecord(direct)
    let directDisclosure = safeDirect.map(AgentToolDetailPresenter.observableDisclosureText) ?? ""
    let directAX = safeDirect.map { AgentToolDetailPresenter.expanded($0).accessibilitySummary } ?? ""
    let directSurface = directDisclosure + "\n" + directAX
    expect(!directSurface.contains("Alice") && !directSurface.contains("direct-secret")
        && !directSurface.contains("/Users/") && directSurface.contains("DirectSafe.swift"),
        "direct provider record must be safe in visible disclosure and accessibility: \(directSurface)")
    expect(safeDirect?.parentItemID == nil, "direct provider hostile parent must be dropped")

    let encodedHostile = [
        "%2FUsers%2Falice%2Fsecret", "%252FUsers%252Falice%252Fsecret",
        "%25252fUsers%25252falice%25252fsecret", "%2e%2e%2fsecret",
        "%2525252FUsers%2525252Falice%2525252Fsecret",
        "%252e%252e%255csecret", "file%3A%2F%2F%2Fprivate%2Fsecret",
        "%252Fvar%252Ffolders%252Fsecret", "C%3A%5cUsers%5cAlice%5csecret",
        "%255c%255cserver%255cprivate%255csecret",
        "https%3a%2F%2fuser%3Apassword%40host%2fsecret",
        "%2566%2569%256c%2565%253A%252F%252F%252Fhome%252Falice%252Fsecret"
    ]
    for (index, hostile) in encodedHostile.enumerated() {
        let encodedIdentity = testToolDetailKey(AgentToolDetailID("encoded-hostile-\(index)")!)
        _ = await store.recordStart(.init(identity: encodedIdentity, toolName: "Edit", fileChanges: [
            .init(action: .rename, path: "Sources/Safe.swift", renamePath: hostile,
                  diffPreview: "+ plausible \(hostile)")
        ], parentItemID: hostile))
        let encodedRecord = await store.detail(for: encodedIdentity)
        let visible = encodedRecord.map(AgentToolDetailPresenter.observableDisclosureText) ?? ""
        let ax = encodedRecord.map { AgentToolDetailPresenter.expanded($0).accessibilitySummary } ?? ""
        let surface = visible + "\n" + ax
        expect(encodedRecord?.parentItemID == nil && encodedRecord?.fileChanges.first?.diffPreview == "[REDACTED]"
            && !surface.contains(hostile) && !surface.lowercased().contains("password@host")
            && !surface.lowercased().contains("/users/") && !surface.lowercased().contains("/private/")
            && !surface.lowercased().contains("/var/folders/"),
            "encoded hostile parent/diff/rename must not survive storage, disclosure, or AX: \(hostile) => \(surface)")
    }
    let benignPercent = "+ progress 50%\n+ literal %zz and user@host\n+ trailing %"
    expect(AgentToolDetailDisplaySanitizer.diffPreview(benignPercent) == benignPercent,
           "ordinary percent text, malformed escapes and @ must retain authored diff bytes")
    let encodedCredential = "token%3Dsupersecretvalue"
    expect(AgentToolDetailDisplaySanitizer.parentItemID(encodedCredential) == nil,
           "percent-decoded parent credentials must fail closed")
    expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(encodedCredential)") == "[REDACTED]",
           "percent-decoded diff credentials must fail closed")
    for encodedControl in ["%00", "%2500", "%E2%80%AE", "%25E2%2580%25AE"] {
        expect(AgentToolDetailDisplaySanitizer.parentItemID(encodedControl) == nil,
               "decoded parent controls/bidi must fail closed: \(encodedControl)")
        expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(encodedControl)") == "[REDACTED]",
               "decoded diff controls/bidi must fail closed: \(encodedControl)")
    }
    func percentEncode(_ value: String) -> String {
        value.utf8.map { String(format: "%%%02X", $0) }.joined()
    }
    func encodedLayers(_ value: String) -> [String] {
        var result = [value]
        for _ in 0..<3 { result.append(percentEncode(result.last!)) }
        return result
    }
    let secretShapes = [
        "token=supersecretvalue", "api_key=sk-live-12345678",
        "Authorization: Bearer abc.def.ghi", "password=hunter-two"
    ]
    for secret in secretShapes {
        for variant in encodedLayers(secret) {
            expect(AgentToolDetailDisplaySanitizer.parentItemID(variant) == nil,
                   "raw/nested credential parent must fail closed: \(variant)")
            expect(AgentToolDetailDisplaySanitizer.path("Sources/\(variant).swift") == nil,
                   "raw/nested credential path must fail closed: \(variant)")
            expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(variant)") == "[REDACTED]",
                   "raw/nested credential diff must fail closed: \(variant)")
        }
    }
    let explicitRaw = "opaque-explicit-secret"
    let explicitEncoded = percentEncode(explicitRaw)
    for (secretCandidate, disclosedCandidate) in [
        (explicitRaw, percentEncode(explicitRaw)),
        (explicitRaw, percentEncode(percentEncode(explicitRaw))),
        (explicitEncoded, explicitRaw),
        (explicitEncoded, "prefix-\(percentEncode(explicitRaw))-suffix")
    ] {
        expect(AgentToolDetailDisplaySanitizer.parentItemID(disclosedCandidate, explicitSecrets: [secretCandidate]) == nil,
               "decoded/encoded explicit parent secret must fail closed")
        expect(AgentToolDetailDisplaySanitizer.path("Sources/\(disclosedCandidate).swift", explicitSecrets: [secretCandidate]) == nil,
               "decoded/encoded explicit path secret must fail closed")
        expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(disclosedCandidate)", explicitSecrets: [secretCandidate]) == "[REDACTED]",
               "decoded/encoded explicit diff secret must fail closed")
    }
    let bidiValues = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
    let unsafeEncodedScalars = ["%00", "%01", "%1F", "%7F", "%C2%80", "%C2%9F", "%0D", "%FF"]
        + bidiValues.map { scalar -> String in percentEncode(String(UnicodeScalar(scalar)!)) }
    for value in unsafeEncodedScalars.flatMap(encodedLayers) {
        expect(AgentToolDetailDisplaySanitizer.parentItemID(value) == nil,
               "encoded invalid/control/bidi parent must fail closed: \(value)")
        expect(AgentToolDetailDisplaySanitizer.path("Sources/\(value).swift") == nil,
               "encoded invalid/control/bidi path must fail closed: \(value)")
        expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(value)") == "[REDACTED]",
               "encoded invalid/control/bidi diff must fail closed: \(value)")
    }
    for allowed in ["%0A", "%09", "%250A", "%2509"] {
        expect(AgentToolDetailDisplaySanitizer.parentItemID(allowed) == nil,
               "decoded LF/tab remains forbidden in a single-line parent")
        expect(AgentToolDetailDisplaySanitizer.diffPreview("+ \(allowed)") != "[REDACTED]",
               "decoded LF/tab obeys the existing diff allowance")
    }
    let fourthLayer = percentEncode(percentEncode(percentEncode(percentEncode("/Users/alice/private"))))
    expect(AgentToolDetailDisplaySanitizer.parentItemID(fourthLayer) == nil
        && AgentToolDetailDisplaySanitizer.diffPreview("+ \(fourthLayer)") == "[REDACTED]",
        "residual fourth-layer escapes must fail closed")
    let safeControls = ["Sources/Safe.swift", "Sources/user@host.swift", "100%", "%zz", "trailing%", "opaque-id", "日本語-prose"]
    for value in safeControls {
        expect(AgentToolDetailDisplaySanitizer.path(value) == value, "safe path control must retain authored bytes: \(value)")
    }
    expect(AgentToolDetailDisplaySanitizer.parentItemID("opaque-id_日本語@host%") == "opaque-id_日本語@host%",
           "safe opaque Unicode parent ID must survive")
    expect(AgentToolDetailDisplaySanitizer.diffPreview("+ percent = 50%\n+ Unicode 日本語") == "+ percent = 50%\n+ Unicode 日本語",
           "safe percent and Unicode diff must survive")
    let encodedPayload = String(repeating: "%25252Fprivate%25252Fsecret ", count: 500)
    let encodedStart = Date()
    let encodedBounded = AgentToolDetailDisplaySanitizer.diffPreview(encodedPayload, maxBytes: 16_384, maxLines: 200)
    let encodedElapsed = Date().timeIntervalSince(encodedStart)
    expect(encodedBounded == "[REDACTED]" && encodedElapsed < 0.1,
           "maximum adversarial encoded payload must fail closed in bounded linear work: \(encodedElapsed)s")
    print(String(format: "AgentToolDetail encoded disclosure bound: %.6fs (budget 0.100000s)", encodedElapsed))
}

private func runAgentToolDetailPrivacyChecks() async throws {
    let emptyRawID = String()
    let controlRawID = "tool\u{0007}bad"
    let longRawID = String(repeating: "x", count: AgentToolDetailID.maxRawValueBytes + 1)
    let secretBearingRawID = "tool-token=abc"
    expect(AgentToolDetailID(emptyRawID) == nil, "AgentToolDetailID must reject empty IDs")
    expect(AgentToolDetailID(controlRawID) == nil, "AgentToolDetailID must reject control-bearing IDs")
    expect(AgentToolDetailID(longRawID) == nil, "AgentToolDetailID must reject over-bounded IDs")
    expect(AgentToolDetailID(secretBearingRawID) == nil, "AgentToolDetailID must reject secret-shaped IDs")

    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 1_000))
    let store = AgentToolDetailStore(
        clock: { clock.now() },
        timeToLive: 60,
        limits: AgentToolDetailLimits(
            maxArgumentKeyBytes: 24,
            maxFieldValueBytes: 256,
            maxFieldValueLines: 4,
            maxOutputBytes: 512,
            maxOutputLines: 8,
            maxArguments: 6,
            maxAffectedFiles: 8
        )
    )
    let rawSecret = "SECRET-token-123"
    let authSecret = "AUTH-session-456"
    let privateKey = "PRIVATE-signing-789"
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-privacy"),
        toolName: "bash",
        arguments: [
            AgentToolDetailField(key: "command", value: "curl -H 'Authorization: Bearer \(rawSecret)' --token argv-secret --data '{\"token\":\"json-secret\"}' https://user:pass@example.test?token=abc"),
            AgentToolDetailField(key: "password", value: rawSecret),
            AgentToolDetailField(key: "auth", value: authSecret),
            AgentToolDetailField(key: "session_key", value: "session=\(authSecret)"),
            AgentToolDetailField(key: "privateSigningKey", value: privateKey),
            AgentToolDetailField(key: "safe-\(authSecret)", value: "visible-value"),
            AgentToolDetailField(key: "ignored", value: "argument-count-limit")
        ],
        affectedFiles: [
            URL(fileURLWithPath: "/tmp/work/file.swift"),
            URL(string: "file://user:pass@localhost/tmp/work/\(rawSecret)/leaky.swift?token=abc#frag")!,
            URL(string: "https://example.test/not-a-file.swift?token=abc")!
        ],
        explicitSecrets: [rawSecret, "abc"]
    ))
    _ = await store.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-privacy"),
        output: "echoed \(rawSecret) auth \(authSecret) key \(privateKey) and token=abc",
        status: .completed,
        exitCode: 0,
        affectedFiles: [],
        explicitSecrets: [rawSecret, authSecret, privateKey, "session=\(authSecret)", "abc"]
    ))
    guard let detail = await store.detail(for: testToolDetailKey("tool-privacy")) else {
        fputs("FAIL: AgentToolDetailStore privacy: expected stored detail\n", stderr)
        Foundation.exit(1)
    }
    let expanded = AgentToolDetailPresenter.expanded(detail)
    let rendered = ([expanded.header] + expanded.arguments.map { "\($0.key)=\($0.value.text)" } + [expanded.output?.text ?? ""] + expanded.affectedFiles.map(\.absoluteString)).joined(separator: "\n")
    for secret in [rawSecret, authSecret, privateKey, "token=abc", "argv-secret", "json-secret", "user:pass"] {
        expect(!rendered.contains(secret), "AgentToolDetailStore privacy: \(secret) must be redacted/stripped before storage/presentation, got \(rendered)")
    }
    expect(rendered.contains("password=[REDACTED]") && rendered.contains("auth=[REDACTED]") && rendered.contains("privateSigningKey=[REDACTED]"),
           "AgentToolDetailStore privacy: sensitive-key arguments must be replaced, got \(rendered)")
    expect(expanded.arguments.count == 6, "AgentToolDetailStore privacy: maxArguments must bound argument retention, got \(expanded.arguments.count)")
    expect(expanded.arguments.allSatisfy { $0.key.utf8.count <= 24 },
           "AgentToolDetailStore privacy: argument keys must be byte-bounded, got \(expanded.arguments.map(\.key))")
    expect(detail.affectedFiles.count == 1 && detail.affectedFiles == [URL(fileURLWithPath: "/tmp/work/file.swift")],
           "AgentToolDetailStore privacy: secret-bearing affected URLs must be omitted, not rewritten with fabricated markers, got \(detail.affectedFiles)")

    let compact = AgentToolDetailPresenter.compact(detail)
    let accessibility = [compact.accessibilitySummary, expanded.accessibilitySummary].joined(separator: "\n")
    expect(!accessibility.contains(rawSecret) && !accessibility.contains("visible-value") && !accessibility.contains("echoed"),
           "AgentToolDetailPresenter privacy: accessibility summaries must not contain raw argument/output values, got \(accessibility)")

    let failClosedStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await failClosedStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-start-secret"),
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "password", value: rawSecret)],
        explicitSecrets: []
    ))
    _ = await failClosedStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-start-secret"),
        output: "provider echoed start-only password: \(rawSecret)",
        status: .completed,
        exitCode: 0,
        explicitSecrets: []
    ))
    let failClosed = await failClosedStore.detail(for: testToolDetailKey("tool-start-secret"))
    expect(failClosed?.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker,
           "AgentToolDetailStore privacy: start-only sensitive values without end context must omit output with honest marker, got \(String(describing: failClosed?.output?.text))")
    expect(failClosed?.output?.text.contains(rawSecret) == false,
           "AgentToolDetailStore privacy: fail-closed output must not retain echoed start secret")

    let outOfOrderPrivacyStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await outOfOrderPrivacyStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-end-before-secret-start"),
        output: "already echoed \(rawSecret)",
        status: .completed,
        explicitSecrets: []
    ))
    _ = await outOfOrderPrivacyStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-end-before-secret-start"),
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "password", value: rawSecret)]
    ))
    let outOfOrderPrivacy = await outOfOrderPrivacyStore.detail(for: testToolDetailKey("tool-end-before-secret-start"))
    expect(outOfOrderPrivacy?.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker,
           "AgentToolDetailStore privacy: end-before-start sensitive context must replace possible echoed output, got \(String(describing: outOfOrderPrivacy?.output?.text))")

    let zeroFileStore = AgentToolDetailStore(
        clock: { clock.now() },
        timeToLive: 60,
        limits: AgentToolDetailLimits(maxAffectedFiles: 0)
    )
    _ = await zeroFileStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-zero-files"),
        toolName: "edit",
        affectedFiles: [URL(fileURLWithPath: "/tmp/work/A.swift")]
    ))
    let zeroFileDetail = await zeroFileStore.detail(for: testToolDetailKey("tool-zero-files"))
    expect(zeroFileDetail?.affectedFiles == [],
           "AgentToolDetailStore files: maxAffectedFiles=0 must retain no files")

    let runtimeEvents: [AgentRuntimeEvent] = [
        .itemStarted(threadId: "thread", itemId: "tool-privacy", kind: .commandExecution, title: "bash"),
        .itemCompleted(threadId: "thread", itemId: "tool-privacy", kind: .commandExecution, status: .completed)
    ]
    let runtimeJSON = String(decoding: try JSONEncoder().encode(runtimeEvents), as: UTF8.self)
    expect(!runtimeJSON.contains(rawSecret) && !runtimeJSON.contains("visible-value"),
           "AgentRuntimeEvent privacy boundary: normalized events must not carry local tool detail, got \(runtimeJSON)")

    let draft = AgentActivityEventDraft(
        agentId: UUID(uuidString: "00000000-0000-4000-8000-000000000091")!,
        tileId: nil,
        runId: nil,
        tone: .tool,
        kind: "tool.bash",
        status: .working,
        summary: compact.summary,
        occurredAt: clock.now()
    )
    let activity = AgentActivityEvent(stamping: draft, sequence: 1, replicaId: UUID(uuidString: "00000000-0000-4000-8000-000000000092")!)
    let activityJSON = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self)
    expect(!activityJSON.contains(rawSecret) && !activityJSON.contains("visible-value") && !activityJSON.contains("echoed"),
           "AgentActivityEvent privacy boundary: sync-safe activity must not carry expanded local detail, got \(activityJSON)")
}

private func runAgentToolDetailIdentityCollisionChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 2_250))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let itemID: AgentToolDetailID = "reused-item"
    let first = AgentToolDetailKey(
        scope: AgentToolDetailScope(agentID: "agent-a", threadID: "thread-a", turnID: "turn-1", provider: "pi")!,
        providerItemID: itemID
    )
    let second = AgentToolDetailKey(
        scope: AgentToolDetailScope(agentID: "agent-b", threadID: "thread-b", turnID: "turn-9", provider: "pi")!,
        providerItemID: itemID
    )
    _ = await store.recordStart(AgentToolDetailStart(identity: first, toolName: "read"))
    _ = await store.recordEnd(AgentToolDetailEnd(identity: first, output: "first", status: .completed))
    _ = await store.recordStart(AgentToolDetailStart(identity: second, toolName: "edit"))
    _ = await store.recordEnd(AgentToolDetailEnd(identity: second, output: "second", status: .failed))
    let firstDetail = await store.detail(for: first)
    let secondDetail = await store.detail(for: second)
    expect(firstDetail?.toolName == "read" && firstDetail?.output?.text == "first",
           "AgentToolDetail identity: first agent/turn/thread must retain its reused item independently")
    expect(secondDetail?.toolName == "edit" && secondDetail?.output?.text == "second",
           "AgentToolDetail identity: second agent/turn/thread must retain its reused item independently")
    let ambiguousLookup = await store.detail(for: testToolDetailKey(itemID))
    expect(ambiguousLookup == nil,
           "AgentToolDetail identity: item-only lookup must fail closed when only scoped records exist")
    let identities = Set((await store.allDetails()).map(\.identity))
    expect(identities == Set([first, second]),
           "AgentToolDetail identity: provider item/tool call key must include every host-local scope component")

    let pathTitle = "/Users/example/project/run-tool"
    let pathStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await pathStore.recordStart(AgentToolDetailStart(
        identity: first, toolName: pathTitle
    ))
    let retained = await pathStore.detail(for: first)
    expect(retained?.toolName == "Tool",
           "AgentToolDetail privacy: path-bearing tool title must be omitted before retention")
    let providerRecord = AgentToolDetailRecord(
        identity: first, toolName: pathTitle, updatedAt: clock.now()
    )
    let compact = AgentToolDetailPresenter.compact(providerRecord)
    expect(compact.title == "Tool" && !compact.accessibilitySummary.contains(pathTitle),
           "AgentToolDetail privacy: provider-supplied path title must fail closed before AX")

    // RED witness for the untrusted provider composition seam: the current
    // presenter only rejects path-shaped names, so secret/control/unbounded
    // provider titles must fail before they can reach visible text or AX.
    for rawName in [
        "token=provider-secret",
        "control\u{0007}name",
        String(repeating: "x", count: AgentToolDetailLimits().maxToolNameBytes + 1)
    ] {
        let hostileRecord = AgentToolDetailRecord(identity: first, toolName: rawName, updatedAt: clock.now())
        let hostile = AgentToolDetailPresenter.compact(hostileRecord)
        expect(hostile.title == "Tool" && !hostile.accessibilitySummary.contains(rawName),
               "AgentToolDetail privacy RED witness: provider title must fail closed for \(rawName.debugDescription), got \(hostile.title.debugDescription)")
    }
}

private func runAgentToolDetailImplicitSensitivityChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 2_500))
    let implicitCases: [(label: String, text: String, secret: String)] = [
        ("argv whitespace", "runner --access-token implicit-argv-secret", "implicit-argv-secret"),
        ("argv equal", "runner --session-key=implicit-session-secret", "implicit-session-secret"),
        ("query", "https://example.test/?refresh_token=implicit-query-secret", "implicit-query-secret"),
        ("header", "X-Api-Key: implicit-header-secret", "implicit-header-secret"),
        ("json", #"{"private-signing-key":"implicit-json-secret"}"#, "implicit-json-secret")
    ]
    for testCase in implicitCases {
        let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
        let providerItemID = AgentToolDetailID("implicit-\(testCase.label)")!
        _ = await store.recordStart(AgentToolDetailStart(
            identity: testToolDetailKey(providerItemID),
            toolName: "run",
            arguments: [AgentToolDetailField(key: "command", value: testCase.text)],
            affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(testCase.secret)/leak.swift")]
        ))
        let files = await store.detail(for: testToolDetailKey(providerItemID))?.affectedFiles ?? []
        expect(files.isEmpty,
               "AgentToolDetailStore privacy: \(testCase.label) implicit secret must omit affected path without explicitSecrets, got \(files)")
    }
    let hyphenStartStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let hyphenStartSecret = "-leading-start-secret"
    _ = await hyphenStartStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("implicit-hyphen-start"),
        toolName: "run",
        arguments: [AgentToolDetailField(key: "command", value: "runner --access-token \(hyphenStartSecret)")],
        affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(hyphenStartSecret)/start.swift")]
    ))
    let hyphenStartFiles = await hyphenStartStore.detail(for: testToolDetailKey("implicit-hyphen-start"))?.affectedFiles ?? []
    expect(hyphenStartFiles.isEmpty,
           "AgentToolDetailStore privacy: hyphen-leading argv secret must omit affected path without explicitSecrets")

    let outputStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let outputSecret = "implicit-output-secret"
    _ = await outputStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("implicit-output"),
        output: "X-Api-Key: \(outputSecret)",
        status: .completed,
        affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(outputSecret)/output.swift")]
    ))
    let outputDetail = await outputStore.detail(for: testToolDetailKey("implicit-output"))
    let outputFiles = outputDetail?.affectedFiles ?? []
    expect(outputFiles.isEmpty,
           "AgentToolDetailStore privacy: output-discovered secret must omit affected path without explicitSecrets")
    expect(outputDetail?.output?.text.contains(outputSecret) == false,
           "AgentToolDetailStore privacy: output-discovered header secret must be redacted without explicitSecrets")

    let hyphenOutputStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let hyphenOutputSecret = "-leading-output-secret"
    _ = await hyphenOutputStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("implicit-hyphen-output"),
        output: "runner --access-token \(hyphenOutputSecret)",
        status: .completed,
        affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(hyphenOutputSecret)/output.swift")]
    ))
    let hyphenOutputDetail = await hyphenOutputStore.detail(for: testToolDetailKey("implicit-hyphen-output"))
    expect(hyphenOutputDetail?.affectedFiles.isEmpty == true,
           "AgentToolDetailStore privacy: hyphen-leading output secret must omit affected path without explicitSecrets")
    expect(hyphenOutputDetail?.output?.text.contains(hyphenOutputSecret) == false,
           "AgentToolDetailStore privacy: hyphen-leading output secret must be redacted without explicitSecrets")

    let argvCases: [(option: String, separator: String, secret: String)] = [
        ("--access-token", " ", "argv-access-secret"),
        ("--session-key", "=", "argv-session-secret"),
        ("--private-signing-key", " ", "argv-signing-secret"),
        ("--api-password", "=", "argv-password-secret"),
        ("--client-secret", " ", "argv-client-secret"),
        ("--credential", "=", "argv-credential-secret"),
        ("--apiKey", " ", "argv-api-key-secret"),
        ("--db-key", "=", "argv-db-key-secret"),
        ("--oauth-token", " ", "argv-oauth-token-secret"),
        ("--secret-value", "=", "argv-secret-value-secret"),
        ("--access-token", " ", "-leading-argv-secret")
    ]
    for testCase in argvCases {
        let redacted = SecretRedactor.redact("runner \(testCase.option)\(testCase.separator)\(testCase.secret)")
        expect(!redacted.contains(testCase.secret),
               "SecretRedactor argv matrix: \(testCase.option) must redact whitespace/equal value, got \(redacted)")
    }
    let falsePositive = SecretRedactor.redact("runner --tokenize keep-tokenized --monkey keep-monkey")
    expect(falsePositive.contains("keep-tokenized") && falsePositive.contains("keep-monkey"),
           "SecretRedactor argv matrix: near-match option names must not redact ordinary values, got \(falsePositive)")
}

private func runAgentToolDetailTruncationChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 2_000))
    let limits = AgentToolDetailLimits(maxFieldValueBytes: 64, maxFieldValueLines: 2, maxOutputBytes: 96, maxOutputLines: 3)
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60, limits: limits)
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-truncate"),
        toolName: "read",
        arguments: [AgentToolDetailField(key: "note", value: "line1\nline2\nline3\nline4")],
        affectedFiles: [],
        explicitSecrets: []
    ))
    _ = await store.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-truncate"),
        output: String(repeating: "abcdef", count: 40) + "\nsecond\nthird\nfourth",
        status: .failed,
        exitCode: 2,
        affectedFiles: [],
        explicitSecrets: []
    ))
    guard let detail = await store.detail(for: testToolDetailKey("tool-truncate")) else {
        fputs("FAIL: AgentToolDetailStore truncation: expected stored detail\n", stderr)
        Foundation.exit(1)
    }
    let expanded = AgentToolDetailPresenter.expanded(detail)
    let argumentText = expanded.arguments.first?.value.text ?? ""
    expect(argumentText.contains("[truncated]"), "AgentToolDetailStore truncation: argument line cap must include an honest marker, got \(argumentText)")
    expect(argumentText.utf8.count <= limits.maxFieldValueBytes, "AgentToolDetailStore truncation: argument must stay within UTF-8 byte cap, got \(argumentText.utf8.count)")
    expect(lineCount(argumentText) <= limits.maxFieldValueLines, "AgentToolDetailStore truncation: marker must count inside argument line cap, got \(lineCount(argumentText)) lines: \(argumentText)")
    let outputText = expanded.output?.text ?? ""
    expect(outputText.contains("[truncated]"), "AgentToolDetailStore truncation: output byte/line cap must include an honest marker, got \(outputText)")
    expect(outputText.utf8.count <= limits.maxOutputBytes, "AgentToolDetailStore truncation: output must stay within UTF-8 byte cap, got \(outputText.utf8.count)")
    expect(lineCount(outputText) <= limits.maxOutputLines, "AgentToolDetailStore truncation: marker must count inside output line cap, got \(lineCount(outputText)) lines: \(outputText)")

    let minCapStore = AgentToolDetailStore(
        clock: { clock.now() },
        timeToLive: 60,
        limits: AgentToolDetailLimits(maxFieldValueBytes: 16, maxFieldValueLines: 1, maxOutputBytes: 16, maxOutputLines: 1)
    )
    _ = await minCapStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-min-truncate"),
        toolName: "read",
        arguments: [AgentToolDetailField(key: "emoji", value: "👩🏽‍💻👩🏽‍💻👩🏽‍💻")]
    ))
    _ = await minCapStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-min-truncate"),
        output: "one\ntwo",
        status: .completed
    ))
    let minDetail = await minCapStore.detail(for: testToolDetailKey("tool-min-truncate"))
    let minArg = minDetail?.arguments.first?.value.text ?? ""
    let minOutput = minDetail?.output?.text ?? ""
    expect(minArg == "[truncated]" && minArg.utf8.count <= 16 && lineCount(minArg) == 1,
           "AgentToolDetailStore truncation: minimum byte/line cap must retain complete marker, got \(minArg)")
    expect(minOutput == "[truncated]" && minOutput.utf8.count <= 16 && lineCount(minOutput) == 1,
           "AgentToolDetailStore truncation: minimum output cap must retain complete marker, got \(minOutput)")

    let unicodeStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60, limits: AgentToolDetailLimits(maxFieldValueBytes: 40, maxFieldValueLines: 2))
    _ = await unicodeStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-unicode-truncate"),
        toolName: "read",
        arguments: [AgentToolDetailField(key: "emoji", value: "prefix 👩🏽‍💻👩🏽‍💻 suffix")]
    ))
    let unicodeText = await unicodeStore.detail(for: testToolDetailKey("tool-unicode-truncate"))?.arguments.first?.value.text ?? ""
    expect(String(decoding: Array(unicodeText.utf8), as: UTF8.self) == unicodeText,
           "AgentToolDetailStore truncation: bounded text must remain valid UTF-8, got \(unicodeText)")
    expect(!unicodeText.contains("�"), "AgentToolDetailStore truncation: bounded text must not split Unicode replacement characters, got \(unicodeText)")
}

private func runAgentToolDetailAssociationAndExpiryChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 3_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 10)
    let firstFile = URL(fileURLWithPath: "/tmp/project/A.swift")
    let secondFile = URL(fileURLWithPath: "/tmp/project/B.swift")
    let startedAt = clock.now().addingTimeInterval(-100_000)
    let endedAt = startedAt.addingTimeInterval(2)
    _ = await store.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-associate"),
        output: "done",
        status: .completed,
        exitCode: 0,
        affectedFiles: [secondFile],
        endedAt: endedAt,
        explicitSecrets: []
    ))
    clock.advance(by: 5)
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-associate"),
        toolName: "edit",
        arguments: [AgentToolDetailField(key: "path", value: "A.swift")],
        affectedFiles: [firstFile, firstFile],
        startedAt: startedAt,
        explicitSecrets: []
    ))
    guard let detail = await store.detail(for: testToolDetailKey("tool-associate")) else {
        fputs("FAIL: AgentToolDetailStore association: expected detail after out-of-order start/end\n", stderr)
        Foundation.exit(1)
    }
    expect(detail.toolName == "edit", "AgentToolDetailStore association: later start must fill tool name, got \(detail.toolName)")
    expect(detail.status == .completed && detail.exitCode == 0 && detail.output?.text == "done",
           "AgentToolDetailStore association: start must not erase earlier end/output/status, got \(detail)")
    expect(detail.affectedFiles == [secondFile.standardizedFileURL, firstFile.standardizedFileURL],
           "AgentToolDetailStore association: affected files must dedupe preserving reliable observations, got \(detail.affectedFiles)")
    expect(detail.duration?.rounded() == 2, "AgentToolDetailStore association: duration must derive from associated provider timestamps, got \(String(describing: detail.duration))")
    let stillRetained = await store.detail(for: testToolDetailKey("tool-associate"))
    expect(stillRetained != nil,
           "AgentToolDetailStore expiry: old provider timestamps must not expire a newly observed record")

    clock.advance(by: 11)
    let expired = await store.expireNow()
    expect(expired == ["tool-associate"], "AgentToolDetailStore expiry: deterministic local clock should expire the stale key, got \(expired)")
    let afterExpiry = await store.detail(for: testToolDetailKey("tool-associate"))
    expect(afterExpiry == nil, "AgentToolDetailStore expiry: lookup after expiry must be nil, got \(String(describing: afterExpiry))")

    let timestampStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 10)
    _ = await timestampStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-future-old"),
        toolName: "bash",
        startedAt: clock.now().addingTimeInterval(100_000)
    ))
    _ = await timestampStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-future-old"),
        output: "future provider date cannot pin retention",
        status: .completed,
        endedAt: clock.now().addingTimeInterval(100_000)
    ))
    clock.advance(by: 11)
    let futureExpired = await timestampStore.expireNow()
    expect(futureExpired == ["tool-future-old"],
           "AgentToolDetailStore expiry: future provider timestamps must not retain records beyond local TTL")

    // TTL zero is terminal cleanup, not a special case that waits for a read.
    let zeroTTLStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 0)
    _ = await zeroTTLStore.recordStart(AgentToolDetailStart(identity: testToolDetailKey("tool-zero-ttl"), toolName: "read"))
    for _ in 0..<3 { await Task.yield() }
    let zeroTTLDetails = await zeroTTLStore.allDetails()
    expect(zeroTTLDetails.isEmpty,
           "AgentToolDetailStore expiry: TTL zero must remove records without a lookup-triggered retention window")
    await zeroTTLStore.shutdown()
}

private func runAgentToolDetailConcurrencyChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 4_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                let id = AgentToolDetailID("tool-concurrent-\(index)")!
                _ = await store.recordStart(AgentToolDetailStart(
                    identity: testToolDetailKey(id),
                    toolName: "tool-\(index)",
                    arguments: [AgentToolDetailField(key: "index", value: "\(index)")],
                    affectedFiles: [],
                    explicitSecrets: []
                ))
                _ = await store.recordEnd(AgentToolDetailEnd(
                    identity: testToolDetailKey(id),
                    output: "ok \(index)",
                    status: .completed,
                    exitCode: 0,
                    affectedFiles: [],
                    explicitSecrets: []
                ))
            }
        }
    }
    let details = await store.allDetails()
    expect(details.count == 100, "AgentToolDetailStore concurrency: actor must retain every independently keyed detail, got \(details.count)")
    expect(details.allSatisfy { $0.status == .completed && $0.output?.text.hasPrefix("ok ") == true },
           "AgentToolDetailStore concurrency: all starts/ends must associate under actor isolation, got \(details.prefix(3))")

    let raceStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let base = clock.now()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                _ = await raceStore.recordStart(AgentToolDetailStart(
                    identity: testToolDetailKey("tool-same-id-race"),
                    toolName: "worker-\(index)",
                    startedAt: base.addingTimeInterval(TimeInterval(index))
                ))
                _ = await raceStore.recordEnd(AgentToolDetailEnd(
                    identity: testToolDetailKey("tool-same-id-race"),
                    output: "ok \(index)",
                    status: .completed,
                    exitCode: index,
                    endedAt: base.addingTimeInterval(TimeInterval(index))
                ))
            }
        }
    }
    let raced = await raceStore.detail(for: testToolDetailKey("tool-same-id-race"))
    expect(raced?.toolName == "worker-19" && raced?.output?.text == "ok 19" && raced?.exitCode == 19,
           "AgentToolDetailStore concurrency: same-ID races must deterministically keep newest provider facts, got \(String(describing: raced))")

    _ = await raceStore.recordEnd(AgentToolDetailEnd(
        identity: testToolDetailKey("tool-same-id-race"),
        output: "stale regression",
        status: .failed,
        exitCode: 1,
        endedAt: base.addingTimeInterval(10)
    ))
    let afterStaleEnd = await raceStore.detail(for: testToolDetailKey("tool-same-id-race"))
    expect(afterStaleEnd?.status == .completed && afterStaleEnd?.output?.text == "ok 19" && afterStaleEnd?.exitCode == 19,
           "AgentToolDetailStore ordering: stale terminal end must not regress status/output/exit code, got \(String(describing: afterStaleEnd))")

    _ = await raceStore.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-same-id-race"),
        toolName: "stale-start",
        arguments: [AgentToolDetailField(key: "path", value: "stale.swift")],
        startedAt: base.addingTimeInterval(10)
    ))
    let afterStaleStart = await raceStore.detail(for: testToolDetailKey("tool-same-id-race"))
    expect(afterStaleStart?.toolName == "worker-19" && afterStaleStart?.arguments.isEmpty == true,
           "AgentToolDetailStore ordering: stale start must not regress name/arguments, got \(String(describing: afterStaleStart))")

    // Equal and absent timestamps use the same canonical sanitized payload tie
    // policy in either arrival order. Arrival is deliberately not a sequence.
    let equalClock = ManualToolDetailClock(base)
    for timestamp in [base.addingTimeInterval(5), nil] {
        for index in 0..<12 {
            let secretA = "cross-store-start-a-\(index)"
            let secretB = "cross-store-start-b-\(index)"
            let a = AgentToolDetailStart(
                identity: testToolDetailKey(AgentToolDetailID("tool-cross-store-start-\(index)")!),
                toolName: "alpha-\(index)",
                arguments: [AgentToolDetailField(key: "password", value: secretA)],
                startedAt: timestamp
            )
            let b = AgentToolDetailStart(
                identity: testToolDetailKey(AgentToolDetailID("tool-cross-store-start-\(index)")!),
                toolName: "zulu-\(index)",
                arguments: [AgentToolDetailField(key: "password", value: secretB)],
                startedAt: timestamp
            )
            let left = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            let right = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            _ = await left.recordStart(a)
            _ = await left.recordStart(b)
            _ = await right.recordStart(b)
            _ = await right.recordStart(a)
            let leftValue = await left.detail(for: a.identity)
            let rightValue = await right.detail(for: a.identity)
            let timestampLabel = timestamp == nil ? "absent" : "equal"
            expect(leftValue?.toolName == rightValue?.toolName && leftValue?.arguments == rightValue?.arguments,
                   "AgentToolDetailStore ordering: cross-store \(timestampLabel) secret-bearing start winner must not depend on random HMAC or arrival")
        }
    }

    // File/parent detail is a separate monotonic lattice from name/argument
    // timestamp selection. Every weak/rich order and timestamp relation must
    // converge, including scoped-ID reuse after a fresh store lifecycle.
    let timestampPairs: [(Date?, Date?)] = [
        (base, base), (nil, nil), (base.addingTimeInterval(10), base),
        (base, base.addingTimeInterval(10)), (nil, base), (base, nil)
    ]
    for (index, pair) in timestampPairs.enumerated() {
        let identity = testToolDetailKey(AgentToolDetailID("tool-detail-lattice-\(index)")!)
        let weak = AgentToolDetailStart(identity: identity, toolName: "Edit", startedAt: pair.0)
        let rich = AgentToolDetailStart(identity: identity, toolName: "Edit", fileChanges: [
            .init(action: .edit, path: "Sources/Rich.swift", diffPreview: "+rich")
        ], parentItemID: "parent-rich", startedAt: pair.1)
        let left = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        let right = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        _ = await left.recordStart(weak); _ = await left.recordStart(rich)
        _ = await right.recordStart(rich); _ = await right.recordStart(weak)
        let lhs = await left.detail(for: identity)
        let rhs = await right.detail(for: identity)
        expect(lhs?.fileChanges == rhs?.fileChanges && lhs?.parentItemID == rhs?.parentItemID
            && lhs?.fileChanges.first?.path == "Sources/Rich.swift" && lhs?.parentItemID == "parent-rich",
            "start detail lattice must converge for weak/rich timestamp permutation \(pair): \(String(describing: lhs)) vs \(String(describing: rhs))")
    }
    for secretFirst in [false, true] {
        let identity = testToolDetailKey(AgentToolDetailID("tool-late-secret-\(secretFirst)")!)
        let leaky = AgentToolDetailStart(identity: identity, toolName: "Edit", fileChanges: [
            .init(action: .edit, path: "Sources/late-secret-value.swift")
        ])
        let knowledge = AgentToolDetailStart(identity: identity, toolName: "Edit", explicitSecrets: ["late-secret-value"])
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in secretFirst ? [knowledge, leaky] : [leaky, knowledge] { _ = await store.recordStart(event) }
        let retained = await store.detail(for: identity)
        let surface = retained.map(AgentToolDetailPresenter.observableDisclosureText) ?? ""
        expect(retained?.fileChanges.isEmpty == true && !surface.contains("late-secret-value"),
               "late secret knowledge must remove prior/future matching file facts in either arrival order: \(surface)")
    }
    for secretFirst in [false, true] {
        let identity = testToolDetailKey(AgentToolDetailID("tool-short-secret-\(secretFirst)")!)
        let leaky = AgentToolDetailStart(identity: identity, toolName: "Edit",
            fileChanges: [.init(action: .edit, path: "Sources/prefixabc.swift")], parentItemID: "parent-prefixabc")
        let knowledge = AgentToolDetailStart(identity: identity, toolName: "Edit", explicitSecrets: ["abc"])
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in secretFirst ? [knowledge, leaky] : [leaky, knowledge] { _ = await store.recordStart(event) }
        let retained = await store.detail(for: identity)
        expect(retained?.fileChanges.isEmpty == true && retained?.parentItemID == nil,
               "short opaque secrets must fail closed for file and parent facts in both orders")
    }
    for secretFirst in [false, true] {
        let identity = testToolDetailKey(AgentToolDetailID("tool-parent-secret-\(secretFirst)")!)
        let leaky = AgentToolDetailStart(identity: identity, toolName: "Edit", parentItemID: "prefix-parent-secret-suffix")
        let knowledge = AgentToolDetailStart(identity: identity, toolName: "Edit", explicitSecrets: ["parent-secret"])
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in secretFirst ? [knowledge, leaky] : [leaky, knowledge] { _ = await store.recordStart(event) }
        let retained = await store.detail(for: identity)
        expect(retained?.parentItemID == nil,
               "late parent secret knowledge must remove/prevent substring parent facts")
    }
    let sameParentIdentity = testToolDetailKey("tool-parent-same-event-secret")
    let sameParentStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    _ = await sameParentStore.recordStart(.init(identity: sameParentIdentity, toolName: "Edit",
        parentItemID: "prefix-parent-secret-suffix", explicitSecrets: ["parent-secret"]))
    let sameParent = await sameParentStore.detail(for: sameParentIdentity)
    expect(sameParent?.parentItemID == nil, "same-event explicit secret must suppress parent linkage")
    let costIdentity = testToolDetailKey("tool-secret-scan-cost")
    let costStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    _ = await costStore.recordStart(.init(identity: costIdentity, toolName: "Edit",
        explicitSecrets: ["bounded-secret"] ))
    let worstRows = (0..<24).map { index in
        AgentToolDetailObservation.FileChange(action: .rename,
            path: "Sources/\(String(repeating: "p", count: 210))\(index).swift",
            renamePath: "Sources/\(String(repeating: "r", count: 208))\(index).swift",
            diffPreview: String(repeating: "+ safe explicit diff\n", count: 100))
    }
    let costStart = Date()
    _ = await costStore.recordStart(.init(identity: costIdentity, toolName: "Edit", fileChanges: worstRows))
    let costElapsed = Date().timeIntervalSince(costStart)
    expect(costElapsed < 0.1,
           "over-window 24-row opaque-secret input did not fail closed within the generous 100ms debug budget: \(costElapsed)s")
    let costRecord = await costStore.detail(for: costIdentity)
    expect(costRecord?.fileChanges.isEmpty == true,
           "over-1024 candidate windows must fail closed before substring HMAC work")
    print(String(format: "AgentToolDetail privacy over-window fail-closed: %.6fs (budget 0.100000s)", costElapsed))
    let underIdentity = testToolDetailKey("tool-secret-scan-under-cap")
    let underStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    _ = await underStore.recordStart(.init(identity: underIdentity, toolName: "Edit", explicitSecrets: ["absent-secret"]))
    let underRows = (0..<2).map { index in
        AgentToolDetailObservation.FileChange(action: .rename,
            path: "Sources/\(String(repeating: "p", count: 220))\(index).swift",
            renamePath: "Sources/\(String(repeating: "r", count: 220))\(index).swift")
    }
    let underStart = Date()
    _ = await underStore.recordStart(.init(identity: underIdentity, toolName: "Edit", fileChanges: underRows))
    let underElapsed = Date().timeIntervalSince(underStart)
    let underRecord = await underStore.detail(for: underIdentity)
    expect(underElapsed < 0.1 && underRecord?.fileChanges.count == 2,
           "just-under-cap safe rows must remain useful within 100ms: \(underElapsed)s")
    print(String(format: "AgentToolDetail privacy under-window retained: %.6fs (budget 0.100000s)", underElapsed))
    let normalIdentity = testToolDetailKey("tool-secret-scan-normal")
    let normalStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    _ = await normalStore.recordStart(.init(identity: normalIdentity, toolName: "Edit", explicitSecrets: ["unrelated-secret"]))
    _ = await normalStore.recordStart(.init(identity: normalIdentity, toolName: "Edit", fileChanges: [
        .init(action: .edit, path: "Sources/One.swift", diffPreview: "+safe"),
        .init(action: .write, path: "Sources/Two.swift", diffPreview: "+safe-two")
    ]))
    let normalRecord = await normalStore.detail(for: normalIdentity)
    expect(normalRecord?.fileChanges.map(\.path) == ["Sources/One.swift", "Sources/Two.swift"]
        && normalRecord?.fileChanges.allSatisfy({ $0.diffPreview == nil }) == true,
        "normal one/two-row safe paths must remain useful while opaque-secret diffs fail closed")
    let manySecretStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    _ = await manySecretStore.recordStart(.init(identity: costIdentity, toolName: "Edit",
        explicitSecrets: ["first-secret", "second-longer-secret"]))
    _ = await manySecretStore.recordStart(.init(identity: costIdentity, toolName: "Edit", fileChanges: worstRows))
    let manySecretRecord = await manySecretStore.detail(for: costIdentity)
    expect(manySecretRecord?.fileChanges.isEmpty == true,
           "multiple opaque secret lengths must drop file rows without multiplicative substring work")
    for secretFirst in [false, true] {
        let identity = testToolDetailKey(AgentToolDetailID("tool-late-embedded-secret-\(secretFirst)")!)
        let leaky = AgentToolDetailStart(identity: identity, toolName: "Edit", fileChanges: [
            .init(action: .rename, path: "Sources/prefix-late-secret-value-suffix.swift",
                  renamePath: "Sources/prefix-late-secret-value-destination.swift")
        ])
        let knowledge = AgentToolDetailStart(identity: identity, toolName: "Edit", explicitSecrets: ["late-secret-value"])
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in secretFirst ? [knowledge, leaky] : [leaky, knowledge] { _ = await store.recordStart(event) }
        let retained = await store.detail(for: identity)
        expect(retained?.fileChanges.isEmpty == true,
               "bounded substring HMAC must remove embedded source+rename secrets in both orders")
    }
    for secretFirst in [false, true] {
        let identity = testToolDetailKey(AgentToolDetailID("tool-late-rename-secret-\(secretFirst)")!)
        let leaky = AgentToolDetailStart(identity: identity, toolName: "Edit", fileChanges: [
            .init(action: .rename, path: "Sources/SafeBefore.swift", renamePath: "Sources/late-rename-secret.swift")
        ])
        let knowledge = AgentToolDetailStart(identity: identity, toolName: "Edit", explicitSecrets: ["late-rename-secret"])
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in secretFirst ? [knowledge, leaky] : [leaky, knowledge] { _ = await store.recordStart(event) }
        let retained = await store.detail(for: identity)
        expect(retained?.fileChanges.isEmpty == true,
               "late secret knowledge must remove rename-only facts in either arrival order")
    }
    let conflictIdentity = testToolDetailKey("tool-parent-conflict")
    let parentA = AgentToolDetailStart(identity: conflictIdentity, toolName: "Edit", parentItemID: "parent-a")
    let parentB = AgentToolDetailStart(identity: conflictIdentity, toolName: "Edit", parentItemID: "parent-b")
    for ordered in [[parentA, parentB], [parentB, parentA]] {
        let store = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
        for event in ordered { _ = await store.recordStart(event) }
        let conflict = await store.detail(for: conflictIdentity)
        expect(conflict?.parentItemID == nil,
               "conflicting explicit parents must deterministically expose no fabricated parent")
    }
    let parentStressStore = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    for index in 0..<10_000 {
        _ = await parentStressStore.recordStart(.init(identity: conflictIdentity, toolName: "Edit", parentItemID: "parent-\(index)"))
    }
    let parentStressRecord = await parentStressStore.detail(for: conflictIdentity)
    expect(parentStressRecord?.parentItemID == nil
        && parentStressRecord?.observedParentItemIDs.count ?? 99 <= 1
        && parentStressRecord?.observedParentConflict == true,
           "10k distinct parents must remain permanently ambiguous with bounded retained state")
    let directConflict = AgentToolDetailRecord(identity: conflictIdentity, updatedAt: equalClock.now(),
        parentItemID: "parent-should-drop", observedParentItemIDs: ["parent-a"], observedParentConflict: true)
    expect(directConflict.parentItemID == nil && directConflict.observedParentItemIDs.isEmpty,
           "direct record construction must normalize permanent parent conflict to no exposed parent")

    // Secret-only sanitized ties must merge their opaque associations. The
    // subsequent end supplies only A: either arrival order must therefore
    // produce the same honest fail-closed result in separate store lifecycles.
    for timestamp in [base.addingTimeInterval(5), nil] {
        for index in 0..<12 {
            let secretA = "secret-only-start-a-\(index)"
            let secretB = "secret-only-start-b-\(index)"
            let providerItemID = AgentToolDetailID("tool-secret-only-start-\(index)")!
            let a = AgentToolDetailStart(
                identity: testToolDetailKey(providerItemID),
                toolName: "bash",
                arguments: [AgentToolDetailField(key: "password", value: secretA)],
                startedAt: timestamp
            )
            let b = AgentToolDetailStart(
                identity: testToolDetailKey(providerItemID),
                toolName: "bash",
                arguments: [AgentToolDetailField(key: "password", value: secretB)],
                startedAt: timestamp
            )
            let left = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            let right = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            _ = await left.recordStart(a)
            _ = await left.recordStart(b)
            _ = await right.recordStart(b)
            _ = await right.recordStart(a)
            let end = AgentToolDetailEnd(
                identity: testToolDetailKey(providerItemID),
                output: "echoed \(secretA)",
                status: .completed,
                endedAt: timestamp,
                explicitSecrets: [secretA]
            )
            let leftValue = await left.recordEnd(end)
            let rightValue = await right.recordEnd(end)
            let timestampLabel = timestamp == nil ? "absent" : "equal"
            expect(leftValue.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker &&
                   rightValue.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker &&
                   leftValue.output == rightValue.output,
                   "AgentToolDetailStore ordering: cross-store \(timestampLabel) secret-only start tie must merge associations before later output redaction")
        }
    }

    for timestamp in [base.addingTimeInterval(5), nil] {
        for index in 0..<12 {
            let secretA = "cross-store-end-a-\(index)"
            let secretB = "cross-store-end-b-\(index)"
            let a = AgentToolDetailEnd(
                identity: testToolDetailKey(AgentToolDetailID("tool-cross-store-end-\(index)")!),
                output: "alpha-\(index) \(secretA)",
                status: .completed,
                endedAt: timestamp,
                explicitSecrets: [secretA]
            )
            let b = AgentToolDetailEnd(
                identity: testToolDetailKey(AgentToolDetailID("tool-cross-store-end-\(index)")!),
                output: "zulu-\(index) \(secretB)",
                status: .completed,
                endedAt: timestamp,
                explicitSecrets: [secretB]
            )
            let left = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            let right = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
            _ = await left.recordEnd(a)
            _ = await left.recordEnd(b)
            _ = await right.recordEnd(b)
            _ = await right.recordEnd(a)
            let leftValue = await left.detail(for: a.identity)
            let rightValue = await right.detail(for: a.identity)
            let timestampLabel = timestamp == nil ? "absent" : "equal"
            expect(leftValue?.output == rightValue?.output,
                   "AgentToolDetailStore ordering: cross-store \(timestampLabel) secret-bearing end winner must not depend on random HMAC or arrival")
        }
    }

    let forward = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let reverse = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let equalDate = base.addingTimeInterval(5)
    let firstStart = AgentToolDetailStart(identity: testToolDetailKey("tool-tie"), toolName: "alpha", arguments: [AgentToolDetailField(key: "command", value: "one")], startedAt: equalDate)
    let secondStart = AgentToolDetailStart(identity: testToolDetailKey("tool-tie"), toolName: "zulu", arguments: [AgentToolDetailField(key: "command", value: "two")], startedAt: equalDate)
    _ = await forward.recordStart(firstStart)
    _ = await forward.recordStart(secondStart)
    _ = await reverse.recordStart(secondStart)
    _ = await reverse.recordStart(firstStart)
    let forwardValue = await forward.detail(for: testToolDetailKey("tool-tie"))
    let reverseValue = await reverse.detail(for: testToolDetailKey("tool-tie"))
    expect(forwardValue?.toolName == reverseValue?.toolName && forwardValue?.arguments == reverseValue?.arguments,
           "AgentToolDetailStore ordering: equal timestamp winner must be independent of actor arrival")

    let absentForward = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let absentReverse = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let absentA = AgentToolDetailStart(identity: testToolDetailKey("tool-absent-tie"), toolName: "alpha", arguments: [AgentToolDetailField(key: "command", value: "one")])
    let absentB = AgentToolDetailStart(identity: testToolDetailKey("tool-absent-tie"), toolName: "zulu", arguments: [AgentToolDetailField(key: "command", value: "two")])
    _ = await absentForward.recordStart(absentA)
    _ = await absentForward.recordStart(absentB)
    _ = await absentReverse.recordStart(absentB)
    _ = await absentReverse.recordStart(absentA)
    let absentForwardValue = await absentForward.detail(for: testToolDetailKey("tool-absent-tie"))
    let absentReverseValue = await absentReverse.detail(for: testToolDetailKey("tool-absent-tie"))
    expect(absentForwardValue?.toolName == absentReverseValue?.toolName && absentForwardValue?.arguments == absentReverseValue?.arguments,
           "AgentToolDetailStore ordering: absent timestamp winner must be independent of actor arrival")
}

private func runAgentToolDetailPresentationChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 5_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-command-summary"),
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "command", value: "swift test --filter Core")]
    ))
    var detail = await store.detail(for: testToolDetailKey("tool-command-summary"))
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Ran swift test --filter Core"),
           "AgentToolDetailPresenter compact: command summary should be useful and sanitized")
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-command-summary-long"),
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "command", value: "line one\nline two " + String(repeating: "long ", count: 80))]
    ))
    let oneLineSummary = AgentToolDetailPresenter.compact((await store.detail(for: testToolDetailKey("tool-command-summary-long")))!).summary
    expect(!oneLineSummary.contains("\n") && oneLineSummary.utf8.count <= 180,
           "AgentToolDetailPresenter compact: command summaries must be one short normalized line, got \(oneLineSummary)")

    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-search-summary"),
        toolName: "grep",
        arguments: [AgentToolDetailField(key: "query", value: "AgentToolDetail")]
    ))
    detail = await store.detail(for: testToolDetailKey("tool-search-summary"))
    // `.plans/45` S3 — the action sentence quotes the query (Dylan's
    // action-first row design).
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Searched for \u{201C}AgentToolDetail\u{201D}"),
           "AgentToolDetailPresenter compact: search summary should be useful and sanitized, got \(AgentToolDetailPresenter.compact(detail!).summary)")

    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-edit-summary"),
        toolName: "edit",
        affectedFiles: [URL(fileURLWithPath: "/tmp/project/File.swift")]
    ))
    detail = await store.detail(for: testToolDetailKey("tool-edit-summary"))
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Edited File.swift"),
           "AgentToolDetailPresenter compact: edit summary should use safe basename")
    let disclosure = AgentToolDetailPresenter.observableDisclosureText(detail!)
    // T2 (2026-08-25) — this used to pin the DOUBLING:
    // "Edited File.swift\nChanged: …/project/File.swift", a title and a body line
    // naming the same file. Dylan: "there is a lot of doubling." The title
    // already names the basename, so the body line is suppressed and the
    // directory stays available expanded.
    expect(disclosure == "Edited File.swift",
           "AgentToolDetailPresenter disclosure: a title that already names the file must not be repeated underneath it, got \(disclosure)")

    // The abbreviation guarantee still needs a live case, or removing the line
    // above would leave the path-safety assertions below vacuous. A tool whose
    // title does NOT name the file keeps its file line, and that is where the
    // "never an absolute host path" rule is actually exercised.
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-file-line-survives"),
        toolName: "bash",
        affectedFiles: [URL(fileURLWithPath: "/tmp/project/File.swift")]
    ))
    let unnamed = await store.detail(for: testToolDetailKey("tool-file-line-survives"))
    let unnamedDisclosure = AgentToolDetailPresenter.observableDisclosureText(unnamed!)
    expect(unnamedDisclosure.contains("File: …/project/File.swift"),
           "AgentToolDetailPresenter disclosure: a title that does NOT name the file must still identify its abbreviated target, got \(unnamedDisclosure)")
    // And the tool name alone is never a body line: the title is already
    // "Bash", so "bash" underneath it was the same word twice in two cases.
    expect(!unnamedDisclosure.lowercased().split(separator: "\n").contains("bash"),
           "AgentToolDetailPresenter disclosure: the bare tool name must not be a body line under a title that is the same tool name, got \(unnamedDisclosure)")
    for text in [disclosure, unnamedDisclosure] {
        expect(!text.contains("/tmp/") && !text.contains("/Users/"),
               "AgentToolDetailPresenter disclosure: expanded target must not print an absolute host path, got \(text)")
    }
    expect(!AgentToolDetailPresenter.compact(detail!).accessibilitySummary.contains("File.swift"),
           "AgentToolDetailPresenter compact: accessibility summary must not expose raw file names")
}

/// T2 follow-up (2026-08-25) — the single-file dedupe shipped in
/// `runAgentToolDetailPresentationChecks` only ever constructed ONE affected
/// file, so it could not express either failure mode the fix actually
/// guards against: (1) two-or-more affected files sharing a basename ALL
/// disappearing because the title can only ever name one of them, and
/// (2) a non-file-oriented action line (a bash command) coincidentally
/// containing an affected file's literal name as a substring.
private func runAgentToolDetailDisclosureCollisionChecks() async throws {
    let store = AgentToolDetailStore()

    // Same basename from two different directories — real-world normal
    // (`index.ts`, `mod.rs`, `__init__.py`). The title can only say
    // "Edited index.ts"; both file lines must still appear, or the second
    // file is invisible even fully expanded.
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-multi-same-basename"),
        toolName: "edit",
        affectedFiles: [
            URL(fileURLWithPath: "/repo/a/src/index.ts"),
            URL(fileURLWithPath: "/repo/b/lib/index.ts"),
        ]
    ))
    let multiDetail = await store.detail(for: testToolDetailKey("tool-multi-same-basename"))!
    let multiDisclosure = AgentToolDetailPresenter.observableDisclosureText(multiDetail)
    expect(multiDisclosure.contains("…/src/index.ts") && multiDisclosure.contains("…/lib/index.ts"),
           "AgentToolDetailPresenter disclosure: two affected files sharing a basename must BOTH stay listed, got \(multiDisclosure)")

    // A bash/run row whose free-text action sentence happens to contain the
    // word "test" must not swallow an affected file that is literally named
    // "test" — the title isn't naming that file, it's narrating a command.
    _ = await store.recordStart(AgentToolDetailStart(
        identity: testToolDetailKey("tool-substring-collision"),
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "command", value: "npm test")],
        affectedFiles: [URL(fileURLWithPath: "/repo/test")]
    ))
    let collisionDetail = await store.detail(for: testToolDetailKey("tool-substring-collision"))!
    let collisionDisclosure = AgentToolDetailPresenter.observableDisclosureText(collisionDetail)
    expect(collisionDisclosure.contains("File: …/repo/test"),
           "AgentToolDetailPresenter disclosure: an action line that merely CONTAINS a file's name as a substring (\u{201C}Ran npm test\u{201D} vs. a file literally named \u{201C}test\u{201D}) must not suppress that file's line, got \(collisionDisclosure)")
}

private func runAgentToolDetailSourceBoundaryChecks() {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sources = root.appendingPathComponent("Sources")
    let swiftFiles = allSwiftFiles(under: sources)
    expect(!swiftFiles.isEmpty, "AgentToolDetailStore source boundary: expected Swift sources under \(sources.path)")

    for file in swiftFiles {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            fputs("FAIL: AgentToolDetailStore source boundary: could not read \(file.path)\n", stderr)
            Foundation.exit(1)
        }
        let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
        let compacted = source.replacingOccurrences(of: "\n", with: " ")
        let localDetailTypeNames = [
            "AgentToolDetailID",
            "AgentToolDetailScope",
            "AgentToolDetailKey",
            "AgentToolDetailField",
            "AgentToolDetailStart",
            "AgentToolDetailEnd",
            "AgentToolDetailBoundedText",
            "AgentToolDetailArgument",
            "AgentToolDetailRecord"
        ]
        for typeName in localDetailTypeNames {
            let conformancePattern = #"(struct|enum|extension)\s+"# + typeName + #"\b[^\{;]*(Codable|Encodable|Decodable)\b"#
            expect(compacted.range(of: conformancePattern, options: .regularExpression) == nil,
                   "AgentToolDetailStore source boundary: host-local detail vocabulary must remain non-Codable; found forbidden conformance on \(typeName) in \(relative)")
        }

        if relative == "Sources/ContinuumRevivedCore/Agents/AgentToolDetailStore.swift" {
            expect(source.contains("HMAC<SHA256>"),
                   "AgentToolDetailStore privacy boundary: secret association must use keyed HMAC")
            expect(!source.contains("SHA256.hash"),
                   "AgentToolDetailStore privacy boundary: predictable exact-secret SHA-256 fingerprint remains")
            expect(source.contains("SymmetricKey(size: .bits256)"),
                   "AgentToolDetailStore privacy boundary: per-store ephemeral key generation is missing")
        }

        let isRuntimeOrActivityFile = relative == "Sources/ContinuumRevivedCore/AgentStatusEngine.swift" ||
            relative == "Sources/ContinuumRevivedCore/AgentActivityEvent.swift"
        let isSyncFile = relative.hasPrefix("Sources/ContinuumRevivedSync/")
        if isRuntimeOrActivityFile || isSyncFile {
            expect(!source.contains("AgentToolDetail"),
                   "AgentToolDetailStore source boundary: runtime/activity/sync production types must not gain local detail references; found in \(relative)")
        }
    }
}

private func runAgentToolDetailCompileNegativeBoundaryCheck() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let modulePath = root.appendingPathComponent(".build/debug/Modules")
    guard FileManager.default.fileExists(atPath: modulePath.path) else {
        fputs("FAIL: AgentToolDetailStore compile-negative boundary: Core modules are unavailable at \(modulePath.path)\n", stderr)
        Foundation.exit(1)
    }
    let source = """
    import ContinuumRevivedCore
    func mustNotBeCodable(_ value: AgentToolDetailRecord) {
        let _: any Encodable = value
    }
    """
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-tool-detail-noncodable-\\(UUID().uuidString).swift")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    let includePaths = [
        modulePath.path,
        root.appendingPathComponent(".build/checkouts/swift-markdown/Sources/CAtomic/include").path,
        root.appendingPathComponent(".build/checkouts/swift-cmark/extensions/include").path,
        root.appendingPathComponent(".build/checkouts/swift-cmark/src/include").path,
        root.appendingPathComponent(".build/checkouts/GRDB.swift/Support").path,
        root.appendingPathComponent(".build/checkouts/GRDB.swift/Sources/GRDBSQLite").path
    ]
    process.arguments = ["-typecheck"] + includePaths.flatMap { ["-I", $0] } + [sourceURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let diagnostics = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    expect(process.terminationStatus != 0,
           "AgentToolDetailStore boundary: compile-negative Encodable oracle unexpectedly accepted local detail")
    expect(diagnostics.contains("does not conform") || diagnostics.contains("not convertible") || diagnostics.contains("cannot convert"),
           "AgentToolDetailStore boundary: expected a non-Codable compile diagnostic, got: \(diagnostics)")
}

private func lineCount(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.split(separator: "\n", omittingEmptySubsequences: false).count
}

private func allSwiftFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

private final class ManualToolDetailClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ initial: Date) {
        self.value = initial
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
