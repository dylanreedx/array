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

    /// Claude's `sandbox` setting for a lead whose checkout is `root`. Both the
    /// path as given and with links resolved are denied.
    public static func claudeSandbox(checkoutRoot root: String) -> [String: Any] {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
                "filesystem": ["denyWrite": Array(Set([root, resolved])).sorted()]]
    }
}
