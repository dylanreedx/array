import ContinuumRevivedAgentUI
import Foundation

/// Ordered user-wide settings surface. Zone project/Home, color, name, layout
/// override and collapsed state are entity state, not global overrides.
///
/// Each `SettingsSection` is one sidebar pane; its `groups` are the grouped-form
/// sections inside it. Pane ids are stable — CoreChecks and the app look panes
/// up by id — so a pane may be retitled or regrouped but never renamed.
public enum SettingsSchema {
    /// The sidebar heading drawn above the tile panes.
    public static let tilesHeading = "Tiles"

    public static func sections() -> [SettingsSection] {
        [
            general(), appearance(), canvas(),
            agents(), editor(), terminal(), browser(),
            notificationsAndSounds(), keyboard(), iPhone(), advanced(),
        ]
    }

    // MARK: - Panes

    private static func general() -> SettingsSection {
        SettingsSection(id: "general", title: "General", iconSystemName: "gearshape", groups: [
            SettingsGroup(id: "general.closing", title: "Closing tiles", rows: [
                SettingsRow(
                    .choice(key: DeleteConfirmPolicy.userDefaultsKey, label: "Ask before closing a tile",
                            options: [DeleteConfirmPolicy.never.rawValue, DeleteConfirmPolicy.runtimes.rawValue, DeleteConfirmPolicy.always.rawValue],
                            default: DeleteConfirmPolicy.runtimes.rawValue,
                            titles: [
                                DeleteConfirmPolicy.never.rawValue: "Never",
                                DeleteConfirmPolicy.runtimes.rawValue: "Terminals and browsers",
                                DeleteConfirmPolicy.always.rawValue: "Always",
                            ]),
                    help: "Notes and files close straight away; their contents are saved on disk.",
                    keywords: ["delete", "confirm", "close", "warning"]),
            ]),
            SettingsGroup(id: "general.dock", title: "Activity Dock", rows: [
                SettingsRow(.toggle(key: WorkspaceSidebarConfig.visibleKey, label: "Show the Activity Dock", default: WorkspaceSidebarConfig.defaultVisible),
                            keywords: ["sidebar", "inbox", "agents list"]),
                SettingsRow(.number(key: WorkspaceSidebarConfig.widthKey, label: "Dock width", range: 180...640, default: WorkspaceSidebarConfig.defaultWidth, unit: "pt", step: 8),
                            keywords: ["sidebar"]),
            ]),
            SettingsGroup(id: "general.updates", title: "Updates", rows: [
                SettingsRow(.action(id: "checkForUpdates", label: "Software update", buttonTitle: "Check for Updates…"),
                            keywords: ["update", "upgrade", "version", "sparkle"]),
            ]),
        ])
    }

