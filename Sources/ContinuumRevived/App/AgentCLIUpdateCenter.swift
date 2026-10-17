import AppKit
import ContinuumRevivedCore
import Foundation
import Observation
import UserNotifications

/// In-app maintenance for the agent CLIs (Claude Code, Codex, Pi), after T3 Code.
///
/// Per CLI it knows the binary Array spawns, who installed it and the one
/// command that may update it (`AgentCLIUpdatePlan`), the installed version,
/// the newest published one, and the state of an update the user started.
/// Settings › Agents › Agent CLIs draws it; ⌘K offers "Update <CLI>" from it.
///
/// **Inert unless enabled.** `shared` does nothing — no subprocess, no
/// network — until the real app's startup calls `enableLive()`, which itself
/// refuses in every QA shape (`livePermitted`). Checks build their own center
/// with injected dependencies (hazard 6).
@MainActor
@Observable
final class AgentCLIUpdateCenter {
    /// Settings › Agents › "Check for agent CLI updates". On by default.
    static let checksEnabledKey = AgentCLIUpdateConfig.checksEnabledKey
    static let checksEnabledDefault = AgentCLIUpdateConfig.checksEnabledDefault
    static let lastSeenVersionKeyPrefix = "continuum.agents.cliVersion."
    static let checkInterval: TimeInterval = 60 * 60
    /// The first check waits this long after launch, off the startup path.
    static let launchDelay: TimeInterval = 30

    struct Dependencies {
        /// The absolute binary Array spawns for a harness, or nil (not found).
        var resolvedPath: @Sendable (AgentHarness) -> String?
        var fileSystem: AgentCLIFileSystem
        var readVersion: @Sendable (AgentCLIUpdatePlan) -> String?
        var fetcher: AgentCLILatestVersionFetching
        var makeRunner: (@escaping @Sendable (AgentHarness) -> AgentCLIUpdatePlan?) -> AgentCLIUpdateRunner
        /// For the vendors' opt-out variables.
        var environment: [String: String]
        var testedVersions: [AgentHarness: String]
        var deliverNotice: @MainActor (String) -> Void
        /// Re-probe readiness (signed in / ready) after an update.
        var refreshReadiness: @MainActor () -> Void

        static func live() -> Dependencies {
            Dependencies(
                resolvedPath: { harness in
                    let command: PiAgentRunner.ResolvedCommand
                    switch harness {
                    case .claudeCode: command = ClaudeAgentRunner.liveResolvedCommand()
                    case .codex: command = CodexAgentRunner.liveResolvedCommand()
                    case .pi: command = PiAgentRunner.liveResolvedCommand()
                    }
                    // `/usr/bin/env <name>` is a fallback, not an install anyone owns.
                    return command.prefixArgs.isEmpty ? command.executable : nil
                },
                fileSystem: .live,
                readVersion: { AgentCLIProcess.readVersion(executable: $0.resolvedPath) },
                fetcher: AgentCLILiveLatestVersionFetcher(),
                makeRunner: { AgentCLIUpdateRunner(resolvePlan: $0) },
                environment: ProcessInfo.processInfo.environment,
                testedVersions: AgentCLITestedVersions.bundled(),
                deliverNotice: { AgentCLIVersionNotice.deliver($0) },
                refreshReadiness: { AgentModelCatalog.shared.requestRefresh(minimumInterval: 0) })
        }
    }

    enum Phase: Equatable {
        case idle
        case running(log: String)
        case finished(AgentCLIUpdateResult)
    }

    struct Status: Equatable {
        var plan: AgentCLIUpdatePlan?
        var installed: String?
        var latest: String?
        var phase: Phase = .idle
        /// The latest check was skipped by the CLI's own opt-out variable.
        var optedOut = false

        var isRunning: Bool { if case .running = phase { return true }; return false }
        var hasNewer: Bool { AgentCLIVersion.isNewer(latest, than: installed) }
        /// "Update" is offered: a newer version, a command Array may run, idle.
        var canUpdate: Bool { hasNewer && plan?.isRunnable == true && !isRunning }
    }

    static let shared = AgentCLIUpdateCenter(dependencies: .live(), defaults: .standard, active: false)

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let cache: AgentCLILatestVersionCache
    @ObservationIgnored private lazy var runner: AgentCLIUpdateRunner = {
        let resolvedPath = dependencies.resolvedPath
        let fileSystem = dependencies.fileSystem
        return dependencies.makeRunner { harness in
            AgentCLIInstallOwnerResolver.plan(harness: harness, resolvedPath: resolvedPath(harness), fileSystem: fileSystem)
        }
    }()
    /// How the runner reaches the agents. The app wires it to the supervisor.
    @ObservationIgnored var sessionGate: AgentCLISessionGate = .inert
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshInFlight = false

    private(set) var statuses: [AgentHarness: Status] = [:]
    /// False for `shared` until `enableLive()`; true for an injected center.
    private(set) var isActive: Bool
    /// QA: how many latest-version checks have actually started.
    @ObservationIgnored private(set) var latestCheckCount = 0

