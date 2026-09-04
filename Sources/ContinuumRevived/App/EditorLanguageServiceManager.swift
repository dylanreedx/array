import ContinuumRevivedCore
import Foundation

@MainActor
final class EditorLanguageServiceManager {
    enum Status: Equatable {
        case unavailable
        case installing(String)
        case starting(String)
        case ready(String)
        case failed(String)
    }

    private struct SessionKey: Hashable { var root: String; var recipe: String }
    private struct Entry {
        var coordinator: LanguageServiceCoordinator
        var openURIs: Set<String>
    }

    private var sessions: [SessionKey: Entry] = [:]
    private var pending: [SessionKey: Task<LanguageServiceCoordinator, Error>] = [:]
    private var diagnosticSinks: [String: @MainActor ([LSPDiagnostic]) -> Void] = [:]
    private let installer: PrivateLanguageServerInstaller
    private let searchPath: String

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppChannel.liveApplicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("LanguageSupport", isDirectory: true)
        searchPath = ToolSearchPath.merged(
            loginShellPath: ProcessInfo.processInfo.environment["PATH"] ?? "",
            processPath: ProcessInfo.processInfo.environment["PATH"] ?? "",
            wellKnown: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        )
        installer = PrivateLanguageServerInstaller(
            installationRoot: support,
            environment: LanguageServerInstallEnvironment(
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
                createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
                write: { try $0.write(to: $1, options: .atomic) },
                run: { executable, arguments, directory in
                    let process = Process()
                    let errorPipe = Pipe()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errorPipe
                    try process.run()
                    return await withCheckedContinuation { continuation in
                        process.terminationHandler = { process in
                            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                            continuation.resume(returning: LanguageServerCommandResult(
                                exitCode: process.terminationStatus,
                                standardError: String(decoding: data.prefix(4_096), as: UTF8.self)
                            ))
                        }
                    }
                },
                download: { _, _, _, _ in
                    throw LanguageServerInstallError.unavailableInstaller("This server requires a supported toolchain installation.")
                }
            )
        )
    }

    func open(
        fileURL: URL,
        projectRoot: URL,
        text: String,
        version: UInt64,
        status: @escaping @MainActor (Status) -> Void,
        diagnostics: @escaping @MainActor ([LSPDiagnostic]) -> Void
    ) {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL) else {
            status(.unavailable)
            return
        }
        let key = SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)
        status(.starting(recipe.displayName))
        Task { [weak self] in
            guard let self else { return }
            do {
                let coordinator = try await self.coordinator(for: key, recipe: recipe, root: projectRoot) {
                    status(.installing(recipe.displayName))
                }
                self.diagnosticSinks[fileURL.absoluteString] = diagnostics
                await coordinator.setDiagnosticsHandler { [weak self] uri, values in
                    Task { @MainActor in self?.diagnosticSinks[uri]?(values) }
                }
                let document = LanguageDocumentSnapshot(
                    uri: fileURL.absoluteString,
                    languageId: recipe.languages.first ?? fileURL.pathExtension,
                    text: text,
                    version: Int(clamping: version)
                )
                try await coordinator.open(document)
                var entry = self.sessions[key]!
                entry.openURIs.insert(fileURL.absoluteString)
                self.sessions[key] = entry
                status(.ready(recipe.displayName))
            } catch {
                status(.failed(error.localizedDescription))
            }
        }
    }

    func change(fileURL: URL, projectRoot: URL, text: String, version: UInt64) {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL) else { return }
        let key = SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)
        guard let coordinator = sessions[key]?.coordinator else { return }
        Task { try? await coordinator.change(uri: fileURL.absoluteString, text: text, version: Int(clamping: version)) }
    }

    func save(fileURL: URL, projectRoot: URL) {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL),
              let coordinator = sessions[SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)]?.coordinator
        else { return }
        Task { try? await coordinator.save(uri: fileURL.absoluteString) }
    }

    func close(fileURL: URL, projectRoot: URL) {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL) else { return }
        let key = SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)
        guard let coordinator = sessions[key]?.coordinator else { return }
        sessions[key]?.openURIs.remove(fileURL.absoluteString)
        diagnosticSinks.removeValue(forKey: fileURL.absoluteString)
        Task { try? await coordinator.close(uri: fileURL.absoluteString) }
    }

    func completion(fileURL: URL, projectRoot: URL, position: LSPPosition) async -> [LSPCompletionItem] {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL),
              let coordinator = sessions[SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)]?.coordinator
        else { return [] }
        return (try? await coordinator.completion(uri: fileURL.absoluteString, position: position)) ?? []
    }

    func definition(fileURL: URL, projectRoot: URL, position: LSPPosition) async -> [LSPLocation] {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL),
              let coordinator = sessions[SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)]?.coordinator
        else { return [] }
        return (try? await coordinator.definition(uri: fileURL.absoluteString, position: position)) ?? []
    }

    func hover(fileURL: URL, projectRoot: URL, position: LSPPosition) async -> String? {
        guard let recipe = LanguageServerCatalog.recipe(forFileURL: fileURL),
              let coordinator = sessions[SessionKey(root: projectRoot.standardizedFileURL.path, recipe: recipe.id)]?.coordinator,
              let value = try? await coordinator.hover(uri: fileURL.absoluteString, position: position)
        else { return nil }
        return Self.hoverText(value)
    }

    func shutdown() {
        let values = sessions.values.map(\.coordinator)
        sessions.removeAll(); pending.values.forEach { $0.cancel() }; pending.removeAll()
        values.forEach { coordinator in Task { await coordinator.shutdown() } }
    }

    private func coordinator(
        for key: SessionKey,
        recipe: LanguageServerRecipe,
        root: URL,
        installing: @escaping @MainActor () -> Void
    ) async throws -> LanguageServiceCoordinator {
        if let existing = sessions[key]?.coordinator { return existing }
        if let task = pending[key] { return try await task.value }
        let installer = self.installer
        let path = searchPath
        let task = Task<LanguageServiceCoordinator, Error> {
            var executable = installer.detect(recipe, path: path)
            if executable == nil, recipe.installer != nil {
                await installing()
                let npm = Self.findExecutable("npm", path: path)
                let go = Self.findExecutable("go", path: path)
                executable = try await installer.install(recipe, npmExecutable: npm, goExecutable: go)
            }
            guard let executable else {
                throw LanguageServerInstallError.unavailableInstaller("\(recipe.displayName) is unavailable. Install its language toolchain to enable code intelligence.")
            }
            let stream = ProcessLanguageServerByteStream(
                executable: executable, arguments: recipe.arguments,
                workingDirectory: root,
                environment: ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
            )
            let coordinator = LanguageServiceCoordinator(projectRoot: root, transport: JSONRPCLanguageServerTransport(stream: stream))
            try await coordinator.initialize(processId: Int(ProcessInfo.processInfo.processIdentifier))
            return coordinator
        }
        pending[key] = task
        do {
            let value = try await task.value
            pending[key] = nil
            sessions[key] = Entry(coordinator: value, openURIs: [])
            return value
        } catch {
            pending[key] = nil
            throw error
        }
    }

    private static func findExecutable(_ name: String, path: String) -> URL? {
        for part in path.split(separator: ":") {
            let value = URL(fileURLWithPath: String(part), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: value.path) { return value }
        }
        return nil
    }

    private static func hoverText(_ value: LSPValue) -> String? {
        switch value {
        case let .string(text): return text
        case let .array(values):
            let parts = values.compactMap(hoverText)
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case let .object(object):
            if let contents = object["contents"] { return hoverText(contents) }
            if let value = object["value"] { return hoverText(value) }
            return nil
        default: return nil
        }
    }
}
