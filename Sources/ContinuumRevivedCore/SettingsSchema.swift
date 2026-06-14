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
                ]
            ),
        ]
    }
}
