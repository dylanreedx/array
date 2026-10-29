import AppKit
import ContinuumRevivedCore
import ImageIO

/// Runs only inside the existing opt-in live gate, on its newly created UIKit
/// witness device. The caller supplies the exact owned UDID and readback file.
@MainActor
enum WorkspaceAPIDeviceLiveChecks {
    static func run(device: String, statePath: String, output: URL) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw WorkspaceAPIDeviceChecks.Failure(message: message) }
        }
        var guestPath = statePath
        func state() -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: guestPath)),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return result
        }
        func wait(_ label: String, _ ready: () -> Bool) async throws {
            for _ in 0..<500 { if ready() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw WorkspaceAPIDeviceChecks.Failure(message: "live API guest readback timed out: " + label + "; state=" + String(describing: state()))
        }
        let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.device-live.\(UUID())")!
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let traceURL = output.appendingPathComponent("connection-trace.txt")
        let oldFactory = IOSPreviewRuntime.sessionFactory
        IOSPreviewRuntime.sessionFactory = { TracedSession(output: traceURL) }
        defer { IOSPreviewRuntime.sessionFactory = oldFactory }
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings)
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        defer {
            f.api.deviceAPI.sessions.revoke(principal: f.agentId.rawValue)
            f.runtime.controller(for: f.projectPb)?.releaseRuntimes()
            supervisor.stopAll()
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let originalCounter = state()["taps"] as! Int
        let source = try await IOSPreviewTools.devices().first { $0.id == device }!
        let template = source.template!
        let scope = IOSPreviewAutomationSessions.Scope(principal: f.agentId.rawValue, project: f.projectPb, checkout: f.pbHandle)
        func cleanup() async throws {
            f.api.deviceAPI.sessions.revoke(principal: f.agentId.rawValue)
            f.runtime.controller(for: f.projectPb)?.releaseRuntimes()
            for receipt in try await IOSPreviewManagedDevices.shared.owned(scope: scope) {
                await IOSPreviewRuntime.waitForRetirement(deviceID: receipt.deviceID)
                try await IOSPreviewManagedDevices.shared.discard(deviceID: receipt.deviceID, scope: scope)
            }
        }
        do {
        if let sourceRoot = ProcessInfo.processInfo.environment["IOS_PREVIEW_LIVE_AGENT_BUILD_PROJECT"] {
            // Preparing hundreds of MB of code/dependencies is not activity on
            // an automated simulator; do it before acquiring its idle lease.
            try await WorkspaceAPIDeviceBuildLiveChecks.prepare(f, source: URL(fileURLWithPath: sourceRoot))
        }
        let opened = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.open", payload: [
            "checkoutHandle": f.pbHandle.rawValue, "zoneId": f.zoneB.uuidString, "templateId": template.id,
            "allowBoot": true, "idempotencyKey": "live-owned-create"]))
        let ownedDevice = opened["deviceId"] as! String
        try require(ownedDevice != device, "new agent tile must create a fresh device, never adopt the template source")
        guard let app = ProcessInfo.processInfo.environment["CONTINUUM_IOS_PREVIEW_WITNESS_APP"] else {
            throw WorkspaceAPIDeviceChecks.Failure(message: "live harness must supply its disposable witness app")
        }
        _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "install", ownedDevice, app])
        _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "launch", ownedDevice, "dev.arrayapp.preview-proof"])
        let container = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "get_app_container", ownedDevice, "dev.arrayapp.preview-proof", "data"])
        guestPath = URL(fileURLWithPath: String(decoding: container, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("Documents/proof-state.json").path
        let target: [String: Any] = ["checkoutHandle": f.pbHandle.rawValue, "sessionId": opened["sessionId"]!]
        try await wait("initial portrait layout") { (state()["height"] as? Double ?? 0) > (state()["width"] as? Double ?? 1) && state()["button"] != nil }
        let observation = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try require(observation["orientation"] as? Int == 1, "live API must return upright portrait geometry")
        var observationMilliseconds: [Double] = []
        var mainTicks = 0
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { mainTicks += 1 }
        }
        defer { ticker.invalidate() }
        for _ in 0..<10 {
            let begin = ContinuousClock.now
            _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
            let duration = begin.duration(to: .now).components
            observationMilliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        ticker.invalidate()
        try require(mainTicks > 0, "main run loop must keep serving UI while fresh observations wait/decode")
        // Explicit observations replace the old handle, so acquire the frame
        // used for the tap after the benchmark.
        let tapObservation = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        let before = state()["taps"] as! Int
        let button = state()["button"] as! [String: Double]
        let width = observation["width"] as! Int, height = observation["height"] as! Int
        var action = target
        action["kind"] = "tap"; action["observationId"] = tapObservation["observationId"]
        action["x"] = button["x"]! * Double(width); action["y"] = button["y"]! * Double(height)
        action["idempotencyKey"] = "live-exactly-one-tap"
        let actionBegan = ContinuousClock.now
        let result = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: action))
        let actionDuration = actionBegan.duration(to: .now).components
        let actionMilliseconds = Double(actionDuration.seconds) * 1000 + Double(actionDuration.attoseconds) / 1e15
        try require(result["outcome"] as? String == "native_sequence_completed", "real input requires a native completion acknowledgement")
        try await wait("portrait tap counter") { state()["taps"] as? Int == before + 1 }
        _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: action))
        let after = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try require((after["sequence"] as! Int) > (observation["sequence"] as! Int), "live API must return another newly emitted frame after the action")
        var stale = action; stale["idempotencyKey"] = "live-stale-frame"
        let rejected = await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: stale)
        try require((rejected["error"] as? [String: Any])?["code"] as? String == "target_conflict", "replaced observation must be rejected before native input")
        try await Task.sleep(for: .milliseconds(300))
        try require(state()["taps"] as? Int == before + 1, "replay/stale call must cause zero extra UIKit taps")
        try require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontmost, "device API must not steal Mac app focus")
        // Each extended action travels through the same production API as taps.
        // Test helper inputs are normalized image coordinates, converted to the
        // fresh API image's pixels here; production performs the native transform.
        func act(_ action: IOSPreviewBoundedAction) async throws {
            let fresh = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
            var payload = action.payload!
            for key in ["x", "endX"] { if let value = payload[key] as? Double { payload[key] = value * Double(fresh["width"] as! Int) } }
            for key in ["y", "endY"] { if let value = payload[key] as? Double { payload[key] = value * Double(fresh["height"] as! Int) } }
            payload.merge(target) { _, value in value }
            payload["observationId"] = fresh["observationId"]
            payload["idempotencyKey"] = UUID().uuidString
            _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: payload))
            // Every action kind must also share exactly-once retry behavior.
            _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: payload))
        }
        let fieldPoint = state()["field"] as! [String: Double]
        try await act(.tap(x: fieldPoint["x"]!, y: fieldPoint["y"]!))
        try await wait("API field focus") { state()["fieldFocused"] as? Bool == true }
        try await act(.text("café 🧪 漢字"))
        try await wait("API Unicode text") { state()["text"] as? String == "café 🧪 漢字" }
        try await act(.key("backspace"))
        try await wait("API named backspace") { state()["text"] as? String == "café 🧪 漢" }
        let swipesBefore = state()["swipes"] as? Int ?? 0
        try await act(.swipe(x: 0.02, y: 0.7, endX: 0.02, endY: 0.3, milliseconds: 200))
        try await wait("API UIKit swipe") { state()["swipes"] as? Int == swipesBefore + 1 }
        try await act(.key("return"))
        try await wait("API Return dismisses field") { state()["fieldFocused"] as? Bool == false }
        try await act(.rotate(3))
        try await wait("landscape transition completed") {
            (state()["width"] as? Double ?? 0) > (state()["height"] as? Double ?? 1) && state()["transitioning"] as? Bool == false
        }
        var oldGeometry = action; oldGeometry["idempotencyKey"] = "old-geometry-after-rotation"
        oldGeometry["observationId"] = after["observationId"]
        let oldGeometryResult = await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: oldGeometry)
        try require((oldGeometryResult["error"] as? [String: Any])?["code"] as? String == "target_conflict", "old geometry must cause zero native action")
        let landscape = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try require(landscape["orientation"] as? Int == 3 && (landscape["width"] as! Int) > (landscape["height"] as! Int), "real landscape screenshot must be upright")
        let beforeLandscapeImage = landscape["image"] as! [String: String]
        try Data(base64Encoded: beforeLandscapeImage["data"]!)!.write(to: output.appendingPathComponent("device-api-landscape-before-tap.jpg"))
        try JSONSerialization.data(withJSONObject: state(), options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("landscape-state-before.json"))
        let landscapeButton = state()["button"] as! [String: Double]
        var landscapeAction = target
        landscapeAction["kind"] = "tap"; landscapeAction["observationId"] = landscape["observationId"]
        landscapeAction["x"] = landscapeButton["x"]! * Double(landscape["width"] as! Int)
        landscapeAction["y"] = landscapeButton["y"]! * Double(landscape["height"] as! Int)
        landscapeAction["idempotencyKey"] = "live-landscape-one-tap"
        _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: landscapeAction))
        try await wait("landscape tap counter") { state()["taps"] as? Int == before + 2 }
        _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.act", payload: landscapeAction))
        let landscapeAfter = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try require(state()["taps"] as? Int == before + 2, "portrait and landscape retries must never add a third tap")
        let image = after["image"] as! [String: String]
        let jpeg = Data(base64Encoded: image["data"]!)!
        try require(CGImageSourceCreateWithData(jpeg as CFData, nil) != nil, "live returned image must decode")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try jpeg.write(to: output.appendingPathComponent("device-api-after-tap.jpg"))
        let landscapeImage = landscapeAfter["image"] as! [String: String]
        try Data(base64Encoded: landscapeImage["data"]!)!.write(to: output.appendingPathComponent("device-api-landscape-after-tap.jpg"))
        try await act(.home)
        try await wait("API Home backgrounds app") { state()["active"] as? Bool == false }
        _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "launch", ownedDevice, "dev.arrayapp.preview-proof"])
        var buildReport: [String: Any] = ["state": "NOT_RUN"]
        if ProcessInfo.processInfo.environment["IOS_PREVIEW_LIVE_AGENT_BUILD_PROJECT"] != nil {
            // Companion currently presents portrait UI; start its build proof
            // from settled portrait, independently of the earlier landscape test.
            try await act(.rotate(1))
            try await wait("portrait before companion build") {
                (state()["height"] as? Double ?? 0) > (state()["width"] as? Double ?? 1) && state()["transitioning"] as? Bool == false
            }
            buildReport = try await WorkspaceAPIDeviceBuildLiveChecks.run(f, target: target, device: ownedDevice,
                output: output)
            _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "launch", ownedDevice, "dev.arrayapp.preview-proof"])
            try await wait("witness active after companion build") { state()["active"] as? Bool == true }
        }
        _ = try WorkspaceAPIDeviceChecks.result(await WorkspaceAPIDeviceChecks.call(f.api, agent: f.agentId, op: "device.close", payload: target))
        try require(state()["taps"] as? Int == before + 2, "closing the attachment must preserve the running guest")
        guestPath = statePath
        try require(state()["taps"] as? Int == originalCounter, "the template source simulator must receive zero input")
        observationMilliseconds.sort()
        let report: [String: Any] = ["workspaceAPI": "PASS", "agentBuild": buildReport, "device": ownedDevice, "templateSourceDevice": device,
            "templateSourceUnchanged": true, "apiUnicodeReadback": "PASS", "apiBackspaceReadback": "PASS", "apiSwipeReadback": "PASS", "apiHomeReadback": "PASS", "apiRotationReadback": "PASS", "hostCreatedDisposable": true, "tapsBefore": before, "tapsAfter": before + 2, "portraitTap": "PASS", "landscapeTap": "PASS", "oldGeometryRejected": true,
            "nativeAcknowledgement": "PASS", "sameKeyReplay": "NO_EXTRA_INPUT", "staleFrame": "REJECTED",
            "freshSequenceBefore": observation["sequence"]!, "freshSequenceAfter": after["sequence"]!,
            "width": width, "height": height, "landscapeWidth": landscape["width"]!, "landscapeHeight": landscape["height"]!, "nativeCaptureTimeKnown": false, "macFocusPreserved": true,
            "providerModelTurn": "NOT_RUN", "snapshotSamples": observationMilliseconds.count,
            "snapshotP50Milliseconds": observationMilliseconds[max(0, Int(ceil(Double(observationMilliseconds.count) * 0.5)) - 1)],
            "snapshotP95Milliseconds": observationMilliseconds[max(0, Int(ceil(Double(observationMilliseconds.count) * 0.95)) - 1)],
            "snapshotSamplesMilliseconds": observationMilliseconds, "percentileMethod": "nearest rank",
            "mainRunLoopPumpSeconds": 0.02, "tapNativeAckMilliseconds": actionMilliseconds,
            "mainRunLoopTicksDuringSnapshots": mainTicks, "latencyEndpoint": "API reply, not physical display scanout"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("device-api-report.json"))
        try await cleanup()
        print("PASS: real workspace API observe/tap/observe changes the disposable UIKit counter once per requested orientation; retry and stale frame cause no extra input; fresh image returned without Mac focus change; host-created device cleaned by receipt, template simulator unchanged")
        } catch {
            try await cleanup()
            throw error
        }
    }
    @MainActor
    private final class TracedSession: IOSPreviewSession {
        private let base = IOSPreviewProcessSession()
        private let output: URL
        var helperPID: Int32? { base.helperPID }
        var encodedFrameRate: Int? { base.encodedFrameRate }
        func setReducedCapture(_ reduced: Bool) { base.setReducedCapture(reduced) }
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        init(output: URL) {
            self.output = output
            base.onFrame = { [weak self] image in self?.onFrame?(image) }
            base.onFailure = { [weak self] message in
                self?.trace("failure: " + message)
                self?.onFailure?(message)
            }
        }
        private func trace(_ message: String) {
            var data = (try? Data(contentsOf: output)) ?? Data()
            data.append(Data((Date().description + " " + message + "\n").utf8))
            try? data.write(to: output, options: .atomic)
        }
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws {
            trace("start " + deviceID)
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trace("starting helperPID=" + String(self.helperPID ?? 0))
                }
            }
            defer { timer.invalidate() }
            do {
                try await base.start(deviceID: deviceID, allowBoot: allowBoot, orientation: orientation)
                trace("start returned")
            } catch {
                trace("start error: " + error.localizedDescription)
                throw error
            }
        }
        func send(tag: UInt8, payload: [String: Any]) { base.send(tag: tag, payload: payload) }
        func observe() async throws -> IOSPreviewObservation { try await base.observe() }
        func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int?) async throws {
            try await base.acknowledgedTap(x: x, y: y, geometryGeneration: geometryGeneration)
        }
        func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int?) async throws {
            try await base.acknowledgedAction(action, geometryGeneration: geometryGeneration)
        }
        func stop() { base.stop() }
        func stop(completion: @escaping @MainActor () -> Void) { base.stop(completion: completion) }
    }

}
