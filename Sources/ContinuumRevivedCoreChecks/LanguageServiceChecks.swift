import ContinuumRevivedCore
import Foundation

private actor FakeLanguageTransport: LanguageServerTransport {
    var calls: [(String, String, LSPValue)] = []
    var notificationHandler: (@Sendable (String, LSPValue) -> Void)?
    func request(method: String, params: LSPValue) async throws -> LSPValue {
        calls.append(("request", method, params))
        if method == "textDocument/completion" { return .object(["items": .array([.object(["label": .string("print"), "detail": .string("function")])])]) }
        if method == "textDocument/definition" { return .array([.object(["uri": .string("file:///root/Def.swift"), "range": .object(["start": .object(["line": .number(1), "character": .number(2)]), "end": .object(["line": .number(1), "character": .number(5)])])])]) }
        return .object([:])
    }
    func notify(method: String, params: LSPValue) async throws { calls.append(("notify", method, params)) }
    func stop() async { calls.append(("stop", "", .null)) }
    func setNotificationHandler(_ handler: (@Sendable (String, LSPValue) -> Void)?) { notificationHandler = handler }
    func methods() -> [String] { calls.map(\.1) }
}

private final class InstallerWitness: @unchecked Sendable {
    let lock = NSLock(); var executablePaths = Set<String>(); var command: [String] = []; var checksum: String?
    func executable(_ url: URL) -> Bool { lock.withLock { executablePaths.contains(url.path) } }
    func record(_ arguments: [String], installed: String) { lock.withLock { command = arguments; executablePaths.insert(installed) } }
    func download(checksum: String, destination: URL, executable: String) -> URL { lock.withLock { self.checksum = checksum; let url = destination.appendingPathComponent(executable); executablePaths.insert(url.path); return url } }
}

private final class ScriptedByteStream: @unchecked Sendable, LanguageServerByteStream {
    let lock = NSLock(); var receive: (@Sendable (Data) -> Void)?
    func start(_ receive: @escaping @Sendable (Data) -> Void, _ terminated: @escaping @Sendable (Error?) -> Void) async throws { lock.withLock { self.receive = receive } }
    func write(_ data: Data) async throws {
        let separator = Data("\r\n\r\n".utf8); guard let boundary = data.range(of: separator) else { return }
        let body = data.subdata(in: boundary.upperBound..<data.count)
        guard case .object(let request) = try JSONDecoder().decode(LSPValue.self, from: body), let id = request["id"] else { return }
        let response = try JSONEncoder().encode(LSPValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .string("ok")]))
        let framed = LSPContentLengthFramer.frame(response); let midpoint = framed.count / 2
        let receiver = lock.withLock { receive }; receiver?(framed.prefix(midpoint)); receiver?(framed.suffix(from: midpoint))
    }
    func stop() async {}
}

func runLanguageServiceChecks() async throws {
    expect(LanguageServerCatalog.recipe(forFileURL: URL(fileURLWithPath: "/tmp/a.tsx"))?.id == "typescript", "language server catalog maps TSX")
    expect(LanguageServerCatalog.recipe(forFileURL: URL(fileURLWithPath: "/tmp/a.swift"))?.executableNames == ["sourcekit-lsp"], "catalog prefers the toolchain SourceKit-LSP")

    let bodyA = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}".utf8)
    let bodyB = Data("{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}".utf8)
    let framed = LSPContentLengthFramer.frame(bodyA) + LSPContentLengthFramer.frame(bodyB)
    var framer = LSPContentLengthFramer()
    var decoded: [Data] = []
    for byte in framed { decoded += try framer.append(Data([byte])) }
    expect(decoded == [bodyA, bodyB], "stdio framer handles byte fragmentation and adjacent messages")
    let scripted = ScriptedByteStream()
    let rpc = JSONRPCLanguageServerTransport(stream: scripted)
    let correlated = try await rpc.request(method: "probe", params: .null)
    expect(correlated == .string("ok"), "JSON-RPC transport correlates a fragmented stdio response")
    await rpc.stop()

    let witness = InstallerWitness()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-lsp-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = root.appendingPathComponent("typescript/current/node_modules/.bin/typescript-language-server").path
    let environment = LanguageServerInstallEnvironment(
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        write: { try $0.write(to: $1, options: .atomic) },
        run: { _, arguments, directory in
            let installed = directory.appendingPathComponent("node_modules/.bin/typescript-language-server")
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: installed.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            witness.record(arguments, installed: installed.path)
            return .init(exitCode: 0)
        },
        download: { _, checksum, destination, executable in
            let installed = witness.download(checksum: checksum, destination: destination, executable: executable)
            FileManager.default.createFile(atPath: installed.path, contents: Data("fixture".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            return installed
        }
    )
    let installer = PrivateLanguageServerInstaller(installationRoot: root, environment: environment)
    let installed = try await installer.install(LanguageServerCatalog.builtIns.first { $0.id == "typescript" }!, npmExecutable: URL(fileURLWithPath: "/usr/bin/npm"))
    expect(installed.path == expected, "private installer returns its scoped executable")
    expect(witness.lock.withLock { witness.command.contains("typescript-language-server@4.3.4") && witness.command.contains("--ignore-scripts") }, "installer pins package version and disables lifecycle scripts")
    let archiveRecipe = LanguageServerRecipe(id: "fixture", displayName: "Fixture", languages: ["fixture"], fileExtensions: ["fixture"], executableNames: ["fixture-lsp"], installer: .archive(url: URL(string: "https://fixture.invalid/lsp.zip")!, sha256: "abc123", executable: "fixture-lsp"))
    let downloaded = try await installer.install(archiveRecipe, npmExecutable: nil)
    expect(downloaded.path.hasPrefix(root.appendingPathComponent("fixture/current").path + "/") && witness.lock.withLock { witness.checksum == "abc123" }, "archive downloader must verify and atomically promote into the recipe's private directory")
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("typescript/current/receipt.json").path), "private installs must retain a versioned receipt")

    let transport = FakeLanguageTransport()
    let coordinator = LanguageServiceCoordinator(projectRoot: URL(fileURLWithPath: "/root"), transport: transport)
    try await coordinator.initialize(processId: 42)
    let uri = "file:///root/Main.swift"
    try await coordinator.open(.init(uri: uri, languageId: "swift", text: "pri", version: 1))
    try await coordinator.change(uri: uri, text: "print", version: 2)
    try await coordinator.change(uri: uri, text: "stale", version: 1)
    try await coordinator.save(uri: uri)
    let completions = try await coordinator.completion(uri: uri, position: .init(line: 0, character: 5))
    let definitions = try await coordinator.definition(uri: uri, position: .init(line: 0, character: 1))
    try await coordinator.close(uri: uri)
    expect(completions.first?.label == "print", "completion result supports CompletionList")
    expect(definitions.first?.uri == "file:///root/Def.swift", "definition locations decode")
    let methods = await transport.methods()
    expect(methods.filter { $0 == "textDocument/didChange" }.count == 1, "stale document versions are suppressed")
    expect(methods.contains("initialize") && methods.contains("initialized") && methods.contains("textDocument/didOpen") && methods.contains("textDocument/didSave") && methods.contains("textDocument/didClose"), "coordinator owns the LSP document lifecycle")
}
