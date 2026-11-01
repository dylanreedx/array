import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/110-agent-characters/README.md
/// Where the built-in agent characters ship, and their parsed theme.
public enum AgentCharacterBundled {
    public static let themeFileName = "ducks.theme.json"
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
