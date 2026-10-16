import Foundation

/// What one update click ended as. Success is only ever reported from a fresh
/// `--version` read after the command exits, never from the exit code alone.
public enum AgentCLIUpdateResult: Equatable, Sendable {
    case updated(from: String?, to: String, output: String)
    /// The command succeeded and the version did not move.
    case unchanged(version: String, output: String)
    case failed(exitCode: Int32, output: String)
    case timedOut(output: String)
    /// The command exited 0 but the CLI no longer answers `--version`.
    case unverified(output: String)
    /// The installation changed between the check and the run; nothing ran.
    case aborted(reason: String)
    /// Array declined to run it (no command, or a turn in flight); nothing ran.
    case refused(reason: String)

    public var output: String {
        switch self {
        case let .updated(_, _, output), let .unchanged(_, output), let .failed(_, output),
             let .timedOut(output), let .unverified(output): return output
        case .aborted, .refused: return ""
        }
    }

    public var summary: String {
        switch self {
        case let .updated(_, to, _): return "Updated to \(to)"
        case let .unchanged(version, _): return "Already up to date (\(version))"
        case let .failed(code, _): return "Failed (exit \(code))"
        case .timedOut: return "Timed out after 5 minutes"
        case .unverified: return "Finished, but the CLI no longer reports a version"
        case let .aborted(reason): return "Not run: \(reason)"
        case let .refused(reason): return reason
        }
    }

    public var succeeded: Bool {
        if case .updated = self { return true }
        return false
    }
}

/// How the runner reaches the sessions of one harness. Implemented by the app
/// over `AgentSupervisor`; a fake in the witness.
public struct AgentCLISessionGate: Sendable {
    /// True while any agent of `harness` has a turn in flight.
    public var hasRunningTurn: @Sendable (AgentHarness) -> Bool
    /// Stop that harness's IDLE persistent sessions so the next turn starts the
    /// new binary. Running turns are never touched. Returns how many stopped.
    public var stopIdleSessions: @Sendable (AgentHarness) -> Int
    /// Tell agents still running the old binary that a restart picks up `version`.
    public var noteRunningSessionsNeedRestart: @Sendable (AgentHarness, String) -> Void

    public init(hasRunningTurn: @escaping @Sendable (AgentHarness) -> Bool,
                stopIdleSessions: @escaping @Sendable (AgentHarness) -> Int,
                noteRunningSessionsNeedRestart: @escaping @Sendable (AgentHarness, String) -> Void) {
        self.hasRunningTurn = hasRunningTurn
        self.stopIdleSessions = stopIdleSessions
        self.noteRunningSessionsNeedRestart = noteRunningSessionsNeedRestart
    }

    public static let inert = AgentCLISessionGate(
        hasRunningTurn: { _ in false }, stopIdleSessions: { _ in 0 }, noteRunningSessionsNeedRestart: { _, _ in })
}

#if os(macOS)
/// Runs one plan's update command, only ever on a click. Blocking: call it
/// off the main thread.
public final class AgentCLIUpdateRunner: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 5 * 60

    /// Re-decides the plan immediately before running (production: resolve the
    /// binary again and classify it again).
    private let resolvePlan: @Sendable (AgentHarness) -> AgentCLIUpdatePlan?
    private let readVersion: @Sendable (AgentCLIUpdatePlan) -> String?
    private let environment: @Sendable (AgentCLIUpdatePlan) -> [String: String]
    private let timeout: TimeInterval
    private let outputLimit: Int

    public init(
        resolvePlan: @escaping @Sendable (AgentHarness) -> AgentCLIUpdatePlan?,
        readVersion: @escaping @Sendable (AgentCLIUpdatePlan) -> String? = { plan in
            AgentCLIProcess.readVersion(executable: plan.resolvedPath)
        },
        environment: @escaping @Sendable (AgentCLIUpdatePlan) -> [String: String] = { plan in
            AgentCLIProcess.environment(for: plan.argv?.first ?? plan.resolvedPath)
        },
        timeout: TimeInterval = AgentCLIUpdateRunner.defaultTimeout,
        outputLimit: Int = 16 * 1024
    ) {
        self.resolvePlan = resolvePlan
        self.readVersion = readVersion
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    // One lock per installer (`plan.lockKey`), process-wide.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var installerLocks: [String: NSLock] = [:]
    private static func lock(for key: String) -> NSLock {
        registryLock.withLock {
            if let lock = installerLocks[key] { return lock }
            let lock = NSLock()
            installerLocks[key] = lock
            return lock
        }
    }

    public func run(
        _ plan: AgentCLIUpdatePlan,
        gate: AgentCLISessionGate,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) -> AgentCLIUpdateResult {
        guard let argv = plan.argv else {
            return .refused(reason: plan.guidance ?? "Array can't update this install.")
        }
        let installerLock = Self.lock(for: plan.lockKey)
        installerLock.lock()
        defer { installerLock.unlock() }

        // The binary Array checked must still be the binary it would update.
        guard let fresh = resolvePlan(plan.harness) else {
            return .aborted(reason: "\(plan.harness.rawValue) is no longer installed at \(plan.resolvedPath)")
        }
        guard fresh == plan else {
            return .aborted(reason: "the \(plan.harness.rawValue) install changed since Array checked it; check again")
        }
        // npm removes the old package directory out from under a live process.
        if plan.replacesRunningBinary && gate.hasRunningTurn(plan.harness) {
            return .refused(reason: "Finish or stop the running \(plan.harness.rawValue) turns first: npm replaces the files they are running from.")
        }

        let before = readVersion(plan)
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-cli-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let outcome = AgentCLIProcess.run(
            argv: argv, environment: environment(plan), currentDirectory: workDirectory,
            timeout: timeout, outputLimit: outputLimit, onOutput: onOutput)
        if outcome.timedOut { return .timedOut(output: outcome.output) }
        if let launchError = outcome.launchError {
            return .failed(exitCode: -1, output: launchError)
        }
        let code = outcome.exitCode ?? -1
        guard code == 0 else { return .failed(exitCode: code, output: outcome.output) }

        guard let after = readVersion(plan) else { return .unverified(output: outcome.output) }
        guard after != before else { return .unchanged(version: after, output: outcome.output) }
        _ = gate.stopIdleSessions(plan.harness)
        gate.noteRunningSessionsNeedRestart(plan.harness, after)
        return .updated(from: before, to: after, output: outcome.output)
    }
}
#endif
