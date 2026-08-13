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
                id: "activity",
                title: "Activity",
                iconSystemName: "sidebar.left",
                fields: [
                    .toggle(
                        key: WorkspaceSidebarConfig.visibleKey,
                        label: "Show Activity Dock",
                        default: WorkspaceSidebarConfig.defaultVisible
                    ),
                    .text(
                        key: WorkspaceSidebarConfig.widthKey,
                        label: "Activity Dock Width (pt)",
                        default: String(Int(WorkspaceSidebarConfig.defaultWidth))
                    ),
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
                    .text(key: SessionObserverConfig.debounceMsKey, label: "Agent Status Debounce (ms)", default: String(SessionObserverConfig.defaultDebounceMs)),
                    .text(key: SessionObserverConfig.maxChangesPerMinuteKey, label: "Agent Status Change Budget (per minute)", default: String(SessionObserverConfig.defaultMaxChangesPerMinute)),
                    .text(key: SessionObserverConfig.detectionPollSecondsKey, label: "Agent Detection Poll Interval (s)", default: String(SessionObserverConfig.defaultDetectionPollSeconds)),
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
                    .choice(
                        key: NewTileCwdConfig.userDefaultsKey,
                        label: "New Terminal Working Directory",
                        options: NewTileCwdPolicy.allCases.map(\.rawValue),
                        default: NewTileCwdConfig.defaultPolicy.rawValue
                    ),
                ]
            ),
            SettingsSection(
                id: "agents",
                title: "Agents",
                iconSystemName: "bell.badge",
                fields: [
                    // Owner correction: these are the DEFAULTS a newly created
                    // agent starts with — each agent tile overrides its own
                    // next turn in the composer. The old "Agent Model" label
                    // read as if it drove every agent.
                    .info(label: "Defaults for newly created agents only. Each existing agent persists its own harness, model, and effort for the next turn in its composer."),
                    // Which CLI runs managed agents. pi covers every provider
                    // (the default); Claude Code narrows to Anthropic models and
                    // Codex to OpenAI models, each pinning that provider's native
                    // sign-in. The model list below filters to the choice.
                    .choice(
                        key: AgentBackendConfig.key,
                        label: "Agent Harness",
                        options: AgentBackendConfig.options,
                        default: AgentBackendConfig.defaultBackend.rawValue
                    ),
                    .choice(
                        key: AgentModelConfig.modelKey,
                        label: "Default Model",
                        options: AgentModelConfig.modelOptions,
                        default: AgentModelConfig.defaultModel
                    ),
                    .choice(
                        key: AgentModelConfig.thinkingKey,
                        label: "Default Reasoning Effort",
                        options: AgentModelConfig.thinkingOptions,
                        default: AgentModelConfig.defaultThinking
                    ),
                    .choice(
                        key: AgentAutoSettleConfig.afterDaysKey,
                        label: "Auto-Settle After (days)",
                        options: AgentAutoSettleConfig.options,
                        default: AgentAutoSettleConfig.defaultOption
                    ),
                    .info(label: "Choose which agent events send a push notification. Security alerts always notify."),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .approvalRequested), label: "Approval Requests", default: PushCategory.approvalRequested.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .agentWaitingForInput), label: "Waiting for Input", default: PushCategory.agentWaitingForInput.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .agentFinished), label: "Agent Finished", default: PushCategory.agentFinished.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .agentFailed), label: "Agent Failed", default: PushCategory.agentFailed.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .stillWorkingDigest), label: "Still-Working Digest", default: PushCategory.stillWorkingDigest.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .desktopConnectionChanged), label: "Desktop Connection Changes", default: PushCategory.desktopConnectionChanged.defaultEnabled),
                    .toggle(key: PersistedPushCategoryPreferences.key(for: .sessionReapedOrRevived), label: "Session Reaped or Revived", default: PushCategory.sessionReapedOrRevived.defaultEnabled),
                ]
            ),
            SettingsSection(
                id: "appearance",
                title: "Appearance",
                iconSystemName: "paintbrush",
                fields: [
                    .choice(
                        key: CommandCenterAppearanceConfig.glassinessKey,
                        label: "Command Menu Appearance",
                        options: CommandCenterAppearanceConfig.options,
                        default: CommandCenterAppearanceConfig.defaultGlassiness.rawValue
                    ),
                    .slider(
                        key: CommandCenterAppearanceConfig.customOpacityKey,
                        label: "Custom Command Menu Opacity",
                        range: CommandCenterAppearanceConfig.customOpacityRange,
                        default: CommandCenterAppearanceConfig.defaultCustomOpacity,
                        visibleWhen: SettingsVisibility(
                            key: CommandCenterAppearanceConfig.glassinessKey,
                            equals: CommandCenterGlassiness.custom.rawValue
                        )
                    ),
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