    private static func appearance() -> SettingsSection {
        SettingsSection(id: "appearance", title: "Appearance", iconSystemName: "paintbrush",
                        keywords: ["theme", "dark", "light", "look", "colour", "color"], groups: [
            SettingsGroup(id: "appearance.theme", title: "Theme", rows: [
                SettingsRow(.choice(key: AppTheme.defaultsKey, label: "App theme",
                                    options: AppTheme.allCases.map(\.rawValue),
                                    default: AppTheme.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AppTheme.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Ten neutral palettes. Changes apply immediately across the app.",
                            keywords: ["neutral", "palette", "grey", "gray", "black", "white"]),
            ]),
            SettingsGroup(id: "appearance.canvasBackground", title: "Canvas background", rows: [
                SettingsRow(.custom(id: "canvasBackground", label: "Canvas background")),
            ]),
            SettingsGroup(id: "appearance.corners", title: "Corners", rows: [
                SettingsRow(.choice(key: CornerStyle.defaultsKey, label: "Corner style",
                                    options: CornerStyle.allCases.map(\.rawValue),
                                    default: CornerStyle.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: CornerStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Tiles, zones, menus, the command menu, Settings and every card follow it right away.",
                            keywords: ["corners", "radius", "rounded", "sharp", "square", "bubbly", "roundness"]),
            ]),
            SettingsGroup(id: "appearance.focus", title: "Focus", rows: [
                SettingsRow(.toggle(key: FocusBorderConfig.enabledKey, label: "Outline the focused tile", default: FocusBorderConfig.defaultEnabled),
                            keywords: ["focus border", "ring", "highlight"]),
                SettingsRow(.choice(key: FocusBorderConfig.colorKey, label: "Outline colour", options: FocusBorderConfig.colorOptions, default: FocusBorderConfig.defaultColor),
                            keywords: ["focus border", "color", "accent"]),
                SettingsRow(.number(key: FocusBorderConfig.gapKey, label: "Outline gap", range: 0...40, default: FocusBorderConfig.defaultGap, unit: "px", step: 1),
                            keywords: ["focus border", "spacing"]),
                SettingsRow(.toggle(key: ResizeHUDConfig.enabledKey, label: "Show size while resizing", default: ResizeHUDConfig.defaultEnabled),
                            keywords: ["resize", "dimensions", "hud"]),
            ]),
            SettingsGroup(id: "appearance.commandMenu", title: "Command menu", rows: [
                SettingsRow(.choice(key: CommandCenterAppearanceConfig.glassinessKey, label: "Background", options: CommandCenterAppearanceConfig.options, default: CommandCenterAppearanceConfig.defaultGlassiness.rawValue),
                            keywords: ["command center", "palette", "glass", "blur", "frosted", "transparency"]),
                SettingsRow(.slider(key: CommandCenterAppearanceConfig.customOpacityKey, label: "Opacity", range: CommandCenterAppearanceConfig.customOpacityRange, default: CommandCenterAppearanceConfig.defaultCustomOpacity, visibleWhen: SettingsVisibility(key: CommandCenterAppearanceConfig.glassinessKey, equals: CommandCenterGlassiness.custom.rawValue), format: .percent),
                            keywords: ["command center", "palette", "transparency"]),
            ]),
        ])
    }

    private static func canvas() -> SettingsSection {
        let toolbarItems: [SettingsRow] = CommandRegistry.definitions().compactMap { definition in
            guard let item = definition.floatingToolbarItem else { return nil }
            return SettingsRow(
                .toggle(key: FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue),
                        label: "Show \(item.title) button", default: FloatingToolbarConfig.defaultItemVisible),
                keywords: ["toolbar", "button"])
        }
        return SettingsSection(id: "canvasAndZones", title: "Canvas", iconSystemName: "square.grid.2x2", groups: [
            SettingsGroup(id: "canvas.layout", title: "Layout", rows: [
                SettingsRow(.toggle(key: CanvasAutoLayoutConfig.enabledKey, label: "Arrange tiles automatically", default: CanvasAutoLayoutConfig.defaultEnabled),
                            help: "New zones keep their tiles tidy. Each zone can override this.",
                            keywords: ["auto layout", "tidy", "arrange"]),
                SettingsRow(.choice(key: CanvasAutoLayoutConfig.activationKey, label: "When you turn it on for a zone", options: CanvasAutoLayoutActivation.allCases.map(\.rawValue), default: CanvasAutoLayoutConfig.defaultActivation.rawValue,
                                    titles: [
                                        CanvasAutoLayoutActivation.immediately.rawValue: "Tidy right away",
                                        CanvasAutoLayoutActivation.onFirstEdit.rawValue: "Wait until the next change",
                                    ]),
                            keywords: ["auto layout", "tidy"]),
                SettingsRow(.number(key: TileGapResolver.userDefaultsKey, label: "Space between tiles", range: 0...160, default: TileGapResolver.defaultGap, unit: "pt", step: 4),
                            keywords: ["gap", "spacing", "padding"]),
                SettingsRow(.number(key: ZoneBoundsConfig.paddingKey, label: "Zone padding", range: 0...240, default: ZoneBoundsConfig.defaultPadding, unit: "pt", step: 4),
                            help: "Used when a new zone is laid out.",
                            keywords: ["spacing", "margin"]),
                SettingsRow(.toggle(key: DragMagnetizeConfig.enabledKey, label: "Snap tiles while dragging", default: DragMagnetizeConfig.defaultEnabled),
                            keywords: ["magnet", "snapping", "align"]),
            ]),
            SettingsGroup(id: "canvas.zones", title: "Zones", rows: [
                SettingsRow(.toggle(key: ZoneChromeFeature.userDefaultsKey, label: "Show zone headers", default: true),
                            help: "Headers, borders, and the project and Home folder of each zone.",
                            keywords: ["zone chrome", "border", "title bar"]),
                SettingsRow(.text(key: DefaultGroupZoneName.userDefaultsKey, label: "New zone name", default: DefaultGroupZoneName.fallback),
                            keywords: ["default name", "rename"]),
                SettingsRow(.choice(key: ZoneColorConfig.assignmentPolicyKey, label: "New zone colour", options: ZoneColorAssignmentPolicy.allCases.map(\.rawValue), default: ZoneColorConfig.defaultAssignmentPolicy.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: ZoneColorAssignmentPolicy.allCases.map { ($0.rawValue, $0.displayName) })),
                            help: "Used when a zone is created. A colour you pick is never changed.",
                            keywords: ["color", "palette"]),
            ]),
            SettingsGroup(id: "canvas.toolbar", title: "Toolbar and hints", rows: [
                SettingsRow(.toggle(key: FloatingToolbarConfig.visibleKey, label: "Show the canvas toolbar", default: FloatingToolbarConfig.defaultVisible),
                            keywords: ["floating toolbar", "create"]),
            ] + toolbarItems + [
                SettingsRow(.action(id: "resetToolbarPosition", label: "Toolbar position", buttonTitle: "Reset Position"),
                            keywords: ["toolbar", "edge", "move"]),
                SettingsRow(.toggle(key: CanvasShortcutRailConfig.visibleKey, label: "Show shortcut hints on the canvas", default: CanvasShortcutRailConfig.defaultVisible),
                            keywords: ["shortcut rail", "keyboard", "help"]),
            ]),
        ])
    }

