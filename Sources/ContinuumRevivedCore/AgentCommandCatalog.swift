import Foundation

/// The surface on which a command is understood.  The distinction is
/// intentionally explicit: a slash command is not automatically a shell
/// command, and a prompt skill is not automatically an Array action.
public enum AgentCommandSurface: String, Codable, CaseIterable, Equatable, Sendable {
    case array
    case providerSlash
    case skill
    case promptTemplate
    case extensionCommand
    case cli
}

public enum AgentCommandCapability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case readOnly
    case promptOnly
    case localWrite
    case network
    case processControl
    case destructive
    case authentication
}

public enum AgentCommandAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(String)
    case requiresTrust(String)
    case unknown

    private enum CodingKeys: String, CodingKey { case kind, reason }
    private enum Kind: String, Codable { case available, unavailable, requiresTrust, unknown }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .available: self = .available
        case .unavailable: self = .unavailable(try container.decode(String.self, forKey: .reason))
        case .requiresTrust: self = .requiresTrust(try container.decode(String.self, forKey: .reason))
        case .unknown: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(Kind.available, forKey: .kind)
        case let .unavailable(reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .requiresTrust(reason):
            try container.encode(Kind.requiresTrust, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// Host-local metadata for one command.  This is deliberately metadata-only:
/// command bodies and executable arguments are loaded by the provider adapter
/// only after the user explicitly invokes a row.
public struct AgentCommandDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let detail: String?
    public let argumentHint: String?
    public let harness: AgentHarness?
    public let scope: AgentCompletionScope
    public let sourceIdentifier: String
    public let surface: AgentCommandSurface
    public let capabilities: Set<AgentCommandCapability>
    public let availability: AgentCommandAvailability
    public let supportsArguments: Bool
    public let supportsQueueing: Bool
    public let runsImmediately: Bool
    public let userInvocable: Bool
    public let modelInvocable: Bool
    public let contextFork: Bool

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        detail: String? = nil,
        argumentHint: String? = nil,
        harness: AgentHarness? = nil,
        scope: AgentCompletionScope = .system,
        sourceIdentifier: String,
        surface: AgentCommandSurface,
        capabilities: Set<AgentCommandCapability> = [.promptOnly],
        availability: AgentCommandAvailability = .available,
        supportsArguments: Bool = false,
        supportsQueueing: Bool = false,
        runsImmediately: Bool = false,
        userInvocable: Bool = true,
        modelInvocable: Bool = false,
        contextFork: Bool = false
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.detail = detail
        self.argumentHint = argumentHint
        self.harness = harness
        self.scope = scope
        self.sourceIdentifier = sourceIdentifier
        self.surface = surface
        self.capabilities = capabilities
        self.availability = availability
        self.supportsArguments = supportsArguments
        self.supportsQueueing = supportsQueueing
        self.runsImmediately = runsImmediately
        self.userInvocable = userInvocable
        self.modelInvocable = modelInvocable
        self.contextFork = contextFork
    }

    public var isEnabled: Bool {
        if case .available = availability { return userInvocable }
        return false
    }

    public var disabledReason: String? {
        switch availability {
        case .available:
            return userInvocable ? nil : "Not user-invocable"
        case let .unavailable(reason), let .requiresTrust(reason):
            return reason
        case .unknown:
            return "Provider capability is not available"
        }
    }

    public var invocationNames: [String] { [name] + aliases }
}

/// Structured command acceptance. `arguments` contains only user-entered
/// argument tokens; provider adapters serialize the final native form. The
/// string overload exists only at the completion boundary and tokenizes without
/// invoking a shell.
public struct AgentCommandInvocation: Equatable, Sendable, Identifiable {
    public let id: String
    public let descriptorID: String
    public let name: String
    public let arguments: [String]
    public let harness: AgentHarness?
    public let surface: AgentCommandSurface

    public init(
        descriptorID: String,
        name: String,
        arguments: [String] = [],
        harness: AgentHarness? = nil,
        surface: AgentCommandSurface
    ) {
        self.id = descriptorID
        self.descriptorID = descriptorID
        self.name = name
        self.arguments = arguments
        self.harness = harness
        self.surface = surface
    }

