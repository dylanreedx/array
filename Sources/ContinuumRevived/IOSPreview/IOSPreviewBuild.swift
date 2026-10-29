import Foundation
import ContinuumRevivedCore

struct IOSPreviewBuildChoice: Equatable, Sendable {
    let container: URL
    let scheme: String
    var arguments: [String] { [container.pathExtension == "xcworkspace" ? "-workspace" : "-project", container.path, "-scheme", scheme] }
    var title: String { "\(container.deletingPathExtension().lastPathComponent) · \(scheme)" }
}

/// Runs only on an explicit user action. Each run has fresh products and an exact
/// device destination; a successful build is required before any installation.
@MainActor
final class IOSPreviewBuild {
    private static var activeDevices: Set<String> = []
    typealias Command = ([String], URL?) async throws -> Data
    var command: Command = { arguments, log in
        try await IOSPreviewCommands.run(arguments, outputURL: log, timeoutSeconds: 900)
    }
    var onProgress: ((String) -> Void)?

    func choices(in root: URL) async throws -> [IOSPreviewBuildChoice] {
        let containers = try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            // Deliberately shallow: never crawl node_modules, .build or worktrees.
            return try [root, root.appendingPathComponent("ios")].flatMap { directory -> [URL] in
                guard fm.fileExists(atPath: directory.path) else { return [] }
                return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) }
            }.sorted { $0.path < $1.path }
        }.value
        var choices: [IOSPreviewBuildChoice] = []
        for container in containers {
            try Task.checkCancellation()
            let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
            let data = try await command(["/usr/bin/xcodebuild", flag, container.path, "-list", "-json"], nil)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let value = (json?["workspace"] ?? json?["project"]) as? [String: Any]
            for scheme in (value?["schemes"] as? [String] ?? []).sorted() {
                choices.append(.init(container: container, scheme: scheme))
            }
        }
        return choices
    }

    struct Product: Equatable { let app: URL; let bundleID: String }
    static func product(from data: Data, inside directory: URL) throws -> Product {
        let settings = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let products = settings.compactMap { entry -> Product? in
            guard let value = entry["buildSettings"] as? [String: Any],
                  value["PRODUCT_TYPE"] as? String == "com.apple.product-type.application",
                  value["PLATFORM_NAME"] as? String == "iphonesimulator",
                  let path = value["TARGET_BUILD_DIR"] as? String,
                  let name = value["FULL_PRODUCT_NAME"] as? String, name.hasSuffix(".app"),
                  let id = value["PRODUCT_BUNDLE_IDENTIFIER"] as? String, !id.isEmpty else { return nil }
            let app = URL(fileURLWithPath: path).appendingPathComponent(name).resolvingSymlinksInPath()
            guard app.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { return nil }
            return Product(app: app, bundleID: id)
        }
        guard products.count == 1 else {
            throw IOSPreviewError.unavailable("Choose a scheme that builds exactly one iOS simulator app.")
        }
        return products[0]
    }

    func run(choice: IOSPreviewBuildChoice, deviceID: String, directory: URL) async throws -> Product {
        guard UUID(uuidString: deviceID) != nil else { throw IOSPreviewError.unavailable("Choose a simulator first.") }
        guard Self.activeDevices.insert(deviceID).inserted else {
            throw IOSPreviewError.unavailable("This simulator already has a build in progress. Wait for its owned commands to stop.")
        }
        defer { Self.activeDevices.remove(deviceID) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let derived = directory.appendingPathComponent("DerivedData")
        // No reuse: callers allocate a fresh UUID directory for every invocation.
        guard !FileManager.default.fileExists(atPath: derived.path) else {
            throw IOSPreviewError.unavailable("Build directory already contains products. Start a new build.")
        }
        let base = ["/usr/bin/xcodebuild"] + choice.arguments + ["-configuration", "Debug", "-sdk", "iphonesimulator",
            "-destination", "platform=iOS Simulator,id=\(deviceID)", "-derivedDataPath", derived.path, "CODE_SIGNING_ALLOWED=NO"]
        onProgress?("Building \(choice.scheme)…")
        try Task.checkCancellation()
        _ = try await command(base + ["build"], directory.appendingPathComponent("build.log"))
        try Task.checkCancellation()
        let settings = try await command(base + ["-showBuildSettings", "-json"], nil)
        let product = try Self.product(from: settings, inside: derived)
        let infoURL = product.app.appendingPathComponent("Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == product.bundleID,
              (info?["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true else {
            throw IOSPreviewError.unavailable("The built simulator app could not be verified.")
        }
        try Task.checkCancellation()
        onProgress?("Installing \(choice.scheme)…")
        _ = try await command(["/usr/bin/xcrun", "simctl", "install", deviceID, product.app.path], nil)
        try Task.checkCancellation()
        onProgress?("Launching \(choice.scheme)…")
        _ = try await command(["/usr/bin/xcrun", "simctl", "launch", "--terminate-running-process", deviceID, product.bundleID], nil)
        try Task.checkCancellation()
        let receipt: [String: Any] = ["container": choice.container.path, "scheme": choice.scheme,
            "deviceID": deviceID, "app": product.app.path, "bundleID": product.bundleID,
            "completedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        return product
    }

    /// Called only after the owned command tree settles. Keep the small log and
    /// receipt, but discard products/package caches from this unique run. The
    /// installed simulator app has its own copy; receipt paths are provenance.
    @discardableResult
    static func releaseDerivedData(in directory: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let derived = directory.appendingPathComponent("DerivedData")
            let fm = FileManager.default
            guard fm.fileExists(atPath: derived.path) else { return true }
            do {
                try fm.removeItem(at: derived)
                return true
            } catch {
                let message = "Could not remove this run's DerivedData: \(error.localizedDescription)\n"
                try? Data(message.utf8).write(to: directory.appendingPathComponent("cleanup.log"), options: .atomic)
                return false
            }
        }.value
    }

    static func newDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"].map { URL(fileURLWithPath: $0) }
            ?? RegistryStore.defaultApplicationSupportDirectory()
        return base.appendingPathComponent("DeveloperTools/iOSPreview/Builds/\(UUID())")
    }
}
