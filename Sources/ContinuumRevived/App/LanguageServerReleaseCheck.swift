import ContinuumRevivedCore
import Foundation

/// `--language-server-release-check`: a language server is released once the
/// last file tile using it closes (after a short grace), and not before. They
/// used to stay resident — sourcekit-lsp, tsserver, often hundreds of MB —
/// until the app quit.
@MainActor
enum LanguageServerReleaseCheck {
    /// A transport that records what the coordinator sent it.
    private final class RecordingTransport: LanguageServerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        private var stopped = 0
        var log: [String] { lock.withLock { methods } }
        var stopCount: Int { lock.withLock { stopped } }
        func request(method: String, params: LSPValue) async throws -> LSPValue {
            lock.withLock { methods.append(method) }
            return .object([:])
        }
        func notify(method: String, params: LSPValue) async throws {
            lock.withLock { methods.append(method) }
        }
        func stop() async { lock.withLock { stopped += 1 } }
        func setNotificationHandler(_ handler: (@Sendable (String, LSPValue) -> Void)?) async {}
    }

    struct CheckError: Error, CustomStringConvertible { let description: String }

    static func run() throws -> URL {
        let transports = LockedList<RecordingTransport>()
        let grace: TimeInterval = 0.2
        let manager = EditorLanguageServiceManager(coordinatorFactory: { root, _ in
            let transport = RecordingTransport()
            transports.append(transport)
            let coordinator = LanguageServiceCoordinator(projectRoot: root, transport: transport)
            try await coordinator.initialize(processId: nil)
            return coordinator
        }, releaseGrace: grace)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-lsp-release-\(UUID().uuidString)", isDirectory: true)
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        var ready: Set<String> = []
        func open(_ name: String) {
            manager.open(fileURL: file(name), projectRoot: root, text: "let x = 1\n", version: 1,
                         status: { if case .ready = $0 { ready.insert(name) } }, diagnostics: { _ in })
        }
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func shutdowns() -> Int { transports.items.reduce(0) { $0 + $1.log.filter { $0 == "shutdown" }.count } }

        // Two Swift file tiles share one server.
        open("a.swift"); open("b.swift")
        guard pump(until: 5, { ready == ["a.swift", "b.swift"] }) else {
            throw CheckError(description: "files never became ready: \(ready)")
        }
        guard transports.items.count == 1, manager.qaSessionCount == 1 else {
            throw CheckError(description: "two files of one language must share one server; servers=\(transports.items.count)")
        }

        // Closing one keeps the server for the other.
        manager.close(fileURL: file("a.swift"), projectRoot: root)
        pump(grace * 4)
        guard shutdowns() == 0, manager.qaSessionCount == 1 else {
            throw CheckError(description: "the server was released while b.swift still had it open")
        }

        // Closing the last releases it after the grace.
        manager.close(fileURL: file("b.swift"), projectRoot: root)
        guard pump(until: grace * 10, { shutdowns() == 1 && manager.qaSessionCount == 0 }) else {
            throw CheckError(description: "the server outlived its last file: shutdowns=\(shutdowns()) sessions=\(manager.qaSessionCount)")
        }
        guard transports.items.first?.log.contains("exit") == true, transports.items.first?.stopCount == 1 else {
            throw CheckError(description: "a released server must be sent shutdown+exit and its process stopped: \(transports.items.first?.log ?? [])")
        }

        // Reopening within the grace keeps the (new) server: no cold start.
        ready.removeAll()
        open("c.swift")
        guard pump(until: 5, { ready.contains("c.swift") }) else { throw CheckError(description: "c.swift never became ready") }
        manager.close(fileURL: file("c.swift"), projectRoot: root)
        open("d.swift")
        guard pump(until: 5, { ready.contains("d.swift") }) else { throw CheckError(description: "d.swift never became ready") }
        pump(grace * 4)
        guard transports.items.count == 2, shutdowns() == 1, manager.qaSessionCount == 1 else {
            throw CheckError(description: "reopening within the grace must keep the server: servers=\(transports.items.count) shutdowns=\(shutdowns())")
        }
        manager.close(fileURL: file("d.swift"), projectRoot: root)
        _ = pump(until: grace * 10, { manager.qaSessionCount == 0 })

        let artifact = FileManager.default.temporaryDirectory.appendingPathComponent("language-server-release-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["check": "language-server-release", "shutdowns": shutdowns()])
            .write(to: artifact, options: .atomic)
        return artifact
    }
}

private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    var items: [Element] { lock.withLock { storage } }
    func append(_ element: Element) { lock.withLock { storage.append(element) } }
}
