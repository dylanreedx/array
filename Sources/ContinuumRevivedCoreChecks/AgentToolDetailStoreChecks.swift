import ContinuumRevivedCore
import Foundation

func runAgentToolDetailStoreChecks() async throws {
    try await runAgentToolDetailPrivacyChecks()
    try await runAgentToolDetailTruncationChecks()
    try await runAgentToolDetailAssociationAndExpiryChecks()
    try await runAgentToolDetailConcurrencyChecks()
    runAgentToolDetailSourceBoundaryChecks()
    print("Agent tool detail store checks passed: privacy redaction, truncation markers, start/end association, deterministic expiry, concurrency, and source boundaries")
}

private func runAgentToolDetailPrivacyChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 1_000))
    let store = AgentToolDetailStore(
        clock: { clock.now() },
        timeToLive: 60,
        limits: AgentToolDetailLimits(maxFieldValueBytes: 256, maxFieldValueLines: 4, maxOutputBytes: 512, maxOutputLines: 8)
    )
    let rawSecret = "SECRET-token-123"
    _ = await store.recordStart(AgentToolDetailStart(
        providerItemID: "tool-privacy",
        toolName: "bash",
        arguments: [
            AgentToolDetailField(key: "command", value: "curl -H 'Authorization: Bearer \(rawSecret)' https://example.test?token=abc"),
            AgentToolDetailField(key: "password", value: rawSecret),
            AgentToolDetailField(key: "safe", value: "visible-value")
        ],
        affectedFiles: [URL(fileURLWithPath: "/tmp/work/file.swift")],
        explicitSecrets: ["abc"]
    ))
    _ = await store.recordEnd(AgentToolDetailEnd(
        providerItemID: "tool-privacy",
        output: "echoed \(rawSecret) and token=abc",
        status: .completed,
        exitCode: 0,
        affectedFiles: [],
        explicitSecrets: [rawSecret, "abc"]
    ))
    guard let detail = await store.detail(for: "tool-privacy") else {
        fputs("FAIL: AgentToolDetailStore privacy: expected stored detail\n", stderr)
        Foundation.exit(1)
    }
    let expanded = AgentToolDetailPresenter.expanded(detail)
    let rendered = ([expanded.header] + expanded.arguments.map { "\($0.key)=\($0.value.text)" } + [expanded.output?.text ?? ""] + expanded.affectedFiles.map(\.path)).joined(separator: "\n")
    expect(!rendered.contains(rawSecret), "AgentToolDetailStore privacy: sensitive values must be redacted before storage/presentation, got \(rendered)")
    expect(!rendered.contains("token=abc"), "AgentToolDetailStore privacy: explicit secrets/query tokens must be redacted, got \(rendered)")
    expect(rendered.contains("password=[REDACTED]") || rendered.contains("password=********"), "AgentToolDetailStore privacy: sensitive-key arguments must be replaced, got \(rendered)")

    let compact = AgentToolDetailPresenter.compact(detail)
    let accessibility = [compact.accessibilitySummary, expanded.accessibilitySummary].joined(separator: "\n")
    expect(!accessibility.contains(rawSecret) && !accessibility.contains("visible-value") && !accessibility.contains("echoed"),
           "AgentToolDetailPresenter privacy: accessibility summaries must not contain raw argument/output values, got \(accessibility)")

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
    expect(argumentText.contains("[truncated:"), "AgentToolDetailStore truncation: argument line cap must include an honest marker, got \(argumentText)")
    expect(argumentText.utf8.count <= limits.maxFieldValueBytes, "AgentToolDetailStore truncation: argument must stay within UTF-8 byte cap, got \(argumentText.utf8.count)")
    let outputText = expanded.output?.text ?? ""
    expect(outputText.contains("[truncated:"), "AgentToolDetailStore truncation: output byte/line cap must include an honest marker, got \(outputText)")
    expect(outputText.utf8.count <= limits.maxOutputBytes, "AgentToolDetailStore truncation: output must stay within UTF-8 byte cap, got \(outputText.utf8.count)")
}

private func runAgentToolDetailAssociationAndExpiryChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 3_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 10)
    let firstFile = URL(fileURLWithPath: "/tmp/project/A.swift")
    let secondFile = URL(fileURLWithPath: "/tmp/project/B.swift")
    let startedAt = clock.now()
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
    expect(detail.duration?.rounded() == 2, "AgentToolDetailStore association: duration must derive from associated timestamps, got \(String(describing: detail.duration))")

    clock.advance(by: 11)
    let expired = await store.expireNow()
    expect(expired == ["tool-associate"], "AgentToolDetailStore expiry: deterministic clock should expire the stale key, got \(expired)")
    let afterExpiry = await store.detail(for: "tool-associate")
    expect(afterExpiry == nil, "AgentToolDetailStore expiry: lookup after expiry must be nil, got \(String(describing: afterExpiry))")
}

private func runAgentToolDetailConcurrencyChecks() async throws {
    let clock = ManualToolDetailClock(Date(timeIntervalSinceReferenceDate: 4_000))
    let store = AgentToolDetailStore(clock: { clock.now() }, timeToLive: 60)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                let id = "tool-concurrent-\(index)"
                _ = await store.recordStart(AgentToolDetailStart(
                    providerItemID: AgentToolDetailID(id),
                    toolName: "tool-\(index)",
                    arguments: [AgentToolDetailField(key: "index", value: "\(index)")],
                    affectedFiles: [],
                    explicitSecrets: []
                ))
                _ = await store.recordEnd(AgentToolDetailEnd(
                    providerItemID: AgentToolDetailID(id),
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
}

private func runAgentToolDetailSourceBoundaryChecks() {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Sources/ContinuumRevivedCore/Agents/AgentToolDetailStore.swift")
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
        fputs("FAIL: AgentToolDetailStore source boundary: could not read \(sourceURL.path)\n", stderr)
        Foundation.exit(1)
    }
    expect(!source.contains(": Codable") && !source.contains(", Codable"),
           "AgentToolDetailStore source boundary: host-local detail vocabulary must remain non-Codable")
    expect(!source.contains("AgentRuntimeEvent"),
           "AgentToolDetailStore source boundary: detail store must not widen or construct normalized runtime events")
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
