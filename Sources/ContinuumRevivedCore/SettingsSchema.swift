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
            general(), appearance(), sidebar(), agentCharacters(), canvas(),
            agents(), editor(), terminal(), browser(),
            notificationsAndSounds(), keyboard(), iPhone(), usage(), advanced(),
        ]
    }

    // MARK: - Panes

    private static func general() -> SettingsSection {
        SettingsSection(id: "general", title: "General", iconSystemName: "gearshape", groups: [
            SettingsGroup(id: "general.closing", title: nil, rows: [
                SettingsRow(
                    .choice(key: DeleteConfirmPolicy.userDefaultsKey, label: "Confirm before closing a tile",
                            options: [DeleteConfirmPolicy.never.rawValue, DeleteConfirmPolicy.runtimes.rawValue, DeleteConfirmPolicy.always.rawValue],
                            default: DeleteConfirmPolicy.runtimes.rawValue,
                            titles: [
                                DeleteConfirmPolicy.never.rawValue: "Never",
                                DeleteConfirmPolicy.runtimes.rawValue: "Terminals and browsers",
                                DeleteConfirmPolicy.always.rawValue: "Every tile",
                            ]),
                    help: "Notes and files close straight away; their contents are saved on disk.",
                    keywords: ["delete", "confirm", "close", "warning", "ask", "switch", "off", "never"]),
            ]),
            SettingsGroup(id: "general.navigation", title: "Jumping and focusing", rows: [
                SettingsRow(.toggle(key: AgentJumpConfig.composerFirstKey, label: "Jump to an agent's composer", default: AgentJumpConfig.defaultComposerFirst),
                            help: "Jumping to an agent (jump labels, ⌘K) keeps a readable zoom and lands on its composer. When the tile is taller than the screen, its header stays pinned at the top.",
                            keywords: ["jump", "reveal", "focus", "composer", "sticky header", "zoom"]),
                SettingsRow(.toggle(key: TileHeaderClickConfig.focusKey, label: "Click a header to focus its tile", default: TileHeaderClickConfig.defaultFocus),
                            help: "Fits as much of the tile on screen as possible and puts the cursor in it, like ⌥↩. Dragging a header still moves the tile.",
                            keywords: ["header", "title bar", "click", "focus", "centre", "center", "fit", "zoom"]),
            ]),
            SettingsGroup(id: "general.updates", title: "Updates", rows: [
                SettingsRow(.choice(key: "array.updateChannel", label: "Update channel", options: ["Stable", "Tip"], default: "Stable",
                                    titles: ["Stable": "Stable", "Tip": "Early access"]),
                            help: "Early access includes prerelease updates.", keywords: ["sparkle", "beta", "tip", "prerelease"]),
                SettingsRow(.action(id: "checkForUpdates", label: "Software update", buttonTitle: "Check for Updates…"),
                            keywords: ["update", "upgrade", "version", "sparkle"]),
            ]),
        ])
    }

    private static func appearance() -> SettingsSection {
        SettingsSection(id: "appearance", title: "Appearance", iconSystemName: "paintbrush",
                        keywords: ["theme", "dark", "light", "look", "colour", "color"], groups: [
            SettingsGroup(id: "appearance.theme", title: nil, rows: [
                SettingsRow(.choice(key: AppTheme.defaultsKey, label: "App theme",
                                    options: AppTheme.allCases.map(\.rawValue),
                                    default: AppTheme.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AppTheme.allCases.map { ($0.rawValue, $0.title) })),
                            keywords: ["neutral", "palette", "grey", "gray", "black", "white"]),
                SettingsRow(.choice(key: CornerStyle.defaultsKey, label: "Corner style",
                                    options: CornerStyle.allCases.map(\.rawValue),
                                    default: CornerStyle.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: CornerStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Tiles, zones, menus, the command menu and Settings follow it right away.",
                            keywords: ["corners", "radius", "rounded", "sharp", "square", "bubbly", "roundness"]),
            ]),
            SettingsGroup(id: "appearance.canvasBackground", title: "Canvas background", rows: [
                SettingsRow(.custom(id: "canvasBackground", label: "Canvas background")),
            ]),
            SettingsGroup(id: "appearance.focus", title: "Focused tile outline", rows: [
                SettingsRow(.toggle(key: FocusBorderConfig.enabledKey, label: "Outline the focused tile", default: FocusBorderConfig.defaultEnabled),
                            keywords: ["focus border", "ring", "highlight"]),
                SettingsRow(.choice(key: FocusBorderConfig.colorKey, label: "Outline colour", options: FocusBorderConfig.colorOptions, default: FocusBorderConfig.defaultColor),
                            keywords: ["focus border", "color", "accent"]),
                SettingsRow(.number(key: FocusBorderConfig.gapKey, label: "Outline gap", range: 0...40, default: FocusBorderConfig.defaultGap, unit: "px", step: 1),
                            keywords: ["focus border", "spacing"]),
            ]),
            SettingsGroup(id: "appearance.commandMenu", title: "Command menu", rows: [
                SettingsRow(.choice(key: CommandCenterAppearanceConfig.glassinessKey, label: "Background", options: CommandCenterAppearanceConfig.options, default: CommandCenterAppearanceConfig.defaultGlassiness.rawValue),
                            keywords: ["command center", "palette", "glass", "blur", "frosted", "transparency"]),
                SettingsRow(.slider(key: CommandCenterAppearanceConfig.customOpacityKey, label: "Opacity", range: CommandCenterAppearanceConfig.customOpacityRange, default: CommandCenterAppearanceConfig.defaultCustomOpacity, visibleWhen: SettingsVisibility(key: CommandCenterAppearanceConfig.glassinessKey, equals: CommandCenterGlassiness.custom.rawValue), format: .percent),
                            keywords: ["command center", "palette", "transparency"]),
            ]),
        ])
    }

    /// The sidebar's own settings. Pane id is new; the rows keep their defaults
    /// keys, so saved values carry over from Appearance untouched. With the
    /// sidebar off, every row but its switch is hidden (`SettingsDependencies`).
    private static func sidebar() -> SettingsSection {
        SettingsSection(id: "sidebar", title: "Sidebar", iconSystemName: "sidebar.left",
                        keywords: ["sidebar", "activity dock", "dock", "inbox", "agents list", "list"], groups: [
            SettingsGroup(id: "sidebar.dock", title: nil, rows: [
                SettingsRow(.toggle(key: WorkspaceSidebarConfig.visibleKey, label: "Show the sidebar", default: WorkspaceSidebarConfig.defaultVisible),
                            help: "A list of every agent, what each is doing, and what needs you.",
                            keywords: ["sidebar", "inbox", "agents list", "activity dock", "dock"]),
                SettingsRow(.number(key: WorkspaceSidebarConfig.widthKey, label: "Sidebar width", range: 180...640, default: WorkspaceSidebarConfig.defaultWidth, unit: "pt", step: 8),
                            help: "You can also drag its edge.",
                            keywords: ["sidebar", "dock", "wide"]),
                SettingsRow(.choice(key: SidebarLayout.defaultsKey, label: "Layout",
                                    options: SidebarLayout.allCases.map(\.rawValue),
                                    default: SidebarLayout.defaultLayout.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: SidebarLayout.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Ledger is denser; Quiet inbox is calmer.",
                            keywords: ["sidebar", "layout", "ledger", "quiet", "inbox", "density"]),
            ]),
            SettingsGroup(id: "sidebar.highlight", title: "Highlight", rows: [
                SettingsRow(.choice(key: SidebarActiveIndicatorScope.defaultsKey, label: "Applies to",
                                    options: SidebarActiveIndicatorScope.allCases.map(\.rawValue),
                                    default: SidebarActiveIndicatorScope.fallback.rawValue,
                                    titles: [SidebarActiveIndicatorScope.selected.rawValue: "Open agent",
                                             SidebarActiveIndicatorScope.working.rawValue: "All working agents"]),
                            help: "Which agents get the highlight.",
                            keywords: ["sidebar", "highlight", "working", "lead", "selection", "active", "apply"]),
                SettingsRow(.choice(key: SidebarActiveIndicatorStyle.defaultsKey, label: "Highlight style",
                                    options: SidebarActiveIndicatorStyle.allCases.map(\.rawValue),
                                    default: SidebarActiveIndicatorStyle.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: SidebarActiveIndicatorStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "How the highlight looks.",
                            keywords: ["sidebar", "duplex", "gradient", "sheen", "classic", "selection", "motion", "active agent"]),
            ]),
            SettingsGroup(id: "sidebar.header", title: nil, rows: [
                SettingsRow(.choice(key: SidebarHeaderBackground.defaultsKey, label: "Header background",
                                    options: SidebarHeaderBackground.allCases.map(\.rawValue),
                                    default: SidebarHeaderBackground.fallback.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: SidebarHeaderBackground.allCases.map { ($0.rawValue, $0.title) })),
                            help: "A subtle static pattern behind the sidebar controls.",
                            keywords: ["sidebar", "header", "pattern", "background"]),
            ]),
        ])
    }

    // Plan 110: small characters beside each agent's provider mark. "Character"
    // is the animated figure; "badge" is the plate behind the provider mark.
    private static func agentCharacters() -> SettingsSection {
        SettingsSection(id: "agentCharacters", title: AgentCharacterCopy.feature, iconSystemName: "face.smiling",
                        keywords: ["icons", "icon packs", "characters", "sprites", "ducks", "mascot", "symbols"], groups: [
            SettingsGroup(id: "agentCharacters.display", title: nil, rows: [
                SettingsRow(.toggle(key: AgentCharacterConfig.enabledKey, label: "Show animated characters",
                                    default: AgentCharacterConfig.defaultEnabled),
                            help: "A small character beside each agent's provider mark acts out what the agent is doing.",
                            keywords: ["icons", "characters", "sprites", "ducks", "animation", "mascot", "agent icons"]),
                SettingsRow(.choice(key: AgentCharacterConfig.motionKey, label: "Animate while working",
                                    options: AgentCharacterConfig.Motion.allCases.map(\.rawValue),
                                    default: AgentCharacterConfig.defaultMotion.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentCharacterConfig.Motion.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Off keeps every character on a still pose. Resting agents always hold still.",
                            keywords: ["icons", "characters", "animation", "motion", "reduce motion", "still"]),
                SettingsRow(.choice(key: AgentCharacterConfig.sizeKey, label: "Character size",
                                    options: AgentCharacterConfig.Size.allCases.map(\.rawValue),
                                    default: AgentCharacterConfig.defaultSize.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentCharacterConfig.Size.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Larger characters make the sidebar row and the tile's title bar taller.",
                            keywords: ["icons", "characters", "size", "scale", "bigger", "larger", "icon size"]),
            ]),
            SettingsGroup(id: "agentCharacters.badge", title: "Tile badge", rows: [
                SettingsRow(.choice(key: AgentCharacterConfig.bubbleStyleKey, label: "Badge style",
                                    options: AgentCharacterConfig.BubbleStyle.allCases.map(\.rawValue),
                                    default: AgentCharacterConfig.defaultBubbleStyle.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentCharacterConfig.BubbleStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "The shape behind the provider mark in an agent tile's title.",
                            keywords: ["agent", "icon", "tile icon", "bubble", "orb", "inline", "squircle", "minimal", "glass", "badge"]),
                SettingsRow(.choice(key: AgentCharacterConfig.iconScaleKey, label: "Badge size",
                                    options: AgentCharacterConfig.IconScale.allCases.map(\.rawValue),
                                    default: AgentCharacterConfig.defaultIconScale.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentCharacterConfig.IconScale.allCases.map { ($0.rawValue, $0.title) })),
                            help: "For Squircle, Orb and Minimal. They shrink with the tile when zoomed out.",
                            keywords: ["agent", "icon", "tile icon size", "size", "small", "large", "bigger", "smaller", "bubble", "badge"]),
            ]),
            SettingsGroup(id: "agentCharacters.sets", title: AgentCharacterCopy.set, rows: [
                SettingsRow(.custom(id: "agentCharacters", label: AgentCharacterCopy.set),
                            keywords: ["icons", "icon packs", "characters", "character sets", "theme", "import", "ducks", "symbols"]),
            ]),
        ])
    }

    private static func canvas() -> SettingsSection {
        return SettingsSection(id: "canvasAndZones", title: "Canvas", iconSystemName: "square.grid.2x2", groups: [
            SettingsGroup(id: "canvas.layout", title: "Tiles", rows: [
                SettingsRow(.toggle(key: CanvasAutoLayoutConfig.enabledKey, label: "Arrange tiles automatically", default: CanvasAutoLayoutConfig.defaultEnabled),
                            help: "New zones keep their tiles tidy. Each zone can override this.",
                            keywords: ["auto layout", "tidy", "arrange"]),
                SettingsRow(.choice(key: CanvasAutoLayoutConfig.activationKey, label: "When you turn it on for a zone", options: CanvasAutoLayoutActivation.allCases.map(\.rawValue), default: CanvasAutoLayoutConfig.defaultActivation.rawValue,
                                    titles: [
                                        CanvasAutoLayoutActivation.immediately.rawValue: "Tidy now",
                                        CanvasAutoLayoutActivation.onFirstEdit.rawValue: "On next change",
                                    ]),
                            help: "Whether the tiles already in the zone are tidied right away or at its next change.",
                            keywords: ["auto layout", "tidy"]),
                SettingsRow(.choice(key: CanvasAutoLayoutConfig.growthKey, label: "New tiles grow the zone", options: CanvasGrowthDirection.allCases.map(\.rawValue), default: CanvasAutoLayoutConfig.defaultGrowth.rawValue,
                                    titles: [
                                        CanvasGrowthDirection.fan.rawValue: "Fan out",
                                        CanvasGrowthDirection.right.rawValue: "Right",
                                        CanvasGrowthDirection.down.rawValue: "Down",
                                    ]),
                            help: "Where a new tile goes, and where a lead's helpers open. Fan out follows the zone's shape.",
                            keywords: ["auto layout", "grow", "direction", "fan", "helpers", "right", "down", "downward"]),
                SettingsRow(.number(key: TileGapResolver.userDefaultsKey, label: "Space between tiles", range: 0...160, default: TileGapResolver.defaultGap, unit: "pt", step: 4),
                            help: "The gap kept between neighbouring tiles when they are arranged or snapped.",
                            keywords: ["gap", "spacing", "padding"]),
                SettingsRow(.toggle(key: DragMagnetizeConfig.enabledKey, label: "Snap tiles while dragging", default: DragMagnetizeConfig.defaultEnabled),
                            help: "Tiles you drag stick to the edges of nearby tiles.",
                            keywords: ["magnet", "snapping", "align"]),
            ]),
            SettingsGroup(id: "canvas.zones", title: "Zones", rows: [
                SettingsRow(.number(key: ZoneBoundsConfig.paddingKey, label: "Zone padding", range: 0...240, default: ZoneBoundsConfig.defaultPadding, unit: "pt", step: 4),
                            help: "The margin around the tiles when a new zone is laid out.",
                            keywords: ["spacing", "margin"]),
                SettingsRow(.toggle(key: ZoneChromeFeature.userDefaultsKey, label: "Show zone headers", default: true),
                            help: "Each zone gets a title bar and a border.",
                            keywords: ["zone chrome", "border", "title bar"]),
                SettingsRow(.text(key: DefaultGroupZoneName.userDefaultsKey, label: "New zone name", default: DefaultGroupZoneName.fallback),
                            help: "The name a zone gets when you create it. You can rename any zone.",
                            keywords: ["default name", "rename"]),
                SettingsRow(.choice(key: ZoneColorConfig.assignmentPolicyKey, label: "New zone colour", options: ZoneColorAssignmentPolicy.allCases.map(\.rawValue), default: ZoneColorConfig.defaultAssignmentPolicy.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: ZoneColorAssignmentPolicy.allCases.map { ($0.rawValue, $0.displayName) })),
                            help: "Used when a zone is created. A colour you pick is never changed.",
                            keywords: ["color", "palette"]),
            ]),
            SettingsGroup(id: "canvas.toolbar", title: "Toolbar", rows: [
                SettingsRow(.toggle(key: FloatingToolbarConfig.visibleKey, label: "Show the canvas toolbar", default: FloatingToolbarConfig.defaultVisible),
                            help: "The floating bar of create buttons on the canvas.",
                            keywords: ["floating toolbar", "create"]),
                SettingsRow(.custom(id: "toolbarButtons", label: "Toolbar buttons"),
                            help: "Choose which buttons the toolbar shows.",
                            keywords: ["toolbar", "button", "buttons"]),
                SettingsRow(.action(id: "resetToolbarPosition", label: "Toolbar position", buttonTitle: "Reset Position"),
                            keywords: ["toolbar", "edge", "move"]),
            ]),
            SettingsGroup(id: "canvas.hints", title: "On the canvas", rows: [
                SettingsRow(.toggle(key: CanvasShortcutRailConfig.visibleKey, label: "Show shortcut hints on the canvas", default: CanvasShortcutRailConfig.defaultVisible),
                            help: "A strip of key hints along the canvas edge.",
                            keywords: ["shortcut rail", "keyboard", "help"]),
                SettingsRow(.toggle(key: ResizeHUDConfig.enabledKey, label: "Show size while resizing", default: ResizeHUDConfig.defaultEnabled),
                            keywords: ["resize", "dimensions", "hud"]),
            ]),
        ])
    }

    private static func agents() -> SettingsSection {
        let managed = SettingsRequirement(key: AgentManagedModeConfig.enabledKey)
        let statusRow = AgentStatusElement.presentationOrder.filter { $0 != .contextMeter }.map { element in
            SettingsRow(.toggle(key: element.settingKey, label: element.title, default: element.defaultVisible),
                        keywords: element.isAccountScoped ? ["status", "quota", "usage", "account", "limits"] : ["status"])
        }
        return SettingsSection(id: "agents", title: "Agents", iconSystemName: "sparkles", sidebarHeading: tilesHeading,
                               keywords: ["ai", "assistant"], groups: [
            // Managed mode is one switch; the rows that steer it exist only while it is on.
            SettingsGroup(id: "agents.managedMode", title: nil,
                          footer: "Applies to Claude Code and Codex agents. A change takes effect at each agent's next turn, which re-reads its conversation at full price.", rows: [
                SettingsRow(.toggle(key: AgentManagedModeConfig.enabledKey, label: "Managed mode", default: true),
                            help: "A lead agent plans the work and hands pieces to helper agents.",
                            keywords: ["managed", "lead", "delegate", "helpers", "orchestrate", "opinionated"]),
                SettingsRow(.number(key: AgentSpawnLimitConfig.maximumActiveChildrenKey, label: "Limit helpers running at once",
                                    range: Double(AgentSpawnLimitConfig.supportedRange.lowerBound)...Double(AgentSpawnLimitConfig.supportedRange.upperBound),
                                    default: Double(AgentSpawnLimitConfig.defaultMaximumActiveChildren), unit: "helpers", step: 1),
                            help: "How many helpers one agent may run at the same time. Off means no limit.",
                            keywords: ["children", "sub-agents", "subagents", "spawn", "limit", "max", "helpers"],
                            showsWhen: managed,
                            optionalNumber: SettingsOptionalNumber(off: .double(0), onValue: .double(4), range: 1...16, unit: "helpers",
                                                                   singularUnit: "helper", sliderLabel: "Helpers at once")),
                SettingsRow(.toggle(key: AgentShortReportConfig.enabledKey, label: "Ask helpers for short reports",
                                    default: AgentShortReportConfig.enabledDefault),
                            help: "A helper's long final message is cut to a short report, and the rest is saved to a file.",
                            keywords: ["report", "summary", "subagents", "helpers", "delegate", "context", "short"], showsWhen: managed),
                SettingsRow(.toggle(key: HelperTileTidyConfig.enabledKey, label: "Tidy finished helper tiles",
                                    default: HelperTileTidyConfig.enabledDefault),
                            help: "Closes a helper's tile once its result has reached the lead; the agent stays in the sidebar.",
                            keywords: ["tidy", "close", "tiles", "subagents", "helpers", "delegate", "clean up", "finished"], showsWhen: managed),
                SettingsRow(.toggle(key: AgentManagedModeConfig.stallAlertsKey, label: "Helper stuck alerts", default: false),
                            help: "Quick tells the lead after about 3 minutes without progress; Patient waits 10.",
                            keywords: ["stalled", "stuck", "watchdog", "helper", "alert", "no progress", "patient", "quick"],
                            showsWhen: managed, toggleTitles: SettingsToggleTitles(off: "Patient", on: "Quick")),
                SettingsRow(.toggle(key: AgentManagedModeConfig.showIndicatorKey, label: "Show Managed indicator", default: true),
                            help: "Shows Managed beside the branch in agent tiles.",
                            keywords: ["managed", "badge", "indicator", "header"], showsWhen: managed),
            ]),
            // .plans/101: one login per CLI for the whole app, chosen here.
            SettingsGroup(id: "agents.accounts", title: "Accounts",
                          footer: "Every agent of a CLI uses the account in use. A switch lets running turns finish, then their next turn signs in as the new account. Each account signs in with the CLI's own login; Array never sees a password or token.", rows: [
                SettingsRow(.custom(id: "agentAccounts", label: "Accounts")),
            ]),
            SettingsGroup(id: "agents.clis", title: "Agent CLIs", rows: [
                SettingsRow(.custom(id: "harnessStatus", label: "Agent CLIs")),
                SettingsRow(.toggle(key: AgentCLIUpdateConfig.checksEnabledKey, label: "Check for agent CLI updates",
                                    default: AgentCLIUpdateConfig.checksEnabledDefault),
                            help: "Looks for newer versions at most once an hour. Updates only run when you click Update.",
                            keywords: ["update", "upgrade", "version", "cli", "npm", "homebrew"]),
            ]),
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
                                    titles: [
                                        WorkspaceToolsPermission.free.rawValue: "In their project",
                                        WorkspaceToolsPermission.askFirst.rawValue: "Ask first",
                                        WorkspaceToolsPermission.off.rawValue: "Off",
                                    ]),
                            help: "What an agent may do on the canvas without asking: act in its own project, ask before each kind of action, or get no workspace tools. Anything in another project still asks.",
                            keywords: ["workspace tools", "canvas api", "permissions", "approval", "orchestrate", "delegate", "message", "subagents", "free"],
                            segmented: true),
            ]),
            SettingsGroup(id: "agents.context", title: "Context",
                          footer: "Applies to every agent, Managed or not. Ask me first shows a button beside the composer and waits for you; Automatically compacts between turns. Agents a lead started have no composer to watch, so they compact automatically between turns while this is on.", rows: [
                SettingsRow(.choice(key: AgentContextAutoCompactionPolicy.modeKey, label: "Compact long conversations",
                                    options: AgentContextCompactionMode.allCases.map(\.rawValue),
                                    default: AgentContextAutoCompactionPolicy.defaultMode.rawValue,
                                    titles: ["ask": "Ask me first", "automatic": "Automatically", "never": "Off"]),
                            help: "Turn this off to never compact.",
                            keywords: ["compact", "compaction", "summarize", "context", "automatic", "ask", "warn", "stall", "long", "off", "never", "switch"]),
                SettingsRow(.choice(key: AgentContextAutoCompactionPolicy.compactAtKey, label: "Compact at",
                                    options: AgentContextAutoCompactionPolicy.options, default: AgentContextAutoCompactionPolicy.defaultOption,
                                    titles: Dictionary(uniqueKeysWithValues: AgentContextAutoCompactionPolicy.options.map { ($0, AgentContextAutoCompactionPolicy.sizeLabel(for: $0)) })),
                            help: "Long conversations cost more every turn. A small model window counts as long when it is 90% full, if that comes first.",
                            keywords: ["compact", "tokens", "threshold", "percent", "size", "context", "slider"]),
                SettingsRow(.toggle(key: AgentStatusElement.contextMeter.settingKey, label: "Show the context meter", default: AgentStatusElement.contextMeter.defaultVisible),
                            keywords: ["context meter", "status", "tokens"]),
            ]),
            SettingsGroup(id: "agents.instructions", title: "Agent instructions",
                          footer: "Claude Code agents already read your own Claude instructions, so they are left as they are. Array only reads your rules file; it never changes it.", rows: [
                SettingsRow(.toggle(key: ReplyStandard.enabledKey, label: "Give every agent Array's reply rules", default: false),
                            help: "Each time Array starts an agent, it adds its \(ReplyStandard.wordCount)-word rules for replies. Running agents keep what they started with.",
                            keywords: ["reply", "replies", "rules", "report", "answer", "instructions", "codex", "pi", "claude"]),
                SettingsRow(.toggle(key: PersonalRulesConfig.enabledKey, label: "Give Codex and Pi agents my rules", default: false),
                            help: "Each time Array starts a Codex or Pi agent, it adds the text of your rules file to that agent's instructions.",
                            keywords: ["rules", "instructions", "preferences", "commit", "codex", "pi", "agents.md", "claude.md"]),
                SettingsRow(.text(key: PersonalRulesConfig.pathKey, label: "Rules file", default: ""),
                            help: "The full path to a short text file you keep.",
                            keywords: ["rules", "instructions", "file", "path"],
                            showsWhen: SettingsRequirement(key: PersonalRulesConfig.enabledKey, defaultOn: false)),
            ]),
            SettingsGroup(id: "agents.identity", title: "Look",
                          footer: "Agents have no colour until you pick one from the tile's menu.", rows: [
                SettingsRow(.choice(key: AgentIdentityColorConfig.styleKey, label: "Agent colour shows as",
                                    options: AgentIdentityColorStyle.allCases.map(\.rawValue),
                                    default: AgentIdentityColorConfig.defaultStyle.rawValue,
                                    titles: Dictionary(uniqueKeysWithValues: AgentIdentityColorStyle.allCases.map { ($0.rawValue, $0.title) })),
                            help: "Where a tile shows its agent's colour.",
                            keywords: ["color", "colour", "identity", "tint", "border", "stripe"], segmented: true),
                SettingsRow(.toggle(key: AgentTerminalFaceConfig.showToggleKey, label: "Show Terminal toggle",
                                    default: AgentTerminalFaceConfig.defaultShowToggle),
                            help: "Adds a small icon to Claude Code tiles to switch between chat and Terminal.",
                            keywords: ["terminal", "chat", "toggle", "switch", "CLI", "title bar"]),
            ]),
            SettingsGroup(id: "agents.status", title: "Status row",
                          footer: "Applies to every agent tile. Account usage is per provider account, shared by every agent signed into it.",
                          rows: statusRow),
            SettingsGroup(id: "agents.dictation", title: "Composer",
                          footer: "Speech is transcribed on this Mac. No audio is kept or sent anywhere.", rows: [
                SettingsRow(.toggle(key: DictationConfig.enabledKey, label: "Dictate into the composer", default: DictationConfig.defaultEnabled),
                            help: "Shows a microphone button beside Send. Press ⇧⌘D to start or finish, Esc to discard.",
                            keywords: ["dictation", "voice", "speech", "microphone", "mic", "talk"]),
            ]),
            SettingsGroup(id: "agents.lifecycle", title: "Sessions", rows: [
                SettingsRow(.choice(key: AgentAutoSettleConfig.afterDaysKey, label: "Archive finished agents", options: AgentAutoSettleConfig.options, default: AgentAutoSettleConfig.defaultOption,
                                    titles: Dictionary(uniqueKeysWithValues: AgentAutoSettleConfig.options.map { option in
                                        guard let days = Int(option) else { return (option, "Never") }
                                        return (option, days == 1 ? "After 1 day" : "After \(days) days")
                                    })),
                            help: "Moves an agent that has sat idle out of the Activity Dock list.",
                            keywords: ["auto settle", "settle", "archive", "idle", "never"],
                            optionalNumber: SettingsOptionalNumber(off: .string(AgentAutoSettleConfig.offOption),
                                                                   onValue: .string(AgentAutoSettleConfig.defaultOption),
                                                                   range: Double(AgentAutoSettleConfig.dayOptions.first ?? 1)...Double(AgentAutoSettleConfig.dayOptions.last ?? 90),
                                                                   stops: AgentAutoSettleConfig.dayOptions.map(Double.init),
                                                                   unit: "days", singularUnit: "day", sliderLabel: "Archive after")),
                SettingsRow(.number(key: AgentIdleSessionConfig.minutesKey, label: "Stop idle sessions after", range: AgentIdleSessionConfig.supportedRange, default: AgentIdleSessionConfig.defaultMinutes, unit: "min", step: 1),
                            help: "Frees memory. Your next message resumes the conversation.",
                            keywords: ["idle", "memory", "hibernate", "session", "timeout", "reap"],
                            optionalNumber: SettingsOptionalNumber(off: nil, onValue: .double(AgentIdleSessionConfig.defaultMinutes),
                                                                   range: AgentIdleSessionConfig.supportedRange,
                                                                   stops: [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120], unit: "min",
                                                                   sliderLabel: "Stop idle sessions after")),
            ]),
            SettingsGroup(id: "agents.privacy", title: "Privacy", rows: [
                SettingsRow(.toggle(key: TranscriptShellCommandConfig.key, label: "Show shell commands in transcripts",
                                    default: TranscriptShellCommandConfig.defaultEnabled),
                            help: "Keeps the commands agents run on this Mac so transcript rows can show them. Never synced.",
                            keywords: ["privacy", "shell", "command", "bash", "history", "transcript"]),
            ]),
            SettingsGroup(id: "agents.tokenTelemetry", title: "Usage recording",
                          footer: "Kept on this Mac only. Never uploaded or synced.", rows: [
                SettingsRow(.toggle(key: AgentTokenTelemetryConfig.enabledKey, label: "Record token usage and command timing",
                                    default: AgentTokenTelemetryConfig.defaultEnabled),
                            help: "Counts task tokens by agent, model and type, and host-observed command timing when available. Turning it off stops new token and timing records and deletes nothing.",
                            keywords: ["usage", "tokens", "telemetry", "cost", "cache", "privacy"]),
            ]),
        ])
    }

    private static func editor() -> SettingsSection {
        SettingsSection(id: "editor", title: "Editor", iconSystemName: "curlybraces", sidebarHeading: tilesHeading,
                        keywords: ["code", "file"], groups: [
            SettingsGroup(id: "editor.appearance", title: "Text and editing", footer: "Applies to every editor tile right away.", rows: [
                SettingsRow(.choice(key: EditorPreferences.appearanceKey, label: "Appearance", options: EditorAppearance.allCases.map(\.rawValue), default: EditorAppearance.system.rawValue,
                                    titles: [
                                        EditorAppearance.system.rawValue: "Match System",
                                        EditorAppearance.light.rawValue: "Light",
                                        EditorAppearance.dark.rawValue: "Dark",
                                    ]),
                            keywords: ["theme"], segmented: true),
                SettingsRow(.text(key: EditorPreferences.fontFamilyKey, label: "Font", default: EditorPreferences.defaultFontFamily),
                            keywords: ["font family", "typeface", "monospace"]),
                SettingsRow(.number(key: EditorPreferences.fontSizeKey, label: "Font size", range: EditorPreferences.fontSizeRange, default: EditorPreferences.defaultFontSize, unit: "pt", step: 1),
                            keywords: ["text size"],
                            optionalNumber: SettingsOptionalNumber(off: nil, onValue: .double(EditorPreferences.defaultFontSize), range: EditorPreferences.fontSizeRange, unit: "pt", sliderLabel: "Font size")),
                SettingsRow(.number(key: EditorPreferences.lineHeightKey, label: "Line height", range: EditorPreferences.lineHeightRange, default: EditorPreferences.defaultLineHeight, unit: "×", step: 0.1),
                            keywords: ["spacing"],
                            optionalNumber: SettingsOptionalNumber(off: nil, onValue: .double(EditorPreferences.defaultLineHeight), range: EditorPreferences.lineHeightRange, step: 0.1, unit: "×", sliderLabel: "Line height")),
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
        let keepRunning = SettingsRequirement(key: TmuxPersistenceConfig.enabledKey, defaultOn: TmuxPersistenceConfig.defaultEnabled)
        let scrollback = SettingsRequirement(key: SessionResumeConfig.scrollbackEnabledKey, defaultOn: SessionResumeConfig.scrollbackEnabledDefault)
        return SettingsSection(id: "terminal", title: "Terminal", iconSystemName: "terminal", sidebarHeading: tilesHeading,
                        keywords: ["shell", "console"], groups: [
            SettingsGroup(id: "terminal.display", title: "Display", footer: "Applies to new terminals.", rows: [
                SettingsRow(.number(key: TerminalDisplayConfig.fontSizeKey, label: "Use my own font size", range: 0...48, default: TerminalDisplayConfig.defaultFontSize, unit: "pt", step: 1),
                            help: "Off: terminals use the font size from your Ghostty configuration.",
                            keywords: ["text size", "font size", "ghostty"],
                            optionalNumber: SettingsOptionalNumber(off: .double(0), onValue: .double(TerminalDisplayConfig.defaultFontSize),
                                                                   range: TerminalDisplayConfig.minFontSize...TerminalDisplayConfig.maxFontSize,
                                                                   unit: "pt", sliderLabel: "Font size")),
            ]),
            SettingsGroup(id: "terminal.sessions", title: "Sessions", footer: "Applies to new terminals.", rows: [
                SettingsRow(.toggle(key: TmuxPersistenceConfig.enabledKey, label: "Keep shells running when Array quits", default: TmuxPersistenceConfig.defaultEnabled),
                            help: "A terminal comes back where you left it.",
                            keywords: ["tmux", "persist", "restore"]),
                SettingsRow(.toggle(key: TmuxPersistenceConfig.ambientPerWorkspaceKey, label: "Share one session outside zones", default: TmuxPersistenceConfig.ambientPerWorkspaceDefault),
                            help: "Terminals that are not in a zone share one session per workspace.",
                            keywords: ["tmux", "unzoned"], showsWhen: keepRunning),
                SettingsRow(.toggle(key: SessionResumeConfig.scrollbackEnabledKey, label: "Restore scrollback", default: SessionResumeConfig.scrollbackEnabledDefault),
                            help: "A terminal that comes back after a restart shows what was on screen before.",
                            keywords: ["history", "resume"]),
                SettingsRow(.number(key: SessionResumeConfig.scrollbackMaxLinesKey, label: "Lines to restore", range: 0...100_000, default: Double(SessionResumeConfig.scrollbackMaxLinesDefault), unit: "lines", step: 500),
                            help: "How much history comes back with a restored terminal.",
                            keywords: ["scrollback", "history"], showsWhen: scrollback,
                            optionalNumber: SettingsOptionalNumber(off: nil, onValue: .double(Double(SessionResumeConfig.scrollbackMaxLinesDefault)),
                                                                   range: 500...20_000, step: 500, unit: "lines", sliderLabel: "Lines to restore")),
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
                            help: "The page a new browser tile starts on.",
                            keywords: ["home page", "default url", "start page"]),
                SettingsRow(.toggle(key: BrowserWebInspectorConfig.userDefaultsKey, label: "Allow Safari Web Inspector", default: BrowserWebInspectorConfig.defaultEnabled),
                            help: "Lets you inspect browser tiles from Safari's Develop menu.",
                            keywords: ["devtools", "developer", "inspect", "debug"]),
            ]),
        ])
    }

    private static func notificationsAndSounds() -> SettingsSection {
        SettingsSection(id: "activityAndNotifications", title: "Notifications & Sounds", iconSystemName: "bell.badge",
                        keywords: ["alerts", "audio"], groups: [
            SettingsGroup(id: "sounds", title: "Agent sounds", rows: [
                SettingsRow(.agentSounds(label: "Agent sounds")),
            ]),
        ])
    }

    private static func keyboard() -> SettingsSection {
        SettingsSection(id: "keybindings", title: "Keyboard", iconSystemName: "keyboard",
                        keywords: ["keys", "hotkeys", "keybindings"], groups: [
            SettingsGroup(id: "keyboard.navigation", title: "Navigation", rows: [
                SettingsRow(.choice(key: NavKeymap.leaderHoldDefaultsKey, label: "Hold to navigate", options: NavKeymap.leaderHoldModifierOptions, default: NavKeymap.modifierToken(NavKeymap.default.leaderHoldModifier),
                                    titles: ["opt": "⌥ Option", "ctrl": "⌃ Control", "cmd": "⌘ Command", "shift": "⇧ Shift"]),
                            help: "Hold this key to label every tile and zone, then press a label to jump there.",
                            keywords: ["leader", "modifier", "jump", "labels"]),
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

    /// `.plans/116` part 21: how Array did the work on this Mac, read from the
    /// run ledger. One bespoke group; the page records nothing.
    private static func usage() -> SettingsSection {
        SettingsSection(id: "usage", title: "Usage", iconSystemName: "chart.bar",
                        keywords: ["usage", "tokens", "metrics", "tasks", "helpers", "time"], groups: [
            SettingsGroup(id: "usage.report", title: nil, rows: [
                SettingsRow(.custom(id: "usage", label: "Usage on this Mac"),
                            keywords: ["tokens", "cache", "tasks", "helpers", "time", "metrics"]),
            ]),
        ])
    }

    private static func advanced() -> SettingsSection {
        SettingsSection(id: "advanced", title: "Advanced", iconSystemName: "wrench.and.screwdriver",
                        keywords: ["performance", "memory"], groups: [
            SettingsGroup(id: "advanced.limits", title: "Memory limits",
                          footer: "Lower limits use less memory; tiles beyond them reload when you return.", rows: [
                SettingsRow(.number(key: BrowserRuntimeBudget.defaultsKey, label: "Live web pages", range: 1...128, default: Double(BrowserRuntimeBudget.defaultMaxLive), unit: "pages", step: 1),
                            help: "How many browser tiles keep their page loaded at once.",
                            keywords: ["browser", "webview", "budget", "max"]),
                SettingsRow(.number(key: ZoneHydrationBudgetConfig.maxLiveZonesKey, label: "Live zones", range: 1...64, default: Double(ZoneHydrationBudgetConfig.defaultMaxLiveZones), unit: "zones", step: 1),
                            help: "How many zones keep their tiles running at once. Tiles in other zones reload when you return.",
                            keywords: ["hydration", "budget", "max"]),
                SettingsRow(.toggle(key: ZoneRuntimeBudgetConfig.closeOnZeroKey, label: "Close a project's terminals and pages when it has no zones", default: ZoneRuntimeBudgetConfig.defaultCloseOnZero),
                            help: "Frees the terminals and web pages of a project with no zone on the canvas. Off keeps them warm, so coming back is faster but uses more memory.",
                            keywords: ["memory", "unused"]),
                SettingsRow(.toggle(key: IOSPreviewReclaimConfig.enabledKey, label: "Shut down simulators no preview is showing", default: IOSPreviewReclaimConfig.defaultEnabled),
                            help: "Only simulators Array started. Each one holds 2–3 GB. After 2 minutes with its preview off screen or closed, Array shuts it down, and starts it again when the preview comes back.",
                            keywords: ["ios", "simulator", "memory", "shutdown", "preview"]),
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
                CustomEntry(anchor: "sounds.characters", label: AgentCharacterCopy.sounds,
                            keywords: sound + ["icons", "characters", "ducks", "quack", "voices", "duckherd"]),
                CustomEntry(anchor: "sounds.library", label: "Custom sounds", keywords: sound + ["import", "library"]),
            ]
        case .custom("harnessStatus", _):
            return AgentHarness.allCases.map { harness in
                CustomEntry(anchor: "harness.\(harness.rawValue)", label: harness.rawValue,
                            keywords: ["agent cli", "sign in", "login", "installed", "ready", "harness",
                                       "version", "update", "upgrade", "npm"])
            }
        case .custom("agentAccounts", _):
            return [
                CustomEntry(anchor: "agentAccounts.list", label: "Accounts",
                            keywords: ["account", "accounts", "personal", "work", "team", "max", "plan", "switch",
                                       "login", "sign in", "subscription", "claude", "codex", "usage", "limit"]),
            ]
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
        case .custom("toolbarButtons", _):
            return CommandRegistry.definitions().compactMap { definition in
                guard let item = definition.floatingToolbarItem else { return nil }
                return CustomEntry(anchor: "custom.toolbarButtons", label: "Show \(item.title) button", keywords: ["toolbar", "button"])
            }
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
