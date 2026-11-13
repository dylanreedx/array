import Foundation

public enum SidebarHeaderBackground: String, CaseIterable, Sendable {
    case none, dots, diagonal, contours, grid
    public static let defaultsKey = "continuum.sidebar.headerBackground"
    public static let fallback: Self = .none
    public var title: String {
        switch self {
        case .none: return "None"
        case .dots: return "Dot grid"
        case .diagonal: return "Fine diagonals"
        case .contours: return "Contours"
        case .grid: return "Soft grid"
        }
    }
    public static func resolve(in defaults: UserDefaults) -> Self {
        (defaults.string(forKey: defaultsKey)).flatMap(Self.init(rawValue:)) ?? fallback
    }
}
