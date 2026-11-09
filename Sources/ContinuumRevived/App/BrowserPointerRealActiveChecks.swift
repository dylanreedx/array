import AppKit
import Darwin
import ContinuumRevivedCore

/// An explicitly approved experiment, absent from the unattended matrix.
/// Candidate isolation is never enabled by a normal launch.
@MainActor
func runBrowserPointerRealActiveCheck() throws {
    guard ProcessInfo.processInfo.environment["ARRAY_ALLOW_REAL_KEY_PROOF"] == "1" else {
        throw WorkspaceAPIChecks.Failure(message: "REFUSED: active pointer proof requires Dylan approval and ARRAY_ALLOW_REAL_KEY_PROOF=1; no activation occurred")
    }
    guard let rawPID = ProcessInfo.processInfo.environment["ARRAY_REAL_KEY_PREVIOUS_PID"],
          let pid = Int32(rawPID), let previous = NSRunningApplication(processIdentifier: pid),
          pid != ProcessInfo.processInfo.processIdentifier else {
        throw WorkspaceAPIChecks.Failure(message: "active pointer proof needs the previous frontmost PID captured before LaunchServices open")
    }
    if let path = ProcessInfo.processInfo.environment["ARRAY_REAL_KEY_LOG_PATH"] {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else { throw WorkspaceAPIChecks.Failure(message: "cannot open pointer proof log") }
        let redirected = dup2(fd, STDOUT_FILENO) >= 0 && dup2(fd, STDERR_FILENO) >= 0
        if fd > STDERR_FILENO { close(fd) }
        guard redirected else { throw WorkspaceAPIChecks.Failure(message: "cannot redirect pointer proof log") }
    }
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    let alarmHandler = signal(SIGALRM) { _ in Darwin._exit(1) }
    alarm(29)
    defer { alarm(0); _ = signal(SIGALRM, alarmHandler) }
    let progress = BrowserRealKeyProofProgress()
    let names = ["unowned tile hover red/green", "css menu", "mouseleave menu", "click atomicity", "deliberate takeover"]
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    watchdog.schedule(deadline: .now() + 26)
    watchdog.setEventHandler {
        for name in names where !progress.contains(name) { fputs("FAIL: \(name): hard timeout\n", stderr) }
        fputs("FAIL: pointer proof timed out at 26s; restoring previous app and exiting\n", stderr)
        DispatchQueue.main.async {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previous) }
            _ = previous.activate(options: [.activateIgnoringOtherApps])
        }
        _ = previous.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.5)
        fputs(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            ? "PASS: watchdog confirmed previous frontmost PID\n"
            : "FAIL: watchdog could not confirm restoration before exit\n", stderr)
        Darwin._exit(1)
    }
    watchdog.resume()
    defer { watchdog.cancel() }
    let originalBackend = BrowserAutomation.focusFreeInputEnabled
    defer {
        BrowserAutomation.focusFreeInputEnabled = originalBackend
        BrowserAutomation._pointerFilterForChecks = false
    }
    let start = Date()
    let end = start.addingTimeInterval(23)
    var failures: [String] = []
    _ = NSApp.setActivationPolicy(.regular)
    NSApp.finishLaunching()
    do {
        BrowserAutomation.focusFreeInputEnabled = true
        let h = try BrowserHardeningHarness(realKey: true)
        defer { h.tearDown() }
        h.window.setContentSize(NSSize(width: 6000, height: 4000))
        h.f.canvas.frame = NSRect(x: 0, y: 0, width: 6000, height: 4000)
        h.window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)
        h.window.makeKey()
        h.pump(1) { NSApp.isActive && h.window.isKeyWindow && NSApp.keyWindow === h.window }
        guard NSApp.isActive, h.window.isKeyWindow, NSApp.keyWindow === h.window,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              !NSScreen.screens.contains(where: { $0.frame.intersects(h.window.frame) }) else {
            throw WorkspaceAPIChecks.Failure(message: "real active/key setup failed")
        }
        print("PASS: real active app and native key window; previous PID=\(pid)")
        @MainActor func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw WorkspaceAPIChecks.Failure(message: message) }
        }
        @MainActor func call(_ op: String, _ payload: [String: Any]) throws -> [String: Any] {
            try require(Date() < end, "23-second case budget exhausted")
            return try h.ok(op, payload, timeout: max(0.1, min(2, end.timeIntervalSinceNow)))
        }
        let opened = try call("browser.open", ["url": "about:blank"])
        guard let tile = opened["tileId"] as? String, let tileID = UUID(uuidString: tile),
              let browser = h.live(tileID) else { throw WorkspaceAPIChecks.Failure(message: "missing driven browser") }
        try require(browser.automation.supportsFocusFreeInput, "focus-free suppression capability unavailable")
        let user = try h.userBrowser()
        user.webView.loadHTMLString("<style>button:hover{background:red}</style><button id=user>User target</button><script>window.moves=0;window.picks=0;document.addEventListener('mousemove',e=>{if(e.isTrusted)moves++});document.querySelector('button').onclick=e=>{if(e.isTrusted)picks++}</script>", baseURL: nil)
        h.pump(1) { !user.webView.isLoading }
        h.window.contentView?.layoutSubtreeIfNeeded()
        try require(!user.automation.isEngaged, "user browser must have no agent owner")
        @MainActor func read(_ runtime: WKWebViewBrowserRuntime, _ script: String) throws -> [String: Any] {
            try require(Date() < end, "23-second read budget exhausted")
            var result: [String: Any]?
            var failure: Error?
            var answered = false
            runtime.webView.evaluateJavaScript(script) { value, error in
                result = value as? [String: Any]; failure = error; answered = true
            }
            h.pump(min(0.6, max(0, end.timeIntervalSinceNow))) { answered }
            guard answered, failure == nil, let result else {
                throw WorkspaceAPIChecks.Failure(message: "page read failed: \(String(describing: failure))")
            }
            return result
        }
        @MainActor func eval(_ script: String) throws {
            _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { \(script); return true }"])
        }
        @MainActor func point(_ runtime: WKWebViewBrowserRuntime, _ x: Double, _ y: Double) -> NSPoint {
            let view = runtime.webView
            return view.convert(NSPoint(x: x * view.pageZoom,
                y: view.isFlipped ? y * view.pageZoom : view.bounds.height - y * view.pageZoom), to: nil)
        }
        @MainActor func mouse(_ type: NSEvent.EventType, _ runtime: WKWebViewBrowserRuntime, _ x: Double, _ y: Double) {
            let event = NSEvent.mouseEvent(with: type, location: point(runtime, x, y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
        @MainActor func click(_ x: Double, _ y: Double) throws {
            _ = try call("browser.click", ["tileId": tile, "x": x, "y": y])
        }
        @MainActor func scenario(_ name: String, _ body: @MainActor () throws -> Void) {
            do { try body() } catch { failures.append("\(name): \(error)"); print("FAIL: \(name): \(error)") }
            progress.insert(name)
            BrowserAutomation._pointerFilterForChecks = false
        }
        // A real tracking tag routes the synthetic exit to WKWebView. No
        // pointer is moved and no system event is posted.
        let exitTag = browser.webView.addTrackingRect(browser.webView.bounds, owner: browser.webView, userData: nil, assumeInside: false)
        defer { browser.webView.removeTrackingRect(exitTag) }
        @MainActor func exitDrivenView() {
            let event = NSEvent.enterExitEvent(with: .mouseExited, location: point(browser, 450, 200), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: exitTag, userData: nil)!
            NSApp.sendEvent(event)
        }
        // Fail the stimulus prerequisite instead of calling an undeliverable
        // red control KILLED. This was the inactive harness's false confidence.
        var pointerStimulated = false
        scenario("unowned tile hover red/green") {
            for enabled in [false, true] {
                BrowserAutomation._pointerFilterForChecks = enabled
                let before = try read(user, "({moves:window.moves})")["moves"] as? Int ?? -1
                mouse(.mouseMoved, user, 400, 200)
                mouse(.mouseMoved, user, 30, 15)
                h.pump(0.06)
                let after = try read(user, "({moves:window.moves,hover:document.querySelector('button').matches(':hover')})")
                try require((after["moves"] as? Int ?? -1) > before && after["hover"] as? Bool == true,
                    "synthetic move failed to stimulate trusted pointer/hover in unowned active WebKit: \(after)")
                print("PASS: unowned tile hover filter=\(enabled) \(after)")
            }
            pointerStimulated = true
        }
        for kind in ["css", "mouseleave"] {
            scenario("\(kind) menu") {
                try require(pointerStimulated, "pointer stimulus prerequisite failed; cannot classify hover theft")
                @MainActor func attempt(_ filter: Bool) throws -> Bool {
                    BrowserAutomation._pointerFilterForChecks = filter
                    try eval("""
                        document.body.innerHTML = '<style>body{margin:0}#menu{position:absolute;left:10px;top:10px;width:150px}button{width:140px;height:35px}#item{display:none}#menu:hover #item,#menu.open #item{display:block}</style><div id=menu><button id=opener>Open</button><button id=item>Choose</button></div>';
                        window.picked=0;window.moves=0;window.exits=0;
                        const menu=document.getElementById('menu');
                        document.getElementById('opener').onclick=()=>{if('\(kind)'==='mouseleave')menu.classList.add('open')};
                        menu.addEventListener('mouseleave',()=>{window.exits++;menu.classList.remove('open')});
                        document.addEventListener('mousemove',e=>{if(e.isTrusted)window.moves++},{once:true});
                        document.getElementById('item').onclick=e=>{if(e.isTrusted)window.picked++}
                        """)
                    try click(40, 25)
                    let initial = try read(browser, "({shown:document.getElementById('item').getBoundingClientRect().height>0,moves:window.moves,exits:window.exits})")
                    try require(initial["shown"] as? Bool == true, "agent click did not establish \(kind) menu; no valid red control")
                    let parent = browser.webView.superview
                    let generation = browser.automation.userInputCount
                    mouse(.mouseMoved, browser, 450, 200)
                    exitDrivenView()
                    h.pump(0.06)
                    let stimulated = try read(browser, "({moves:window.moves,exits:window.exits})")
                    if !filter {
                        try require((stimulated["moves"] as? Int ?? 0) > (initial["moves"] as? Int ?? 0) ||
                            (stimulated["exits"] as? Int ?? 0) > (initial["exits"] as? Int ?? 0),
                            "driven tile did not receive the red-control pointer stimulus: \(stimulated)")
                    }
                    try click(40, 60)
                    let state = try read(browser, "({picked:window.picked,moves:window.moves,exits:window.exits})")
                    print("INFO: \(kind) filter=\(filter) \(state)")
                    try require(h.live(tileID) === browser && browser.webView.superview === parent && browser.automation.userInputCount == generation,
                        "passive input changed runtime/parent/control")
                    return state["picked"] as? Int == 1
                }
                if try attempt(false) { print("KILLED: \(kind) menu survived effective user pointer input; candidate not enabled for this case") }
                else {
                    print("PASS: RED \(kind) menu lost agent's next click")
                    try require(try attempt(true), "candidate filter did not preserve \(kind) menu click")
                    print("PASS: GREEN \(kind) menu preserved the agent click")
                }
            }
        }
        scenario("click atomicity") {
            print("KILLED: approved active run observed one clean agent click and one intended user click; atomic candidate removed")
        }
        scenario("deliberate takeover") {
            BrowserAutomation._pointerFilterForChecks = true
            defer { browser.automation._duringAgentClickForChecks = nil }
            for enabled in [false, true] {
            BrowserAutomation._pointerFilterForChecks = enabled
            for key in [false, true] {
                try eval("document.body.innerHTML='<input style=\"width:200px;height:40px\" id=field>'; window.takeKeys=0; document.addEventListener('keydown',e=>{if(e.isTrusted)window.takeKeys++},{once:true})")
                let before = browser.automation.userInputCount
                var immediate = false
                browser.automation._duringAgentClickForChecks = {
                    if key { h.userKey(into: browser) }
                    else {
                        mouse(.leftMouseDown, browser, 35, 20)
                        mouse(.leftMouseUp, browser, 35, 20)
                    }
                    immediate = browser.automation.userInputCount > before
                }
                let answer = try h.raw("browser.click", ["tileId":tile,"x":35,"y":20], timeout: min(2, max(0.1,end.timeIntervalSinceNow)))
                browser.automation._duringAgentClickForChecks = nil
                try require(immediate && answer["status"] as? String == "error", "tile-local user \(key ? "key" : "click") did not take over immediately")
                let paused = try h.raw("browser.evaluate", ["tileId":tile,"script":"() => 1"], timeout: 0.5)
                try require(h.errorCode(paused) == "target_conflict", "takeover did not remain durable")
                if key {
                    let state = try read(browser, "({keys:window.takeKeys})")
                    try require(state["keys"] as? Int == 1, "deliberate key did not reach the driven page exactly once")
                }
                print("PASS: \(key ? "key" : "click") takes over immediately during native click and stays fenced; candidates=\(enabled)")
                guard let surface = h.f.canvas.tileView(for: tileID) as? BrowserTileNSView else { throw WorkspaceAPIChecks.Failure(message: "missing handback surface") }
                surface.qaChooseAgentControl("return")
                _ = try call("browser.snapshot", ["tileId":tile])
            }
            }
        }
    } catch { failures.append("setup: \(error)"); print("FAIL: setup: \(error)") }
    for name in names where !progress.contains(name) { print("FAIL: \(name): setup prevented execution") }
    BrowserAutomation._pointerFilterForChecks = false
    // Cooperatively yield the foreground, rather than only asking a background
    // process to take it. Confirm the PID, not the request's Bool.
    if #available(macOS 14.0, *) {
        NSApp.yieldActivation(to: previous)
        let requested = previous.activate(from: .current, options: [.activateAllWindows])
        print("INFO: restoration yield + activate(from:) requested=\(requested)")
    } else { _ = previous.activate(options: [.activateIgnoringOtherApps]) }
    let restoreEnd = Date().addingTimeInterval(1)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < restoreEnd {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
        print("PASS: previous frontmost PID \(pid) restored before exit; elapsed=\(Date().timeIntervalSince(start))s")
    } else { failures.append("previous frontmost PID did not restore before exit"); print("FAIL: foreground restoration") }
    if !failures.isEmpty { throw WorkspaceAPIChecks.Failure(message: failures.joined(separator: "; ")) }
    print("PASS: active pointer proof complete")
}
