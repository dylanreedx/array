import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import Foundation

/// The provider entry, not a checks-only spawner: this will grow with the
/// browser tools until it witnesses the entire S3 path.
@MainActor
func runWorkspaceAPIBrowserCheck() throws {
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw WorkspaceAPIChecks.Failure(message: "browser API check requires isolated app support and a dev binary")
    }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    var permission: WorkspaceToolsPermission = .free
    f.delegate.qaAgentSupervisor.workspaceToolsPermission = { permission }
    var scopePrompts = 0
    var scopeDecision: WorkspaceAPIService.ScopeApprovalDecision = .allowForSession
    f.api.approvalHandler = { _ in scopePrompts += 1; return scopeDecision }
    let window = NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = f.canvas
    window.orderFrontOffscreenForChecks()
    defer { window.orderOut(nil) }
    var response: [String: Any]?
    f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": "browser-open-check",
                            "op": "browser.open", "payload": ["url": "about:blank"]]) { response = $0 }
    let deadline = Date().addingTimeInterval(15)
    while response == nil && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard let response, response["status"] as? String == "ok",
          let result = response["result"] as? [String: Any], let raw = result["tileId"] as? String,
          let tileId = UUID(uuidString: raw), let tile = f.canvas.tileRecord(for: tileId),
          tile.metadata.browserOwnerAgentId == f.agentId, tile.metadata.browserProfileId == BrowserProfile.agentsProfileId,
          f.runtime.liveControllers.flatMap(\.browserRuntimes).contains(where: { $0.tileId == tileId && !$0.isTerminated }) else {
        throw WorkspaceAPIChecks.Failure(message: "MCP browser open must create a live owned Agents-profile tile: \(String(describing: response))")
    }
    func rawCall(_ op: String, _ payload: [String: Any], agent: AgentID? = nil) throws -> [String: Any] {
        var response: [String: Any]?
        f.api.handleMCPRequest(["agentId": (agent ?? f.agentId).rawValue.uuidString, "requestId": UUID().uuidString,
                                "op": op, "payload": payload]) { response = $0 }
        let deadline = Date().addingTimeInterval(15)
        while response == nil && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard let response else { throw WorkspaceAPIChecks.Failure(message: "MCP \(op) timed out") }
        return response
    }
    func call(_ op: String, _ payload: [String: Any]) throws -> [String: Any] {
        let response = try rawCall(op, payload)
        guard response["status"] as? String == "ok", let result = response["result"] as? [String: Any] else {
            throw WorkspaceAPIChecks.Failure(message: "MCP \(op) failed: \(response)")
        }
        return result
    }
    let target = tileId.uuidString
    _ = try call("browser.evaluate", ["tileId": target, "script": "() => { document.body.innerHTML = '<label for=email>Email</label><input id=email><button onclick=\"document.body.dataset.clicked=(+(document.body.dataset.clicked||0)+1)\">Submit</button>'; return true; }"])
    let snapshot = try call("browser.snapshot", ["tileId": target])
    guard let outline = snapshot["text"] as? String else { throw WorkspaceAPIChecks.Failure(message: "snapshot did not return the page outline") }
    guard let screenshotBrowser = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId == tileId }) else {
        throw WorkspaceAPIChecks.Failure(message: "browser runtime is missing")
    }
    let agentTile = ManagedAgentTileNSView(tile: Tile(
        id: f.agentTileB, kind: .managedAgent, title: "Screenshot witness",
        frame: TileFrame(x: 0, y: 0, width: 560, height: 620), zPosition: .first,
        runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed-agent")))
    agentTile.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
    let agentWindow = NSWindow(contentRect: agentTile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    agentWindow.contentView = agentTile
    agentWindow.orderFrontOffscreenForChecks()
    defer { agentWindow.orderOut(nil) }
    f.delegate.qaBindAgentComposerState(agentTile)
    agentTile.attach(agentID: f.agentId, supervisor: f.delegate.qaAgentSupervisor)
    var screenshotReply: [String: Any]?
    var timerDuringScreenshot = false
    screenshotBrowser.automation._screenshotStarted = {
        DispatchQueue.main.async { if screenshotReply == nil { timerDuringScreenshot = true } }
    }
    f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
        "op": "browser.take_screenshot", "payload": ["tileId": target]]) { screenshotReply = $0 }
    let screenshotDeadline = Date().addingTimeInterval(15)
    while screenshotReply == nil && Date() < screenshotDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    screenshotBrowser.automation._screenshotStarted = nil
    let image = (screenshotReply?["result"] as? [String: Any])?["image"] as? [String: Any]
    guard screenshotReply?["status"] as? String == "ok", timerDuringScreenshot,
          image?["mimeType"] as? String == "image/png", let encoded = image?["data"] as? String,
          Data(base64Encoded: encoded)?.starts(with: [137, 80, 78, 71]) == true else {
        throw WorkspaceAPIChecks.Failure(message: "MCP screenshot must return a PNG without blocking the main queue")
    }
    guard let path = (screenshotReply?["result"] as? [String: Any])?["screenshotPath"] as? String,
          path.hasPrefix(f.delegate.qaAgentSupervisor.browserArtifactRoot.path + "/"), path.contains(f.agentId.rawValue.uuidString),
          let saved = try? Data(contentsOf: URL(fileURLWithPath: path)), saved == Data(base64Encoded: encoded),
          let permissions = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int,
          permissions & 0o077 == 0 else {
        throw WorkspaceAPIChecks.Failure(message: "screenshot must be saved privately in the agent's channel-local artifact folder")
    }
    let screenshotBlocks = f.delegate.qaAgentSupervisor.transcriptDocumentProjection(for: f.agentId)?.entries.flatMap(\.blocks).filter {
        if case .image = $0.payload { return true }; return false
    } ?? []
    guard screenshotBlocks.count == 1,
          case let .image(payload) = screenshotBlocks[0].payload,
          payload.attachment.contentType == "image/png",
          !payload.attachment.id.rawValue.contains("/") else {
        throw WorkspaceAPIChecks.Failure(message: "a requested screenshot must become one owned, path-free transcript image")
    }
    var ownedImage: AgentComposerStoredAttachment?
    var imageLookupFinished = false
    Task { @MainActor in
        ownedImage = try? await f.delegate.qaAgentSupervisor.qaStoredBrowserImage(payload.attachment.id)
        imageLookupFinished = true
    }
    let imageLookupDeadline = Date().addingTimeInterval(5)
    while !imageLookupFinished && Date() < imageLookupDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let ownedImage, ownedImage.manifest.ownership.agentID == f.agentId,
          ownedImage.manifest.ownership.state == .sent,
          (try? Data(contentsOf: ownedImage.fileURL)) == Data(base64Encoded: encoded) else {
        throw WorkspaceAPIChecks.Failure(message: "the transcript image must resolve to the requesting agent's sent PNG")
    }
    let renderDeadline = Date().addingTimeInterval(5)
    while Date() < renderDeadline {
        agentTile.layoutSubtreeIfNeeded()
        if agentTile.qaDisplayedBlockIDs.contains(screenshotBlocks[0].id),
           agentTile.qaCanvasTranscript?.imageSources[payload.attachment.id] != nil { break }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard agentTile.qaDisplayedBlockIDs.contains(screenshotBlocks[0].id),
          agentTile.qaCanvasTranscript?.imageSources[payload.attachment.id] != nil else {
        throw WorkspaceAPIChecks.Failure(message: "the mounted agent transcript must lay out the screenshot and load its owned image")
    }
    let objectDirectory = ownedImage.fileURL.deletingLastPathComponent()
    let beforeRevokedImport = Set(try FileManager.default.contentsOfDirectory(atPath: objectDirectory.path))
    f.api._afterBrowserScreenshotImportHook = { f.api.revoke(agentId: f.agentId) }
    let revokedImport = try rawCall("browser.take_screenshot", ["tileId": target])
    f.api._afterBrowserScreenshotImportHook = nil
    let afterRevokedImport = Set(try FileManager.default.contentsOfDirectory(atPath: objectDirectory.path))
    let imagesAfterRevocation = f.delegate.qaAgentSupervisor.transcriptDocumentProjection(for: f.agentId)?.entries.flatMap(\.blocks).filter {
        if case .image = $0.payload { return true }; return false
    } ?? []
    guard (revokedImport["error"] as? [String: Any])?["code"] as? String == "outcome_unknown",
          beforeRevokedImport == afterRevokedImport, imagesAfterRevocation.count == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "revocation during screenshot import must remove the staged image without publishing it")
    }
    let artifactDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let beforeRevokedSave = Set(try FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path))
    f.api._afterBrowserScreenshotSaveHook = { f.api.revoke(agentId: f.agentId) }
    let revokedScreenshot = try rawCall("browser.take_screenshot", ["tileId": target])
    f.api._afterBrowserScreenshotSaveHook = nil
    let afterRevokedSave = Set(try FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path))
    guard (revokedScreenshot["error"] as? [String: Any])?["code"] as? String == "outcome_unknown",
          beforeRevokedSave == afterRevokedSave else {
        throw WorkspaceAPIChecks.Failure(message: "revocation during screenshot save must suppress the image and remove its new artifact")
    }
    let artifactProbe = f.tempRoot.appendingPathComponent("artifact-symlink-probe", isDirectory: true)
    let outside = f.tempRoot.appendingPathComponent("artifact-outside", isDirectory: true)
    try FileManager.default.createDirectory(at: artifactProbe, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let redirectedRoot = artifactProbe.appendingPathComponent("agent-browser-artifacts", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: redirectedRoot, withDestinationURL: outside)
    guard BrowserArtifactStore.save(root: redirectedRoot, agentId: f.agentId, png: Data([1, 2, 3])) == nil,
          try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "a symlink must not redirect screenshot artifacts")
    }
    func ref(_ name: String) throws -> String {
        guard let line = outline.split(separator: "\n").first(where: { $0.contains("\"\(name)\"") }),
              let range = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
            throw WorkspaceAPIChecks.Failure(message: "no ref for \(name): \(outline)")
        }
        return String(line[range].dropFirst(5).dropLast())
    }
    _ = try call("browser.click", ["tileId": target, "ref": try ref("Submit")])
    guard let rippleView = f.canvas.tileView(for: tileId) as? BrowserTileNSView,
          rippleView.hostView.qaAgentRippleCount > 0,
          let ripplePoint = rippleView.hostView.qaLastAgentRipplePoint,
          rippleView.hostView.bounds.contains(ripplePoint) else {
        throw WorkspaceAPIChecks.Failure(message: "an agent click must show a ripple on the real browser tile")
    }
    _ = try call("browser.type", ["tileId": target, "ref": try ref("Email"), "text": "through-api"])
    let audit = f.api.browserAudit(for: tileId)
    guard audit.contains(where: { $0.operation == .browserType && $0.agentId == f.agentId && $0.outcome == "ok" }),
          !String(describing: audit).contains("through-api") else {
        throw WorkspaceAPIChecks.Failure(message: "browser tile audit must record the action without typed data")
    }
    guard let activityView = f.canvas.tileView(for: tileId) as? BrowserTileNSView,
          activityView.qaBrowserActivity.contains(where: { $0.contains("Typed in a browser") }),
          !activityView.qaBrowserActivity.joined().contains("through-api") else {
        throw WorkspaceAPIChecks.Failure(message: "browser control menu must show safe activity without typed data")
    }
    let actual = try call("browser.evaluate", ["tileId": target,
        "script": "() => ({ clicked: document.body.dataset.clicked, text: document.getElementById('email').value })"])
    guard let value = actual["value"] as? [String: Any], value["clicked"] as? String == "1",
          value["text"] as? String == "through-api" else {
        throw WorkspaceAPIChecks.Failure(message: "MCP clicks and typing must reach the actual page: \(actual)")
    }
    let clickPayload: [String: Any] = ["tileId": target, "ref": try ref("Submit"), "idempotencyKey": "one-click"]
    _ = try call("browser.click", clickPayload)
    _ = try call("browser.click", clickPayload)
    let conflict = try rawCall("browser.click", ["tileId": target, "ref": try ref("Email"), "idempotencyKey": "one-click"])
    let clickCount = try call("browser.evaluate", ["tileId": target, "script": "() => document.body.dataset.clicked"])
    guard (conflict["error"] as? [String: Any])?["code"] as? String == "idempotency_conflict",
          clickCount["value"] as? String == "2" else {
        throw WorkspaceAPIChecks.Failure(message: "same-key clicks must replay once and different payloads must conflict")
    }
    let policyPayload: [String: Any] = ["tileId": target, "script": "() => document.title", "idempotencyKey": "policy-replay"]
    _ = try call("browser.evaluate", policyPayload)
    permission = .askFirst
    let policyReplay = try rawCall("browser.evaluate", policyPayload)
    guard (policyReplay["error"] as? [String: Any])?["code"] as? String == "permission_denied" else {
        throw WorkspaceAPIChecks.Failure(message: "a policy change must not replay a Free-policy browser result: \(policyReplay)")
    }
    permission = .free
    let viewportBeforeNavigation = f.canvas.viewport
    let armedBeforeNavigation = f.canvas.armedZoneId
    let frameBeforeNavigation = f.canvas.navigationTileSnapshot(for: tileId)?.worldFrame
    let interactionBeforeNavigation = f.runtime.interactionGeneration
    let localPage = f.pbRoot.appendingPathComponent("browser-api-fixture.html")
    try Data("<html><head><title>Second page</title></head><body><h1>Navigation arrived</h1></body></html>".utf8).write(to: localPage)
    _ = try call("browser.navigate", ["tileId": target, "url": localPage.absoluteString])
    let navigated = try call("browser.snapshot", ["tileId": target])
    guard (navigated["text"] as? String)?.contains("Navigation arrived") == true else {
        throw WorkspaceAPIChecks.Failure(message: "navigation must load the requested page before returning")
    }
    try f.runtime.controller(for: f.projectPb)?.flushCanvasSave()
    guard try f.storePb.loadCanvas().tiles.first(where: { $0.id == tileId })?.metadata.url == localPage.absoluteString else {
        throw WorkspaceAPIChecks.Failure(message: "the browser URL must persist after navigation")
    }
    guard f.canvas.viewport == viewportBeforeNavigation, f.canvas.armedZoneId == armedBeforeNavigation,
          f.canvas.navigationTileSnapshot(for: tileId)?.worldFrame == frameBeforeNavigation,
          f.runtime.interactionGeneration == interactionBeforeNavigation else {
        throw WorkspaceAPIChecks.Failure(message: "browser navigation must preserve the user's camera, armed zone, tile frame and interaction generation")
    }
    var domainPrompts = 0
    f.api.browserDomainApprovalHandler = { _, _, _, reply in domainPrompts += 1; reply(.deny); return {} }
    let denied = try rawCall("browser.navigate", ["tileId": target, "url": "https://example.invalid/"])
    guard (denied["error"] as? [String: Any])?["code"] as? String == "scope_approval_required",
          domainPrompts == 1, f.canvas.tileRecord(for: tileId)?.metadata.url == localPage.absoluteString else {
        throw WorkspaceAPIChecks.Failure(message: "a denied remote navigation must ask once and leave the saved URL unchanged: \(denied)")
    }
    let takeoverPayload: [String: Any] = ["tileId": target, "idempotencyKey": "takeover-snapshot"]
    _ = try call("browser.snapshot", takeoverPayload)
    guard let browser = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId == tileId }) else {
        throw WorkspaceAPIChecks.Failure(message: "browser runtime disappeared")
    }
    window.makeFirstResponder(browser.webView)
    let beforeUserInput = browser.automation.userInputCount
    let userKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    NSApp.sendEvent(userKey)
    let afterTakeover = try rawCall("browser.snapshot", takeoverPayload)
    guard browser.automation.userInputCount == beforeUserInput + 1, afterTakeover["status"] as? String == "error",
          (afterTakeover["error"] as? [String: Any])?["code"] as? String == "target_conflict" else {
        throw WorkspaceAPIChecks.Failure(message: "a user takeover must invalidate a cached browser reply: \(afterTakeover)")
    }
    let cachedPayload: [String: Any] = ["tileId": target, "idempotencyKey": "revoke-snapshot"]
    _ = try call("browser.snapshot", cachedPayload)
    f.api.revoke(agentId: f.agentId)
    let afterRevocation = try rawCall("browser.snapshot", cachedPayload)
    guard afterRevocation["status"] as? String == "error",
          (afterRevocation["error"] as? [String: Any])?["code"] as? String == "permission_denied" else {
        throw WorkspaceAPIChecks.Failure(message: "revocation must prevent replay of cached page data: \(afterRevocation)")
    }
    browser.webViewWebContentProcessDidTerminate(browser.webView)
    let terminationDeadline = Date().addingTimeInterval(3)
    while !browser.isTerminated && Date() < terminationDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    let deadSnapshot = try rawCall("browser.snapshot", ["tileId": target])
    guard browser.isTerminated, (deadSnapshot["error"] as? [String: Any])?["code"] as? String == "browser_not_live" else {
        throw WorkspaceAPIChecks.Failure(message: "a dead browser must return browser_not_live without restarting")
    }
    _ = try call("browser.navigate", ["tileId": target, "action": "reload"])
    guard let restarted = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId == tileId }),
          restarted.id != browser.id, !restarted.isTerminated,
          (try call("browser.snapshot", ["tileId": target])["text"] as? String)?.contains("Navigation arrived") == true else {
        throw WorkspaceAPIChecks.Failure(message: "explicit reload must restart the same browser tile and load its saved page")
    }
    let userSpawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard case let .spawned(userBrowser) = userSpawner.spawnBrowser(url: "about:blank", beside: f.agentTileB, targetZoneId: f.zoneB) else {
        throw WorkspaceAPIChecks.Failure(message: "could not create the user browser fixture")
    }
    f.api.browserRuntimeWiring?(userBrowser, f.projectPb)
    let userTile = userBrowser.tileId.uuidString
    _ = try call("browser.snapshot", ["tileId": userTile])
    var handOverAllowed = false
    var handOverPrompts = 0
    var evaluatePrompts = 0
    f.api.browserHandOverApprovalHandler = { _, _, evaluate, reply in
        if evaluate { evaluatePrompts += 1 } else { handOverPrompts += 1 }
        reply(handOverAllowed)
        return {}
    }
    let refusedHandOver = try rawCall("browser.press_key", ["tileId": userTile, "keyName": "Enter"])
    guard (refusedHandOver["error"] as? [String: Any])?["code"] as? String == "scope_approval_required", handOverPrompts == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "user browser control must ask even under Free")
    }
    handOverAllowed = true
    let reapprovalInputs = userBrowser.automation.userInputCount
    let reapproval = try rawCall("browser.press_key", ["tileId": userTile, "keyName": "Enter"])
    guard reapproval["status"] as? String == "ok" else {
        throw WorkspaceAPIChecks.Failure(message: "initial hand-over failed: inputs=\(reapprovalInputs)->\(userBrowser.automation.userInputCount), engaged=\(userBrowser.automation.isEngaged), gate=\(userBrowser.agentNavigationDecision != nil), prompts=\(handOverPrompts), reply=\(reapproval)")
    }
    window.makeFirstResponder(userBrowser.webView)
    let otherBrowserInputCount = userBrowser.automation.userInputCount
    _ = try call("browser.press_key", ["tileId": target, "keyName": "Enter"])
    guard userBrowser.automation.userInputCount == otherBrowserInputCount && userBrowser.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "agent input in another tile must not masquerade as user takeover here")
    }
    handOverAllowed = false
    let refusedEvaluation = try rawCall("browser.evaluate", ["tileId": userTile, "script": "() => 1"])
    guard (refusedEvaluation["error"] as? [String: Any])?["code"] as? String == "scope_approval_required", evaluatePrompts == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "evaluation on a handed-over browser must ask every time")
    }
    window.makeFirstResponder(userBrowser.webView)
    let userBrowserInputs = userBrowser.automation.userInputCount
    let takeBackKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
    NSApp.sendEvent(takeBackKey)
    let afterTakeBack = try rawCall("browser.press_key", ["tileId": userTile, "keyName": "Enter"])
    guard userBrowser.automation.userInputCount == userBrowserInputs + 1, !userBrowser.automation.isEngaged,
          userBrowser.agentNavigationDecision == nil, handOverPrompts == 3,
          (afterTakeBack["error"] as? [String: Any])?["code"] as? String == "scope_approval_required" else {
        throw WorkspaceAPIChecks.Failure(message: "user input must take the browser back and release its agent lease: inputs=\(userBrowserInputs)->\(userBrowser.automation.userInputCount), engaged=\(userBrowser.automation.isEngaged), gate=\(userBrowser.agentNavigationDecision != nil), prompts=\(handOverPrompts), reply=\(afterTakeBack)")
    }
    handOverAllowed = true
    let secondInputs = userBrowser.automation.userInputCount
    let secondApproval = try rawCall("browser.press_key", ["tileId": userTile, "keyName": "Enter"])
    guard secondApproval["status"] as? String == "ok" else {
        throw WorkspaceAPIChecks.Failure(message: "hand-over after user input failed: inputs=\(secondInputs)->\(userBrowser.automation.userInputCount), engaged=\(userBrowser.automation.isEngaged), gate=\(userBrowser.agentNavigationDecision != nil), prompts=\(handOverPrompts), reply=\(secondApproval)")
    }
    guard let userView = f.canvas.tileView(for: userBrowser.tileId),
          let worldFrame = f.canvas.navigationTileSnapshot(for: userBrowser.tileId)?.worldFrame else {
        throw WorkspaceAPIChecks.Failure(message: "user browser tile disappeared before chrome takeover")
    }
    f.canvas.setViewport(CanvasViewport(x: worldFrame.x - 40, y: worldFrame.y - 40, zoom: 1))
    f.canvas.layoutSubtreeIfNeeded()
    let headerPoint = userView.convert(NSPoint(x: userView.bounds.midX, y: 10), to: nil)
    let chromeCount = userBrowser.automation.userInputCount
    let mouseDown = NSEvent.mouseEvent(with: .leftMouseDown, location: headerPoint, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: headerPoint, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    NSApp.sendEvent(mouseDown)
    NSApp.sendEvent(mouseUp)
    guard userBrowser.automation.userInputCount == chromeCount + 1, !userBrowser.automation.isEngaged,
          userBrowser.agentNavigationDecision == nil else {
        throw WorkspaceAPIChecks.Failure(message: "a real click on browser chrome must take control back")
    }
    let beforeExpiredOpen = f.canvas.allWorkspaceTiles().filter { $0.kind == .browser && $0.metadata.browserOwnerAgentId == f.agentId }.count
    f.api._browserInventoryReadHook = { f.api.browserOpenAdmission.qaExpireCurrentReservation() }
    let expiredOpen = try rawCall("browser.open", ["url": "about:blank"])
    f.api._browserInventoryReadHook = nil
    guard (expiredOpen["error"] as? [String: Any])?["code"] as? String == "busy",
          f.canvas.allWorkspaceTiles().filter({ $0.kind == .browser && $0.metadata.browserOwnerAgentId == f.agentId }).count == beforeExpiredOpen else {
        throw WorkspaceAPIChecks.Failure(message: "an inventory scan that lost its reservation must not create a browser")
    }
    let second = try call("browser.open", ["url": localPage.absoluteString])
    guard let secondId = second["tileId"] as? String,
          (try call("browser.snapshot", ["tileId": secondId])["text"] as? String)?.contains("Navigation arrived") == true else {
        throw WorkspaceAPIChecks.Failure(message: "browser open must load its requested URL before returning")
    }
    for _ in 0..<2 { _ = try call("browser.open", ["url": "about:blank"]) }
    let ownerCap = try rawCall("browser.open", ["url": "about:blank"])
    guard (ownerCap["error"] as? [String: Any])?["code"] as? String == "busy" else {
        throw WorkspaceAPIChecks.Failure(message: "a fifth browser for one agent must be refused: \(ownerCap)")
    }
    let other = f.delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot, tileId: f.agentTileB)
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: other, true)
    let otherRead = try rawCall("browser.snapshot", ["tileId": target], agent: other)
    let otherControl = try rawCall("browser.press_key", ["tileId": target, "keyName": "Enter"], agent: other)
    guard otherRead["status"] as? String == "ok",
          (otherControl["error"] as? [String: Any])?["code"] as? String == "permission_denied" else {
        throw WorkspaceAPIChecks.Failure(message: "another agent may inspect a scoped browser but may not control its owner's tile")
    }
    var remoteCanvas = try f.storePc.loadCanvas()
    for _ in 0..<8 {
        remoteCanvas.tiles.append(Tile(id: UUID(), kind: .browser, title: "Saved agent browser", frame: tile.frame,
            zPosition: tile.zPosition, zoneId: tile.zoneId, runtimeRef: nil, metadata: TileMetadata(browserOwnerAgentId: AgentID(rawValue: UUID()))))
    }
    try f.storePc.saveCanvas(remoteCanvas)
    let globalCap = try rawCall("browser.open", ["url": "about:blank"], agent: other)
    guard (globalCap["error"] as? [String: Any])?["code"] as? String == "busy" else {
        throw WorkspaceAPIChecks.Failure(message: "the total browser cap must include an unhydrated project's saved tiles: \(globalCap)")
    }
    remoteCanvas.tiles.removeLast()
    try f.storePc.saveCanvas(remoteCanvas)
    let third = f.delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot, tileId: f.fileTileB)
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: third, true)
    f.api._browserInventoryReadHook = { try? await Task.sleep(nanoseconds: 250_000_000) }
    defer { f.api._browserInventoryReadHook = nil }
    var simultaneous: [[String: Any]] = []
    for agent in [other, third] {
        f.api.handleMCPRequest(["agentId": agent.rawValue.uuidString, "requestId": UUID().uuidString,
                                "op": "browser.open", "payload": ["url": "about:blank"]]) { simultaneous.append($0) }
    }
    let simultaneousDeadline = Date().addingTimeInterval(15)
    while simultaneous.count < 2 && Date() < simultaneousDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard simultaneous.filter({ $0["status"] as? String == "ok" }).count == 1,
          simultaneous.filter({ ($0["error"] as? [String: Any])?["code"] as? String == "busy" }).count == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "concurrent agents must not open two browsers into the last global slot: \(simultaneous)")
    }
    guard scopePrompts == 0 else { throw WorkspaceAPIChecks.Failure(message: "Free must not show the general browser permission prompt") }
    permission = .askFirst
    _ = try call("browser.evaluate", ["tileId": target, "script": "() => 1"])
    _ = try call("browser.evaluate", ["tileId": target, "script": "() => 2"])
    guard scopePrompts == 1 else { throw WorkspaceAPIChecks.Failure(message: "Ask first session approval must prompt once") }
    f.api.revoke(agentId: f.agentId)
    scopeDecision = .allowOnce
    _ = try call("browser.evaluate", ["tileId": target, "script": "() => 3"])
    _ = try call("browser.evaluate", ["tileId": target, "script": "() => 4"])
    guard scopePrompts == 3 else { throw WorkspaceAPIChecks.Failure(message: "allow once must not grant later browser actions") }
    try runAgentBrowserPopupCheck()
    try runBrowserControlHardeningChecks()
    print("Workspace browser API: MCP browser operations, ownership, permissions, residency, caps, restart and popup passed")
}

