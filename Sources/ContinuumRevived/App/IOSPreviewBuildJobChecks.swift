import AppKit
import ContinuumRevivedCore

@MainActor
enum IOSPreviewBuildJobChecks {
    private final class Native: IOSPreviewSession {
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        var stopped = false
        var encodedFrameRate: Int? = 30
        func setReducedCapture(_ reduced: Bool) { encodedFrameRate = reduced ? 1 : 30 }
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws { onFrame?(IOSPreviewChecks.image()) }
        func send(tag: UInt8, payload: [String: Any]) {}
        func stop() { stopped = true }
    }
    static func run() async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw IOSPreviewChecks.Failure(description: message) }
        }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<500 { if ready() { return }; try await Task.sleep(for: .milliseconds(5)) }
            throw IOSPreviewChecks.Failure(description: "build job witness timed out")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-build-jobs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = IOSPreviewRuntime.sessionFactory, native = Native()
        IOSPreviewRuntime.sessionFactory = { native }
        let runtime = IOSPreviewRuntime(tileID: UUID(), deviceID: UUID().uuidString)
        let sessions = IOSPreviewAutomationSessions()
        defer {
            for id in Array(sessions.attachments.keys) { sessions.release(id: id) }
            runtime.disconnect(); IOSPreviewRuntime.sessionFactory = factory
        }
        runtime.connect(allowBoot: false)
        try await wait { runtime.state == .connected }
        let scope = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: UUID(), checkout: CheckoutHandle.derive(canonicalRoot: root.path))
        let entry = try sessions.attach(runtime: runtime, scope: scope)
        runtime.retireViewer()
        var ownerActive = true, authorized = true, hold = false, fail = false
        var calls: [[String]] = []
        let jobs = IOSPreviewBuildJobs(sessions: sessions, ownerIsRunning: { _ in ownerActive })
        defer { for job in jobs.jobs.values { try? FileManager.default.removeItem(at: job.directory) } }
        jobs.makeBuilder = {
            let builder = IOSPreviewBuild()
            builder.command = { args, log in
                calls.append(args)
                if args.contains("-list") { return Data("{\"project\":{\"schemes\":[\"App\"]}}".utf8) }
                if args.last == "build" {
                    if hold { try await Task.sleep(for: .seconds(10)) }
                    if fail { throw IOSPreviewError.unavailable("deliberate build failure") }
                    let index = args.firstIndex(of: "-derivedDataPath")!
                    let app = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("Build/App.app")
                    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                    let plist: [String: Any] = ["CFBundleIdentifier": "dev.array.job.check", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
                    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
                    if let log { try Data("bounded fixture log".utf8).write(to: log) }
                }
                if args.contains("-showBuildSettings") {
                    let index = args.firstIndex(of: "-derivedDataPath")!
                    return try JSONSerialization.data(withJSONObject: [["buildSettings": [
                        "PRODUCT_TYPE": "com.apple.product-type.application", "PLATFORM_NAME": "iphonesimulator",
                        "TARGET_BUILD_DIR": args[index + 1] + "/Build", "FULL_PRODUCT_NAME": "App.app", "PRODUCT_BUNDLE_IDENTIFIER": "dev.array.job.check"]]])
                }
                return Data()
            }
            return builder
        }
        func start(_ id: String) throws -> IOSPreviewBuildJobs.Job {
            try jobs.start(id: id, sessionID: entry.id, scope: scope, root: root, projectFile: "App.xcodeproj", scheme: "App", authorized: { authorized }, settled: { _ in })
        }
        let success = try start("success")
        try await wait { success.task == nil }
        try require(success.state == "succeeded" && success.bundleID == "dev.array.job.check", "service job must settle with verified product identity")
        try require(calls.filter { $0.count > 2 && $0[1] == "simctl" }.allSatisfy { ($0[2] == "install" ? $0[3] : $0[4]) == runtime.deviceID }, "install and launch must retain the exact leased device")
        try require(!FileManager.default.fileExists(atPath: success.directory.appendingPathComponent("DerivedData").path), "settled service job must release only its products")
        try require(runtime.state == .connected && !native.stopped, "hidden job must retain the one native runtime")
        calls = []; fail = true
        let failed = try start("failed")
        try await wait { failed.task == nil }
        try require(failed.state == "failed" && !calls.contains { $0.contains("install") }, "failed build must never install stale products")
        fail = false; hold = true; calls = []
        let cancelled = try start("cancelled")
        try require(native.encodedFrameRate == 1, "hidden build must reduce capture demand while retaining ownership")
        runtime.resume()
        try require(native.encodedFrameRate == 30, "visible build must restore interactive capture")
        runtime.suspend()
        try require(native.encodedFrameRate == 1, "hiding a running build must lower capture demand again")
        try await wait { calls.contains { $0.last == "build" } }
        do { _ = try start("duplicate"); throw IOSPreviewChecks.Failure(description: "overlapping job admitted") }
        catch is IOSPreviewBuildJobs.Failure {}
        let humanBuilder = IOSPreviewBuild()
        do {
            _ = try await humanBuilder.run(choice: .init(container: root.appendingPathComponent("App.xcodeproj"), scheme: "App"), deviceID: runtime.deviceID!, directory: root.appendingPathComponent("competing-human"))
            throw IOSPreviewChecks.Failure(description: "human build raced agent build")
        } catch is IOSPreviewError {}
        try jobs.cancel(id: cancelled.id, scope: scope)
        try await wait { cancelled.task == nil }
        try require(native.encodedFrameRate == 30, "settled build must restore interactive observations")
        try require(cancelled.state == "cancelled" && !calls.contains { $0.contains("install") }, "cancelled service build must stop before installation")
        calls = []
        let ended = try start("owner-ended")
        try await wait { calls.contains { $0.last == "build" } }
        ownerActive = false; jobs.sweep()
        try await wait { ended.task == nil }
        try require(ended.state == "cancelled" && !calls.contains { $0.contains("install") }, "agent ending must cancel its owned build")
        ownerActive = true; calls = []
        let revoked = try start("revoked")
        try await wait { calls.contains { $0.last == "build" } }
        authorized = false; jobs.sweep()
        try await wait { revoked.task == nil }
        try require(revoked.state == "cancelled" && !calls.contains { $0.contains("install") }, "revocation must cancel a build before install")
        authorized = true; calls = []
        let deadline = try start("deadline")
        try await wait { calls.contains { $0.last == "build" } }
        let afterDeadline = ContinuousClock.now.advanced(by: .seconds(901))
        jobs.now = { afterDeadline }; jobs.sweep()
        try await wait { deadline.task == nil }
        try require(deadline.state == "cancelled" && deadline.failureReason == "deadline" && !calls.contains { $0.contains("install") }, "whole-job deadline must release owned build before install")
        let foreign = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: scope.project, checkout: scope.checkout)
        try require(jobs.lookup(id: success.id, scope: foreign) == nil, "foreign owner must not inspect a job")
        print("IOSPreviewBuildJobChecks passed: service lifetime, exact device, hidden retention, fresh products, failed/cancelled/ended/revoked no-install, per-owner capacity, human/agent device exclusion, scoped results and cleanup")
    }
}
