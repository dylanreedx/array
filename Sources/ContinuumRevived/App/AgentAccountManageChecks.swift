import AppKit
import ContinuumRevivedCore
import Foundation

/// 0.7.37 field report: Dylan's Personal and Work labels named each other's
/// logins, and Settings could not show it or fix it. Both logins share ONE
/// email (a personal Max and a Team organisation), and the rows printed
/// `email · plan`, so the organisation that tells them apart was never shown.
///
/// Drives the real Settings builder with two accounts sharing one email in
/// different organisations, crossed as in the field:
/// - each row names its own organisation and plan, so the two read distinctly;
/// - each row offers Rename and the CLI's own sign-in again;
/// - Rename through Settings relabels, persists, and survives a relaunch;
/// - the relabelled accounts keep their folders: a switch still launches the
///   agent in the folder the login is in, and sign-in again targets it too;
/// - an `accounts.json` written before rename existed still loads.
@MainActor
func runAgentAccountManageChecks() async throws {
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
    final class Logins: @unchecked Sendable {
        private let lock = NSLock()
        private var byAccount: [String: AgentAccountIdentity] = [:]
        func set(_ id: String, _ identity: AgentAccountIdentity) { lock.withLock { byAccount[id] = identity } }
        func read(_ account: AgentAccount) -> AgentAccountUsageProbe.Reading? {
            .init(identity: lock.withLock { byAccount[account.id] }, quota: nil)
        }
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("account-manage-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let claudeBin = root.appendingPathComponent("claude-bin", isDirectory: true)
    _ = try AgentSteeringQAFakes.install(.claude, in: claudeBin)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(claudeBin.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }
    let personalClaude = root.appendingPathComponent("personal-claude", isDirectory: true)
    try fm.createDirectory(at: personalClaude.appendingPathComponent("projects"), withIntermediateDirectories: true)
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let support = root.appendingPathComponent("support", isDirectory: true)

    let logins = Logins()
    func makeSupervisor() -> AgentSupervisor {
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
        supervisor.personalClaudeDirectory = personalClaude
        supervisor.personalCodexDirectory = root.appendingPathComponent("personal-codex", isDirectory: true)
        supervisor.accountUsageReader = { logins.read($0) }
        return supervisor
    }

    let supervisor = makeSupervisor()
    defer { supervisor.stopAll() }
    let personal = AgentAccount.defaultAccount(for: .claudeCode)
    let work = try supervisor.addAccount(harness: .claudeCode, label: "Work")
    let now = Date()
    let team = AgentAccountIdentity(harness: .claudeCode, email: "dylan@example.com",
                                    organizationName: "Bannockburn", organizationId: "org-team", plan: "team", observedAt: now)
    let max = AgentAccountIdentity(harness: .claudeCode, email: "dylan@example.com",
                                   organizationName: "dylan@example.com's Organization", organizationId: "org-personal",
                                   plan: "max", observedAt: now)
    // Crossed, as in the field: "Personal" holds the Team login, "Work" the Max.
    logins.set(personal.id, team)
    logins.set(work.id, max)
    supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 0)
    try await waitFor("both logins must be read") {
        supervisor.accountIdentity(accountId: personal.id) != nil && supervisor.accountIdentity(accountId: work.id) != nil
    }

    // Settings as the app builds it.
    let delegate = AppDelegate()
    delegate.agentSupervisor = supervisor
    let suite = "account-manage-\(UUID().uuidString)"
    delegate.qaSettingsDefaults = UserDefaults(suiteName: suite)
    delegate.qaStubsCompanionSettingsView = true
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let model = delegate.qaMakeSettingsModal(paneID: "agents").model
    let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1_100, height: 1_400))
    defer { fixture.tearDown() }
    fixture.show(paneID: "agents")
    fixture.settle(0.3)
    func rendered(_ id: String) -> String { model.renderedTexts["account.\(id)"] ?? "<none>" }
    func detail(_ id: String) -> String {
        rendered(id).components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }

    try require(rendered(personal.id) == "Personal: In use · dylan@example.com · Bannockburn · Team"
                    && rendered(work.id) == "Work: Saved · dylan@example.com · Personal organization · Max",
                "each row must name its own organisation and plan, got Personal=\(rendered(personal.id)) Work=\(rendered(work.id))")
    try require(detail(personal.id) != detail(work.id),
                "two logins sharing one email must read distinctly, got \(detail(personal.id)) twice")
    for id in [personal.id, work.id] {
        try require(model.renderedTexts["account.manage.\(id)"] == "Rename… Sign in again…",
                    "\(id) must offer Rename and Sign in again, got \(model.renderedTexts["account.manage.\(id)"] ?? "nothing")")
    }

    // Fixing the swap is relabelling, through Settings' own action.
    guard let rename = model.onRenameAccount else { throw Failure(description: "Settings offers no Rename action") }
    rename(personal.id, "Work")
    rename(work.id, "  Personal ")
    rename(work.id, "   ")
    fixture.settle(0.2)
    try require(rendered(personal.id) == "Work: In use · dylan@example.com · Bannockburn · Team"
                    && rendered(work.id) == "Personal: Saved · dylan@example.com · Personal organization · Max",
                "Rename must relabel only (trimmed, blank refused), got \(rendered(personal.id)) / \(rendered(work.id))")

    // Persisted: a relaunch reads the new names on the same folders.
    let relaunched = makeSupervisor()
    defer { relaunched.stopAll() }
    let labels = Dictionary(uniqueKeysWithValues: relaunched.accounts.filter { $0.harness == .claudeCode }.map { ($0.id, $0) })
    try require(labels[personal.id]?.label == "Work" && labels[personal.id]?.configDirectory == nil
                    && labels[work.id]?.label == "Personal" && labels[work.id]?.configDirectory == work.configDirectory,
                "names must survive a relaunch on unchanged folders, got \(labels)")

    // The switch targets the login's folder, whatever it is called.
    let agent = relaunched.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode,
                                 model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
    func dirs() -> [String] { AgentSteeringQAFakes.configDirectories(in: claudeBin) }
    try require(relaunched.switchAccount(to: work.id) == .switched(finishingTurns: 0), "switch to the account now named Personal")
    try require(relaunched.send("PLAIN on max", to: agent), "turn refused: \(relaunched.sendRefusal(for: agent) ?? "?")")
    try await waitFor("the turn on Personal must run in Work's old folder, got \(dirs())") {
        !relaunched.isRunning(agent) && dirs().last == work.configDirectory
    }
    try require(relaunched.switchAccount(to: personal.id) == .switched(finishingTurns: 0), "switch to the account now named Work")
    try require(relaunched.send("PLAIN on team", to: agent), "second turn refused")
    try await waitFor("the turn on Work must run in Claude's default folder, got \(dirs())") {
        !relaunched.isRunning(agent) && dirs().count == 2 && dirs().last == "<default>"
    }
    try require(relaunched.activeAccount(for: .claudeCode).label == "Work",
                "the account in use must carry its new name")

    // Sign in again lands in the same folder as the label now names.
    let signInPersonal = AgentAccountSetup.claudeSignInArguments(for: labels[work.id]!, claudeExecutable: "/bin/claude")
    let signInWork = AgentAccountSetup.claudeSignInArguments(for: labels[personal.id]!, claudeExecutable: "/bin/claude")
    try require(signInPersonal.first == "CLAUDE_CONFIG_DIR=\(work.configDirectory!)"
                    && Array(signInWork.prefix(2)) == ["-u", "CLAUDE_CONFIG_DIR"],
                "sign in again must target each account's own folder, got \(signInPersonal) / \(signInWork)")

    // A file written before accounts could be renamed still loads whole.
    let legacy = root.appendingPathComponent("legacy-support", isDirectory: true)
    try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    let legacyJSON = """
    {"accounts":[{"configDirectory":"/tmp/x/claude","harness":"Claude Code","id":"claude.work","label":"Work"}],
     "active":{"Claude Code":"claude.work"}}
    """
    try Data(legacyJSON.utf8).write(to: legacy.appendingPathComponent("accounts.json"))
    let loaded = AgentAccountStore(applicationSupportDirectory: legacy).load()
    try require(loaded.accounts.map(\.id) == ["claude.work"] && loaded.active["Claude Code"] == "claude.work"
                    && loaded.defaultLabels.isEmpty,
                "an accounts.json from before rename must still load, got \(loaded)")

    if let capture = ProcessInfo.processInfo.environment["CONTINUUM_ACCOUNT_MANAGE_CAPTURE_DIR"], !capture.isEmpty {
        let directory = URL(fileURLWithPath: capture, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let shot = SettingsFixtureWindow(model: model, size: NSSize(width: 1_000, height: 1_400),
                                             appearance: NSAppearance(named: appearance))
            shot.show(paneID: "agents")
            shot.settle(0.4)
            if let view = shot.window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("accounts-\(name).png"))
            }
            shot.tearDown()
        }
    }

    print("AgentAccountManageChecks passed: two Claude accounts sharing one email render distinctly by organisation and plan, each offers Rename and Sign in again, Rename through Settings relabels (trimmed, blank refused) and survives a relaunch on unchanged folders, a switch and a sign-in still target the login's own folder, and an accounts.json from before rename still loads")
}