    private static func agents() -> SettingsSection {
        let statusRow = AgentStatusElement.presentationOrder.filter { $0 != .contextMeter }.map { element in
            SettingsRow(.toggle(key: element.settingKey, label: element.title, default: element.defaultVisible),
                        keywords: element.isAccountScoped ? ["status", "quota", "usage", "account", "limits"] : ["status"])
        }
        return SettingsSection(id: "agents", title: "Agents", iconSystemName: "sparkles", sidebarHeading: tilesHeading,
                               keywords: ["ai", "assistant"], groups: [
            SettingsGroup(id: "agents.new", title: "New agents",
                          footer: "Applies to new agents. Existing agents keep their own CLI, model, and effort.", rows: [
                SettingsRow(.choice(key: AgentBackendConfig.key, label: "Agent CLI", options: AgentBackendConfig.options, default: AgentBackendConfig.defaultBackend.rawValue),
                            help: "The command-line tool that runs a new agent.",
                            keywords: ["harness", "default", "backend", "provider"]),
                SettingsRow(.choice(key: AgentModelConfig.modelKey, label: "Model", options: AgentModelConfig.modelOptions, default: AgentModelConfig.defaultModel),
                            keywords: ["default model", "llm"]),
                SettingsRow(.choice(key: AgentModelConfig.thinkingKey, label: "Reasoning effort", options: AgentModelConfig.thinkingOptions, default: AgentModelConfig.defaultThinking,
                                    titles: [
                                        "off": "Off", "minimal": "Minimal", "low": "Low", "medium": "Medium",
                                        "high": "High", "xhigh": "Extra high", "max": "Maximum",
                                    ]),
                            keywords: ["thinking", "effort"]),
                SettingsRow(.choice(key: WorkspaceToolsConfig.permissionKey, label: "Agent permissions",
                                    options: WorkspaceToolsPermission.allCases.map(\.rawValue),
                                    default: WorkspaceToolsConfig.defaultPermission.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: WorkspaceToolsPermission.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Free: agents start, message, and inspect other agents, open files, and arrange tiles in their own project without asking. Anything in another project still asks. Ask first: each kind of action asks once per agent. Off: new agents get no workspace tools.",
                            keywords: ["workspace tools", "canvas api", "permissions", "approval", "orchestrate", "delegate", "message", "subagents"]),
            ]),
            SettingsGroup(id: "agents.clis", title: "Agent CLIs",
                          footer: "Each CLI signs in with its own login. Array never asks for an API key.", rows: [
                SettingsRow(.custom(id: "harnessStatus", label: "Agent CLIs")),
                SettingsRow(.toggle(key: AgentCLIUpdateConfig.checksEnabledKey, label: "Check for agent CLI updates",
                                    default: AgentCLIUpdateConfig.checksEnabledDefault),
                            help: "Looks for newer versions at most once an hour. Updates only run when you click Update.",
                            keywords: ["update", "upgrade", "version", "cli", "npm", "homebrew"]),
            ]),
            SettingsGroup(id: "agents.identity", title: "Agent colour", rows: [
                SettingsRow(.choice(key: AgentIdentityColorConfig.styleKey, label: "Agent colour shows as",
                                    options: AgentIdentityColorStyle.allCases.map(\.rawValue),
                                    default: AgentIdentityColorConfig.defaultStyle.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentIdentityColorStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Agents have no colour until you pick one from the tile's menu.",
                            keywords: ["color", "colour", "identity", "tint", "border", "stripe"]),
            ]),
            SettingsGroup(id: "agents.context", title: "Context", rows: [
                SettingsRow(.toggle(key: AgentContextAutoCompactionPolicy.enabledKey, label: "Compact context automatically", default: true),
                            keywords: ["tokens", "summarize"]),
                SettingsRow(.number(key: AgentContextAutoCompactionPolicy.percentKey, label: "Compact when context is", range: 50...99, default: 90, unit: "% full", step: 1),
                            keywords: ["threshold", "tokens"]),
                SettingsRow(.toggle(key: AgentStatusElement.contextMeter.settingKey, label: "Show the context meter", default: AgentStatusElement.contextMeter.defaultVisible),
                            keywords: ["context meter", "status", "tokens"]),
            ]),
            SettingsGroup(id: "agents.dictation", title: "Dictation",
                          footer: "Speech is transcribed on this Mac. No audio is kept or sent anywhere.", rows: [
                SettingsRow(.toggle(key: DictationConfig.enabledKey, label: "Dictate into the composer", default: DictationConfig.defaultEnabled),
                            help: "Shows a microphone button beside Send. Press ⇧⌘D to start or finish, Esc to discard.",
                            keywords: ["dictation", "voice", "speech", "microphone", "mic", "talk"]),
            ]),
            SettingsGroup(id: "agents.transcript", title: "Transcript", rows: [
                SettingsRow(.toggle(key: AgentTerminalFaceConfig.showToggleKey, label: "Show Terminal toggle",
                                    default: AgentTerminalFaceConfig.defaultShowToggle),
                            help: "Adds a small icon to Claude Code tiles to switch between chat and Terminal. You can always switch from the tile menu or with ⌃⌘T.",
                            keywords: ["terminal", "chat", "toggle", "switch", "CLI", "title bar"]),
                SettingsRow(.toggle(key: TranscriptShellCommandConfig.key, label: "Show shell commands in transcripts",
                                    default: TranscriptShellCommandConfig.defaultEnabled),
                            help: "Keeps the commands agents run on this Mac so transcript rows can show them. Never synced.",
                            keywords: ["privacy", "shell", "command", "bash", "history", "transcript"]),
            ]),
            SettingsGroup(id: "agents.status", title: "Status row",
                          footer: "Applies to every agent tile. Account usage is per provider account, shared by every agent signed into it.",
                          rows: statusRow),
            SettingsGroup(id: "agents.lifecycle", title: "Finished agents", rows: [
                SettingsRow(.choice(key: AgentAutoSettleConfig.afterDaysKey, label: "Settle finished agents", options: AgentAutoSettleConfig.options, default: AgentAutoSettleConfig.defaultOption,
                                    titles: Dictionary(uniqueKeysWithValues: AgentAutoSettleConfig.options.map { option in
                                        guard let days = Int(option) else { return (option, "Never") }
                                        return (option, days == 1 ? "After 1 day" : "After \(days) days")
                                    })),
                            help: "Moves an idle agent out of the Activity Dock list.",
                            keywords: ["auto settle", "archive", "idle"]),
                SettingsRow(.number(key: AgentSpawnLimitConfig.maximumActiveChildrenKey, label: "Sub-agents at once", range: Double(AgentSpawnLimitConfig.supportedRange.lowerBound)...Double(AgentSpawnLimitConfig.supportedRange.upperBound), default: Double(AgentSpawnLimitConfig.defaultMaximumActiveChildren), unit: "agents", step: 1),
                            help: "How many child agents one agent may run at the same time.",
                            keywords: ["children", "spawn", "limit", "max"], zeroTitle: "No limit"),
            ]),
        ])
    }

    private static func editor() -> SettingsSection {
        SettingsSection(id: "editor", title: "Editor", iconSystemName: "curlybraces", sidebarHeading: tilesHeading,
                        keywords: ["code", "file"], groups: [
            SettingsGroup(id: "editor.appearance", title: nil, footer: "Applies to every editor tile right away.", rows: [
                SettingsRow(.choice(key: EditorPreferences.appearanceKey, label: "Appearance", options: EditorAppearance.allCases.map(\.rawValue), default: EditorAppearance.system.rawValue,
                                    titles: [
                                        EditorAppearance.system.rawValue: "Match System",
                                        EditorAppearance.light.rawValue: "Light",
                                        EditorAppearance.dark.rawValue: "Dark",
                                    ]),
                            keywords: ["theme"]),
                SettingsRow(.text(key: EditorPreferences.fontFamilyKey, label: "Font", default: EditorPreferences.defaultFontFamily),
                            keywords: ["font family", "typeface", "monospace"]),
                SettingsRow(.number(key: EditorPreferences.fontSizeKey, label: "Font size", range: EditorPreferences.fontSizeRange, default: EditorPreferences.defaultFontSize, unit: "pt", step: 1),
                            keywords: ["text size"]),
                SettingsRow(.number(key: EditorPreferences.lineHeightKey, label: "Line height", range: EditorPreferences.lineHeightRange, default: EditorPreferences.defaultLineHeight, unit: "×", step: 0.1),
                            keywords: ["spacing"]),
                SettingsRow(.toggle(key: EditorPreferences.lineNumbersKey, label: "Line numbers", default: true),
                            keywords: ["gutter"]),
                SettingsRow(.toggle(key: EditorPreferences.wordWrapKey, label: "Wrap long lines", default: false),
                            keywords: ["word wrap", "soft wrap"]),
                SettingsRow(.toggle(key: EditorPreferences.vimEnabledKey, label: "Vim keys", default: false),
                            keywords: ["vim", "modal editing"]),
            ]),
        ])
    }

    private static func terminal() -> SettingsSection {
        SettingsSection(id: "terminal", title: "Terminal", iconSystemName: "terminal", sidebarHeading: tilesHeading,
                        keywords: ["shell", "console"], groups: [
            SettingsGroup(id: "terminal.display", title: "Display", footer: "Applies to new terminals.", rows: [
                SettingsRow(.number(key: TerminalDisplayConfig.fontSizeKey, label: "Font size", range: 0...48, default: TerminalDisplayConfig.defaultFontSize, unit: "pt", step: 1),
                            help: "At 0, terminals use your Ghostty configuration.",
                            keywords: ["text size"], zeroTitle: "Default"),
            ]),
            SettingsGroup(id: "terminal.sessions", title: "Sessions", footer: "Applies to new terminals.", rows: [
                SettingsRow(.toggle(key: TmuxPersistenceConfig.enabledKey, label: "Keep shells running when Array quits", default: TmuxPersistenceConfig.defaultEnabled),
                            help: "Uses tmux, so a terminal comes back where you left it.",
                            keywords: ["tmux", "persist", "restore"]),
                SettingsRow(.toggle(key: TmuxPersistenceConfig.ambientPerWorkspaceKey, label: "Share one session outside zones", default: TmuxPersistenceConfig.ambientPerWorkspaceDefault),
                            help: "Terminals not in a zone share one tmux session per workspace.",
                            keywords: ["tmux", "unzoned"]),
                SettingsRow(.toggle(key: SessionResumeConfig.scrollbackEnabledKey, label: "Restore scrollback", default: SessionResumeConfig.scrollbackEnabledDefault),
                            keywords: ["history", "resume"]),
                SettingsRow(.number(key: SessionResumeConfig.scrollbackMaxLinesKey, label: "Lines to restore", range: 0...100_000, default: Double(SessionResumeConfig.scrollbackMaxLinesDefault), unit: "lines", step: 500),
                            keywords: ["scrollback", "history"]),
            ]),
            SettingsGroup(id: "terminal.directory", title: "Starting folder", rows: [
                SettingsRow(.choice(key: NewTileCwdConfig.userDefaultsKey, label: "Terminals outside a zone start in", options: NewTileCwdPolicy.allCases.map(\.rawValue), default: NewTileCwdConfig.defaultPolicy.rawValue,
                                    titles: [
                                        NewTileCwdPolicy.inheritFocus.rawValue: "The focused terminal's folder",
                                        NewTileCwdPolicy.projectRoot.rawValue: "The project folder",
                                        NewTileCwdPolicy.lastUsed.rawValue: "The last folder used",
                                    ]),
                            help: "A terminal created in a zone always starts in that zone's Home folder.",
                            keywords: ["cwd", "directory", "working directory"]),
            ]),
        ])
    }

    private static func browser() -> SettingsSection {
        SettingsSection(id: "browser", title: "Browser", iconSystemName: "globe", sidebarHeading: tilesHeading,
                        keywords: ["web", "webkit"], groups: [
            SettingsGroup(id: "browser.general", title: nil, rows: [
                SettingsRow(.url(key: DefaultBrowserURL.userDefaultsKey, label: "New browser tiles open", default: DefaultBrowserURL.fallback),
                            keywords: ["home page", "default url", "start page"]),
                SettingsRow(.toggle(key: BrowserWebInspectorConfig.userDefaultsKey, label: "Allow Safari Web Inspector", default: BrowserWebInspectorConfig.defaultEnabled),
                            help: "Safari Web Inspector is native WebKit inspection, opened from Safari's Develop menu. Array Inspector opens inside Array with focused Elements, Console, Styles, and Network panels, and needs no setting.",
                            keywords: ["devtools", "developer", "inspect", "debug"]),
            ]),
        ])
    }

    private static func notificationsAndSounds() -> SettingsSection {
        SettingsSection(id: "activityAndNotifications", title: "Notifications & Sounds", iconSystemName: "bell.badge",
                        keywords: ["alerts", "audio"], groups: [
            SettingsGroup(id: "sounds", title: "Sounds", rows: [
                SettingsRow(.agentSounds(label: "Agent sounds")),
            ]),
        ])
    }

    private static func keyboard() -> SettingsSection {
        SettingsSection(id: "keybindings", title: "Keyboard", iconSystemName: "keyboard",
                        keywords: ["keys", "hotkeys", "keybindings"], groups: [
            SettingsGroup(id: "keyboard.navigation", title: "Navigation",
                          footer: "Hold the key to show jump labels on every tile and zone.", rows: [
                SettingsRow(.choice(key: NavKeymap.leaderHoldDefaultsKey, label: "Hold to navigate", options: NavKeymap.leaderHoldModifierOptions, default: NavKeymap.modifierToken(NavKeymap.default.leaderHoldModifier),
                                    titles: ["opt": "⌥ Option", "ctrl": "⌃ Control", "cmd": "⌘ Command", "shift": "⇧ Shift"]),
                            keywords: ["leader", "modifier", "jump"]),
                SettingsRow(.number(key: NavKeymap.leaderDwellDefaultsKey, label: "Hold for", range: Double(NavKeymap.minimumLeaderDwellMs)...2_000, default: Double(NavKeymap.default.leaderDwellMs), unit: "ms", step: 25),
                            keywords: ["delay", "leader"]),
                SettingsRow(.text(key: NavKeymap.leaderLabelKeysDefaultsKey, label: "Tile label keys", default: NavKeymap.default.leaderLabelKeys),
                            keywords: ["jump labels", "alphabet"]),
                SettingsRow(.text(key: NavKeymap.leaderZoneOrdinalKeysDefaultsKey, label: "Zone number keys", default: NavKeymap.default.leaderZoneOrdinalKeys),
                            keywords: ["jump", "zones"]),
            ]),
            SettingsGroup(id: "keyboard.shortcuts", title: "Shortcuts", rows: [
                SettingsRow(.shortcuts(label: "Keyboard shortcuts")),
            ]),
        ])
    }

    private static func iPhone() -> SettingsSection {
        let categories: [(PushCategory, String)] = [
            (.approvalRequested, "Approval requests"),
            (.agentWaitingForInput, "Waiting for input"),
            (.agentFinished, "Agent finished"),
            (.agentFailed, "Agent failed"),
            (.stillWorkingDigest, "Still-working digest"),
            (.desktopConnectionChanged, "Mac connection changes"),
            (.sessionReapedOrRevived, "Sessions closed or revived"),
        ]
        return SettingsSection(id: "companion", title: "iPhone", iconSystemName: "iphone",
                               keywords: ["companion", "phone", "mobile", "ios"], groups: [
            SettingsGroup(id: "iphone.pairing", title: "Pairing", rows: [
                SettingsRow(.custom(id: "companion", label: "iPhone pairing")),
            ]),
            SettingsGroup(id: "iphone.notifications", title: "Notifications",
                          footer: "Choose which agent events reach your iPhone. Security alerts always do.",
                          rows: categories.map { category, title in
                SettingsRow(.toggle(key: PersistedPushCategoryPreferences.key(for: category), label: title, default: category.defaultEnabled),
                            keywords: ["push", "notify", "alert"])
            }),
        ])
    }

    private static func advanced() -> SettingsSection {
        SettingsSection(id: "advanced", title: "Advanced", iconSystemName: "wrench.and.screwdriver",
                        keywords: ["performance", "memory"], groups: [
            SettingsGroup(id: "advanced.limits", title: "Limits",
                          footer: "Lower limits use less memory; tiles beyond them reload when you return.", rows: [
                SettingsRow(.number(key: BrowserRuntimeBudget.defaultsKey, label: "Live web pages", range: 1...128, default: Double(BrowserRuntimeBudget.defaultMaxLive), unit: "pages", step: 1),
                            keywords: ["browser", "webview", "budget", "max"]),
                SettingsRow(.number(key: ZoneHydrationBudgetConfig.maxLiveZonesKey, label: "Live zones", range: 1...64, default: Double(ZoneHydrationBudgetConfig.defaultMaxLiveZones), unit: "zones", step: 1),
                            keywords: ["hydration", "budget", "max"]),
                SettingsRow(.toggle(key: ZoneRuntimeBudgetConfig.closeOnZeroKey, label: "Close a project's runtime when it has no zones on the canvas", default: ZoneRuntimeBudgetConfig.defaultCloseOnZero),
                            keywords: ["memory", "unused"]),
            ]),
        ])
    }

    // MARK: - Retained tuning knobs

    /// Internal tuning knobs that left the Settings UI. Their defaults keys,
    /// defaults and ranges are unchanged and every resolver still reads them; they
    /// are listed here so checks keep witnessing their bounds and the setting
    /// registry still knows them.
    public static func retainedTuningFields() -> [SettingsField] {
        [
            .number(key: FocusBorderConfig.speedKey, label: "Focus Border Speed", range: 0.05...5, default: FocusBorderConfig.defaultSpeed, unit: "s", step: 0.05),
            .number(key: ZoneGestureConfig.minCreateDragScreenPointsKey, label: "Zone Creation Drag Threshold", range: 2...80, default: ZoneGestureConfig.defaultMinCreateDragScreenPoints, unit: "px", step: 1),
            .number(key: ZoneBoundsConfig.emptyMinWidthKey, label: "Empty Zone Minimum Width", range: 120...2_000, default: ZoneBoundsConfig.defaultEmptyMinWidth, unit: "pt", step: 8),
            .number(key: ZoneBoundsConfig.emptyMinHeightKey, label: "Empty Zone Minimum Height", range: 80...1_200, default: ZoneBoundsConfig.defaultEmptyMinHeight, unit: "pt", step: 8),
            .number(key: AutosaveConfig.debounceMsKey, label: "Autosave Debounce", range: 0...10_000, default: Double(AutosaveConfig.defaultDebounceMs), unit: "ms", step: 50),
            .number(key: IdleReaperConfig.inactivityThresholdKey, label: "Idle Reaper Threshold", range: 30...86_400, default: IdleReaperConfig.defaultInactivityThreshold, unit: "s", step: 30),
            .number(key: IdleReaperConfig.sweepIntervalKey, label: "Idle Reaper Sweep Interval", range: 5...3_600, default: IdleReaperConfig.defaultSweepInterval, unit: "s", step: 5),
            .number(key: ZoneHydrationReconcileConfig.intervalKey, label: "Zone Hydration Debounce", range: 0...10_000, default: Double(ZoneHydrationReconcileConfig.defaultIntervalMs), unit: "ms", step: 25),
            .number(key: SessionObserverConfig.debounceMsKey, label: "Agent Status Debounce", range: 0...10_000, default: Double(SessionObserverConfig.defaultDebounceMs), unit: "ms", step: 25),
            .number(key: SessionObserverConfig.maxChangesPerMinuteKey, label: "Agent Status Change Budget", range: 1...10_000, default: Double(SessionObserverConfig.defaultMaxChangesPerMinute), unit: "/ min", step: 1),
            .number(key: SessionObserverConfig.detectionPollSecondsKey, label: "Agent Detection Poll Interval", range: 0.1...300, default: Double(SessionObserverConfig.defaultDetectionPollSeconds), unit: "s", step: 0.1),
            .text(key: TmuxPersistenceConfig.pathKey, label: "tmux Path", default: TmuxPersistenceConfig.defaultPath),
            .number(key: TerminalScrollConfig.preciseMultiplierKey, label: "Precise Scroll Multiplier", range: 0.05...10, default: TerminalScrollConfig.preciseMultiplierDefault, unit: "×", step: 0.05),
            .number(key: TerminalScrollConfig.lineMultiplierKey, label: "Wheel Scroll Multiplier", range: 0.05...20, default: TerminalScrollConfig.lineMultiplierDefault, unit: "×", step: 0.1),
        ]
    }

    // MARK: - Bespoke rows

    /// A searchable row inside bespoke content: `anchor` is the id the rendered
    /// row carries, so search can scroll to it and the drift guard can find it.
    public struct CustomEntry: Equatable, Sendable {
        public let anchor: String
        public let label: String
        public let keywords: [String]
        public init(anchor: String, label: String, keywords: [String] = []) {
            self.anchor = anchor
            self.label = label
            self.keywords = keywords
        }
    }

    /// The rows each bespoke field renders, declared once so search and the
    /// renderer agree. An embedded AppKit editor exposes one anchor for all of its
    /// rows, since its insides are not individually scrollable.
    public static func customEntries(for field: SettingsField) -> [CustomEntry] {
        switch field {
        case .agentSounds:
            let sound = ["sound", "chime", "bell", "audio", "alert", "volume"]
            return [
                CustomEntry(anchor: "sounds.master", label: "Play agent sounds", keywords: sound + ["mute"]),
                CustomEntry(anchor: "sounds.volume", label: "Volume", keywords: sound),
            ] + AgentSignalKind.allCases.sorted(by: { $0.priority > $1.priority }).map { kind in
                CustomEntry(anchor: "sounds.kind.\(kind.rawValue)", label: "\(kind.displayName) sound", keywords: sound)
            } + [
                CustomEntry(anchor: "sounds.library", label: "Custom sounds", keywords: sound + ["import", "library"]),
            ]
        case .custom("harnessStatus", _):
            return AgentHarness.allCases.map { harness in
                CustomEntry(anchor: "harness.\(harness.rawValue)", label: harness.rawValue,
                            keywords: ["agent cli", "sign in", "login", "installed", "ready", "harness",
                                       "version", "update", "upgrade", "npm"])
            }
        case .custom("canvasBackground", _):
            // Rows that only appear in some states (a custom colour, grid spacing,
            // an image's opacity) are found through the row that is always there.
            let words = ["wallpaper", "canvas", "background"]
            return [
                CustomEntry(anchor: "canvasBackground.scope", label: "Canvas background", keywords: words + ["workspace", "global", "inherit"]),
                CustomEntry(anchor: "canvasBackground.pattern", label: "Grid pattern", keywords: words + ["dots", "lines", "grid colour", "grid color", "spacing"]),
                CustomEntry(anchor: "canvasBackground.base", label: "Canvas colour", keywords: words + ["base colour", "base color", "system"]),
                CustomEntry(anchor: "canvasBackground.image", label: "Background image", keywords: words + ["picture", "photo", "opacity", "fit", "fill"]),
                CustomEntry(anchor: "canvasBackground.reset", label: "Reset background", keywords: words),
            ]
        case .custom("companion", _):
            return [CustomEntry(anchor: "custom.companion", label: "Pair an iPhone",
                                keywords: ["companion", "invite", "relay", "pairing", "phone", "devices"])]
        case .shortcuts:
            return ShortcutCatalog.entries().map { entry in
                // The layer is a search word: "browser find" finds the Browser tile's Find.
                let layer: [String]
                switch entry.layer {
                case .global: layer = ["global", "everywhere"]
                case .navMode: layer = ["navigation", "nav mode"]
                case .inbox: layer = ["activity dock", "inbox"]
                case let .tile(kind): layer = [kind.rawValue, "tile"]
                }
                return CustomEntry(anchor: "shortcut.\(entry.id)", label: entry.label,
                                   keywords: ["shortcut", "keyboard", "hotkey"] + layer)
            }
        default:
            return []
        }
    }

    // MARK: - Registry bridge

    /// Metadata bridge while consumers migrate to `UserSettingsStore`. Every
    /// visible preference has a stable id; richer hand-authored definitions win.
    /// The retained tuning knobs stay registered: they left the UI, not the app.
    public static func registeredDefinitions() -> [AnySettingDefinition] {
        let typed = BuiltInSettingRegistry.all()
        var seen = Set(typed.map(\.id))
        var result = typed
        let tuning = SettingsSection(id: "advanced", title: "Advanced", fields: retainedTuningFields())
        for section in sections() + [tuning] {
            for field in section.fields {
                guard let key = field.key else { continue }
                // Categorised by what the setting IS, not the pane it sits in: the
                // navigation keys share the Keyboard pane with the shortcuts table
                // but are value settings of their own category.
                let category = key.hasPrefix("continuum.keymap.") ? .navigation : SettingsCategory(sectionID: section.id)
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
        // SessionObserver reads these three once, when it is constructed at launch.
        if [TmuxPersistenceConfig.pathKey, SessionObserverConfig.debounceMsKey, SessionObserverConfig.maxChangesPerMinuteKey, SessionObserverConfig.detectionPollSecondsKey].contains(key) { return .nextLaunch }
        return .live
    }
}

private extension SettingsCategory {
    init(sectionID: String) {
        switch sectionID {
        case "appearance", "editor": self = .appearance
        case "canvasAndZones": self = .canvasAndZones
        case "keybindings": self = .keybindings
        case "agents": self = .agents
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "activityAndNotifications", "companion": self = .activityAndNotifications
        case "advanced": self = .advanced
        default: self = .general
        }
    }
}
