import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/110-agent-characters/README.md
/// Where the built-in agent characters ship, and their parsed theme.
public enum AgentCharacterBundled {
    public static let themeFileName = "ducks.theme.json"
    /// The built-in set's theme id.
    public static let themeID = "ducks-classic"
    public static let licenseFileName = "LICENSE.txt"
    static let folder = "AgentCharacters"
    static let resourceBundleName = "continuum-revived_ContinuumRevivedCore.bundle"

    /// The built-in set's folder: inside the app at Contents/Resources, or beside
    /// a bare binary (checks), as `make-app-bundle.sh` lays Core's resources out.
    public static func folderURL() -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let url = root.appendingPathComponent(resourceBundleName).appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(themeFileName).path) { return url }
        }
        return nil
    }

    public static var themeURL: URL? { folderURL()?.appendingPathComponent(themeFileName) }
    public static var licenseURL: URL? { folderURL()?.appendingPathComponent(licenseFileName) }

    nonisolated(unsafe) private static var cached: AgentCharacterTheme?
    private static let lock = NSLock()

    /// The built-in theme, parsed once per process. nil only when the resource is
    /// missing or broken, which the bundle checks catch before a release.
    public static func theme() -> AgentCharacterTheme? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let url = themeURL, let data = try? Data(contentsOf: url),
              case let .success(theme) = AgentCharacterThemeParser.parse(data: data) else { return nil }
        cached = theme
        return theme
    }
}

/// Settings › Appearance › Agent characters. Off by default.
public enum AgentCharacterConfig {
    public static let enabledKey = "agentCharacters.enabled"
    public static let defaultEnabled = false
    public static let motionKey = "agentCharacters.motion"
    /// The selected set's id; the built-in set's when absent.
    public static let themeKey = "agentCharacters.theme"

    public enum Motion: String, CaseIterable, Sendable {
        /// Agents in motion animate; everything at rest holds still.
        case working
        /// Every character holds its state's still frame.
        case never

        public var title: String {
            switch self {
            case .working: return "Working agents only"
            case .never: return "Never (still poses)"
            }
        }
    }

    public static let defaultMotion = Motion.working

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static func motion(_ defaults: UserDefaults) -> Motion {
        defaults.string(forKey: motionKey).flatMap(Motion.init(rawValue:)) ?? defaultMotion
    }

    /// FNV-1a over the agent id's 16 bytes: the same agent gets the same character
    /// on every launch, surface and device, with nothing stored.
    public static func stableHash(_ id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    public static func characterIndex(for id: UUID, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(stableHash(id) % UInt64(count))
    }

    /// 0..<1: where in its loop this agent's character is, so two agents doing the
    /// same thing do not move in step.
    public static func phase(for id: UUID) -> Double {
        Double((stableHash(id) >> 20) % 10_000) / 10_000
    }
}

/// Sets the person imported: each a copy of one theme file in
/// `<app support>/characters/<id>/theme.json`. Read only, never redistributed,
/// and never written back to where it came from.
public enum AgentCharacterImports {
    public static let fileName = "theme.json"
    /// The format's per-folder file name and the file suffix a theme folder holds.
    public static let folderThemeName = "duckherd-theme.json"
    public static let themeSuffix = ".theme.json"
    /// The format reads at most this many candidate files from one folder.
    public static let maximumCandidates = 40

    public static func load(id: String, in directory: URL) -> AgentCharacterTheme? {
        guard AgentCharacterThemeParser.isThemeID(id) else { return nil }
        let url = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), case let .success(theme) = AgentCharacterThemeParser.parse(data: data),
              theme.id == id else { return nil }
        return theme
    }

    /// Every imported set, by title.
    public static func list(in directory: URL) -> [AgentCharacterTheme] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return folders.compactMap { load(id: $0, in: directory) }.sorted { $0.title < $1.title }
    }

    public enum ImportResult: Equatable, Sendable {
        case imported(AgentCharacterTheme)
        /// The file is not a valid theme: its first problems, each saying where.
        case invalid(file: URL, problems: [String])
        case unreadable(file: URL, reason: String)
    }

    /// Validate `file` and copy exactly it into `directory/<id>/theme.json`.
    /// Nothing is written when the file has a problem.
    public static func importTheme(from file: URL, into directory: URL) -> ImportResult {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= AgentCharacterThemeParser.maximumFileBytes else {
            return .invalid(file: file, problems: ["the file is over 3 MB"])
        }
        guard let data = try? Data(contentsOf: file) else {
            return .unreadable(file: file, reason: "Array could not read this file.")
        }
        switch AgentCharacterThemeParser.parse(data: data) {
        case let .failure(problems):
            return .invalid(file: file, problems: problems.messages)
        case let .success(theme):
            guard theme.id != AgentCharacterBundled.themeID else {
                return .invalid(file: file, problems: ["\"id\" \(theme.id) is the built-in set's; give the set its own id"])
            }
            let folder = directory.appendingPathComponent(theme.id, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            } catch {
                return .unreadable(file: file, reason: "Array could not save its copy: \(error.localizedDescription)")
            }
            return .imported(theme)
        }
    }

    /// Import every candidate in a folder (scanned the way the format scans its
    /// themes folder), or the file itself.
    public static func importAll(from url: URL, into directory: URL) -> [ImportResult] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            return [.unreadable(file: url, reason: "The file is gone.")]
        }
        guard isFolder.boolValue else { return [importTheme(from: url, into: directory)] }
        return candidates(inFolder: url).map { importTheme(from: $0, into: directory) }
    }

    public static func remove(id: String, from directory: URL) {
        guard AgentCharacterThemeParser.isThemeID(id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    /// `<folder>/*.theme.json` and `<folder>/<sub>/duckherd-theme.json`, sorted,
    /// at most 40. Lists names only; nothing is read.
    public static func candidates(inFolder folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [URL] = []
        for name in names.sorted() {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let nested = url.appendingPathComponent(folderThemeName)
                if FileManager.default.fileExists(atPath: nested.path) { out.append(nested) }
            } else if name.hasSuffix(themeSuffix) {
                out.append(url)
            }
        }
        return Array(out.prefix(maximumCandidates))
    }

    /// Theme files Claude Code's plugins point at, found on this Mac WITHOUT
    /// reading any theme: the `themesDir` a plugin's settings name in
    /// `<home>/.claude/settings.json` (`pluginConfigs`), and the theme file at the
    /// root of each installed plugin (`installed_plugins.json`). `home` is passed
    /// in so a check can point it at a fixture, never at the real one.
    public static func discover(home: URL) -> [URL] {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        var found: [URL] = []
        if let data = try? Data(contentsOf: claude.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configs = settings["pluginConfigs"] as? [String: Any] {
            for key in configs.keys.sorted() {
                guard let config = configs[key] as? [String: Any] else { continue }
                // A plugin's settings may sit directly or under an `options` object.
                let raw = (config["themesDir"] as? String) ?? ((config["options"] as? [String: Any])?["themesDir"] as? String)
                guard let raw, !raw.isEmpty else { continue }
                let path = raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))).path : raw
                found += candidates(inFolder: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        if let data = try? Data(contentsOf: claude.appendingPathComponent("plugins/installed_plugins.json")),
           let installed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plugins = installed["plugins"] as? [String: Any] {
            for key in plugins.keys.sorted() {
                for entry in (plugins[key] as? [[String: Any]]) ?? [] {
                    guard let path = entry["installPath"] as? String, !path.isEmpty else { continue }
                    let file = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(folderThemeName)
                    if FileManager.default.fileExists(atPath: file.path) { found.append(file) }
                }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
