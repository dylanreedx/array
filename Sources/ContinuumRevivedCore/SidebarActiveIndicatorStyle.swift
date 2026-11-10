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
