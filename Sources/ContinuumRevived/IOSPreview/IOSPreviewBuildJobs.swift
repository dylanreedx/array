import Foundation
import ContinuumRevivedCore

/// Service-owned build lifetime. This internal foundation is not advertised as a
/// workspace capability until operation/grant/API/live witnesses are complete.
@MainActor
final class IOSPreviewBuildJobs {
    enum Failure: Error { case busy, notOwned, invalidChoice }
    final class Job {
        let id: String
        let scope: IOSPreviewAutomationSessions.Scope
        let sessionID: UUID
        let deviceID: String
        let directory: URL
        let projectFile: String
        let scheme: String
        let startedAt = ContinuousClock.now
        var state = "queued"
        var failureReason: String?
        var bundleID: String?
        var logTail: String?
        var logTruncated = false
        var mayHaveInstalled = false
        var task: Task<Void, Error>?
        var authorized: (() -> Bool)?
        init(id: String, entry: IOSPreviewAutomationSessions.Attachment, deviceID: String, directory: URL, projectFile: String, scheme: String) {
            self.id = id; scope = entry.scope; sessionID = entry.id
            self.deviceID = deviceID; self.directory = directory
            self.projectFile = projectFile; self.scheme = scheme
        }
    }
    private(set) var jobs: [String: Job] = [:]
    private let sessions: IOSPreviewAutomationSessions
    var ownerIsRunning: (UUID) -> Bool
    private var timer: Timer?
    var now: () -> ContinuousClock.Instant = { .now }
    var makeBuilder: () -> IOSPreviewBuild = {
        let builder = IOSPreviewBuild()
        builder.command = { arguments, log in
            if let log {
                try await IOSPreviewCommands.runBoundedLog(arguments, outputURL: log)
                return Data()
            }
            return try await IOSPreviewCommands.run(arguments, timeoutSeconds: 60)
        }
        return builder
    }
    init(sessions: IOSPreviewAutomationSessions, ownerIsRunning: @escaping (UUID) -> Bool) {
        self.sessions = sessions; self.ownerIsRunning = ownerIsRunning
    }

