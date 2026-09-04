import Foundation

public struct LanguageServerCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardError: String
    public init(exitCode: Int32, standardError: String = "") { self.exitCode = exitCode; self.standardError = standardError }
}

public struct LanguageServerInstallEnvironment: Sendable {
    public var isExecutable: @Sendable (URL) -> Bool
    public var createDirectory: @Sendable (URL) throws -> Void
    public var write: @Sendable (Data, URL) throws -> Void
    public var run: @Sendable (URL, [String], URL) async throws -> LanguageServerCommandResult
    /// Downloads, verifies the expected SHA-256, and materializes the named
    /// executable beneath the supplied private destination. Keeping this seam
    /// injected makes network and archive formats testable without granting the
    /// installer an ambient network client.
    public var download: @Sendable (URL, String, URL, String) async throws -> URL

    public init(isExecutable: @escaping @Sendable (URL) -> Bool, createDirectory: @escaping @Sendable (URL) throws -> Void, write: @escaping @Sendable (Data, URL) throws -> Void, run: @escaping @Sendable (URL, [String], URL) async throws -> LanguageServerCommandResult, download: @escaping @Sendable (URL, String, URL, String) async throws -> URL) {
        self.isExecutable = isExecutable; self.createDirectory = createDirectory; self.write = write
        self.run = run; self.download = download
    }
}

public enum LanguageServerInstallError: Error, Equatable, LocalizedError {
    case unavailableInstaller(String), commandFailed(String)
    public var errorDescription: String? {
        switch self { case .unavailableInstaller(let s), .commandFailed(let s): return s }
    }
}

public struct PrivateLanguageServerInstaller: Sendable {
    public var installationRoot: URL
    public var environment: LanguageServerInstallEnvironment

    public init(installationRoot: URL, environment: LanguageServerInstallEnvironment) { self.installationRoot = installationRoot; self.environment = environment }

    public func detect(_ recipe: LanguageServerRecipe, path: String) -> URL? {
        let roots = [
            installationRoot.appendingPathComponent(recipe.id).appendingPathComponent("current/node_modules/.bin"),
            installationRoot.appendingPathComponent(recipe.id).appendingPathComponent("current/bin"),
            installationRoot.appendingPathComponent(recipe.id).appendingPathComponent("node_modules/.bin"),
            installationRoot.appendingPathComponent(recipe.id).appendingPathComponent("bin")
        ]
            + path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        for root in roots { for name in recipe.executableNames { let url = root.appendingPathComponent(name); if environment.isExecutable(url) { return url } } }
        return nil
    }

    public func install(_ recipe: LanguageServerRecipe, npmExecutable: URL?, goExecutable: URL? = nil) async throws -> URL {
        if let found = detect(recipe, path: "") { return found }
        let serverRoot = installationRoot.appendingPathComponent(recipe.id, isDirectory: true)
        let stagingRoot = installationRoot.appendingPathComponent(".staging", isDirectory: true)
        let destination = stagingRoot.appendingPathComponent("\(recipe.id)-\(UUID().uuidString)", isDirectory: true)
        try environment.createDirectory(destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        guard let strategy = recipe.installer else { throw LanguageServerInstallError.unavailableInstaller("\(recipe.displayName) must be installed by the user.") }
        let stagedExecutable: URL
        switch strategy {
        case let .npm(package, version, executable):
            guard let npmExecutable else { throw LanguageServerInstallError.unavailableInstaller("npm is required to install \(recipe.displayName).") }
            let result = try await environment.run(npmExecutable, ["install", "--no-audit", "--no-fund", "--ignore-scripts", "--prefix", destination.path, "\(package)@\(version)"], destination)
            guard result.exitCode == 0 else { throw LanguageServerInstallError.commandFailed(result.standardError) }
            let installed = destination.appendingPathComponent("node_modules/.bin/\(executable)")
            guard environment.isExecutable(installed) else { throw LanguageServerInstallError.commandFailed("Installer completed without producing \(executable).") }
            stagedExecutable = installed
        case let .go(module, version, executable):
            guard let goExecutable else { throw LanguageServerInstallError.unavailableInstaller("Go is required to install \(recipe.displayName).") }
            let bin = destination.appendingPathComponent("bin", isDirectory: true)
            let cache = destination.appendingPathComponent("gomodcache", isDirectory: true)
            try environment.createDirectory(bin)
            try environment.createDirectory(cache)
            let result = try await environment.run(
                URL(fileURLWithPath: "/usr/bin/env"),
                ["GOBIN=\(bin.path)", "GOMODCACHE=\(cache.path)", goExecutable.path, "install", "\(module)@\(version)"],
                destination
            )
            guard result.exitCode == 0 else { throw LanguageServerInstallError.commandFailed(result.standardError) }
            let installed = bin.appendingPathComponent(executable)
            guard environment.isExecutable(installed) else { throw LanguageServerInstallError.commandFailed("Installer completed without producing \(executable).") }
            stagedExecutable = installed
        case let .archive(url, sha256, executable):
            let installed = try await environment.download(url, sha256, destination, executable).standardizedFileURL
            let root = destination.standardizedFileURL.path + "/"
            guard installed.path.hasPrefix(root), environment.isExecutable(installed) else {
                throw LanguageServerInstallError.commandFailed("Downloaded server did not produce a private executable.")
            }
            stagedExecutable = installed
        }
        try Task.checkCancellation()
        let receipt = try JSONEncoder().encode(InstallReceipt(
            recipeID: recipe.id,
            displayName: recipe.displayName,
            installedAt: Date(),
            executableRelativePath: String(stagedExecutable.path.dropFirst(destination.path.count + 1))
        ))
        try environment.write(receipt, destination.appendingPathComponent("receipt.json"))
        try environment.createDirectory(serverRoot)
        let current = serverRoot.appendingPathComponent("current", isDirectory: true)
        let previous = serverRoot.appendingPathComponent("previous", isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
        if fileManager.fileExists(atPath: current.path) { try fileManager.moveItem(at: current, to: previous) }
        do {
            try fileManager.moveItem(at: destination, to: current)
        } catch {
            if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: current)
            }
            throw error
        }
        return current.appendingPathComponent(String(stagedExecutable.path.dropFirst(destination.path.count + 1)))
    }

    private struct InstallReceipt: Codable {
        var recipeID: String
        var displayName: String
        var installedAt: Date
        var executableRelativePath: String
    }
}
