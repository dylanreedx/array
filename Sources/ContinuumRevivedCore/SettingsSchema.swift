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
                iconSystemName: "keyboard",
                fields: [
                    .shortcuts(label: "Keyboard Shortcuts")
                ]
            ),
            SettingsSection(
                id: "navigation",
                title: "Navigation",
                iconSystemName: "arrow.up.arrow.down",
                fields: [
                    .choice(
                        key: NavKeymap.leaderHoldDefaultsKey,
                        label: "Hold-to-Navigate Key",
                        options: NavKeymap.leaderHoldModifierOptions,
                        default: NavKeymap.modifierToken(NavKeymap.default.leaderHoldModifier)
                    ),
                    .text(
                        key: NavKeymap.leaderDwellDefaultsKey,
                        label: "Hold Activation Delay (ms)",
                        default: String(NavKeymap.default.leaderDwellMs)
                    ),
                    .text(
                        key: NavKeymap.leaderLabelKeysDefaultsKey,
                        label: "Jump Label Keys",
                        default: NavKeymap.default.leaderLabelKeys
                    ),
                    .text(
                        key: NavKeymap.leaderZoneOrdinalKeysDefaultsKey,
                        label: "Zone Number Keys",
                        default: NavKeymap.default.leaderZoneOrdinalKeys
                    ),
                ]
            ),
            SettingsSection(
                id: "general",
                title: "General",
                iconSystemName: "gearshape",
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
                ]
            ),
            SettingsSection(
                id: "zones",
                title: "Zones",
                iconSystemName: "square.grid.2x2",
                fields: [
                    .toggle(key: ZoneChromeFeature.userDefaultsKey, label: "Zone Chrome", default: true),
                    .text(key: DefaultGroupZoneName.userDefaultsKey, label: "Default Zone Name", default: DefaultGroupZoneName.fallback),
                    .text(key: AmbientZoneHome.userDefaultsKey, label: "Ambient Zone Home Directory", default: AmbientZoneHome.fallback),
                    .text(key: ZoneBoundsConfig.paddingKey, label: "Zone Padding", default: String(Int(ZoneBoundsConfig.defaultPadding))),
                    .text(key: ZoneBoundsConfig.emptyMinWidthKey, label: "Zone Empty Min Width", default: String(Int(ZoneBoundsConfig.defaultEmptyMinWidth))),
                    .text(key: ZoneBoundsConfig.emptyMinHeightKey, label: "Zone Empty Min Height", default: String(Int(ZoneBoundsConfig.defaultEmptyMinHeight))),
                    .text(key: ZoneGestureConfig.minCreateDragScreenPointsKey, label: "Zone Create Drag Threshold (px)", default: String(Int(ZoneGestureConfig.defaultMinCreateDragScreenPoints))),
                ]
            ),
            SettingsSection(
                id: "canvas",
                title: "Canvas",
                iconSystemName: "macwindow",
                fields: [
                    .text(key: TileGapResolver.userDefaultsKey, label: "Tile Gap", default: String(Int(TileGapResolver.defaultGap))),
                    .toggle(key: DragMagnetizeConfig.enabledKey, label: "Drag Snapping", default: DragMagnetizeConfig.defaultEnabled),
                ]
            ),
            SettingsSection(
                id: "sessions",
                title: "Sessions",
                iconSystemName: "clock.arrow.circlepath",
                fields: [
                    .text(key: AutosaveConfig.debounceMsKey, label: "Autosave Debounce (ms)", default: String(AutosaveConfig.defaultDebounceMs)),
                    .toggle(key: SessionResumeConfig.scrollbackEnabledKey, label: "Restore Scrollback on Resume", default: SessionResumeConfig.scrollbackEnabledDefault),
                    .text(key: SessionResumeConfig.scrollbackMaxLinesKey, label: "Scrollback Resume Max Lines", default: String(SessionResumeConfig.scrollbackMaxLinesDefault)),
                    .text(
                        key: IdleReaperConfig.inactivityThresholdKey,
                        label: "Idle Reaper Threshold (seconds)",
                        default: String(Int(IdleReaperConfig.defaultInactivityThreshold))
                    ),
                    .text(
                        key: IdleReaperConfig.sweepIntervalKey,
                        label: "Idle Reaper Sweep Interval (seconds)",
                        default: String(Int(IdleReaperConfig.defaultSweepInterval))
                    ),
                ]
            ),
            SettingsSection(
                id: "limits",
                title: "Runtime Limits",
                iconSystemName: "gauge.with.dots.needle.67percent",
                fields: [
                    .text(key: ZoneHydrationBudgetConfig.maxLiveZonesKey, label: "Max Live Zones", default: String(ZoneHydrationBudgetConfig.defaultMaxLiveZones)),
                    .text(key: BrowserRuntimeBudget.defaultsKey, label: "Max Live Web Views", default: String(BrowserRuntimeBudget.defaultMaxLive)),
                    .text(key: ZoneHydrationReconcileConfig.intervalKey, label: "Zone Hydration Debounce (ms)", default: String(ZoneHydrationReconcileConfig.defaultIntervalMs)),
                    .toggle(key: ZoneRuntimeBudgetConfig.closeOnZeroKey, label: "Close Project Runtime When Unused", default: ZoneRuntimeBudgetConfig.defaultCloseOnZero),
                    // WorkspaceProfileConfig capture/apply modes are intentionally absent
                    // until a session-state bridge is designed (no behavioral effect yet).
                ]
            ),
            SettingsSection(
                id: "browser",
                title: "Browser",
                iconSystemName: "globe",
                fields: [
                    .info(
                        label: "Safari Web Inspector is advanced native WebKit inspection from Safari Develop. Continuum Inspector Tile opens inside Continuum with limited Elements, logs-only Console, Styles, and Network-lite panels."
                    ),
                    .toggle(
                        key: BrowserWebInspectorConfig.userDefaultsKey,
                        label: "Enable Safari Web Inspector for Browser Tiles (open from Safari Develop)",
                        default: BrowserWebInspectorConfig.defaultEnabled
                    ),
                ]
            ),
            SettingsSection(
                id: "terminal",
                title: "Terminal",
                iconSystemName: "terminal",
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
                    .toggle(
                        key: TmuxPersistenceConfig.ambientPerWorkspaceKey,
                        label: "Share Ambient Terminal Session per Workspace",
                        default: TmuxPersistenceConfig.ambientPerWorkspaceDefault
                    ),
                    .text(
                        key: TerminalDisplayConfig.fontSizeKey,
                        label: "Shell Font Size (0 = Ghostty default)",
                        default: String(Int(TerminalDisplayConfig.defaultFontSize))
                    ),
                    .text(
                        key: TerminalScrollConfig.preciseMultiplierKey,
                        label: "Shell Scroll Precise Multiplier",
                        default: String(TerminalScrollConfig.preciseMultiplierDefault)
                    ),
                    .text(
                        key: TerminalScrollConfig.lineMultiplierKey,
                        label: "Shell Scroll Wheel Multiplier",
                        default: String(TerminalScrollConfig.lineMultiplierDefault)
                    ),
                ]
            ),
            SettingsSection(
                id: "appearance",
                title: "Appearance",
                iconSystemName: "paintbrush",
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
