import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// .plans/101 slice 1 — live limits and identity, through production.
///
/// A real `AgentSupervisor` with real records and real attached tiles; only the
/// CLI read is a fixture (`accountUsageReader`), because no check may ask a real
/// login. What it pins:
///
/// - attaching a tile asks for the account's limits with no turn, ONCE per
///   harness however many tiles attach, and the answer reaches the row: its
///   account presentation (drawn in the hover card) names the plan, the pills
///   say what is left;
/// - a newer read waits out its interval and never overlaps one in flight;
/// - a read that names no login (timeout or sign-out) changes nothing;
/// - a different login replaces the account and drops the old login's windows;
/// - pi is never asked and shows no account;
/// - with the live gate off, the production reader spawns nothing.
@MainActor
func runAgentAccountUsageAppChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }

    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var next: [String: AgentAccountUsageProbe.Reading?] = [:]
        private var gate: DispatchSemaphore?
        func set(_ accountId: String, _ reading: AgentAccountUsageProbe.Reading?) {
            lock.withLock { next[accountId] = .some(reading) }
        }
        func hold() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
        func release() {
            let held = lock.withLock { () -> DispatchSemaphore? in defer { gate = nil }; return gate }
            held?.signal()
        }
        var callLog: [String] { lock.withLock { calls } }
        func read(_ account: AgentAccount) -> AgentAccountUsageProbe.Reading? {
            let (reading, gate) = lock.withLock { () -> (AgentAccountUsageProbe.Reading?, DispatchSemaphore?) in
                calls.append(account.id)
                return ((next[account.id] ?? nil), self.gate)
            }
            gate?.wait()
            return reading
        }
    }

    let now = Date()
    func identity(_ email: String, org: String, plan: String) -> AgentAccountIdentity {
        AgentAccountIdentity(harness: .claudeCode, email: email, organizationId: org, plan: plan, observedAt: now)
    }
    func quota(_ fiveHour: Double, _ weekly: Double) -> AgentAccountQuotaSnapshot {
        AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: [
                AgentQuotaWindow(kind: .fiveHour, utilization: fiveHour, resetsAt: now.addingTimeInterval(7_200)),
                AgentQuotaWindow(kind: .sevenDay, utilization: weekly, resetsAt: now.addingTimeInterval(500_000)),
            ],
            observedAt: now, source: .claudeUsageRequest)
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("account-usage-app-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    // The production reader, gate never enabled in a check process: it must
    // answer nil without spawning anything.
    let gated = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("gated")))
    try require(gated.accountUsageReader(AgentAccount.defaultAccount(for: .claudeCode)) == nil
                    && gated.accountUsageReader(AgentAccount.defaultAccount(for: .codex)) == nil,
                "with the live gate off the production reader must read nothing")

    let reader = Reader()
    let personalID = AgentAccount.defaultAccountId(for: .claudeCode)
    let personal = AgentAccount.defaultAccount(for: .claudeCode)
    reader.set(personalID, .init(identity: identity("personal@example.com", org: "org-personal", plan: "max"),
                                  quota: quota(0.11, 0.14)))
    let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("store")))
    defer { supervisor.stopAll() }
    supervisor.accountUsageReader = { reader.read($0) }

    func attachTile(harness: AgentHarness) -> (AgentID, ManagedAgentTileNSView) {
        let tileID = UUID()
        let config = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: harness,
                                  model: config.model, thinking: config.thinking, tileId: tileID)
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "account-usage-check",
            frame: TileFrame(x: 0, y: 0, width: 900, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: root.appendingPathComponent("drafts-\(tileID.uuidString)"),
                debounceInterval: 60),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        return (id, tile)
    }
    /// The account the row holds for its hover card, e.g. `Claude · Max`.
    func account(_ tile: ManagedAgentTileNSView) -> String? {
        tile.qaCompactStatusRow.qaAccountPresentation?.card.title
    }
    func facts(_ tile: ManagedAgentTileNSView) -> String {
        let row = tile.qaCompactStatusRow
        return "account \(String(describing: account(tile))) 5h '\(row.qaQuotaText(.quotaFiveHour))' 7d '\(row.qaQuotaText(.quotaSevenDay))' reads \(reader.callLog)"
    }

    // (1) Attach asks once, with no turn, and the row names the account.
    let (firstID, first) = attachTile(harness: .claudeCode)
    try await expectEventually("attaching must read the account and paint it: \(facts(first))") {
        account(first) == "Claude · Max"
            && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 89%"
            && first.qaCompactStatusRow.qaQuotaText(.quotaSevenDay) == "7d 86%"
    }
    try require(supervisor.accountIdentity(for: firstID)?.email == "personal@example.com",
                "the supervisor must hold the login it read")
    let (_, second) = attachTile(harness: .claudeCode)
    try await expectEventually("a second tile on the same login must show the same account: \(facts(second))") {
        account(second) == "Claude · Max"
    }
    try require(reader.callLog == [personalID],
                "two tiles on one login must cause ONE read, got \(reader.callLog)")

    // (2) Pi is never asked and shows no account.
    let (_, piTile) = attachTile(harness: .pi)
    try await Task.sleep(for: .milliseconds(100))
    try require(!reader.callLog.contains(where: { $0.hasPrefix("pi.") }) && account(piTile) == nil,
                "pi reports no account and must not be asked: \(facts(piTile))")

    // (3) Throttle and in-flight: inside the interval nothing; past it one
    // read, and a second request while it is out does not start another.
    try require(!supervisor.refreshAccountUsage(account: personal, minimumInterval: 30),
                "a read inside its interval must not start")
    reader.hold()
    reader.set(personalID, .init(identity: identity("personal@example.com", org: "org-personal", plan: "max"),
                                  quota: quota(0.94, 0.20)))
    try require(supervisor.refreshAccountUsage(account: personal, minimumInterval: 30, now: now.addingTimeInterval(31)),
                "a read past its interval must start")
    try require(!supervisor.refreshAccountUsage(account: personal, minimumInterval: 0, now: now.addingTimeInterval(62)),
                "a read must never overlap one still in flight")
    reader.release()
    try await expectEventually("the newer reading must reach every tile on the login: \(facts(second))") {
        second.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 6%"
            && second.qaCompactStatusRow.qaQuotaState(.quotaFiveHour) == .critical
    }
    try require(reader.callLog.filter { $0 == personalID }.count == 2,
                "exactly two reads so far, got \(reader.callLog)")

    // (4) A read that names no login changes nothing.
    reader.set(personalID, .init(identity: nil, quota: nil))
    supervisor.refreshAccountUsage(account: personal, minimumInterval: 0, now: now.addingTimeInterval(120))
    try await expectEventually("the third read must run and finish") {
        reader.callLog.count == 3 && supervisor.qaAccountUsageInFlight.isEmpty
    }
    try require(account(first) == "Claude · Max"
                    && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 6%",
                "a timeout or sign-out must not blank a real reading: \(facts(first))")

    // (5) A different login replaces the account and drops the old windows.
    reader.set(personalID, .init(identity: identity("work@example.com", org: "org-team", plan: "team"), quota: nil))
    supervisor.refreshAccountUsage(account: personal, minimumInterval: 0, now: now.addingTimeInterval(180))
    try await expectEventually("a changed login must replace the account and its windows: \(facts(first))") {
        account(first) == "Claude · Team"
            && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour).isEmpty
    }
    try require(supervisor.accountIdentity(for: firstID)?.email == "work@example.com",
                "the supervisor must hold the new login")

    print("AgentAccountUsageAppChecks passed: attach reads the account once per login with no turn and the row names it (Max, 5h 89%, 7d 86% left); throttle and in-flight guards hold; a read naming no login changes nothing; a new login replaces the account and drops the old windows; pi is never asked; the gated production reader spawns nothing")
}

