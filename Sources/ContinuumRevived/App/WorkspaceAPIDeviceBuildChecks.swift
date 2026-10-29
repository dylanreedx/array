import Foundation
import ContinuumRevivedCore

@MainActor
enum WorkspaceAPIDeviceBuildChecks {
    static func run(_ f: WorkspaceAPIChecks.Fixture, session: String, mcp: IOSPreviewMCPCheckClient) async throws {
        func require(_ value: Bool, _ message: String) throws { if !value { throw WorkspaceAPIDeviceChecks.Failure(message: message) } }
        func result(_ response: [String: Any]) throws -> [String: Any] { try WorkspaceAPIDeviceChecks.result(response) }
        print("WorkspaceAPIDeviceBuildChecks starting")
        func call(_ op: String, _ payload: [String: Any]) async -> [String: Any] {
            let response = await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: op, payload: payload)
            if response["status"] as? String == "error" {
                print("BUILD CHECK reply: op=\(op) kind=\(payload["kind"] ?? "none") key=\(payload["idempotencyKey"] ?? "none") error=\(response["error"] ?? "none")")
            }
            return response
        }
        var hold = false, fail = false, failInstall = false, calls: [[String]] = []
        f.api.deviceBuildJobs.ownerIsRunning = { _ in true } // fixture has no real model turn
        f.api.deviceBuildJobs.makeBuilder = {
            let builder = IOSPreviewBuild()
            builder.command = { args, log in
                calls.append(args)
                if args.contains("-list") { return Data("{\"project\":{\"schemes\":[\"App\"]}}".utf8) }
                if args.last == "build" {
                    if hold { try await Task.sleep(for: .seconds(10)) }
                    if fail { throw IOSPreviewError.unavailable("fixture compiler failure") }
                    let index = args.firstIndex(of: "-derivedDataPath")!
                    let app = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("Build/App.app")
                    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                    let info: [String: Any] = ["CFBundleIdentifier": "dev.array.api.build.check", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
                    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
                    if let log { try Data(String(repeating: "fixture compiler output\n", count: 2000).utf8).write(to: log) }
                }
                if args.contains("-showBuildSettings") {
                    let index = args.firstIndex(of: "-derivedDataPath")!
                    return try JSONSerialization.data(withJSONObject: [["buildSettings": ["PRODUCT_TYPE": "com.apple.product-type.application", "PLATFORM_NAME": "iphonesimulator", "TARGET_BUILD_DIR": args[index + 1] + "/Build", "FULL_PRODUCT_NAME": "App.app", "PRODUCT_BUNDLE_IDENTIFIER": "dev.array.api.build.check"]]])
                }
                if args.count > 2, args[1] == "simctl", args[2] == "install", failInstall { throw IOSPreviewError.unavailable("fixture install failure") }
                return Data()
            }
            return builder
        }
        defer { for job in f.api.deviceBuildJobs.jobs.values { try? FileManager.default.removeItem(at: job.directory) } }
        let target: [String: Any] = ["checkoutHandle": f.pbHandle.rawValue, "sessionId": session,
            "kind": "start", "projectFile": "App.xcodeproj", "scheme": "App", "idempotencyKey": "build-one"]
        func settled(_ id: String) async throws -> [String: Any] {
            for _ in 0..<500 {
                let response = try result(await call("operation.get", ["operationId": id]))
                if response["status"] as? String != "accepted" { return response }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw WorkspaceAPIDeviceChecks.Failure(message: "API build operation did not settle")
        }
        let prompts = f.api.approvalPromptCount
        let started = try result(await call("device.build_run", target)), id = started["operationId"] as! String
        try require(f.api.approvalPromptCount == prompts + 1, "device Open session grant must not silently authorize builds under Ask first")
        let completed = try await settled(id)
        let build = completed["deviceBuild"] as! [String: Any]
        try require(completed["status"] as? String == "committed" && build["kind"] as? String == "device_build" && build["state"] as? String == "succeeded" && completed["childResult"] == nil,
            "operation.get must publish a tagged build result, not a delegated child answer")
        try require((build["logTail"] as? String ?? "").utf8.count <= 8192 && build["logTruncated"] as? Bool == true, "operation result must bound compiler diagnostics")
        let beforeRetry = calls.count
        let replay = try result(await call("device.build_run", target))
        try require(replay["operationId"] as? String == id && calls.count == beforeRetry, "same-key build must retain operation identity without re-running commands")
        var conflict = target; conflict["scheme"] = "Another"
        let conflicted = await call("device.build_run", conflict)
        try require((conflicted["error"] as? [String: Any])?["code"] as? String == "idempotency_conflict", "changed build payload must conflict")
        var escaped = target; escaped["projectFile"] = "../Outside.xcodeproj"; escaped["idempotencyKey"] = "escape"
        let escapedResult = await call("device.build_run", escaped)
        try require(escapedResult["status"] as? String == "error" && calls.count == beforeRetry, "escaping project container must be rejected before any command")
        fail = true; calls = []
        var failure = target; failure["idempotencyKey"] = "build-failed"
        let failed = try result(await call("device.build_run", failure)), failedID = failed["operationId"] as! String
        let failedResult = try await settled(failedID)
        try require((failedResult["deviceBuild"] as? [String: Any])?["state"] as? String == "failed" && !calls.contains { $0.contains("install") }, "failed API build must not install stale products")
        let failureCalls = calls.count
        _ = try result(await call("device.build_run", failure))
        try require(calls.count == failureCalls, "failed accepted job must not silently rerun on retry")
        fail = false; hold = true; calls = []
        var pending = target; pending["idempotencyKey"] = "build-cancelled"
        let running = try result(await call("device.build_run", pending)), runningID = running["operationId"] as! String
        for _ in 0..<200 { if calls.contains(where: { $0.last == "build" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        _ = try result(await call("device.build_run", ["checkoutHandle": f.pbHandle.rawValue, "kind": "cancel", "operationId": runningID]))
        let cancelled = try await settled(runningID)
        try require((cancelled["deviceBuild"] as? [String: Any])?["state"] as? String == "cancelled" && !calls.contains { $0.contains("install") }, "API cancellation must stop before installation")
        hold = false; failInstall = true; calls = []
        var install = target; install["idempotencyKey"] = "install-uncertain"
        let installing = try result(await call("device.build_run", install)), installID = installing["operationId"] as! String
        let uncertain = try await settled(installID)
        try require((uncertain["deviceBuild"] as? [String: Any])?["state"] as? String == "outcome_unknown" && !calls.contains { $0.contains("launch") }, "installation failure must preserve uncertainty and skip launch")
        failInstall = false; calls = []
        var nativeRequest = target; nativeRequest["idempotencyKey"] = "native-mcp-build"
        let nativeReply = try await mcp.call(tool: "array_device_build_run", arguments: nativeRequest)
        let nativeStarted = try result(nativeReply["structuredContent"] as! [String: Any])
        let nativeID = nativeStarted["operationId"] as! String
        _ = try await settled(nativeID)
        let nativePoll = try await mcp.call(tool: "array_get_operation", arguments: ["operationId": nativeID])
        let nativeResult = try result(nativePoll["structuredContent"] as! [String: Any])
        try require((nativeResult["deviceBuild"] as? [String: Any])?["state"] as? String == "succeeded", "actual MCP executable must deliver tagged build result")
        let nativeCalls = calls.count
        _ = try await mcp.call(tool: "array_device_build_run", arguments: nativeRequest)
        try require(calls.count == nativeCalls, "native MCP build retry must not repeat commands")
        hold = true; calls = []
        var revokedRequest = target; revokedRequest["idempotencyKey"] = "revoked-api-build"
        let revokedStart = try result(await call("device.build_run", revokedRequest))
        let revokedID = revokedStart["operationId"] as! String
        for _ in 0..<200 { if calls.contains(where: { $0.last == "build" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        f.api.revoke(agentId: f.agentId)
        for _ in 0..<500 { if f.api.deviceBuildJobs.jobs[revokedID]?.task == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        try require(f.api.deviceBuildJobs.jobs[revokedID]?.state == "cancelled" && !calls.contains { $0.contains("install") }, "production API revocation must cancel its owned build before install")
        print("WorkspaceAPIDeviceBuildChecks passed: separate Ask-first build grant, accepted job identity, tagged operation polling, bounded log, same-key success/failure replay, payload conflict, path escape denial, failure/cancel no-install install uncertainty/no-launch, native MCP and revoke cancellation")
    }
}
