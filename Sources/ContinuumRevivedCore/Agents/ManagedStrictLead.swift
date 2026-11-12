import Foundation

/// `.plans/116` gap 20 and part 1: a Managed lead whose shell cannot write
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
/// - Codex 0.167.0 permission profile: the checkout and everything else read
///   only, `.build` under the workspace root and the temp folders writable,
///   network on. It wins over `sandbox_mode=danger-full-access`, but a thread or
///   turn that pins `dangerFullAccess` overrides it, so a strict launch pins none.
public enum ManagedStrictLead {
    public static let enabledKey = "agents.strictLead.enabled"
    public static let environmentKey = "ARRAY_STRICT_LEAD"

    public static func isEnabled(defaults: UserDefaults,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let value = environment[environmentKey] { return ["1", "true", "yes", "on"].contains(value.lowercased()) }
        return defaults.object(forKey: enabledKey) as? Bool == true
    }

    /// Claude's `sandbox` setting for a lead whose checkout is `root`. Both the
    /// path as given and with links resolved are denied.
    public static func claudeSandbox(checkoutRoot root: String) -> [String: Any] {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
                "filesystem": ["denyWrite": Array(Set([root, resolved])).sorted()]]
    }

    public static let codexProfile = "array-strict-lead"
    /// `-c` overrides for Codex's app-server.
    public static let codexOverrides: [String] = [
        "default_permissions=\"\(codexProfile)\"",
        "permissions.\(codexProfile).filesystem={\":root\"=\"read\",\":workspace_roots\"={\".\"=\"read\",\".build\"=\"write\"},\":tmpdir\"=\"write\",\":slash_tmp\"=\"write\"}",
        "permissions.\(codexProfile).network.enabled=true",
    ]
}
