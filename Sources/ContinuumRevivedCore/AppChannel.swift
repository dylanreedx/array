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
    public static let editorTestBundleIdentifier = "dev.arrayapp.macos.editor-test"

    /// "Array" for the prod bundle alone; "Array Dev" for the dev bundle and
    /// for bare binaries (nil bundle id) — dev work lands in the dev store by
    /// default instead of the user's real state.
    public static func applicationSupportDirectoryName(bundleIdentifier: String?) -> String {
        if bundleIdentifier == editorTestBundleIdentifier { return "Array Editor Test" }
        return bundleIdentifier == prodBundleIdentifier ? "Array" : "Array Dev"
    }

    /// The defaults domain non-standard contexts read as "the bundled app's
    /// settings". Channel-scoped so a dev build falls back to the DEV
    /// bundle's domain and never reads (or leaks into) prod preferences.
    public static func bundledDefaultsDomain(bundleIdentifier: String?) -> String {
        if bundleIdentifier == editorTestBundleIdentifier { return editorTestBundleIdentifier }
        return bundleIdentifier == prodBundleIdentifier ? prodBundleIdentifier : devBundleIdentifier
    }

    public static var liveApplicationSupportDirectoryName: String {
        applicationSupportDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public static var liveBundledDefaultsDomain: String {
        bundledDefaultsDomain(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Keychain service name for `base`, scoped to the channel.
    ///
    /// The keychain is prod state exactly like Application Support and the
    /// defaults domain, and it was the one piece of it this type did not cover:
    /// the companion relay credential and the paired-session secret were
    /// hardcoded constants shared by every build. macOS keys keychain ACLs on
    /// CODE SIGNATURE, and a dev build — or a bare `swift build` binary, whose
    /// signature changes on every rebuild — has a different one, so touching a
    /// prod item makes macOS prompt and disturbs the trust the prod app relies
    /// on. That really happened: a check flag run against the wrong binary fell
    /// through the flag cascade, booted the full app, read this item, and left
    /// the user's running copy prompting for the keychain password on every
    /// companion sync until they re-granted access.
    ///
    /// Nothing about that required a mistake to be dangerous: any dev build
    /// reaching this code would do the same. The prod name is unchanged, so a
    /// shipped install keeps its existing credential and does not re-pair.
    public static func keychainService(_ base: String, bundleIdentifier: String?) -> String {
        if bundleIdentifier == editorTestBundleIdentifier { return base + ".editor-test" }
        return bundleIdentifier == prodBundleIdentifier ? base : base + ".dev"
    }

    public static func liveKeychainService(_ base: String) -> String {
        keychainService(base, bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
