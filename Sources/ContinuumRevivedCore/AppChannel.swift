import Foundation

/// Dev/prod channel split (go-live follow-up): the prod copy in /Applications
/// must never share state with dev builds or agent-driven runs. macOS keys
/// preferences and app identity off the bundle id, so the channel IS the
/// bundle id: exactly `dev.arrayapp.macos` is prod; everything else — the dev
/// bundle id, a bare `swift build` binary with no bundle id at all — is the
/// dev channel. Only the prod-identified bundle may touch the prod
/// Application Support dir and defaults domain.
///
/// The mappings are pure static functions so the matrix pins them; the `live*`
/// accessors are the one place `Bundle.main` is consulted.
public enum AppChannel {
    public static let prodBundleIdentifier = "dev.arrayapp.macos"
    public static let devBundleIdentifier = "dev.arrayapp.macos.dev"

    /// "Array" for the prod bundle alone; "Array Dev" for the dev bundle and
    /// for bare binaries (nil bundle id) — dev work lands in the dev store by
    /// default instead of the user's real state.
    public static func applicationSupportDirectoryName(bundleIdentifier: String?) -> String {
        bundleIdentifier == prodBundleIdentifier ? "Array" : "Array Dev"
    }

    /// The defaults domain non-standard contexts read as "the bundled app's
    /// settings". Channel-scoped so a dev build falls back to the DEV
    /// bundle's domain and never reads (or leaks into) prod preferences.
    public static func bundledDefaultsDomain(bundleIdentifier: String?) -> String {
        bundleIdentifier == prodBundleIdentifier ? prodBundleIdentifier : devBundleIdentifier
    }

    public static var liveApplicationSupportDirectoryName: String {
        applicationSupportDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public static var liveBundledDefaultsDomain: String {
        bundledDefaultsDomain(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
