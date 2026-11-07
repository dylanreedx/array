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
        // Drive the production delegate with an inert real updater. These are
        // the channels Sparkle uses to filter the feed, including stable always.
        func accepted(_ channel: String?) -> Bool {
            channel == nil || delegate.allowedChannels(for: controller.updater).contains(channel!)
        }
        precondition(accepted(nil) && !accepted("tip") && !accepted("beta"))
        defaults.set("Tip", forKey: "array.updateChannel")
        precondition(accepted(nil) && accepted("tip") && !accepted("beta"))
        defaults.set("Stable", forKey: "array.updateChannel")
        precondition(accepted(nil) && !accepted("tip"))
        print("update-channel-check passed: Stable → Tip → Stable through Sparkle delegate")
    }
}
