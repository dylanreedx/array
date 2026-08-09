import Foundation

/// Where CLI tools actually live when the app is launched from Finder: a GUI
/// launch inherits the thin launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// so `claude`/`codex`/`nvim` installed into user-level dirs are invisible
/// and tiles die with "not found on $PATH" (go-live Phase 4). This is the
/// shared augmentation seam: curated well-known install dirs plus
/// order-preserving PATH merging, pure at every decision point so the matrix
/// can pin it. Same idea as `PiAgentRunner.liveExtraDirs`, generalized beyond
/// pi/node (that seam stays as-is — its behavior is pinned separately).
public enum ToolSearchPath {
    /// Curated install dirs a GUI launch omits, restricted to those that
    /// exist on disk. Order is the precedence order among the extras; the
    /// base PATH always wins overall (see `appending`). The nvm expansion
    /// mirrors `PiAgentRunner.liveExtraDirs`: newest node first.
    public static func wellKnownDirectories(
        home: String,
        directoryExists: (String) -> Bool,
        nodeVersions: (String) -> [String]
    ) -> [String] {
        var candidates = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims"
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        candidates += nodeVersions(nvmRoot).sorted().reversed().map { "\(nvmRoot)/\($0)/bin" }
        return candidates.filter(directoryExists)
    }

    public static func liveWellKnownDirectories() -> [String] {
        wellKnownDirectories(
            home: NSHomeDirectory(),
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            nodeVersions: { root in
                (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            }
        )
    }

    /// `basePath` extended with the extras that aren't already on it. The
    /// user's PATH keeps precedence — extras only widen the search, they
    /// never shadow something the user put first.
    public static func appending(extraDirs: [String], to basePath: String) -> String {
        let baseDirs = ToolDetector.splitPath(basePath)
        var seen = Set(baseDirs)
        var suffix: [String] = []
        for dir in extraDirs where !dir.isEmpty && !seen.contains(dir) {
            seen.insert(dir)
            suffix.append(dir)
        }
        return (baseDirs + suffix).joined(separator: ":")
    }

    /// The upgrade merge once the login-shell PATH is known: the login shell
    /// is the ground truth for dotfile-managed installs, so its dirs lead;
    /// process-PATH dirs survive (QA sentinels, launchd basics), then the
    /// well-known extras as the final safety net.
    public static func merged(loginShellPath: String, processPath: String, wellKnown: [String]) -> String {
        appending(extraDirs: ToolDetector.splitPath(processPath) + wellKnown, to: loginShellPath)
    }
}
