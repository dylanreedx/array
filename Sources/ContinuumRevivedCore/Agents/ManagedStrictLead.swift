import Foundation

/// `.plans/116` gap 20 and part 1: a Managed Claude lead whose shell cannot write
/// inside its checkout, so the work has to go to a helper. Off by default;
/// unproven changes ship switched off. Settings key for the app, environment
/// variable for the benchmark (the environment wins when set).
///
/// Measured on this Mac:
/// - Claude Code 2.1.321, `--permission-mode bypassPermissions` and this
///   `sandbox` value in `--settings`: shell and interpreter writes in the
///   checkout, `git commit` and a `dangerouslyDisableSandbox` call are all
///   refused; reads, `git status`/`log`, `$TMPDIR` writes and network work;
///   hooks still run outside the sandbox. `denyWrite` wins over `allowWrite`,
///   so a build directory INSIDE the checkout is refused too: a strict Claude
///   lead builds outside it (`$TMPDIR`).
/// - Codex is NOT covered: Codex leads launch exactly as with the switch off.
///   Codex 0.167.0's permission profiles enforce the same limit in its own
///   sandbox, and win over `sandbox_mode=danger-full-access`, but a thread or
///   turn that pins `dangerFullAccess` overrides them, and the app-server's
///   sandbox policies (`dangerFullAccess`, `readOnly`, `workspaceWrite`,
///   `externalSandbox`) cannot name a profile. So nothing can pin the profile
///   on `thread/resume` or `turn/start`, and whether a thread first run with
///   full access keeps it when resumed is unproven. A strict mode that might
///   not hold is not shipped.
public enum ManagedStrictLead {
    public static let enabledKey = "agents.strictLead.enabled"
    public static let environmentKey = "ARRAY_STRICT_LEAD"

    public static func isEnabled(defaults: UserDefaults,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let value = environment[environmentKey] { return ["1", "true", "yes", "on"].contains(value.lowercased()) }
        return defaults.object(forKey: enabledKey) as? Bool == true
    }

    /// The one line a strict lead is told, in its system prompt. No other agent gets it.
    public static let leadLine = "Strict lead: your shell cannot write inside your checkout, so helpers make the changes; build outside it with a scratch path, such as swift build --scratch-path \"$TMPDIR/build\"."

    /// Claude's `sandbox` setting for a lead whose checkout is `root`. Denied
    /// for writing, as given and with links resolved: the checkout, and the
    /// git directories it uses when they live outside it (a linked worktree's
    /// own git directory and the shared one holding objects and refs; or an
    /// enclosing repository's `.git`). A strict lead may read git; it may not
    /// commit, move a branch or write objects: committing is a helper's job.
    public static func claudeSandbox(checkoutRoot root: String) -> [String: Any] {
        var denied = [root] + gitDirectories(checkoutRoot: root)
        denied += denied.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
                "filesystem": ["denyWrite": Array(Set(denied)).sorted()]]
    }

    /// The git directories outside `root` that its repository writes: file
    /// reads only, no git process. Empty when `.git` is inside the checkout.
    static func gitDirectories(checkoutRoot root: String) -> [String] {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: root).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return directory.path == URL(fileURLWithPath: root).standardizedFileURL.path ? [] : [dotGit.path]
                }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return [] }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
                var found = [gitDir.path]
                if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
                    found.append(URL(fileURLWithPath: common, relativeTo: gitDir).standardizedFileURL.path)
                }
                return found
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return [] }
            directory = parent
        }
    }
}
