import ContinuumRevivedCore
import Foundation

/// The settings schema: pane order and ids, field binding and bounds, plain-word
/// choice titles, and the search registry built from it. A standalone arm
/// (`--settings-schema-check`) as well as part of the bare run, because the bare
/// run is KNOWN-RED and nothing inside it reaches the matrix.
func runSettingsSchemaChecks() {
    let sections = SettingsSchema.sections()
    // Rendered fields plus the tuning knobs that left the UI but kept their keys:
    // both must stay unique, bound, and bounded.
    let tuningFields = SettingsSchema.retainedTuningFields()
    let allFields = sections.flatMap(\.fields) + tuningFields

    expect(
        sections.map(\.title) == [
            "General", "Appearance", "Canvas", "Agents", "Editor", "Terminal", "Browser",
            "Notifications & Sounds", "Keyboard", "iPhone", "Advanced",
        ],
        "settings exposes the eleven product panes in stable order, got \(sections.map(\.title))"
    )
    // Pane ids are what the app and these checks look panes up by: retitled, never renamed.
    expect(
        sections.map(\.id) == [
            "general", "appearance", "canvasAndZones", "agents", "editor", "terminal", "browser",
            "activityAndNotifications", "keybindings", "companion", "advanced",
        ],
        "settings pane ids must be stable and ordered, got \(sections.map(\.id))"
    )
    // The Tiles heading sits over one contiguous run: Agents, Editor, Terminal, Browser.
    expect(
        sections.map { $0.sidebarHeading == SettingsSchema.tilesHeading } == [
            false, false, false, true, true, true, true, false, false, false, false,
        ],
        "the Tiles sidebar heading must cover exactly Agents, Editor, Terminal and Browser"
    )
    let renderedKeys = Set(sections.flatMap(\.fields).compactMap(\.key))
    for field in tuningFields {
        expect(!renderedKeys.contains(field.key ?? ""), "tuning knob \(field.key ?? field.label) left the UI and must not render")
    }

    // Structural invariants: non-empty ids/labels/titles, no duplicate keys.
    for section in sections {
        expect(!section.id.isEmpty, "settings section id must be non-empty")
        expect(!section.title.isEmpty, "settings section title must be non-empty")
        for field in section.fields {
            expect(!field.label.isEmpty, "settings field label must be non-empty")
        }
    }
    let fieldKeys = allFields.compactMap(\.key)
    expect(Set(fieldKeys).count == fieldKeys.count, "settings field keys must be unique across all sections")

    // Existing prefs represented: the schema must bind each of these exact keys.
    let expectedKeys: Set<String> = [
        AgentManagedModeConfig.enabledKey,
        AgentManagedModeConfig.showIndicatorKey,
        ZoneChromeFeature.userDefaultsKey,
        DeleteConfirmPolicy.userDefaultsKey,
        DefaultBrowserURL.userDefaultsKey,
        TileGapResolver.userDefaultsKey,
        FocusBorderConfig.enabledKey,
        FocusBorderConfig.colorKey,
        FocusBorderConfig.gapKey,
        FocusBorderConfig.speedKey,
        DragMagnetizeConfig.enabledKey,
        ZoneHydrationBudgetConfig.maxLiveZonesKey,
        ZoneHydrationReconcileConfig.intervalKey,
        BrowserRuntimeBudget.defaultsKey,
        DefaultGroupZoneName.userDefaultsKey,
        AutosaveConfig.debounceMsKey,
        ZoneGestureConfig.minCreateDragScreenPointsKey,
        TmuxPersistenceConfig.enabledKey,
        TmuxPersistenceConfig.pathKey,
        TerminalDisplayConfig.fontSizeKey,
        TerminalScrollConfig.preciseMultiplierKey,
        TerminalScrollConfig.lineMultiplierKey,
        WorkspaceSidebarConfig.visibleKey,
        WorkspaceSidebarConfig.widthKey,
        AgentModelConfig.modelKey,
        AgentModelConfig.thinkingKey,
        // WorkspaceProfileConfig.defaultCaptureModeKey and defaultApplyModeKey are
        // intentionally excluded: captureMode/applyMode have no behavioral effect yet
        // (WorkspaceDocument is layout-only; T13 session-state is in ProjectStore sibling
        // stores). Settings entries will be added when the session-state bridge lands.
    ]
    expect(expectedKeys.isSubset(of: Set(fieldKeys)), "settings schema must represent every existing pref key")
    expect(!fieldKeys.contains("continuum.ambientZoneHome"), "Ambient Zone Home is no longer a global setting")

    // Drag snapping resolver: default-true on empty defaults, reads an override.
    let dragSuiteName = "DragMagnetizeChecks-\(UUID().uuidString)"
    let dragDefaults = UserDefaults(suiteName: dragSuiteName)!
    defer { dragDefaults.removePersistentDomain(forName: dragSuiteName) }
    dragDefaults.removePersistentDomain(forName: dragSuiteName)
    expect(DragMagnetizeConfig.enabled(defaults: dragDefaults) == true, "drag magnetize defaults to enabled")
    dragDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
    expect(DragMagnetizeConfig.enabled(defaults: dragDefaults) == false, "drag magnetize reads a disabled override")

    // ZoneHydrationReconcileConfig resolver round-trip.
    let reconcileSuiteName = "ZoneHydrationReconcileConfigChecks-\(UUID().uuidString)"
    let reconcileDefaults = UserDefaults(suiteName: reconcileSuiteName)!
    defer { reconcileDefaults.removePersistentDomain(forName: reconcileSuiteName) }
    reconcileDefaults.removePersistentDomain(forName: reconcileSuiteName)
    expect(ZoneHydrationReconcileConfig.intervalMs(defaults: reconcileDefaults) == ZoneHydrationReconcileConfig.defaultIntervalMs, "reconcile debounce: empty defaults returns 200")
    reconcileDefaults.set("50", forKey: ZoneHydrationReconcileConfig.intervalKey)
    expect(ZoneHydrationReconcileConfig.intervalMs(defaults: reconcileDefaults) == 50, "reconcile debounce: string override '50' reads back 50")

    // AutosaveConfig resolver: default / clamp-low / clamp-high / non-numeric → default.
    let autosaveSuiteName = "AutosaveConfigChecks-\(UUID().uuidString)"
    let autosaveDefaults = UserDefaults(suiteName: autosaveSuiteName)!
    defer { autosaveDefaults.removePersistentDomain(forName: autosaveSuiteName) }
    autosaveDefaults.removePersistentDomain(forName: autosaveSuiteName)
    expect(AutosaveConfig.debounceMs(defaults: autosaveDefaults) == 200, "autosave debounce: empty defaults returns 200")
    autosaveDefaults.set("750", forKey: AutosaveConfig.debounceMsKey)
    expect(AutosaveConfig.debounceMs(defaults: autosaveDefaults) == 750, "autosave debounce: '750' reads back 750")
    autosaveDefaults.set("-5", forKey: AutosaveConfig.debounceMsKey)
    expect(AutosaveConfig.debounceMs(defaults: autosaveDefaults) == AutosaveConfig.minDebounceMs, "autosave debounce: '-5' clamps to min (\(AutosaveConfig.minDebounceMs))")
    autosaveDefaults.set("99999", forKey: AutosaveConfig.debounceMsKey)
    expect(AutosaveConfig.debounceMs(defaults: autosaveDefaults) == AutosaveConfig.maxDebounceMs, "autosave debounce: '99999' clamps to max (\(AutosaveConfig.maxDebounceMs))")
    autosaveDefaults.set("abc", forKey: AutosaveConfig.debounceMsKey)
    expect(AutosaveConfig.debounceMs(defaults: autosaveDefaults) == 200, "autosave debounce: 'abc' non-numeric falls back to 200")

    // ZoneGestureConfig resolver: empty defaults → 24; override 40 → 40; override 0 or negative → 24.
    let zoneGestureSuiteName = "ZoneGestureConfigChecks-\(UUID().uuidString)"
    let zoneGestureDefaults = UserDefaults(suiteName: zoneGestureSuiteName)!
    defer { zoneGestureDefaults.removePersistentDomain(forName: zoneGestureSuiteName) }
    zoneGestureDefaults.removePersistentDomain(forName: zoneGestureSuiteName)
    expect(ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults) == 24, "zoneGestureConfig: absent key returns 24")
    zoneGestureDefaults.set(40.0, forKey: ZoneGestureConfig.minCreateDragScreenPointsKey)
    expect(ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults) == 40, "zoneGestureConfig: override 40 returns 40")
    zoneGestureDefaults.set(0.0, forKey: ZoneGestureConfig.minCreateDragScreenPointsKey)
    expect(ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults) == 24, "zoneGestureConfig: override 0 falls back to 24")
    zoneGestureDefaults.set(-5.0, forKey: ZoneGestureConfig.minCreateDragScreenPointsKey)
    expect(ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults) == 24, "zoneGestureConfig: negative override falls back to 24")

    // The Keybindings section renders the ShortcutCatalog via a .shortcuts field.
    expect(allFields.contains { if case .shortcuts = $0 { return true } else { return false } }, "settings schema must include a .shortcuts field")

    guard let generalSection = sections.first(where: { $0.id == "general" }),
          let soundsSection = sections.first(where: { $0.id == "activityAndNotifications" }) else {
        expect(false, "settings schema must include General and Notifications & Sounds")
        fatalError("unreachable")
    }
    expect(soundsSection.title == "Notifications & Sounds", "Notifications & Sounds pane title")
    expect(soundsSection.fields.contains { if case .agentSounds = $0 { return true } else { return false } }, "Notifications & Sounds renders the sounds editor")
    expect(generalSection.fields.contains { $0.key == WorkspaceSidebarConfig.visibleKey }, "General exposes Activity Dock visibility")
    expect(generalSection.fields.contains { $0.key == WorkspaceSidebarConfig.widthKey }, "General exposes Activity Dock width")

    let sidebarSuiteName = "WorkspaceSidebarConfigChecks-\(UUID().uuidString)"
    let sidebarDefaults = UserDefaults(suiteName: sidebarSuiteName)!
    defer { sidebarDefaults.removePersistentDomain(forName: sidebarSuiteName) }
    sidebarDefaults.removePersistentDomain(forName: sidebarSuiteName)
    expect(WorkspaceSidebarConfig.resolveVisible(defaults: sidebarDefaults) == true, "workspace sidebar defaults visible")
    expect(WorkspaceSidebarConfig.resolveWidth(defaults: sidebarDefaults) == 280.0, "workspace sidebar default width")
    WorkspaceSidebarConfig.setVisible(false, defaults: sidebarDefaults)
    expect(WorkspaceSidebarConfig.resolveVisible(defaults: sidebarDefaults) == false, "workspace sidebar visible round-trips false")
    WorkspaceSidebarConfig.setWidth(350, defaults: sidebarDefaults)
    expect(WorkspaceSidebarConfig.resolveWidth(defaults: sidebarDefaults) == 350.0, "workspace sidebar width round-trips in-range value")
    WorkspaceSidebarConfig.setWidth(100, defaults: sidebarDefaults)
    expect(WorkspaceSidebarConfig.resolveWidth(defaults: sidebarDefaults) == 220.0, "workspace sidebar width clamps to floor")
    WorkspaceSidebarConfig.setWidth(520, defaults: sidebarDefaults)
    expect(WorkspaceSidebarConfig.resolveWidth(defaults: sidebarDefaults) == 520.0, "workspace sidebar persists a width above the legacy ceiling for the window-derived live clamp")
    sidebarDefaults.set("320", forKey: WorkspaceSidebarConfig.widthKey)
    expect(WorkspaceSidebarConfig.resolveWidth(defaults: sidebarDefaults) == 320.0, "workspace sidebar width accepts Settings text-field numeric string")

    // Per-field UserDefaults behavior in a suite that answers only from itself. A
    // plain suite reads the global domain as a fallback, which this used to scrub
    // by rewriting every app's shared preferences (mirrors the delete-policy check).
    let suiteName = "SettingsSchemaChecks-\(UUID().uuidString)"
    let defaults = QAIsolatedDefaults(isolatedSuiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    for field in allFields {
        switch field {
        case .info:
            expect(field.currentValue(in: defaults) == nil, ".info field has no bound value")
            field.setValue(.string("ignored"), in: defaults)
            expect(field.currentValue(in: defaults) == nil, ".info setValue is a no-op")
        case .shortcuts, .agentSounds, .action, .custom:
            expect(field.currentValue(in: defaults) == nil, "rich settings field has no directly bound value")
        case .toggle(_, _, let fallback):
            expect(field.currentValue(in: defaults) == .bool(fallback), "toggle currentValue on empty defaults is its declared default")
            field.setValue(.bool(!fallback), in: defaults)
            expect(field.currentValue(in: defaults) == .bool(!fallback), "toggle round-trips through setValue/currentValue")
        case .text(_, _, let fallback):
            expect(field.currentValue(in: defaults) == .string(fallback), "text currentValue on empty defaults is its declared default")
            field.setValue(.string("\(fallback)-edited"), in: defaults)
            expect(field.currentValue(in: defaults) == .string("\(fallback)-edited"), "text round-trips through setValue/currentValue")
        case .url(let key, _, let fallback):
            expect(field.currentValue(in: defaults) == .string(fallback), "URL currentValue on empty defaults is its declared default")
            let valid = "https://example.com/settings-check"
            field.setValue(.string(valid), in: defaults)
            expect(field.currentValue(in: defaults) == .string(valid), "URL round-trips a valid absolute URL")
            field.setValue(.string("not a URL"), in: defaults)
            expect(defaults.string(forKey: key) == valid, "invalid URL remains unpersisted for inline validation")
        case .directory(_, _, let fallback):
            expect(field.currentValue(in: defaults) == .string(fallback), "directory currentValue on empty defaults is its declared default")
            field.setValue(.string("/tmp"), in: defaults)
            expect(field.currentValue(in: defaults) == .string("/tmp"), "directory picker values round-trip")
        case .number(let key, _, let range, let fallback, _, _):
            expect(field.currentValue(in: defaults) == .double(fallback), "number currentValue on empty defaults is its declared default")
            field.setValue(.double(range.upperBound + 1), in: defaults)
            expect(field.currentValue(in: defaults) == .double(range.upperBound), "number controls clamp values to their declared range")
            expect(defaults.double(forKey: key) == range.upperBound, "number controls persist the bounded value")
        case .choice(let key, _, let options, let fallback, _):
            expect(field.currentValue(in: defaults) == .string(fallback), "choice currentValue on empty defaults is its declared default")
            let valid = options.first { $0 != fallback } ?? fallback
            field.setValue(.string(valid), in: defaults)
            expect(field.currentValue(in: defaults) == .string(valid), "choice round-trips a valid option")
            field.setValue(.string("not-a-valid-option"), in: defaults)
            expect(field.currentValue(in: defaults) == .string(fallback), "choice rejects an invalid value, falling back to default")
            expect(defaults.string(forKey: key) == fallback, "choice persists the fallback when given an invalid value")
        case .slider(let key, _, let range, let fallback, _, _):
            expect(field.currentValue(in: defaults) == .double(fallback), "slider currentValue on empty defaults is its declared default")
            field.setValue(.double(range.upperBound + 1), in: defaults)
            expect(field.currentValue(in: defaults) == .double(range.upperBound), "slider clamps values to its declared range")
            expect(defaults.double(forKey: key) == range.upperBound, "slider persists its bounded numeric value")
        }
    }

    // The zone-chrome toggle, written through the schema, is observed by the real
    // resolver in the same isolated suite.
    let chromeSuiteName = "SettingsSchemaChecks-chrome-\(UUID().uuidString)"
    let chromeDefaults = UserDefaults(suiteName: chromeSuiteName)!
    defer { chromeDefaults.removePersistentDomain(forName: chromeSuiteName) }
    chromeDefaults.removePersistentDomain(forName: chromeSuiteName)
    let chromeField = allFields.first { $0.key == ZoneChromeFeature.userDefaultsKey }!
    chromeField.setValue(.bool(false), in: chromeDefaults)
    expect(
        ZoneChromeFeature.resolvedFromDefaults(standardDefaults: chromeDefaults, legacyDefaults: nil).isEnabled == false,
        "zone-chrome field written through the schema is observed by ZoneChromeFeature.resolvedFromDefaults"
    )

    runSettingsPlainWordsChecks(sections: sections)
    runSettingsRegistrySearchChecks(sections: sections)
}

