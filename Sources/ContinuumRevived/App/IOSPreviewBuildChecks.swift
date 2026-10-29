import Foundation

@MainActor
enum IOSPreviewBuildChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw IOSPreviewChecks.Failure(description: message) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-ios-build-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let container = root.appendingPathComponent("An App With Spaces.xcodeproj")
        let choice = IOSPreviewBuildChoice(container: container, scheme: "A Scheme With Spaces")
        let device = UUID().uuidString
        let builder = IOSPreviewBuild()
        var calls: [[String]] = []
        var failBuild = false
        var cancelBuild = false
        var omitProduct = false
        var emptySettings = false
        var builtBundleID = "dev.array.preview.check"
        var builtPlatforms = ["iPhoneSimulator"]
        var failingStep: String?
        var activeDirectory = root.appendingPathComponent("success")
        builder.command = { arguments, log in
            calls.append(arguments)
            if arguments.count > 2, arguments[1] == "simctl", arguments[2] == failingStep {
                throw IOSPreviewError.unavailable("deliberate \(arguments[2]) failure")
            }
            if arguments.last == "build" {
                if cancelBuild { try await Task.sleep(nanoseconds: 10_000_000_000) }
                if failBuild { throw IOSPreviewError.unavailable("deliberate compiler error") }
                let app = activeDirectory.appendingPathComponent("DerivedData/Build/Products/Debug-iphonesimulator/App.app")
                if !omitProduct {
                    try fm.createDirectory(at: app, withIntermediateDirectories: true)
                    let plist: [String: Any] = ["CFBundleIdentifier": builtBundleID, "CFBundleSupportedPlatforms": builtPlatforms]
                    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
                }
                if let log { try Data("build output".utf8).write(to: log) }
            }
            if arguments.contains("-showBuildSettings") {
                if emptySettings { return Data("[]".utf8) }
                return try JSONSerialization.data(withJSONObject: [["buildSettings": [
                    "PRODUCT_TYPE": "com.apple.product-type.application", "PLATFORM_NAME": "iphonesimulator",
                    "TARGET_BUILD_DIR": activeDirectory.appendingPathComponent("DerivedData/Build/Products/Debug-iphonesimulator").path,
                    "FULL_PRODUCT_NAME": "App.app", "PRODUCT_BUNDLE_IDENTIFIER": "dev.array.preview.check"]]])
            }
            return Data()
        }
        let product = try await builder.run(choice: choice, deviceID: device, directory: activeDirectory)
        try expect(calls.count == 4, "build, settings, install and launch must run exactly once")
        try expect(calls[0].contains(container.path) && calls[0].contains(choice.scheme), "spaces must remain literal argv entries")
        try expect(calls[0].contains("platform=iOS Simulator,id=\(device)"), "build must target selected UDID")
        try expect(calls[2] == ["/usr/bin/xcrun", "simctl", "install", device, product.app.path], "install must use fresh app and exact device")
        try expect(calls[3] == ["/usr/bin/xcrun", "simctl", "launch", "--terminate-running-process", device, product.bundleID], "launch must use verified bundle ID and exact device")
        try expect(fm.fileExists(atPath: activeDirectory.appendingPathComponent("run.json").path), "successful run must write provenance")
        calls = []
        do { _ = try await builder.run(choice: choice, deviceID: device, directory: activeDirectory); throw IOSPreviewChecks.Failure(description: "stale products accepted") }
        catch is IOSPreviewError { }
        try expect(calls.isEmpty, "existing products must fail before commands")
        activeDirectory = root.appendingPathComponent("failed")
        failBuild = true
        do { _ = try await builder.run(choice: choice, deviceID: device, directory: activeDirectory); throw IOSPreviewChecks.Failure(description: "failed build installed an app") }
        catch is IOSPreviewError { }
        try expect(calls.count == 1 && calls[0].last == "build", "failed build must never inspect, install or launch stale products")
        calls = []; failBuild = false; cancelBuild = true
        activeDirectory = root.appendingPathComponent("cancelled")
        let task = Task { try await builder.run(choice: choice, deviceID: device, directory: activeDirectory) }
        while calls.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; throw IOSPreviewChecks.Failure(description: "cancelled build succeeded") }
        catch is CancellationError { }
        try expect(calls.count == 1, "cancelled build must never install or launch")
        // Every admission barrier must prevent the following side effect; an
        // exit code alone cannot establish that a stale/invalid app was refused.
        cancelBuild = false
        for (mode, expectedCalls) in [("missing-product", 2), ("missing-settings-product", 2),
                                      ("mismatched-bundle", 2), ("device-platform", 2),
                                      ("install-failure", 3), ("launch-failure", 4)] {
            calls = []
            activeDirectory = root.appendingPathComponent(mode)
            omitProduct = mode == "missing-product"
            emptySettings = mode == "missing-settings-product"
            builtBundleID = mode == "mismatched-bundle" ? "dev.array.wrong.product" : "dev.array.preview.check"
            builtPlatforms = mode == "device-platform" ? ["iPhoneOS"] : ["iPhoneSimulator"]
            failingStep = mode == "install-failure" ? "install" : mode == "launch-failure" ? "launch" : nil
            var observedFailure: Error?
            do { _ = try await builder.run(choice: choice, deviceID: device, directory: activeDirectory) }
            catch { observedFailure = error }
            try expect(observedFailure != nil, "\(mode) must fail")
            try expect(calls.count == expectedCalls, "\(mode) must stop before any later command")
            try expect(!fm.fileExists(atPath: activeDirectory.appendingPathComponent("run.json").path),
                       "\(mode) must never mint a successful run receipt")
        }
        let outside = try JSONSerialization.data(withJSONObject: [["buildSettings": [
            "PRODUCT_TYPE": "com.apple.product-type.application", "PLATFORM_NAME": "iphonesimulator",
            "TARGET_BUILD_DIR": "/tmp", "FULL_PRODUCT_NAME": "Stale.app", "PRODUCT_BUNDLE_IDENTIFIER": "stale"]]])
        do { _ = try IOSPreviewBuild.product(from: outside, inside: root); throw IOSPreviewChecks.Failure(description: "outside product accepted") }
        catch is IOSPreviewError { }
        // A stale build outcome may never hide the actual transport state.
        let running = "Running an old device's app"
        try expect(IOSPreviewTileNSView.statusText(state: .failed("Transport failed"), buildMessage: running) == "Transport failed",
                   "transport failure must take precedence over a previous successful build")
        try expect(!IOSPreviewTileNSView.statusText(state: .disconnected, buildMessage: running).contains(running),
                   "a disconnected tile must not claim that an old build is running")
        try expect(IOSPreviewTileNSView.statusText(state: .connecting, buildMessage: running) == "Connecting to simulator…",
                   "a fresh connection must not display stale build status")
        try expect(IOSPreviewTileNSView.statusText(state: .connected, buildMessage: running) == running,
                   "the current live connection must retain its build progress/outcome")

        // Retain useful diagnostics, never the per-run 1.5GiB dependency tree.
        let cleanupRoot = root.appendingPathComponent("cleanup")
        let derived = cleanupRoot.appendingPathComponent("DerivedData/SourcePackages/checkouts")
        try fm.createDirectory(at: derived, withIntermediateDirectories: true)
        let log = cleanupRoot.appendingPathComponent("build.log")
        let receipt = cleanupRoot.appendingPathComponent("run.json")
        let sibling = root.appendingPathComponent("other-run/DerivedData")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("diagnostics".utf8).write(to: log)
        try Data("receipt".utf8).write(to: receipt)
        try Data("owned products".utf8).write(to: derived.appendingPathComponent("artifact"))
        let released = await IOSPreviewBuild.releaseDerivedData(in: cleanupRoot)
        try expect(released && !fm.fileExists(atPath: cleanupRoot.appendingPathComponent("DerivedData").path),
                   "a completed run must discard its own products and dependency cache")
        try expect(fm.fileExists(atPath: log.path) && fm.fileExists(atPath: receipt.path),
                   "build cleanup must retain its log and successful run receipt")
        try expect(fm.fileExists(atPath: sibling.path), "build cleanup must never touch another run")
        let repeatedCleanup = await IOSPreviewBuild.releaseDerivedData(in: cleanupRoot)
        try expect(repeatedCleanup, "build cleanup must be idempotent")
        print("IOSPreviewBuildChecks passed: exact scheme/device, fresh products, verified bundle, provenance, missing/mismatched product rejection, install/launch failure barriers, build failure barrier, cancellation barrier, stale-product rejection, connection-status precedence and scoped product cleanup")
    }
}
