import ContinuumRevivedCore
import Foundation

func runAgentToolDetailStoreChecks() async throws {
    try await runAgentToolDetailPrivacyChecks()
    try await runAgentToolDetailImplicitSensitivityChecks()
    try await runAgentToolDetailTruncationChecks()
    try await runAgentToolDetailAssociationAndExpiryChecks()
    try await runAgentToolDetailConcurrencyChecks()
    try await runAgentToolDetailPresentationChecks()
    runAgentToolDetailSourceBoundaryChecks()
    try runAgentToolDetailCompileNegativeBoundaryCheck()
    print("Agent tool detail store checks passed: privacy redaction/fail-closed output, provider ID bounds, argument/file bounds, truncation caps, start/end ordering, local expiry, same-ID concurrency, compact summaries, and source boundaries")
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
        providerItemID: "tool-privacy",
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
        providerItemID: "tool-privacy",
        output: "echoed \(rawSecret) auth \(authSecret) key \(privateKey) and token=abc",
        status: .completed,
        exitCode: 0,
        affectedFiles: [],
        explicitSecrets: [rawSecret, authSecret, privateKey, "session=\(authSecret)", "abc"]
    ))
    guard let detail = await store.detail(for: "tool-privacy") else {
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
        providerItemID: "tool-start-secret",
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "password", value: rawSecret)],
        explicitSecrets: []
    ))
    _ = await failClosedStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-start-secret",
        output: "provider echoed start-only password: \(rawSecret)",
        status: .completed,
        exitCode: 0,
        explicitSecrets: []
    ))
    let failClosed = await failClosedStore.detail(for: "tool-start-secret")
    expect(failClosed?.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker,
           "AgentToolDetailStore privacy: start-only sensitive values without end context must omit output with honest marker, got \(String(describing: failClosed?.output?.text))")
    expect(failClosed?.output?.text.contains(rawSecret) == false,
           "AgentToolDetailStore privacy: fail-closed output must not retain echoed start secret")

    let outOfOrderPrivacyStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await outOfOrderPrivacyStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-end-before-secret-start",
        output: "already echoed \(rawSecret)",
        status: .completed,
        explicitSecrets: []
    ))
    _ = await outOfOrderPrivacyStore.recordStart(AgentToolDetailStart(
        providerItemID: "tool-end-before-secret-start",
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "password", value: rawSecret)]
    ))
    let outOfOrderPrivacy = await outOfOrderPrivacyStore.detail(for: "tool-end-before-secret-start")
    expect(outOfOrderPrivacy?.output?.text == AgentToolDetailSanitizer.redactionUnavailableMarker,
           "AgentToolDetailStore privacy: end-before-start sensitive context must replace possible echoed output, got \(String(describing: outOfOrderPrivacy?.output?.text))")

    let zeroFileStore = AgentToolDetailStore(
        clock: { clock.now() },
        timeToLive: 60,
        limits: AgentToolDetailLimits(maxAffectedFiles: 0)
    )
    _ = await zeroFileStore.recordStart(AgentToolDetailStart(
        providerItemID: "tool-zero-files",
        toolName: "edit",
        affectedFiles: [URL(fileURLWithPath: "/tmp/work/A.swift")]
    ))
    let zeroFileDetail = await zeroFileStore.detail(for: "tool-zero-files")
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

private func runAgentToolDetailImplicitSensitivityChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 2_500))
    let implicitCases: [(label: String, text: String, secret: String)] = [
        ("argv whitespace", "runner --access-token implicit-argv-secret", "implicit-argv-secret"),
        ("argv equal", "runner --session-key=implicit-session-secret", "implicit-session-secret"),
        ("query", "https://example.test/?refresh_token=implicit-query-secret", "implicit-query-secret"),
        ("header", "Authorization: Bearer implicit-header-secret", "implicit-header-secret"),
        ("json", #"{"private-signing-key":"implicit-json-secret"}"#, "implicit-json-secret")
    ]
    for testCase in implicitCases {
        let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
        let providerItemID = AgentToolDetailID("implicit-\(testCase.label)")!
        _ = await store.recordStart(AgentToolDetailStart(
            providerItemID: providerItemID,
            toolName: "run",
            arguments: [AgentToolDetailField(key: "command", value: testCase.text)],
            affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(testCase.secret)/leak.swift")]
        ))
        let files = await store.detail(for: providerItemID)?.affectedFiles ?? []
        expect(files.isEmpty,
               "AgentToolDetailStore privacy: \(testCase.label) implicit secret must omit affected path without explicitSecrets, got \(files)")
    }
    let outputStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    let outputSecret = "implicit-output-secret"
    _ = await outputStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "implicit-output",
        output: "Authorization: Bearer \(outputSecret)",
        status: .completed,
        affectedFiles: [URL(fileURLWithPath: "/tmp/implicit-\(outputSecret)/output.swift")]
    ))
    let outputFiles = await outputStore.detail(for: "implicit-output")?.affectedFiles ?? []
    expect(outputFiles.isEmpty,
           "AgentToolDetailStore privacy: output-discovered secret must omit affected path without explicitSecrets")

    let argvCases: [(option: String, separator: String, secret: String)] = [
        ("--access-token", " ", "argv-access-secret"),
        ("--session-key", "=", "argv-session-secret"),
        ("--private-signing-key", " ", "argv-signing-secret"),
        ("--api-password", "=", "argv-password-secret"),
        ("--client-secret", " ", "argv-client-secret"),
        ("--credential", "=", "argv-credential-secret")
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
        providerItemID: "tool-truncate",
        toolName: "read",
        arguments: [AgentToolDetailField(key: "note", value: "line1\nline2\nline3\nline4")],
        affectedFiles: [],
        explicitSecrets: []
    ))
    _ = await store.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-truncate",
        output: String(repeating: "abcdef", count: 40) + "\nsecond\nthird\nfourth",
        status: .failed,
        exitCode: 2,
        affectedFiles: [],
        explicitSecrets: []
    ))
    guard let detail = await store.detail(for: "tool-truncate") else {
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
        providerItemID: "tool-min-truncate",
        toolName: "read",
        arguments: [AgentToolDetailField(key: "emoji", value: "👩🏽‍💻👩🏽‍💻👩🏽‍💻")]
    ))
    _ = await minCapStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-min-truncate",
        output: "one\ntwo",
        status: .completed
    ))
    let minDetail = await minCapStore.detail(for: "tool-min-truncate")
    let minArg = minDetail?.arguments.first?.value.text ?? ""
    let minOutput = minDetail?.output?.text ?? ""
    expect(minArg == "[truncated]" && minArg.utf8.count <= 16 && lineCount(minArg) == 1,
           "AgentToolDetailStore truncation: minimum byte/line cap must retain complete marker, got \(minArg)")
    expect(minOutput == "[truncated]" && minOutput.utf8.count <= 16 && lineCount(minOutput) == 1,
           "AgentToolDetailStore truncation: minimum output cap must retain complete marker, got \(minOutput)")

    let unicodeStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60, limits: AgentToolDetailLimits(maxFieldValueBytes: 40, maxFieldValueLines: 2))
    _ = await unicodeStore.recordStart(AgentToolDetailStart(
        providerItemID: "tool-unicode-truncate",
        toolName: "read",
        arguments: [AgentToolDetailField(key: "emoji", value: "prefix 👩🏽‍💻👩🏽‍💻 suffix")]
    ))
    let unicodeText = await unicodeStore.detail(for: "tool-unicode-truncate")?.arguments.first?.value.text ?? ""
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
        providerItemID: "tool-associate",
        output: "done",
        status: .completed,
        exitCode: 0,
        affectedFiles: [secondFile],
        endedAt: endedAt,
        explicitSecrets: []
    ))
    clock.advance(by: 5)
    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-associate",
        toolName: "edit",
        arguments: [AgentToolDetailField(key: "path", value: "A.swift")],
        affectedFiles: [firstFile, firstFile],
        startedAt: startedAt,
        explicitSecrets: []
    ))
    guard let detail = await store.detail(for: "tool-associate") else {
        fputs("FAIL: AgentToolDetailStore association: expected detail after out-of-order start/end\n", stderr)
        Foundation.exit(1)
    }
    expect(detail.toolName == "edit", "AgentToolDetailStore association: later start must fill tool name, got \(detail.toolName)")
    expect(detail.status == .completed && detail.exitCode == 0 && detail.output?.text == "done",
           "AgentToolDetailStore association: start must not erase earlier end/output/status, got \(detail)")
    expect(detail.affectedFiles == [secondFile.standardizedFileURL, firstFile.standardizedFileURL],
           "AgentToolDetailStore association: affected files must dedupe preserving reliable observations, got \(detail.affectedFiles)")
    expect(detail.duration?.rounded() == 2, "AgentToolDetailStore association: duration must derive from associated provider timestamps, got \(String(describing: detail.duration))")
    let stillRetained = await store.detail(for: "tool-associate")
    expect(stillRetained != nil,
           "AgentToolDetailStore expiry: old provider timestamps must not expire a newly observed record")

    clock.advance(by: 11)
    let expired = await store.expireNow()
    expect(expired == ["tool-associate"], "AgentToolDetailStore expiry: deterministic local clock should expire the stale key, got \(expired)")
    let afterExpiry = await store.detail(for: "tool-associate")
    expect(afterExpiry == nil, "AgentToolDetailStore expiry: lookup after expiry must be nil, got \(String(describing: afterExpiry))")

    let timestampStore = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 10)
    _ = await timestampStore.recordStart(AgentToolDetailStart(
        providerItemID: "tool-future-old",
        toolName: "bash",
        startedAt: clock.now().addingTimeInterval(100_000)
    ))
    _ = await timestampStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-future-old",
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
    _ = await zeroTTLStore.recordStart(AgentToolDetailStart(providerItemID: "tool-zero-ttl", toolName: "read"))
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
                    providerItemID: id,
                    toolName: "tool-\(index)",
                    arguments: [AgentToolDetailField(key: "index", value: "\(index)")],
                    affectedFiles: [],
                    explicitSecrets: []
                ))
                _ = await store.recordEnd(AgentToolDetailEnd(
                    providerItemID: id,
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
                    providerItemID: "tool-same-id-race",
                    toolName: "worker-\(index)",
                    startedAt: base.addingTimeInterval(TimeInterval(index))
                ))
                _ = await raceStore.recordEnd(AgentToolDetailEnd(
                    providerItemID: "tool-same-id-race",
                    output: "ok \(index)",
                    status: .completed,
                    exitCode: index,
                    endedAt: base.addingTimeInterval(TimeInterval(index))
                ))
            }
        }
    }
    let raced = await raceStore.detail(for: "tool-same-id-race")
    expect(raced?.toolName == "worker-19" && raced?.output?.text == "ok 19" && raced?.exitCode == 19,
           "AgentToolDetailStore concurrency: same-ID races must deterministically keep newest provider facts, got \(String(describing: raced))")

    _ = await raceStore.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-same-id-race",
        output: "stale regression",
        status: .failed,
        exitCode: 1,
        endedAt: base.addingTimeInterval(10)
    ))
    let afterStaleEnd = await raceStore.detail(for: "tool-same-id-race")
    expect(afterStaleEnd?.status == .completed && afterStaleEnd?.output?.text == "ok 19" && afterStaleEnd?.exitCode == 19,
           "AgentToolDetailStore ordering: stale terminal end must not regress status/output/exit code, got \(String(describing: afterStaleEnd))")

    _ = await raceStore.recordStart(AgentToolDetailStart(
        providerItemID: "tool-same-id-race",
        toolName: "stale-start",
        arguments: [AgentToolDetailField(key: "path", value: "stale.swift")],
        startedAt: base.addingTimeInterval(10)
    ))
    let afterStaleStart = await raceStore.detail(for: "tool-same-id-race")
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
                providerItemID: AgentToolDetailID("tool-cross-store-start-\(index)")!,
                toolName: "alpha-\(index)",
                arguments: [AgentToolDetailField(key: "password", value: secretA)],
                startedAt: timestamp
            )
            let b = AgentToolDetailStart(
                providerItemID: AgentToolDetailID("tool-cross-store-start-\(index)")!,
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
            let leftValue = await left.detail(for: a.providerItemID)
            let rightValue = await right.detail(for: a.providerItemID)
            let timestampLabel = timestamp == nil ? "absent" : "equal"
            expect(leftValue?.toolName == rightValue?.toolName && leftValue?.arguments == rightValue?.arguments,
                   "AgentToolDetailStore ordering: cross-store \(timestampLabel) secret-bearing start winner must not depend on random HMAC or arrival")
        }
    }

    for timestamp in [base.addingTimeInterval(5), nil] {
        for index in 0..<12 {
            let secretA = "cross-store-end-a-\(index)"
            let secretB = "cross-store-end-b-\(index)"
            let a = AgentToolDetailEnd(
                providerItemID: AgentToolDetailID("tool-cross-store-end-\(index)")!,
                output: "alpha-\(index) \(secretA)",
                status: .completed,
                endedAt: timestamp,
                explicitSecrets: [secretA]
            )
            let b = AgentToolDetailEnd(
                providerItemID: AgentToolDetailID("tool-cross-store-end-\(index)")!,
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
            let leftValue = await left.detail(for: a.providerItemID)
            let rightValue = await right.detail(for: a.providerItemID)
            let timestampLabel = timestamp == nil ? "absent" : "equal"
            expect(leftValue?.output == rightValue?.output,
                   "AgentToolDetailStore ordering: cross-store \(timestampLabel) secret-bearing end winner must not depend on random HMAC or arrival")
        }
    }

    let forward = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let reverse = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let equalDate = base.addingTimeInterval(5)
    let firstStart = AgentToolDetailStart(providerItemID: "tool-tie", toolName: "alpha", arguments: [AgentToolDetailField(key: "command", value: "one")], startedAt: equalDate)
    let secondStart = AgentToolDetailStart(providerItemID: "tool-tie", toolName: "zulu", arguments: [AgentToolDetailField(key: "command", value: "two")], startedAt: equalDate)
    _ = await forward.recordStart(firstStart)
    _ = await forward.recordStart(secondStart)
    _ = await reverse.recordStart(secondStart)
    _ = await reverse.recordStart(firstStart)
    let forwardValue = await forward.detail(for: "tool-tie")
    let reverseValue = await reverse.detail(for: "tool-tie")
    expect(forwardValue?.toolName == reverseValue?.toolName && forwardValue?.arguments == reverseValue?.arguments,
           "AgentToolDetailStore ordering: equal timestamp winner must be independent of actor arrival")

    let absentForward = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let absentReverse = AgentToolDetailStore(clock: { equalClock.now() }, timeToLive: 60)
    let absentA = AgentToolDetailStart(providerItemID: "tool-absent-tie", toolName: "alpha", arguments: [AgentToolDetailField(key: "command", value: "one")])
    let absentB = AgentToolDetailStart(providerItemID: "tool-absent-tie", toolName: "zulu", arguments: [AgentToolDetailField(key: "command", value: "two")])
    _ = await absentForward.recordStart(absentA)
    _ = await absentForward.recordStart(absentB)
    _ = await absentReverse.recordStart(absentB)
    _ = await absentReverse.recordStart(absentA)
    let absentForwardValue = await absentForward.detail(for: "tool-absent-tie")
    let absentReverseValue = await absentReverse.detail(for: "tool-absent-tie")
    expect(absentForwardValue?.toolName == absentReverseValue?.toolName && absentForwardValue?.arguments == absentReverseValue?.arguments,
           "AgentToolDetailStore ordering: absent timestamp winner must be independent of actor arrival")
}

private func runAgentToolDetailPresentationChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 5_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-command-summary",
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "command", value: "swift test --filter Core")]
    ))
    var detail = await store.detail(for: "tool-command-summary")
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Ran swift test --filter Core"),
           "AgentToolDetailPresenter compact: command summary should be useful and sanitized")
    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-command-summary-long",
        toolName: "bash",
        arguments: [AgentToolDetailField(key: "command", value: "line one\nline two " + String(repeating: "long ", count: 80))]
    ))
    let oneLineSummary = AgentToolDetailPresenter.compact((await store.detail(for: "tool-command-summary-long"))!).summary
    expect(!oneLineSummary.contains("\n") && oneLineSummary.utf8.count <= 180,
           "AgentToolDetailPresenter compact: command summaries must be one short normalized line, got \(oneLineSummary)")

    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-search-summary",
        toolName: "grep",
        arguments: [AgentToolDetailField(key: "query", value: "AgentToolDetail")]
    ))
    detail = await store.detail(for: "tool-search-summary")
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Searched for AgentToolDetail"),
           "AgentToolDetailPresenter compact: search summary should be useful and sanitized")

    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-edit-summary",
        toolName: "edit",
        affectedFiles: [URL(fileURLWithPath: "/tmp/project/File.swift")]
    ))
    detail = await store.detail(for: "tool-edit-summary")
    expect(AgentToolDetailPresenter.compact(detail!).summary.hasPrefix("Edited File.swift"),
           "AgentToolDetailPresenter compact: edit summary should use safe basename")
    expect(!AgentToolDetailPresenter.compact(detail!).accessibilitySummary.contains("File.swift"),
           "AgentToolDetailPresenter compact: accessibility summary must not expose raw file names")
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
