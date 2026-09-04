import Foundation

#if os(macOS)
/// A shell-free Process adapter for JSON-RPC stdio. Lifecycle is guarded because
/// FileHandle callbacks arrive outside the coordinator actor.
public final class ProcessLanguageServerByteStream: @unchecked Sendable, LanguageServerByteStream {
    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.environment = environment
    }

    public func start(_ receive: @escaping @Sendable (Data) -> Void, _ terminated: @escaping @Sendable (Error?) -> Void) async throws {
        let process = Process(); let stdin = Pipe(); let stdout = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = workingDirectory; process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout
        // A language server may log indefinitely. An unread stderr Pipe can fill
        // and deadlock the server, so discard it until the app supplies a bounded
        // diagnostics sink.
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; if !data.isEmpty { receive(data) } }
        process.terminationHandler = { _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            terminated(nil)
        }
        lock.withLock { self.process = process; self.input = stdin.fileHandleForWriting }
        do { try process.run() } catch { lock.withLock { self.process = nil; self.input = nil }; throw error }
    }

    public func write(_ data: Data) async throws {
        let handle = lock.withLock { input }
        guard let handle else { throw LanguageServerTransportError.stopped }
        try handle.write(contentsOf: data)
    }

    public func stop() async {
        let state = lock.withLock { () -> (Process?, FileHandle?) in defer { process = nil; input = nil }; return (process, input) }
        try? state.1?.close()
        if state.0?.isRunning == true { state.0?.terminate() }
    }
}
#endif
