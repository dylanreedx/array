import AppKit
import ContinuumRevivedCore
import Foundation

/// Review findings on the agent browser API, each driven through the
/// provider entry (`handleMCPRequest`) on the production-mounted fixture.
/// Every scenario gets its own fixture and all of them run, so one failure
/// cannot hide another.
@MainActor
func runBrowserControlHardeningChecks() throws {
    let scenarios: [(String, () throws -> Void)] = [
        ("a tile moved off the Agents profile needs a hand-over", runProfileSwitchScenario),
        ("Ask first asks before an agent reads a user tile", runAskFirstReadScenario),
        ("a taken-over tile rehydrates without the agent gate", runTakenOverRehydrationScenario),
        ("a same-document navigation finishes and frees the tile", runFragmentNavigationScenario),
        ("a page cannot stack domain prompts", runPromptFloodScenario),
        ("the real hand-over sheet names the page and pauses its clock", runProductionSheetScenario),
        ("site grants follow visits and public suffix boundaries", runSiteScopeScenario),
        ("cancelled existing-browser navigation dismisses its site sheet", runCancelledNavigationScenario),
        ("real navigation, reclaim and reopen end a browser visit", runActualVisitScenario),
        ("one project takeover includes JavaScript across browser tiles", runBrowserSessionScenario),
        ("queued site approval pauses the action budget", runQueuedDomainApprovalScenario),
        ("cancelled scope approval cannot create session consent", runCancelledScopeScenario),
        ("Ask-first approval time does not spend the action deadline", runSlowApprovalScenario),
        ("revocation releases a handed-over user tile", runRevocationReleaseScenario),
        ("a reload in an unloaded zone leaves one runtime when the zone returns", runUnloadedZoneReloadScenario),
    ]
    var failures: [String] = []
    for (name, scenario) in scenarios {
        do { try scenario() } catch { failures.append("\(name): \(error)") }
    }
    guard failures.isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "\(failures.count) of \(scenarios.count) browser hardening scenario(s) failed:\n- "
            + failures.joined(separator: "\n- "))
    }
}

@MainActor
private final class BrowserHardeningHarness {
    let f: WorkspaceAPIChecks.Fixture
    let window: NSWindow
    var permission: WorkspaceToolsPermission = .free

    init() throws {
        f = try WorkspaceAPIChecks.makeFixture()
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        window = NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = f.canvas
        window.orderFrontOffscreenForChecks()
        f.delegate.qaAgentSupervisor.workspaceToolsPermission = { [unowned self] in self.permission }
        f.api.approvalHandler = { _ in .allowForSession }
    }

    func tearDown() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        f.tearDown()
    }

    func pump(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func raw(_ op: String, _ payload: [String: Any], agent: AgentID? = nil, timeout: TimeInterval = 20) throws -> [String: Any] {
        var response: [String: Any]?
        f.api.handleMCPRequest(["agentId": (agent ?? f.agentId).rawValue.uuidString, "requestId": UUID().uuidString,
                                "op": op, "payload": payload]) { response = $0 }
        pump(timeout) { response != nil }
        guard let response else { throw WorkspaceAPIChecks.Failure(message: "\(op) did not answer within \(Int(timeout)) s") }
        return response
    }

    func ok(_ op: String, _ payload: [String: Any], timeout: TimeInterval = 20) throws -> [String: Any] {
        let response = try raw(op, payload, timeout: timeout)
        guard response["status"] as? String == "ok", let result = response["result"] as? [String: Any] else {
            throw WorkspaceAPIChecks.Failure(message: "\(op) failed: \(response)")
        }
        return result
    }

    func errorCode(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }

    func live(_ tileId: UUID) -> WKWebViewBrowserRuntime? {
        f.runtime.liveControllers.flatMap(\.browserRuntimes).first { $0.tileId == tileId && !$0.isTerminated }
    }

    /// An agent-owned browser on a local page, opened through the API.
    func ownedBrowser(title: String = "Owned page") throws -> (UUID, URL) {
        let page = f.pbRoot.appendingPathComponent("hardening-\(UUID().uuidString.prefix(8)).html")
        try Data("<html><head><title>\(title)</title></head><body><h1 id=top>Top</h1><p id=section>Section</p></body></html>".utf8).write(to: page)
        let opened = try ok("browser.open", ["url": page.absoluteString])
        guard let raw = opened["tileId"] as? String, let tileId = UUID(uuidString: raw), live(tileId) != nil else {
            throw WorkspaceAPIChecks.Failure(message: "browser.open did not create a live tile: \(opened)")
        }
        return (tileId, page)
    }

    /// A user's own Default-profile browser, created the way the canvas does.
    func userBrowser(url: String = "about:blank") throws -> WKWebViewBrowserRuntime {
        let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
        guard case let .spawned(browser) = spawner.spawnBrowser(url: url, beside: f.agentTileB, targetZoneId: f.zoneB) else {
            throw WorkspaceAPIChecks.Failure(message: "could not create a user browser")
        }
        f.api.browserRuntimeWiring?(browser, f.projectPb)
        pump(3) { !browser.webView.isLoading }
        return browser
    }

    /// A real key press into the browser, through the app's event path.
    func userKey(into browser: WKWebViewBrowserRuntime) {
        window.makeFirstResponder(browser.webView)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        NSApp.sendEvent(key)
    }

    /// Every label in the window's attached sheet, which the real presenter
    /// fills from the production alert text.
    func sheetText() -> String? {
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { return nil }
        var parts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { parts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        walk(content)
        return parts.joined(separator: "\n")
    }
}

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw WorkspaceAPIChecks.Failure(message: message()) }
}