/// A trusted click on a target=_blank link must produce an owned, gated tile.
@MainActor
private func runAgentBrowserPopupCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    f.delegate.qaAgentSupervisor.workspaceToolsPermission = { .free }
    let window = NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = f.canvas
    window.orderFrontOffscreenForChecks()
    defer { window.close() }
    func call(_ op: String, _ payload: [String: Any]) throws -> [String: Any] {
        var response: [String: Any]?
        f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
                                "op": op, "payload": payload]) { response = $0 }
        let deadline = Date().addingTimeInterval(15)
        while response == nil && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard let response, response["status"] as? String == "ok", let result = response["result"] as? [String: Any] else {
            throw WorkspaceAPIChecks.Failure(message: "popup fixture \(op) failed: \(String(describing: response))")
        }
        return result
    }
    let opened = try call("browser.open", ["url": "about:blank"])
    guard let source = opened["tileId"] as? String, let sourceId = UUID(uuidString: source) else {
        throw WorkspaceAPIChecks.Failure(message: "popup source missing")
    }
    _ = try call("browser.evaluate", ["tileId": source,
        "script": "() => { document.body.innerHTML = '<a href=\"about:blank\" target=\"_blank\">Open popup</a>'; return true; }"])
    let snapshot = try call("browser.snapshot", ["tileId": source])
    guard let outline = snapshot["text"] as? String,
          let line = outline.split(separator: "\n").first(where: { $0.contains("Open popup") }),
          let match = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
        throw WorkspaceAPIChecks.Failure(message: "popup link missing from snapshot")
    }
    let ref = String(line[match].dropFirst(5).dropLast())
    _ = try call("browser.click", ["tileId": source, "ref": ref])
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && f.canvas.allWorkspaceTiles().filter({ $0.kind == .browser && $0.metadata.browserOwnerAgentId == f.agentId }).count < 2 {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    let children = f.canvas.allWorkspaceTiles().filter { $0.kind == .browser && $0.id != sourceId && $0.metadata.browserOwnerAgentId == f.agentId }
    guard children.count == 1, children[0].metadata.browserProfileId == BrowserProfile.agentsProfileId,
          let child = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId == children[0].id }),
          child.agentNavigationDecision != nil else {
        throw WorkspaceAPIChecks.Failure(message: "agent popup must create a live owned and gated Agents-profile browser")
    }
    var pendingApproval: (@MainActor (WorkspaceAPIService.BrowserDomainDecision) -> Void)?
    f.api.browserDomainApprovalHandler = { _, _, _, reply in pendingApproval = reply; return {} }
    _ = try call("browser.evaluate", ["tileId": source,
        "script": "() => { document.body.innerHTML = '<a href=\"https://popup-takeover.invalid/\" target=\"_blank\">Remote popup</a>'; return true; }"])
    let remoteSnapshot = try call("browser.snapshot", ["tileId": source])
    guard let remoteOutline = remoteSnapshot["text"] as? String,
          let remoteLine = remoteOutline.split(separator: "\n").first(where: { $0.contains("Remote popup") }),
          let remoteMatch = remoteLine.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
        throw WorkspaceAPIChecks.Failure(message: "remote popup link missing")
    }
    _ = try call("browser.click", ["tileId": source, "ref": String(remoteLine[remoteMatch].dropFirst(5).dropLast())])
    let approvalDeadline = Date().addingTimeInterval(5)
    while pendingApproval == nil && Date() < approvalDeadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard let approval = pendingApproval else { throw WorkspaceAPIChecks.Failure(message: "remote popup must ask for its destination") }
    f.api.takeBackBrowser(tileId: sourceId)
    approval(.allowForSession)
    let waitDeadline = Date().addingTimeInterval(0.6)
    while Date() < waitDeadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    let attemptedRemote = f.runtime.liveControllers.flatMap(\.browserRuntimes).contains { runtime in
        runtime.networkLiteEvents.contains { $0.kind == BrowserNetworkLiteEventKind.navigationStarted.rawValue && $0.url.contains("popup-takeover.invalid") }
    }
    guard !attemptedRemote, f.api.browserDomainApprovals[f.agentId]?.contains("popup-takeover.invalid") != true else {
        throw WorkspaceAPIChecks.Failure(message: "taking control while popup approval is pending must prevent its remote request and session grant")
    }
    f.runtime.liveControllers.flatMap(\.browserRuntimes).forEach { $0.terminate(policy: .force) }
}
