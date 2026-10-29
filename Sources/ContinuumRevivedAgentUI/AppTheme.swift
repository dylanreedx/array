import Foundation

/// Ten achromatic palettes. Each changes surface depth, never hue, geometry,
/// provider identity or the semantic meaning of a status colour.
public enum AppTheme: String, CaseIterable, Sendable {
    case neutral, black, carbon, ink, graphite, stone, silver, paper, chalk, contrast

    public static let defaultsKey = "array.appearance.theme"
    public static let fallback: AppTheme = .neutral
    // Like CornerStyle, written by the main-actor app controller before repaint.
    nonisolated(unsafe) public static var current: AppTheme = .neutral

    public static func resolve(_ value: String?) -> AppTheme {
        value.flatMap(Self.init(rawValue:)) ?? fallback
    }

    public var title: String { rawValue.capitalized }

    public var appearance: TokenTheme {
        switch self {
        case .stone, .silver, .paper, .chalk: return .light
        default: return .dark
        }
    }

    public var detail: String {
        switch self {
        case .neutral: return "Dark · balanced gray"
        case .black: return "Dark · black canvas"
        case .carbon: return "Dark · deep gray"
        case .ink: return "Dark · quiet surfaces"
        case .graphite: return "Dark · lifted panels"
        case .stone: return "Light · soft gray"
        case .silver: return "Light · brighter panels"
        case .paper: return "Light · quiet surfaces"
        case .chalk: return "Light · crisp white"
        case .contrast: return "Dark · stronger separation"
        }
    }

    private var tuning: (depth: Double, lift: Double, white: Double) {
        switch self {
        case .neutral: return (1, 0, 0)
        case .black: return (1, -10, 0.02)
        case .carbon: return (0.9, -4, 0.04)
        case .ink: return (0.85, 0, 0.06)
        case .graphite: return (0.8, 5, 0.08)
        case .stone: return (0.7, 10, 0.10)
        case .silver: return (0.6, 17, 0.12)
        case .paper: return (1.05, -6, 0.14)
        case .chalk: return (1.1, -9, 0.16)
        case .contrast: return (1.2, -11, 0.18)
        }
    }

    // Explicit light ramps give the light choices visibly different canvas,
    // panel and content depths; a tiny whitening percentage was indistinguishable.
    private static let lightRamps: [AppTheme: [String: UInt8]] = [
        .stone: ["canvas": 235, "panel": 243, "tileBody": 245, "tileChrome": 235, "overlay": 249,
                 "cardMessage": 240, "cardUserMessage": 235, "cardTool": 241, "cardPlan": 238, "cardDiff": 242, "cardError": 239,
                 "composer": 236, "artifact": 237, "codeSubdued": 233, "rowSelected": 224, "rowHover": 239],
        .silver: ["canvas": 241, "panel": 247, "tileBody": 251, "tileChrome": 243, "overlay": 253,
                  "cardMessage": 246, "cardUserMessage": 244, "cardTool": 247, "cardPlan": 245, "cardDiff": 248, "cardError": 250,
                  "composer": 245, "artifact": 244, "codeSubdued": 240, "rowSelected": 228, "rowHover": 243],
        .paper: ["canvas": 247, "panel": 250, "tileBody": 255, "tileChrome": 248, "overlay": 254,
                 "cardMessage": 251, "cardUserMessage": 249, "cardTool": 252, "cardPlan": 250, "cardDiff": 253, "cardError": 254,
                 "composer": 250, "artifact": 249, "codeSubdued": 244, "rowSelected": 232, "rowHover": 247],
        .chalk: ["canvas": 238, "panel": 246, "tileBody": 255, "tileChrome": 237, "overlay": 253,
                 "cardMessage": 242, "cardUserMessage": 235, "cardTool": 244, "cardPlan": 239, "cardDiff": 245, "cardError": 243,
                 "composer": 241, "artifact": 238, "codeSubdued": 234, "rowSelected": 221, "rowHover": 240],
    ]

    func surface(light: ChipColor, dark: ChipColor, role: String) -> TokenColor {
        let t = tuning
        let override = Self.lightRamps[self]?[role]
        let l = override.map { Double($0) / 255 } ?? (light.r + (1 - light.r) * t.white)
        let d = min(1, max(0, dark.r * t.depth + t.lift / 255))
        return TokenColor(light: ChipColor(r: l, g: l, b: l),
                          dark: ChipColor(r: d, g: d, b: d))
    }
}
