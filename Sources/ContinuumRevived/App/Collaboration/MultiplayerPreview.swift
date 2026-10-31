import CryptoKit
import Darwin
import Foundation
import ContinuumRevivedCore

/// `scripts/multiplayer-preview.sh`: two visible dev-channel Array apps acting
/// as two people on a LOCAL relay, for trying collaboration by hand.
///
/// `CONTINUUM_MULTIPLAYER_PREVIEW=<config.json>` turns it on. It is refused
/// (exit 2) unless the bundle has its own dev identity (never prod, never the
/// shared `dev.arrayapp.macos.dev`), app support is isolated and the relay is
/// loopback, so it can never fall back to the Keychain or a real CLI. While on:
/// - the collaboration credential lives in a file under the preview root,
///   never the Keychain;
/// - the check fakes stand in for `claude`, `codex` and `pi` on PATH, the
///   login-shell PATH upgrade is skipped so a real CLI cannot win, and no
///   catalogue probe, session titling or account read runs;
/// - the app never activates itself and never writes into `~/.pi`.
struct MultiplayerPreview: Decodable, Sendable {
    /// "A" or "B": the person this window plays.
    let label: String
    /// "host" creates the shared workspace and invites; "guest" accepts.
    let role: String
    let endpoint: String
    let enrollmentCode: String
    /// This instance's own folder: vault, fake CLIs, identity and ready marker.
    let root: String
    /// Folder both instances read and write: the guest's ID, the invitation.
    let exchange: String
    let areaLabel: String
    /// "left" or "right": which half of the screen this person's windows take.
    let side: String

    static let environmentKey = "CONTINUUM_MULTIPLAYER_PREVIEW"
    /// The script's bundles: `dev.arrayapp.macos.mp-a`, `dev.arrayapp.macos.mp-b`.
    static let bundlePrefix = "dev.arrayapp.macos.mp-"

    /// Read with `getenv`, not ProcessInfo: `main()` consults this before
    /// `ToolEnvironment.bootstrap()`, and ProcessInfo caches PATH on first read.
    static let current: MultiplayerPreview? = {
        func refuse(_ reason: String) -> Never {
            fputs("MULTIPLAYER PREVIEW REFUSED: \(reason)\n", stderr)
            exit(2)
        }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        guard let raw = getenv(environmentKey) else {
            // Opened from Finder, a preview bundle would fall onto the shared
            // "Array Dev" store and the Keychain. Only the script launches it.
            if bundle.hasPrefix(bundlePrefix) { refuse("start this bundle with scripts/multiplayer-preview.sh") }
            return nil
        }
        let path = String(cString: raw)
        guard bundle.hasPrefix("dev.arrayapp.macos."), bundle != AppChannel.devBundleIdentifier,
              bundle != AppChannel.editorTestBundleIdentifier else { refuse("bundle \(bundle) is not a separate dev identity") }
        guard getenv("CONTINUUM_APP_SUPPORT") != nil else { refuse("CONTINUUM_APP_SUPPORT is not isolated") }
        let config: MultiplayerPreview
        do { config = try JSONDecoder().decode(MultiplayerPreview.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { refuse("unreadable configuration \(path): \(error)") }
        guard let url = URL(string: config.endpoint),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") else { refuse("relay must be loopback") }
        guard config.root.hasPrefix("/"), config.exchange.hasPrefix("/"), ["host", "guest"].contains(config.role) else { refuse("bad root, exchange or role") }
        return config
    }()

    var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    var exchangeURL: URL { URL(fileURLWithPath: exchange, isDirectory: true) }

    /// Called from `main()` before PATH bootstrap: the fakes lead PATH.
    func installFakeCLIs() {
        let bin = rootURL.appendingPathComponent("bin", isDirectory: true)
        do {
            for harness in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] { try AgentSteeringQAFakes.install(harness, in: bin) }
        } catch {
            fputs("MULTIPLAYER PREVIEW REFUSED: fake CLIs not installed: \(error)\n", stderr)
            exit(2)
        }
        let current = getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
        setenv("PATH", bin.path + ":" + current, 1)
    }

    func write(_ object: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    func read(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    /// Polls for the other window's file; the two apps start independently.
    func waitFor(_ url: URL, timeout: TimeInterval = 120) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read(url) { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// The preview's collaboration credential vault: one 0600 file per item under
/// the preview root, the same shape as the pair witness's QA vault.
final class MultiplayerPreviewCredentialVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    let directory: URL
    init(_ directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func file(_ service: String, _ account: String) -> URL {
        let key = SHA256.hash(data: Data((service + "/" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".credential")
    }
    func read(service: String, account: String) throws -> Data? {
        try lock.withLock { let path = file(service, account); return FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil }
    }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock { let path = file(service, account); try data.write(to: path, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    }
    func remove(service: String, account: String) throws { try lock.withLock { let path = file(service, account); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } } }
}
