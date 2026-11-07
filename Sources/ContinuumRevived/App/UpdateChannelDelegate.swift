import ContinuumRevivedCore
import Foundation
import Sparkle

/// Sparkle always includes unchannelled stable items. Read on each check so
/// Settings takes effect without restarting. Dev/QA never starts the updater.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        defaults.string(forKey: "array.updateChannel") == "Tip" ? ["tip"] : []
    }

    static func check() {
        let suite = "array.update-channel-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = UpdateChannelDelegate(defaults: defaults)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        // Sparkle's public appcast API exposes items, but no channel-filtering
        // operation. Assert its delegate contract directly rather than copying
        // Sparkle's filtering logic. Resolve the real Settings field so a key
        // drift between Settings and the updater makes this witness fail.
        guard let field = SettingsSchema.sections().flatMap(\.groups)
            .flatMap(\.rows).map(\.field)
            .first(where: { $0.key == "array.updateChannel" }) else {
            preconditionFailure("Settings is missing the update channel field")
        }
        precondition(delegate.allowedChannels(for: controller.updater) == [])
        field.setValue(.string("Tip"), in: defaults)
        precondition(delegate.allowedChannels(for: controller.updater) == ["tip"])
        field.setValue(.string("Stable"), in: defaults)
        precondition(delegate.allowedChannels(for: controller.updater) == [])
        print("update-channel-check passed: Settings writer → Sparkle delegate: Stable [] → Tip [tip] → Stable []")
    }
}