/// Every choice a person can open shows words, never a stored value. The model
/// picker is exempt: its titles are the live catalogue's display names.
private func runSettingsPlainWordsChecks(sections: [SettingsSection]) {
    func isPlainWords(_ value: String) -> Bool {
        // A leading key glyph ("⌥ Option") is words; a leading digit is a value.
        let trimmed = value.unicodeScalars.drop { CharacterSet.symbols.contains($0) || CharacterSet.whitespaces.contains($0) }
        guard let first = trimmed.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        // A lower-to-upper hump inside a word is an identifier ("inheritFocus").
        var previousWasLower = false
        for scalar in value.unicodeScalars {
            let upper = CharacterSet.uppercaseLetters.contains(scalar)
            if upper && previousWasLower { return false }
            previousWasLower = CharacterSet.lowercaseLetters.contains(scalar)
        }
        return true
    }
    expect(!isPlainWords("inheritFocus") && !isPlainWords("opt") && !isPlainWords("3") && isPlainWords("Claude Code") && isPlainWords("⌥ Option"),
           "plain-words classifier must reject identifiers and digits and accept titles")
    var choices = 0
    for section in sections {
        for field in section.fields {
            guard case let .choice(key, label, options, _, _) = field, key != AgentModelConfig.modelKey else { continue }
            choices += 1
            for option in options {
                let shown = field.displayTitle(forOption: option)
                expect(isPlainWords(shown), "\(section.title) ▸ \(label) shows the stored value '\(shown)' for option '\(option)'; give it a title")
            }
        }
        for row in section.rows {
            let label = row.field.label
            for jargon in ["(0 =", "Harness", "Chrome", "Debounce", "Multiplier"] {
                expect(!label.contains(jargon), "\(section.title) ▸ '\(label)' uses jargon '\(jargon)'")
            }
            if case let .number(_, _, range, _, unit, _) = row.field {
                expect(!unit.contains("="), "\(section.title) ▸ \(label): a number's meaning at 0 belongs in zeroTitle, not its unit")
                if row.zeroTitle != nil { expect(range.contains(0), "\(label): zeroTitle on a range without 0") }
            }
        }
    }
    expect(choices >= 10, "expected every settings choice to be checked, saw \(choices)")
    let terminalFont = sections.first { $0.id == "terminal" }?.rows.first { $0.field.key == TerminalDisplayConfig.fontSizeKey }
    expect(terminalFont?.zeroTitle == "Default", "terminal font size at 0 must read Default")
}

