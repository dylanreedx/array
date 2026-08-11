import ContinuumRevivedCore
import Foundation

private struct DelayedCompletionProvider: AgentCompletionProvider {
    let providerID: String
    let trigger: Character
    let delayNanoseconds: UInt64
    let values: [AgentCompletion]

    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return values
    }
}

func runAgentCompletionNegativeWitness() {
    let query = AgentCompletionQueryDetector.activeQuery(
        in: "literal \\@not-a-query",
        selection: NSRange(location: 21, length: 0)
    )
    // Deliberately wrong: an escaped trigger is not at a token boundary and must
    // not open a completion request.
    expect(query != nil, "agent completion negative witness: escaped trigger opened suggestions")
}

func runAgentCompletionChecks() async throws {
    let quoted = "open @\"Sources/My File.swift\" tail"
    let quotedCaret = ("open @\"Sources/My" as NSString).length
    let query = AgentCompletionQueryDetector.activeQuery(
        in: quoted,
        selection: NSRange(location: quotedCaret, length: 0)
    )
    expect(query?.trigger == "@", "AgentCompletion: quoted path trigger was not detected")
    expect(query?.text == "Sources/My", "AgentCompletion: quote-aware query decoding was not exact")
    expect(
        AgentCompletionQueryDetector.activeQuery(
            in: "/help",
            selection: NSRange(location: 0, length: 0)
        ) == nil,
        "AgentCompletion: a caret before the trigger opened suggestions"
    )
    expect(
        query?.replacementRange == NSRange(location: 5, length: ("@\"Sources/My File.swift\"" as NSString).length),
        "AgentCompletion: middle-caret replacement did not span the complete quoted token"
    )

    let escaped = "use @Sources/My\\ File.swift"
    let escapedQuery = AgentCompletionQueryDetector.activeQuery(
        in: escaped,
        selection: NSRange(location: (escaped as NSString).length, length: 0)
    )
    expect(escapedQuery?.text == "Sources/My File.swift", "AgentCompletion: escaped whitespace ended the query")
    let unicode = "open @\"Design/🧭 Map.swift\""
    let unicodeQuery = AgentCompletionQueryDetector.activeQuery(
        in: unicode,
        selection: NSRange(location: (unicode as NSString).length, length: 0)
    )
    expect(unicodeQuery?.text == "Design/🧭 Map.swift", "AgentCompletion: UTF-16 query decoding damaged a path")
    expect(
        AgentCompletionQueryDetector.activeQuery(
            in: "literal \\@not-a-query",
            selection: NSRange(location: ("literal \\@not-a-query" as NSString).length, length: 0)
        ) == nil,
        "AgentCompletion: escaped/non-boundary trigger opened suggestions"
    )
    expect(
        AgentCompletionQueryDetector.activeQuery(
            in: "say @thing",
            selection: NSRange(location: 4, length: 2)
        ) == nil,
        "AgentCompletion: non-caret selection opened suggestions"
    )

    let fixtureProviders = AgentCompletionFixtures.providers()
    expect(
        Set(fixtureProviders.map(\.trigger)) == ["/", "@", "$"],
        "AgentCompletion: bounded slash/file/skill fixture registrations are incomplete"
    )
    expect(
        Set(fixtureProviders.map(\.providerID)).count == fixtureProviders.count,
        "AgentCompletion: fixture provider IDs are not replaceable without collision"
    )
    let semanticPayloads: [AgentCompletionPayload] = [
        .insertText("literal"),
        .file(AgentPromptFileReference(
            displayName: "README.md",
            contentType: "text/markdown",
            fileURL: URL(fileURLWithPath: "/tmp/array-completion-check/README.md")
        )),
        .skill(ResolvedSkillInvocation(name: "review", providerHandle: "skill.review")),
        .promptTemplate(ResolvedPromptTemplate(name: "handoff", prompt: "Prepare a handoff")),
        .runtimeCommand(ResolvedRuntimeCommand(name: "compact", providerHandle: "runtime.compact")),
        .directory(DirectoryNavigationTarget(
            directoryURL: URL(fileURLWithPath: "/tmp/array-completion-check/Sources", isDirectory: true)
        )),
    ]
    let semanticPayloadKinds = Set(semanticPayloads.map { payload in
        switch payload {
        case .insertText: return "text"
        case .file: return "file"
        case .skill: return "skill"
        case .promptTemplate: return "template"
        case .runtimeCommand: return "runtime"
        case .directory: return "directory"
        }
    })
    expect(
        semanticPayloadKinds == ["text", "file", "skill", "template", "runtime", "directory"],
        "AgentCompletion: typed contract does not exercise every semantic acceptance path"
    )

    let checkoutRoot = URL(fileURLWithPath: "/tmp/array-completion-checkout", isDirectory: true)
    let context = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!),
        backend: .codex,
        checkoutRoot: checkoutRoot,
        gitRoot: checkoutRoot,
        arrayProjectRoot: URL(fileURLWithPath: "/tmp/array-project", isDirectory: true),
        trustState: .trusted
    )
    let contextualQuery = AgentCompletionQuery(
        trigger: "@",
        text: "Source",
        replacementRange: NSRange(location: 0, length: 7),
        context: context
    )
    expect(
        contextualQuery.context == context
            && contextualQuery.context?.backend == .codex
            && contextualQuery.context?.checkoutRoot == checkoutRoot,
        "AgentCompletion: one query did not retain its immutable agent/backend/checkout context"
    )

    let legacyText = AgentCompletion(id: "legacy", title: "legacy", insertionText: "/legacy")
    expect(
        legacyText.payload == .insertText("/legacy"),
        "AgentCompletion: source-compatible text results lost explicit insertion semantics"
    )

    let preferredProvenance = AgentCompletionProvenance(
        backend: .claudeCode,
        scope: .personal,
        sourceIdentifier: "~/.claude/commands/help.md",
        invocationName: "help"
    )

    let slashA = StaticAgentCompletionProvider(
        providerID: "commands-a",
        trigger: "/",
        completions: [
            AgentCompletion(
                id: "help-a",
                title: "help",
                detail: "Primary help",
                insertionText: "/help",
                score: 20,
                payload: .promptTemplate(ResolvedPromptTemplate(name: "help", prompt: "Explain available help")),
                provenance: preferredProvenance
            ),
            AgentCompletion(id: "history", title: "history", insertionText: "/history", score: 5),
        ]
    )
    let slashB = StaticAgentCompletionProvider(
        providerID: "commands-b",
        trigger: "/",
        completions: [
            AgentCompletion(id: "help-b", title: "Help", detail: "Secondary help", insertionText: "/help", score: 10),
            AgentCompletion(id: "handoff", title: "handoff", insertionText: "/handoff", score: 50),
        ]
    )
    let file = StaticAgentCompletionProvider(
        providerID: "files",
        trigger: "@",
        completions: [AgentCompletion(id: "file", title: "Help.swift", insertionText: "@Help.swift", score: 100)]
    )
    let registry = AgentCompletionProviderRegistry(providers: [slashB, file, slashA])
    let slashQuery = AgentCompletionQuery(
        trigger: "/", text: "he", replacementRange: NSRange(location: 0, length: 3)
    )
    let merged = await registry.suggestions(for: slashQuery)
    expect(merged.map(\.insertionText) == ["/help"], "AgentCompletion: trigger filtering/static filtering/dedupe was not exact")
    expect(merged[0].id == "help-a" && merged[0].score == 20, "AgentCompletion: deterministic merge did not retain the preferred result")
    expect(merged[0].providerIDs == ["commands-a", "commands-b"], "AgentCompletion: dedupe dropped provider provenance")
    expect(
        merged[0].payload == .promptTemplate(ResolvedPromptTemplate(name: "help", prompt: "Explain available help"))
            && merged[0].provenance == preferredProvenance,
        "AgentCompletion: deterministic merge detached semantic payload/provenance from the preferred row"
    )
    expect(!merged.contains(where: { $0.id == "file" }), "AgentCompletion: a provider for another trigger leaked into results")

    await registry.register(StaticAgentCompletionProvider(
        providerID: "commands-a",
        trigger: "/",
        completions: [AgentCompletion(id: "hello", title: "hello", insertionText: "/hello", score: 1)]
    ))
    let replaced = await registry.suggestions(for: slashQuery)
    expect(replaced.map(\.id) == ["help-b", "hello"], "AgentCompletion: same-ID provider registration did not replace deterministically")

    let localeIndependentRegistry = AgentCompletionProviderRegistry(providers: [
        StaticAgentCompletionProvider(
            providerID: "locale-order",
            trigger: "$",
            completions: [
                AgentCompletion(id: "item-2", title: "item 2", insertionText: "$item-2"),
                AgentCompletion(id: "item-10", title: "item 10", insertionText: "$item-10"),
            ]
        )
    ])
    let localeIndependent = await localeIndependentRegistry.suggestions(for: AgentCompletionQuery(
        trigger: "$", text: "", replacementRange: NSRange(location: 0, length: 1)
    ))
    expect(
        localeIndependent.map(\.id) == ["item-10", "item-2"],
        "AgentCompletion: ordering used locale-aware natural comparison instead of fixed lexical ranking"
    )

    let delayed = DelayedCompletionProvider(
        providerID: "delayed",
        trigger: "$",
        delayNanoseconds: 200_000_000,
        values: [AgentCompletion(id: "stale", title: "stale", insertionText: "$stale")]
    )
    await registry.register(delayed)
    let staleTask = Task {
        await registry.suggestions(for: AgentCompletionQuery(
            trigger: "$", text: "st", replacementRange: NSRange(location: 0, length: 3)
        ))
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    staleTask.cancel()
    let stale = await staleTask.value
    expect(stale.isEmpty, "AgentCompletion: cancelled stale request returned actionable suggestions")

    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--agent-completion-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    try witness.run()
    witness.waitUntilExit()
    let output = String(data: witnessError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let expected = "FAIL: agent completion negative witness: escaped trigger opened suggestions"
    expect(witness.terminationStatus != 0, "AgentCompletion: required escaped-trigger negative witness did not observe red")
    expect(output.contains(expected), "AgentCompletion: negative witness missed the named compiled assertion")

    print("Agent completion negative witness observed red (exit \(witness.terminationStatus)): \(expected)")
    print("Agent completion checks passed: semantic payloads/context, quote/escape/middle-caret detection, replacement registry, deterministic dedupe/rank/provenance, trigger isolation, and stale cancellation")
}