/// Finding 1: moving an agent's tile to Default hands it the user's sessions.
@MainActor
private func runProfileSwitchScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, _) = try h.ownedBrowser()
    let spawner = try h.f.runtime.ensureSpawner(forProjectId: h.f.projectPb)
    guard let switchProfile = spawner.browserProfileSwitchHandler else {
        throw WorkspaceAPIChecks.Failure(message: "the project spawner has no production profile-switch handler")
    }
    switchProfile(tileId, BrowserProfile.defaultProfileId)
    h.pump(3) { h.live(tileId)?.webView.isLoading == false }
    try expect(h.f.canvas.tileRecord(for: tileId)?.metadata.browserProfileId == BrowserProfile.defaultProfileId,
               "the profile menu must move the tile to Default")
    var handOverPrompts = 0
    h.f.api.browserHandOverApprovalHandler = { _, _, _, reply in handOverPrompts += 1; reply(false); return {} }
    let control = try h.raw("browser.press_key", ["tileId": tileId.uuidString, "keyName": "Enter"])
    try expect(h.errorCode(control) == "scope_approval_required" && handOverPrompts == 1,
               "control of a tile moved to Default must ask for a hand-over: prompts=\(handOverPrompts) reply=\(control)")
    let evaluate = try h.raw("browser.evaluate", ["tileId": tileId.uuidString, "script": "() => document.cookie"])
    try expect(h.errorCode(evaluate) == "scope_approval_required",
               "JavaScript in a tile moved to Default must not run on the old owner stamp: \(evaluate)")
    try expect(h.f.api.browserLeaseLedger?.protectedTileIds().contains(tileId) != true,
               "a tile moved to Default must leave the agent lease, or the idle sweep could close it")
}

/// Finding 2 (Ask first only): D1 reads follow the inspect rules, which ask.
@MainActor
private func runAskFirstReadScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let user = try h.userBrowser()
    var handOverPrompts = 0
    h.f.api.browserHandOverApprovalHandler = { _, _, _, reply in handOverPrompts += 1; reply(false); return {} }
    h.permission = .askFirst
    let read = try h.raw("browser.snapshot", ["tileId": user.tileId.uuidString])
    try expect(h.errorCode(read) == "scope_approval_required" && handOverPrompts == 1,
               "under Ask first, reading a user tile must ask: prompts=\(handOverPrompts) reply=\(read)")
    h.permission = .free
    _ = try h.ok("browser.snapshot", ["tileId": user.tileId.uuidString])
    try expect(handOverPrompts == 1, "under Free, D1 lets an agent read a project browser without asking")
}

