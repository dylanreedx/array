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
                    .text(
                        key: NavKeymap.leaderZoneOrdinalKeysDefaultsKey,
                        label: "Zone Jump Ordinal Keys",
                        default: NavKeymap.default.leaderZoneOrdinalKeys
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
                    .text(key: ZoneBoundsConfig.paddingKey, label: "Zone Padding", default: String(Int(ZoneBoundsConfig.defaultPadding))),
                    .text(key: ZoneBoundsConfig.emptyMinWidthKey, label: "Zone Empty Min Width", default: String(Int(ZoneBoundsConfig.defaultEmptyMinWidth))),
                    .text(key: ZoneBoundsConfig.emptyMinHeightKey, label: "Zone Empty Min Height", default: String(Int(ZoneBoundsConfig.defaultEmptyMinHeight))),
                    .toggle(
                        key: DragMagnetizeConfig.enabledKey,
                        label: "Drag Snapping",
                        default: DragMagnetizeConfig.defaultEnabled
                    ),
                    .text(
                        key: ZoneHydrationBudgetConfig.maxLiveZonesKey,
                        label: "Max Live Zones",
                        default: String(ZoneHydrationBudgetConfig.defaultMaxLiveZones)
                    ),
                    .text(
                        key: ZoneHydrationReconcileConfig.intervalKey,
                        label: "Zone Hydration Debounce (ms)",
                        default: String(ZoneHydrationReconcileConfig.defaultIntervalMs)
                    ),
                    .text(
                        key: BrowserRuntimeBudget.defaultsKey,
                        label: "Max Live Web Views",
                        default: String(BrowserRuntimeBudget.defaultMaxLive)
                    ),
                    .toggle(
                        key: ZoneRuntimeBudgetConfig.closeOnZeroKey,
                        label: "Close Project Runtime When Unused",
                        default: ZoneRuntimeBudgetConfig.defaultCloseOnZero
                    ),
                    .text(
                        key: DefaultGroupZoneName.userDefaultsKey,
                        label: "Default Zone Name",
                        default: DefaultGroupZoneName.fallback
                    ),
                    .text(
                        key: AmbientZoneHome.userDefaultsKey,
                        label: "Ambient Zone Home Directory",
                        default: AmbientZoneHome.fallback
                    ),
                    .text(
                        key: AutosaveConfig.debounceMsKey,
                        label: "Autosave Debounce (ms)",
                        default: String(AutosaveConfig.defaultDebounceMs)
                    ),
                    .toggle(
                        key: SessionResumeConfig.scrollbackEnabledKey,
                        label: "Restore Scrollback on Resume",
                        default: SessionResumeConfig.scrollbackEnabledDefault
                    ),
                    .text(
                        key: SessionResumeConfig.scrollbackMaxLinesKey,
                        label: "Scrollback Resume Max Lines",
                        default: String(SessionResumeConfig.scrollbackMaxLinesDefault)
                    ),
                    .text(
                        key: ZoneGestureConfig.minCreateDragScreenPointsKey,
                        label: "Zone Create Drag Threshold (px)",
                        default: String(Int(ZoneGestureConfig.defaultMinCreateDragScreenPoints))
                    ),
                    // WorkspaceProfileConfig.defaultCaptureModeKey and defaultApplyModeKey
                    // are intentionally not in SettingsSchema yet. The captureMode/applyMode
                    // distinction has no behavioral effect: T13 session-state fields live in
                    // ProjectStore sibling stores (not WorkspaceDocument), so snapshot and
                    // template produce byte-identical profiles. Settings entries will be added
                    // when a session-state bridge is designed.
                ]
            ),
            SettingsSection(
                id: "terminal",
                title: "Terminal",
                fields: [
                    .toggle(
                        key: TmuxPersistenceConfig.enabledKey,
                        label: "Keep Shells Alive (tmux)",
                        default: TmuxPersistenceConfig.defaultEnabled
                    ),
                    .text(
                        key: TmuxPersistenceConfig.pathKey,
                        label: "tmux Path",
                        default: TmuxPersistenceConfig.defaultPath
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
                    .toggle(
                        key: ResizeHUDConfig.enabledKey,
                        label: "Resize Size Indicator",
                        default: ResizeHUDConfig.defaultEnabled
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
