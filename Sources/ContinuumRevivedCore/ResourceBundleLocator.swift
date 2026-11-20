import Foundation

/// Finds a file inside a SwiftPM resource bundle copied into an app by hand.
/// Toolchains before Swift 6.4 emit the bundle flat (`X.bundle/<path>`); newer
/// ones emit the macOS layout (`X.bundle/Contents/Resources/<path>`). Both work.
public enum ResourceBundleLocator {
    public static let coreBundleName = "continuum-revived_ContinuumRevivedCore.bundle"

    /// Directories that may hold the copied bundle: Contents/Resources in an app,
    /// beside the executable for a bare binary.
    public static func defaultRoots() -> [URL] {
        [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
    }

    public static func url(bundleName: String, relativePath: String, roots: [URL]? = nil,
                           fileManager: FileManager = .default) -> URL? {
        for root in roots ?? defaultRoots() {
            let bundle = root.appendingPathComponent(bundleName, isDirectory: true)
            for base in [bundle, bundle.appendingPathComponent("Contents/Resources", isDirectory: true)] {
                let url = base.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public static func coreURL(_ relativePath: String, roots: [URL]? = nil) -> URL? {
        url(bundleName: coreBundleName, relativePath: relativePath, roots: roots)
    }
}