/// Finding 3: after the user takes a tile back, a reload must not re-arm the
/// agent's local-only gate on the user's browsing.
@MainActor
private func runTakenOverRehydrationScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, _) = try h.ownedBrowser()
    guard let browser = h.live(tileId) else { throw WorkspaceAPIChecks.Failure(message: "owned browser is not live") }
    h.userKey(into: browser)
    try expect(browser.agentNavigationDecision == nil, "a user key must take the tile back")
    guard let controller = h.f.runtime.controller(for: h.f.projectPb), controller.onBrowserRuntimeHydrated != nil else {
        throw WorkspaceAPIChecks.Failure(message: "the project controller lacks the production hydration callback")
    }
    h.window.makeFirstResponder(nil)
    try controller.setTier(.snapshot, allowDehydratingFocusedZone: true)
    try controller.setTier(.live)
    guard let restored = h.live(tileId), restored.id != browser.id else {
        throw WorkspaceAPIChecks.Failure(message: "the tile did not rehydrate with a new runtime")
    }
    try expect(restored.agentNavigationDecision == nil,
               "a taken-over tile must rehydrate without the agent's navigation gate, or the user's own remote links are cancelled"
               + " (taken over: \(h.f.api.browserUserTakenOver.contains(tileId)), restore route: \(controller.tileSpawner?.agentBrowserRestoreGateOwner != nil))")
}

/// Finding 4: WebKit sends no didFinish for a fragment navigation.
@MainActor
private func runFragmentNavigationScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, page) = try h.ownedBrowser()
    let started = Date()
    _ = try h.ok("browser.navigate", ["tileId": tileId.uuidString, "url": page.absoluteString + "#section"])
    try expect(Date().timeIntervalSince(started) < 5, "a fragment navigation must return promptly")
    let next = try h.raw("browser.navigate", ["tileId": tileId.uuidString, "url": page.absoluteString])
    try expect(next["status"] as? String == "ok", "the tile must accept navigation after a fragment navigation: \(next)")
}

/// Finding 5: page script must not queue a sheet per navigation.
@MainActor
private func runPromptFloodScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, _) = try h.ownedBrowser()
    h.permission = .askFirst
    var pending: [(WorkspaceAPIService.BrowserDomainDecision) -> Void] = []
    h.f.api.browserDomainApprovalHandler = { _, _, _, reply in pending.append(reply); return {} }
    defer { pending.forEach { $0(.deny) } }
    _ = try h.ok("browser.evaluate", ["tileId": tileId.uuidString, "script":
        "() => { for (let i = 0; i < 6; i++) setTimeout(() => { location.href = 'https://flood' + i + '.invalid/'; }, i * 60); return true; }"])
    h.pump(1.5)
    try expect(pending.count == 1, "one tile may hold one pending domain prompt; the page raised \(pending.count)")
}

/// Findings 5 and 6, through the production presenter: the hand-over sheet
/// says which page and profile, and it closes when its request expires.
@MainActor
private func runProductionSheetScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let page = h.f.pbRoot.appendingPathComponent("signed-in-page.html")
    try Data("<html><head><title>Billing dashboard</title></head><body>Signed in</body></html>".utf8).write(to: page)
    let user = try h.userBrowser(url: page.absoluteString)
    h.pump(3) { user.title == "Billing dashboard" }
    var response: [String: Any]?
    h.f.api.handleMCPRequest(["agentId": h.f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
                              "op": "browser.press_key", "payload": ["tileId": user.tileId.uuidString, "keyName": "Enter"]]) { response = $0 }
    h.pump(3) { h.window.attachedSheet != nil }
    let text = h.sheetText() ?? ""
    try expect(text.contains("Billing dashboard") && text.contains("Default"),
               "the hand-over sheet must name the page and its profile: \(text)")
    try captureBrowserPermissionSheet(h, name: "browser-handover")
    h.pump(16)
    try expect(response == nil && h.window.attachedSheet != nil, "reading an approval beyond 15 s must leave the request and sheet alive")
    guard let sheet = h.window.attachedSheet else { throw WorkspaceAPIChecks.Failure(message: "approval disappeared") }
    h.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    h.pump(5) { response != nil }
    try expect(response?["status"] as? String == "ok", "the approved action must run after the user finishes reading: \(String(describing: response))")
}

/// Finding 7: the prompt used to run inside the queued action, so its 15 s
/// deadline ran while the user read it.
@MainActor
private func runSlowApprovalScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, _) = try h.ownedBrowser()
    h.permission = .askFirst
    var prompts = 0
    h.f.api.approvalHandler = { _ in
        prompts += 1
        h.pump(16)
        return .allowForSession
    }
    let reply = try h.raw("browser.evaluate", ["tileId": tileId.uuidString, "script": "() => 7"], timeout: 45)
    try expect(prompts == 1 && reply["status"] as? String == "ok",
               "an action approved after 16 s must run, not expire: prompts=\(prompts) reply=\(reply)")
}

