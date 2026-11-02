import AppKit
import ContinuumRevivedCore
import Foundation

/// Paid, opt-in acceptance of a Managed lead on a REAL CLI (`.plans/102`).
/// The production boot mount, supervisor, workspace MCP, hooks and runners;
/// no catalogue fixtures or scripted CLIs. Run through
/// `scripts/check-managed-live.sh`, never from the matrix.
@MainActor
func runManagedModeLiveChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    let environment = ProcessInfo.processInfo.environment
    guard environment["ARRAY_MANAGED_LIVE"] == "1",
          environment["CONTINUUM_APP_SUPPORT"] != nil,
          let evidencePath = environment["ARRAY_MANAGED_LIVE_EVIDENCE"],
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(description: "Managed live requires ARRAY_MANAGED_LIVE=1, isolated app support and an evidence path (dev only).")
    }
    let harness: AgentHarness = environment["ARRAY_MANAGED_LIVE_HARNESS"] == "codex" ? .codex : .claudeCode
    let evidenceDir = URL(fileURLWithPath: evidencePath).deletingLastPathComponent()
    // Managed ON through the real typed Settings key in a private suite.
    let modeSuite = "array.qa.managed-live"
    let settings = QAIsolatedDefaults(isolatedSuiteName: modeSuite)!
    settings.removePersistentDomain(forName: modeSuite)
    settings.set(true, forKey: AgentManagedModeConfig.enabledKey)
    defer { settings.removePersistentDomain(forName: modeSuite) }

    var evidence: [String: Any] = ["harness": harness.rawValue, "status": "running", "startedAt": ISO8601DateFormatter().string(from: Date())]
    var results: [String: Bool] = [:]
    func save() {
        evidence["results"] = results
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
        }
    }
    func record(_ key: String, _ passed: Bool, _ detail: Any? = nil) {
        results[key] = passed
        if let detail { evidence[key] = detail }
        print("LIVE \(passed ? "PASS" : "FAIL") \(key)\(detail.map { ": \($0)" } ?? "")")
        save()
    }
    save()

    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    guard await waitUntil(timeout: 45, pollInterval: 0.1, { !catalog.refreshInFlightForQA }) else {
        throw Failure(description: "Live catalogue probe timed out")
    }
    let snapshot = catalog.snapshot(for: harness)
    guard snapshot.readiness.canRun else { throw Failure(description: "\(harness.rawValue): \(snapshot.readiness)") }
    let preferred = harness == .claudeCode
        ? snapshot.models.first { $0.localizedCaseInsensitiveContains("sonnet") }
        : snapshot.seedModel
    guard let leadModel = environment["ARRAY_MANAGED_LIVE_MODEL"] ?? preferred, snapshot.models.contains(leadModel) else {
        throw Failure(description: "Choose an exact lead model from the live catalogue via ARRAY_MANAGED_LIVE_MODEL: \(snapshot.models)")
    }
    evidence["leadModel"] = leadModel
    evidence["catalogue"] = snapshot.models

    let fixture = try WorkspaceInvariantsFixture(label: "managed-live")
    defer { fixture.dispose() }
    let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
    evidence["projectRoot"] = root.path
    // A disposable repository with a real test target for command evidence.
    try ".array/\n.worktrees/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "test:\n\tgrep -qx ALPHA greeting.txt\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    for args in [["init", "-q"], ["add", ".gitignore", "Makefile"], ["-c", "user.name=Array Live", "-c", "user.email=live@array.invalid", "commit", "-qm", "seed"]] {
        _ = try HelperRetryWorktreeChecks.git(root, args)
    }
    var supervisor: AgentSupervisor!
    var app: AppDelegate!
    fixture.configureMount = { delegate, _ in
        delegate.qaSettingsDefaults = settings
        app = delegate
        supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: fixture.appSupport),
            nameTitlerCommand: { _ in nil }, claudeSessionTitle: { _, _ in nil },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport),
            transcriptStore: AgentTranscriptStore(root: fixture.appSupport.appendingPathComponent("transcripts")))
        supervisor.workspaceToolsPermission = { .free }
        delegate.agentSupervisor = supervisor
    }
    try fixture.mount()
    // The app installs its sidebar activity feed at launch; the mount does not.
    app.installAgentAwarenessHooks()
    defer {
        supervisor.stopAll()
        // Keep Array's own isolated state (transcripts, records) as evidence.
        let kept = evidenceDir.appendingPathComponent("app-support-\(harness.rawValue)")
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.copyItem(at: fixture.appSupport, to: kept)
    }
    // Lowered so a sleeping helper is flagged inside one paid run.
    supervisor.helperWatchdogThreshold = 20

    let lead = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: harness, model: leadModel,
        thinking: "low", projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root, displayName: "Managed live lead")
    record("leadIsManaged", supervisor.effectiveMode(for: lead) == .managed, supervisor.effectiveMode(for: lead).rawValue)
    guard results["leadIsManaged"] == true else { throw Failure(description: "Lead is not Managed; no model turn was sent.") }
    _ = supervisor.setWorkspaceToolsEnabled(agentID: lead, true)

    var text: [AgentID: String] = [:]
    var answers: [AgentID: [String]] = [:]
    var tools: [AgentID: [String]] = [:]
    var failures: [String] = []
    var context: [AgentID: [Int]] = [:]
    let observer = supervisor.addDeliveredEventObserver { id, event in
        switch event {
        case .turnStarted: text[id] = ""
        case let .contentDelta(_, _, .assistant, delta): text[id, default: ""] += delta
        case let .itemStarted(_, _, _, title): tools[id, default: []].append(title ?? "")
        case let .contextWindowUpdated(_, snapshot): if let used = snapshot.usedTokens { context[id, default: []].append(used) }
        case let .turnCompleted(_, _, outcome, error):
            answers[id, default: []].append(text[id] ?? "")
            if outcome == .failed { failures.append("\(id.rawValue): \(error ?? "turn failed")") }
        case let .runtimeError(_, message): failures.append("\(id.rawValue): \(message)")
        default: break
        }
    }
    defer { supervisor.removeDeliveredEventObserver(observer) }
    func name(_ id: AgentID) -> String { id == lead ? "lead" : (supervisor.records[id]?.humanDisplayName ?? id.rawValue.uuidString) }
    func snapshotAgents() {
        evidence["agents"] = ([lead] + supervisor.children(of: lead)).map { id -> [String: Any] in
            let r = supervisor.records[id]
            var o: [String: Any] = ["id": id.rawValue.uuidString, "name": name(id), "model": r?.model ?? "",
                "mode": r?.mode.rawValue ?? "", "parent": r?.parentAgentID?.rawValue.uuidString ?? "",
                "checkoutRoot": r?.checkoutRoot ?? "", "cwd": r?.cwd ?? "",
                "toolCalls": tools[id] ?? [], "answers": answers[id] ?? [], "contextUsedTokens": context[id] ?? [],
                "hookEvents": (supervisor.hookReceipts[id] ?? []).map { "\($0.event)\($0.toolName.map { ":" + $0 } ?? "")\($0.command.map { " `\($0.prefix(80))`" } ?? "")" }]
            if let report = r?.lastReport?.report {
                o["report"] = ["summary": report.summary, "checks": report.checks.map { "\($0.result.rawValue): \($0.what)" },
                               "commandEvidence": (report.commandEvidence ?? []).map { "\($0)" }]
            }
            if let plan = r?.declaredStatus?.plan { o["declaredPlan"] = plan.map { "\($0)" } }
            if let ctx = r?.delegationContext {
                o["delegation"] = ["brief": String(ctx.brief.prefix(400)), "retryOf": ctx.retryOf?.rawValue.uuidString ?? "",
                                   "createdWorktree": ctx.createdWorktree, "notice": ctx.checkoutNotice ?? ""]
            }
            if let flag = r?.helperWatchdogNeedsYou { o["watchdog"] = flag }
            return o
        }
        evidence["failures"] = failures
        save()
    }

    // Turn 1: two independent jobs at once; job B stalls on purpose.
    let prompt1 = """
    Live Array test of Managed mode in this repo (it has a Makefile). Two independent jobs. Run both helpers at the same time, then collect their reports with wait_agents (timeoutSeconds 240).
    Job A: create greeting.txt containing exactly the line ALPHA, run `make test`, and report the result.
    Job B: create notes.txt containing exactly the line BETA, then run the shell command `sleep 100`, then report.
    Pick each helper's model to fit its job. If a helper is stopped, say so and do not retry it yet. End with one short line per job.
    """
    print("LIVE starting \(harness.rawValue) lead \(leadModel)")
    guard supervisor.send(prompt1, to: lead) else { throw Failure(description: "Lead send refused") }

    // Both helpers exist.
    let delegated = await waitUntil(timeout: 240, pollInterval: 0.2) { supervisor.children(of: lead).count >= 2 }
    snapshotAgents()
    let helpers = supervisor.children(of: lead)
    record("twoHelpersDelegated", delegated && helpers.count >= 2, helpers.map(name))
    guard delegated else { throw Failure(description: "The lead did not start two helpers; inspect \(evidencePath)") }
    func isJobB(_ id: AgentID) -> Bool {
        let brief = supervisor.records[id]?.delegationContext?.brief ?? ""
        return brief.contains("BETA") || brief.contains("sleep")
    }
    let jobB = helpers.first(where: isJobB)
    let jobA = helpers.first { !isJobB($0) }
    record("helperModelsFromCatalogue", helpers.allSatisfy { snapshot.models.contains(supervisor.records[$0]?.model ?? "") },
           helpers.map { "\(name($0)): \(supervisor.records[$0]?.model ?? "?")" })
    record("helpersAreFreeAndTileless", helpers.allSatisfy { supervisor.records[$0]?.mode == .free && supervisor.records[$0]?.tileId == nil })
    let checkouts = Set(helpers.compactMap { supervisor.records[$0].map { WorktreeManager.resolved(URL(fileURLWithPath: $0.checkoutRoot)) } })
    record("concurrentHelpersOwnCheckouts", checkouts.count == helpers.count, Array(checkouts))

    // The sidebar, from the production row builder, drawn offscreen.
    // Rows follow the app's own event pushes; a helper with no event yet has
    // no row. Wait for them rather than reading one instant.
    var rows = app.agentInboxRowsForQA()
    _ = await waitUntil(timeout: 20, pollInterval: 0.25) {
        rows = app.agentInboxRowsForQA()
        return rows.filter { $0.parentId == lead.rawValue }.count >= helpers.count
    }
    let helperRows = rows.filter { $0.parentId == lead.rawValue }
    let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: 460))
    inbox.hoverCardEnabled = false
    inbox.onRevealRow = { _ in }
    let window = SidebarSortChecks.CheckWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = inbox
    window.orderFrontOffscreenForChecks()
    defer { window.orderOut(nil) }
    inbox.setScope(.all)
    inbox.restoreParentFolds([lead.rawValue: true])
    inbox.reload(rows: rows)
    inbox.layoutForQA()
    let leadCell = inbox.ownershipCellForQA(id: lead.rawValue)
    leadCell?.layoutSubtreeIfNeeded()
    let anyWorking = helpers.contains { supervisor.isRunning($0) }
    record("sidebarNestsHelpersUnderLead", helperRows.count == helpers.count, ["drawn": inbox.drawnSequenceForQA, "helperRows": helperRows.map(\.title)])
    record("sidebarLeadGlyphWhileHelperWorks", !anyWorking || leadCell?.showsWorkingGlyphForQA == true,
           ["helperRunning": anyWorking, "glyph": leadCell?.showsWorkingGlyphForQA ?? false, "managedBadge": supervisor.showsManagedIndicator(for: lead)])

    // Stall: the sleeping helper is flagged, then stopped as a user would.
    if let jobB {
        let flagged = await waitUntil(timeout: 150, pollInterval: 0.5) { supervisor.records[jobB]?.helperWatchdogNeedsYou != nil || !supervisor.isRunning(jobB) }
        let flag = supervisor.records[jobB]?.helperWatchdogNeedsYou
        record("stallFlagged", flagged && flag != nil, flag ?? "helper ended before it was flagged")
        snapshotAgents()
        if supervisor.isRunning(jobB) { supervisor.stop(jobB) }
    } else {
        record("stallFlagged", false, "no job-B helper identified")
    }
    let turn1 = await waitUntil(timeout: 420, pollInterval: 0.2) { !supervisor.isRunning(lead) && !(answers[lead] ?? []).isEmpty }
    // Let any queued watchdog alert/delivery turns settle.
    _ = await waitUntil(timeout: 120, pollInterval: 0.5) { !supervisor.isRunning(lead) && supervisor.children(of: lead).allSatisfy { !supervisor.isRunning($0) } }
    snapshotAgents()
    record("leadTurn1Completed", turn1, answers[lead] ?? [])
    let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"]
    let leadToolUses = (supervisor.hookReceipts[lead] ?? []).filter { $0.event == "PreToolUse" }.compactMap(\.toolName)
    record("leadNeverEdited", !leadToolUses.contains(where: editTools.contains), leadToolUses)
    record("leadBriefInjected", (supervisor.hookReceipts[lead] ?? []).contains { $0.event == "SessionStart" })
    let plan = supervisor.leadPlan(for: lead)
    record("leadPlanPosted", plan.map { !$0.steps.isEmpty } ?? false, plan.map { $0.steps.map { "\($0.state.rawValue) \($0.owner): \($0.title)" } } ?? [])
    if let jobA {
        let report = supervisor.records[jobA]?.lastReport?.report
        record("helperFiledReport", report != nil, report?.summary ?? "no array_report filed")
        let observed = (report?.commandEvidence ?? []).contains { $0.outcome == .observed }
        record("reportCommandEvidenceObserved", observed, (report?.commandEvidence ?? []).map { "\($0)" })
        let greeting = URL(fileURLWithPath: supervisor.records[jobA]!.checkoutRoot).appendingPathComponent("greeting.txt")
        record("jobAWorkOnDisk", (try? String(contentsOf: greeting, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "ALPHA")
    }

    // Turn 2: retry the stopped helper; its first prompt must carry the old work.
    if let jobB {
        let prompt2 = "I stopped the helper for job B (agent id \(jobB.rawValue.uuidString)). Retry it with array_delegate and retryOf set to that id so it continues the earlier work, but tell it to skip the sleep. Collect its report with wait_agents (timeoutSeconds 180), then answer in one line."
        guard supervisor.send(prompt2, to: lead) else { throw Failure(description: "Lead retry send refused") }
        let retried = await waitUntil(timeout: 240, pollInterval: 0.2) {
            supervisor.children(of: lead).contains { supervisor.records[$0]?.delegationContext?.retryOf == jobB }
        }
        let retry = supervisor.children(of: lead).first { supervisor.records[$0]?.delegationContext?.retryOf == jobB }
        record("retryDelegated", retried && retry != nil)
        _ = await waitUntil(timeout: 300, pollInterval: 0.2) {
            !supervisor.isRunning(lead) && (answers[lead] ?? []).count >= 2 && !(retry.map(supervisor.isRunning) ?? false)
        }
        snapshotAgents()
        // The retry's real first prompt, as Array's own transcript stored it.
        let transcripts = fixture.appSupport.appendingPathComponent("transcripts")
        var carried = false
        if let retry {
            let id = retry.rawValue.uuidString.lowercased()
            let files = (FileManager.default.enumerator(at: transcripts, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            for file in files where file.path.lowercased().contains(id) {
                if let body = try? String(contentsOf: file, encoding: .utf8), body.contains("Retry context"), body.contains("notes.txt") { carried = true }
            }
        }
        record("retryPromptCarriesEarlierWork", carried)
        record("leadTurn2Completed", (answers[lead] ?? []).count >= 2, answers[lead] ?? [])
    }
    snapshotAgents()
    let passed = results.values.allSatisfy { $0 }
    evidence["status"] = passed ? "passed" : "failed"
    save()
    print("LIVE managed \(harness.rawValue): \(results.filter(\.value).count)/\(results.count) passed; evidence \(evidencePath)")
    guard passed else {
        throw Failure(description: "Managed live \(harness.rawValue) failed: \(results.filter { !$0.value }.keys.sorted())")
    }
}
