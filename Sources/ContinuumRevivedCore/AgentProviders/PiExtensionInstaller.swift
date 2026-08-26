import CryptoKit
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
        /// Wrote the file: it was missing, or it byte-matched a PRIOR shipped
        /// version of ours (see `knownPriorContentHashes`) and was updated.
        case installed
        /// Already present with exactly our content — no write needed.
        case alreadyCurrent
        /// Present with content that is neither current nor any prior shipped
        /// version — left alone. Never clobbers a user's modified copy.
        case leftUserModifiedCopy
        /// The extension's own bytes could not be located to install (a
        /// dev/test binary not built with the Core resource, or the shipped
        /// resource bundle is missing from the app).
        case sourceUnavailable
    }

    /// SHA-256 (hex) of every PRIOR shipped version of the extension file.
    /// This is what lets an update actually REACH existing installs: a copy
    /// whose hash is listed here is ours, so it is overwritten; unknown bytes
    /// are a user's edit and stay sacred. Before shipping a new version of the
    /// .ts, append the hash of the version it replaces
    /// (`git show HEAD:Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-spawn-agent.ts | shasum -a 256`).
    public static let knownPriorContentHashes: Set<String> = [
        // The original fire-and-forget spawn_agent (a8ab0b40, shipped by
        // 5e4ac132; both commits carry byte-identical content).
        "3e536320b6c99957255bb26b7709acdf838b075c99212c57211cf5f34831bd5a",
    ]

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Idempotent: safe to call on every launch. Compares by content, so
    /// re-running after an update replaces our own prior copy (current bytes or
    /// a `knownPriorContentHashes` version) but never a user's edited one.
    /// Never touches settings.json — pi's auto-discovery finds this file
    /// without a settings entry.
    public static func install(
        sourceContent: Data? = nil,
        destinationDirectory: URL = PiExtensionInstaller.defaultExtensionsDirectory(),
        knownPriorHashes: Set<String> = PiExtensionInstaller.knownPriorContentHashes,
        fileManager: FileManager = .default
    ) -> InstallResult {
        guard let content = sourceContent ?? bundledExtensionContent(fileManager: fileManager) else {
            return .sourceUnavailable
        }
        let destination = destinationDirectory.appendingPathComponent(extensionFileName)
        if let existing = try? Data(contentsOf: destination) {
            if existing == content { return .alreadyCurrent }
            guard knownPriorHashes.contains(sha256Hex(existing)) else {
                return .leftUserModifiedCopy
            }
            // A prior shipped version of our own file: fall through to the write.
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
