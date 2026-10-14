// Opt-in release acceptance check. This makes paid provider calls and must
// never run as part of ordinary UI QA or the offline matrix.

import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import Foundation

private final class LiveCompactionObservationBox {
    var seenWarningWithCompactAction = false
    var warningFraction: Double?
    var warningUsedTokens: Int?
    var warningWindowTokens: Int?
    var warningButtonEnabled = false
    var warningState: AgentRadialContextMeterState?
    var successfulBoundaries: [AgentCompactionLifecycleEvent] = []
    var toolBoundaryCount = 0
    var failedTurn: String?
    var completedFillTurns = 0
    var turnPromptPeakTokens: Int?
    var cumulativePromptTokens = 0
    var peakReportedTokens = 0
    var initialEpoch: UInt64?
}

private final class LiveCompactionProviderEvidence: Encodable {
    var harness: String
    var model: String
    var status = "running"
    var failureCategory: String?
    var windowTokens: Int?
    var latestPromptTokens: Int?
    var peakPromptTokens: Int?
    var warningUsedTokens: Int?
    var warningPercent: Int?
    var warningCompactButtonVisible = false
    var boundaryObserved = false
    var trigger: String?
    var epochDelta: UInt64?
    var preCompactionTokens: Int?
    var postCompactionTokens: Int?
    var fillCharacters = 0
    var fillTurns = 0
    var cumulativePromptTokens = 0
    var toolBoundaries = 0
    var transcriptRetained = false
    var exactMarkerRecall = false

    init(harness: String, model: String) {
        self.harness = harness
        self.model = model
    }
}

private final class LiveCompactionEvidenceJournal {
    let url: URL
    var providers: [LiveCompactionProviderEvidence] = []
    private(set) var writeFailed = false

    init(url: URL) { self.url = url }

    func append(_ provider: LiveCompactionProviderEvidence) {
        providers.append(provider)
        flush()
    }

    func flush() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(providers)
            try data.write(to: url, options: .atomic)
            writeFailed = false
        } catch {
            writeFailed = true
        }
    }
}

