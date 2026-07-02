import Foundation

public struct LaunchProfileSpec: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: Kind
    public let title: String
    public let agentKind: AgentKind?

    public init(id: String, displayName: String, kind: Kind, title: String, agentKind: AgentKind? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.title = title
        self.agentKind = agentKind
    }

    public enum Kind: Equatable, Sendable {
        case shell
        case tool(executableName: String, args: [String])
        case custom
    }
}

public enum LaunchProfileResolution: Equatable, Sendable {
    case found(LaunchProfile)
    case missing(executableName: String)
    case notConfigured(profileId: String)
}
