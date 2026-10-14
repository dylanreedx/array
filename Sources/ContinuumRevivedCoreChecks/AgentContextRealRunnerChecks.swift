import ContinuumRevivedCore
import Foundation

private final class RealContextEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentRuntimeEvent] = []
    private var failure: String?
    func append(_ event: AgentRuntimeEvent) { lock.lock(); stored.append(event); lock.unlock() }
    func fail(_ error: Error) { lock.lock(); failure = String(describing: error); lock.unlock() }
    var events: [AgentRuntimeEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
}

/// Release-time witness: each production runner makes one tool-free turn using
/// the user's existing CLI login, then its real telemetry must produce a meter
/// numerator and denominator. This is deliberately separate from the offline
/// matrix fixtures because it contacts the providers.
func runAgentContextRealRunnerChecks() {
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-context-live-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { expect(false, "context live: isolated scratch root must be created: \(error)"); return }
    defer { try? FileManager.default.removeItem(at: root) }

    // Codex app-server has no --ignore-user-config switch. Give it an empty
    // CODEX_HOME with only the user's login file linked in, so its MCP/plugin
    // configuration cannot leak into this live witness.
    let originalEnvironment = ProcessInfo.processInfo.environment
    let originalCodexHome = originalEnvironment["CODEX_HOME"]
    let sourceCodexHome = URL(fileURLWithPath: NSString(string: originalCodexHome ?? "~/.codex")
        .expandingTildeInPath).standardizedFileURL
    let isolatedCodexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    let authSource = sourceCodexHome.appendingPathComponent("auth.json")
    let authDestination = isolatedCodexHome.appendingPathComponent("auth.json")
    guard FileManager.default.fileExists(atPath: authSource.path) else {
        expect(false, "context live: original Codex auth file must exist to isolate its configuration")
        return
    }
    do {
        try FileManager.default.createDirectory(at: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedCodexHome.path)
        try FileManager.default.createSymbolicLink(at: authDestination, withDestinationURL: authSource)
        let sourceModelCache = sourceCodexHome.appendingPathComponent("models_cache.json")
        if FileManager.default.fileExists(atPath: sourceModelCache.path) {
            try FileManager.default.copyItem(
                at: sourceModelCache,
                to: isolatedCodexHome.appendingPathComponent("models_cache.json"))
        }
    } catch {
        expect(false, "context live: isolated Codex home must link the existing auth file")
        return
    }
    setenv("CODEX_HOME", isolatedCodexHome.path, 1)
    defer {
        if let originalCodexHome { setenv("CODEX_HOME", originalCodexHome, 1) }
        else { unsetenv("CODEX_HOME") }
    }

    func codexHasEmptyMCPConfiguration() -> Bool {
        let command = CodexAgentRunner.liveResolvedCommand()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + ["mcp", "list", "--json"]
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let servers = json as? [[String: Any]] { return servers.isEmpty }
        if let object = json as? [String: Any], let servers = object["servers"] as? [[String: Any]] {
            return servers.isEmpty
        }
        return false
    }
    expect(codexHasEmptyMCPConfiguration(), "context live: isolated Codex home must expose zero configured MCP servers")

    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    let refreshDeadline = Date().addingTimeInterval(15)
    while catalog.refreshInFlightForQA && Date() < refreshDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    expect(!catalog.refreshInFlightForQA, "context live: real CLI model catalog probes must finish")
    let claudeCatalog = catalog.snapshot(for: .claudeCode)
    let codexCatalog = catalog.snapshot(for: .codex)
    let piCatalog = catalog.snapshot(for: .pi)
    expect(!claudeCatalog.models.isEmpty, "context live: Claude's installed CLI must offer models")
    expect(!codexCatalog.models.isEmpty, "context live: Codex's installed CLI must offer models")
    expect(!piCatalog.models.isEmpty, "context live: Pi's installed CLI must offer models")
    let resolver = AgentContextWindowResolver()
    let unresolved = resolver.unresolvedModels(in: [claudeCatalog, codexCatalog, piCatalog])
    expect(unresolved.isEmpty, "context live: all actually offered live models must resolve: \(unresolved.joined(separator: ", "))")

    let claudeModel = "anthropic/claude-sonnet-5-5"
    let codexModel = "openai-codex/gpt-5.6-sol"
    let piModel = "openai-codex/gpt-5.6-sol"
    expect(claudeCatalog.models.contains(claudeModel), "context live: Claude 2.1.296 catalog must offer \(claudeModel)")
    expect(codexCatalog.models.contains(codexModel), "context live: Codex catalog must offer \(codexModel)")
    expect(piCatalog.models.contains(piModel), "context live: Pi catalog must offer \(piModel)")

    let prompt = AgentPrompt("Reply with exactly the word OK. Do not use tools.")
    func run(_ label: String, stop: @escaping () -> Void,
             _ body: @escaping @Sendable (@escaping @Sendable (AgentRuntimeEvent) -> Void) throws -> Void) -> [AgentRuntimeEvent] {
        let box = RealContextEvents()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            do { try body { box.append($0) } }
            catch { box.fail(error) }
        }
        if done.wait(timeout: .now() + 150) != .success {
            stop()
            _ = done.wait(timeout: .now() + 5)
            expect(false, "context live: \(label) tiny turn exceeded the 150s limit")
        }
        expect(box.error == nil, "context live: \(label) tiny turn failed: \(box.error ?? "unknown error")")
        let events = box.events
        expect(events.contains { if case .turnCompleted(_, _, .completed, _) = $0 { return true }; return false },
               "context live: \(label) tiny turn must complete")
        return events
    }
    func readings(_ events: [AgentRuntimeEvent]) -> [AgentContextWindowSnapshot] {
        events.compactMap { if case let .contextWindowUpdated(_, snapshot) = $0 { return snapshot }; return nil }
    }
    func actualPrompt(_ snapshots: [AgentContextWindowSnapshot]) -> AgentContextWindowSnapshot? {
        snapshots.last { AgentContextOccupancy.promptTokens(from: $0).map { $0 > 0 } == true }
    }

    let claude = ClaudeAgentRunner(config: .init(
        model: ClaudeCLIBackend.modelArgument(forCatalogId: claudeModel),
        effort: "low", cwd: root, sessionId: UUID().uuidString.lowercased(),
        extraArgs: ["--settings", #"{"disableAllHooks":true}"#, "--tools", "", "--strict-mcp-config",
                    "--setting-sources", ""], conversationMayExist: false))
    let claudeEvents = run("Claude", stop: { claude.stop() }) { handler in try claude.run(prompt: prompt, onEvent: handler) }
    claude.stop()
    let claudeReading = actualPrompt(readings(claudeEvents))
    expect(claudeReading != nil, "context live: Claude must report actual per-request prompt tokens")
    if let claudeReading {
        expect(claudeReading.source == .claudeAssistantUsage,
               "context live: Claude occupancy must come from its assistant request, not result run totals")
        let statedWindow = readings(claudeEvents).compactMap(\.maxTokens).last
        let resolved = resolver.resolve(harness: .claudeCode, model: claudeModel, stated: statedWindow)
        let meter = AgentContextOccupancy.withDerivedOccupancy(claudeReading, contextWindow: resolved.tokens)
        expect(resolved.source == .provider && resolved.tokens == 1_000_000,
               "context live: Claude's own result must state Sonnet 5.5's 1M window; got \(String(describing: resolved.tokens)) from \(resolved.source)")
        expect((meter.usedTokens ?? 0) > 0 && meter.maxTokens == 1_000_000,
               "context live: Claude must fill the meter from actual tokens/window, got \(String(describing: meter.usedTokens))/\(String(describing: meter.maxTokens))")
        print("context live: claude model=\(claudeModel) used=\(meter.usedTokens ?? 0) window=\(meter.maxTokens ?? 0) source=provider")
    }

    // The normal production default is app-server; any inherited emergency
    // override is neutralized for this witness and restored afterwards.
    let previousTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
    setenv("CONTINUUM_CODEX_TRANSPORT", "appServer", 1)
    defer {
        if let previousTransport { setenv("CONTINUUM_CODEX_TRANSPORT", previousTransport, 1) }
        else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
    }
    expect(CodexCLIBackend.transportOverride() == .appServer, "context live: Codex witness must use default app-server transport")
    let codex = CodexAgentRunner(config: .init(
        model: CodexCLIBackend.modelArgument(forCatalogId: codexModel), effort: "low", cwd: root))
    let codexEvents = run("Codex app-server", stop: { codex.stop() }) { handler in try codex.run(prompt: prompt, onEvent: handler) }
    codex.stop()
    let codexReading = actualPrompt(readings(codexEvents))
    expect(codexReading != nil, "context live: Codex app-server must report per-request context tokens")
    if let codexReading {
        expect(codexReading.source == .codexRolloutTokenCount,
               "context live: Codex occupancy must come from last token usage")
        let resolved = resolver.resolve(
            harness: .codex, model: codexModel, stated: codexReading.maxTokens,
            piStore: codexCatalog.contextWindows[codexModel])
        let meter = AgentContextOccupancy.withDerivedOccupancy(codexReading, contextWindow: resolved.tokens)
        expect(resolved.source == .provider && (resolved.tokens ?? 0) > 0,
               "context live: Codex app-server must state a positive modelContextWindow; got \(String(describing: resolved.tokens))")
        expect((meter.usedTokens ?? 0) > 0 && (meter.maxTokens ?? 0) > 0,
               "context live: Codex must fill the meter from actual tokens/window, got \(String(describing: meter.usedTokens))/\(String(describing: meter.maxTokens))")
        print("context live: codex model=\(codexModel) used=\(meter.usedTokens ?? 0) window=\(meter.maxTokens ?? 0) source=provider transport=app-server")
    }

    let piStoreWindow = piCatalog.contextWindows[piModel]
    expect((piStoreWindow ?? 0) > 0, "context live: Pi's live catalogue must publish \(piModel)'s context window")
    let pi = PiAgentRunner(config: .init(
        model: piModel, thinking: "low", cwd: root,
        sessionId: nil, extraArgs: ["--no-tools", "--no-extensions", "--no-skills", "--no-context-files"], extensionPaths: []))
    let piEvents = run("Pi", stop: { pi.stop() }) { handler in try pi.run(prompt: prompt, onEvent: handler) }
    pi.stop()
    let piReading = actualPrompt(readings(piEvents))
    expect(piReading != nil, "context live: Pi must report actual per-request prompt tokens")
    if let piReading {
        expect(piReading.source == .piMessageUsage,
               "context live: Pi occupancy must come from its provider message usage")
        let resolved = resolver.resolve(
            harness: .pi, model: piModel, piStore: piStoreWindow)
        let meter = AgentContextOccupancy.withDerivedOccupancy(piReading, contextWindow: resolved.tokens)
        expect(resolved.tokens == piStoreWindow && (resolved.tokens ?? 0) > 0,
               "context live: Pi denominator must match its actual live catalogue window")
        expect((meter.usedTokens ?? 0) > 0 && meter.maxTokens == piStoreWindow,
               "context live: Pi must fill the meter from actual tokens/catalogue window, got \(String(describing: meter.usedTokens))/\(String(describing: meter.maxTokens))")
        print("context live: pi model=\(piModel) used=\(meter.usedTokens ?? 0) window=\(meter.maxTokens ?? 0) source=\(resolved.source.rawValue)")
    }
    #endif
}