/// Finding 8: revoking an agent must not leave its gate on the user's tile.
@MainActor
private func runRevocationReleaseScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let user = try h.userBrowser()
    h.f.api.browserHandOverApprovalHandler = { _, _, _, reply in reply(true); return {} }
    _ = try h.ok("browser.press_key", ["tileId": user.tileId.uuidString, "keyName": "Enter"])
    try expect(user.agentNavigationDecision != nil, "a handed-over tile carries the agent gate while it acts")
    h.f.api.revoke(agentId: h.f.agentId)
    try expect(user.agentNavigationDecision == nil && !user.automation.isEngaged,
               "revocation must release the user's tile: gate=\(user.agentNavigationDecision != nil) engaged=\(user.automation.isEngaged)")
}

/// Review point: an agent reloads its browser while its zone is unloaded.
/// The production hydration pass then brings the zone back; the tile must end
/// with exactly one live runtime (hydration restarts tiles without one, and a
/// second runtime would be an orphan). An off-camera zone staying live during
/// the agent's turn is `--browser-lease-check`'s running pin; between turns it
/// may unload by design, and the next call answers browser_not_live.
@MainActor
private func runUnloadedZoneReloadScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tileId, _) = try h.ownedBrowser()
    guard let controller = h.f.runtime.controller(for: h.f.projectPb) else {
        throw WorkspaceAPIChecks.Failure(message: "the agent's project has no controller")
    }
    try controller.setTier(.snapshot, allowDehydratingFocusedZone: true)
    try expect(h.live(tileId) == nil, "unloading the zone must retire the browser runtime")
    let dead = try h.raw("browser.snapshot", ["tileId": tileId.uuidString])
    try expect(h.errorCode(dead) == "browser_not_live", "an unloaded browser must report browser_not_live: \(dead)")
    _ = try h.ok("browser.navigate", ["tileId": tileId.uuidString, "action": "reload"])
    try expect(h.live(tileId) != nil, "reload must restart the browser")
    h.f.runtime.reconcileHydration(rearmForCamera: false)
    h.pump(1)
    try expect(h.live(tileId) != nil, "the hydration pass must keep the browser the agent just reloaded")
    _ = try h.ok("browser.snapshot", ["tileId": tileId.uuidString])
    try controller.setTier(.live)
    let runtimes = h.f.runtime.liveControllers.flatMap(\.browserRuntimes).filter { $0.tileId == tileId && !$0.isTerminated }
    try expect(runtimes.count == 1, "reloading the zone must leave the tile exactly one live runtime, found \(runtimes.count)")
}

@MainActor
private func runSiteScopeScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    h.permission = .askFirst
    let sites = [("www.example.co.uk", "example.co.uk"), ("other.co.uk", "other.co.uk"),
        ("alice.github.io", "alice.github.io"), ("bob.github.io", "bob.github.io"),
        ("www.city.kawasaki.jp", "city.kawasaki.jp"), ("a.b.kawasaki.jp", "a.b.kawasaki.jp")]
    for (host, expected) in sites { try expect(BrowserSiteScope.site(for: host) == expected, "wrong permission site for \(host)") }
    for host in ["localhost", "0.0.0.0", "10.1.2.3", "172.16.2.4", "192.168.1.2", "[fd00::1]", "[fe80::1]"] {
        try expect(BrowserAgentNavigationPolicy.classify(URL(string: "http://" + host)!, checkoutRoot: h.f.pbRoot) == .local, "local address asked: \(host)")
    }
    let dismissDomain = h.f.delegate.presentBrowserDomainApproval(agentId: h.f.agentId, tileId: tile, host: "example.co.uk") { _ in }
    h.pump(1) { h.window.attachedSheet != nil }
    try captureBrowserPermissionSheet(h, name: "browser-domain")
    dismissDomain()
    h.pump(1) { h.window.attachedSheet == nil }
    var prompts = 0
    h.f.api.browserDomainApprovalHandler = { _, _, _, reply in prompts += 1; reply(.allowOnce); return {} }
    func visit(_ url: String) throws {
        var allowed = false
        h.f.api.authorizeBrowserNavigation(tileId: tile, agentId: h.f.agentId, url: URL(string: url)!) { allowed = $0 }
        try expect(allowed, "visit denied: \(url)")
    }
    try visit("https://www.example.co.uk")
    try visit("https://api.example.co.uk/path")
    try expect(prompts == 1, "Allow Once must cover a visit's pages and same-site subdomains")
    try visit("https://unrelated.co.uk")
    try expect(prompts == 2, "co.uk must not share grants")
    try visit("http://localhost")
    try visit("https://www.example.co.uk")
    try expect(prompts == 3, "returning after leaving must start a new visit")
}

