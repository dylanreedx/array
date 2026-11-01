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
/// `<app support>/characters/<id>/theme.json`. Read only; never redistributed.
public enum AgentCharacterImports {
    public static let fileName = "theme.json"

    public static func load(id: String, in directory: URL) -> AgentCharacterTheme? {
        guard AgentCharacterThemeParser.isThemeID(id) else { return nil }
        let url = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), case let .success(theme) = AgentCharacterThemeParser.parse(data: data),
              theme.id == id else { return nil }
        return theme
    }
}
