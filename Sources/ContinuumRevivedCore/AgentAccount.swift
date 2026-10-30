import Foundation

/// An account Array knows about: a NAME for one CLI login, never the login.
///
/// ONE account per CLI is in use for the whole app at a time (Dylan: "a tile
/// from one account and another cannot exist on the canvas at once"); the rest
/// are saved logins Settings can switch to.
///
/// For Codex an account is a `CODEX_HOME`, where codex keeps that login's
/// `auth.json`. For Claude an account is a config directory. The CLI keys its own login by
/// that directory (its keychain item is `Claude Code-credentials-<hash of the
/// dir>`), so two directories hold two logins side by side. "Personal" is the
/// CLI's default directory (`~/.claude`, `configDirectory == nil`); an account
/// Array adds lives under Array's Application Support, which keeps it
/// channel-split like the rest of the app's own state and out of a project's
/// shared `.array/`.
///
/// Nothing here is a credential. The record is an id, a label, a harness and a
/// path. Who is signed in there is read from the CLI when needed.
public struct AgentAccount: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var harness: AgentHarness
    /// `CLAUDE_CONFIG_DIR` for this account. Nil is the CLI's own default.
    public var configDirectory: String?

    public init(id: String, label: String, harness: AgentHarness, configDirectory: String?) {
        self.id = id
        self.label = label
        self.harness = harness
        self.configDirectory = configDirectory
    }

    public var isDefault: Bool { configDirectory == nil }

    public static func defaultAccountId(for harness: AgentHarness) -> String {
        "\(harnessKey(harness)).default"
    }

    /// The login each CLI already has. Always present, never stored.
    public static func defaultAccount(for harness: AgentHarness) -> AgentAccount {
        AgentAccount(
            id: defaultAccountId(for: harness),
            label: "Personal",
            harness: harness,
            configDirectory: nil)
    }

    static func harnessKey(_ harness: AgentHarness) -> String {
        switch harness {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .pi: return "pi"
        }
    }
}

/// The accounts Array added (`accounts.json`) and the directories it owns for
/// them (`accounts/<id>/claude`), both under the app's Application Support.
public struct AgentAccountStore {
    public let root: URL
    private let fileURL: URL
    private let writer: AtomicWriter

    public init(applicationSupportDirectory: URL) {
        root = applicationSupportDirectory.appendingPathComponent("accounts", isDirectory: true)
        fileURL = applicationSupportDirectory.appendingPathComponent("accounts.json", isDirectory: false)
        writer = AtomicWriter(
            backupsDirectory: applicationSupportDirectory.appendingPathComponent("backups", isDirectory: true),
            retainedBackups: 1,
            legacyBackupPolicy: .targetDedicated)
    }

    /// The saved logins Array added (the defaults are implied) and which
    /// account each CLI uses, by `AgentHarness` raw value. No credential.
    public struct State: Codable, Equatable {
        public var accounts: [AgentAccount]
        public var active: [String: String]
        public init(accounts: [AgentAccount] = [], active: [String: String] = [:]) {
            self.accounts = accounts
            self.active = active
        }
    }

    public func load() -> State {
        guard let data = try? Data(contentsOf: fileURL),
              var state = try? JSONCodec.makeDecoder().decode(State.self, from: data) else { return State() }
        state.accounts = state.accounts.filter { !$0.isDefault }
        return state
    }

    public func save(_ state: State) throws {
        var stored = state
        stored.accounts = state.accounts.filter { !$0.isDefault }
        try writer.write(stored, to: fileURL)
    }

    /// A new Claude account named `label`, with a directory of its own. The id
    /// is the label's slug, numbered past any id already taken, so a second
    /// "Work" is `claude.work-2` rather than a collision.
    public func makeClaudeAccount(label: String, existing: [AgentAccount]) -> AgentAccount {
        makeAccount(harness: .claudeCode, label: label, existing: existing)
    }

    public func makeAccount(harness: AgentHarness, label: String, existing: [AgentAccount]) -> AgentAccount {
        let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let key = AgentAccount.harnessKey(harness)
        let base = "\(key).\(slug.isEmpty ? "account" : slug)"
        let taken = Set(existing.map(\.id))
        var id = base
        var n = 2
        while taken.contains(id) || id == AgentAccount.defaultAccountId(for: harness) {
            id = "\(base)-\(n)"
            n += 1
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        return AgentAccount(id: id, label: label, harness: harness, configDirectory: directory.path)
    }
}

/// Setting up a second Claude config directory so it behaves like the first.
public enum AgentAccountSetup {
    /// What the two accounts SHARE, so they do not drift: settings, the global
    /// instructions, the user's agents, skills and commands, and `projects/`.
    /// Each is a symlink back to the personal directory, so an edit through
    /// either account is one edit.
    ///
    /// `projects/` is shared so a conversation is ONE file both logins can
    /// resume: switching an agent's account is a respawn with `--resume` on
    /// the same id, with no copy to go stale, and Claude's per-project memory
    /// and every reader of `~/.claude/projects` keep working. Measured on
    /// 2.1.312 (no turn spent): through a symlinked `projects/`, `--resume`
    /// finds the session and stops at the login check, where a folder without
    /// it answers "No conversation found".
    ///
    /// What is NOT here is deliberate: `.claude.json` (it caches the signed-in
    /// account), any credentials file, caches and history.
    public static let sharedClaudeItems = ["settings.json", "CLAUDE.md", "agents", "skills", "commands", "projects"]

