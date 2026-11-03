import Foundation

/// Duckherd (the Claude Code plugin by Ali Alsalkhadi) conducts a Claude
/// session the way an Array Managed lead does: its own lead brief, quick-look
/// budget, helper types and report rule, plus sounds and banners on the Mac.
/// Two conductors in one session fight, and Duckherd's wins (measured on claude
/// 2.1.317 with Duckherd 0.4.10: the Managed lead made no `array_delegate`
/// call). A Managed agent is Array's conductor, so Duckherd stays off there.
/// A Free agent keeps whatever the user set up.
///
/// Every read here is read-only. Array never edits the user's plugins,
/// settings or Duckherd's store.
public enum ClaudeDuckherd {
    public static let pluginName = "duckherd"

    /// The `pluginConfigs` value for the Managed `--settings`. Claude reads a
    /// plugin's options from `pluginConfigs["duckherd" or
    /// "duckherd@<marketplace>"].options` (its debug log, 2.1.317), and
    /// `--settings` outranks the user's own settings for the same key. The bare
    /// name is always present; each installed `duckherd@<marketplace>` key is
    /// added, so a user's own options under the qualified key can't win.
    public static func switchedOffPluginConfigs(installedKeys: [String]) -> [String: Any] {
        var configs: [String: Any] = [:]
        for key in [pluginName] + installedKeys.sorted() {
            configs[key] = ["options": ["startOn": false]]
        }
        return configs
    }

    /// The `duckherd@<marketplace>` keys the user has installed or enabled.
    /// `installed_plugins.json` lists installs; `settings.json`'s
    /// `enabledPlugins` lists what is switched on. Read-only, missing files
    /// are empty.
    public static func installedPluginKeys(configDirectory: URL) -> [String] {
        var keys = Set<String>()
        func object(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let installed = object("plugins/installed_plugins.json")?["plugins"] as? [String: Any] ?? [:]
        let enabled = object("settings.json")?["enabledPlugins"] as? [String: Any] ?? [:]
        for key in Array(installed.keys) + Array(enabled.keys) where key.hasPrefix(pluginName + "@") {
            keys.insert(key)
        }
        return keys.sorted()
    }

    /// Whether Duckherd's own store says this session was switched ON with
    /// `/duckherd on`. Duckherd keeps that choice as `leadOn:<session>` and
    /// checks it before `startOn`, so a resumed session that was once switched
    /// on comes back on despite the Managed setting. The store is
    /// `<config>/plugins/store/duckherd_<marketplace>-<hash>.json`, one per
    /// install, so every one is read.
    public static func sessionSwitchedOn(sessionId: String, configDirectory: URL) -> Bool {
        let store = configDirectory.appendingPathComponent("plugins/store", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return false }
        for name in names where name.hasPrefix(pluginName + "_") && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: store.appendingPathComponent(name)),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let choice = object["leadOn:" + sessionId] as? [String: Any] else { continue }
            if choice["on"] as? Bool == true { return true }
        }
        return false
    }

    /// What a Managed session sends, silently, before its first prompt when
    /// the store says the session is on. Measured: claude answers it itself
    /// with one synthetic `result` and no model call.
    public static let switchOffCommand = "/duckherd off"

    /// `/duckherd on`, which a Managed session never forwards: it would make
    /// Duckherd a second conductor and save that choice for every resume.
    public static func isSwitchOnCommand(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace)
        return words == ["/duckherd", "on"]
    }

    /// The Claude config directory a runner's process reads.
    public static func configDirectory(_ configured: String?) -> URL {
        if let configured, !configured.isEmpty { return URL(fileURLWithPath: configured, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }
}
