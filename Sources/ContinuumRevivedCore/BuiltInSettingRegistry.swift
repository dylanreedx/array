import Foundation

public enum CanvasShortcutRailConfig {
    public static let visibleKey = "continuum.canvas.shortcutRail.visible"
    public static let defaultVisible = true

    public static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibleKey) != nil else { return defaultVisible }
        return defaults.bool(forKey: visibleKey)
    }
}

public enum ZoneColorAssignmentPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case nextUnusedThenLeastRecent
    case alwaysTeal
    case manual

    public var displayName: String {
        switch self {
        case .nextUnusedThenLeastRecent: return "Next unused, then least recent"
        case .alwaysTeal: return "Always teal"
        case .manual: return "Choose during creation"
        }
    }
}

public enum ZoneColorConfig {
    public static let assignmentPolicyKey = "continuum.zone.colorAssignmentPolicy"
    public static let defaultAssignmentPolicy = ZoneColorAssignmentPolicy.nextUnusedThenLeastRecent
    public static let palette = ["teal", "blue", "mint", "purple", "orange", "yellow", "red"]
}

public enum ZoneColorAllocator {
    /// Existing zones are supplied oldest-to-newest. Unused palette entries win;
    /// once exhausted, the color whose latest assignment is oldest wins. Manual
    /// choices are never rewritten by this allocator.
    public static func nextColor(
        existingColors: [String],
        palette: [String] = ZoneColorConfig.palette
    ) -> String {
        guard let fallback = palette.first else { return "teal" }
        let normalized = existingColors.map { $0.lowercased() }
        if let unused = palette.first(where: { !normalized.contains($0.lowercased()) }) {
            return unused
        }
        let lastAssignments = Dictionary(uniqueKeysWithValues: palette.map { color in
            (color, normalized.lastIndex(of: color.lowercased()) ?? -1)
        })
        return palette.min {
            let lhs = lastAssignments[$0] ?? -1
            let rhs = lastAssignments[$1] ?? -1
            if lhs != rhs { return lhs < rhs }
            return (palette.firstIndex(of: $0) ?? 0) < (palette.firstIndex(of: $1) ?? 0)
        } ?? fallback
    }
}

/// Typed settings that immediately support onboarding and zone creation. The
/// legacy renderer can consume the same keys while it is replaced category by
/// category; new settings must enter through this registry first.
public enum BuiltInSettingRegistry {
    public static let autoLayout = SettingDefinition(
        id: SettingID(rawValue: CanvasAutoLayoutConfig.enabledKey),
        category: .canvasAndZones,
        title: "Auto Layout",
        description: "Automatically arrange tiles in zones that inherit the global default.",
        defaultValue: CanvasAutoLayoutConfig.defaultEnabled,
        control: .toggle,
        applicationPolicy: .live,
        keywords: ["tidy", "arrange", "zones"],
        consumerID: "canvas.autoLayout"
    )

    public static let autoLayoutActivation = SettingDefinition(
        id: SettingID(rawValue: CanvasAutoLayoutConfig.activationKey),
        category: .canvasAndZones,
        title: "When Enabling Auto Layout",
        description: "Controls whether enabling auto layout immediately tidies existing tiles.",
        defaultValue: CanvasAutoLayoutConfig.defaultActivation.rawValue,
        control: .labeledEnum(options: Dictionary(uniqueKeysWithValues: CanvasAutoLayoutActivation.allCases.map { ($0.rawValue, $0.rawValue) })),
        validation: SettingValidation { CanvasAutoLayoutActivation(rawValue: $0) == nil ? "Choose a supported activation behavior." : nil },
        applicationPolicy: .live,
        keywords: ["tidy", "animation"],
        consumerID: "canvas.autoLayout.activation"
    )

    public static let zoneChrome = SettingDefinition(
        id: SettingID(rawValue: ZoneChromeFeature.userDefaultsKey),
        category: .canvasAndZones,
        title: "Zone Chrome",
        description: "Show zone headers, borders, and project/Home context.",
        defaultValue: true,
        control: .toggle,
        applicationPolicy: .live,
        keywords: ["headers", "borders", "project"],
        consumerID: "canvas.zoneChrome"
    )

