import Foundation

/// The ordered registry of settings sections — the single declarative source the
/// generic renderer (docs/24 S4/S5) draws from. Each `General` field binds to the
/// EXACT UserDefaults key of an existing resolver, so toggling it in settings
/// drives the live app: `ZoneChromeFeature`, `DeleteConfirmPolicy`,
/// `DefaultBrowserURL`, `TileGapResolver`.
///
/// Adding a preference = append one `SettingsField`; adding a section = append one
/// `SettingsSection`. No renderer changes.
public enum SettingsSchema {
    public static func sections() -> [SettingsSection] {
        [
            SettingsSection(
                id: "keybindings",
                title: "Keybindings",
                fields: [
                    .shortcuts(label: "Keyboard Shortcuts")
                ]
            ),
            SettingsSection(
                id: "navigation",
                title: "Navigation",
                fields: [
                    .choice(
                        key: NavKeymap.leaderHoldDefaultsKey,
                        label: "Leader Modifier (hold)",
                        options: NavKeymap.leaderHoldModifierOptions,
                        default: NavKeymap.modifierToken(NavKeymap.default.leaderHoldModifier)
                    ),
                    .text(
                        key: NavKeymap.leaderDwellDefaultsKey,
                        label: "Leader Hold Delay (ms)",
                        default: String(NavKeymap.default.leaderDwellMs)
                    ),
                    .text(
                        key: NavKeymap.leaderLabelKeysDefaultsKey,
                        label: "Jump Label Keys",
                        default: NavKeymap.default.leaderLabelKeys
                    ),
                ]
            ),
            SettingsSection(
                id: "general",
                title: "General",
                fields: [
                    .text(
                        key: DefaultBrowserURL.userDefaultsKey,
                        label: "Default Browser URL",
                        default: DefaultBrowserURL.fallback
                    ),
                    .choice(
                        key: DeleteConfirmPolicy.userDefaultsKey,
                        label: "Delete Confirmation",
                        options: [
                            DeleteConfirmPolicy.never.rawValue,
                            DeleteConfirmPolicy.runtimes.rawValue,
                            DeleteConfirmPolicy.always.rawValue,
                        ],
                        default: DeleteConfirmPolicy.runtimes.rawValue
                    ),
                    .toggle(
                        key: ZoneChromeFeature.userDefaultsKey,
                        label: "Zone Chrome",
                        default: true
                    ),
                    .text(
                        key: TileGapResolver.userDefaultsKey,
                        label: "Tile Gap",
                        default: String(Int(TileGapResolver.defaultGap))
                    ),
                    .toggle(
                        key: DragMagnetizeConfig.enabledKey,
                        label: "Drag Snapping",
                        default: DragMagnetizeConfig.defaultEnabled
                    ),
                ]
            ),
            SettingsSection(
                id: "appearance",
                title: "Appearance",
                fields: [
                    .toggle(
                        key: FocusBorderConfig.enabledKey,
                        label: "Focus Border",
                        default: FocusBorderConfig.defaultEnabled
                    ),
                    .choice(
                        key: FocusBorderConfig.colorKey,
                        label: "Focus Border Color",
                        options: FocusBorderConfig.colorOptions,
                        default: FocusBorderConfig.defaultColor
                    ),
                    .text(
                        key: FocusBorderConfig.gapKey,
                        label: "Focus Border Gap (px)",
                        default: String(Int(FocusBorderConfig.defaultGap))
                    ),
                    .text(
                        key: FocusBorderConfig.speedKey,
                        label: "Focus Border Speed (s)",
                        default: String(FocusBorderConfig.defaultSpeed)
                    ),
                ]
            ),
        ]
    }
}