/// Review captures of the row and its account card, light and dark, normal and
/// near a limit — the four frames of the approved mockup, drawn by the real
/// views. Written only when `CONTINUUM_ACCOUNT_USAGE_CAPTURE_DIR` is set; no
/// gate reads them.
@MainActor
func captureAccountUsageForReview(to directory: URL) throws {
    final class TileBody: NSView {
        override func draw(_ dirtyRect: NSRect) {
            SurfaceToken.tileBody.color.nsColor(in: self).setFill()
            bounds.fill()
        }
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let checkout = URL(fileURLWithPath: "/Users/qa/Projects/array", isDirectory: true)
    let location = AgentLocationSnapshot(
        home: AgentHome(projectId: nil, projectRoot: checkout, checkoutRoot: checkout),
        whereDirectory: checkout)
    let identity = AgentAccountIdentity(
        harness: .claudeCode, email: "personal@example.com", plan: "max", observedAt: now)
    let cases: [(String, Double, Double)] = [("normal", 0.16, 0.07), ("near-limit", 0.94, 0.19)]
    for (name, fiveHour, weekly) in cases {
        let quota = AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: [
                AgentQuotaWindow(kind: .fiveHour, utilization: fiveHour, resetsAt: now.addingTimeInterval(8_220)),
                AgentQuotaWindow(kind: .sevenDay, utilization: weekly, resetsAt: now.addingTimeInterval(540_000)),
            ],
            observedAt: now.addingTimeInterval(-60), source: .claudeUsageRequest)
        let context = AgentContextWindowSnapshot(
            usedTokens: 273_000, maxTokens: 1_000_000, observedAt: now,
            source: .providerSessionStats, freshness: .live)
        let presentation = AgentCompactStatusPresentation.present(
            location: location, projectName: "Array",
            activity: AgentCompactActivityInput(phase: .ready, phaseStartedAt: now),
            now: now, contextWindow: context, accountQuota: quota, accountIdentity: identity,
            enabledElements: [.location, .activity, .contextMeter, .quotaFiveHour, .quotaSevenDay])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: 720, height: 330)
            let probe = try UIProbe.render(
                UIProbe.Spec(id: "account-usage.\(name)", size: size, appearance: appearance)
            ) {
                let body = TileBody(frame: NSRect(origin: .zero, size: size))
                let row = AgentCompactStatusRowView(
                    frame: NSRect(x: 12, y: 12, width: size.width - 24,
                                  height: AgentCompactStatusRowView.preferredHeight))
                row.apply(presentation)
                body.addSubview(row)
                row.layoutSubtreeIfNeeded()
                if let account = presentation.account, let pills = row.qaAccountPillsFrame {
                    let card = AgentAccountUsageCardView(frame: .zero)
                    card.apply(account.card)
                    card.layoutSubtreeIfNeeded()
                    let cardSize = card.intrinsicContentSize
                    let anchor = row.convert(pills, to: body)
                    card.frame = NSRect(
                        x: max(12, min(anchor.midX - cardSize.width / 2, size.width - cardSize.width - 12)),
                        y: anchor.maxY + CGFloat(Space.m), width: cardSize.width, height: cardSize.height)
                    body.addSubview(card)
                }
                return body
            }
            let label = appearance == .darkAqua ? "dark" : "light"
            try probe.hostRep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("account-usage-\(name)-\(label).png"))
        }
    }
}