/// The registry both search and rendering read, and the word-prefix search over it.
private func runSettingsRegistrySearchChecks(sections: [SettingsSection]) {
    let suiteName = "SettingsRegistryChecks-\(UUID().uuidString)"
    let defaults = QAIsolatedDefaults(isolatedSuiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let entries = SettingsRegistry.entries(sections: sections, defaults: defaults)
    let ids = entries.map(\.id)
    expect(Set(ids).count == ids.count, "settings registry entry ids must be unique")
    for section in sections {
        expect(entries.contains { $0.id == "pane.\(section.id)" }, "registry must hold a pane entry for \(section.id)")
    }
    // Every keyed, rendered field is an entry anchored on its key.
    for field in sections.flatMap(\.fields) {
        guard let key = field.key else { continue }
        if case .slider = field, !field.isVisible(in: defaults) { continue }
        expect(entries.contains { $0.anchor == "field.\(key)" }, "registry is missing the row for \(key)")
    }
    // A conditional row exists only while its condition holds.
    expect(!entries.contains { $0.anchor == "field.\(CommandCenterAppearanceConfig.customOpacityKey)" },
           "the custom opacity row must not be searchable while Frosted is chosen")

    expect(AgentManagedModeConfig.enabled(defaults: defaults) && AgentManagedModeConfig.showIndicator(defaults: defaults),
           "Managed mode and indicator must default on")
    func search(_ query: String) -> [SettingsSearch.Result] { SettingsSearch.search(query, in: entries) }
    func has(_ query: String, _ predicate: (SettingsEntry) -> Bool) -> Bool { search(query).contains { predicate($0.entry) } }

    expect(has("managed") { $0.field?.key == AgentManagedModeConfig.enabledKey }, "Managed mode searchable")
    expect(has("indicator") { $0.field?.key == AgentManagedModeConfig.showIndicatorKey }, "Managed indicator searchable")
    expect(has("dark") { $0.paneID == "editor" && $0.label == "Appearance" }, "'dark' must find the Editor appearance (an option title)")
    expect(has("managed") { $0.field?.key == AgentManagedModeConfig.enabledKey }, "Managed mode searchable")
    expect(has("indicator") { $0.field?.key == AgentManagedModeConfig.showIndicatorKey }, "Managed indicator searchable")
    expect(has("dark") { $0.id == "pane.appearance" }, "'dark' must find the Appearance pane")
    expect(has("theme") { $0.id == "pane.appearance" } && has("theme") { $0.paneID == "editor" && $0.label == "Appearance" },
           "'theme' must find Appearance and the Editor appearance")
    expect(has("codex") { $0.field?.key == AgentBackendConfig.key }, "'codex' must find the default agent CLI")
    expect(has("chime") { $0.anchor == "sounds.master" }, "'chime' must find the sounds")
    expect(has("background") { $0.anchor == "canvasBackground.scope" }, "'background' must find the canvas background")
    expect(has("wallpaper") { $0.anchor == "canvasBackground.scope" }, "'wallpaper' must find the canvas background")
    expect(search("continuum").isEmpty && search("autoLayout").isEmpty, "raw defaults keys must never be searchable")

    // "on" matches words STARTING with "on" only. The old substring search matched
    // nearly every row ("Notifications", "Opacity" via "continuum.…").
    let onResults = search("on")
    expect(!onResults.isEmpty && onResults.count < entries.count / 4,
           "'on' must return a handful of word-prefix matches, got \(onResults.count) of \(entries.count)")
    for result in onResults {
        let entry = result.entry
        let words = ([entry.label, entry.groupTitle ?? "", entry.paneTitle] + entry.keywords + entry.optionTitles)
            .flatMap(SettingsSearch.words)
        expect(words.contains { $0.hasPrefix("on") }, "'on' matched '\(entry.label)' without a word starting with 'on'")
    }
    // A row never matches on its pane's title alone; the pane entry answers that.
    let terminal = search("terminal")
    expect(terminal.first?.entry.id == "pane.terminal", "'terminal' must rank the Terminal pane first, got \(terminal.first?.entry.id ?? "none")")
    expect(!terminal.contains { $0.entry.field?.key == TerminalDisplayConfig.fontSizeKey },
           "'terminal' must not return Font size just because it sits in the Terminal pane")
    // Ranking: a label word-prefix outranks a keyword-only match.
    let sounds = search("volume")
    expect(sounds.first?.entry.anchor == "sounds.volume", "'volume' must rank the Volume row first, got \(sounds.first?.entry.label ?? "none")")
    let grouped = SettingsSearch.grouped(search("font"))
    expect(Set(grouped.map(\.paneID)) == ["editor", "terminal"], "'font' groups into Editor and Terminal, got \(grouped.map(\.paneID))")
}
