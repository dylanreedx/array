import CryptoKit
import ContinuumRevivedCore
import Foundation
import Darwin

/// Each command is the leader of a fresh process group. Keep that leader
/// unreaped through cancellation escalation so a delayed signal cannot target a
/// reused PID/group. Signals never address Array's inherited process group.
private final class IOSPreviewCommandTask: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var timeout = false
    private var escalated = false
    var didCancel: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { timeout } }

    func launch(arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard let executable = arguments.first, !executable.isEmpty,
                  arguments.allSatisfy({ !$0.contains("\0") }),
                  environment.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                throw IOSPreviewError.unavailable("Invalid developer tool command.")
            }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            func checked(_ code: Int32) throws { if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) } }
            try checked(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            let input = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(input) }
            try checked(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
            try checked(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
            try checked(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
            try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try checked(posix_spawnattr_setpgroup(&attributes, 0))
            var argv = arguments.map { strdup($0) } + [nil]
            var env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }
            var child: pid_t = 0
            try checked(posix_spawn(&child, executable, &actions, &attributes, &argv, &env))
            pid = child
        }
    }

    func cancel(timedOut: Bool = false) {
        let child = lock.withLock { () -> pid_t? in
            timeout = timeout || timedOut
            guard !cancelled else { return nil }
            cancelled = true
            guard let pid else { return nil }
            _ = Darwin.kill(-pid, SIGTERM)
            return pid
        }
        guard let child else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            self.lock.withLock {
                guard self.pid == child else { return }
                _ = Darwin.kill(-child, SIGKILL)
                self.escalated = true
            }
        }
    }

    func waitForExit() throws -> Int32 {
        while true {
            let status: Int32? = try lock.withLock {
                guard let pid else { throw POSIXError(.ECHILD) }
                // Even if the leader exited on TERM, descendants can ignore it.
                // Reap only after KILL has reached the entire owned group.
                if cancelled && !escalated { return nil }
                var status: Int32 = 0
                let result = Darwin.waitpid(pid, &status, WNOHANG)
                if result == 0 { return nil }
                if result < 0 {
                    if errno == EINTR { return nil }
                    self.pid = nil
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
                }
                self.pid = nil
                return status
            }
            if let status { return status }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

enum IOSPreviewError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
}

/// All commands are typed, explicit-device operations. No shell or `booted` alias.
enum IOSPreviewCommands {
    static func run(_ arguments: [String], outputURL: URL? = nil, timeoutSeconds: Double = 120) async throws -> Data {
        let task = IOSPreviewCommandTask()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
            let output = Pipe()
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("array-ios-command-\(UUID()).log")
            let buildLog: FileHandle?
            if let outputURL {
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                buildLog = try FileHandle(forWritingTo: outputURL)
            } else { buildLog = nil }
            let errors: FileHandle
            if let buildLog { errors = buildLog }
            else {
                FileManager.default.createFile(atPath: log.path, contents: nil)
                errors = try FileHandle(forWritingTo: log)
            }
            defer { try? errors.close(); try? FileManager.default.removeItem(at: log) }
            defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
            try task.launch(arguments: arguments, environment: ToolEnvironment.shared.environment(),
                            stdout: buildLog?.fileDescriptor ?? output.fileHandleForWriting.fileDescriptor,
                            stderr: errors.fileDescriptor)
            // Unlike Foundation Process, posix_spawn does not close the parent's
            // pipe writer. Only the owned child group may retain this endpoint.
            try output.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { task.cancel(timedOut: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            defer { timeout.cancel() }
            let data = buildLog == nil ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            let terminationStatus = try task.waitForExit()
            if task.didTimeOut { throw IOSPreviewError.unavailable("Developer tool timed out. Open Xcode and try again.") }
            if task.didCancel { throw CancellationError() }
            guard terminationStatus == 0 else {
                let message = errorTail(at: outputURL ?? log)
                throw IOSPreviewError.unavailable(message.isEmpty ? "Developer tool failed." : message)
            }
            return data
            }.value
        } onCancel: { task.cancel() }
    }

    /// Agent build logs have a fixed memory/disk budget while the command is
    /// running. Keep the newest tail; never buffer the entire compiler stream.
    static func runBoundedLog(_ arguments: [String], outputURL: URL, timeoutSeconds: Double = 900) async throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 900 else {
            throw IOSPreviewError.unavailable("Invalid build deadline.")
        }
        let task = IOSPreviewCommandTask()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                var tail = Data()
                let maximumBytes = 512 * 1024
                var nextWrite = ContinuousClock.now
                try Data().write(to: outputURL, options: .atomic)
                defer { try? tail.write(to: outputURL, options: .atomic) }
                try task.launch(arguments: arguments, environment: ToolEnvironment.shared.environment(),
                    stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: pipe.fileHandleForWriting.fileDescriptor)
                var reaped = false
                defer { if !reaped { task.cancel(); _ = try? task.waitForExit() } }
                try pipe.fileHandleForWriting.close()
                let timeout = DispatchWorkItem { task.cancel(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                defer { timeout.cancel() }
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    tail.append(chunk)
                    if tail.count > maximumBytes { tail.removeFirst(tail.count - maximumBytes) }
                    if ContinuousClock.now >= nextWrite {
                        // Logging failure must not abandon a running owned tree.
                        try? tail.write(to: outputURL, options: .atomic)
                        nextWrite = .now.advanced(by: .seconds(1))
                    }
                }
                let status = try task.waitForExit()
                reaped = true
                if task.didTimeOut { throw IOSPreviewError.unavailable("Build timed out; owned commands stopped.") }
                if task.didCancel { throw CancellationError() }
                guard status == 0 else { throw IOSPreviewError.unavailable("Build failed. See the bounded build log.") }
            }.value
        } onCancel: { task.cancel() }
    }

    /// A noisy compiler may write megabytes of stderr. Retain it on disk and
    /// read only a fixed tail when forming the short in-tile failure message.
    private static func errorTail(at url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        do {
            let length = try file.seekToEnd()
            try file.seek(toOffset: length > 4096 ? length - 4096 : 0)
            let tail = try file.read(upToCount: 4096) ?? Data()
            return String(String(decoding: tail, as: UTF8.self).suffix(1400))
        } catch { return "" }
    }
}

