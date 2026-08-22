import ContinuumRevivedCore
import Foundation

private final class ObservedSettingIDs: @unchecked Sendable {
    var values: [SettingID] = []
}

func runProductRegistryChecks() throws {
    let registry = try CommandRegistry.productRegistry()
    let commandIDs = Set(registry.commands.map(\.id))
    let shortcutIDs = Set(registry.shortcuts.map(\.id))
    let settingIDs = Set(registry.settings.map(\.id))

    expect(commandIDs.count == registry.commands.count, "every built-in command has one stable ID")
    expect(shortcutIDs.count == registry.shortcuts.count, "every built-in shortcut has one stable ID")
    expect(settingIDs.count == registry.settings.count, "every built-in setting has one stable ID")
    expect(
        registry.shortcuts.allSatisfy { commandIDs.contains($0.commandID) },
        "every shortcut references a registered command"
    )
    expect(
        registry.settings.filter { $0.applicationPolicy == .live }.allSatisfy { !$0.consumerID.rawValue.isEmpty },
        "every live setting declares its exact consumer"
    )
    expect(
        registry.commands.filter { $0.paletteVisible }.allSatisfy { $0.paletteAction != nil },
        "every static Command Center row has one dispatch token"
    )
    expect(commandIDs.contains("help.replayGettingStarted"), "Getting Started replay is a registered command")
    expect(!settingIDs.contains("continuum.ambientZoneHome"),
           "the removed Ambient Zone Home preference is not registered")
    let valueSettingCategories = Set(SettingsCategory.allCases).subtracting([.keybindings])
    expect(
        valueSettingCategories.isSubset(of: Set(registry.settings.map(\.category))) && !registry.shortcuts.isEmpty,
        "every value-settings category is registered and Keybindings is backed by shortcut definitions"
    )

    let global = ShortcutDefinition(
        id: "test.global",
        commandID: "app.commandCenter",
        contexts: [.global],
        defaultGestures: [ShortcutGesture(keyCode: 40, modifiers: .command)],
        conflictDomain: .global
    )
    let browserOnly = ShortcutDefinition(
        id: "test.browser",
        commandID: "app.commandCenter",
        contexts: [.tile(.browser)],
        defaultGestures: [ShortcutGesture(keyCode: 40, modifiers: .command)],
        conflictDomain: .contexts([.tile(.browser)])
    )
    let noteOnly = ShortcutDefinition(
        id: "test.note",
        commandID: "app.commandCenter",
        contexts: [.tile(.note)],
        defaultGestures: [ShortcutGesture(keyCode: 40, modifiers: .command)],
        conflictDomain: .contexts([.tile(.note)])
    )
    expect(ShortcutConflictResolver.conflicts(global, browserOnly), "global bindings conflict with active contexts")
    expect(!ShortcutConflictResolver.conflicts(browserOnly, noteOnly), "mutually exclusive tile contexts may share a gesture")

    let suite = "array.productRegistryChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserSettingsStore(defaults: defaults)
    let observed = ObservedSettingIDs()
    let token = store.observe(BuiltInSettingRegistry.shortcutRail.id) { id in observed.values.append(id) }
    expect(store.value(for: BuiltInSettingRegistry.shortcutRail), "typed settings return the registered default")
    expect(store.set(false, for: BuiltInSettingRegistry.shortcutRail) == nil, "a valid typed setting write succeeds")
    expect(!store.value(for: BuiltInSettingRegistry.shortcutRail), "typed writes are immediately readable")
    expect(observed.values == [BuiltInSettingRegistry.shortcutRail.id], "setting observation is exact-ID, not a generic broadcast")
    expect(store.isModified(BuiltInSettingRegistry.shortcutRail), "modified state compares against the registered default")
    store.reset(BuiltInSettingRegistry.shortcutRail)
    expect(store.value(for: BuiltInSettingRegistry.shortcutRail), "reset restores the registered default")
    store.removeObserver(token)

    let invalidGap = store.set(500, for: BuiltInSettingRegistry.tileGap)
    expect(invalidGap != nil, "invalid values report inline validation instead of being silently clamped")
    expect(store.value(for: BuiltInSettingRegistry.tileGap) == TileGapResolver.defaultGap, "invalid input is not persisted")

    do {
        _ = try ProductRegistry(features: [
            FeatureRegistration(id: "duplicate", commands: [], settings: []),
            FeatureRegistration(id: "duplicate", commands: [], settings: []),
        ])
        expect(false, "duplicate feature IDs must fail registration")
    } catch ProductRegistryError.duplicateFeature {
        // expected
    }

    print("ProductRegistry checks passed")
}
