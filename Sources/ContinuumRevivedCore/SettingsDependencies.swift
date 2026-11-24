import ContinuumRevivedAgentUI
import Foundation

/// Rows that only mean something while another setting is on. With the parent
/// off they are HIDDEN, not dimmed (the pattern of Agents › Context). The rule is
/// keyed by the row's anchor (`SettingsRegistry.anchor`), so a rule never changes
/// a stored key or value.
public enum SettingsDependencies {
    public enum Gate: Equatable, Sendable {
        /// Shown while the Bool at `key` is on (`defaultOn` when absent).
        case on(key: String, defaultOn: Bool)
        /// Shown while the string at `key` (or `fallback` when absent) is not `value`.
        case notEqual(key: String, value: String, fallback: String)

        public func isOpen(in defaults: UserDefaults) -> Bool {
            switch self {
            case let .on(key, defaultOn):
                return defaults.object(forKey: key) as? Bool ?? defaultOn
            case let .notEqual(key, value, fallback):
                return (defaults.string(forKey: key) ?? fallback) != value
            }
        }
    }

    private static let sidebarGate = Gate.on(key: WorkspaceSidebarConfig.visibleKey, defaultOn: WorkspaceSidebarConfig.defaultVisible)
    private static let outlineGate = Gate.on(key: FocusBorderConfig.enabledKey, defaultOn: FocusBorderConfig.defaultEnabled)
    private static let charactersGate = Gate.on(key: AgentCharacterConfig.enabledKey, defaultOn: AgentCharacterConfig.defaultEnabled)
    private static let autoLayoutGate = Gate.on(key: CanvasAutoLayoutConfig.enabledKey, defaultOn: CanvasAutoLayoutConfig.defaultEnabled)
    private static let toolbarGate = Gate.on(key: FloatingToolbarConfig.visibleKey, defaultOn: FloatingToolbarConfig.defaultVisible)
    private static let badgeSizeGate = Gate.notEqual(key: AgentCharacterConfig.bubbleStyleKey,
                                                     value: AgentCharacterConfig.BubbleStyle.inline.rawValue,
                                                     fallback: AgentCharacterConfig.defaultBubbleStyle.rawValue)

    /// Anchor → the gate that must be open for the row to show.
    public static let gates: [String: Gate] = [
        // Sidebar: everything but the switch.
        "field.\(WorkspaceSidebarConfig.widthKey)": sidebarGate,
        "field.\(SidebarLayout.defaultsKey)": sidebarGate,
        "field.\(SidebarActiveIndicatorScope.defaultsKey)": sidebarGate,
        "field.\(SidebarActiveIndicatorStyle.defaultsKey)": sidebarGate,
        "field.\(SidebarHeaderBackground.defaultsKey)": sidebarGate,
        // Appearance: the outline's colour and gap.
        "field.\(FocusBorderConfig.colorKey)": outlineGate,
        "field.\(FocusBorderConfig.gapKey)": outlineGate,
        // Agent Icons.
        "field.\(AgentCharacterConfig.motionKey)": charactersGate,
        "field.\(AgentCharacterConfig.sizeKey)": charactersGate,
        "custom.agentCharacters": charactersGate,
        "field.\(AgentCharacterConfig.iconScaleKey)": badgeSizeGate,
        // Canvas.
        "field.\(CanvasAutoLayoutConfig.activationKey)": autoLayoutGate,
        "field.\(CanvasAutoLayoutConfig.growthKey)": autoLayoutGate,
        "custom.toolbarButtons": toolbarGate,
        "action.resetToolbarPosition": toolbarGate,
    ]

    public static func isOpen(_ field: SettingsField, in defaults: UserDefaults) -> Bool {
        guard let anchor = SettingsRegistry.anchor(for: field), let gate = gates[anchor] else { return true }
        return gate.isOpen(in: defaults)
    }
}