struct IOSPreviewDevice: Equatable, Sendable {
    let id: String
    let name: String
    let runtime: String
    let isBooted: Bool
    let typeIdentifier: String?
    var template: IOSPreviewDeviceTemplate? {
        guard let typeIdentifier else { return nil }
        return IOSPreviewDeviceTemplate(typeIdentifier: typeIdentifier, runtime: runtime)
    }
    init(id: String, name: String, runtime: String, isBooted: Bool, typeIdentifier: String? = nil) {
        self.id = id; self.name = name; self.runtime = runtime; self.isBooted = isBooted; self.typeIdentifier = typeIdentifier
    }
}

/// Installation happens only after an explicit Connect. Hashes pin the exact
/// artifacts exercised in the live proof; no npm lifecycle scripts execute.
actor IOSPreviewTools {
    static let shared = IOSPreviewTools()
    struct Installation: Sendable { let addon: URL; let ws: URL; let node: URL; let bridge: URL }
    private var installationTask: Task<Installation, Error>?

    func installation() async throws -> Installation {
        if let installationTask { return try await installationTask.value }
        let task = Task { try await self.install() }
        installationTask = task
        do { return try await task.value }
        catch { installationTask = nil; throw error }
    }

    private func install() async throws -> Installation {
        let env = ToolEnvironment.shared.environment()
        guard let nodePath = (env["PATH"] ?? "").split(separator: ":").map({ String($0) + "/node" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw IOSPreviewError.unavailable("Install Node.js to connect an iOS preview.")
        }
        guard let bridge = Bundle.module.url(forResource: "bridge", withExtension: "cjs", subdirectory: "IOSPreview") else {
            throw IOSPreviewError.unavailable("The iOS preview helper is missing. Reinstall Array.")
        }
        let base = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"].map { URL(fileURLWithPath: $0) }
            ?? RegistryStore.defaultApplicationSupportDirectory()
        let root = base.appendingPathComponent("DeveloperTools/iOSPreview/expo-0.19.0-canary-20261023-1357114")
        let expo = root.appendingPathComponent("expo/package")
        let ws = root.appendingPathComponent("ws/package")
        let addon = expo.appendingPathComponent("vendor/serve-sim/dist/native/serve-sim-native.node")
        if !FileManager.default.fileExists(atPath: addon.path) {
            try await extract(
                url: "https://registry.npmjs.org/expo-device-hub/-/expo-device-hub-0.19.0-canary-20261023-1357114.tgz",
                hash: "esQLuRBpA7YgUO3/Ikxo4g9lfdX6hBRimaDz2iZTNIZXq0b2+iN1Xok74TXnWV/hLwsEFJ+SF6nKMW5QXFgn8g==",
                into: root.appendingPathComponent("expo"))
        }
        if !FileManager.default.fileExists(atPath: ws.appendingPathComponent("index.js").path) {
            try await extract(url: "https://registry.npmjs.org/ws/-/ws-8.21.0.tgz",
                hash: "Vsp28b7DRcimFQvrqu2Wek3z1iYxDCWqHYB8Qsnk/S4RfaCQzPGPyBNuVjJV3cd6UiKtUtp6sNM77gWvzcCH+g==",
                into: root.appendingPathComponent("ws"))
        }
        return Installation(addon: addon, ws: ws, node: URL(fileURLWithPath: nodePath), bridge: bridge)
    }

    private func extract(url: String, hash: String, into destination: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              Data(SHA512.hash(data: data)).base64EncodedString() == hash else {
            throw IOSPreviewError.unavailable("The iOS preview download could not be verified. Try Connect again.")
        }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent("download-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("archive.tgz")
        try data.write(to: archive)
        _ = try await IOSPreviewCommands.run(["/usr/bin/tar", "-xzf", archive.path, "-C", staging.path])
        try fm.removeItem(at: archive)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
    }

    static func devices() async throws -> [IOSPreviewDevice] {
        let data = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"])
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let groups = root?["devices"] as? [String: [[String: Any]]] ?? [:]
        return groups.filter { $0.key.contains("iOS") }.flatMap { runtime, devices in
            devices.compactMap { value -> IOSPreviewDevice? in
                guard let id = value["udid"] as? String, UUID(uuidString: id) != nil,
                      let name = value["name"] as? String, value["isAvailable"] as? Bool == true else { return nil }
                return IOSPreviewDevice(id: id, name: name, runtime: runtime,
                    isBooted: value["state"] as? String == "Booted", typeIdentifier: value["deviceTypeIdentifier"] as? String)
            }
        }.sorted { ($0.name, $0.runtime, $0.id) < ($1.name, $1.runtime, $1.id) }
    }
}
