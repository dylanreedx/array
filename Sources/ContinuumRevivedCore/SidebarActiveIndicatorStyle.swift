import Foundation

/// The selected/open agent's surface in the sidebar. Shared by Settings and its renderer.
public enum SidebarActiveIndicatorStyle: String, CaseIterable, Sendable {
    case duplex, gradient, sheen
    case classic = "current"

    public static let defaultsKey = "continuum.sidebar.activeAgentStyle"
    public static let fallback: Self = .duplex

    public var title: String {
        switch self {
        case .duplex: return "Duplex"
        case .gradient: return "Gradient"
        case .sheen: return "Sheen"
        case .classic: return "Classic"
        }
    }

    public static func resolve(in defaults: UserDefaults) -> Self {
        (defaults.object(forKey: defaultsKey) as? String).flatMap(Self.init(rawValue:)) ?? fallback
    }
}

/// Working lights every running agent, as 0.7.47 did, and is the default. Selected
/// lights only the open agent: the one clicked or focused on the canvas, never the
/// table's transient selection, so a fold, reload or push cannot change it.
public enum SidebarActiveIndicatorScope: String, CaseIterable, Sendable {
    case selected, working
    public static let defaultsKey = "continuum.sidebar.activeAgentScope"
    public static let fallback: Self = .working
    public var title: String { self == .selected ? "Selected agent" : "All working agents" }
    public static func resolve(in defaults: UserDefaults) -> Self {
        (defaults.string(forKey: defaultsKey)).flatMap(Self.init(rawValue:)) ?? fallback
    }
}
