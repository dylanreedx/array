import ContinuumRevivedCore
import Foundation

private final class EditorPreferenceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func receive() { lock.withLock { count += 1 } }
    var received: Int { lock.withLock { count } }
}

func runEditorPreferencesChecks() {
    let suite = "array.editor.preferences.check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = EditorPreferences(defaults: defaults)
    expect(initial.appearance == .system && initial.fontSize == 13 && initial.lineHeight == 1.5,
           "editor defaults must use System appearance and readable default typography")
    expect(initial.lineNumbers && !initial.wordWrap && !initial.vimEnabled,
           "editor defaults must enable line numbers and disable wrap and Vim")
    expect(initial.resolve(systemIsDark: true) == .dark && initial.resolve(systemIsDark: false) == .light,
           "System editor appearance must resolve with the operating system appearance")
    for theme in [EditorThemeTokens.light, .dark] {
        let keys: [KeyPath<EditorThemeTokens, String>] = [
            \.background, \.foreground, \.sidebarBackground, \.chromeBackground,
            \.border, \.mutedForeground, \.selection, \.hover, \.accent,
            \.gutterBackground, \.gutterForeground, \.activeLine, \.error, \.warning,
        ]
        for key in keys {
            expect(theme.resolvedColor(key).hexKey == String(theme[keyPath: key].dropFirst()).uppercased(),
                   "AppKit and CodeMirror must resolve the same editor palette values")
        }
    }
    let events = EditorPreferenceEvents()
    let observer = NotificationCenter.default.addObserver(
        forName: SettingChangeEvent.name(for: SettingID(rawValue: EditorPreferences.vimEnabledKey)),
        object: nil, queue: nil
    ) { _ in events.receive() }
    defer { NotificationCenter.default.removeObserver(observer) }
    EditorPreferences.setVimEnabled(true, defaults: defaults)
    expect(EditorPreferences(defaults: defaults).vimEnabled && events.received == 1,
           "tile Vim toggle must persist globally and notify existing editors")
    EditorPreferences.setVimEnabled(false, defaults: defaults)
    expect(!EditorPreferences(defaults: defaults).vimEnabled && events.received == 2,
           "disabling Vim must persist and notify editors immediately")
    defaults.set("Light", forKey: EditorPreferences.appearanceKey)
    defaults.set(99, forKey: EditorPreferences.fontSizeKey)
    defaults.set(0.1, forKey: EditorPreferences.lineHeightKey)
    defaults.set("  ", forKey: EditorPreferences.fontFamilyKey)
    let changed = EditorPreferences(defaults: defaults)
    expect(changed.fontSize == 32 && changed.lineHeight == 1.1 && changed.fontFamily == EditorPreferences.defaultFontFamily,
           "invalid typography must clamp to supported bounds or restore the system font")
    expect(changed.resolve(systemIsDark: true) == .light,
           "explicit editor theme must remain independent of app and system themes")
    let section = SettingsSchema.sections().first { $0.id == "editor" }
    expect(Set(section?.fields.compactMap(\.key) ?? []) == Set(EditorPreferences.allKeys),
           "dedicated Editor settings must expose every live editor preference")
    for field in section?.fields ?? [] { field.reset(in: defaults) }
    expect(EditorPreferences(defaults: defaults) == initial,
           "resetting Editor settings must restore all original defaults")
}
