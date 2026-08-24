import Foundation

// Ticket: C8 — pi subagent DETECTION (PiEventTranslator, AgentSupervisor's
// handleSpawnRequest) has existed for a while but never fired. One of four
// independent reasons: continuum-spawn-agent.ts (the extension that gives pi
// its `spawn_agent` tool) has never been installed anywhere pi loads
// extensions from. This installs it.
//
// Destination confirmed from pi's own `dist/core/resource-loader.js` and
// `dist/core/package-manager.js` (package `@earendil-works/pi-coding-agent`):
// `getAgentDir()` (`~/.pi/agent`, or `$PI_CODING_AGENT_DIR` if set) + literal
// "extensions" is one of the roots pi auto-discovers extensions from
// (`collectAutoExtensionEntries`), separate from `-e`/`--extension` (which
// loads an explicit path regardless of discovery settings — see
// PiAgentRunner.processArguments). Installing here is defense in depth
// alongside `-e`, not a replacement for it: auto-discovery can be disabled by
// a user's settings.json, `-e` cannot.
public enum PiExtensionInstaller {
    public static let extensionFileName = "continuum-spawn-agent.ts"

    /// `~/.pi/agent/extensions` — see the file-level comment for the source.
    public static func defaultExtensionsDirectory(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".pi/agent/extensions", isDirectory: true)
    }

    public enum InstallResult: Equatable, Sendable {
        /// Wrote the file: either it was missing, or it matched our own
        /// content already (write-if-absent path taken; see `install`).
        case installed
        /// Already present with exactly our content — no write needed.
        case alreadyCurrent
        /// Present with DIFFERENT content and it isn't ours — left alone.
        /// Never clobbers a user's modified copy.
        case leftUserModifiedCopy
        /// The extension's own bytes could not be located to install (a
        /// dev/test binary not built with the Core resource, or the shipped
        /// resource bundle is missing from the app).
        case sourceUnavailable
    }

    /// Idempotent: safe to call on every launch. Compares by content, not by
    /// existence, so re-running after an update replaces our own prior copy
    /// but never a user's edited one. Never touches settings.json — pi's
    /// auto-discovery finds this file without a settings entry.
    public static func install(
        sourceContent: Data? = nil,
        destinationDirectory: URL = PiExtensionInstaller.defaultExtensionsDirectory(),
        fileManager: FileManager = .default
    ) -> InstallResult {
        guard let content = sourceContent ?? bundledExtensionContent(fileManager: fileManager) else {
            return .sourceUnavailable
        }
        let destination = destinationDirectory.appendingPathComponent(extensionFileName)
        if let existing = try? Data(contentsOf: destination) {
            return existing == content ? .alreadyCurrent : .leftUserModifiedCopy
        }
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try content.write(to: destination, options: .atomic)
            return .installed
        } catch {
            return .sourceUnavailable
        }
    }

    /// The extension's shipped bytes at runtime. Deliberately NOT
    /// `Bundle.module`: SwiftPM's generated accessor resolves the resource
    /// bundle at `Bundle.main.bundleURL.appendingPathComponent(...)`, which
    /// for a macOS .app is the .app directory itself — a location codesign
    /// refuses to seal alongside Contents/ ("unsealed contents present in the
    /// bundle root"). The real app instead copies the bundle into
    /// Contents/Resources (see make-app-bundle.sh); a bare dev/checks binary
    /// gets the bundle dropped next to it by SwiftPM directly. Both are
    /// covered below.
    public static func bundledExtensionContent(fileManager: FileManager = .default) -> Data? {
        guard let url = bundledExtensionURL(fileManager: fileManager) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func bundledExtensionURL(fileManager: FileManager = .default) -> URL? {
        let resourceBundleName = "continuum-revived_ContinuumRevivedCore.bundle"
        let relativePath = "PiExtensions/\(extensionFileName)"
        var candidates: [URL] = []
        if let resourcesURL = Bundle.main.resourceURL {
            candidates.append(
                resourcesURL.appendingPathComponent(resourceBundleName).appendingPathComponent(relativePath))
        }
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent(resourceBundleName).appendingPathComponent(relativePath))
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