@MainActor
private func runBrowserSessionScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let first = try h.userBrowser()
    let second = try h.userBrowser()
    var takeover = 0
    var javascript = 0
    h.f.api.browserHandOverApprovalHandler = { _, _, evaluate, reply in
        if evaluate {
            javascript += 1
            reply(true)
        } else {
            takeover += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { reply(true) }
        }
        return {}
    }
    _ = try h.ok("browser.evaluate", ["tileId": first.tileId.uuidString, "script": "() => 7"], timeout: 40)
    _ = try h.ok("browser.evaluate", ["tileId": second.tileId.uuidString, "script": "() => 8"])
    let peer = h.f.delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: h.f.pbRoot,
        harness: .pi, model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: h.f.projectPb, projectRoot: h.f.pbRoot)
    _ = h.f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: peer, true)
    let peerReply = try h.raw("browser.evaluate", ["tileId": second.tileId.uuidString, "script": "() => 9"], agent: peer)
    try expect(peerReply["status"] as? String == "ok", "combined consent must cover another enabled agent in the same project")
    try expect(takeover == 1 && javascript == 0, "ONE takeover must include JavaScript across project browser tiles; takeover=\(takeover) javascript=\(javascript)")
}

@MainActor
private func runCancelledScopeScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    h.permission = .askFirst
    var cancelled = false
    var prompts = 0
    h.f.api.approvalHandler = { _ in prompts += 1; cancelled = true; return .allowForSession }
    var response: WorkspaceAPIService.Reply?
    h.f.api.dispatchBrowserAction(agentId: h.f.agentId, requestId: UUID().uuidString, operation: .browserEvaluate,
        payload: ["tileId": tile.uuidString, "script": "() => 1"], isCancelled: { cancelled }) { response = $0 }
    guard case let .error(error)? = response, error.code == .permissionDenied else {
        throw WorkspaceAPIChecks.Failure(message: "cancellation during approval must reject before minting consent")
    }
    h.f.api.approvalHandler = { _ in prompts += 1; return .deny }
    let next = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => 2"])
    try expect(prompts == 2 && h.errorCode(next) == "scope_approval_required", "cancelled approval must not cache project session consent")
}

