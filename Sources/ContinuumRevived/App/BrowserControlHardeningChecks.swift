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
        ("the real hand-over sheet names the page and expires", runProductionSheetScenario),
        ("Ask-first approval time does not spend the action deadline", runSlowApprovalScenario),
        ("revocation releases a handed-over user tile", runRevocationReleaseScenario),
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
    h.pump(20) { response != nil }
    try expect(h.errorCode(response ?? [:]) == "scope_approval_required", "an unanswered hand-over must be refused: \(String(describing: response))")
    h.pump(1) { h.window.attachedSheet == nil }
    try expect(h.window.attachedSheet == nil, "the hand-over sheet must close when its request expires")
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