    /// Codex's equivalents: its config, instructions, prompts and skills, and
    /// `sessions/` so a thread resumes from either login. Never `auth.json`.
    public static let sharedCodexItems = ["config.toml", "AGENTS.md", "agents", "commands", "prompts", "skills", "sessions"]

    public static func sharedItems(for harness: AgentHarness) -> [String] {
        harness == .codex ? sharedCodexItems : sharedClaudeItems
    }

    /// The Personal Codex home: an inherited `CODEX_HOME` (the runner keeps
    /// it for the default account), else `~/.codex`.
    public static func personalCodexDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Creates `directory` and links each shared item that exists in `personal`
    /// and is absent here. Never replaces a file already in the directory: a
    /// setting made only for this account stays. Returns the names linked.
    @discardableResult
    public static func prepareClaudeConfigDirectory(_ directory: URL, sharingFrom personal: URL) throws -> [String] {
        try prepareDirectory(directory, sharing: sharedClaudeItems, from: personal)
    }

    @discardableResult
    public static func prepareDirectory(_ directory: URL, sharing items: [String], from personal: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var linked: [String] = []
        for name in items {
            let source = personal.appendingPathComponent(name)
            let target = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path),
                  (try? fm.destinationOfSymbolicLink(atPath: target.path)) == nil,
                  !fm.fileExists(atPath: target.path) else { continue }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
            linked.append(name)
        }
        return linked
    }

    /// The Personal account's directory: the CLI's default, `~/.claude`. Not an
    /// inherited `CLAUDE_CONFIG_DIR` — the default account's probe and runner
    /// remove that variable, so this is the directory they actually use.
    public static func personalClaudeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public enum SessionMove: Equatable, Sendable {
        /// Both folders see one `projects/`: nothing to move.
        case shared
        /// The session file (and its sidecar folder) was copied across.
        case copied
        /// There is no session file to move yet.
        case missing
    }

    /// Makes the conversation `sessionId` resumable from `target`.
    ///
    /// Normally both folders share `projects/` and this is a no-op. A folder
    /// whose `projects/` is its own (one Claude created before it was linked)
    /// gets the session file and its sidecar folder (subagent transcripts,
    /// spilled tool results) copied in, replacing an older copy, so
    /// `--resume <same id>` finds the conversation the agent was having.
    public static func ensureSessionVisible(
        sessionId: String,
        cwd: String,
        from source: URL,
        to target: URL
    ) throws -> SessionMove {
        let fm = FileManager.default
        let sourceProjects = source.appendingPathComponent("projects", isDirectory: true)
        let targetProjects = target.appendingPathComponent("projects", isDirectory: true)
        if sourceProjects.resolvingSymlinksInPath().standardizedFileURL.path
            == targetProjects.resolvingSymlinksInPath().standardizedFileURL.path {
            return .shared
        }
        let slug = ClaudeAgentStateReader.encodeCwd(cwd)
        let from = sourceProjects.appendingPathComponent(slug, isDirectory: true)
        let to = targetProjects.appendingPathComponent(slug, isDirectory: true)
        let file = "\(sessionId).jsonl"
        guard fm.fileExists(atPath: from.appendingPathComponent(file).path) else { return .missing }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in [file, sessionId] {
            let item = from.appendingPathComponent(name)
            guard fm.fileExists(atPath: item.path) else { continue }
            let destination = to.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: item, to: destination)
        }
        return .copied
    }

    /// argv for Claude's OWN sign-in in this account's directory, run through
    /// `env` so the terminal tile needs no environment plumbing of its own. The
    /// claude path is absolute because `env` does not search Array's PATH.
    /// Codex's own `login`, in the account's home.
    public static func codexSignInArguments(for account: AgentAccount, codexExecutable: String) -> [String] {
        var arguments: [String] = []
        if let directory = account.configDirectory { arguments.append("CODEX_HOME=\(directory)") }
        return arguments + [codexExecutable, "login"]
    }

    public static func claudeSignInArguments(for account: AgentAccount, claudeExecutable: String) -> [String] {
        var arguments: [String] = []
        if let directory = account.configDirectory { arguments.append("CLAUDE_CONFIG_DIR=\(directory)") }
        return arguments + [claudeExecutable, "auth", "login", "--claudeai"]
    }
}