    public init(
        descriptorID: String,
        name: String,
        arguments: String,
        harness: AgentHarness? = nil,
        surface: AgentCommandSurface
    ) {
        self.init(
            descriptorID: descriptorID,
            name: name,
            arguments: Self.tokenize(arguments),
            harness: harness,
            surface: surface
        )
    }

    /// Native slash serialization is kept at the dispatch boundary.  It is not
    /// used as draft text and never enters persistence as a path-like reference.
    public var nativeSlashText: String {
        let suffix = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? "/\(name)" : "/\(name) \(suffix)"
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
    }
}

public enum AgentCommandExecutionStatus: Equatable, Sendable {
    case completed
    case refused(String)
    case failed(String)
    case cancelled
}

public struct AgentCommandExecutionResult: Equatable, Sendable {
    public let status: AgentCommandExecutionStatus
    public let summary: String
    public let artifactURL: URL?

    public init(status: AgentCommandExecutionStatus, summary: String, artifactURL: URL? = nil) {
        self.status = status
        self.summary = summary
        self.artifactURL = artifactURL
    }
}

public struct AgentCommandProbeSnapshot: Equatable, Sendable {
    public let harness: AgentHarness
    public let executableURL: URL?
    public let version: String?
    public let commands: [AgentCommandDescriptor]
    public let refreshedAt: Date
    public let diagnostics: [String]

    public init(
        harness: AgentHarness,
        executableURL: URL? = nil,
        version: String? = nil,
        commands: [AgentCommandDescriptor],
        refreshedAt: Date = Date(),
        diagnostics: [String] = []
    ) {
        self.harness = harness
        self.executableURL = executableURL
        self.version = version
        self.commands = commands
        self.refreshedAt = refreshedAt
        self.diagnostics = diagnostics
    }
}

/// Provider adapters are intentionally narrow.  Array owns the command menu
/// and approval boundary; an adapter owns native discovery and serialization.
public protocol AgentHarnessCommandAdapter: Sendable {
    var harness: AgentHarness { get }
    func probe(context: AgentCompletionContext?) async -> AgentCommandProbeSnapshot
    func discoverCommands(context: AgentCompletionContext?) async -> [AgentCommandDescriptor]
    func invoke(_ invocation: AgentCommandInvocation, context: AgentCompletionContext?) async throws -> AgentCommandExecutionResult
    func cancel(_ invocation: AgentCommandInvocation, context: AgentCompletionContext?) async
}

public enum AgentCommandCatalog {
    public static let baselineVersion = "2026-08-20"

    public static func baseline(for harness: AgentHarness) -> [AgentCommandDescriptor] {
        switch harness {
        case .claudeCode:
            return claudeBaseline
        case .codex:
            return codexBaseline
        case .pi:
            return piBaseline
        }
    }

    public static func allBaselines() -> [AgentCommandDescriptor] {
        AgentHarness.allCases.flatMap(baseline(for:)) + arrayBaseline
    }

    public static func arrayCommands() -> [AgentCommandDescriptor] { arrayBaseline }

