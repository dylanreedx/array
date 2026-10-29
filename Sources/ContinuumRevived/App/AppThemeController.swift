import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum AppThemeController {
    static let didChangeNotification = Notification.Name("array.appearance.theme.changed")

    static func adoptSavedTheme(defaults: UserDefaults) {
        adopt(AppTheme.resolve(defaults.string(forKey: AppTheme.defaultsKey)))
    }

    static func observeSetting(defaults: UserDefaults) -> NSObjectProtocol {
        nonisolated(unsafe) let defaults = defaults
        return NotificationCenter.default.addObserver(
            forName: SettingChangeEvent.name(for: SettingID(rawValue: AppTheme.defaultsKey)),
            object: nil, queue: nil
        ) { _ in
            // Finish the Settings binding transaction before changing AppKit's
            // appearance. Forcing hosting-view layout inside it clips SwiftUI text.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    apply(AppTheme.resolve(defaults.string(forKey: AppTheme.defaultsKey)))
                }
            }
        }
    }

    private static func adopt(_ theme: AppTheme) {
        AppTheme.current = theme
        NSApp.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
    }

    // Palette changes affect paint, not geometry. Do not force layout on private
    // SwiftUI hosting descendants while their appearance transaction is changing.
    private static func repaint(_ view: NSView) {
        if let themed = view as? TokenThemed { themed.applyTokens() }
        view.needsDisplay = true
        for child in view.subviews { repaint(child) }
    }

    static func apply(_ theme: AppTheme) {
        adopt(theme)
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            repaint(root)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
