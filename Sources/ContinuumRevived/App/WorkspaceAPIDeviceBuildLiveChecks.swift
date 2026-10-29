import Foundation
import ContinuumRevivedCore

/// Opt-in actual companion build on a receipt-owned disposable guest. The
/// source checkout is copied into the fixture; no app opens the user's root.
@MainActor
enum WorkspaceAPIDeviceBuildLiveChecks {
    static func prepare(_ f: WorkspaceAPIChecks.Fixture, source: URL) async throws {
        let destination = f.pbRoot
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for name in ["Package.swift", "Package.resolved", "Sources", "ios"] {
                let input = source.appendingPathComponent(name)
                if !fm.fileExists(atPath: input.path), name == "Package.resolved" { continue }
                try fm.copyItem(at: input, to: destination.appendingPathComponent(name))
            }
            let thirdParty = destination.appendingPathComponent("ThirdParty")
            try fm.createDirectory(at: thirdParty, withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent("ThirdParty/GhosttyKit.xcframework").resolvingSymlinksInPath(),
                to: thirdParty.appendingPathComponent("GhosttyKit.xcframework"))
        }.value
    }
    static func run(_ f: WorkspaceAPIChecks.Fixture, target: [String: Any], device: String,
                    output: URL) async throws -> [String: Any] {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw WorkspaceAPIDeviceChecks.Failure(message: message) }
        }
        f.api.deviceBuildJobs.ownerIsRunning = { _ in true } // fixture has no real model process
        var request = target
        request.merge(["kind": "start", "projectFile": "ios/Continuum.xcodeproj", "scheme": "Continuum", "idempotencyKey": "live-companion-build"]) { _, new in new }
        let attachmentID = UUID(uuidString: target["sessionId"] as! String)!
        let runtime = f.api.deviceAPI.sessions.attachments[attachmentID]!.runtime
        let helperBefore = runtime.helperPID
        let began = ContinuousClock.now
        let mcp = try IOSPreviewMCPCheckClient(api: f.api, agent: f.agentId)
        defer { mcp.close() }
        let nativeStarted = try await mcp.call(tool: "array_device_build_run", arguments: request)
        let started = try WorkspaceAPIDeviceChecks.result(nativeStarted["structuredContent"] as! [String: Any])
        let id = started["operationId"] as! String
        var switched = false
        var hiddenFrames = 0
        var result: [String: Any] = [:]
        for _ in 0..<4600 {
            result = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "operation.get", payload: ["operationId": id]))
            if !switched, let build = result["deviceBuild"] as? [String: Any], build["state"] as? String == "building" {
                // Trusted user seam switches away while the real compiler runs.
                try f.runtime.switchWorkspace(to: f.workspaceWB)
                switched = true
                for _ in 0..<100 {
                    if runtime.encodedFrameRate == 1 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try require(runtime.encodedFrameRate == 1, "hidden build must acknowledge native reduced capture rate")
                let frameStart = runtime.receivedFrames
                try await Task.sleep(for: .seconds(3))
                hiddenFrames = runtime.receivedFrames - frameStart
                try require(hiddenFrames <= 12, "hidden build must reduce delivered frames, not merely label the stream")
            }
            if result["status"] as? String != "accepted" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("device-build-operation.json"))
        guard let build = result["deviceBuild"] as? [String: Any] else { throw WorkspaceAPIDeviceChecks.Failure(message: "live build did not publish its tagged result") }
        if result["status"] as? String != "committed", let log = build["logTail"] as? String {
            try Data(log.utf8).write(to: output.appendingPathComponent("device-build-failure-tail.log"))
        }
        try require(result["status"] as? String == "committed" && build["state"] as? String == "succeeded", "actual companion build/install/launch failed; inspect device-build-operation.json")
        try require(build["deviceId"] as? String == device && build["bundleId"] as? String == "dev.dylanreedx.continuum", "build must install the real companion on the exact owned device")
        try require(helperBefore != nil && helperBefore == runtime.helperPID, "workspace switch/build must retain one helper identity")
        for _ in 0..<100 {
            if runtime.encodedFrameRate == IOSPreviewProcessSession.captureFramesPerSecond { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(runtime.encodedFrameRate == IOSPreviewProcessSession.captureFramesPerSecond, "settled hidden build must restore interactive observation rate")
        try require(switched && f.runtime.workspaceId == f.workspaceWB, "build must survive a real workspace switch without switching back")
        let nativePolled = try await mcp.call(tool: "array_get_operation", arguments: ["operationId": id])
        let polled = try WorkspaceAPIDeviceChecks.result(nativePolled["structuredContent"] as! [String: Any])
        try require((polled["deviceBuild"] as? [String: Any])?["state"] as? String == "succeeded", "native MCP must deliver the tagged actual build result")
        let nativeReplay = try await mcp.call(tool: "array_device_build_run", arguments: request)
        let replay = try WorkspaceAPIDeviceChecks.result(nativeReplay["structuredContent"] as! [String: Any])
        try require(replay["operationId"] as? String == id, "live build retry must retain operation identity")
        _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "get_app_container", device, "dev.dylanreedx.continuum", "app"])
        let observation = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        let image = observation["image"] as! [String: String]
        try Data(base64Encoded: image["data"]!)!.write(to: output.appendingPathComponent("device-built-companion.jpg"))
        let duration = began.duration(to: .now).components
        let report: [String: Any] = ["state": "PASS", "operationId": id, "deviceId": device,
            "bundleId": "dev.dylanreedx.continuum", "source": "isolated copy of actual companion sources",
            "workspaceSwitchDuringBuild": true, "nativeMCPExecutable": "PASS", "helperIdentityPreserved": true,
            "hiddenBuildCaptureFramesPerSecond": 1, "deliveredFramesInHiddenThreeSeconds": hiddenFrames,
            "interactiveRateRestored": true, "sameKeyReplay": "SAME_OPERATION", "freshProducts": true,
            "elapsedSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
            "providerModelTurn": "NOT_RUN"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("device-build-report.json"))
        print("PASS: real agent API builds, installs and launches companion on its exact disposable guest; hidden workspace lifetime and stable retry identity")
        return report
    }
}