@MainActor
private func captureBrowserPermissionSheet(_ h: BrowserHardeningHarness, name: String) throws {
    guard let sheet = h.window.attachedSheet, let content = sheet.contentView else {
        throw WorkspaceAPIChecks.Failure(message: "missing browser permission sheet for capture")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("qa-runs/permission-ux", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let previous = sheet.appearance
    defer { sheet.appearance = previous }
    for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        sheet.appearance = NSAppearance(named: appearance)
        sheet.appearance?.performAsCurrentDrawingAppearance {
            content.needsDisplay = true
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            sheet.displayIfNeeded()
        }
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(sheet.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WorkspaceAPIChecks.Failure(message: "browser permission sheet could not render its compositor window")
        }
        try data.write(to: root.appendingPathComponent(name + "-" + label + ".png"))
    }
}


/// Drives WebKit's real policy callback and production sheet, then cancellation.
@MainActor
private func runCancelledNavigationScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, page) = try h.ownedBrowser()
    h.permission = .askFirst
    var cancelled = false
    var response: WorkspaceAPIService.Reply?
    var lateAnswer: ((WorkspaceAPIService.BrowserDomainDecision) -> Void)?
    var dismissed = false
    h.f.api.browserDomainApprovalHandler = { agent, tile, host, reply in
        lateAnswer = reply
        let dismiss = h.f.delegate.presentBrowserDomainApproval(agentId: agent, tileId: tile, host: host, completion: reply)
        return { dismissed = true; dismiss() }
    }
    h.f.api.dispatchBrowserAction(agentId: h.f.agentId, requestId: UUID().uuidString, operation: .browserNavigate,
        payload: ["tileId": tile.uuidString, "url": "https://cancel-navigation.invalid/"],
        isCancelled: { cancelled }) { response = $0 }
    h.pump(3) { h.window.attachedSheet != nil }
    try expect(h.window.attachedSheet != nil && lateAnswer != nil, "navigation must reach the real site sheet")
    cancelled = true
    h.pump(2) { dismissed && h.window.attachedSheet == nil && response != nil }
    // Settle even a broken implementation so the other scenarios still run.
    let cancelledPrompt = dismissed && h.window.attachedSheet == nil && response != nil
    if !dismissed { lateAnswer?(.deny); h.pump(1) }
    lateAnswer?(.allowForProjectSession)
    h.pump(0.2)
    try expect(cancelledPrompt, "cancelled navigation must dismiss its sheet and settle without waiting for the user")
    try expect(h.live(tile)?.webView.url == page, "cancelled destination must never load")
    try expect(h.f.api.browserProjectDomainApprovals[h.f.projectPb]?.contains("cancel-navigation.invalid") != true
               && h.f.api.browserDomainApprovals[h.f.agentId]?.contains("cancel-navigation.invalid") != true,
               "late Allow must not cache consent for cancelled navigation")
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
}

/// HTML loads commit real documents without network access; no authorization
/// helper is called between the user's departure and return.
@MainActor
private func runActualVisitScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let browser = try h.userBrowser()
    let tile = browser.tileId
    func load(_ browser: WKWebViewBrowserRuntime, _ site: String) throws {
        browser.webView.loadHTMLString("<html><head><title>\(site)</title></head><body>Visit</body></html>",
                                      baseURL: URL(string: "https://" + site + "/"))
        h.pump(3) { browser.webView.url?.host == site && !browser.webView.isLoading && browser.title == site }
        try expect(browser.webView.url?.host == site && !browser.webView.isLoading, "fixture document must really load")
        h.pump(0.1)
    }
    var prompts = 0
    h.f.api.browserDomainApprovalHandler = { _, _, _, reply in prompts += 1; reply(.allowOnce); return {} }
    try load(browser, "visit-a.invalid")
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    try expect(prompts == 1, "same live visit must reuse Once")
    try load(browser, "visit-b.invalid")
    try load(browser, "visit-a.invalid")
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    let departureAsked = prompts == 2
    h.userKey(into: browser)
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    let reclaimAsked = prompts == (departureAsked ? 3 : 2)
    guard let controller = h.f.runtime.controller(for: h.f.projectPb) else {
        throw WorkspaceAPIChecks.Failure(message: "missing project controller")
    }
    h.window.makeFirstResponder(nil)
    try controller.setTier(.snapshot, allowDehydratingFocusedZone: true)
    try controller.setTier(.live)
    guard let reopened = h.live(tile), reopened.id != browser.id else {
        throw WorkspaceAPIChecks.Failure(message: "browser must reopen with a new runtime")
    }
    try load(reopened, "visit-a.invalid")
    let beforeReopenRead = prompts
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    try expect(prompts == beforeReopenRead + 1, "runtime reopen must ask for a new visit")
    try expect(departureAsked && reclaimAsked,
               "actual departure/return and user reclaim must each end Once: departure=\(departureAsked) reclaim=\(reclaimAsked)")
}

