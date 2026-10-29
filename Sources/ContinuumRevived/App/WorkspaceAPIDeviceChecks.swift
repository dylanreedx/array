import AppKit
import ContinuumRevivedCore

@MainActor
enum WorkspaceAPIDeviceChecks {
    struct Failure: Error { let message: String }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private final class Native: IOSPreviewSession {
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        var count = 0, sequence = 0
        var extended: [IOSPreviewBoundedAction] = []
        var holdExtended = false
        var selectedDevice: String?
        var stopped = false
        var failAfterInput = false
        var onObserve: (() -> Void)?
        var onStart: (() -> Void)?
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws { selectedDevice = deviceID; onStart?(); onFrame?(IOSPreviewChecks.image()) }
        func send(tag: UInt8, payload: [String: Any]) {}
        func stop() { stopped = true }
        func observe() async throws -> IOSPreviewObservation {
            sequence += 1; onObserve?()
            return IOSPreviewObservation(image: IOSPreviewChecks.image(), orientation: 1, geometryGeneration: 1,
                sequence: sequence, helperEmittedAt: Date(), hostReceivedAt: Date())
        }
        func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int?) async throws {
            if case let .tap(x, y) = action { try await acknowledgedTap(x: x, y: y, geometryGeneration: geometryGeneration) }
            else {
                extended.append(action)
                if holdExtended { try await Task.sleep(for: .seconds(5)) }
            }
        }
        func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int?) async throws {
            count += 1
            if failAfterInput { onFailure?("lost acknowledgement"); throw IOSPreviewActionChannel.Failure.outcomeUnknown }
        }
    }
    static func call(_ api: WorkspaceAPIService, agent: AgentID, op: String, payload: [String: Any], id: String = UUID().uuidString) async -> [String: Any] {
        let data: Data = await withCheckedContinuation { continuation in
            api.handleMCPRequest(["agentId": agent.rawValue.uuidString, "op": op, "requestId": id, "payload": payload]) {
                continuation.resume(returning: try! JSONSerialization.data(withJSONObject: $0))
            }
        }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func result(_ response: [String: Any]) throws -> [String: Any] {
        guard response["status"] as? String == "ok", let value = response["result"] as? [String: Any] else {
            throw Failure(message: "expected success, got \(response)")
        }
        return value
    }
    private static func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else { throw Failure(message: "isolated dev state required") }
        let defaults = QAIsolatedDefaults(isolatedSuiteName: "array.qa.device-api.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteDomainName) }
        let f = try WorkspaceAPIChecks.makeFixture(settings: defaults)
        defer { f.tearDown() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = f.canvas
        window.orderFrontOffscreenForChecks()
        defer { window.close() }
        let supervisor = f.delegate.qaAgentSupervisor
        defer { supervisor.stopAll() }
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        let missingCheckout = await call(f.api, agent: f.agentId, op: "device.build_run", payload: [
            "kind": "start", "sessionId": UUID().uuidString, "projectFile": "App.xcodeproj",
            "scheme": "App", "idempotencyKey": "missing-checkout"])
        let diagnostic = (missingCheckout["error"] as? [String: Any])?["message"] as? String ?? ""
        try expect(code(missingCheckout) == "invalid_request" && diagnostic.contains("checkoutHandle") && diagnostic.contains("array_workspace_context"),
            "a missing checkout must identify the required field and recovery tool, got \(missingCheckout)")
        try expect(f.api.deviceBuildJobs.jobs.isEmpty, "a malformed request must start no build")
        print("PASS: missing device build checkout returns actionable invalid_request before effects")
        let factory = IOSPreviewRuntime.sessionFactory
        var native: [Native] = []
        var reclaimDuringStart = false
        IOSPreviewRuntime.sessionFactory = {
            let value = Native()
            value.onStart = {
                if reclaimDuringStart {
                    for tile in f.canvas.allWorkspaceTiles() where tile.kind == .iosPreview {
                        (f.canvas.tileView(for: tile.id) as? IOSPreviewTileNSView)?.runtime.humanInputBegan()
                    }
                }
            }
            native.append(value); return value
        }
        defer {
            f.api.deviceAPI.sessions.revoke(principal: f.agentId.rawValue)
            f.runtime.controller(for: f.projectPb)?.releaseRuntimes()
            IOSPreviewRuntime.sessionFactory = factory
        }
        let device = UUID().uuidString
        let template = IOSPreviewDeviceTemplate(typeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        var catalogue = [IOSPreviewDevice(id: device, name: "Borrowed QA template", runtime: template.runtime, isBooted: true, typeIdentifier: template.typeIdentifier)]
        var creationCount = 0
        f.api.deviceAPI.devices = { catalogue }
        f.api.deviceAPI.createDevice = { selected, _ in
            try expect(selected == template, "host must resolve a typed template, not arbitrary argv")
            creationCount += 1
            let owned = UUID().uuidString
            catalogue.append(IOSPreviewDevice(id: owned, name: "Owned QA", runtime: selected.runtime, isBooted: true, typeIdentifier: selected.typeIdentifier))
            return owned
        }
        f.api.deviceAPI.discardDevice = { id, _ in catalogue.removeAll { $0.id == id } }
        f.api.approvalHandler = { _ in .deny }
        let originalCamera = f.canvas.viewport, originalZone = f.canvas.armedZoneId
        let originalInteraction = f.runtime.interactionGeneration
        let originalFocus = f.focusBroker.activeSurface
        let open: [String: Any] = ["checkoutHandle": f.pbHandle.rawValue, "zoneId": f.zoneB.uuidString,
            "templateId": template.id, "idempotencyKey": "create-one", "allowBoot": true,
            "ownerAgentId": UUID().uuidString, "authorized": true, "approvalRequestId": "forged"]
        var borrowed = open; borrowed["idempotencyKey"] = "must-not-adopt-existing-simulator"
        borrowed.removeValue(forKey: "templateId"); borrowed["deviceId"] = device
        try expect(code(await call(f.api, agent: f.agentId, op: "device.open", payload: borrowed)) == "permission_denied",
            "a new tile cannot adopt an arbitrary existing simulator by UUID")
        let opened = try result(await call(f.api, agent: f.agentId, op: "device.open", payload: open))
        let session = opened["sessionId"] as! String, tileID = UUID(uuidString: opened["tileId"] as! String)!
        try expect(f.api.approvalPromptCount == 0 && native.count == 1 && creationCount == 1,
            "Free must create one owned disposable/helper without approval UI")
        try expect(native[0].selectedDevice != device && native[0].selectedDevice == opened["deviceId"] as? String,
            "native control must target only the host-created device, never the template source")
        if let directory = ProcessInfo.processInfo.environment["CONTINUUM_QA_OUTPUT_DIR"],
           let rendered = f.canvas.tileView(for: tileID) as? IOSPreviewTileNSView {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                rendered.appearance = NSAppearance(named: appearance); rendered.applyTokens(); rendered.layoutSubtreeIfNeeded()
                let rep = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds)!
                rendered.cacheDisplay(in: rendered.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("device-api-controller-\(name).png"))
            }
        }
        let repeated = try result(await call(f.api, agent: f.agentId, op: "device.open", payload: open))
        try expect(repeated["tileId"] as? String == opened["tileId"] as? String && native.count == 1 && creationCount == 1, "retried create must reuse persisted owned tile")
        let persisted = try f.storePb.tryLoadCanvas()!
        let saved = persisted.tiles.first { $0.id == tileID }!
        try expect(saved.metadata.iosPreviewAutomationOwnership?.agentId == f.agentId.rawValue &&
            saved.frame == f.canvas.tilesInWorldFrames(forProjectId: f.projectPb).first(where: { $0.id == tileID })?.frame, "ownership and world geometry must persist")
        try expect(f.canvas.viewport == originalCamera && f.canvas.armedZoneId == originalZone &&
            f.runtime.interactionGeneration == originalInteraction && f.focusBroker.activeSurface == originalFocus,
            "agent open must preserve camera, armed zone, interaction generation and focus")
        let target: [String: Any] = ["checkoutHandle": f.pbHandle.rawValue, "sessionId": session]
        let observation = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try expect((observation["image"] as? [String: Any])?["mimeType"] as? String == "image/jpeg" && observation["nativeCaptureTimeKnown"] as? Bool == false,
            "observation must include a real image with truthful timestamp limits")
        let encoded = try JSONSerialization.data(withJSONObject: ["status": "ok", "result": observation])
        let mcp = WorkspaceMCPToolResult.make(reply: try JSONDecoder().decode(WorkspaceMCPJSON.self, from: encoded))
        guard case .array(let blocks)? = mcp["content"], case .object(let visible)? = mcp["structuredContent"],
              case .object(let visibleResult)? = visible["result"], case .object(let imageSummary)? = visibleResult["image"] else { throw Failure(message: "missing MCP image projection") }
        let imageBlocks = blocks.filter { if case .object(let item) = $0 { return item["type"] == .string("image") }; return false }
        try expect(imageBlocks.count == 1 && imageSummary["data"] == nil && imageSummary["attached"] == .bool(true),
            "provider response must carry one image block without duplicate base64 JSON")
        var action = target
        action["kind"] = "tap"; action["observationId"] = observation["observationId"]
        action["x"] = 100; action["y"] = 100; action["idempotencyKey"] = "one-tap"
        _ = try result(await call(f.api, agent: f.agentId, op: "device.act", payload: action))
        var retry = action
        if ProcessInfo.processInfo.environment["CONTINUUM_QA_NEGATIVE_DEVICE_REPLAY"] == "1" { retry["idempotencyKey"] = "independent-second-tap" }
        _ = try result(await call(f.api, agent: f.agentId, op: "device.act", payload: retry))
        try expect(native[0].count == 1, "same-key tap must have exactly one effect through production MCP dispatch")
        var conflict = action; conflict["x"] = 200
        try expect(code(await call(f.api, agent: f.agentId, op: "device.act", payload: conflict)) == "idempotency_conflict", "different payload cannot reuse tap key")
        let fresh = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        try expect((fresh["sequence"] as? Int ?? 0) > (observation["sequence"] as? Int ?? 0), "observe/act/observe must obtain a new native frame")
        var bad = action; bad["idempotencyKey"] = "forged"; bad["observationId"] = UUID().uuidString
        try expect(code(await call(f.api, agent: f.agentId, op: "device.act", payload: bad)) == "target_conflict" && native[0].count == 1,
            "forged frame must cause zero HID")
        let extendedPayloads: [[String: Any]] = [
            ["kind": "swipe", "x": 10, "y": 20, "endX": 30, "endY": 40, "milliseconds": 150],
            ["kind": "text", "text": "café 🧪 漢字"], ["kind": "key", "key": "backspace"],
            ["kind": "home"], ["kind": "rotate", "orientation": 3]
        ]
        for (index, values) in extendedPayloads.enumerated() {
            let frame = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: target))
            var payload = target.merging(values) { _, new in new }
            payload["observationId"] = frame["observationId"]; payload["idempotencyKey"] = "extended-\(index)"
            _ = try result(await call(f.api, agent: f.agentId, op: "device.act", payload: payload))
            _ = try result(await call(f.api, agent: f.agentId, op: "device.act", payload: payload))
            try expect(native[0].extended.count == index + 1, "each extended action retry must cause exactly one native dispatch")
        }
        let rejectedFrame = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        for (index, values) in ([["kind": "text", "text": String(repeating: "x", count: 16385)], ["kind": "key", "key": "shell"], ["kind": "rotate", "orientation": 5], ["kind": "swipe", "x": 10, "y": 20, "endX": 30, "endY": 40, "milliseconds": 2000]] as [[String: Any]]).enumerated() {
            var payload = target.merging(values) { _, new in new }
            payload["observationId"] = rejectedFrame["observationId"]; payload["idempotencyKey"] = "invalid-extended-\(index)"
            try expect(code(await call(f.api, agent: f.agentId, op: "device.act", payload: payload)) == "invalid_request", "invalid extended action must reject before dispatch")
        }
        try expect(native[0].extended.count == 5, "invalid extended actions must cause zero input")
        var wrong = target; wrong["checkoutHandle"] = f.paHandle.rawValue
        try expect(code(await call(f.api, agent: f.agentId, op: "device.observe", payload: wrong)) == "permission_denied", "wrong explicit checkout cannot observe")
        let view = f.canvas.tileView(for: tileID) as! IOSPreviewTileNSView
        let frame = f.canvas.tilesInWorldFrames(forProjectId: f.projectPb).first(where: { $0.id == tileID })!.frame
        f.canvas.setViewport(CanvasViewport(x: frame.x - 100, y: frame.y - 100, zoom: 1))
        f.canvas.layoutSubtreeIfNeeded()
        let cancelFrame = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: target))
        var cancelledSwipe = target
        cancelledSwipe.merge(["kind": "swipe", "x": 10, "y": 20, "endX": 30, "endY": 40,
            "milliseconds": 150, "observationId": cancelFrame["observationId"]!, "idempotencyKey": "takeover-swipe"]) { _, new in new }
        native[0].holdExtended = true
        let pendingSwipe = Task {
            let response = await call(f.api, agent: f.agentId, op: "device.act", payload: cancelledSwipe)
            return try! JSONSerialization.data(withJSONObject: response)
        }
        for _ in 0..<200 {
            if native[0].extended.count == 6 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(native[0].extended.count == 6, "takeover witness must reach an in-flight native swipe")
        let point = view.screen.convert(CGPoint(x: view.screen.screenRect.midX, y: view.screen.screenRect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
        let interruptedSwipe = try JSONSerialization.jsonObject(with: await pendingSwipe.value) as! [String: Any]
        native[0].holdExtended = false
        try expect(code(interruptedSwipe) == "outcome_unknown", "takeover after native admission must preserve uncertain effect")
        let cancelledReplay = await call(f.api, agent: f.agentId, op: "device.act", payload: cancelledSwipe)
        try expect(code(cancelledReplay) == "outcome_unknown" && native[0].extended.count == 6,
            "retry after takeover must retrieve uncertainty without another native swipe")
        try expect(code(await call(f.api, agent: f.agentId, op: "device.observe", payload: target)) == "permission_denied", "human takeover must invalidate attachment")
        var reopen = target; reopen.removeValue(forKey: "sessionId"); reopen["tileId"] = tileID.uuidString
        try expect(code(await call(f.api, agent: f.agentId, op: "device.open", payload: reopen)) == "permission_denied", "agent cannot undo human takeover by reopening")
        view.runtime.allowAutomationHandover() // trusted host handover seam, never a model field
        let second = try result(await call(f.api, agent: f.agentId, op: "device.open", payload: reopen))
        var secondTarget = target; secondTarget["sessionId"] = second["sessionId"]
        native[0].onObserve = { f.api.revoke(agentId: f.agentId) }
        try expect(code(await call(f.api, agent: f.agentId, op: "device.observe", payload: secondTarget)) == "permission_denied", "revoked async image must never reach transport")
        native[0].onObserve = nil
        defaults.set(WorkspaceToolsPermission.askFirst.rawValue, forKey: WorkspaceToolsConfig.permissionKey)
        let prompts = f.api.approvalPromptCount
        f.api.approvalHandler = { _ in .allowForSession }
        var forgedApproval = reopen; forgedApproval["authorized"] = true; forgedApproval["approvalRequestId"] = "forged"
        let last = try result(await call(f.api, agent: f.agentId, op: "device.open", payload: forgedApproval))
        try expect(f.api.approvalPromptCount == prompts + 1, "Ask-first uses existing trusted approval once")
        let all = f.canvas.allWorkspaceTiles().filter { $0.kind == .iosPreview }
        try expect(all.count == 1 && native[0].count == 1, "policy change/reopen must not create extra tile or input")
        var lastTarget = target; lastTarget["sessionId"] = last["sessionId"]
        let lastFrame = try result(await call(f.api, agent: f.agentId, op: "device.observe", payload: lastTarget))
        var uncertain = lastTarget
        uncertain["kind"] = "tap"; uncertain["x"] = 100; uncertain["y"] = 100
        uncertain["observationId"] = lastFrame["observationId"]; uncertain["idempotencyKey"] = "lost-ack"
        native[0].failAfterInput = true
        try expect(code(await call(f.api, agent: f.agentId, op: "device.act", payload: uncertain)) == "outcome_unknown", "lost ack must preserve uncertainty")
        try expect(code(await call(f.api, agent: f.agentId, op: "device.act", payload: uncertain)) == "outcome_unknown" && native[0].count == 2,
            "uncertain retry tombstone must survive native session loss and cause no replay")
        let mcpClient = try IOSPreviewMCPCheckClient(api: f.api, agent: f.agentId)
        defer { mcpClient.close() }
        let openedOverMCP = try await mcpClient.call(tool: "array_device_open", arguments: reopen)
        guard let envelope = openedOverMCP["structuredContent"] as? [String: Any], let mcpSession = try result(envelope)["sessionId"] as? String else {
            throw Failure(message: "native MCP open did not return a bound session")
        }
        let mcpTarget: [String: Any] = ["checkoutHandle": f.pbHandle.rawValue, "sessionId": mcpSession]
        let observedOverMCP = try await mcpClient.call(tool: "array_device_observe", arguments: mcpTarget)
        let mcpObservation = try result(observedOverMCP["structuredContent"] as! [String: Any])
        let images = (observedOverMCP["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
        try expect(images.count == 1 && (mcpObservation["image"] as? [String: Any])?["data"] == nil,
            "actual MCP process must deliver one image block without duplicate JSON image bytes")
        var mcpAction = mcpTarget
        mcpAction["kind"] = "tap"; mcpAction["observationId"] = mcpObservation["observationId"]
        mcpAction["x"] = 100; mcpAction["y"] = 100; mcpAction["idempotencyKey"] = "real-native-mcp-tap"
        let mcpActed = try await mcpClient.call(tool: "array_device_act", arguments: mcpAction)
        _ = try result(mcpActed["structuredContent"] as! [String: Any])
        let mcpRetry = try await mcpClient.call(tool: "array_device_act", arguments: mcpAction)
        _ = try result(mcpRetry["structuredContent"] as! [String: Any])
        try expect(native.count == 2 && native[1].count == 1, "real native MCP transport must target the one reconnected device and never replay input")
        let mcpClosed = try await mcpClient.call(tool: "array_device_close", arguments: mcpTarget)
        _ = try result(mcpClosed["structuredContent"] as! [String: Any])
        view.runtime.disconnect()
        reclaimDuringStart = true
        let interrupted = await call(f.api, agent: f.agentId, op: "device.open", payload: reopen)
        try expect(code(interrupted) == "permission_denied" && native.last?.stopped == true && native.last?.count == 0,
            "human input during provisional connection must fence attachment before agent input")
        reclaimDuringStart = false
        view.runtime.allowAutomationHandover()
        // Borrowing is possible only through the actual human device picker
        // on an owned tile, then trusted handback; never a model UUID field.
        view.selectDevice(id: device, name: "Human-selected simulator")
        try expect(code(await call(f.api, agent: f.agentId, op: "device.open", payload: reopen)) == "permission_denied",
            "manual selection of another simulator must require human handback")
        view.runtime.allowAutomationHandover()
        let borrowedAfterHandover = try result(await call(f.api, agent: f.agentId, op: "device.open", payload: reopen))
        try expect(borrowedAfterHandover["managedSimulator"] as? Bool == false && native.last?.selectedDevice == device,
            "explicit UI-borrowed simulator must stay distinct from host-created ownership")
        try expect(try f.storePb.tryLoadCanvas()?.tiles.first(where: { $0.id == tileID })?.metadata.iosPreviewAutomationOwnership?.managedSimulator == false,
            "borrowed status must persist without minting a managed-device receipt")
        try await WorkspaceAPIDeviceBuildChecks.run(f, session: borrowedAfterHandover["sessionId"] as! String, mcp: mcpClient)
        print("WorkspaceAPIDeviceChecks native MCP passed: real executable, authenticated HTTP, owned open, image item, exactly-one tap and close")
        print("WorkspaceAPIDeviceChecks passed: production mount and async MCP open/observe/tap/observe, exact-once retry, persistent owner/world geometry, no presentation, image blocks, stale/scope/takeover/revocation denial, Free and Ask-first")
    }
}
