import Foundation

/// Builds tmux-backed launch profiles for terminal tile persistence.
///
/// P1 is pure Core: command construction, stable tile-keyed session names,
/// kill-session argv construction, and persisted config/detection helpers.
public enum TmuxSession {
    public enum InvocationMode: Sendable {
        case interactive
        case control
    }

    public struct Invocation: Equatable, Sendable {
        public let command: String
        public let arguments: [String]

        public init(command: String, arguments: [String]) {
            self.command = command
            self.arguments = arguments
        }
    }

    public enum ReachError: Error, Equatable, CustomStringConvertible {
        case tunnelUnsupported(relayHost: String)

        public var description: String {
            switch self {
            case let .tunnelUnsupported(relayHost):
                return "tmux tunnel transport is unsupported (relay: \(relayHost))"
            }
        }
    }

    public static func sessionName(tileId: UUID) -> String {
        "array-\(tileId.uuidString)"
    }

    public static func viewSessionName(tileId: UUID) -> String {
        "array-view-\(tileId.uuidString)"
    }

    public static func wrap(
        profile: LaunchProfile,
        tileId: UUID,
        tmuxPath: String,
        reach: RemoteReach = .localhost,
        defaults: UserDefaults = .standard
    ) -> LaunchProfile {
        let name = sessionName(tileId: tileId)
        var arguments = ["new-session", "-A", "-s", name, "-c", profile.cwd]
        if shouldPassInnerCommand(profile) {
            arguments.append(profile.command)
            arguments.append(contentsOf: profile.arguments)
        }
        let resolved: Invocation
        do {
            resolved = try invocation(
                tmuxPath: tmuxPath,
                arguments: arguments,
                reach: reach,
                defaults: defaults,
                mode: .interactive
            )
        } catch {
            // `wrap` predates throwing launch-profile construction. Preserve
            // its explicit unsupported-tunnel trap while all new shared-view
            // and process-control paths surface a typed error.
            fatalError(String(describing: error))
        }
        return LaunchProfile(
            command: resolved.command,
            arguments: resolved.arguments,
            cwd: profile.cwd,
            title: profile.title
        )
    }

    /// Builds the one production launch used by every tile whose window lives
    /// in a shared project/workspace session. The view owns selected-window
    /// state; the base session continues to own the actual windows.
    public static func groupedViewProfile(
        profile: LaunchProfile,
        tileId: UUID,
        baseSessionName: String,
        windowTarget: String,
        tmuxPath: String,
        reach: RemoteReach = .localhost,
        defaults: UserDefaults = .standard
    ) throws -> LaunchProfile {
        let arguments = [
            "new-session", "-t", baseSessionName,
            "-s", viewSessionName(tileId: tileId),
            "-A",
            ";",
            "select-window", "-t", windowTarget
        ]
        let invocation = try invocation(
            tmuxPath: tmuxPath,
            arguments: arguments,
            reach: reach,
            defaults: defaults,
            mode: .interactive
        )
        return LaunchProfile(
            command: invocation.command,
            arguments: invocation.arguments,
            cwd: profile.cwd,
            title: profile.title
        )
    }

    /// Resolves a tmux argv onto its daemon owner. Ghostty launches request an
    /// interactive SSH pty; background control/query operations explicitly do
    /// not. Both paths share host, port, config and shell-quoting construction.
    public static func invocation(
        tmuxPath: String,
        arguments: [String],
        reach: RemoteReach,
        defaults: UserDefaults = .standard,
        mode: InvocationMode
    ) throws -> Invocation {
        switch reach {
        case .localhost:
            return Invocation(command: tmuxPath, arguments: arguments)
        case let .sshForward(target), let .tailscale(target):
            let command = tmuxPath.isEmpty ? "tmux" : tmuxPath
            let remoteInvocation = ([command] + arguments)
                .map(shellEscape(_:))
                .joined(separator: " ")
            var sshArgs = sshBaseArgs(target: target, defaults: defaults)
            sshArgs.append(mode == .interactive ? "-t" : "-T")
            let host = [target.username, target.hostname]
                .compactMap { $0 }
                .joined(separator: "@")
            sshArgs.append(contentsOf: [host, remoteInvocation])
            return Invocation(command: "/usr/bin/ssh", arguments: sshArgs)
        case let .tunnel(relayHost):
            throw ReachError.tunnelUnsupported(relayHost: relayHost)
        }
    }

    public static func killSessionCommand(tileId: UUID, tmuxPath: String) -> (command: String, arguments: [String]) {
        (command: tmuxPath, arguments: ["kill-session", "-t", sessionName(tileId: tileId)])
    }

    public static func killViewSessionCommand(tileId: UUID, tmuxPath: String) -> (command: String, arguments: [String]) {
        (command: tmuxPath, arguments: ["kill-session", "-t", viewSessionName(tileId: tileId)])
    }

    public static func groupedViewSessionArguments(viewSessionName: String, projectSessionName: String) -> [String] {
        ["new-session", "-d", "-t", projectSessionName, "-s", viewSessionName, "-A"]
    }

    public static func selectWindowArguments(viewSessionName: String, windowTarget: String) -> [String] {
        ["select-window", "-t", "\(viewSessionName):\(windowTarget)"]
    }

