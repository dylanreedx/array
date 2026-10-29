import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

private struct BrowserAutomationEngineCheckError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// `--browser-automation-engine-check` (`.plans/80-browser-computer-use`, S2).
///
/// A real `WKWebViewBrowserRuntime` on an offline fixture page, in an
/// off-screen window beside an `NSTextView` that stands in for whatever the
/// user is typing in. Everything goes through `runtime.automation`, the entry
/// point S3's workspace API calls. Outcomes are read back from the page.
@MainActor
func runBrowserAutomationEngineCheck() throws {
    var outcome: Result<String, Error>?
    Task { @MainActor in
        do { outcome = .success(try await BrowserAutomationEngineCheck().run()) } catch { outcome = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(90)
    while outcome == nil, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    switch outcome {
    case .success(let summary): print("Browser automation engine check passed: \(summary)")
    case .failure(let error): throw error
    case nil: throw BrowserAutomationEngineCheckError("the check did not finish within 90 s")
    }
}

@MainActor
private final class BrowserAutomationEngineCheck {
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Counts sheets the runtime would have shown. While an agent drives the
    /// tile there must be none.
    final class CountingPresenter: BrowserUIDialogPresenting {
        var shown = 0
        func presentJavaScriptAlert(message: String, window: NSWindow?, completion: @escaping () -> Void) { shown += 1; completion() }
        func presentJavaScriptConfirm(message: String, window: NSWindow?, completion: @escaping (Bool) -> Void) { shown += 1; completion(true) }
        func presentJavaScriptPrompt(prompt: String, defaultText: String?, window: NSWindow?, completion: @escaping (String?) -> Void) { shown += 1; completion(nil) }
        func presentOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?, completion: @escaping ([URL]?) -> Void) { shown += 1; completion(nil) }
        func presentDownloadSavePanel(suggestedFilename: String, window: NSWindow?, completion: @escaping (URL?) -> Void) { shown += 1; completion(nil) }
        func presentHTTPAuthenticationPrompt(host: String, realm: String?, previousFailureCount: Int, window: NSWindow?, completion: @escaping ((username: String, password: String)?) -> Void) { shown += 1; completion(nil) }
        func presentTLSChallengePrompt(host: String, window: NSWindow?, completion: @escaping (Bool) -> Void) { shown += 1; completion(false) }
    }

    final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    static let page = """
    <!doctype html><html><head><title>Engine fixture</title>
    <style>body{margin:0;font:14px -apple-system} #red{position:absolute;left:600px;top:20px;width:100px;height:80px;background:rgb(255,0,0)}</style>
    </head><body>
    <h1>Sign up</h1>
    <form onsubmit="event.preventDefault(); window.submitted = (window.submitted || 0) + 1;">
      <label for="email">Email</label> <input id="email">
      <label for="pw">Password</label> <input id="pw" type="password">
      <label for="upload">Upload</label> <input id="upload" type="file">
      <button id="go" type="button">Create account</button>
    </form>
    <p>Already have an <b>account</b>? Sign in.</p>
    <div id="card" style="cursor:pointer;width:120px;height:30px">Open card</div>
    <button id="gone" type="button">Remove me</button>
    <button id="confirmer" type="button">Delete</button>
    <button id="thrower" type="button">Throw</button>
    <div id="late"></div>
    <button id="under" type="button" style="position:absolute;left:20px;top:420px;width:120px;height:30px">Under</button>
    <div style="position:absolute;left:10px;top:410px;width:200px;height:60px;background:rgba(0,0,0,.1)"></div>
    <div id="red"></div>
    <div style="height:2400px"></div>
    <button id="far" type="button">Far away</button>
    <script>
    window.events = [];
    const log = (name) => (e) => events.push(name + ':' + e.isTrusted);
    document.getElementById('go').addEventListener('click', (e) => { log('go')(e); document.getElementById('late').textContent = 'Account created'; });
    document.getElementById('under').addEventListener('click', log('under'));
    document.getElementById('gone').addEventListener('click', log('gone'));
    document.getElementById('far').addEventListener('click', log('far'));
    document.getElementById('card').addEventListener('click', log('card'));
    document.getElementById('confirmer').addEventListener('click', () => { window.confirmAnswer = confirm('Delete everything?'); });
    document.getElementById('thrower').addEventListener('click', () => { setTimeout(() => { throw new Error('fixture boom'); }, 0); });
    // A React-style controlled input: the page owns the value and writes it back.
    window.model = '';
    const email = document.getElementById('email');
    email.addEventListener('keydown', log('keydown'));
    email.addEventListener('input', (e) => { window.model = e.target.value; email.value = window.model; });
    // The page tampers with DOM methods the reader relies on. The isolated
    // world must not notice.
    Element.prototype.getBoundingClientRect = function() { return { left: -999, top: -999, width: 0, height: 0, right: 0, bottom: 0, x: 0, y: 0 }; };
    Document.prototype.elementFromPoint = function() { return null; };
    window.getComputedStyle = function() { return { display: 'none' }; };
    </script></body></html>
    """

    let presenter = CountingPresenter()
    let window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    let plane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let host = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let userField = NSTextView(frame: NSRect(x: 820, y: 20, width: 160, height: 100))
    let runtime: WKWebViewBrowserRuntime
    var engine: BrowserAutomation { runtime.automation }
    private var notes: [String] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        runtime = WKWebViewBrowserRuntime(tileId: TileID(), webView: webView, initialURL: "about:blank", uiDialogPresenter: presenter)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(plane)
        window.contentView?.addSubview(userField)
        plane.addSubview(host)
        runtime.attach(to: host)
        window.orderFrontOffscreenForChecks()
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw BrowserAutomationEngineCheckError(message()) }
    }

    private var soon: Date { Date().addingTimeInterval(10) }

    private func page(_ function: String) async throws -> Any? {
        let json = try await engine.evaluate(function, deadline: soon)
        return try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    private func events() async throws -> [String] {
        try await page("() => window.events") as? [String] ?? []
    }

    private func ref(_ name: String, in text: String) throws -> String {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"\(name)\"") }),
              let range = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
            throw BrowserAutomationEngineCheckError("no tag for \"\(name)\" in the outline:\n\(text)")
        }
        return String(line[range].dropFirst(5).dropLast())
    }

    private func expectError(_ expected: (BrowserAutomationError) -> Bool, _ label: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as BrowserAutomationError {
            try expect(expected(error), "\(label): wrong error: \(error)")
            return
        }
        throw BrowserAutomationEngineCheckError("\(label): expected an error, got success")
    }

    func run() async throws -> String {
        runtime.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://fixture.array.test/"))
        let loadDeadline = Date().addingTimeInterval(15)
        while runtime.webView.isLoading || runtime.webView.title != "Engine fixture" {
            try expect(Date() < loadDeadline, "the fixture page did not load")
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 1. The outline, read past the page's tampering, with passwords masked.
        let first = try await engine.snapshot(deadline: soon)
        for needle in ["heading \"Sign up\"", "[level=1]", "textbox \"Email\"", "textbox \"Password\"",
                       "button \"Create account\"", "clickable \"Open card\"", "text: Already have an account ? Sign in."] {
            try expect(first.text.contains(needle), "the outline is missing \(needle):\n\(first.text)")
        }
        try expect(first.generation == 1, "first snapshot generation was \(first.generation)")
        let go = try ref("Create account", in: first.text)
        let email = try ref("Email", in: first.text)
        let password = try ref("Password", in: first.text)

        // 2. The reader is invisible to the page.
        let footprint = try await page("() => ({ reader: typeof window.__arrayAutomation, tagged: document.querySelectorAll('[ref],[data-ref],[data-array-ref]').length })") as? [String: Any]
        try expect(footprint?["reader"] as? String == "undefined" && (footprint?["tagged"] as? Int) == 0,
                   "the page can see the reader: \(String(describing: footprint))")

        // 3. Click by tag at three canvas zooms: trusted, and the user's field keeps focus.
        var clicks = 0
        var firstChanges: [String]?
        for (label, boundsWidth) in [("1x", 800.0), ("0.5x", 1_600.0), ("2x", 400.0)] {
            plane.setBoundsSize(NSSize(width: boundsWidth, height: boundsWidth * 0.75))
            window.makeFirstResponder(userField)
            let result = try await engine.click(ref: go, deadline: soon)
            clicks += 1
            if firstChanges == nil { firstChanges = result.changes }
            let seen = try await events().filter { $0.hasPrefix("go:") }
            try expect(seen.count == clicks && seen.allSatisfy { $0 == "go:true" }, "click at \(label) did not arrive trusted: \(seen)")
            try expect(window.firstResponder === userField, "click at \(label) moved first responder to \(String(describing: window.firstResponder))")
        }
        plane.setBoundsSize(NSSize(width: 800, height: 600))
        try expect(firstChanges?.contains("+ text: Account created") == true,
                   "the first click's reply did not report the new text: \(String(describing: firstChanges))")

        // 4. Typing into a controlled input: trusted keys, the page's model
        // follows, and the user's field is first responder again afterwards.
        window.makeFirstResponder(userField)
        let typed = try await engine.type("hello@array.dev", ref: email, deadline: soon)
        let model = try await page("() => window.model") as? String
        try expect(typed.value == "hello@array.dev" && model == "hello@array.dev", "typing did not land: value=\(String(describing: typed.value)) model=\(String(describing: model))")
        try expect(try await events().contains("keydown:true"), "typed keys were not trusted")
        try expect(window.firstResponder === userField && userField.string.isEmpty, "typing disturbed the user's field: \(String(describing: window.firstResponder)) '\(userField.string)'")
        let replaced = try await engine.type("x", ref: email, clear: true, deadline: soon)
        try expect(replaced.value == "x", "clear did not replace the field: \(String(describing: replaced.value))")
        _ = try await engine.pressKey("Backspace", deadline: soon)
        try expect(try await page("() => window.model") as? String == "", "Backspace did not reach the field")

        // 5. Passwords never come back.
        let secret = try await engine.type("hunter2", ref: password, deadline: soon)
        let masked = try await engine.snapshot(deadline: soon)
        try expect(secret.value == "••••••" && !masked.text.contains("hunter2") && masked.text.contains("value=\"••••••\""),
                   "a password leaked: value=\(String(describing: secret.value))\n\(masked.text)")

        // 6. The user typing in the tile holds a type back. The key goes the
        // real way, through NSApp.sendEvent, where the user's keys go.
        window.makeFirstResponder(runtime.webView)
        let userKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                       isARepeat: false, keyCode: 6)!
        let inputsBefore = engine.userInputCount
        NSApp.sendEvent(userKey)
        try expect(engine.userInputCount == inputsBefore + 1, "the user's key in the tile was not noticed")
        try await expectError({ $0 == .userTyping }, "a type right after the user's key") {
            _ = try await self.engine.type("y", ref: email, deadline: Date().addingTimeInterval(0.3))
        }
        let heldFrom = Date()
        _ = try await engine.type("y", ref: email, deadline: soon)
        let held = Date().timeIntervalSince(heldFrom)
        try expect(held >= 0.6, "a type after the user's key ran after \(held) s instead of waiting")
        let agentInputs = engine.userInputCount
        window.makeFirstResponder(userField)

        // 7. Refusals that click nothing.
        let fresh = try await engine.snapshot(deadline: soon)
        let under = try ref("Under", in: fresh.text)
        let gone = try ref("Remove me", in: fresh.text)
        try await expectError({ if case .covered = $0 { return true }; return false }, "a covered button") {
            _ = try await self.engine.click(ref: under, deadline: self.soon)
        }
        _ = try await page("() => { document.getElementById('gone').remove(); return 1; }")
        try await expectError({ $0 == .staleRef(gone) }, "a removed button") {
            _ = try await self.engine.click(ref: gone, deadline: self.soon)
        }
        let afterRefusals = try await events()
        try expect(!afterRefusals.contains { $0.hasPrefix("under:") || $0.hasPrefix("gone:") }, "a refused click still clicked: \(afterRefusals)")
        try expect(engine.userInputCount == agentInputs, "the agent's own input counted as the user's")

        // 8. A clickable div, and a button below the fold scrolled into view.
        _ = try await engine.click(ref: try ref("Open card", in: fresh.text), deadline: soon)
        _ = try await engine.click(ref: try ref("Far away", in: fresh.text), deadline: soon)
        let reached = try await events()
        try expect(reached.contains("card:true") && reached.contains("far:true"), "the card or the far button was not clicked: \(reached)")

        // 9. Dialogs go to the agent while it drives, never to a sheet.
        engine.isEngaged = true
        let dialog = try await engine.click(ref: try ref("Delete", in: fresh.text), deadline: soon)
        engine.isEngaged = false
        try expect(dialog.dialogs == ["confirm \"Delete everything?\": cancelled"] && presenter.shown == 0,
                   "the confirm was not answered for the agent: \(dialog.dialogs), sheets=\(presenter.shown)")
        try expect(try await page("() => window.confirmAnswer") as? Bool == false, "the page did not see the confirm cancelled")
        let uploadSnapshot = try await engine.snapshot(deadline: soon)
        let upload = try ref("Upload", in: uploadSnapshot.text)
        engine.isEngaged = true
        let chooser = try await engine.click(ref: upload, deadline: soon)
        engine.isEngaged = false
        try expect(presenter.shown == 0 && chooser.dialogs.contains(where: { $0.contains("file chooser") && $0.contains("refused") }),
                   "file upload must be refused without an Open panel: \(chooser.dialogs)")
        let protection = URLProtectionSpace(host: "fixture.example", port: 80, protocol: "http", realm: "private", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: ChallengeSender())
        var authDisposition: URLSession.AuthChallengeDisposition?
        engine.isEngaged = true
        runtime.handleAuthenticationChallenge(challenge) { disposition, _ in authDisposition = disposition }
        engine.isEngaged = false
        try expect(presenter.shown == 0 && authDisposition == .cancelAuthenticationChallenge,
                   "HTTP authentication during agent control must cancel without an unattended prompt")

        // 10. A page error thrown after a click comes back with that click.
        let thrown = try await engine.click(ref: try ref("Throw", in: fresh.text), deadline: soon)
        try expect(thrown.consoleErrors.contains { $0.contains("fixture boom") }, "the page error was not reported: \(thrown.consoleErrors)")

        // 11. Waits run on a wall clock and time out with a reason.
        _ = try await page("() => { setTimeout(() => { document.getElementById('late').textContent = 'Ready later'; }, 400); return 1; }")
        let waited = try await engine.waitFor(.textAppears("Ready later"), timeout: 5, deadline: soon)
        try expect(waited.summary.hasPrefix("Waited"), "wait summary: \(waited.summary)")
        try await expectError({ if case .timedOut = $0 { return true }; return false }, "a wait for text that never comes") {
            _ = try await self.engine.waitFor(.textAppears("never shown"), timeout: 0.5, deadline: self.soon)
        }

        // 12. Screenshots: the red block is red, on screen, hidden and off-window.
        _ = try await engine.scroll(dx: 0, dy: -100_000, deadline: soon)
        for state in ["shown", "hidden", "off-window"] {
            if state == "hidden" { plane.isHidden = true }
            if state == "off-window" { plane.isHidden = false; host.removeFromSuperview() }
            let shot = try await engine.screenshot(deadline: soon)
            try expect(shot.pixelWidth <= BrowserAutomation.screenshotMaxPixelWidth, "screenshot is \(shot.pixelWidth) px wide")
            let colour = try Self.pixel(shot, cssX: 650, cssY: 60, cssWidth: 800)
            try expect(colour.red > 200 && colour.green < 60 && colour.blue < 60, "screenshot \(state): the red block reads \(colour)")
            notes.append("\(state) \(shot.pixelWidth)x\(shot.pixelHeight)")
        }
        plane.addSubview(host)

        // 13. A click right after the tile comes back from a hidden parent.
        plane.isHidden = true
        _ = try await engine.snapshot(deadline: soon)
        plane.isHidden = false
        window.makeFirstResponder(userField)
        _ = try await engine.click(ref: go, deadline: soon)
        try expect(try await events().filter { $0.hasPrefix("go:") }.count == clicks + 1, "a click after unhiding did not arrive")

        // 14. The snapshot cap cuts console first, then page text, then the outline's tail.
        let many = (0..<1_500).map { BrowserAutomation.OutlineLine(depth: $0 % 3, isText: $0 % 2 == 0, text: "line \($0) " + String(repeating: "x", count: 20)) }
        let capped = BrowserAutomation.compose(url: "https://x.test/", title: "Big", generation: 9, lines: many, elementCapHit: false,
                                               console: (0..<50).map { "error \($0)" }, dialogs: [])
        try expect(capped.text.utf8.count <= BrowserAutomation.snapshotByteCap, "a capped snapshot is \(capped.text.utf8.count) bytes")
        try expect(capped.cut.count == 3 && capped.cut[0].contains("console") && capped.cut[1].contains("page text") && capped.cut[2].contains("outline"),
                   "the cap cut in the wrong order: \(capped.cut)")
        let small = BrowserAutomation.compose(url: "https://x.test/", title: "Small", generation: 1, lines: Array(many.prefix(20)), elementCapHit: false,
                                              console: ["error 1"], dialogs: [])
        try expect(small.cut.isEmpty && small.text.contains("error 1"), "a small snapshot was cut: \(small.cut)")

        // The host action adapter must return the actual page's result, not a
        // synthesized outcome. Browser API dispatch and grants are tested separately.
        let toolSnapshot = await BrowserActionExecutor.perform(.snapshot(tile: runtime.tileId, key: nil), runtime: runtime, deadline: soon)
        guard case let .result(snapshotFields) = toolSnapshot,
              snapshotFields["text"]?.string?.contains("Sign up") == true else {
            throw BrowserAutomationEngineCheckError("browser action adapter did not return the real outline")
        }
        let toolEval = await BrowserActionExecutor.perform(.evaluate(tile: runtime.tileId, script: "() => ({ title: document.title })", key: nil), runtime: runtime, deadline: soon)
        guard case let .result(evalFields) = toolEval,
              evalFields["value"]?.object?["title"]?.string == "Engine fixture" else {
            throw BrowserAutomationEngineCheckError("browser action adapter did not return page evaluation")
        }
        let previousConsoleSequence = runtime.consoleEntrySequence
        _ = try await page("() => { console.error('adapter-' + 'x'.repeat(800)); return true; }")
        let consoleDeadline = Date().addingTimeInterval(2)
        while runtime.consoleEntrySequence == previousConsoleSequence && Date() < consoleDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let toolConsole = await BrowserActionExecutor.perform(.console(tile: runtime.tileId, level: "error", key: nil), runtime: runtime, deadline: soon)
        guard case let .result(consoleFields) = toolConsole, consoleFields["pageSupplied"]?.bool == true,
              consoleFields["truncated"]?.bool == true,
              consoleFields["entries"]?.array?.contains(where: { $0.object?["message"]?.string?.hasPrefix("adapter-") == true }) == true else {
            throw BrowserAutomationEngineCheckError("browser console adapter must label and bound page-supplied messages")
        }
        let toolShot = await BrowserActionExecutor.perform(.screenshot(tile: runtime.tileId, ref: nil, key: nil), runtime: runtime, deadline: soon)
        guard case let .result(shotFields) = toolShot,
              shotFields["image"]?.object?["mimeType"]?.string == "image/png",
              let bytes = shotFields["image"]?.object?["data"]?.string,
              Data(base64Encoded: bytes)?.starts(with: [137, 80, 78, 71]) == true else {
            throw BrowserAutomationEngineCheckError("browser action adapter must return a real PNG")
        }
        let wrongTile = await BrowserActionExecutor.perform(.click(tile: UUID(), target: .ref(go), key: nil), runtime: runtime, deadline: soon)
        guard case .error = wrongTile else { throw BrowserAutomationEngineCheckError("adapter must reject the wrong runtime") }
        let toolClick = await BrowserActionExecutor.perform(.click(tile: runtime.tileId, target: .ref(go), key: nil), runtime: runtime, deadline: soon)
        guard case .result = toolClick,
              try await events().filter({ $0.hasPrefix("go:") }).count == clicks + 2 else {
            throw BrowserAutomationEngineCheckError("browser adapter click did not reach the page")
        }
        let toolType = await BrowserActionExecutor.perform(.type(tile: runtime.tileId, text: "adapter", ref: email, clear: true, submit: false, key: nil), runtime: runtime, deadline: soon)
        guard case .result = toolType, try await page("() => window.model") as? String == "adapter" else {
            throw BrowserAutomationEngineCheckError("browser adapter typing did not reach the page")
        }
        // The user can take over while WebKit is still resolving a target or
        // while a long type is in flight. No later agent key may be delivered.
        window.makeFirstResponder(userField)
        let takeoverKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.window.makeFirstResponder(self.runtime.webView)
            NSApp.sendEvent(takeoverKey)
        }
        try await expectError({ $0 == .userTyping }, "an in-flight type after user takeover") {
            _ = try await self.engine.type(String(repeating: "a", count: 100), ref: email, clear: true, deadline: self.soon)
        }
        let afterUserTakeover = try await page("() => window.model") as? String ?? ""
        try expect(afterUserTakeover.filter({ $0 == "a" }).count < 100 && window.firstResponder === runtime.webView,
                   "agent typing continued or moved the user's focus after takeover")
        var checkedNavigation = false
        var decisionReturned = false
        let urlBeforeDenial = runtime.url
        var publishedURLs: [String] = []
        let priorStateChange = runtime.onStateChange
        runtime.onStateChange = { publishedURLs.append(self.runtime.url) }
        runtime.agentNavigationDecision = { _, complete in
            checkedNavigation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { complete(false); decisionReturned = true }
        }
        runtime.loadURL("about:blank")
        let navigationDeadline = Date().addingTimeInterval(2)
        while !checkedNavigation && Date() < navigationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(checkedNavigation && !decisionReturned && runtime.webView.title == "Engine fixture",
                   "agent navigation must wait for the host decision")
        while !decisionReturned && Date() < navigationDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(decisionReturned && runtime.webView.title == "Engine fixture", "agent navigation must obey denial")
        try expect(runtime.url == urlBeforeDenial && !publishedURLs.contains("about:blank"),
                   "a denied destination must never be published or persisted as the browser URL")
        var pendingDecision: (@MainActor (Bool) -> Void)?
        runtime.agentNavigationDecision = { _, complete in pendingDecision = complete }
        runtime.loadURL("about:blank")
        let pendingDeadline = Date().addingTimeInterval(2)
        while pendingDecision == nil && Date() < pendingDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(pendingDecision != nil, "the next navigation must reach the decision gate")
        runtime.agentNavigationDecision = { _, complete in complete(false) }
        pendingDecision?(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(runtime.url == urlBeforeDenial && runtime.webView.title == "Engine fixture",
                   "an approval from a replaced gate must not authorize navigation")
        runtime.agentNavigationDecision = { _, complete in complete(true) }
        runtime.loadURL("about:blank")
        let allowedDeadline = Date().addingTimeInterval(2)
        while runtime.url != "about:blank" && Date() < allowedDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(runtime.url == "about:blank" && publishedURLs.contains("about:blank"),
                   "an allowed committed navigation must publish its URL")
        try await checkRedirectGate()
        runtime.onStateChange = priorStateChange
        runtime.agentNavigationDecision = nil

        window.orderOut(nil)
        runtime.terminate(policy: .force)
        return "outline read past page tampering with passwords masked; trusted clicks at 1x, 0.5x and 2x with the user's field kept first responder; controlled input typed; the user's key held a type \(String(format: "%.2f", held)) s; covered and stale refused; dialog answered for the agent; page error reported; screenshots \(notes.joined(separator: ", "))"
    }

    private func checkRedirectGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-browser-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let logFile = directory.appendingPathComponent("requests")
        let source = """
        import http.server, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(sys.argv[2], 'a') as log: log.write(self.path + '\\n')
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/blocked')
                    self.end_headers()
                elif self.path == '/download':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename="fixture.txt"')
                    self.end_headers()
                    self.wfile.write(b'private browser download')
                elif self.path == '/iframe':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html')
                    self.end_headers()
                    self.wfile.write(b'<iframe src="/child"></iframe>')
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'blocked destination')
            def log_message(self, *args): pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        with open(sys.argv[1], 'w') as port: port.write(str(server.server_port))
        server.serve_forever()
        """
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", source, portFile.path, logFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let startupDeadline = Date().addingTimeInterval(5)
        var port: Int?
        while port == nil && Date() < startupDeadline {
            port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(Int.init)
            if port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard let port else { throw BrowserAutomationEngineCheckError("redirect fixture server failed to start") }
        var seen: [String] = []
        runtime.agentNavigationDecision = { url, complete in
            seen.append(url.path)
            complete(url.path == "/redirect")
        }
        runtime.loadURL("http://127.0.0.1:\(port)/redirect")
        let redirectDeadline = Date().addingTimeInterval(5)
        while !seen.contains("/blocked") && Date() < redirectDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let requests = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        try expect(seen.contains("/redirect") && seen.contains("/blocked") && requests.contains("/redirect")
                   && !requests.contains("/blocked") && runtime.url == "about:blank",
                   "a redirected destination must be checked and denied before its request or URL is published: seen=\(seen), requests=\(requests)")
        seen.removeAll()
        runtime.agentNavigationDecision = { url, complete in
            seen.append(url.path)
            complete(url.path == "/iframe")
        }
        runtime.loadURL("http://127.0.0.1:\(port)/iframe")
        let frameDeadline = Date().addingTimeInterval(3)
        var frameRequests = ""
        while Date() < frameDeadline {
            frameRequests = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            if frameRequests.contains("/child") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(frameRequests.contains("/child") && !seen.contains("/child"),
                   "child frames must load without a top-level navigation approval: seen=\(seen), requests=\(frameRequests)")
        let redirectRoot = directory.appendingPathComponent("redirected-downloads", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: redirectRoot, withDestinationURL: outside)
        try expect(BrowserArtifactStore.downloadDestination(root: redirectRoot, tileId: runtime.tileId, suggestedFilename: "bad") == nil,
                   "a symlink must not redirect agent downloads")
        let downloadRoot = directory.appendingPathComponent("downloads", isDirectory: true)
        var destination: URL?
        runtime.agentDownloadDestination = { filename in
            destination = BrowserArtifactStore.downloadDestination(root: downloadRoot, tileId: self.runtime.tileId, suggestedFilename: filename)
            return destination
        }
        let sheetsBeforeDownload = presenter.shown
        engine.isEngaged = true
        runtime.agentNavigationDecision = { _, complete in complete(true) }
        runtime.loadURL("http://127.0.0.1:\(port)/download")
        let downloadDeadline = Date().addingTimeInterval(3)
        while Date() < downloadDeadline {
            if let destination, (try? Data(contentsOf: destination)) == Data("private browser download".utf8) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        engine.isEngaged = false
        let mode = destination.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber }
        try expect(presenter.shown == sheetsBeforeDownload && destination != nil && mode?.intValue == 0o700 &&
                   destination.flatMap { try? Data(contentsOf: $0) } == Data("private browser download".utf8),
                   "an agent download must reach a private tile directory without a Save panel")
    }

    private static func pixel(_ shot: BrowserAutomationScreenshot, cssX: Double, cssY: Double, cssWidth: Double) throws -> (red: Int, green: Int, blue: Int) {
        guard let rep = NSBitmapImageRep(data: shot.png) else { throw BrowserAutomationEngineCheckError("the screenshot is not a PNG") }
        let scale = Double(rep.pixelsWide) / cssWidth
        guard let colour = rep.colorAt(x: Int(cssX * scale), y: Int(cssY * scale))?.usingColorSpace(.sRGB) else {
            throw BrowserAutomationEngineCheckError("no pixel at \(cssX),\(cssY)")
        }
        return (Int(colour.redComponent * 255), Int(colour.greenComponent * 255), Int(colour.blueComponent * 255))
    }
}