    public static let tileGap = SettingDefinition(
        id: SettingID(rawValue: TileGapResolver.userDefaultsKey),
        category: .canvasAndZones,
        title: "Default Tile Gap",
        description: "Spacing used by auto layout and tidy.",
        defaultValue: TileGapResolver.defaultGap,
        control: .boundedNumber(range: 0...160, unit: "pt", step: 4),
        validation: SettingValidation { (0...160).contains($0) ? nil : "Choose a gap from 0 to 160 pt." },
        applicationPolicy: .live,
        keywords: ["spacing", "padding", "layout"],
        consumerID: "canvas.tileGap"
    )

    public static let shortcutRail = SettingDefinition(
        id: SettingID(rawValue: CanvasShortcutRailConfig.visibleKey),
        category: .canvasAndZones,
        title: "Canvas Shortcut Rail",
        description: "Keep essential Add, Jump, Navigation, and Pan shortcuts visible on the canvas.",
        defaultValue: CanvasShortcutRailConfig.defaultVisible,
        control: .toggle,
        applicationPolicy: .live,
        keywords: ["hints", "keyboard", "onboarding", "command center"],
        consumerID: "canvas.shortcutRail"
    )

    public static let zoneColorPolicy = SettingDefinition(
        id: SettingID(rawValue: ZoneColorConfig.assignmentPolicyKey),
        category: .canvasAndZones,
        title: "Automatic Zone Colors",
        description: "Choose how new zones receive an initial color. Manual color choices are never overwritten.",
        defaultValue: ZoneColorConfig.defaultAssignmentPolicy.rawValue,
        control: .labeledEnum(options: Dictionary(uniqueKeysWithValues: ZoneColorAssignmentPolicy.allCases.map { ($0.rawValue, $0.displayName) })),
        validation: SettingValidation { ZoneColorAssignmentPolicy(rawValue: $0) == nil ? "Choose a supported color policy." : nil },
        applicationPolicy: .nextCreation,
        keywords: ["palette", "organization", "project"],
        consumerID: "zone.creation.color"
    )

    public static let zonePadding = SettingDefinition(
        id: SettingID(rawValue: ZoneBoundsConfig.paddingKey),
        category: .canvasAndZones,
        title: "Default Zone Padding",
        description: "Padding around tiles when a new zone is laid out.",
        defaultValue: ZoneBoundsConfig.defaultPadding,
        control: .boundedNumber(range: 0...240, unit: "pt", step: 4),
        validation: SettingValidation { (0...240).contains($0) ? nil : "Choose padding from 0 to 240 pt." },
        applicationPolicy: .nextCreation,
        keywords: ["spacing", "layout"],
        consumerID: "zone.creation.padding"
    )

    public static let creationThreshold = SettingDefinition(
        id: SettingID(rawValue: ZoneGestureConfig.minCreateDragScreenPointsKey),
        category: .advanced,
        level: .advanced,
        title: "Zone Creation Drag Threshold",
        description: "Minimum empty-canvas drag distance before Array begins a provisional zone.",
        defaultValue: ZoneGestureConfig.defaultMinCreateDragScreenPoints,
        control: .boundedNumber(range: 2...80, unit: "px", step: 1),
        validation: SettingValidation { (2...80).contains($0) ? nil : "Choose a threshold from 2 to 80 px." },
        applicationPolicy: .live,
        keywords: ["gesture", "drag", "marquee"],
        consumerID: "canvas.zoneGesture"
    )

    public static func all() -> [AnySettingDefinition] {
        [
            autoLayout.erased,
            autoLayoutActivation.erased,
            zoneChrome.erased,
            tileGap.erased,
            shortcutRail.erased,
            zoneColorPolicy.erased,
            zonePadding.erased,
            creationThreshold.erased,
        ]
    }
}
