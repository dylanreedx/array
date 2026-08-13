import Foundation

public enum AgentHarness: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case pi = "Pi"
}

public typealias AgentBackend = AgentHarness

public struct AgentLaunchSelection: Equatable, Sendable {
    public let harness: AgentHarness
    public let model: String
    public let thinking: String

    public init(harness: AgentHarness, model: String, thinking: String) {
        self.harness = harness
        self.model = model
        self.thinking = thinking
    }
}

public enum HarnessReadiness: Equatable, Sendable {
    case checking
    case ready
    case missing
    case loggedOut
    case unavailable(String)

    public var canRun: Bool { self == .ready }
}

public struct AgentHarnessCatalogSnapshot: Equatable, Sendable {
    public let harness: AgentHarness
    public let readiness: HarnessReadiness
    public let models: [String]
    public let displayNames: [String: String]
    public let contextWindows: [String: Int]
    public let refreshedAt: Date?

    public init(
        harness: AgentHarness,
        readiness: HarnessReadiness,
        models: [String],
        displayNames: [String: String] = [:],
        contextWindows: [String: Int] = [:],
        refreshedAt: Date? = nil
    ) {
        self.harness = harness
        self.readiness = readiness
        self.models = models
        self.displayNames = displayNames
        self.contextWindows = contextWindows
        self.refreshedAt = refreshedAt
    }
}

public enum AgentHarnessConfig {
    public static let key = "continuum.agents.backend"
    public static let defaultHarness: AgentHarness = .claudeCode
    public static var options: [String] { AgentHarness.allCases.map(\.rawValue) }

    public static func explicitlyStored(defaults: UserDefaults = .standard) -> AgentHarness? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        switch raw {
        case AgentHarness.claudeCode.rawValue: return .claudeCode
        case AgentHarness.codex.rawValue: return .codex
        case AgentHarness.pi.rawValue, "pi (all providers)": return .pi
        default: return nil
        }
    }

    public static func resolved(defaults: UserDefaults = .standard) -> AgentHarness {
        explicitlyStored(defaults: defaults) ?? defaultHarness
    }

    public static func store(_ harness: AgentHarness, defaults: UserDefaults = .standard) {
        defaults.set(harness.rawValue, forKey: key)
    }

    public static func provider(forID id: String) -> String {
        let parts = id.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : "other"
    }

    public static func isProviderCompatible(model: String, harness: AgentHarness) -> Bool {
        switch harness {
        case .claudeCode: return provider(forID: model) == "anthropic"
        case .codex: return provider(forID: model) == "openai-codex"
        case .pi: return model.contains("/")
        }
    }
}

public enum LegacyAgentHarnessMigration {
    public struct Evidence: Equatable, Sendable {
        public let hasCodexThread: Bool
        public let hasClaudeConversation: Bool
        public let hasPiSession: Bool
        public init(hasCodexThread: Bool, hasClaudeConversation: Bool, hasPiSession: Bool) {
            self.hasCodexThread = hasCodexThread
            self.hasClaudeConversation = hasClaudeConversation
            self.hasPiSession = hasPiSession
        }
    }

    public static func resolve(evidence: Evidence, storedPreference: AgentHarness?) -> AgentHarness? {
        if evidence.hasCodexThread { return .codex }
        if evidence.hasClaudeConversation && evidence.hasPiSession { return nil }
        if evidence.hasClaudeConversation { return .claudeCode }
        if evidence.hasPiSession { return .pi }
        return storedPreference ?? .claudeCode
    }
}

public enum AgentBackendConfig {
    public static let key = AgentHarnessConfig.key
    public static let defaultBackend = AgentHarnessConfig.defaultHarness
    public static var options: [String] { AgentHarnessConfig.options }
    public static func resolved(defaults: UserDefaults = .standard) -> AgentHarness {
        AgentHarnessConfig.resolved(defaults: defaults)
    }
    public static func explicitlyStored(defaults: UserDefaults = .standard) -> AgentHarness? {
        AgentHarnessConfig.explicitlyStored(defaults: defaults)
    }
    public static func store(_ harness: AgentHarness, defaults: UserDefaults = .standard) {
        AgentHarnessConfig.store(harness, defaults: defaults)
    }
    public static func provider(forID id: String) -> String { AgentHarnessConfig.provider(forID: id) }
}