    private static func descriptor(
        _ harness: AgentHarness,
        _ name: String,
        _ detail: String,
        aliases: [String] = [],
        surface: AgentCommandSurface = .providerSlash,
        capabilities: Set<AgentCommandCapability> = [.promptOnly],
        arguments: Bool = false,
        queueing: Bool = false,
        immediate: Bool = false,
        source: String = "builtin"
    ) -> AgentCommandDescriptor {
        AgentCommandDescriptor(
            id: "\(harness.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")):\(name)",
            name: name,
            aliases: aliases,
            detail: detail,
            argumentHint: arguments ? "arguments" : nil,
            harness: harness,
            scope: .system,
            sourceIdentifier: source,
            surface: surface,
            capabilities: capabilities,
            supportsArguments: arguments,
            supportsQueueing: queueing,
            runsImmediately: immediate
        )
    }

    private static let arrayBaseline: [AgentCommandDescriptor] = [
        AgentCommandDescriptor(id: "array:help", name: "help", detail: "Show Array commands", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:clear", name: "clear", aliases: ["new", "reset"], detail: "Start a fresh conversation", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:plan", name: "plan", detail: "Switch to planning mode", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.promptOnly]),
        AgentCommandDescriptor(id: "array:status", name: "status", detail: "Show agent and session status", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:model", name: "model", detail: "Choose the active model", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:compact", name: "compact", detail: "Compact the current conversation", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.promptOnly]),
        AgentCommandDescriptor(id: "array:resume", name: "resume", detail: "Resume a saved agent session", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:fork", name: "fork", detail: "Fork the current conversation", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.localWrite], runsImmediately: true),
        AgentCommandDescriptor(id: "array:diff", name: "diff", detail: "Inspect the current working-tree diff", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:review", name: "review", detail: "Review the current working tree", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly]),
        AgentCommandDescriptor(id: "array:verify", name: "verify", detail: "Run the project verification contract", sourceIdentifier: "array.builtin", surface: .cli, capabilities: [.localWrite, .processControl], runsImmediately: true),
        AgentCommandDescriptor(id: "array:run", name: "run", detail: "Run a declared harness action", argumentHint: "arguments", sourceIdentifier: "array.builtin", surface: .cli, capabilities: [.processControl], supportsArguments: true, runsImmediately: true),
        AgentCommandDescriptor(id: "array:goal", name: "goal", detail: "Set or inspect a persistent goal", argumentHint: "arguments", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.localWrite], supportsArguments: true, runsImmediately: true),
        AgentCommandDescriptor(id: "array:skills", name: "skills", detail: "Browse discovered skills", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:commands", name: "commands", detail: "Browse all provider commands", sourceIdentifier: "array.builtin", surface: .array, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:harness", name: "harness", detail: "Inspect harness capabilities and jobs", argumentHint: "arguments", sourceIdentifier: "array.builtin", surface: .cli, capabilities: [.readOnly], supportsArguments: true, runsImmediately: true),
        AgentCommandDescriptor(id: "array:doctor", name: "doctor", detail: "Diagnose provider and project setup", sourceIdentifier: "array.builtin", surface: .cli, capabilities: [.readOnly], runsImmediately: true),
        AgentCommandDescriptor(id: "array:qa", name: "qa", detail: "Run an artifact-backed QA check", argumentHint: "arguments", sourceIdentifier: "array.builtin", surface: .cli, capabilities: [.processControl], supportsArguments: true, runsImmediately: true),
    ]

    private static let claudeBaseline: [AgentCommandDescriptor] = [
        descriptor(.claudeCode, "add-dir", "Add a working directory", capabilities: [.localWrite], arguments: true),
        descriptor(.claudeCode, "agents", "Manage agent configurations", capabilities: [.localWrite], immediate: true),
        descriptor(.claudeCode, "autocompact", "Configure automatic context compaction", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.claudeCode, "background", "Run the current session in the background", capabilities: [.processControl], arguments: true),
        descriptor(.claudeCode, "batch", "Orchestrate a large change across worktrees", surface: .skill, capabilities: [.localWrite, .processControl], arguments: true),
        descriptor(.claudeCode, "branch", "Branch the current conversation", capabilities: [.localWrite], arguments: true),
        descriptor(.claudeCode, "btw", "Ask a side question", arguments: true),
        descriptor(.claudeCode, "cd", "Move the session working directory", capabilities: [.localWrite], arguments: true),
        descriptor(.claudeCode, "clear", "Start a new conversation", aliases: ["new", "reset"], capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "code-review", "Review the current diff", aliases: ["review"], surface: .skill, capabilities: [.readOnly], arguments: true),
        descriptor(.claudeCode, "compact", "Compact the current conversation"),
        descriptor(.claudeCode, "context", "Inspect context usage", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "copy", "Copy the latest output", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "debug", "Diagnose a runtime issue", surface: .skill, capabilities: [.readOnly], arguments: true),
        descriptor(.claudeCode, "deep-research", "Run a research workflow", surface: .skill, capabilities: [.network, .processControl], arguments: true),
        descriptor(.claudeCode, "diff", "Show the working-tree diff", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "doctor", "Diagnose installation and configuration", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "effort", "Set reasoning effort", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.claudeCode, "export", "Export the current conversation", capabilities: [.localWrite], arguments: true),
        descriptor(.claudeCode, "feedback", "Report a problem", capabilities: [.network], immediate: true),
        descriptor(.claudeCode, "fork", "Fork the current session", capabilities: [.localWrite]),
        descriptor(.claudeCode, "help", "Show Claude help", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "hooks", "Inspect lifecycle hooks", capabilities: [.localWrite], immediate: true),
        descriptor(.claudeCode, "ide", "Inspect IDE context", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "init", "Create project instructions", capabilities: [.localWrite], immediate: true),
        descriptor(.claudeCode, "mcp", "Inspect MCP servers", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "memory", "Inspect project memory", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "model", "Choose the active model", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.claudeCode, "permissions", "Configure tool permissions", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.claudeCode, "plugin", "Manage plugins", capabilities: [.localWrite, .network], arguments: true, immediate: true),
        descriptor(.claudeCode, "plan", "Enter plan mode"),
        descriptor(.claudeCode, "resume", "Resume a saved session", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.claudeCode, "rewind", "Restore a checkpoint", capabilities: [.localWrite], arguments: true),
        descriptor(.claudeCode, "security-review", "Review for security issues", surface: .skill, capabilities: [.readOnly]),
        descriptor(.claudeCode, "skills", "Browse available skills", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "status", "Show session status", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "tasks", "Show background tasks", capabilities: [.readOnly], immediate: true),
        descriptor(.claudeCode, "verify", "Run verification", surface: .skill, capabilities: [.processControl], arguments: true),
        descriptor(.claudeCode, "workflows", "Browse workflows", surface: .skill, capabilities: [.readOnly], immediate: true),
    ]

    private static let codexBaseline: [AgentCommandDescriptor] = [
        descriptor(.codex, "permissions", "Set approval and sandbox permissions", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "ide", "Include IDE context", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "keymap", "Inspect keyboard shortcuts", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "vim", "Toggle Vim mode", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "agent", "Switch agent threads", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "subagents", "Switch agent threads", aliases: ["agent"], capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "apps", "Browse connected apps", capabilities: [.network], immediate: true),
        descriptor(.codex, "plugins", "Browse installed plugins", capabilities: [.network], immediate: true),
        descriptor(.codex, "hooks", "Inspect lifecycle hooks", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "clear", "Start a fresh chat", aliases: ["new"], capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "rename", "Rename the current chat", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "archive", "Archive the current session", capabilities: [.destructive, .localWrite], immediate: true),
        descriptor(.codex, "delete", "Delete the current session", capabilities: [.destructive, .localWrite], immediate: true),
        descriptor(.codex, "compact", "Compact the current chat"),
        descriptor(.codex, "copy", "Copy the latest output", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "diff", "Show the Git diff", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "experimental", "Toggle experimental features", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "approve", "Approve one retry", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "memories", "Configure memory use", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "skills", "Browse and use skills", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "import", "Import external-agent setup", capabilities: [.localWrite], arguments: true),
        descriptor(.codex, "feedback", "Send feedback", capabilities: [.network], immediate: true),
        descriptor(.codex, "init", "Create an AGENTS.md scaffold", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "logout", "Sign out of Codex", capabilities: [.authentication, .destructive], immediate: true),
        descriptor(.codex, "mcp", "Inspect MCP tools", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "mention", "Attach a file", capabilities: [.readOnly], arguments: true),
        descriptor(.codex, "model", "Choose the active model", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "fast", "Toggle Fast mode", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "plan", "Toggle plan mode"),
        descriptor(.codex, "goal", "Set a persistent goal", arguments: true),
        descriptor(.codex, "personality", "Choose communication style", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "ps", "Show background terminals", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "stop", "Stop background terminals", capabilities: [.processControl], immediate: true),
        descriptor(.codex, "fork", "Fork the current chat", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "side", "Start a temporary side chat", arguments: true),
        descriptor(.codex, "btw", "Ask a side question", arguments: true),
        descriptor(.codex, "resume", "Resume a saved chat", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "review", "Review the working tree", capabilities: [.readOnly], arguments: true),
        descriptor(.codex, "status", "Show session status", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "usage", "Show account usage", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "debug-config", "Diagnose config layers", capabilities: [.readOnly], immediate: true),
        descriptor(.codex, "cloud-environment", "Choose the cloud execution environment", capabilities: [.network], arguments: true, immediate: true),
        descriptor(.codex, "ide-context", "Toggle automatic IDE context", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "local", "Run the chat in the local workspace", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "project", "Choose the project for new chats", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "reasoning", "Choose reasoning effort", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "worktree", "Run the chat in a new Git worktree", capabilities: [.localWrite, .processControl], arguments: true, immediate: true),
        descriptor(.codex, "app", "Continue this chat in the desktop app", capabilities: [.network], immediate: true),
        descriptor(.codex, "raw", "Toggle raw scrollback mode", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.codex, "statusline", "Configure status-line fields", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "title", "Configure terminal title fields", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "theme", "Choose the terminal syntax theme", capabilities: [.localWrite], immediate: true),
        descriptor(.codex, "pets", "Choose or hide the terminal pet", aliases: ["pet"], capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "setup-default-sandbox", "Configure the degraded Windows sandbox", capabilities: [.localWrite, .processControl], immediate: true),
        descriptor(.codex, "sandbox-add-read-dir", "Grant a Windows sandbox read directory", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.codex, "exit", "Exit the CLI", aliases: ["quit"], capabilities: [.destructive], immediate: true),
        descriptor(.codex, "exec", "Run a non-interactive Codex task", surface: .cli, capabilities: [.processControl], arguments: true, immediate: true, source: "codex.cli"),
        descriptor(.codex, "login", "Authenticate Codex", surface: .cli, capabilities: [.authentication], immediate: true, source: "codex.cli"),
        descriptor(.codex, "update", "Update the Codex CLI", surface: .cli, capabilities: [.network, .localWrite], immediate: true, source: "codex.cli"),
        descriptor(.codex, "sandbox", "Run a command in the Codex sandbox", surface: .cli, capabilities: [.processControl], arguments: true, immediate: true, source: "codex.cli"),
        descriptor(.codex, "cloud", "Open Codex cloud tasks", surface: .cli, capabilities: [.network], arguments: true, immediate: true, source: "codex.cli"),
        descriptor(.codex, "mcp-server", "Run the Codex MCP server", surface: .cli, capabilities: [.network, .processControl], arguments: true, immediate: true, source: "codex.cli"),
    ]

    private static let piBaseline: [AgentCommandDescriptor] = [
        descriptor(.pi, "login", "Authenticate a provider", capabilities: [.authentication], immediate: true),
        descriptor(.pi, "logout", "Sign out of a provider", capabilities: [.authentication, .destructive], immediate: true),
        descriptor(.pi, "model", "Switch models", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.pi, "scoped-models", "Configure model cycling", capabilities: [.localWrite], immediate: true),
        descriptor(.pi, "settings", "Configure Pi settings", capabilities: [.localWrite], immediate: true),
        descriptor(.pi, "resume", "Resume a previous session", capabilities: [.readOnly], arguments: true, immediate: true),
        descriptor(.pi, "new", "Start a new session", capabilities: [.readOnly], immediate: true),
        descriptor(.pi, "name", "Name the current session", capabilities: [.localWrite], arguments: true, immediate: true),
        descriptor(.pi, "session", "Show session information", capabilities: [.readOnly], immediate: true),
        descriptor(.pi, "tree", "Navigate the session tree", capabilities: [.readOnly], immediate: true),
        descriptor(.pi, "fork", "Fork the current session", capabilities: [.localWrite], immediate: true),
        descriptor(.pi, "compact", "Compact the current context", arguments: true),
        descriptor(.pi, "copy", "Copy the latest assistant message", capabilities: [.readOnly], immediate: true),
    ]
}

