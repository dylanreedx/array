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
        .command(AgentCommandInvocation(
            descriptorID: "codex:review",
            name: "review",
            harness: .codex,
            surface: .providerSlash
        )),
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
        case .command: return "command"
        case .directory: return "directory"
        }
    })
    expect(
        semanticPayloadKinds == ["text", "file", "skill", "template", "runtime", "command", "directory"],
        "AgentCompletion: typed contract does not exercise every semantic acceptance path"
    )

    let baselineCommands = AgentCommandCatalog.allBaselines()
    expect(
        baselineCommands.contains(where: { $0.id == "array:plan" && $0.name == "plan" })
            && baselineCommands.contains(where: { $0.harness == .claudeCode && $0.name == "batch" && $0.surface == .skill })
            && baselineCommands.contains(where: { $0.harness == .codex && $0.name == "review" })
            && baselineCommands.contains(where: { $0.harness == .codex && $0.name == "worktree" && $0.surface == .providerSlash })
            && baselineCommands.contains(where: { $0.harness == .codex && $0.name == "cloud" && $0.surface == .cli })
            && baselineCommands.contains(where: { $0.harness == .pi && $0.name == "settings" }),
        "AgentCommandCatalog: provider baselines did not retain Array, Claude, Codex, and Pi command families"
    )
    let destructive = baselineCommands.first(where: { $0.id == "codex:delete" })
    expect(
        destructive?.capabilities.contains(.destructive) == true
            && destructive?.capabilities.contains(.localWrite) == true,
        "AgentCommandCatalog: destructive provider commands lost their capability classification"
    )
    let codexInvocation = AgentCommandInvocation(
        descriptorID: "codex:review",
        name: "review",
        arguments: "--base main",
        harness: .codex,
        surface: .providerSlash
    )
    expect(
        codexInvocation.nativeSlashText == "/review --base main"
            && codexInvocation.id == "codex:review",
        "AgentCommandInvocation: native serialization or stable identity was not preserved"
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
    let commandProvider = AgentCommandCompletionProvider()
    let commandContext = AgentCompletionContext(
        agentID: context.agentID,
        backend: .codex,
        checkoutRoot: checkoutRoot,
        gitRoot: checkoutRoot,
        arrayProjectRoot: context.arrayProjectRoot,
        trustState: .trusted
    )
    let commandRows = await commandProvider.suggestions(for: AgentCompletionQuery(
        trigger: "/",
        text: "review",
        replacementRange: NSRange(location: 0, length: 7),
        context: commandContext
    ))
    expect(
        commandRows.contains(where: { $0.id == "codex:review" && $0.payload == .command(AgentCommandInvocation(
            descriptorID: "codex:review", name: "review", harness: .codex, surface: .providerSlash
        )) })
            && commandRows.contains(where: { $0.id == "claude-code:code-review" && !$0.isEnabled }),
        "AgentCommandCompletionProvider: active-provider command payloads or disabled other-provider rows were not surfaced"
    )
    let harnessRows = await commandProvider.suggestions(for: AgentCompletionQuery(
        trigger: "/",
        text: "qa",
        replacementRange: NSRange(location: 0, length: 3),
        context: commandContext
    ))
    expect(
        harnessRows.contains(where: {
            $0.id == "array:qa"
                && !$0.isEnabled
                && $0.disabledReason == "Run from Array Command Center"
        }),
        "AgentCommandCompletionProvider: CLI/harness actions bypassed the approval surface"
    )
    let encodedDescriptor = try JSONEncoder().encode(AgentCommandCatalog.baseline(for: .codex).first!)
    let decodedDescriptor = try JSONDecoder().decode(AgentCommandDescriptor.self, from: encodedDescriptor)
    expect(
        decodedDescriptor == AgentCommandCatalog.baseline(for: .codex).first,
        "AgentCommandDescriptor: metadata-only cache encoding lost descriptor identity"
    )

    let fileManager = FileManager.default
    let resourceRoot = fileManager.temporaryDirectory
        .appendingPathComponent("array-command-resources-\(UUID().uuidString)", isDirectory: true)
    let resourceCheckout = resourceRoot.appendingPathComponent("checkout", isDirectory: true)
    let resourceHome = resourceRoot.appendingPathComponent("home", isDirectory: true)
    try fileManager.createDirectory(at: resourceCheckout.appendingPathComponent(".claude/skills/review", isDirectory: true), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourceRoot.appendingPathComponent(".claude/skills/inherited", isDirectory: true), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourceCheckout.appendingPathComponent(".claude/commands", isDirectory: true), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourceCheckout.appendingPathComponent(".pi/extensions", isDirectory: true), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourceCheckout.appendingPathComponent(".array/commands", isDirectory: true), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: resourceRoot) }
    try Data("---\nname: review\ndescription: Review staged changes\narguments: <scope>\ncontext: fork\n---\nprivate body\n".utf8)
        .write(to: resourceCheckout.appendingPathComponent(".claude/skills/review/SKILL.md"))
    try Data("---\nname: inherited\ndescription: Parent project skill\n---\nparent body\n".utf8)
        .write(to: resourceRoot.appendingPathComponent(".claude/skills/inherited/SKILL.md"))
    try Data("---\nname: legacy-check\ndescription: Legacy command\nuser-invocable: false\n---\nbody\n".utf8)
        .write(to: resourceCheckout.appendingPathComponent(".claude/commands/legacy-check.md"))
    try Data("export default function command() {}".utf8)
        .write(to: resourceCheckout.appendingPathComponent(".pi/extensions/demo.ts"))
    let manifestJSON = """
    {"name":"qa-flow","description":"Run the checked-in QA flow","executable":"swift","arguments":["run","Array","--qa"],"workingDirectory":".","capabilities":["processControl"],"approval":"confirm","supportsArguments":false}
    """
    try Data(manifestJSON.utf8).write(to: resourceCheckout.appendingPathComponent(".array/commands/qa-flow.json"))
    let resourceContext = AgentCompletionContext(
        agentID: context.agentID,
        backend: .claudeCode,
        checkoutRoot: resourceCheckout,
        gitRoot: resourceCheckout,
        arrayProjectRoot: context.arrayProjectRoot,
        trustState: .trusted
    )
    let discoveredResources = AgentCommandResourceDiscovery.discover(context: resourceContext, homeDirectory: resourceHome)
    expect(
        discoveredResources.contains(where: { $0.name == "review" && $0.contextFork && $0.supportsArguments && $0.scope == .project })
            && discoveredResources.contains(where: { $0.name == "legacy-check" && !$0.userInvocable })
            && discoveredResources.contains(where: { $0.name == "inherited" && $0.scope == .project })
            && discoveredResources.contains(where: { $0.surface == .extensionCommand && !$0.isEnabled && $0.availability == .requiresTrust("Trust this extension before loading executable code") }),
        "AgentCommandResourceDiscovery: provider frontmatter, legacy commands, or extension trust metadata was lost"
    )
    let discoveredManifest = AgentHarnessCommandManifestDiscovery.discover(context: resourceContext)
    expect(
        discoveredManifest.count == 1 && discoveredManifest[0].name == "qa-flow"
            && discoveredManifest[0].surface == .cli
            && discoveredManifest[0].capabilities.contains(.processControl),
        "AgentHarnessCommandManifestDiscovery: safe argv manifest was not indexed"
    )
    expect(
        AgentHarnessExecutableProbe.locate(harness: .codex, environment: ["PATH": "/definitely/missing"]) == nil,
        "AgentHarnessExecutableProbe: missing provider executable was incorrectly reported as available"
    )
    let runnerRoot = resourceRoot.appendingPathComponent("runner-root", isDirectory: true)
    try fileManager.createDirectory(at: runnerRoot, withIntermediateDirectories: true)
    let runnerResult = await AgentHarnessCommandRunner.run(
        executable: "/bin/echo",
        arguments: ["$(touch SHOULD_NOT_EXIST)", "argv-safe"],
        workingDirectory: runnerRoot,
        checkoutRoot: runnerRoot
    )
    expect(
        runnerResult.status == .completed
            && runnerResult.summary.contains("$(touch SHOULD_NOT_EXIST)")
            && runnerResult.artifactURL.map { fileManager.fileExists(atPath: $0.path) } == true
            && !fileManager.fileExists(atPath: runnerRoot.appendingPathComponent("SHOULD_NOT_EXIST").path),
        "AgentHarnessCommandRunner: argv execution or artifact capture was not shell-free"
    )
    if let artifactURL = runnerResult.artifactURL { try? fileManager.removeItem(at: artifactURL) }
    let refusedRunner = await AgentHarnessCommandRunner.run(
        executable: "/bin/echo",
        arguments: [],
        workingDirectory: resourceRoot,
        checkoutRoot: runnerRoot
    )
    expect(
        refusedRunner.status == .refused("Working directory must remain inside the checkout"),
        "AgentHarnessCommandRunner: checkout cwd containment was not enforced"
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

    let fileIndexRoot = fileManager.temporaryDirectory
        .appendingPathComponent("array-agent-file-index-\(UUID().uuidString)", isDirectory: true)
    let falconOuter = fileIndexRoot.appendingPathComponent("falcon-platform", isDirectory: true)
    let falconRoot = falconOuter.appendingPathComponent("falcon", isDirectory: true)
    try fileManager.createDirectory(at: falconRoot.appendingPathComponent("Sources/Nested", isDirectory: true), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fileIndexRoot) }

    func write(_ relativePath: String, _ contents: String = "fixture") throws {
        let url = falconRoot.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", falconRoot.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "AgentCompletion: git fixture command failed: \(arguments.joined(separator: " "))")
    }

    try write("README.md", "falcon")
    try write("Sources/FalconClient.swift")
    try write("Sources/Nested/My Quoted 'File'.swift")
    try write("Sources/Nested/deleted.swift")
    try write("ignored.swift")
    try write(".gitignore", "ignored.swift\n")
    try Data("outer decoy".utf8).write(to: falconOuter.appendingPathComponent("OUTER.md"))
    try git(["init", "-q"])
    try git(["add", ".gitignore", "README.md", "Sources"])
    try git(["config", "user.name", "Array Check"])
    try git(["config", "user.email", "array-check@invalid.example"])
    try git(["commit", "-q", "-m", "fixture"])
    let worktreeRoot = fileIndexRoot.appendingPathComponent("falcon-worktree", isDirectory: true)
    try git(["worktree", "add", "-q", "-b", "array-file-index-check", worktreeRoot.path])
    let worktreeContext = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID(uuidString: "ABCDEF98-1234-1234-1234-1234567890AB")!),
        backend: .codex,
        checkoutRoot: worktreeRoot,
        gitRoot: worktreeRoot,
        arrayProjectRoot: falconOuter,
        trustState: .trusted
    )
    let worktreeResults = await AgentFileIndex().suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "readme", replacementRange: NSRange(location: 0, length: 7), context: worktreeContext
    ))
    guard case let .file(worktreeReference) = worktreeResults.first?.payload else {
        expect(false, "AgentCompletion: a real Git worktree root did not index tracked files")
        return
    }
    expect(
        worktreeReference.fileURL == worktreeRoot.appendingPathComponent("README.md"),
        "AgentCompletion: worktree indexing escaped to its primary repository"
    )
    let outside = fileIndexRoot.appendingPathComponent("outside", isDirectory: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    try write("Sources/linked-target.swift")
    try fileManager.createSymbolicLink(
        at: falconRoot.appendingPathComponent("Sources/outside-link", isDirectory: true),
        withDestinationURL: outside
    )

    let falconContext = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID(uuidString: "FEDCBA98-1234-1234-1234-1234567890AB")!),
        backend: .codex,
        checkoutRoot: falconRoot,
        gitRoot: falconRoot,
        arrayProjectRoot: falconOuter,
        trustState: .trusted
    )
    let fileIndex = AgentFileIndex(entryLimit: 100, resultLimit: 3)
    let rootFiles = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "", replacementRange: NSRange(location: 0, length: 1), context: falconContext
    ))
    expect(
        rootFiles.map(\.title) == ["Sources/", "README.md"],
        "AgentCompletion: empty @ results were not immediate directories-first children: \(rootFiles.map(\.title))"
    )
    expect(
        !rootFiles.contains(where: { $0.detail == "OUTER.md" || $0.detail == "ignored.swift" }),
        "AgentCompletion: Falcon escaped its nested checkout root or included an ignored file"
    )
    guard case let .directory(sourcesTarget) = rootFiles[0].payload else {
        expect(false, "AgentCompletion: directory row did not carry a navigation payload")
        return
    }
    expect(
        sourcesTarget.directoryURL == falconRoot.appendingPathComponent("Sources", isDirectory: true),
        "AgentCompletion: directory payload did not resolve inside Falcon's exact checkout"
    )
    let externalFiles = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "outer", replacementRange: NSRange(location: 0, length: 6),
        context: falconContext, navigationPath: falconOuter.path
    ))
    guard case let .file(externalReference) = externalFiles.first?.payload else {
        expect(false, "AgentCompletion: explicit external scope did not produce a file payload")
        return
    }
    expect(
        externalReference.fileURL == falconOuter.appendingPathComponent("OUTER.md"),
        "AgentCompletion: external navigation did not preserve the selected absolute file"
    )
    let boundedChildren = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "", replacementRange: NSRange(location: 0, length: 1),
        context: falconContext, navigationPath: "Sources"
    ))
    expect(
        boundedChildren.count == 3 && boundedChildren.first?.title == "Nested/",
        "AgentCompletion: result ceiling or directory-first scoped order was not enforced"
    )

    let fuzzyFiles = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "fc", replacementRange: NSRange(location: 0, length: 3),
        context: falconContext, navigationPath: "Sources"
    ))
    expect(
        fuzzyFiles.first?.detail == "Sources/FalconClient.swift",
        "AgentCompletion: deterministic basename fuzzy ranking did not prefer FalconClient.swift"
    )
    let quotedFiles = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "quoted file", replacementRange: NSRange(location: 0, length: 12),
        context: falconContext, navigationPath: "Sources/Nested"
    ))
    guard case let .file(indexedReference) = quotedFiles.first?.payload else {
        expect(false, "AgentCompletion: spaced/quoted file did not produce a semantic file payload")
        return
    }
    let dragDropShape = AgentPromptFileReference(
        displayName: "My Quoted 'File'.swift",
        contentType: indexedReference.contentType,
        fileURL: falconRoot.appendingPathComponent("Sources/Nested/My Quoted 'File'.swift")
    )
    expect(
        indexedReference == dragDropShape,
        "AgentCompletion: @ acceptance did not produce the drag/drop AgentPromptFileReference shape"
    )

    try fileManager.removeItem(at: falconRoot.appendingPathComponent("Sources/Nested/deleted.swift"))
    let deleted = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "deleted", replacementRange: NSRange(location: 0, length: 8),
        context: falconContext
    ))
    expect(deleted.isEmpty, "AgentCompletion: a deleted cached path remained actionable")
    let symlink = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "outside-link", replacementRange: NSRange(location: 0, length: 13),
        context: falconContext
    ))
    expect(symlink.isEmpty, "AgentCompletion: a symlink could navigate outside the checkout")
    let cancelled = Task {
        await fileIndex.suggestions(for: AgentCompletionQuery(
            trigger: "@", text: "Falcon", replacementRange: NSRange(location: 0, length: 7), context: falconContext
        ))
    }
    cancelled.cancel()
    let cancelledResults = await cancelled.value
    expect(cancelledResults.isEmpty, "AgentCompletion: cancelled file-index query returned actionable rows")

    let untrusted = AgentCompletionContext(
        agentID: falconContext.agentID,
        backend: falconContext.backend,
        checkoutRoot: falconContext.checkoutRoot,
        gitRoot: falconContext.gitRoot,
        arrayProjectRoot: falconContext.arrayProjectRoot,
        trustState: .untrusted
    )
    let untrustedResults = await fileIndex.suggestions(for: AgentCompletionQuery(
        trigger: "@", text: "", replacementRange: NSRange(location: 0, length: 1), context: untrusted
    ))
    expect(untrustedResults.isEmpty, "AgentCompletion: untrusted checkout exposed file capabilities")

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
    print("Agent completion checks passed: semantic payloads/context, checkout-aware and explicit external file index/root/ignore/symlink/deletion/fuzzy/navigation/acceptance behavior, quote/escape/middle-caret detection, replacement registry, deterministic dedupe/rank/provenance, trigger isolation, and stale cancellation")
}
