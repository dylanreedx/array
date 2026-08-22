import Foundation

/// Ordered user-wide settings surface. Zone project/Home, color, name, layout
/// override and collapsed state are entity state, not global overrides.
public enum SettingsSchema {
    public static func sections() -> [SettingsSection] {
        let core: [SettingsSection] = [
            SettingsSection(id: "general", title: "General", iconSystemName: "gearshape", fields: [
                .choice(key: DeleteConfirmPolicy.userDefaultsKey, label: "Delete Confirmation", options: [DeleteConfirmPolicy.never.rawValue, DeleteConfirmPolicy.runtimes.rawValue, DeleteConfirmPolicy.always.rawValue], default: DeleteConfirmPolicy.runtimes.rawValue),
            ]),
            SettingsSection(id: "appearance", title: "Appearance", iconSystemName: "paintbrush", fields: [
                .choice(key: CommandCenterAppearanceConfig.glassinessKey, label: "Command Menu Appearance", options: CommandCenterAppearanceConfig.options, default: CommandCenterAppearanceConfig.defaultGlassiness.rawValue),
                .slider(key: CommandCenterAppearanceConfig.customOpacityKey, label: "Custom Command Menu Opacity", range: CommandCenterAppearanceConfig.customOpacityRange, default: CommandCenterAppearanceConfig.defaultCustomOpacity, visibleWhen: SettingsVisibility(key: CommandCenterAppearanceConfig.glassinessKey, equals: CommandCenterGlassiness.custom.rawValue)),
                .toggle(key: FocusBorderConfig.enabledKey, label: "Focus Border", default: FocusBorderConfig.defaultEnabled),
                .toggle(key: ResizeHUDConfig.enabledKey, label: "Resize Size Indicator", default: ResizeHUDConfig.defaultEnabled),
                .choice(key: FocusBorderConfig.colorKey, label: "Focus Border Color", options: FocusBorderConfig.colorOptions, default: FocusBorderConfig.defaultColor),
                .number(key: FocusBorderConfig.gapKey, label: "Focus Border Gap", range: 0...40, default: FocusBorderConfig.defaultGap, unit: "px", step: 1),
                .number(key: FocusBorderConfig.speedKey, label: "Focus Border Speed", range: 0.05...5, default: FocusBorderConfig.defaultSpeed, unit: "s", step: 0.05),
            ]),
            SettingsSection(id: "canvasAndZones", title: "Canvas & Zones", iconSystemName: "square.grid.2x2", fields: [
                .toggle(key: CanvasAutoLayoutConfig.enabledKey, label: "Auto Layout by Default", default: CanvasAutoLayoutConfig.defaultEnabled),
                .choice(key: CanvasAutoLayoutConfig.activationKey, label: "When Enabling Auto Layout", options: CanvasAutoLayoutActivation.allCases.map(\.rawValue), default: CanvasAutoLayoutConfig.defaultActivation.rawValue),
                .choice(key: ZoneColorConfig.assignmentPolicyKey, label: "Automatic Zone Colors", options: ZoneColorAssignmentPolicy.allCases.map(\.rawValue), default: ZoneColorConfig.defaultAssignmentPolicy.rawValue),
                .toggle(key: ZoneChromeFeature.userDefaultsKey, label: "Zone Chrome", default: true),
                .toggle(key: CanvasShortcutRailConfig.visibleKey, label: "Canvas Shortcut Rail", default: CanvasShortcutRailConfig.defaultVisible),
                .text(key: DefaultGroupZoneName.userDefaultsKey, label: "Default Zone Name", default: DefaultGroupZoneName.fallback),
                .number(key: TileGapResolver.userDefaultsKey, label: "Default Tile Gap", range: 0...160, default: TileGapResolver.defaultGap, unit: "pt", step: 4),
                .number(key: ZoneBoundsConfig.paddingKey, label: "Default Zone Padding", range: 0...240, default: ZoneBoundsConfig.defaultPadding, unit: "pt", step: 4),
                .toggle(key: DragMagnetizeConfig.enabledKey, label: "Drag Snapping", default: DragMagnetizeConfig.defaultEnabled),
            ]),
            SettingsSection(id: "navigation", title: "Navigation", iconSystemName: "arrow.up.arrow.down", fields: [
                .choice(key: NavKeymap.leaderHoldDefaultsKey, label: "Hold-to-Navigate Key", options: NavKeymap.leaderHoldModifierOptions, default: NavKeymap.modifierToken(NavKeymap.default.leaderHoldModifier)),
                .number(key: NavKeymap.leaderDwellDefaultsKey, label: "Hold Activation Delay", range: 0...2_000, default: Double(NavKeymap.default.leaderDwellMs), unit: "ms", step: 25),
                .text(key: NavKeymap.leaderLabelKeysDefaultsKey, label: "Jump Label Keys", default: NavKeymap.default.leaderLabelKeys),
                .text(key: NavKeymap.leaderZoneOrdinalKeysDefaultsKey, label: "Zone Number Keys", default: NavKeymap.default.leaderZoneOrdinalKeys),
            ]),
        ]
        let creation: [SettingsSection] = [
            SettingsSection(id: "keybindings", title: "Keybindings", iconSystemName: "keyboard", fields: [.shortcuts(label: "Keyboard Shortcuts")]),
            SettingsSection(id: "agents", title: "Agents", iconSystemName: "sparkles", fields: [
                .info(label: "Defaults apply to newly created agents only. Existing agents keep their harness, model, checkout, Home, Where, branch, and effort."),
                .choice(key: AgentBackendConfig.key, label: "Default Agent Harness", options: AgentBackendConfig.options, default: AgentBackendConfig.defaultBackend.rawValue),
                .choice(key: AgentModelConfig.modelKey, label: "Default Model", options: AgentModelConfig.modelOptions, default: AgentModelConfig.defaultModel),
                .choice(key: AgentModelConfig.thinkingKey, label: "Default Reasoning Effort", options: AgentModelConfig.thinkingOptions, default: AgentModelConfig.defaultThinking),
                .choice(key: AgentAutoSettleConfig.afterDaysKey, label: "Auto-Settle After", options: AgentAutoSettleConfig.options, default: AgentAutoSettleConfig.defaultOption),
            ]),
            SettingsSection(id: "terminal", title: "Terminal", iconSystemName: "terminal", fields: [
                .toggle(key: TmuxPersistenceConfig.enabledKey, label: "Keep Shells Alive (tmux)", default: TmuxPersistenceConfig.defaultEnabled),
                .text(key: TmuxPersistenceConfig.pathKey, label: "tmux Path", default: TmuxPersistenceConfig.defaultPath),
                .toggle(key: TmuxPersistenceConfig.ambientPerWorkspaceKey, label: "Share Unzoned Terminal Session per Workspace", default: TmuxPersistenceConfig.ambientPerWorkspaceDefault),
                .number(key: TerminalDisplayConfig.fontSizeKey, label: "Shell Font Size", range: 0...48, default: TerminalDisplayConfig.defaultFontSize, unit: "pt (0 = Ghostty)", step: 1),
                .number(key: TerminalScrollConfig.preciseMultiplierKey, label: "Precise Scroll Multiplier", range: 0.05...10, default: TerminalScrollConfig.preciseMultiplierDefault, unit: "×", step: 0.05),
                .number(key: TerminalScrollConfig.lineMultiplierKey, label: "Wheel Scroll Multiplier", range: 0.05...20, default: TerminalScrollConfig.lineMultiplierDefault, unit: "×", step: 0.1),
                .choice(key: NewTileCwdConfig.userDefaultsKey, label: "Unzoned Shell Directory Fallback", options: NewTileCwdPolicy.allCases.map(\.rawValue), default: NewTileCwdConfig.defaultPolicy.rawValue),
            ]),
            SettingsSection(id: "browser", title: "Browser", iconSystemName: "globe", fields: [
                .url(key: DefaultBrowserURL.userDefaultsKey, label: "Default Browser URL", default: DefaultBrowserURL.fallback),
                .info(label: "Safari Web Inspector is native WebKit inspection. Array Inspector opens inside Array with focused Elements, Console, Styles, and Network panels."),
                .toggle(key: BrowserWebInspectorConfig.userDefaultsKey, label: "Enable Safari Web Inspector for Browser Tiles", default: BrowserWebInspectorConfig.defaultEnabled),
            ]),
        ]
        let activity: [SettingsSection] = [
            SettingsSection(id: "activityAndNotifications", title: "Activity & Notifications", iconSystemName: "bell.badge", fields: [
                .toggle(key: WorkspaceSidebarConfig.visibleKey, label: "Show Activity Dock", default: WorkspaceSidebarConfig.defaultVisible),
                .number(key: WorkspaceSidebarConfig.widthKey, label: "Activity Dock Width", range: 180...640, default: WorkspaceSidebarConfig.defaultWidth, unit: "pt", step: 8),
                .info(label: "Choose which agent events send a notification. Security alerts always notify."),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .approvalRequested), label: "Approval Requests", default: PushCategory.approvalRequested.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .agentWaitingForInput), label: "Waiting for Input", default: PushCategory.agentWaitingForInput.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .agentFinished), label: "Agent Finished", default: PushCategory.agentFinished.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .agentFailed), label: "Agent Failed", default: PushCategory.agentFailed.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .stillWorkingDigest), label: "Still-Working Digest", default: PushCategory.stillWorkingDigest.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .desktopConnectionChanged), label: "Desktop Connection Changes", default: PushCategory.desktopConnectionChanged.defaultEnabled),
                .toggle(key: PersistedPushCategoryPreferences.key(for: .sessionReapedOrRevived), label: "Session Reaped or Revived", default: PushCategory.sessionReapedOrRevived.defaultEnabled),
            ]),
        ]
        let advancedCanvas: [SettingsField] = [
            .number(key: ZoneGestureConfig.minCreateDragScreenPointsKey, label: "Zone Creation Drag Threshold", range: 2...80, default: ZoneGestureConfig.defaultMinCreateDragScreenPoints, unit: "px", step: 1),
            .number(key: ZoneBoundsConfig.emptyMinWidthKey, label: "Empty Zone Minimum Width", range: 120...2_000, default: ZoneBoundsConfig.defaultEmptyMinWidth, unit: "pt", step: 8),
            .number(key: ZoneBoundsConfig.emptyMinHeightKey, label: "Empty Zone Minimum Height", range: 80...1_200, default: ZoneBoundsConfig.defaultEmptyMinHeight, unit: "pt", step: 8),
            .number(key: AutosaveConfig.debounceMsKey, label: "Autosave Debounce", range: 0...10_000, default: Double(AutosaveConfig.defaultDebounceMs), unit: "ms", step: 50),
            .toggle(key: SessionResumeConfig.scrollbackEnabledKey, label: "Restore Scrollback on Resume", default: SessionResumeConfig.scrollbackEnabledDefault),
            .number(key: SessionResumeConfig.scrollbackMaxLinesKey, label: "Scrollback Resume Limit", range: 0...100_000, default: Double(SessionResumeConfig.scrollbackMaxLinesDefault), unit: "lines", step: 500),
            .number(key: IdleReaperConfig.inactivityThresholdKey, label: "Idle Reaper Threshold", range: 30...86_400, default: IdleReaperConfig.defaultInactivityThreshold, unit: "s", step: 30),
            .number(key: IdleReaperConfig.sweepIntervalKey, label: "Idle Reaper Sweep Interval", range: 5...3_600, default: IdleReaperConfig.defaultSweepInterval, unit: "s", step: 5),
        ]
        let advancedRuntime: [SettingsField] = [
            .number(key: ZoneHydrationBudgetConfig.maxLiveZonesKey, label: "Maximum Live Zones", range: 1...64, default: Double(ZoneHydrationBudgetConfig.defaultMaxLiveZones), unit: "zones", step: 1),
            .number(key: BrowserRuntimeBudget.defaultsKey, label: "Maximum Live Web Views", range: 1...128, default: Double(BrowserRuntimeBudget.defaultMaxLive), unit: "views", step: 1),
            .number(key: ZoneHydrationReconcileConfig.intervalKey, label: "Zone Hydration Debounce", range: 0...10_000, default: Double(ZoneHydrationReconcileConfig.defaultIntervalMs), unit: "ms", step: 25),
            .toggle(key: ZoneRuntimeBudgetConfig.closeOnZeroKey, label: "Close Project Runtime When Unused", default: ZoneRuntimeBudgetConfig.defaultCloseOnZero),
            .number(key: SessionObserverConfig.debounceMsKey, label: "Agent Status Debounce", range: 0...10_000, default: Double(SessionObserverConfig.defaultDebounceMs), unit: "ms", step: 25),
            .number(key: SessionObserverConfig.maxChangesPerMinuteKey, label: "Agent Status Change Budget", range: 1...10_000, default: Double(SessionObserverConfig.defaultMaxChangesPerMinute), unit: "/ min", step: 1),
            .number(key: SessionObserverConfig.detectionPollSecondsKey, label: "Agent Detection Poll Interval", range: 0.1...300, default: Double(SessionObserverConfig.defaultDetectionPollSeconds), unit: "s", step: 0.1),
        ]
        let advanced: [SettingsSection] = [
            SettingsSection(id: "advanced", title: "Advanced", iconSystemName: "wrench.and.screwdriver", fields: advancedCanvas + advancedRuntime),
        ]
        return core + creation + activity + advanced
    }

    /// Metadata bridge while consumers migrate to `UserSettingsStore`. Every
    /// visible preference has a stable id; richer hand-authored definitions win.
    public static func registeredDefinitions() -> [AnySettingDefinition] {
        let typed = BuiltInSettingRegistry.all()
        var seen = Set(typed.map(\.id))
        var result = typed
        for section in sections() {
            let category = SettingsCategory(sectionID: section.id)
            for field in section.fields {
                guard let key = field.key else { continue }
                let id = SettingID(rawValue: key)
                guard seen.insert(id).inserted else { continue }
                result.append(AnySettingDefinition(
                    id: id,
                    category: category,
                    level: category == .advanced ? .advanced : .standard,
                    title: field.label,
                    description: field.label,
                    applicationPolicy: applicationPolicy(for: key),
                    keywords: [section.title, field.label],
                    consumerID: SettingConsumerID(rawValue: "settings.consumer.\(key)")
                ))
            }
        }
        return result
    }

    private static func applicationPolicy(for key: String) -> SettingApplicationPolicy {
        if [AgentBackendConfig.key, AgentModelConfig.modelKey, AgentModelConfig.thinkingKey, ZoneColorConfig.assignmentPolicyKey, ZoneBoundsConfig.paddingKey].contains(key) { return .nextCreation }
        if key == TmuxPersistenceConfig.pathKey { return .nextLaunch }
        return .live
    }
}

private extension SettingsCategory {
    init(sectionID: String) {
        switch sectionID {
        case "appearance": self = .appearance
        case "canvasAndZones": self = .canvasAndZones
        case "navigation": self = .navigation
        case "keybindings": self = .keybindings
        case "agents": self = .agents
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "activityAndNotifications": self = .activityAndNotifications
        case "advanced": self = .advanced
        default: self = .general
        }
    }
}