/// .plans/101 — ONE account per CLI for the whole app, switched in Settings,
/// through the PRODUCTION Claude and Codex runners against the reactive fakes
/// on PATH:
///
/// - a switch leaves a running turn on the process and login it started with,
///   and stops an idle pooled session at once;
/// - when the running turn ends its process is retired, not pooled;
/// - every agent's next turn is a new process with the new account's
///   `CLAUDE_CONFIG_DIR` (or `CODEX_HOME`), resuming its own session id;
/// - after the boundary no two agents of a CLI run on different accounts;
/// - Settings, built by the app's own builder, shows the switch in progress;
/// - the choice survives a relaunch; a signed-out account is refused.
@MainActor
func runAgentAccountSwitchChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }
    func sessionArg(_ argv: [String]) -> (flag: String, id: String)? {
        for flag in ["--resume", "--session-id"] {
            if let i = argv.firstIndex(of: flag), i + 1 < argv.count { return (flag, argv[i + 1]) }
        }
        return nil
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("account-switch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let claudeBin = root.appendingPathComponent("claude-bin", isDirectory: true)
    let codexBin = root.appendingPathComponent("codex-bin", isDirectory: true)
    _ = try AgentSteeringQAFakes.install(.claude, in: claudeBin)
    _ = try AgentSteeringQAFakes.install(.codex, in: codexBin)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(claudeBin.path):\(codexBin.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }
    let personalClaude = root.appendingPathComponent("personal-claude", isDirectory: true)
    let personalCodex = root.appendingPathComponent("personal-codex", isDirectory: true)
    for dir in [personalClaude.appendingPathComponent("projects"), personalCodex.appendingPathComponent("sessions")] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let support = root.appendingPathComponent("support")

    func makeSupervisor() -> AgentSupervisor {
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
        supervisor.personalClaudeDirectory = personalClaude
        supervisor.personalCodexDirectory = personalCodex
        supervisor.accountUsageReader = { _ in nil }
        return supervisor
    }
    let supervisor = makeSupervisor()
    defer { supervisor.stopAll() }
    let work = try supervisor.addAccount(harness: .claudeCode, label: supervisor.nextAccountLabel(for: .claudeCode))
    let codexWork = try supervisor.addAccount(harness: .codex, label: supervisor.nextAccountLabel(for: .codex))
    let personal = AgentAccount.defaultAccount(for: .claudeCode)
    let claudeModel = "anthropic/claude-haiku-4-5-20251001"
    let busy = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: claudeModel, thinking: "low")
    let idle = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: claudeModel, thinking: "low")
    let codexAgent = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .codex,
                                      model: "openai-codex/gpt-5.6-sol", thinking: "low")
    func dirs() -> [String] { AgentSteeringQAFakes.configDirectories(in: claudeBin) }
    func spawns() -> Int { AgentSteeringQAFakes.spawnCount(in: claudeBin) }

    // The idle agent has a pooled Personal session; the busy one is mid-turn.
    try require(supervisor.send("PLAIN idle first", to: idle), "idle turn refused: \(supervisor.sendRefusal(for: idle) ?? "?")")
    try await waitFor("the idle agent's first turn must finish and pool") {
        !supervisor.isRunning(idle) && supervisor.qaHasIdleSession(idle)
    }
    let idleSession = sessionArg(AgentSteeringQAFakes.argv(in: claudeBin))
    try require(supervisor.send("PLAIN busy first", to: busy), "busy turn refused")
    try await waitFor("the busy turn must be running") { supervisor.isRunning(busy) && spawns() == 2 }
    let busySession = sessionArg(AgentSteeringQAFakes.argv(in: claudeBin))
    try require(dirs() == ["<default>", "<default>"], "both first turns run on Personal, got \(dirs())")

    let outcome = supervisor.switchAccount(to: work.id)
    try require(outcome == .switched(finishingTurns: 1), "the switch must wait for the one running turn, got \(outcome)")
    try require(!supervisor.qaHasIdleSession(idle), "an idle Personal session must stop at once")
    try require(supervisor.account(forAgent: busy)?.id == personal.id && supervisor.account(forAgent: idle)?.id == work.id,
                "mid-turn the busy agent still spends Personal and the idle one is on Work")
    let rows = AgentAccountSwitchSettingsProbe.rows(supervisor)
    try require(rows.first(where: { $0.id == work.id })?.switchingDetail == "1 agent finishes its turn on Personal, then moves here"
                    && rows.first(where: { $0.id == personal.id })?.isActive == true,
                "Settings must show Work switching while Personal finishes a turn, got \(rows)")
    try await waitFor("the busy turn must finish on its own process") { !supervisor.isRunning(busy) }
    try require(spawns() == 2 && !supervisor.qaHasIdleSession(busy),
                "the running turn finishes on the process it started with, then retires instead of pooling (spawns \(spawns()))")

    // Next turns: both agents on Work, each resuming its own conversation.
    try require(supervisor.send("PLAIN busy second", to: busy), "busy second turn refused")
    try await waitFor("busy second turn") { spawns() == 3 && !supervisor.isRunning(busy) }
    let busyNext = sessionArg(AgentSteeringQAFakes.argv(in: claudeBin))
    try require(supervisor.send("PLAIN idle second", to: idle), "idle second turn refused")
    try await waitFor("idle second turn") { spawns() == 4 && !supervisor.isRunning(idle) }
    let idleNext = sessionArg(AgentSteeringQAFakes.argv(in: claudeBin))
    try require(Array(dirs().suffix(2)) == [work.configDirectory!, work.configDirectory!],
                "every next turn must sign in as Work, got \(dirs())")
    try require(busyNext?.flag == "--resume" && busyNext?.id == busySession?.id
                    && idleNext?.flag == "--resume" && idleNext?.id == idleSession?.id,
                "each agent resumes its own session on Work: \(String(describing: busySession)) → \(String(describing: busyNext)), \(String(describing: idleSession)) → \(String(describing: idleNext))")
    try require(Set([busy, idle].compactMap { supervisor.account(forAgent: $0)?.id }) == [work.id],
                "after the boundary no two Claude agents are on different accounts")

    // Codex moves the same way, by CODEX_HOME.
    try require(supervisor.send("PLAIN codex first", to: codexAgent), "codex turn refused: \(supervisor.sendRefusal(for: codexAgent) ?? "?")")
    try await waitFor("codex first turn") { !supervisor.isRunning(codexAgent) && !AgentSteeringQAFakes.codexHomes(in: codexBin).isEmpty }
    try require(supervisor.switchAccount(to: codexWork.id) == .switched(finishingTurns: 0), "an idle codex switch moves at once")
    try require(supervisor.send("PLAIN codex second", to: codexAgent), "codex second turn refused")
    try await waitFor("codex second turn on Work: \(AgentSteeringQAFakes.codexHomes(in: codexBin))") {
        !supervisor.isRunning(codexAgent) && AgentSteeringQAFakes.codexHomes(in: codexBin).last == codexWork.configDirectory
    }
    try require(AgentSteeringQAFakes.codexHomes(in: codexBin).first == "<default>",
                "codex started on its own home before the switch")
    try require(supervisor.activeAccount(for: .claudeCode).id == work.id,
                "switching Codex must not move Claude")

    // Settings as the app builds it: the rows render, and its Switch action
    // is the switch.
    let settingsDelegate = AppDelegate()
    settingsDelegate.agentSupervisor = supervisor
    let settingsSuite = "account-switch-render-\(UUID().uuidString)"
    settingsDelegate.qaSettingsDefaults = UserDefaults(suiteName: settingsSuite)
    settingsDelegate.qaStubsCompanionSettingsView = true
    defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }
    let settingsModel = settingsDelegate.qaMakeSettingsModal(paneID: "agents").model
    let fixture = SettingsFixtureWindow(model: settingsModel, size: NSSize(width: 1_100, height: 1_400))
    defer { fixture.tearDown() }
    fixture.show(paneID: "agents")
    fixture.settle(0.3)
    try require(settingsModel.renderedTexts["account.\(work.id)"]?.hasPrefix("Work: In use") == true
                    && settingsModel.renderedTexts["account.\(personal.id)"]?.hasPrefix("Personal: Saved") == true,
                "Settings must render Work in use and Personal saved, got \(settingsModel.renderedTexts.filter { $0.key.hasPrefix("account.") })")
    settingsModel.onSwitchAccount?(personal.id)
    fixture.settle(0.2)
    try require(supervisor.activeAccount(for: .claudeCode).id == personal.id
                    && settingsModel.renderedTexts["account.\(personal.id)"]?.hasPrefix("Personal: In use") == true,
                "Settings' Switch must switch the CLI and redraw, got \(String(describing: settingsModel.renderedTexts["account.\(personal.id)"]))")
    try require(supervisor.switchAccount(to: work.id) == .switched(finishingTurns: 0), "back to Work")

    // Persisted, and a signed-out account is refused.
    let relaunched = makeSupervisor()
    try require(relaunched.activeAccount(for: .claudeCode).id == work.id
                    && relaunched.activeAccount(for: .codex).id == codexWork.id,
                "the account in use must survive a relaunch")
    supervisor.applyAccountUsageReading(.init(identity: nil, quota: nil, signedOut: true), accountId: personal.id)
    try require(supervisor.switchAccount(to: personal.id) == .refused("Personal is not signed in. Sign in first."),
                "switching to a signed-out account must be refused")

    print("AgentAccountSwitchChecks passed: a switch leaves a running turn on its process and login, stops an idle pooled session, retires the finishing one at the boundary, then every agent's next turn is a new process with the new CLAUDE_CONFIG_DIR resuming its own session; no two Claude agents run on different accounts after the boundary; Settings shows the switch in progress; Codex moves by CODEX_HOME without moving Claude; the choice survives a relaunch and a signed-out account is refused")
}

/// Settings rows as the app's Settings builder wires them.
@MainActor
enum AgentAccountSwitchSettingsProbe {
    static func rows(_ supervisor: AgentSupervisor) -> [SettingsAccountRow] {
        let delegate = AppDelegate()
        delegate.agentSupervisor = supervisor
        let suite = "account-switch-settings-\(UUID().uuidString)"
        delegate.qaSettingsDefaults = UserDefaults(suiteName: suite)
        delegate.qaStubsCompanionSettingsView = true
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return delegate.qaMakeSettingsModal(paneID: "agents").model.accountRows?() ?? []
    }
}