    func start(id: String, sessionID: UUID, scope: IOSPreviewAutomationSessions.Scope,
               root: URL, projectFile: String, scheme: String,
               authorized: @escaping () -> Bool, settled: @escaping (Job) -> Void) throws -> Job {
        guard authorized(), ownerIsRunning(scope.principal) else { throw Failure.notOwned }
        let entry = try sessions.validate(id: sessionID, scope: scope)
        guard jobs[id] == nil, entry.inFlight == nil, !entry.observing,
              jobs.values.filter({ $0.task != nil }).count < 2,
              !jobs.values.contains(where: { $0.task != nil && $0.scope.principal == scope.principal }),
              let deviceID = entry.runtime.deviceID else { throw Failure.busy }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let container = canonicalRoot.appendingPathComponent(projectFile).resolvingSymlinksInPath().standardizedFileURL
        guard !projectFile.hasPrefix("/"), !projectFile.contains("\0"), projectFile.utf8.count <= 1024,
              container.path.hasPrefix(canonicalRoot.path + "/"),
              ["xcodeproj", "xcworkspace"].contains(container.pathExtension),
              !scheme.isEmpty, scheme.utf8.count <= 256, !scheme.contains("\0") else { throw Failure.invalidChoice }
        let job = Job(id: id, entry: entry, deviceID: deviceID, directory: IOSPreviewBuild.newDirectory(), projectFile: projectFile, scheme: scheme)
        job.authorized = authorized
        jobs[id] = job
        for old in jobs.values.filter({ $0.task == nil && $0.id != id }).sorted(by: { $0.id < $1.id }).dropLast(63) {
            jobs[old.id] = nil
        }
        let builder = makeBuilder()
        let command = builder.command
        builder.command = { [weak self] arguments, log in
            guard let self, authorized(), self.ownerIsRunning(scope.principal) else { throw CancellationError() }
            _ = try self.sessions.validate(id: sessionID, scope: scope)
            try Task.checkCancellation()
            if arguments.count > 4, arguments[1] == "simctl", arguments[2] == "install" {
                job.mayHaveInstalled = true
                if let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[4]).appendingPathComponent("Info.plist")),
                   let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    job.bundleID = info["CFBundleIdentifier"] as? String
                }
            }
            let data = try await command(arguments, log)
            try Task.checkCancellation()
            guard authorized() else { throw CancellationError() }
            _ = try self.sessions.validate(id: sessionID, scope: scope)
            return data
        }
        builder.onProgress = { message in
            job.state = message.hasPrefix("Installing") ? "installing" : message.hasPrefix("Launching") ? "launching" : "building"
        }
        let task = Task<Void, Error> { [self] in
            do {
                // Probe only the explicitly scoped container, never siblings or
                // symlinked projects elsewhere on the host.
                let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
                let data = try await builder.command(["/usr/bin/xcodebuild", flag, container.path, "-list", "-json"], nil)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let value = (json?["workspace"] ?? json?["project"]) as? [String: Any]
                guard (value?["schemes"] as? [String])?.contains(scheme) == true else { throw Failure.invalidChoice }
                let choice = IOSPreviewBuildChoice(container: container, scheme: scheme)
                let product = try await builder.run(choice: choice, deviceID: deviceID, directory: job.directory)
                job.bundleID = product.bundleID; job.state = "succeeded"
            } catch is CancellationError {
                job.state = job.mayHaveInstalled ? "outcome_unknown" : "cancelled"
                job.failureReason = job.failureReason ?? "session_cancelled"
            } catch {
                job.state = job.mayHaveInstalled ? "outcome_unknown" : "failed"
                job.failureReason = error is Failure ? "invalid_choice" : "command_failed"
            }
            await IOSPreviewBuild.releaseDerivedData(in: job.directory)
            let logURL = job.directory.appendingPathComponent("build.log")
            let tail = await Task.detached(priority: .utility) {
                let url = logURL
                guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
                let data = (try? handle.read(upToCount: 8192)) ?? Data()
                var text = String(decoding: data, as: UTF8.self)
                let expanded = text.utf8.count > 8192
                while text.utf8.count > 8192 { text.removeFirst() }
                return (text, size > 8192 || expanded)
            }.value
            job.logTail = tail.0; job.logTruncated = tail.1
            entry.runtime.setAutomationBuildActive(false)
            entry.inFlight = nil; entry.touchedAt = sessions.now()
            job.task = nil; job.authorized = nil
            settled(job)
            if !jobs.values.contains(where: { $0.task != nil }) { timer?.invalidate(); timer = nil }
        }
        job.task = task; entry.inFlight = task; entry.touchedAt = sessions.now()
        entry.runtime.setAutomationBuildActive(true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
        }
        return job
    }
    func result(_ job: Job) -> DeviceBuildOperationResult {
        DeviceBuildOperationResult(state: job.state, deviceId: job.deviceID, projectFile: job.projectFile,
            scheme: job.scheme, bundleId: job.bundleID, mayHaveInstalled: job.mayHaveInstalled,
            logTail: job.logTail, logTruncated: job.logTruncated, failureReason: job.failureReason)
    }
    func lookup(id: String, scope: IOSPreviewAutomationSessions.Scope) -> Job? {
        guard let job = jobs[id], job.scope == scope else { return nil }
        return job
    }
    func cancel(id: String, scope: IOSPreviewAutomationSessions.Scope) throws {
        guard let job = lookup(id: id, scope: scope) else { throw Failure.notOwned }
        if job.task != nil { job.failureReason = "user_cancelled"; job.task?.cancel() }
    }
    func sweep() {
        for job in jobs.values where job.task != nil {
            let reason: String?
            if job.startedAt.duration(to: now()) >= .seconds(900) { reason = "deadline" }
            else if !ownerIsRunning(job.scope.principal) { reason = "owner_ended" }
            else if job.authorized?() != true { reason = "grant_revoked" }
            else if (try? sessions.validate(id: job.sessionID, scope: job.scope)) == nil { reason = "session_ended" }
            else { reason = nil }
            if let reason { job.failureReason = job.failureReason ?? reason; job.task?.cancel() }
        }
    }
}