@MainActor
func runAgentContextLiveCompactionChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(
        _ message: @autoclosure () -> String,
        until deadline: Date,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(description: message())
    }

    #if os(macOS)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "array-live-context-compaction-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    var allProviderLegsPassed = false
    defer {
        if allProviderLegsPassed && ProcessInfo.processInfo.environment["ARRAY_CONTEXT_LIVE_KEEP_SCRATCH"] != "1" {
            try? fm.removeItem(at: root)
        } else {
            fputs("live context compaction private scratch retained: \(root.path)\n", stderr)
        }
    }

    let configuredEvidencePath = ProcessInfo.processInfo.environment["ARRAY_CONTEXT_LIVE_EVIDENCE"]
    let proposedEvidenceURL: URL
    if let configuredEvidencePath, !configuredEvidencePath.isEmpty {
        let configured = URL(fileURLWithPath: NSString(string: configuredEvidencePath).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        proposedEvidenceURL = fm.fileExists(atPath: configured.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? configured.appendingPathComponent("live-context-compaction-\(UUID().uuidString).json")
            : configured
    } else {
        proposedEvidenceURL = fm.temporaryDirectory.appendingPathComponent(
            "array-live-context-compaction-evidence-\(UUID().uuidString).json")
    }
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let evidenceURL = proposedEvidenceURL.path == root.path || proposedEvidenceURL.path.hasPrefix(rootPrefix)
        ? fm.temporaryDirectory.appendingPathComponent("array-live-context-compaction-evidence-\(UUID().uuidString).json")
        : proposedEvidenceURL
    let evidenceJournal = LiveCompactionEvidenceJournal(url: evidenceURL)
    evidenceJournal.flush()
    guard !evidenceJournal.writeFailed else {
        throw Failure(description: "live compaction: sanitized evidence sink could not be created")
    }

    // App-server has no no-user-config switch for its auth lookup. Preserve the
    // user's login file by symlink, but give Codex a fresh private home before
    // catalog discovery so no MCP/plugin config can leak into this run.
    let originalEnvironment = ProcessInfo.processInfo.environment
    let originalCodexHome = originalEnvironment["CODEX_HOME"]
    let sourceCodexHome = URL(fileURLWithPath: NSString(string: originalCodexHome ?? "~/.codex")
        .expandingTildeInPath).standardizedFileURL
    let isolatedCodexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    try fm.createDirectory(at: isolatedCodexHome, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedCodexHome.path)
    let authSource = sourceCodexHome.appendingPathComponent("auth.json")
    let codexAuthAvailable = fm.fileExists(atPath: authSource.path)
    if codexAuthAvailable {
        try fm.createSymbolicLink(
            at: isolatedCodexHome.appendingPathComponent("auth.json"),
            withDestinationURL: authSource)
    }
    let modelCache = sourceCodexHome.appendingPathComponent("models_cache.json")
    if fm.fileExists(atPath: modelCache.path) {
        try fm.copyItem(at: modelCache, to: isolatedCodexHome.appendingPathComponent("models_cache.json"))
    }
    setenv("CODEX_HOME", isolatedCodexHome.path, 1)
    let priorCodexTransport = originalEnvironment["CONTINUUM_CODEX_TRANSPORT"]
    setenv("CONTINUUM_CODEX_TRANSPORT", "appServer", 1)
    let priorPiTransport = originalEnvironment["CONTINUUM_PI_TRANSPORT"]
    setenv("CONTINUUM_PI_TRANSPORT", "rpc", 1)
    defer {
        if let originalCodexHome { setenv("CODEX_HOME", originalCodexHome, 1) }
        else { unsetenv("CODEX_HOME") }
        if let priorCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", priorCodexTransport, 1) }
        else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
        if let priorPiTransport { setenv("CONTINUUM_PI_TRANSPORT", priorPiTransport, 1) }
        else { unsetenv("CONTINUUM_PI_TRANSPORT") }
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
        if process.isRunning { process.terminate(); return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let servers = json as? [[String: Any]] { return servers.isEmpty }
        if let object = json as? [String: Any], let servers = object["servers"] as? [[String: Any]] {
            return servers.isEmpty
        }
        if let object = json as? [String: Any], let servers = object["mcpServers"] as? [String: Any] {
            return servers.isEmpty
        }
        return false
    }
    let codexHasEmptyMCP = codexAuthAvailable && codexHasEmptyMCPConfiguration()

    // Catalog probes are non-turn calls. Run them only after CODEX_HOME has
    // been isolated, then require each selected default model to be installed.
    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    let catalogDeadline = Date().addingTimeInterval(20)
    while catalog.refreshInFlightForQA && Date() < catalogDeadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    let catalogRefreshed = !catalog.refreshInFlightForQA
    typealias LiveSelection = (harness: AgentHarness, model: String, thinking: String)
    let defaults: [LiveSelection] = [AgentHarness.claudeCode, .codex, .pi].map { harness in
        let resolution = AgentModelConfig.resolvedFromDefaults(harness: harness)
        // Use the exact model from the installed Pi capture, whose tiny turn
        // succeeded. Pi's first catalog entry (Spark) can lack account access
        // despite provider-level auth being ready.
        let model = harness == .pi
            ? ProcessInfo.processInfo.environment["ARRAY_CONTEXT_LIVE_PI_MODEL"] ?? "openai-codex/gpt-5.6-sol"
            : resolution.model
        return (harness: harness, model: model, thinking: resolution.thinking)
    }
    // The same settings parser as Settings ▸ Agents, pinned to the product's
    // documented 90% default for this opt-in witness. UI thresholds remain the
    // production 75%/90% presentation; the window itself is never fabricated.
    let testDefaultsName = "array-live-compaction-policy-\(UUID().uuidString)"
    guard let testDefaults = UserDefaults(suiteName: testDefaultsName) else {
        throw Failure(description: "live compaction: cannot create isolated settings suite")
    }
    defer { testDefaults.removePersistentDomain(forName: testDefaultsName) }
    testDefaults.set(true, forKey: AgentContextAutoCompactionPolicy.enabledKey)
    testDefaults.set(90, forKey: AgentContextAutoCompactionPolicy.percentKey)
    guard AgentContextAutoCompactionPolicy.threshold(defaults: testDefaults) == 0.90 else {
        throw Failure(description: "live compaction: settings policy did not resolve the default 90% trigger")
    }

    let maximumPromptCharacters = 1_200_000
    let maximumCumulativePromptTokens = 8_000_000
    let maximumTurns = 32
    let marker = "CTXMARK" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    // This literal is deliberately used only in the original seed prompt and
    // the final local assertion. The recall query never contains it.
    let seedPrompt = "Remember this exact marker for this conversation: \(marker). Reply only SEED_OK. Do not use tools."
    let recallPrompt = "What exact marker did my first prompt ask you to remember? Reply with only that marker. Do not use tools."
    let expectedTurnReply = "DATA_OK"

    func noToolMaterial(turn: Int, characterBudget: Int) -> String {
        let header = "FILL-DATA-\(String(format: "%04d", turn)) Keep these synthetic facts as ordinary conversation text. Reply only DATA_OK. Do not use tools.\n"
        let record = "sample alpha beta gamma delta project note item review result accepted context report. "
        let repeated = String(repeating: record, count: max(1, characterBudget / record.count))
        return String((header + repeated).prefix(characterBudget))
    }

    func makeRunner(_ launch: AgentRunnerLaunch) -> AgentRunning {
        guard let harness = launch.record.harness else {
            return AgentSupervisor.productionRunner(for: launch)
        }
        switch harness {
        case .claudeCode:
            var config = AgentSupervisor.claudeRunnerConfig(for: launch.record, workspaceMCP: nil)
            config.extraArgs += ["--tools", "", "--strict-mcp-config", "--setting-sources", "",
                                 "--settings", #"{"disableAllHooks":true}"#]
            return ClaudeAgentRunner(config: config)
        case .codex:
            var config = AgentSupervisor.codexRunnerConfig(for: launch.record, workspaceMCP: nil)
            // Installed app-server accepts global feature/config overrides.
            // The private home has zero MCP; sandbox configuration is passed
            // as -c because the exec-only -s flag is absent from app-server.
            config.extraArgs += ["--disable", "shell_tool", "--disable", "apps",
                                 "--disable", "plugins", "--disable", "remote_plugin", "--disable", "hooks",
                                 "--disable", "multi_agent", "--disable", "browser_use",
                                 "--disable", "browser_use_external", "--disable", "browser_use_full_cdp_access",
                                 "--disable", "computer_use", "--disable", "view_image",
                                 "--disable", "image_generation", "--disable", "code_mode_host",
                                 "--disable", "sleep_tool", "--disable", "workspace_dependencies",
                                 "--disable", "skill_search", "--disable", "skill_mcp_dependency_install",
                                 "-c", "web_search=disabled", "-c", "sandbox_mode=read-only"]
            return CodexAgentRunner(config: config)
        case .pi:
            var config = AgentSupervisor.runnerConfig(for: launch.record, spawnDepth: launch.spawnDepth)
            config.extraArgs = ["--no-tools", "--no-extensions", "--no-skills", "--no-context-files", "--no-approve"]
            config.extensionPaths = []
            return PiRpcAgentRunner(config: config)
        }
    }

    func makeAttachedTile(supervisor: AgentSupervisor, id: AgentID, tileID: UUID, scratch: URL) -> ManagedAgentTileNSView {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "live-context-compaction",
            frame: TileFrame(x: 0, y: 0, width: 640, height: 480),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: scratch.appendingPathComponent("drafts", isDirectory: true),
                debounceInterval: 0),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        return tile
    }

    func runProvider(
        _ selection: LiveSelection,
        evidence: LiveCompactionProviderEvidence
    ) async throws {
        let harness = selection.harness
        evidence.harness = harness.rawValue
        evidence.model = selection.model
        evidenceJournal.flush()
        guard catalogRefreshed,
              catalog.snapshot(for: harness).models.contains(selection.model) else {
            throw Failure(description: "live compaction \(harness.rawValue): catalog did not confirm selected default model")
        }
        if harness == .codex, (!codexAuthAvailable || !codexHasEmptyMCP) {
            throw Failure(description: "live compaction codex: private CODEX_HOME auth/MCP precondition failed")
        }
        let scratch = root.appendingPathComponent(harness.rawValue, isDirectory: true)
        let records = scratch.appendingPathComponent("records", isDirectory: true)
        let drafts = AgentComposerDraftStore(
            applicationSupportDirectory: scratch.appendingPathComponent("drafts-store", isDirectory: true),
            debounceInterval: 0)
        let transcriptRoot = scratch.appendingPathComponent("transcripts", isDirectory: true)
        let transcriptStore = AgentTranscriptStore(root: transcriptRoot)
        let agentStore = AgentStore(applicationSupportDirectory: records)
        let supervisor = AgentSupervisor(
            store: agentStore,
            makeRunner: makeRunner,
            warn: { _ in },
            nameTitlerCommand: { _ in nil },
            nameGenerationTimeout: 1,
            claudeSessionTitle: { _, _ in nil },
            submissionRecoveryStore: drafts,
            transcriptStore: transcriptStore)
        supervisor.qaContextAutoCompactionThreshold = {
            AgentContextAutoCompactionPolicy.threshold(defaults: testDefaults)
        }

        let scratchProject = scratch.appendingPathComponent("empty-checkout", isDirectory: true)
        try fm.createDirectory(at: scratchProject, withIntermediateDirectories: true)
        let tileID = UUID()
        let id = supervisor.spawn(
            role: nil, prompt: nil, cwd: scratchProject, harness: harness,
            model: selection.model, thinking: selection.thinking, tileId: tileID)
        let tile = makeAttachedTile(supervisor: supervisor, id: id, tileID: tileID, scratch: scratch)
        defer {
            tile.detach()
            supervisor.stop(id)
        }
        let observed = LiveCompactionObservationBox()
        observed.initialEpoch = supervisor.records[id]?.contextEpoch ?? 0
        var promptInFlight = false
        tile.onIngestedEvent = { event in
            switch event {
            case let .contextWindowUpdated(_, reading):
                evidence.latestPromptTokens = reading.usedTokens
                evidence.windowTokens = reading.maxTokens ?? evidence.windowTokens
                if promptInFlight, let used = reading.usedTokens {
                    observed.turnPromptPeakTokens = max(observed.turnPromptPeakTokens ?? 0, used)
                    evidence.cumulativePromptTokens = observed.cumulativePromptTokens + (observed.turnPromptPeakTokens ?? used)
                }
                if let used = reading.usedTokens {
                    observed.peakReportedTokens = max(observed.peakReportedTokens, used)
                    evidence.peakPromptTokens = max(evidence.peakPromptTokens ?? 0, used)
                }
                let state = tile.qaCompactStatusContextState
                let fraction = tile.qaCompactStatusContextFraction
                if let fraction, fraction >= 0.75, fraction < 0.90,
                   state == .warning, tile.qaCompactStatusRow.qaCompactContextButtonVisible,
                   tile.qaCompactStatusRow.qaCompactContextButtonEnabled {
                    let firstWarning = !observed.seenWarningWithCompactAction
                    observed.seenWarningWithCompactAction = true
                    observed.warningFraction = fraction
                    observed.warningUsedTokens = reading.usedTokens
                    observed.warningWindowTokens = reading.maxTokens
                    observed.warningButtonEnabled = true
                    observed.warningState = state
                    evidence.warningUsedTokens = reading.usedTokens
                    evidence.warningPercent = Int((fraction * 100).rounded())
                    evidence.warningCompactButtonVisible = true
                    if firstWarning {
                        print("live context compaction warning: harness=\(harness.rawValue) used=\(reading.usedTokens ?? 0) window=\(reading.maxTokens ?? 0) percent=\(Int((fraction * 100).rounded())) compactVisible=true")
                    }
                }
                evidenceJournal.flush()
            case let .compactionChanged(_, lifecycle) where lifecycle.phase == .succeeded:
                observed.successfulBoundaries.append(lifecycle)
                evidence.boundaryObserved = true
                evidence.trigger = lifecycle.trigger.providerValue
                evidence.preCompactionTokens = lifecycle.beforeTokens?.value ?? observed.peakReportedTokens
                if let epoch = supervisor.records[id]?.contextEpoch,
                   let initial = observed.initialEpoch {
                    evidence.epochDelta = epoch >= initial ? epoch - initial : 0
                }
                evidenceJournal.flush()
                print("live context compaction boundary: harness=\(harness.rawValue) trigger=\(lifecycle.trigger.providerValue) phase=succeeded")
            case let .turnCompleted(_, turnID, .failed, _):
                observed.failedTurn = turnID
                evidenceJournal.flush()
            case let .itemStarted(_, _, kind, _):
                switch kind {
                case .commandExecution, .fileChange, .mcpToolCall, .webSearch, .subagent, .plan, .unknown(_):
                    observed.toolBoundaryCount += 1
                    evidence.toolBoundaries = observed.toolBoundaryCount
                default:
                    break
                }
                evidenceJournal.flush()
            default:
                break
            }
        }

        let deadline = Date().addingTimeInterval(600)
        func complete(
            _ prompt: AgentPrompt,
            label: String,
            expectedReply: String
        ) async throws -> Int {
            let priorCardCount = tile.qaRenderedCardCount
            observed.turnPromptPeakTokens = nil
            observed.failedTurn = nil
            promptInFlight = true
            guard supervisor.send(prompt, to: id) else {
                promptInFlight = false
                throw Failure(description: "live compaction \(harness.rawValue): \(label) send was refused")
            }
            try await expectEventually(
                "live compaction \(harness.rawValue): \(label) did not finish and render before the 600-second provider deadline",
                until: deadline) {
                    observed.failedTurn != nil || (!supervisor.isRunning(id)
                        && tile.qaRenderedCardCount > priorCardCount
                        && tile.qaLastAssistantCardBody?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedReply)
                }
            promptInFlight = false
            guard observed.failedTurn == nil else {
                throw Failure(description: "live compaction \(harness.rawValue): provider reported a failed turn")
            }
            let used = observed.turnPromptPeakTokens ?? supervisor.contextWindowSnapshot(for: id)?.usedTokens
            guard let used, used > 0 else {
                throw Failure(description: "live compaction \(harness.rawValue): no prompt-token reading arrived for \(label)")
            }
            observed.cumulativePromptTokens += used
            evidence.cumulativePromptTokens = observed.cumulativePromptTokens
            evidence.latestPromptTokens = used
            evidence.peakPromptTokens = max(evidence.peakPromptTokens ?? 0, used)
            evidenceJournal.flush()
            guard !evidenceJournal.writeFailed else {
                throw Failure(description: "live compaction: sanitized evidence checkpoint write failed")
            }
            guard observed.cumulativePromptTokens <= maximumCumulativePromptTokens else {
                throw Failure(description: "live compaction \(harness.rawValue): cumulative input-token cap exceeded")
            }
            return used
        }

        _ = try await complete(AgentPrompt(seedPrompt), label: "seed", expectedReply: "SEED_OK")
        guard let initial = supervisor.contextWindowSnapshot(for: id),
              let window = initial.maxTokens, window > 0,
              let initialUsed = initial.usedTokens, initialUsed > 0 else {
            throw Failure(description: "live compaction \(harness.rawValue): supervisor published no actual prompt/window pair after seed")
        }
        let initialEpoch = supervisor.records[id]?.contextEpoch ?? 0
        var cumulativeMaterialCharacters = 0
        var lastUsed = initialUsed
        observed.peakReportedTokens = initialUsed
        observed.initialEpoch = initialEpoch
        evidence.windowTokens = window
        evidence.latestPromptTokens = initialUsed
        evidence.peakPromptTokens = max(evidence.peakPromptTokens ?? 0, initialUsed)
        evidence.epochDelta = 0
        evidenceJournal.flush()

        for turn in 0..<maximumTurns {
            guard Date() < deadline else {
                throw Failure(description: "live compaction \(harness.rawValue): 600-second provider deadline expired while filling")
            }
            if (supervisor.records[id]?.contextEpoch ?? initialEpoch) > initialEpoch,
               !observed.successfulBoundaries.isEmpty { break }
            let fraction = Double(lastUsed) / Double(window)
            if fraction >= 0.90 { break }
            // Use bounded 22%-window token steps until the real reading is in
            // the 80%-85% warning band, then make one smaller final approach
            // to 90%. Character conversion is only a chunk-size estimate; the
            // provider's actual published token reading controls every step.
            let targetFraction = fraction < 0.80 ? min(0.82, fraction + 0.22) : 0.90
            let targetTokens = Int(Double(window) * targetFraction)
            let maximumNextPromptTokens = maximumCumulativePromptTokens - observed.cumulativePromptTokens - lastUsed
            guard maximumNextPromptTokens >= 2_000 else {
                throw Failure(description: "live compaction \(harness.rawValue): 8,000,000 cumulative prompt-token cap leaves no bounded fill budget")
            }
            let requestedTokens = min(maximumNextPromptTokens, max(2_000, targetTokens - lastUsed))
            let boundedCharacters = min(maximumPromptCharacters, max(20_000, requestedTokens * 5))
            guard cumulativeMaterialCharacters + boundedCharacters <= 8_000_000 else {
                throw Failure(description: "live compaction \(harness.rawValue): cumulative fill-character cap reached before compaction")
            }
            let material = noToolMaterial(turn: turn, characterBudget: boundedCharacters)
            cumulativeMaterialCharacters += material.count
            evidence.fillCharacters = cumulativeMaterialCharacters
            evidence.fillTurns = observed.completedFillTurns + 1
            evidenceJournal.flush()
            _ = try await complete(AgentPrompt(material), label: "bounded fill \(turn)", expectedReply: expectedTurnReply)
            observed.completedFillTurns += 1
            evidence.fillTurns = observed.completedFillTurns
            guard let reading = supervisor.contextWindowSnapshot(for: id),
                  reading.maxTokens == window else {
                throw Failure(description: "live compaction \(harness.rawValue): actual supervisor context denominator changed or disappeared")
            }
            if let epoch = supervisor.records[id]?.contextEpoch, epoch > initialEpoch,
               !observed.successfulBoundaries.isEmpty { break }
            guard let used = reading.usedTokens, used > lastUsed else {
                throw Failure(description: "live compaction \(harness.rawValue): actual supervisor prompt usage stopped increasing or denominator changed")
            }
            lastUsed = used
            observed.peakReportedTokens = max(observed.peakReportedTokens, used)
            evidence.latestPromptTokens = used
            evidence.peakPromptTokens = max(evidence.peakPromptTokens ?? 0, used)
            evidenceJournal.flush()
            print("live context compaction progress: harness=\(harness.rawValue) turn=\(turn + 1) used=\(used) window=\(window) percent=\(Int((Double(used) / Double(window) * 100).rounded())) cumulativeInputTokens=\(observed.cumulativePromptTokens)")
            if let epoch = supervisor.records[id]?.contextEpoch, epoch > initialEpoch,
               !observed.successfulBoundaries.isEmpty { break }
        }

        if observed.successfulBoundaries.isEmpty,
           (supervisor.records[id]?.contextEpoch ?? initialEpoch) == initialEpoch,
           (Double(lastUsed) / Double(window) < 0.90) {
            throw Failure(description: "live compaction \(harness.rawValue): fill turn cap reached before the 90% trigger")
        }

        try await expectEventually(
            "live compaction \(harness.rawValue): threshold compaction did not finish before the 600-second provider deadline",
            until: deadline) {
                (supervisor.records[id]?.contextEpoch ?? initialEpoch) > initialEpoch
                    && !observed.successfulBoundaries.isEmpty
            }

        guard observed.seenWarningWithCompactAction,
              let warningFraction = observed.warningFraction,
              let warningUsedTokens = observed.warningUsedTokens,
              observed.warningWindowTokens == window,
              observed.warningButtonEnabled,
              warningFraction >= 0.75, warningFraction < 0.90,
              observed.warningState == .warning else {
            throw Failure(description: "live compaction \(harness.rawValue): native Compact action was not observed on a pre-compaction warning reading")
        }
        guard let epoch = supervisor.records[id]?.contextEpoch, epoch > initialEpoch,
              let boundary = observed.successfulBoundaries.last,
              boundary.phase == .succeeded else {
            throw Failure(description: "live compaction \(harness.rawValue): no successful provider compaction boundary advanced the real supervisor epoch")
        }
        guard observed.toolBoundaryCount == 0 else {
            throw Failure(description: "live compaction \(harness.rawValue): a tool ran despite the no-tools configuration")
        }
        evidence.boundaryObserved = true
        evidence.trigger = boundary.trigger.providerValue
        evidence.epochDelta = epoch - initialEpoch
        evidence.preCompactionTokens = observed.peakReportedTokens
        evidenceJournal.flush()

        // This query intentionally does not repeat the marker. The expected
        // value is local to the assertion; the model must retrieve it from the
        // original task after compacting its conversation.
        try await expectEventually(
            "live compaction \(harness.rawValue): compacted runner did not release its turn slot",
            until: deadline) { !supervisor.isRunning(id) }
        try await complete(AgentPrompt(recallPrompt), label: "marker recall", expectedReply: marker)
        guard tile.qaLastAssistantCardBody?.trimmingCharacters(in: .whitespacesAndNewlines) == marker else {
            throw Failure(description: "live compaction \(harness.rawValue): model failed to recall the original task marker exactly")
        }
        evidence.exactMarkerRecall = true
        // Codex publishes exact compacted prompt usage on its next model
        // request, while Claude/Pi may supply it on the boundary itself.
        // Compare against the captured pre-boundary peak after recall finishes.
        guard let postUsed = supervisor.contextWindowSnapshot(for: id)?.usedTokens,
              let preUsed = evidence.preCompactionTokens, postUsed < preUsed else {
            throw Failure(description: "live compaction \(harness.rawValue): next request did not report smaller post-compaction usage")
        }
        evidence.postCompactionTokens = postUsed
        evidence.latestPromptTokens = postUsed
        evidenceJournal.flush()
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
        var transcriptRetained = false
        while Date() < deadline {
            if let persisted = try await transcriptStore.load(agentID: id, sessionID: sessionID) {
                let durableText = AgentTranscriptCopyController.plainText(for: persisted.entries.flatMap(\.blocks))
                transcriptRetained = durableText.contains(marker)
                    && durableText.contains("FILL-DATA-0000")
                    && durableText.contains(expectedTurnReply)
                if transcriptRetained { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard transcriptRetained else {
            throw Failure(description: "live compaction \(harness.rawValue): original task or bounded work is missing from the durable transcript")
        }
        evidence.transcriptRetained = true
        evidence.status = "passed"
        evidence.failureCategory = nil
        evidence.fillCharacters = cumulativeMaterialCharacters
        evidence.fillTurns = observed.completedFillTurns
        evidence.cumulativePromptTokens = observed.cumulativePromptTokens
        evidence.toolBoundaries = observed.toolBoundaryCount
        evidenceJournal.flush()
    }

    let harnessFilter = (ProcessInfo.processInfo.environment["ARRAY_CONTEXT_LIVE_HARNESSES"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    func filterMatches(_ harness: AgentHarness) -> Bool {
        guard !harnessFilter.isEmpty else { return true }
        switch harness {
        case .claudeCode:
            return harnessFilter.contains("claude") || harnessFilter.contains("claudecode")
        case .codex:
            return harnessFilter.contains("codex")
        case .pi:
            return harnessFilter.contains("pi")
        }
    }
    let selected = defaults.filter { filterMatches($0.harness) }
    guard !selected.isEmpty else {
        throw Failure(description: "live compaction: ARRAY_CONTEXT_LIVE_HARNESSES selected no known provider")
    }
    func failureCategory(_ error: Error) -> String {
        guard let failure = error as? Failure else { return "provider-runtime-error" }
        let reason = failure.description.lowercased()
        if reason.contains("catalog") { return "preflight-catalog" }
        if reason.contains("codex_home") || reason.contains("auth/mcp") { return "provider-isolation" }
        if reason.contains("cap") || reason.contains("budget") { return "safety-cap" }
        if reason.contains("warning") || reason.contains("compact action") { return "warning-not-observed" }
        if reason.contains("boundary") || reason.contains("threshold compaction")
            || reason.contains("post-compaction") || reason.contains("compacted runner") {
            return "compaction-not-observed"
        }
        if reason.contains("marker") || reason.contains("recall") { return "marker-recall" }
        if reason.contains("transcript") { return "transcript-retention" }
        if reason.contains("tool") { return "tool-boundary" }
        if reason.contains("render") || reason.contains("turn") || reason.contains("send") { return "turn-completion" }
        if reason.contains("evidence") { return "evidence-write" }
        return "assertion-failed"
    }

    for selection in selected {
        let providerEvidence = LiveCompactionProviderEvidence(
            harness: selection.harness.rawValue,
            model: selection.model)
        evidenceJournal.append(providerEvidence)
        do {
            try await runProvider(selection, evidence: providerEvidence)
        } catch {
            providerEvidence.status = "failed"
            providerEvidence.failureCategory = failureCategory(error)
            if let failure = error as? Failure {
                // Only our fixed assertion descriptions are diagnostic output;
                // provider/runtime errors may contain content or credentials.
                fputs("live context compaction assertion: \(failure.description)\n", stderr)
            }
            evidenceJournal.flush()
            fputs("live context compaction leg failed: harness=\(selection.harness.rawValue) category=\(providerEvidence.failureCategory ?? "assertion-failed")\n", stderr)
        }
    }
    evidenceJournal.flush()
    guard !evidenceJournal.writeFailed else {
        throw Failure(description: "live compaction: sanitized evidence checkpoint write failed")
    }
    let resultData = try JSONEncoder().encode(evidenceJournal.providers)
    let resultJSON = String(decoding: resultData, as: UTF8.self)
    FileHandle.standardOutput.write(Data("LIVE_CONTEXT_COMPACTION_RESULTS path=\(evidenceURL.path) \(resultJSON)\n".utf8))
    allProviderLegsPassed = evidenceJournal.providers.allSatisfy { $0.status == "passed" }
    if !allProviderLegsPassed {
        throw Failure(description: "live compaction: one or more provider legs failed; see sanitized result record")
    }
    #endif
}
