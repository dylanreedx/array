import Foundation

/// Builds tmux-backed launch profiles for terminal tile persistence.
///
/// P1 is pure Core: command construction, stable tile-keyed session names,
/// kill-session argv construction, and persisted config/detection helpers.
public enum TmuxSession {
    public static func sessionName(tileId: UUID) -> String {
        "continuum-\(tileId.uuidString)"
    }

    public static func wrap(profile: LaunchProfile, tileId: UUID, tmuxPath: String) -> LaunchProfile {
        let name = sessionName(tileId: tileId)
        var arguments = ["new-session", "-A", "-s", name, "-c", profile.cwd]
        if shouldPassInnerCommand(profile) {
            arguments.append(profile.command)
            arguments.append(contentsOf: profile.arguments)
        }
        return LaunchProfile(
            command: tmuxPath,
            arguments: arguments,
            cwd: profile.cwd,
            title: profile.title
        )
    }

    public static func killSessionCommand(tileId: UUID, tmuxPath: String) -> (command: String, arguments: [String]) {
        (command: tmuxPath, arguments: ["kill-session", "-t", sessionName(tileId: tileId)])
    }

    private static func shouldPassInnerCommand(_ profile: LaunchProfile) -> Bool {
        !(profile.title == "Shell" && profile.arguments.isEmpty)
    }
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
}
