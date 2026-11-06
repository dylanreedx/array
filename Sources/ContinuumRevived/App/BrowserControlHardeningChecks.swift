import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

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
final class BrowserHardeningHarness {
    let f: WorkspaceAPIChecks.Fixture
    let window: NSWindow
    var permission: WorkspaceToolsPermission = .free

    init(fakedKey: Bool = false, realKey: Bool = false) throws {
        f = try WorkspaceAPIChecks.makeFixture()
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        window = fakedKey ? BrowserFakedKeyCheckWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false) : (realKey ? BrowserFocusCheckWindow(contentRect: f.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false) : NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false))
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
                              "op": "browser.scroll", "payload": ["tileId": user.tileId.uuidString, "dy": 0]]) { response = $0 }
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
    _ = try h.ok("browser.scroll", ["tileId": user.tileId.uuidString, "dy": 0])
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
func runBrowserDurableTakeoverCheck(experimental: Bool = false) throws {
    let priorSwitch = BrowserAutomation.focusFreeInputEnabled
    BrowserAutomation.focusFreeInputEnabled = experimental
    defer { BrowserAutomation.focusFreeInputEnabled = priorSwitch }
    let h = try BrowserHardeningHarness(fakedKey: experimental)
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let browser = h.live(tile) else { throw WorkspaceAPIChecks.Failure(message: "missing runtime") }
    h.window.setContentSize(NSSize(width: 6000, height: 4000))
    h.f.canvas.frame = NSRect(x: 0, y: 0, width: 6000, height: 4000)
    h.pump(0.1)
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": """
        () => {
          document.body.innerHTML = '<style>#choice{display:none}#menu:hover #choice,#menu.open #choice{display:block}</style><div id="menu"><button id="opener">Pointer opener</button><button id="choice">Pointer choice</button></div><p title="Pointer tooltip">Tooltip</p><p draggable="true">Draggable text and selection</p>';
          window.pointerEvents = []; window.pointerChoice = 0;
          const menu = document.getElementById('menu');
          document.getElementById('opener').onclick = () => menu.classList.add('open');
          document.getElementById('choice').onclick = () => pointerChoice++;
          menu.addEventListener('mouseleave', () => menu.classList.remove('open'));
          for (const type of ['mousemove','mouseenter','mouseleave','dragstart'])
            document.addEventListener(type, e => { if(e.isTrusted) pointerEvents.push(type) }, true);
          return true;
        }
        """])
    func pointerRef(_ label: String) throws -> String {
        let text = try h.ok("browser.snapshot", ["tileId": tile.uuidString])["text"] as? String ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.contains(label) }),
              let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else {
            throw WorkspaceAPIChecks.Failure(message: "missing pointer fixture ref: \(label)")
        }
        return String(line[range].dropFirst(5).dropLast())
    }
    _ = try h.ok("browser.click", ["tileId": tile.uuidString, "ref": try pointerRef("Pointer opener")])
    let parentBefore = browser.webView.superview
    let responderBefore = h.window.firstResponder
    let countBefore = browser.automation.userInputCount
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => { pointerEvents = []; return true }"])
    for local in [NSPoint(x: 30, y: 30), NSPoint(x: 500, y: 300)] {
        let point = browser.webView.convert(local, to: nil)
        for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            NSApp.sendEvent(event)
            // Exercise window routing as well when inactive NSApp routing drops input.
            h.window.sendEvent(event)
        }
        for type: NSEvent.EventType in [.mouseEntered, .mouseExited] {
            let event = NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            NSApp.sendEvent(event)
        }
    }
    h.pump(0.1)
    let pointerState = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => JSON.stringify({events:pointerEvents,hover:document.getElementById('menu').matches(':hover'),open:document.getElementById('menu').classList.contains('open')})"])
    print("Pointer fixture observation (synthetic off-screen only): \(pointerState["value"] ?? "missing")")
    _ = try h.ok("browser.click", ["tileId": tile.uuidString, "ref": try pointerRef("Pointer choice")])
    let picked = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => pointerChoice"])
    try expect(picked["value"] as? Int == 1, "agent next click must still reach the dropdown choice")
    try expect(h.live(tile) === browser && browser.webView.superview === parentBefore &&
        h.window.firstResponder === responderBefore && browser.automation.userInputCount == countBefore,
        "passive pointer fixture changed browser runtime, parent, responder or control generation")
    if experimental {
        _ = try h.ok("browser.evaluate", ["tileId":tile.uuidString,"script":"() => { document.body.innerHTML='<button>Target</button>'; return true }"])
        let text = try h.ok("browser.snapshot", ["tileId":tile.uuidString])["text"] as? String ?? ""
        guard let line = text.split(separator:"\n").first(where:{$0.contains("Target")}), let range = line.range(of:#"\[ref=([^\]]+)\]"#,options:.regularExpression) else { throw WorkspaceAPIChecks.Failure(message:"missing nested takeover target") }
        let ref = String(line[range].dropFirst(5).dropLast())
        let before = browser.automation.userInputCount
        var immediateCount = before
        browser.automation._duringAgentClickForChecks = { h.userKey(into:browser); immediateCount = browser.automation.userInputCount }
        let answer = try h.raw("browser.click", ["tileId":tile.uuidString,"ref":ref])
        browser.automation._duringAgentClickForChecks = nil
        try expect(immediateCount == before+1 && browser.automation.userInputCount == before+1, "real tile key during native delivery must count as takeover")
        try expect(answer["status"] as? String == "error", "nested takeover must fence click result")
        let mutation = try h.raw("browser.evaluate", ["tileId":tile.uuidString,"script":"() => 1"])
        try expect(h.errorCode(mutation) == "target_conflict", "nested takeover must stay paused")
        guard let surface = h.f.canvas.tileView(for:tile) as? BrowserTileNSView else { throw WorkspaceAPIChecks.Failure(message:"missing nested handback") }
        surface.qaChooseAgentControl("return")
        _ = try h.ok("browser.snapshot", ["tileId":tile.uuidString])
        print("PASS: Tier A faked key nested tile-local key takes over during native click and requires explicit handback")
    }
    h.window.setContentSize(NSSize(width: 6000, height: 4000))
    h.f.canvas.frame = NSRect(x: 0, y: 0, width: 6000, height: 4000)
    func scroll(at point: NSPoint, flags: CGEventFlags = [], delta: Int32 = -12, phase: Int64 = 0, momentum: Int64 = 0) throws {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0)!
        let screen = h.window.convertPoint(toScreen: point)
        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(h.window.windowNumber))
        cg.flags = flags
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let event = NSEvent(cgEvent: cg)!
        print("Scroll witness delta=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)")
        NSApp.sendEvent(event)
    }
    let count = browser.automation.userInputCount
    for flags: CGEventFlags in [[], .maskCommand] {
        try scroll(at: NSPoint(x: 4, y: 4), flags: flags)
    }
    try expect(browser.automation.userInputCount == count, "outside canvas scroll/zoom must not take browser control")
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
    h.f.canvas.cameraDriver.noteScrollZoom(deltaY: 1, location: .zero)
    try expect(h.f.canvas.cameraDriver.isCameraSessionActive, "camera fixture must start a zoom session")
    try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil))
    try expect(browser.automation.userInputCount == count, "camera follow-through scroll over a driven browser must not take control")
    for phase: Int64 in [1, 2, 4, 8] {
        h.f.canvas.cameraDriver.noteScrollZoom(deltaY: 1, location: .zero)
        try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil), phase: phase)
        try expect(browser.automation.userInputCount == count, "camera scroll phase must not take browser control")
    }
    for momentum: Int64 in [1, 2, 3] {
        h.f.canvas.cameraDriver.noteScrollZoom(deltaY: 1, location: .zero)
        try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil), momentum: momentum)
        try expect(browser.automation.userInputCount == count, "camera momentum must not take browser control")
    }
    h.pump(2)
    for phase: Int64 in [1, 2, 4, 8] {
        try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil), delta: 0, phase: phase)
        try expect(browser.automation.userInputCount == count, "zero-delta scroll phase must not take browser control after camera settles")
    }
    for momentum: Int64 in [1, 2, 3] {
        try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil), delta: 0, momentum: momentum)
        try expect(browser.automation.userInputCount == count, "zero-delta momentum must not take browser control after camera settles")
    }

    try scroll(at: browser.webView.convert(NSPoint(x: 30, y: 30), to: nil))
    try expect(browser.automation.userInputCount > count, "tile scroll must take browser control")
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
    let persisted = try h.f.storePb.loadCanvas()
    guard let saved = persisted.tiles.first(where: { $0.id == tile }) else { throw WorkspaceAPIChecks.Failure(message: "handback did not persist its tile") }
    try expect(saved.metadata.browserControlPaused == false, "handback must synchronously persist its snapshot requirement")
    let encoded = try JSONEncoder().encode(saved)
    let decoded = try JSONDecoder().decode(Tile.self, from: encoded)
    guard var mounted = h.f.canvas.tileRecord(for: tile) else { throw WorkspaceAPIChecks.Failure(message: "missing mounted handback tile") }
    mounted.metadata = decoded.metadata
    h.f.canvas.updateTile(mounted, recalculateZoneBounds: false)
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
    let cameraBefore = h.f.canvas.canvasState.viewport
    mouse(.leftMouseDown, start, flags: .command)
    mouse(.leftMouseDragged, NSPoint(x: 24, y: 24), flags: .command)
    mouse(.leftMouseUp, NSPoint(x: 24, y: 24), flags: .command)
    try expect(h.f.canvas.canvasState.viewport != cameraBefore, "camera input did not reach the camera driver")
    try expect(browser.automation.userInputCount == count, "camera pan must not take browser control")
    try h.f.runtime.switchWorkspace(to: h.f.workspaceWB)
    try h.f.runtime.switchWorkspace(to: h.f.workspaceWA)
    try expect(!h.f.api.browserUserTakenOver.contains(tile), "workspace navigation must not take browser control")
    try expect(h.f.canvas.tileRecord(for: tile)?.metadata.browserControlPaused != true, "unrelated user work must leave ownership intact")
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
}

@MainActor
func runBrowserRefIdentityCheck() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, page) = try h.ownedBrowser()
    try Data("<html><body><button onclick='window.hit=(window.hit||0)+1'>Target</button></body></html>".utf8).write(to: page)
    _ = try h.ok("browser.navigate", ["tileId": tile.uuidString, "action": "reload"])
    func snapshotRef() throws -> String {
        let result = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
        guard let text = result["text"] as? String,
              let line = text.split(separator: "\n").first(where: { $0.contains("- button \"Target\"") }),
              let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else {
            throw WorkspaceAPIChecks.Failure(message: "no actual Target node ref: \(result)")
        }
        return String(line[range].dropFirst(5).dropLast())
    }
    var old = try snapshotRef()
    let second = page.deletingLastPathComponent().appendingPathComponent("same-nodes.html")
    try Data(contentsOf: page).write(to: second)
    for navigation: [String: Any] in [["url": second.absoluteString], ["action": "reload"], ["action": "back"], ["action": "forward"]] {
        var payload = navigation; payload["tileId"] = tile.uuidString
        _ = try h.ok("browser.navigate", payload)
        let fresh = try snapshotRef()
        try expect(fresh != old, "document change reused a node ref: \(old)")
        let answer = try h.raw("browser.click", ["tileId": tile.uuidString, "ref": old])
        try expect(h.errorCode(answer) == "target_conflict", "stale ref must reject: \(answer)")
        old = fresh
    }
    guard let view = h.f.canvas.tileView(for: tile) as? BrowserTileNSView, let browser = h.live(tile) else {
        throw WorkspaceAPIChecks.Failure(message: "no tab surface")
    }
    let originalTab = view.activeTabIdForQA
    view.createTabForQA(url: second.absoluteString, title: "Replacement")
    h.pump(3) { !browser.webView.isLoading }
    let replacementRef = try snapshotRef()
    try expect(replacementRef != old, "tab replacement reused the old ref")
    view.selectTabForQA(tabId: originalTab)
    h.pump(3) { !browser.webView.isLoading }
    let restoredRef = try snapshotRef()
    try expect(restoredRef != old && restoredRef != replacementRef, "tab restoration reused an old ref")
    let rejected = try h.raw("browser.click", ["tileId": tile.uuidString, "ref": replacementRef])
    try expect(h.errorCode(rejected) == "target_conflict", "ref from replaced tab must reject")
    try Data(#"""
    <html><body><input id="field" aria-label="Submit field" oninput="if(this.value.length===3) document.getElementById('other').focus()">
    <input id="other" onkeydown="if(event.key==='Enter')window.wrongSubmit=true"></body></html>
    """#.utf8).write(to: page)
    _ = try h.ok("browser.navigate", ["tileId": tile.uuidString, "url": page.absoluteString])
    let target = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let outline = target["text"] as? String,
          let field = outline.split(separator: "\n").first(where: { $0.contains("- textbox \"Submit field\"") }),
          let tag = field.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else {
        throw WorkspaceAPIChecks.Failure(message: "no submit field")
    }
    let typed = try h.raw("browser.type", ["tileId": tile.uuidString, "ref": String(field[tag].dropFirst(5).dropLast()), "text": "abc", "submit": true])
    try expect(h.errorCode(typed) == "target_conflict", "submit must refuse after final-character focus change: \(typed)")
    let wrongSubmit = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => Boolean(window.wrongSubmit)"])
    try expect(wrongSubmit["value"] as? Bool == false, "Enter reached a different field")
}

@MainActor
func runBrowserActionResultsCheck() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    let script = "async () => { window.actionCount=(window.actionCount||0)+1; await new Promise(r=>setTimeout(r,17000)); return true; }"
    let payload: [String: Any] = ["tileId": tile.uuidString, "script": script, "idempotencyKey": "uncertain-evaluation"]
    var expired: WorkspaceAPIService.Reply?
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        h.f.api.dispatchBrowserAction(agentId: h.f.agentId, requestId: "queued-expiry", operation: .browserEvaluate,
            payload: ["tileId": tile.uuidString, "script": "() => { window.expiredEffect=true; return true; }"], isCancelled: { false },
            arrived: Date().addingTimeInterval(-14.99), completion: { expired = $0 })
    }
    let first = try h.raw("browser.evaluate", payload, timeout: 22)
    guard case .error(let expiredError)? = expired else { throw WorkspaceAPIChecks.Failure(message: "queued expiry did not report an error") }
    try expect(expiredError.action?.state == .queueExpired && expiredError.action?.effects == BrowserActionResult.Effects.none, "queue expiry must report no effects: \(expiredError), \(String(describing: expiredError.action))")
    let retry = try h.raw("browser.evaluate", payload, timeout: 4)
    func action(_ response: [String: Any]) -> [String: Any]? {
        ((response["error"] as? [String: Any])?["details"] as? [String: Any])?["action"] as? [String: Any]
    }
    try expect(h.errorCode(first) == "outcome_unknown", "dispatched evaluation must time out with uncertain effects")
    guard let report = action(first), let repeated = action(retry) else { throw WorkspaceAPIChecks.Failure(message: "browser errors need structured action results") }
    try expect(report["effects"] as? String == "unknown", "timeout after dispatch must not claim no effects")
    try expect(report["freshSnapshotRequired"] as? Bool == true, "timeout must require observation")
    try expect(report["actionId"] as? String == repeated["actionId"] as? String, "same-key retry must retain action identity")
    h.pump(0.1)
    h.f.api.browserActionQueue = BrowserActionQueue()
    let restarted = try h.raw("browser.evaluate", payload, timeout: 4)
    try expect(action(restarted)?["effects"] as? String == "unknown", "restart must retain uncertain retry history")
    let observed = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => window.actionCount"])
    try expect(observed["value"] as? Int == 1, "same-key timeout retry dispatched input twice")
    let settledScript = "() => { window.settledDispatches=(window.settledDispatches||0)+1; return true; }"
    for n in 0..<70 {
        _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": settledScript, "idempotencyKey": "settled-\(n)"])
    }
    _ = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": settledScript, "idempotencyKey": "settled-0"])
    let settled = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => window.settledDispatches"])
    try expect(settled["value"] as? Int == 70, "evicting a settled result must not permit a same-key input replay")
    let (typingTile, page) = try h.ownedBrowser()
    try Data("<html><body><input aria-label='Field'></body></html>".utf8).write(to: page)
    _ = try h.ok("browser.navigate", ["tileId": typingTile.uuidString, "action": "reload"])
    let snap = try h.ok("browser.snapshot", ["tileId": typingTile.uuidString])
    guard let text = snap["text"] as? String,
          let line = text.split(separator: "\n").first(where: { $0.contains("- textbox \"Field\"") }),
          let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression),
          let browser = h.live(typingTile) else { throw WorkspaceAPIChecks.Failure(message: "no typing field") }
    let ref = String(line[range].dropFirst(5).dropLast())
    let stop = Date().addingTimeInterval(4)
    func interrupt() {
        if browser.automation.actionDeliveredCharacters >= 3 { h.userKey(into: browser) }
        else if Date() < stop { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { interrupt() } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { interrupt() }
    let partial = try h.raw("browser.type", ["tileId": typingTile.uuidString, "ref": ref, "text": String(repeating: "x", count: 200), "idempotencyKey": "partial-type"])
    guard let prefix = action(partial), let count = prefix["deliveredCharacters"] as? Int else { throw WorkspaceAPIChecks.Failure(message: "missing partial typing report: \(partial)") }
    try expect(prefix["effects"] as? String == "partial" && count >= 3 && count < 200, "takeover must report a bounded dispatched prefix: \(partial)")
    let delivered = browser.automation.actionDeliveredCharacters
    let partialRetry = try h.raw("browser.type", ["tileId": typingTile.uuidString, "ref": ref, "text": String(repeating: "x", count: 200), "idempotencyKey": "partial-type"])
    try expect(action(partialRetry)?["effects"] as? String == "partial", "partial retry must retain the original effect report")
    try expect(browser.automation.actionDeliveredCharacters == delivered, "same-key partial retry must not dispatch")
}

@MainActor
func runBrowserWriterTransferCheck() throws {
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let supervisor = h.f.delegate.qaAgentSupervisor
    let reader = supervisor.spawn(role: nil, prompt: nil, cwd: h.f.pbRoot, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: h.f.projectPb, projectRoot: h.f.pbRoot)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: reader, true)
    let (tile, page) = try h.ownedBrowser()
    try Data("<html><body><button>Target</button></body></html>".utf8).write(to: page)
    _ = try h.ok("browser.navigate", ["tileId": tile.uuidString, "action": "reload"])
    let before = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let text = before["text"] as? String,
          let line = text.split(separator: "\n").first(where: { $0.contains("- button \"Target\"") }),
          let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression),
          let view = h.f.canvas.tileView(for: tile) as? BrowserTileNSView else { throw WorkspaceAPIChecks.Failure(message: "no writer fixture") }
    let ref = String(line[range].dropFirst(5).dropLast())
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => { document.body.insertAdjacentHTML('beforeend','<button>Added</button>'); return true; }"])
    let read = try h.raw("browser.snapshot", ["tileId": tile.uuidString], agent: reader)
    try expect(read["status"] as? String == "ok", "a reader must be able to observe the tile")
    try expect(h.f.canvas.tileRecord(for: tile)?.metadata.browserControllingAgentId == h.f.agentId, "reader changed the writer")
    let clicked = try h.ok("browser.click", ["tileId": tile.uuidString, "ref": ref])
    try expect((clicked["changes"] as? [String])?.contains(where: { $0.contains("Added") }) == true, "reader snapshot replaced the writer's comparison baseline")
    let transfer = "writer-" + reader.rawValue.uuidString
    var stayedWithWriter = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        view.qaChooseAgentControl(transfer)
        stayedWithWriter = h.f.canvas.tileRecord(for: tile)?.metadata.browserControllingAgentId == h.f.agentId
    }
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "async () => { await new Promise(r=>setTimeout(r,150)); return true; }"])
    try expect(stayedWithWriter, "transfer must refuse while an action is running")
    h.pump(0.1)
    view.qaChooseAgentControl(transfer)
    try expect(h.f.canvas.tileRecord(for: tile)?.metadata.browserControllingAgentId == reader, "explicit quiescent transfer did not change writer")
    let denied = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
    try expect(h.errorCode(denied) == "permission_denied" || h.errorCode(denied) == "target_conflict", "old writer must lose mutation access")
    let premature = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"], agent: reader)
    try expect(h.errorCode(premature) == "target_conflict", "new writer needs a fresh snapshot")
    let snapshot = try h.raw("browser.snapshot", ["tileId": tile.uuidString], agent: reader)
    try expect(snapshot["status"] as? String == "ok", "new writer snapshot failed")
    let written = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"], agent: reader)
    try expect(written["status"] as? String == "ok", "new writer cannot mutate after snapshot")
    let oldWriter = try h.raw("browser.evaluate", ["tileId": tile.uuidString, "script": "() => true"])
    try expect(h.errorCode(oldWriter) == "permission_denied", "old writer regained access after the new writer's snapshot")
}

@MainActor
func runBrowserBackgroundSchedulingCheck() throws {
    let priorSwitch = BrowserAutomation.focusFreeInputEnabled
    BrowserAutomation.focusFreeInputEnabled = true
    defer { BrowserAutomation.focusFreeInputEnabled = priorSwitch }
    let h = try BrowserHardeningHarness()
    defer { h.tearDown() }
    let (tile, _) = try h.ownedBrowser()
    _ = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    guard let browser = h.live(tile) else { throw WorkspaceAPIChecks.Failure(message: "missing browser") }
    _ = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => { window.timerTicks=0; window.animationTicks=0; window.timerID=setInterval(()=>timerTicks++,10); function frame(){ animationTicks++; requestAnimationFrame(frame) }; requestAnimationFrame(frame); return true }"])
    func counters() throws -> [String: Any] {
        let answer = try h.ok("browser.evaluate", ["tileId": tile.uuidString, "script": "() => ({timer:timerTicks, animation:animationTicks, visibility:document.visibilityState})"])
        return answer["value"] as? [String: Any] ?? [:]
    }
    let before = try counters()
    h.pump(1)
    let after = try counters()
    let ticks = (after["timer"] as? Int ?? 0) - (before["timer"] as? Int ?? 0)
    try expect(ticks >= 20, "engaged hidden page timer remained throttled: \(ticks) ticks in one second; \(before) -> \(after)")
    print("Engaged timers: \(ticks)/s; rAF delta=\((after["animation"] as? Int ?? 0) - (before["animation"] as? Int ?? 0)); visibility=\(after["visibility"] ?? "unknown")")
    h.userKey(into: browser)
    h.pump(0.1)
    let prefs = browser.webView.configuration.preferences
    let defaults = WKPreferences()
    for name in ["_hiddenPageDOMTimerThrottlingEnabled", "_pageVisibilityBasedProcessSuppressionEnabled"] {
        let selector = NSSelectorFromString(name)
        try expect(prefs.responds(to: selector) && defaults.responds(to: selector), "missing scheduling getter \(name)")
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let actual = unsafeBitCast(prefs.method(for: selector), to: Getter.self)(prefs, selector)
        let original = unsafeBitCast(defaults.method(for: selector), to: Getter.self)(defaults, selector)
        try expect(actual == original, "takeover did not restore \(name)")
    }
    try expect(prefs.inactiveSchedulingPolicy == defaults.inactiveSchedulingPolicy, "takeover did not restore inactive scheduling policy")
    let snapshot = try h.ok("browser.snapshot", ["tileId": tile.uuidString])
    try expect((snapshot["backgroundScheduling"] as? String)?.contains("requestAnimationFrame") == true, "snapshot must name the hidden rAF limitation")
    print("PASS: production lease accelerates timers and takeover restores scheduling; hidden rAF remains limited")
}