    public static func activeWindowTargetArguments(viewSessionName: String) -> [String] {
        ["display-message", "-p", "-t", viewSessionName, "#{window_id}"]
    }

    public static func killWindowCommand(target: String, tmuxPath: String) -> (command: String, arguments: [String]) {
        (command: tmuxPath, arguments: ["kill-window", "-t", target])
    }

    public static func attachWindowProfile(paneTarget: String, cwd: String, tmuxPath: String) -> LaunchProfile {
        LaunchProfile(
            command: tmuxPath,
            arguments: ["attach-session", "-t", paneTarget],
            cwd: cwd,
            title: "Terminal"
        )
    }

    public static func newWindowArguments(projectSessionName: String, cwd: String, innerCommand: [String]?) -> [String] {
        var arguments = ["new-window", "-d", "-t", projectSessionName, "-c", cwd, "-P", "-F", "#{pane_id}"]
        if let innerCommand, !innerCommand.isEmpty {
            arguments.append(contentsOf: innerCommand)
        }
        return arguments
    }

    public static func isValidPaneId(_ value: String) -> Bool {
        value.hasPrefix("%") && !value.dropFirst().isEmpty && value.dropFirst().allSatisfy(\.isNumber)
    }

    public static func isValidWindowId(_ value: String) -> Bool {
        value.hasPrefix("@") && !value.dropFirst().isEmpty && value.dropFirst().allSatisfy(\.isNumber)
    }

    public static func i2Verdict(intendedA: String, intendedB: String, observedA: String, observedB: String) -> I2Verdict {
        if observedA != observedB {
            return .distinct
        }
        if intendedA == intendedB {
            return .deliberateSharedView
        }
        return .accidentalMirror
    }

    /// Project-scoped session name (phase 1+). `ZoneRuntimeController` is the
    /// only authoritative caller — see `ZoneRuntimeController.projectSessionName()`.
    public static func projectSessionName(projectId: UUID) -> String {
        "array-proj-\(projectId.uuidString)"
    }

    /// Ambient/workspace-scoped session name (phase 1 fallback promotion).
    public static func ambientSessionName(workspaceId: UUID) -> String {
        "array-ws-\(workspaceId.uuidString)"
    }

    /// Project-scoped kill-session argv — mirrors `killSessionCommand(tileId:tmuxPath:)`.
    /// Reserved for explicit project deletion only; never call on a mere release
    /// (see `ZoneRuntimeController.close()` LIFECYCLE POLICY, D16).
    public static func killProjectSessionCommand(projectId: UUID, tmuxPath: String) -> (command: String, arguments: [String]) {
        (command: tmuxPath, arguments: ["kill-session", "-t", projectSessionName(projectId: projectId)])
    }

    private static func sshBaseArgs(target: SSHTarget, defaults: UserDefaults) -> [String] {
        var args = [
            "-o", "ConnectTimeout=\(RemoteReachConfig.connectTimeout(defaults: defaults))",
            "-o", "ServerAliveInterval=\(RemoteReachConfig.serverAliveInterval(defaults: defaults))",
            "-o", "ServerAliveCountMax=\(RemoteReachConfig.serverAliveCountMax(defaults: defaults))",
            "-o", "BatchMode=no"
        ]
        if let configFile = RemoteReachConfig.configFile(defaults: defaults) {
            args.append(contentsOf: ["-F", configFile])
        }
        if let port = target.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        return args
    }

    private static func shellEscape(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shouldPassInnerCommand(_ profile: LaunchProfile) -> Bool {
        !(profile.title == "Shell" && profile.arguments.isEmpty)
    }
}

public enum I2Verdict: String, Codable, Equatable, Sendable, CustomStringConvertible {
    case distinct
    case deliberateSharedView
    case accidentalMirror

    public var description: String { rawValue }
}

public enum TerminalSessionTarget: Sendable, Equatable {
    case project(projectId: UUID)
    case ambient(workspaceId: UUID)
}

public enum TmuxLocator {
    private static let fallbackPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    public static func resolve(defaults: UserDefaults = .standard) -> String? {
        let configuredPath = TmuxPersistenceConfig.path(defaults: defaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            return configuredPath
        }

        for directory in pathDirectories() {
            let candidate = (directory as NSString).appendingPathComponent("tmux")
            if isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        for candidate in fallbackPaths where isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private static func pathDirectories() -> [String] {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// UserDefaults-backed toggle and optional path override for tmux persistence.
/// Mirrors the surrounding Core config style used by SessionResumeConfig and
/// ResizeHUDConfig.
public enum TmuxPersistenceConfig {
    public static let enabledKey = "continuum.terminal.tmux.enabled"
    public static let defaultEnabled = true

    public static let pathKey = "continuum.terminal.tmux.path"
    public static let defaultPath = ""

    public static let ambientPerWorkspaceKey = "continuum.terminal.tmux.ambientPerWorkspace"
    public static let ambientPerWorkspaceDefault = false

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
    }

    public static func path(defaults: UserDefaults = .standard) -> String {
        defaults.object(forKey: pathKey) != nil
            ? defaults.string(forKey: pathKey) ?? defaultPath
            : defaultPath
    }

    public static func ambientPerWorkspaceEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: ambientPerWorkspaceKey) != nil
            ? defaults.bool(forKey: ambientPerWorkspaceKey)
            : ambientPerWorkspaceDefault
    }
}