/// A real remote-origin document loaded from memory keeps this witness offline.
/// Unlike takeover and scope approvals, this site prompt starts only after the
/// action has entered BrowserActionQueue, so it guards the queue's pause too.
@MainActor
private func runQueuedDomainApprovalScenario() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    guard let browser = h.live(tile) else {
        throw WorkspaceAPIChecks.Failure(message: "missing queued domain fixture browser")
    }
    browser.webView.loadHTMLString(
        "<html><head><title>Queued approval</title></head><body>Offline origin fixture</body></html>",
        baseURL: URL(string: "https://queued-approval.invalid/"))
    h.pump(5) {
        browser.webView.url?.host == "queued-approval.invalid" && !browser.webView.isLoading
            && browser.webView.title == "Queued approval"
    }
    try expect(browser.webView.url?.host == "queued-approval.invalid" && !browser.webView.isLoading,
               "the offline document must commit its real remote origin")
    h.permission = .askFirst
    var prompts = 0
    var answered = false
    h.f.api.browserDomainApprovalHandler = { _, _, site, reply in
        prompts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
            answered = true
            reply(site == "queued-approval.invalid" ? .allowOnce : .deny)
        }
        return {}
    }
    let started = Date()
    let result = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => 42"], timeout: 40)
    try expect(answered && prompts == 1 && Date().timeIntervalSince(started) >= 16
        && (result["value"] as? Int) == 42,
        "a queued action must run after 16 seconds reading its site prompt, beyond its 15-second action budget")
    let next = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => 43"])
    try expect(prompts == 1 && (next["value"] as? Int) == 43,
               "after approval the queue must continue and Once must cover the same visit")
}

@MainActor
func runBrowserDurableTakeoverCheck() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let browser = h.live(tile) else { throw WorkspaceAPIChecks.Failure(message: "missing runtime") }
    h.userKey(into: browser)
    h.pump(0.1)
    for _ in 0..<2 {
        let answer = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => { window.reclaimed = true; return true; }"])
        try expect(h.errorCode(answer) == "target_conflict", "takeover must stay paused: \(answer)")
    }
    guard let view = h.f.canvas.tileView(for: tile) as? BrowserTileNSView else {
        throw WorkspaceAPIChecks.Failure(message: "missing browser surface")
    }
    try expect(h.f.canvas.tileRecord(for: tile)?.metadata.browserControlPaused == true, "pause must be stored in tile metadata")
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WorkspaceAPIChecks.Failure(message: "no handback bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/tmp/array-handback-\(name).png")) }
        try expect(view.qaAgentControlItems.contains("return"), "handback missing in \(name)")
    }
    view.setAgentControl(name: "Reader", colour: nil, engaged: false, userDriving: true, takeControl: {}, revealAgent: {}, close: {})
    try expect(!view.qaAgentControlItems.contains("return"), "unsupported handback must be hidden")
    h.f.api.browserControlPresentation?(tile, h.f.agentId, false, true)
    view.qaChooseAgentControl("return")
    // Discard the old service cache as a restart does; only persisted tile state remains.
    h.f.api.browserNeedsHandbackSnapshot.removeAll()
    let encoded = try JSONEncoder().encode(h.f.canvas.tileRecord(for: tile)!)
    let restored = try JSONDecoder().decode(Tile.self, from: encoded)
    h.f.canvas.updateTile(restored, recalculateZoneBounds: false)
    let premature = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
    try expect(h.errorCode(premature) == "target_conflict", "handback must require a snapshot")
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
}

@MainActor
func runBrowserUnrelatedInputCheck() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let browser = h.live(tile) else { throw WorkspaceAPIChecks.Failure(message: "missing browser") }
    let count = browser.automation.userInputCount
    let composer = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 80))
    h.f.canvas.addSubview(composer)
    h.window.makeFirstResponder(composer)
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: h.window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
    NSApp.sendEvent(key)
    try expect(browser.automation.userInputCount == count, "sibling typing must not take browser control")
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }
    let sibling = composer.convert(NSPoint(x: 20, y: 20), to: nil)
    mouse(.leftMouseDown, sibling); mouse(.leftMouseUp, sibling)
    try expect(browser.automation.userInputCount == count, "clicking a sibling surface must not take browser control")
    composer.removeFromSuperview()
    let start = NSPoint(x: 4, y: 4)
    mouse(.leftMouseDown, start, flags: .command)
    mouse(.leftMouseDragged, NSPoint(x: 24, y: 24), flags: .command)
    mouse(.leftMouseUp, NSPoint(x: 24, y: 24), flags: .command)
    try expect(browser.automation.userInputCount == count, "camera pan must not take browser control")
    try h.f.runtime.switchWorkspace(to: h.f.workspaceWB)
    try h.f.runtime.switchWorkspace(to: h.f.workspaceWA)
    try expect(!h.f.api.browserUserTakenOver.contains(tile), "workspace navigation must not take browser control")
    try expect(h.f.canvas.tileRecord(for: tile)?.metadata.browserControlPaused != true, "unrelated user work must leave ownership intact")
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
}