    init(dependencies: Dependencies, defaults: UserDefaults, active: Bool = true) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.isActive = active
        self.cache = AgentCLILatestVersionCache(fetcher: dependencies.fetcher)
    }

    func status(_ harness: AgentHarness) -> Status { statuses[harness] ?? Status() }

    var checksEnabled: Bool {
        defaults.object(forKey: Self.checksEnabledKey) as? Bool ?? Self.checksEnabledDefault
    }

    /// The CLIs "Update" can run for right now, in display order.
    var updatableHarnesses: [AgentHarness] {
        AgentHarness.allCases.filter { status($0).canUpdate }
    }

    // MARK: - Live gating

    /// Only a real `.app` launch, never a check, a smoke test, a QA flow or an
    /// isolated store — the same shapes that keep the app updater inert.
    nonisolated static func livePermitted(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        for key in ["CONTINUUM_APP_SUPPORT", "CONTINUUM_SMOKE_TEST", "CONTINUUM_QA_FLOW", "CONTINUUM_COMPONENT_SNAPSHOT"]
            where environment[key] != nil { return false }
        return !arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// Called once from the app's startup path. The first check runs
    /// `launchDelay` after launch, then at most hourly.
    func enableLive() {
        guard !isActive, Self.livePermitted() else { return }
        isActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh() }
                }
            }
        }
    }

    // MARK: - Checking

    /// Re-reads each CLI's install and version, posts the version-change notice,
    /// and — when checks are on, or `force` (⌘K "Check for CLI Updates") — looks
    /// up the newest version. Never overlaps itself.
    func refresh(force: Bool = false) async {
        guard isActive, !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let resolvedPath = dependencies.resolvedPath
        let fileSystem = dependencies.fileSystem
        let readVersion = dependencies.readVersion
        let probes: [(AgentHarness, AgentCLIUpdatePlan?, String?)] = await Task.detached(priority: .utility) {
            AgentHarness.allCases.map { harness in
                let plan = AgentCLIInstallOwnerResolver.plan(harness: harness, resolvedPath: resolvedPath(harness), fileSystem: fileSystem)
                return (harness, plan, plan.flatMap(readVersion))
            }
        }.value
        let lookLatest = force || checksEnabled
        for (harness, plan, installed) in probes {
            var status = self.status(harness)
            // Mid-update the runner owns the row; its result re-reads afterwards.
            guard !status.isRunning else { continue }
            status.plan = plan
            status.installed = installed
            if plan == nil { status.latest = nil }
            statuses[harness] = status
            if let installed { noteObservedVersion(installed, for: harness) }
        }
        guard lookLatest else { return }
        for (harness, plan, _) in probes {
            guard let plan else { continue }
            if AgentCLIUpdateOptOut.isOptedOut(harness, environment: dependencies.environment) {
                statuses[harness]?.optedOut = true
                continue
            }
            latestCheckCount += 1
            let latest = await cache.latest(for: plan.latestSource, force: force)
            statuses[harness]?.optedOut = false
            if let latest { statuses[harness]?.latest = latest }
        }
    }

    /// The version-change notice: one per change, persisted per harness, so a
    /// claude that updated itself overnight is announced once on the next probe.
    /// The first sighting only records.
    private func noteObservedVersion(_ version: String, for harness: AgentHarness) {
        let key = Self.lastSeenVersionKeyPrefix + harness.rawValue
        let previous = defaults.string(forKey: key)
        defaults.set(version, forKey: key)
        guard let previous, previous != version else { return }
        dependencies.deliverNotice(Self.noticeText(harness: harness, version: version,
                                                   tested: dependencies.testedVersions[harness]))
    }

    static func noticeText(harness: AgentHarness, version: String, tested: String?) -> String {
        "\(harness.rawValue) updated to \(version)" + (tested.map { " · tested with \($0)" } ?? "")
    }

    // MARK: - Updating

    /// The Update button and ⌘K "Update <CLI>". Runs only what `canUpdate` offered.
    func update(_ harness: AgentHarness) {
        let current = status(harness)
        guard isActive, current.canUpdate, let plan = current.plan else { return }
        statuses[harness]?.phase = .running(log: "")
        let runner = self.runner
        let gate = sessionGate
        Task.detached(priority: .userInitiated) {
            let result = runner.run(plan, gate: gate) { tail in
                Task { @MainActor in
                    guard self.status(harness).isRunning else { return }
                    self.statuses[harness]?.phase = .running(log: tail)
                }
            }
            await self.finish(harness, result: result)
        }
    }

    private func finish(_ harness: AgentHarness, result: AgentCLIUpdateResult) async {
        statuses[harness]?.phase = .finished(result)
        if case let .updated(_, to, _) = result {
            statuses[harness]?.installed = to
            // Array made this change, so it is not news for the change notice.
            defaults.set(to, forKey: Self.lastSeenVersionKeyPrefix + harness.rawValue)
        }
        if case let .unchanged(version, _) = result { statuses[harness]?.installed = version }
        dependencies.refreshReadiness()
    }
}

/// The "Claude Code updated to X" banner. Advisory only. Delivered through
/// UserNotifications, which needs a real app bundle, so checks and bare binaries
/// never reach the center; `qaSink` receives it instead.
@MainActor
enum AgentCLIVersionNotice {
    static var qaSink: ((String) -> Void)?

    static func deliver(_ text: String) {
        if let qaSink { qaSink(text); return }
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = text
            let request = UNNotificationRequest(identifier: "array.agent-cli-updated.\(UUID().uuidString)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { fputs("Agent CLI update notice failed: \(error)\n", stderr) }
            }
        }
    }
}