/// A safe, provider-neutral conversion from descriptors to the existing slash
/// completion rows.  The completion payload retains the descriptor identity.
public struct AgentCommandCompletionProvider: AgentCompletionProvider {
    public let providerID: String

    public init(providerID: String = "array.provider-commands") {
        self.providerID = providerID
    }

    public var trigger: Character { "/" }

    public func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        guard !Task.isCancelled else { return [] }
        let active = query.context?.backend
        let discovered = AgentCommandResourceDiscovery.discover(context: query.context)
        let manifests = AgentHarnessCommandManifestDiscovery.discover(context: query.context)
        let descriptors = (AgentCommandCatalog.allBaselines() + discovered + manifests).map { descriptor in
            var copy = descriptor
            if descriptor.surface == .cli {
                // CLI and harness actions are discoverable from the slash menu,
                // but their approval/result-card path belongs to Command Center.
                // Keeping them disabled here prevents a row click from silently
                // degrading into prompt text or an unapproved subprocess.
                copy = AgentCommandDescriptor(
                    id: descriptor.id,
                    name: descriptor.name,
                    aliases: descriptor.aliases,
                    detail: descriptor.detail,
                    argumentHint: descriptor.argumentHint,
                    harness: descriptor.harness,
                    scope: descriptor.scope,
                    sourceIdentifier: descriptor.sourceIdentifier,
                    surface: descriptor.surface,
                    capabilities: descriptor.capabilities,
                    availability: .unavailable("Run from Array Command Center"),
                    supportsArguments: descriptor.supportsArguments,
                    supportsQueueing: descriptor.supportsQueueing,
                    runsImmediately: descriptor.runsImmediately,
                    userInvocable: descriptor.userInvocable,
                    modelInvocable: descriptor.modelInvocable,
                    contextFork: descriptor.contextFork
                )
            }
            if let harness = descriptor.harness, harness != active {
                copy = AgentCommandDescriptor(
                    id: descriptor.id,
                    name: descriptor.name,
                    aliases: descriptor.aliases,
                    detail: descriptor.detail,
                    argumentHint: descriptor.argumentHint,
                    harness: descriptor.harness,
                    scope: descriptor.scope,
                    sourceIdentifier: descriptor.sourceIdentifier,
                    surface: descriptor.surface,
                    capabilities: descriptor.capabilities,
                    availability: .unavailable("Requires \(harness.rawValue)"),
                    supportsArguments: descriptor.supportsArguments,
                    supportsQueueing: descriptor.supportsQueueing,
                    runsImmediately: descriptor.runsImmediately,
                    userInvocable: descriptor.userInvocable,
                    modelInvocable: descriptor.modelInvocable,
                    contextFork: descriptor.contextFork
                )
            }
            return copy
        }
        let needle = canonical(query.text)
        let arrayNames = Set(AgentCommandCatalog.arrayCommands().flatMap { [$0.name] + $0.aliases })
        return descriptors.compactMap { descriptor in
            guard descriptor.userInvocable else { return nil }
            let isActiveProvider = descriptor.harness != nil && descriptor.harness == active
            let collidesWithArray = isActiveProvider && arrayNames.contains(descriptor.name)
            let invocationName: String
            if let harness = descriptor.harness, !isActiveProvider || collidesWithArray {
                invocationName = harnessPrefix(harness) + ":" + descriptor.name
            } else {
                invocationName = descriptor.name
            }
            let matches = needle.isEmpty || descriptor.invocationNames.contains {
                canonical($0).contains(needle)
            } || canonical(descriptor.detail ?? "").contains(needle)
                || canonical(invocationName).contains(needle)
            guard matches else { return nil }
            let title = descriptor.name
            let detail = [descriptor.detail, descriptor.harness?.rawValue, descriptor.disabledReason]
                .compactMap { $0 }.joined(separator: " · ")
            let arguments: String
            if descriptor.supportsArguments,
               let separator = query.text.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                arguments = String(query.text[query.text.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                arguments = ""
            }
            return AgentCompletion(
                id: descriptor.id,
                title: title,
                detail: detail.isEmpty ? nil : detail,
                insertionText: "/\(invocationName)",
                score: descriptor.harness == active || descriptor.harness == nil ? 100 : 10,
                payload: .command(AgentCommandInvocation(
                    descriptorID: descriptor.id,
                    name: descriptor.name,
                    arguments: arguments,
                    harness: descriptor.harness,
                    surface: descriptor.surface
                )),
                provenance: AgentCompletionProvenance(
                    backend: descriptor.harness,
                    scope: descriptor.scope,
                    sourceIdentifier: descriptor.sourceIdentifier,
                    invocationName: invocationName
                ),
                isEnabled: descriptor.isEnabled,
                disabledReason: descriptor.disabledReason
            )
        }.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func harnessPrefix(_ harness: AgentHarness) -> String {
        switch harness {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .pi: return "pi"
        }
    }

    private func canonical(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
