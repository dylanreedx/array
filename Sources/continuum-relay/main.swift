@preconcurrency import Dispatch
import Foundation
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

struct RelayProcessConfiguration {
    var host = ProcessInfo.processInfo.environment["RELAY_HOST"] ?? "0.0.0.0"
    var port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
    var adminPort = Int(ProcessInfo.processInfo.environment["RELAY_ADMIN_PORT"] ?? "9090") ?? 9090
    var databasePath = ProcessInfo.processInfo.environment["RELAY_DATABASE_PATH"] ?? "/data/relay.sqlite"
    var masterKey: Data? {
        guard let raw = ProcessInfo.processInfo.environment["RELAY_MASTER_KEY"] else { return nil }
        return Data(base64Encoded: raw) ?? Data(raw.utf8)
    }
    var apns: RelayAPNSConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let keyID = env["APNS_KEY_ID"], let teamID = env["APNS_TEAM_ID"], let encoded = env["APNS_PRIVATE_KEY_BASE64"],
              let data = Data(base64Encoded: encoded), let pem = String(data: data, encoding: .utf8) else { return nil }
        return RelayAPNSConfiguration(keyID: keyID, teamID: teamID, privateKeyPEM: pem, topic: env["APNS_TOPIC"] ?? "dev.dylanreedx.continuum", production: env["APNS_ENVIRONMENT"] != "sandbox")
    }
}

func log(_ level: String, _ event: String, fields: [String: String] = [:]) {
    var object = fields
    object["level"] = level; object["event"] = event
    object["timestamp"] = ISO8601DateFormatter().string(from: Date())
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data ?? Data()); FileHandle.standardOutput.write(Data("\n".utf8))
}

private final class SignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if didSignal {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        guard !didSignal else { lock.unlock(); return }
        didSignal = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Dispatch requires a source to outlive its own event handler. Keeping the
/// process signal sources here avoids releasing them from the callback queue
/// while the async main task is unwinding on Linux.
private final class SignalSourceRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [any DispatchSourceSignal] = []

    func retain(_ sources: [any DispatchSourceSignal]) {
        lock.withLock { self.sources.append(contentsOf: sources) }
    }
}

private let processSignalSources = SignalSourceRetention()

let configuration = RelayProcessConfiguration()
guard let masterKey = configuration.masterKey, masterKey.count >= 32 else {
    log("error", "invalid_configuration", fields: ["field": "RELAY_MASTER_KEY"]); exit(2)
}
do {
    let parent = URL(fileURLWithPath: configuration.databasePath).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let store = try RelayStore(path: configuration.databasePath, masterKey: masterKey)
    let pushDelivery: (any RelayEventPushDelivering)? = try configuration.apns.map { try RelayAPNSService(store: store, configuration: $0, transport: RelayURLSessionAPNSTransport()) }
    let server = RelayServer(store: store, configuration: .init(host: configuration.host, publicPort: configuration.port, adminPort: configuration.adminPort), pushDelivery: pushDelivery)
    try await server.start()
    log("info", "ready", fields: ["public_port": "\(configuration.port)", "admin_port": "\(configuration.adminPort)"])

    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let waiter = SignalWaiter()
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let signalHandler: @Sendable () -> Void = { waiter.signal() }
    term.setEventHandler(handler: signalHandler)
    interrupt.setEventHandler(handler: signalHandler)
    processSignalSources.retain([term, interrupt])
    term.resume(); interrupt.resume()
    await withCheckedContinuation { waiter.wait($0) }
    log("info", "shutting_down")
    try await server.stop()
    log("info", "stopped")
    exit(0)
} catch {
    log("error", "startup_or_runtime_failure", fields: ["error_type": String(describing: type(of: error))]); exit(1)
}
