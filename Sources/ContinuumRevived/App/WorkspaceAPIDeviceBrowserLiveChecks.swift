import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
private final class DeviceBrowserLiveReplyRecorder {
    var receive: ((String, [String: Any], [String: Any]) -> Void)?
}

/// Paid acceptance only. Every request still traverses the production API and runner bridge.
@MainActor
func runWorkspaceAPIDeviceBrowserLiveChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    let env = ProcessInfo.processInfo.environment
    guard env["ARRAY_DEVICE_BROWSER_LIVE"] == "1", env["CONTINUUM_APP_SUPPORT"] != nil,
          let output = env["ARRAY_DEVICE_BROWSER_LIVE_OUT"],
          let fixtureProject = env["ARRAY_DEVICE_BROWSER_LIVE_PROJECT"],
          let origin = env["ARRAY_DEVICE_BROWSER_LIVE_URL"],
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(description: "Use ARRAY_DEVICE_BROWSER_LIVE=1 scripts/check-device-browser-live.sh with isolated dev state.")
    }
    // The caller must perform the exact tool sequence itself. Managed's lead
    // brief can delegate it instead; pin the real Settings key in a private suite.
    let modeSuite = "array.qa.device-browser-live-free"
    let modePolicy = QAIsolatedDefaults(isolatedSuiteName: modeSuite)!
    modePolicy.removePersistentDomain(forName: modeSuite)
    modePolicy.set(false, forKey: AgentManagedModeConfig.enabledKey)
    defer { modePolicy.removePersistentDomain(forName: modeSuite) }
    let out = URL(fileURLWithPath: output)
    var evidence: [[String: Any]] = []
    var journalFailed = false
    func save() {
        do { try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("evidence.json"), options: .atomic) }
        catch { journalFailed = true }
    }
    func say(_ value: String) { print(value); fflush(stdout) }
    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    guard await waitUntil(timeout: 30, pollInterval: 0.1, { !catalog.refreshInFlightForQA }) else { throw Failure(description: "Live catalogue timed out") }
    let requested = Set((env["ARRAY_DEVICE_BROWSER_LIVE_HARNESSES"] ?? "codex,pi").split(separator: ",").map(String.init))
    guard !requested.isEmpty, requested.isSubset(of: ["codex", "pi"]) else { throw Failure(description: "Select codex and/or pi explicitly") }
    var anyFailed = false
    for harness in [AgentHarness.codex, .pi] where requested.contains(harness == .codex ? "codex" : "pi") {
        let key = harness == .codex ? "codex" : "pi"
        let snapshot = catalog.snapshot(for: harness)
        let offered = snapshot.models.first { $0.localizedCaseInsensitiveContains("mini") }
            ?? snapshot.models.first { $0.localizedCaseInsensitiveContains("luna") } ?? snapshot.seedModel
        guard snapshot.readiness.canRun, let model = env["ARRAY_DEVICE_BROWSER_LIVE_\(key.uppercased())_MODEL"] ?? offered,
              model.contains("/"), snapshot.models.contains(model) else { throw Failure(description: "\(harness.rawValue) has no ready exact catalogue selection") }
        let thinking = harness == .codex ? "medium" : "low"
        let index = evidence.count
        evidence.append(["harness": harness.rawValue, "model": model, "thinking": thinking, "calls": [], "phases": [], "approvals": [], "status": "running"])
        save()
        let f = try WorkspaceInvariantsFixture(label: "device-browser-live-\(key)")
        let root = f.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        for name in ["Sources", "InputWitness.xcodeproj"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixtureProject).appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        var supervisor: AgentSupervisor!
        defer { supervisor?.stopAll(); f.dispose() }
        f.configureMount = { delegate, _ in
            delegate.qaSettingsDefaults = modePolicy
            supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: f.appSupport),
                nameTitlerCommand: { _ in nil }, claudeSessionTitle: { _, _ in nil },
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: f.appSupport),
                transcriptStore: AgentTranscriptStore(root: f.appSupport.appendingPathComponent("transcripts")))
            delegate.agentSupervisor = supervisor
        }
        try f.mount()
        let mounted = try f.requireMounted("live tools")
        let offscreenWindow = ZoneTruthChecks.hostInWindow(mounted.canvas)
        mounted.canvas.occlusionVisibilityProvider = { true }
        defer { offscreenWindow.orderOut(nil) }
        let api = mounted.delegate.qaWorkspaceAPI
        var permission: WorkspaceToolsPermission = .free
        supervisor.workspaceToolsPermission = { permission }
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: harness, model: model,
            thinking: thinking, projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root, displayName: "Live \(key) tool acceptance")
        guard supervisor.effectiveMode(for: agent) == .free else {
            throw Failure(description: "Live device/browser's private Free setting did not reach the supervisor. No model turn was sent.")
        }
        _ = supervisor.setWorkspaceToolsEnabled(agentID: agent, true)
        let spawner = try mounted.runtime.ensureSpawner(forProjectId: WorkspaceInvariantsFixture.projectA1)
        let scope = CreationScope(projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root.path,
            homeRelativePath: nil, source: .zone, zoneId: WorkspaceInvariantsFixture.zoneA1)
        guard case let .spawned(agentTile) = spawner.spawnManagedAgentForExistingAgent(agent, supervisor: supervisor, creationScope: scope) else {
            throw Failure(description: "Could not install the live caller's tile")
        }
        supervisor.attach(agentID: agent, to: agentTile)
        mounted.delegate.wireManagedAgentTile(agentTile, agentID: agent)
        var phase = "browser"
        var denyBuild = false
        var calls: [[String: Any]] = []
        var approvals: [[String: Any]] = []
        var phases: [[String: Any]] = []
        api.approvalHandler = { prompt in
            approvals.append(["phase": phase, "op": prompt.op.rawValue, "decision": prompt.op == .deviceBuildRun && denyBuild ? "deny" : "allowForSession"])
            evidence[index]["approvals"] = approvals; save()
            return prompt.op == .deviceBuildRun && denyBuild ? .deny : .allowForSession
        }
        @MainActor func capture(_ op: String, _ payload: [String: Any], _ response: [String: Any]) {
            var bounded = response
            if var result = response["result"] as? [String: Any], var image = result["image"] as? [String: Any], let data = image.removeValue(forKey: "data") as? String {
                let file = "\(key)-\(phase)-\(calls.count).jpg"
                if let bytes = Data(base64Encoded: data) { try? bytes.write(to: out.appendingPathComponent(file)) }
                image["file"] = file; result["image"] = image; bounded["result"] = result
            }
            calls.append(["phase": phase, "op": op, "payload": payload, "response": bounded])
            evidence[index]["calls"] = calls; save()
            say("LIVE \(key) \(phase) \(op): \(response["status"] ?? "unknown")")
        }
        // Observe replies, then deliver the untouched production response. The native
        // endpoint still authenticates its real runner; Pi keeps its cancellation seam.
        mounted.delegate.workspaceMCPHost.setHandler { request, reply in
            api.handleMCPRequest(request) { response in
                capture(request["op"] as? String ?? "?", request["payload"] as? [String: Any] ?? [:], response)
                reply(response)
            }
        }
        let replyRecorder = DeviceBrowserLiveReplyRecorder()
        replyRecorder.receive = capture
        supervisor.hostToolHandler = { id, call in
            let wrapped = PiHostToolCall(request: call.request) { response, completion in
                Task { @MainActor in
                    let json = (try? JSONSerialization.jsonObject(with: Data(response.encodedValue(requestId: call.request.requestId).utf8))) as? [String: Any] ?? [:]
                    replyRecorder.receive?(call.request.op, call.request.payload, json)
                    call.respond(response, completion: completion)
                }
            }
            call.onCancel { wrapped.markCancelled() }
            api.handle(agentId: id, call: wrapped)
        }
        var completedTurns = 0
        var runtimeErrors: [String] = []
        let observer = supervisor.addDeliveredEventObserver { id, event in
            guard id == agent else { return }
            if case .turnCompleted = event { completedTurns += 1 }
            if case let .runtimeError(_, message) = event { runtimeErrors.append(message) }
        }
        let rules = "Use only Array workspace tools (load via ToolSearch if deferred). EVERY array_device_* call MUST include checkoutHandle from array_workspace_context, including array_device_build_run. A sessionId never replaces checkoutHandle. No shell, browser automation outside Array, built-in subagents or direct simctl. Read actual tool results; report errors exactly. For asynchronous builds keep calling array_get_operation until succeeded or an explicit failure/cancellation. An unchanged queued/building/installing/launching state is normal, not a reason to finish your turn. Builds may need 120 seconds and you may poll up to 120 times; never return while the build is still running. Never adopt an existing simulator UUID."
        @MainActor func turn(_ label: String, _ prompt: String, expected: String, timeout: Double = 300) async -> Bool {
            phase = label
            say("LIVE starting \(key) \(phase) model=\(model)")
            let before = completedTurns
            let callStart = calls.count
            let sent = supervisor.send(rules + "\n" + prompt, to: agent)
            var done = false
            if sent { done = await waitUntil(timeout: timeout, pollInterval: 0.1) { !supervisor.isRunning(agent) && completedTurns > before } }
            let final = supervisor.latestAssistantLine(for: agent) ?? ""
            let passed = done && final == expected
            phases.append(["phase": label, "completed": done, "final": final, "expected": expected, "status": passed ? "passed" : "failed", "callStart": callStart, "callEnd": calls.count])
            evidence[index]["phases"] = phases; evidence[index]["runtimeErrors"] = runtimeErrors; save()
            say("LIVE \(key) \(label): \(passed ? "PASS" : "FAIL") final=\(final)")
            if !done { supervisor.stop(agent); _ = await waitUntil(timeout: 10, pollInterval: 0.1) { !supervisor.isRunning(agent) } }
            return passed
        }
        var passed = await turn("browser", "Open \(origin)/\(key) with array_browser_open. Take array_browser_snapshot, click Increment once by its ref with array_browser_click (one click only), then take a fresh snapshot. Finish with exactly BROWSER_OK COUNTER_1 only after the page shows COUNTER_1.", expected: "BROWSER_OK COUNTER_1")
        let freePrompt = """
        Use array_workspace_context for your checkoutHandle. Call array_device_list. Choose an available iPhone template (prefer iPhone 17). Call array_device_open with that templateId, zoneId \(WorkspaceInvariantsFixture.zoneA1.uuidString), allowBoot true and idempotencyKey live-device.
        On its returned session call array_device_build_run kind start, projectFile InputWitness.xcodeproj, scheme InputWitness, idempotencyKey live-build-free. Poll array_get_operation until its deviceBuild state is succeeded (it is asynchronous; do not close early).
        Call array_device_observe. Tap once on the large button labeled Tap through the native preview using array_device_act, its fresh observationId, kind tap, pixel coordinates from the image, and idempotencyKey live-tap. Observe again and verify Touches received: 1. Call array_device_close.
        Finish with exactly DEVICE_OK TOUCHES_1 only when all tools succeeded and that counter is visible. If anything fails, report the exact error and stop.
        """
        let free = await turn("device-free", freePrompt, expected: "DEVICE_OK TOUCHES_1", timeout: 480)
        passed = free && passed
        let freeOpen = calls.first { $0["phase"] as? String == "device-free" && $0["op"] as? String == "device.open" && (($0["response"] as? [String: Any])?["status"] as? String) == "ok" }
        let openResult = (freeOpen?["response"] as? [String: Any])?["result"] as? [String: Any]
        let checkout = (freeOpen?["payload"] as? [String: Any])?["checkoutHandle"] as? String
        var cleanupScope: IOSPreviewAutomationSessions.Scope?
        if let checkout, let handle = CheckoutHandle(rawValue: checkout), let device = openResult?["deviceId"] as? String {
            let scope = IOSPreviewAutomationSessions.Scope(principal: agent.rawValue, project: WorkspaceInvariantsFixture.projectA1, checkout: handle)
            cleanupScope = scope
            guard try await IOSPreviewManagedDevices.shared.isOwned(deviceID: device, scope: scope) else { throw Failure(description: "Refusing unowned guest readback") }
            do {
                let bytes = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "get_app_container", device, "dev.arrayapp.preview-proof", "data"])
                let directory = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("Documents/proof-state.json"))) as! [String: Any]
                evidence[index]["guestAfterFreeTap"] = state
                passed = passed && state["taps"] as? Int == 1
            } catch { evidence[index]["guestReadbackFailure"] = error.localizedDescription; passed = false }
            if let tile = openResult?["tileId"] as? String {
                permission = .askFirst
                api.revoke(agentId: agent)
                denyBuild = true
                let reopen = "Reopen your tile \(tile) with checkoutHandle \(checkout) using array_device_open, allowBoot true."
                let denied = await turn("build-ask-denied", reopen + " Call array_device_build_run kind start, sessionId from open, projectFile InputWitness.xcodeproj, scheme InputWitness, idempotencyKey ask-build. Expect a scope_approval_required refusal, then close the session. Finish exactly BUILD_DENIED scope_approval_required if refused as expected.", expected: "BUILD_DENIED scope_approval_required")
                denyBuild = false
                let approved = await turn("build-ask-approved", reopen + " Call array_device_build_run kind start, projectFile InputWitness.xcodeproj, scheme InputWitness, sessionId from open, idempotencyKey ask-build. Poll array_get_operation until deviceBuild state succeeded. Close the session and finish exactly BUILD_APPROVED.", expected: "BUILD_APPROVED", timeout: 480)
                passed = passed && denied && approved
            }
        } else { passed = false }
        // Assert the production replies as well as the model's account of them.
        for op in ["browser.open", "browser.snapshot", "browser.click", "device.list", "device.open", "device.build_run", "device.observe", "device.act", "device.close"] {
            let ok = calls.contains { $0["op"] as? String == op && (($0["response"] as? [String: Any])?["status"] as? String) == "ok" }
            if !ok { passed = false }
        }
        for buildPhase in ["device-free", "build-ask-approved"] {
            let settled = calls.contains { call in
                guard call["phase"] as? String == buildPhase, call["op"] as? String == "operation.get",
                      let result = (call["response"] as? [String: Any])?["result"] as? [String: Any],
                      let build = result["deviceBuild"] as? [String: Any] else { return false }
                return build["state"] as? String == "succeeded"
            }
            evidence[index][buildPhase + "-buildSucceeded"] = settled
            passed = passed && settled
        }
        let denial = calls.contains { $0["phase"] as? String == "build-ask-denied" && $0["op"] as? String == "device.build_run" && (((($0["response"] as? [String: Any])?["error"]) as? [String: Any])?["code"] as? String) == "scope_approval_required" }
        let askApproval = approvals.contains { $0["phase"] as? String == "build-ask-approved" && $0["op"] as? String == "device.build_run" && $0["decision"] as? String == "allowForSession" }
        let freeHadPrompt = approvals.contains { $0["phase"] as? String == "device-free" }
        passed = passed && denial && askApproval && !freeHadPrompt && !journalFailed
        evidence[index]["freeBuildNoPrompt"] = !freeHadPrompt
        evidence[index]["askBuildDenied"] = denial
        evidence[index]["askBuildApprovedAtTrustedSeam"] = askApproval
        evidence[index]["status"] = passed ? "passed" : "failed"
        anyFailed = anyFailed || !passed
        supervisor.hostToolHandler = nil
        replyRecorder.receive = nil
        supervisor.removeDeliveredEventObserver(observer)
        api.deviceAPI.sessions.revoke(principal: agent.rawValue)
        mounted.runtime.controller(for: WorkspaceInvariantsFixture.projectA1)?.releaseRuntimes()
        if let scope = cleanupScope {
            for receipt in try await IOSPreviewManagedDevices.shared.owned(scope: scope) {
                await IOSPreviewRuntime.waitForRetirement(deviceID: receipt.deviceID)
                try await IOSPreviewManagedDevices.shared.discard(deviceID: receipt.deviceID, scope: scope)
            }
        }
        supervisor.stopAll()
        save()
    }
    guard !anyFailed && !journalFailed else { throw Failure(description: "Some live device/browser phases failed; inspect evidence.json") }
    say("Device/browser live acceptance passed: \(requested.sorted().joined(separator: ", ")), Free plus Ask first build denial/approval")
}
