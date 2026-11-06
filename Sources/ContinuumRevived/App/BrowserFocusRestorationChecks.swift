import AppKit
import ContinuumRevivedCore
import ObjectiveC
import Darwin

@MainActor
class BrowserFocusCheckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var responderTrace: ((NSResponder?) -> Void)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let before = firstResponder
        let accepted = super.makeFirstResponder(responder)
        if accepted && firstResponder !== before { responderTrace?(firstResponder) }
        return accepted
    }
}

@MainActor
final class BrowserFakedKeyCheckWindow: BrowserFocusCheckWindow {
    override var isKeyWindow: Bool { true }
}

private final class BrowserRealKeyProofProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var passed: Set<String> = []
    func insert(_ name: String) { lock.lock(); defer { lock.unlock() }; passed.insert(name) }
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return passed.contains(name) }
    func removeAll() { lock.lock(); defer { lock.unlock() }; passed.removeAll() }
}
@MainActor private var tierBPassedCases = BrowserRealKeyProofProgress()

/// Written to stdout/stderr (optionally redirected before any setup).
@MainActor
private func tierBSetupLog(_ step: String, window: NSWindow? = nil, since: Date) {
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
        tierBPassedCases.insert("tookForeground")
    }
    func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(type(of: window))#\(window.windowNumber)"
    }
    print("SETUP: \(step) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(since)))s isActive=\(NSApp.isActive) activationPolicy=\(NSApp.activationPolicy().rawValue) frontmost=\(front?.localizedName ?? "nil") pid=\(front?.processIdentifier ?? -1) selfPid=\(ProcessInfo.processInfo.processIdentifier) window=\(describe(window)) isKeyWindow=\(window?.isKeyWindow.description ?? "nil") keyWindow=\(describe(NSApp.keyWindow)) canBecomeKey=\(window?.canBecomeKey.description ?? "nil")")
}

@MainActor
func runBrowserFocusRestorationCheck(experimental: Bool = false, realKey: Bool = false) throws {
    let priorSwitch = BrowserAutomation.focusFreeInputEnabled
    BrowserAutomation.focusFreeInputEnabled = experimental && (realKey || ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] != "1")
    defer { BrowserAutomation.focusFreeInputEnabled = priorSwitch }
    guard let method = class_getInstanceMethod(ComposerTextView.self, #selector(NSView.acceptsFirstMouse(for:))) else {
        throw WorkspaceAPIChecks.Failure(message: "missing acceptsFirstMouse")
    }
    let original = method_getImplementation(method)
    let accept: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
    if !realKey { method_setImplementation(method, imp_implementationWithBlock(accept)) }
    defer { if !realKey { method_setImplementation(method, original) } }
    let setupStart = Date()
    if realKey { tierBSetupLog("before fixture", since: setupStart) }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    f.delegate.qaAgentSupervisor.workspaceToolsPermission = { .free }
    let window: BrowserFocusCheckWindow = realKey ? BrowserFocusCheckWindow(contentRect: f.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false) : BrowserFakedKeyCheckWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: f.canvas.frame)
    root.addSubview(f.canvas)
    window.contentView = root
    window.orderFrontOffscreenForChecks()
    defer { window.orderOut(nil) }
    if realKey {
        tierBSetupLog("offscreen window ordered; before activate", window: window, since: setupStart)
        NSApp.activate(ignoringOtherApps: true)
        tierBSetupLog("activate requested", window: window, since: setupStart)
        let activationStart = Date()
        let end = activationStart.addingTimeInterval(1)
        while !NSApp.isActive && Date() < end {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            tierBSetupLog("waiting for activation", window: window, since: setupStart)
        }
        tierBSetupLog("activation wait ended (waited \(Date().timeIntervalSince(activationStart))s)", window: window, since: setupStart)
        window.makeKey()
        tierBSetupLog("makeKey requested", window: window, since: setupStart)
        let keyStart = Date()
        let keyEnd = keyStart.addingTimeInterval(1)
        while (!window.isKeyWindow || NSApp.keyWindow !== window) && Date() < keyEnd {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            tierBSetupLog("waiting for native key window", window: window, since: setupStart)
        }
        tierBSetupLog("key wait ended (waited \(Date().timeIntervalSince(keyStart))s)", window: window, since: setupStart)
        guard NSApp.isActive, window.isKeyWindow, NSApp.keyWindow === window else {
            throw WorkspaceAPIChecks.Failure(message: "Tier B real key-window setup failed; see SETUP diagnostics")
        }
    }
    func call(_ op: String, _ payload: [String: Any], allowError: Bool = false) throws -> [String: Any] {
        var response: [String: Any]?
        f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
            "op": op, "payload": payload]) { response = $0 }
        let limit = Date().addingTimeInterval(20)
        while response == nil && Date() < limit { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if allowError, response?["status"] as? String == "error", let response { return response }
        if !experimental, op == "browser.type", response?["status"] as? String == "error",
           let error = response?["error"] as? [String: Any], error["code"] as? String == "outcome_unknown",
           (error["message"] as? String)?.contains("Keyboard focus moved") == true {
            guard let action = (error["details"] as? [String: Any])?["action"] as? [String: Any],
                  !(action["actionId"] as? String ?? "").isEmpty,
                  !(action["retrySessionId"] as? String ?? "").isEmpty,
                  action["freshSnapshotRequired"] as? Bool == true,
                  action["retry"] as? String == "observe_before_new_action" else {
                throw WorkspaceAPIChecks.Failure(message: "focus loss must use the shared action contract: \(error)")
            }
            if op == "browser.type" {
                guard action["effects"] as? String == "partial", action["state"] as? String == "partial",
                      action["deliveredCharacters"] as? Int == 5 else {
                    throw WorkspaceAPIChecks.Failure(message: "typing focus loss must report its prefix: \(action)")
                }
                print("Typing interrupted: state=partial effects=partial deliveredCharacters=5 retry=observe_before_new_action freshSnapshotRequired=true")
            }
            return [:]
        }
        guard response?["status"] as? String == "ok", let result = response?["result"] as? [String: Any] else {
            throw WorkspaceAPIChecks.Failure(message: "\(op): \(String(describing: response))")
        }
        return result
    }
    let opened = try call("browser.open", ["url": "about:blank"])
    let tile = opened["tileId"] as! String
    _ = try call("browser.wait_for", ["tileId": tile, "condition": "idle"])
    _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { document.body.innerHTML='<input aria-label=Field>'; return true }"])
    let outline = try call("browser.snapshot", ["tileId": tile])["text"] as! String
    guard let field = outline.split(separator: "\n").first(where: { $0.contains("Field") }),
          let range = field.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else {
        throw WorkspaceAPIChecks.Failure(message: "missing field ref")
    }
    let ref = String(field[range].dropFirst(5).dropLast())
    let old = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let siblingTileID = UUID()
    guard let source = f.delegate.qaAgentSupervisor.records[f.agentId], let harness = source.harness else {
        throw WorkspaceAPIChecks.Failure(message: "missing source agent")
    }
    let siblingAgent = f.delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot,
        harness: harness, model: source.model, thinking: source.thinking,
        projectId: f.projectPb, projectRoot: f.pbRoot, tileId: siblingTileID)
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: siblingAgent, true)
    let siblingTile = ManagedAgentTileNSView(tile: Tile(id: siblingTileID, kind: .managedAgent, title: "Sibling agent",
        frame: TileFrame(x: 120, y: 0, width: 560, height: 620), zPosition: .first, runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed-agent")))
    siblingTile.frame = NSRect(x: 120, y: 0, width: 560, height: 620)
    root.addSubview(old)
    root.addSubview(siblingTile)
    f.delegate.qaBindAgentComposerState(siblingTile)
    siblingTile.attach(agentID: siblingAgent, supervisor: f.delegate.qaAgentSupervisor)
    let priorPointer = ManagedAgentTileNSView.qaPointerInside
    ManagedAgentTileNSView.qaPointerInside = { $0 === siblingTile }
    defer { ManagedAgentTileNSView.qaPointerInside = priorPointer }
    siblingTile.promoteBodyToNative()
    siblingTile.wakeChrome()
    root.layoutSubtreeIfNeeded()
    guard let next = siblingTile.qaComposerForChecks?.dictationTextView else {
        throw WorkspaceAPIChecks.Failure(message: "missing sibling agent composer")
    }
    let composerPoint = old.convert(NSPoint(x: 5, y: 5), to: nil)
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        NSApp.sendEvent(NSEvent.mouseEvent(with: kind, location: composerPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    window.makeFirstResponder(old)
    var sent = false
    guard let browser = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId.uuidString == tile }) else {
        throw WorkspaceAPIChecks.Failure(message: "missing browser engine")
    }
    let engine = browser.automation
    if realKey && !engine.supportsFocusFreeInput { throw WorkspaceAPIChecks.Failure(message: "Tier B suppression selector unavailable; Stage 1 fallback is not a focus-free proof") }
    var transientBorrow = false
    var expectedHostResponder: NSResponder? = old
    var userFocusGesture = false
    var strictHostTrace = experimental
    if experimental {
        window.responderTrace = { responder in
            if let view = responder as? NSView, view === browser.webView || view.isDescendant(of: browser.webView) { transientBorrow = true }
        }
    }
    // Replay the numeric input sequence while a host composer owns focus.
    _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { const e=document.querySelector('input'); e.type='number'; e.value='1'; window.numericModel='1'; window.numericTrusted=false; e.oninput=event=>{ numericModel=e.value; numericTrusted=event.isTrusted }; return true }"])
    _ = try call("browser.snapshot", ["tileId": tile])
    _ = try call("browser.click", ["tileId": tile, "ref": ref])
    window.makeFirstResponder(old)
    _ = try call("browser.press_key", ["tileId": tile, "keyName": "Meta+a"])
    _ = try call("browser.press_key", ["tileId": tile, "keyName": "3"])
    _ = try call("browser.press_key", ["tileId": tile, "keyName": "Tab"])
    let numeric = try call("browser.evaluate", ["tileId": tile, "script": "() => document.querySelector('input').value"])
    guard numeric["value"] as? String == "3" else {
        throw WorkspaceAPIChecks.Failure(message: "numeric replay did not commit 3: \(numeric)")
    }
    let numericModel = try call("browser.evaluate", ["tileId":tile,"script":"() => numericModel==='3' && numericTrusted"])
    guard numericModel["value"] as? Bool == true else { throw WorkspaceAPIChecks.Failure(message:"numeric 3 did not reach trusted application state") }
    _ = try call("browser.click", ["tileId":tile,"ref":ref])
    _ = try call("browser.press_key", ["tileId":tile,"keyName":"Meta+a"])
    _ = try call("browser.press_key", ["tileId":tile,"keyName":"1"])
    _ = try call("browser.press_key", ["tileId":tile,"keyName":"2"])
    _ = try call("browser.press_key", ["tileId":tile,"keyName":"Tab"])
    let twelve = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value==='12' && numericModel==='12' && numericTrusted"])
    guard twelve["value"] as? Bool == true else { throw WorkspaceAPIChecks.Failure(message:"numeric 12 did not persist after Tab") }
    guard window.firstResponder === old && old.string.isEmpty else { throw WorkspaceAPIChecks.Failure(message: "agent key disturbed composer") }
    let userKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
    NSApp.sendEvent(userKey)
    guard old.string == "q" else { throw WorkspaceAPIChecks.Failure(message: "user key missed composer: value=\(old.string), responder=\(String(describing: window.firstResponder)), keyWindow=\(String(describing: NSApp.keyWindow))") }
    old.string = ""
    _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { const e=document.querySelector('input'); e.type='text'; e.value=''; return true }"])
    if experimental {
        if realKey {
            guard NSApp.keyWindow === window, window.isKeyWindow else { throw WorkspaceAPIChecks.Failure(message:"Tier B lost native key state in numeric case") }
        }
        guard !transientBorrow else { throw WorkspaceAPIChecks.Failure(message: "numeric replay borrowed responder") }
        if realKey { tierBPassedCases.insert("numeric") }
        print("PASS: \(realKey ? "Tier B real key" : "Tier A faked key") numeric 3 and 12 after Tab; trusted application state; user key in composer")
    }
    var borrowedDuringOrdinaryClick = false
    window.responderTrace = { responder in
        if let view = responder as? NSView, view === browser.webView || view.isDescendant(of: browser.webView) {
            borrowedDuringOrdinaryClick = true
        } else if strictHostTrace && !userFocusGesture && responder !== expectedHostResponder {
            borrowedDuringOrdinaryClick = true
        }
    }
    if experimental { engine._duringAgentClickForChecks = { NSApp.sendEvent(userKey) } }
    _ = try call("browser.click", ["tileId": tile, "ref": ref])
    engine._duringAgentClickForChecks = nil
    if experimental { guard !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message: "agent click borrowed responder") } }
    if !experimental { window.responderTrace = nil }
    print("Ordinary agent click: responderBorrowObserved=\(borrowedDuringOrdinaryClick), originalResponderAfterAction=\(window.firstResponder === old)")
    guard window.firstResponder === old else {
        throw WorkspaceAPIChecks.Failure(message: "ordinary click lost composer: \(String(describing: window.firstResponder))")
    }
    if !experimental { NSApp.sendEvent(userKey) }
    guard old.string == "q" else { throw WorkspaceAPIChecks.Failure(message: "ordinary click lost next user key") }
    if experimental {
        if realKey {
            guard NSApp.keyWindow === window, window.isKeyWindow else { throw WorkspaceAPIChecks.Failure(message:"Tier B lost native key state in click case") }
            tierBPassedCases.insert("click")
        }
        print("PASS: \(realKey ? "Tier B real key" : "Tier A faked key") user key during click; zero transient borrow")
    }
    old.string = ""
    var delivered = 0
    engine._afterAgentCharacterForChecks = {
        delivered += 1
        guard delivered == 5 else { return }
        DispatchQueue.main.async {
            userFocusGesture = true
            let point = next.convert(NSPoint(x: 10, y: 10), to: nil)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
            expectedHostResponder = next
            userFocusGesture = false
            for _ in 0..<5 {
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
                NSApp.sendEvent(key)
            }
            sent = true
        }
    }
    defer { engine._afterAgentCharacterForChecks = nil }
    _ = try call("browser.type", ["tileId": tile, "ref": ref, "text": String(repeating: "a", count: 100)])
    let prefix = try call("browser.evaluate", ["tileId": tile, "script": "() => document.querySelector('input').value"])
    guard prefix["value"] as? String == (experimental ? String(repeating: "a", count: 100) : "aaaaa"), sent, delivered == (experimental ? 100 : 5), window.firstResponder === next, next.string == "zzzzz", siblingTile.qaComposerDraftText == "zzzzz", old.string.isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "typing restored obsolete focus or lost user keys: newResponder=\(window.firstResponder === next), delivered=\(delivered), next=\(next.string), old=\(old.string)")
    }
    if experimental { guard !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message:"core type changed host responder") } }
    if experimental && !realKey {
        guard let assets = Bundle.module.url(forResource: "FocusInputFixtures", withExtension: nil) else { throw WorkspaceAPIChecks.Failure(message: "missing vendored editor fixtures") }
        let js = try Data(contentsOf: assets.appendingPathComponent("editor.js"))
        try js.write(to: f.pbRoot.appendingPathComponent("editor.js"))
        func fieldRef() throws -> String {
            let text = try call("browser.snapshot", ["tileId": tile])["text"] as? String ?? ""
            guard let line = text.split(separator: "\n").first(where: { $0.contains("Field") }), let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else { throw WorkspaceAPIChecks.Failure(message: "missing editor ref: \(text)") }
            return String(line[range].dropFirst(5).dropLast())
        }
        for kind in ["react", "cm", "pm"] {
            if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == kind { BrowserAutomation.focusFreeInputEnabled = false }
            engine._afterAgentCharacterForChecks = nil
            let page = f.pbRoot.appendingPathComponent("editor-\(kind).html")
            try Data("<html><head><style>body{margin:20px}input{width:240px;height:40px}.cm-editor,.ProseMirror{min-height:100px;border:1px solid}</style></head><body data-kind='\(kind)'><div id='root'></div><script src='editor.js'></script></body></html>".utf8).write(to: page)
            _ = try call("browser.navigate", ["tileId": tile, "url": page.absoluteString])
            _ = try call("browser.wait_for", ["tileId": tile, "condition": "idle"])
            let editorRef = try fieldRef()
            let startKeys = next.string
            engine._afterAgentCharacterForChecks = { NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32)!) }
            _ = try call("browser.type", ["tileId": tile, "ref": editorRef, "text": "agent", "clear": true])
            let model = try call("browser.evaluate", ["tileId": tile, "script": "() => readState().value"])
            let trustedInput = try call("browser.evaluate", ["tileId": tile, "script": "() => events.some(e=>e.type==='input' && e.trusted)"])
            guard trustedInput["value"] as? Bool == true, model["value"] as? String == "agent", next.string == startKeys + "uuuuu", window.firstResponder === next, !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message: "\(kind) application state/concurrent input failed: \(model)") }
            engine._afterAgentCharacterForChecks = nil
            _ = try call("browser.press_key", ["tileId": tile, "keyName": "Meta+a"])
            _ = try call("browser.type", ["tileId": tile, "text": "replace"])
            let replaced = try call("browser.evaluate", ["tileId": tile, "script": "() => readState().value"])
            guard replaced["value"] as? String == "replace" else { throw WorkspaceAPIChecks.Failure(message: "\(kind) Select All route failed: \(replaced)") }
            _ = try call("browser.press_key", ["tileId": tile, "keyName": "Meta+z"])
            let undone = try call("browser.evaluate", ["tileId": tile, "script": "() => readState().value"])
            guard ["seed", "agent"].contains(undone["value"] as? String ?? "") else { throw WorkspaceAPIChecks.Failure(message: "\(kind) Undo model failed: \(undone)") }
            _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { refreshEditor(); return true }"])
            _ = try call("browser.type", ["tileId": tile, "ref": editorRef, "text": "rerender", "clear": true])
            let refreshed = try call("browser.evaluate", ["tileId": tile, "script": "() => readState().value"])
            guard refreshed["value"] as? String == "rerender" else { throw WorkspaceAPIChecks.Failure(message: "\(kind) rerender failed: \(refreshed)") }
            if kind == "pm" {
                _ = try call("browser.press_key", ["tileId": tile, "keyName": "Meta+b"])
                _ = try call("browser.type", ["tileId": tile, "text": "B"])
                let bold = try call("browser.evaluate", ["tileId": tile, "script": "() => readState().doc.content.some(p => (p.content||[]).some(t => (t.marks||[]).some(m=>m.type==='strong')))"])
                guard bold["value"] as? Bool == true else { throw WorkspaceAPIChecks.Failure(message: "ProseMirror direct bold did not update model") }
            }
            if kind == "react" {
                _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { const host=document.getElementById('root'); const form=document.createElement('form'); host.replaceWith(form); form.appendChild(host); window.submitted=0; window.submitTrusted=false; form.addEventListener('submit',e=>{e.preventDefault(); submitted++; submitTrusted=e.isTrusted}); return true }"])
                _ = try call("browser.type", ["tileId":tile,"ref":editorRef,"text":"submitted","clear":true,"submit":true])
                let submitted = try call("browser.evaluate", ["tileId":tile,"script":"() => submitted===1 && submitTrusted && readState().value==='submitted'"])
                guard submitted["value"] as? Bool == true else { throw WorkspaceAPIChecks.Failure(message:"React form did not submit its model exactly once") }
            } else {
                _ = try call("browser.press_key", ["tileId":tile,"keyName":"Enter"])
                let entered = try call("browser.evaluate", ["tileId":tile,"script":kind == "cm" ? "() => readState().value==='rerender\\n'" : "() => readState().doc.content.length===2"])
                guard entered["value"] as? Bool == true else { throw WorkspaceAPIChecks.Failure(message:"\(kind) Enter did not update application model: \(entered)") }
                _ = try call("browser.press_key", ["tileId":tile,"keyName":"Tab"])
            }
            guard window.firstResponder === next, !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message:"\(kind) submit/Enter/Tab moved host responder") }
            print("PASS: Tier A faked key \(kind) application model, selection/replace, Undo, rerender, submit/Enter/Tab and concurrent composer input")
        }
    }
    if experimental && !realKey {
        engine._afterAgentCharacterForChecks = nil
        var retentionFailures: [String] = []
        for (name, intended, clear, limit) in [
            ("truncated", String(repeating: "x", count: 240), true, 220),
            ("rejected", "requested", false, 0)
        ] {
            _ = try call("browser.evaluate", ["tileId":tile,"script": "() => { document.body.innerHTML='<div contenteditable=true role=textbox aria-label=Retention></div>'; const e=document.querySelector('[contenteditable]'); e.oninput=()=>{e.textContent=\(limit == 0 ? "'X'" : "e.textContent.slice(0,\(limit))")}; return true }"])
            let snapshot = try call("browser.snapshot", ["tileId":tile])["text"] as? String ?? ""
            guard let line = snapshot.split(separator:"\n").first(where:{$0.contains("Retention")}),
                  let range = line.range(of:#"\[ref=([^\]]+)\]"#, options:.regularExpression) else { throw WorkspaceAPIChecks.Failure(message:"missing retention editor") }
            let retentionRef = String(line[range].dropFirst(5).dropLast())
            let reply = try call("browser.type", ["tileId":tile,"ref":retentionRef,"text":intended,"clear":clear], allowError:true)
            let error = reply["error"] as? [String:Any]
            let action = (error?["details"] as? [String:Any])?["action"] as? [String:Any]
            let actual = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('[contenteditable]').textContent"])["value"] as? String
            let expected = limit == 0 ? "X" : String(repeating:"x",count:limit)
            if error?["code"] as? String != "outcome_unknown" || action?["effects"] as? String != "partial" ||
                action?["deliveredCharacters"] as? Int != limit || action?["freshSnapshotRequired"] as? Bool != true || actual != expected {
                print("FAIL: contenteditable \(name) retained=\(limit): \(reply)")
                retentionFailures.append(name)
            } else { print("PASS: contenteditable \(name) reports retained \(limit)/\(intended.count) characters; no false completion") }
        }
        _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { document.querySelector('[contenteditable]').oninput=null; return true }"])
        let normalizedSnapshot = try call("browser.snapshot", ["tileId":tile])["text"] as? String ?? ""
        guard let normalizedLine=normalizedSnapshot.split(separator:"\n").first(where:{$0.contains("Retention")}),
              let normalizedRange=normalizedLine.range(of:#"\[ref=([^\]]+)\]"#,options:.regularExpression) else { throw WorkspaceAPIChecks.Failure(message:"missing normalized editor") }
        let normalizedRef=String(normalizedLine[normalizedRange].dropFirst(5).dropLast())
        _ = try call("browser.type", ["tileId":tile,"ref":normalizedRef,"text":"alpha  beta\nsecond","clear":true])
        _ = try call("browser.type", ["tileId":tile,"text":" suffix"])
        let normalizedValue = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('[contenteditable]').innerText.replace(/\\s+/g,' ').trim()"])
        guard normalizedValue["value"] as? String == "alpha beta second suffix" else { throw WorkspaceAPIChecks.Failure(message:"contenteditable normalization/append failed: \(normalizedValue)") }
        print("PASS: contenteditable full multiline and whitespace normalization, followed by verified append")
        guard retentionFailures.isEmpty else { throw WorkspaceAPIChecks.Failure(message:"contenteditable retention failures: \(retentionFailures)") }
        // Explicit user camera/workspace seams may change host focus. Continue
        // rejecting entry into WebKit while the agent owns delivery.
        strictHostTrace = false
        engine._afterAgentCharacterForChecks = nil
        _ = try call("browser.evaluate", ["tileId": tile, "script": "() => { document.body.innerHTML='<input aria-label=Field>'; return true }"])
        func currentRef() throws -> String {
            let text = try call("browser.snapshot", ["tileId": tile])["text"] as? String ?? ""
            guard let line = text.split(separator: "\n").first(where: { $0.contains("Field") }), let range = line.range(of: #"\[ref=([^\]]+)\]"#, options: .regularExpression) else { throw WorkspaceAPIChecks.Failure(message: "missing lifecycle ref") }
            return String(line[range].dropFirst(5).dropLast())
        }
        _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { const e=document.querySelector('input'); e.value='seed'; e.oninput=()=>{e.value='seed'}; return true }"])
        let rejectionRef = try currentRef()
        let rejected = try call("browser.type", ["tileId":tile,"ref":rejectionRef,"text":"rejected","clear":true], allowError:true)
        guard let rejectionError = rejected["error"] as? [String:Any], rejectionError["code"] as? String == "outcome_unknown", let rejectionAction = (rejectionError["details"] as? [String:Any])?["action"] as? [String:Any], rejectionAction["effects"] as? String == "partial", rejectionAction["deliveredCharacters"] as? Int == 0 else { throw WorkspaceAPIChecks.Failure(message:"application rejection was reported as retained text: \(rejected)") }
        _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { const e=document.querySelector('input'); e.oninput=null; return true }"])
        print("PASS: Tier A faked key application rejects text: zero retained characters, partial effects and snapshot guidance")
        _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { const e=document.querySelector('input'); const host=document.createElement('div'); host.className='monaco-editor'; e.replaceWith(host); host.appendChild(e); e.focus(); return true }"])
        let monacoRef = try currentRef()
        for (operation,payload) in [("browser.click", ["tileId":tile,"ref":monacoRef]), ("browser.press_key", ["tileId":tile,"keyName":"Meta+z"])] {
            let refused = try call(operation,payload,allowError:true)
            guard let error = refused["error"] as? [String:Any], error["code"] as? String == "unsupported", let action = (error["details"] as? [String:Any])?["action"] as? [String:Any], action["effects"] as? String == "none" else { throw WorkspaceAPIChecks.Failure(message:"Monaco known limit was dispatched: \(refused)") }
        }
        _ = try call("browser.evaluate", ["tileId":tile,"script":"() => { document.body.innerHTML='<input aria-label=Field>'; return true }"])
        print("PASS: Tier A faked key Monaco classification fixture refuses caret/Undo before dispatch (actual Monaco remains unsupported)")
        if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == "pan" { BrowserAutomation.focusFreeInputEnabled = false }
        let panRef = try currentRef()
        let cameraBefore = f.canvas.canvasState.viewport
        var panSent = false
        engine._afterAgentCharacterForChecks = {
            guard !panSent else { return }; panSent = true
            DispatchQueue.main.async {
                for (kind, point) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 1000,y:900)), (.leftMouseDragged, NSPoint(x:1020,y:920)), (.leftMouseUp, NSPoint(x:1020,y:920))] {
                    NSApp.sendEvent(NSEvent.mouseEvent(with:kind,location:point,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:1)!)
                }
            }
        }
        _ = try call("browser.type", ["tileId":tile,"ref":panRef,"text":"pan survives","clear":true])
        let panValue = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard !borrowedDuringOrdinaryClick, panSent, f.canvas.canvasState.viewport != cameraBefore, panValue["value"] as? String == "pan survives" else { throw WorkspaceAPIChecks.Failure(message:"pan interrupted typing or camera: \(panValue)") }
        print("PASS: Tier A faked key pan during type preserves page and camera")
        engine._afterAgentCharacterForChecks = nil
        if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == "zone" { BrowserAutomation.focusFreeInputEnabled = false }
        let zoneRef = try currentRef()
        guard let originalZone = f.runtime.document.zones.first(where:{$0.zoneId == f.zoneB}) else { throw WorkspaceAPIChecks.Failure(message:"missing driven zone") }
        var automaticZone = originalZone
        automaticZone.hydrationPolicy = .automatic
        try f.runtime.commitZonePlacement(automaticZone)
        var zoneReconciled = false
        var zoneCharacters = 0
        engine._afterAgentCharacterForChecks = {
            zoneCharacters += 1
            guard zoneCharacters == 3 else { return }
            DispatchQueue.main.async {
                _ = f.runtime.setActiveZone(f.zoneA,reason:.click)
                f.canvas.setViewport(CanvasViewport(x:-10000,y:-10000,zoom:1))
                f.runtime.flushPendingHydrationReconcile()
                zoneReconciled = true
            }
        }
        _ = try call("browser.type", ["tileId":tile,"ref":zoneRef,"text":"zone survives","clear":true])
        let zoneValue = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard !borrowedDuringOrdinaryClick, zoneReconciled, !browser.isTerminated, zoneValue["value"] as? String == "zone survives" else { throw WorkspaceAPIChecks.Failure(message:"off-camera automatic zone retired input") }
        try f.runtime.commitZonePlacement(originalZone)
        f.runtime.flushPendingHydrationReconcile()
        print("PASS: Tier A faked key off-camera automatic zone retains in-flight input")
        engine._afterAgentCharacterForChecks = nil
        if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == "workspace" { BrowserAutomation.focusFreeInputEnabled = false }
        let switchRef = try currentRef()
        let originalWarmCapacity = f.runtime.warmSceneCapacity
        f.runtime.warmSceneCapacity = 0
        defer { f.runtime.warmSceneCapacity = originalWarmCapacity }
        var switched = false
        var switchError: Error?
        var characters = 0
        let originalRuntime = browser.id
        engine._afterAgentCharacterForChecks = {
            characters += 1
            guard characters == 3 else { return }
            DispatchQueue.main.async {
                do {
                    _ = f.runtime.setActiveZone(f.zoneA, reason: .click)
                    try f.runtime.switchWorkspace(to: f.workspaceWB)
                    f.runtime.enforceBrowserRuntimeBudget()
                    switched = true
                } catch { switchError = error }
            }
        }
        _ = try call("browser.type", ["tileId":tile,"ref":switchRef,"text":"workspace survives","clear":true])
        if let switchError { throw switchError }
        guard !borrowedDuringOrdinaryClick, switched, !browser.isTerminated, browser.id == originalRuntime else { throw WorkspaceAPIChecks.Failure(message:"workspace switch retired action runtime") }
        engine._afterAgentCharacterForChecks = nil
        let parked = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard parked["value"] as? String == "workspace survives" else { throw WorkspaceAPIChecks.Failure(message:"parked application value incorrect: \(parked)") }
        _ = try call("browser.snapshot", ["tileId":tile])
        _ = try call("browser.type", ["tileId":tile,"text":" parked"])
        let parkedTyped = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard parkedTyped["value"] as? String == "workspace survives parked" else { throw WorkspaceAPIChecks.Failure(message:"parked type failed: \(parkedTyped)") }
        let parkedPage = f.pbRoot.appendingPathComponent("parked-navigation.html")
        try Data("<html><body><input aria-label=Field value=navigated></body></html>".utf8).write(to:parkedPage)
        _ = try call("browser.navigate", ["tileId":tile,"url":parkedPage.absoluteString])
        let parkedNavigation = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        let storedNavigation = try f.storePb.loadCanvas().tiles.first(where:{$0.id == browser.tileId})?.metadata.url
        guard parkedNavigation["value"] as? String == "navigated", storedNavigation == parkedPage.absoluteString else { throw WorkspaceAPIChecks.Failure(message:"parked navigation did not reconcile page and persisted URL") }
        try f.runtime.switchWorkspace(to:f.workspaceWA)
        guard !browser.isTerminated, browser.id == originalRuntime else { throw WorkspaceAPIChecks.Failure(message:"remount replaced action runtime") }
        print("PASS: Tier A faked key zone/workspace switch, parking, parked input/navigation and persisted URL retain runtime identity")
        guard !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message:"parked input/navigation borrowed responder") }
        // This is the user's deliberate entry, outside any agent action.
        window.responderTrace = nil
        window.makeFirstResponder(browser.webView)
        NSApp.sendEvent(userKey)
        guard let handbackSurface = f.canvas.tileView(for:browser.tileId) as? BrowserTileNSView else { throw WorkspaceAPIChecks.Failure(message:"missing handback surface") }
        handbackSurface.qaChooseAgentControl("return")
        guard f.canvas.tileRecord(for:browser.tileId)?.metadata.browserControlPaused == false else { throw WorkspaceAPIChecks.Failure(message:"handback did not establish snapshot fence") }
        window.makeFirstResponder(next)
        f.canvas.markActive(tileId:f.agentTileB)
        window.responderTrace = { responder in
            if let view = responder as? NSView, view === browser.webView || view.isDescendant(of:browser.webView) { borrowedDuringOrdinaryClick = true }
        }
        try f.runtime.switchWorkspace(to:f.workspaceWB)
        _ = try call("browser.snapshot", ["tileId":tile])
        guard try f.storePb.loadCanvas().tiles.first(where:{$0.id == browser.tileId})?.metadata.browserControlPaused == nil else { throw WorkspaceAPIChecks.Failure(message:"parked handback snapshot did not clear persisted fence") }
        let handbackRef = try currentRef()
        _ = try call("browser.type", ["tileId":tile,"ref":handbackRef,"text":"handback","clear":true])
        let handbackValue = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard handbackValue["value"] as? String == "handback", f.runtime.document.zones.contains(where:{$0.projectId == f.projectPc}) else { throw WorkspaceAPIChecks.Failure(message:"parked handback failed or revealed source workspace") }
        try f.runtime.switchWorkspace(to:f.workspaceWA)
        print("PASS: Tier A faked key handback followed by workspace switch clears its durable fence and resumes input while parked")
        engine._afterAgentCharacterForChecks = nil
        let extra = try call("browser.open", ["url":"about:blank"])
        let extraID = extra["tileId"] as! String
        _ = try call("browser.wait_for", ["tileId":extraID,"condition":"idle"])
        guard let spare = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where:{$0.tileId.uuidString == extraID}) else { throw WorkspaceAPIChecks.Failure(message:"missing eviction spare") }
        window.makeFirstResponder(spare.webView)
        NSApp.sendEvent(userKey)
        window.makeFirstResponder(next)
        f.canvas.markActive(tileId:f.agentTileB)
        f.runtime.qaSetBrowserRuntimeMaxLive(1)
        defer { f.runtime.qaSetBrowserRuntimeMaxLive(6) }
        if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == "eviction" { BrowserAutomation.focusFreeInputEnabled = false }
        let evictionRef = try currentRef()
        var evictionAttempted = false
        characters = 0
        engine._afterAgentCharacterForChecks = {
            characters += 1
            guard characters == 3 else { return }
            DispatchQueue.main.async { f.runtime.enforceBrowserRuntimeBudget(); evictionAttempted = true }
        }
        _ = try call("browser.type", ["tileId":tile,"ref":evictionRef,"text":"eviction survives","clear":true])
        let evictionValue = try call("browser.evaluate", ["tileId":tile,"script":"() => document.querySelector('input').value"])
        guard !borrowedDuringOrdinaryClick, evictionAttempted, spare.isTerminated, !browser.isTerminated, browser.id == originalRuntime, evictionValue["value"] as? String == "eviction survives" else { throw WorkspaceAPIChecks.Failure(message:"budget did not evict spare and preserve leased action: spare=\(spare.isTerminated), active=\(browser.isTerminated), value=\(evictionValue)") }
        print("PASS: Tier A faked key real budget eviction retires spare and preserves in-flight leased input")
        engine._afterAgentCharacterForChecks = nil
        if ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_RED_CONTROL"] == "close" { BrowserAutomation.focusFreeInputEnabled = false }
        let closingRef = try currentRef()
        var closed = false
        characters = 0
        engine._afterAgentCharacterForChecks = {
            characters += 1
            guard characters == 3 else { return }
            DispatchQueue.main.async { f.delegate.deleteTile(id:browser.tileId); closed = true }
        }
        let closeReply = try call("browser.type", ["tileId":tile,"ref":closingRef,"text":String(repeating:"x",count:100),"clear":true], allowError:true)
        guard !borrowedDuringOrdinaryClick, closed, browser.isTerminated, closeReply["status"] as? String == "error", engine.actionDeliveredCharacters < 100 else { throw WorkspaceAPIChecks.Failure(message:"close did not fence original input: \(closeReply)") }
        let deliveredAtClose = engine.actionDeliveredCharacters
        let replacement = try call("browser.open", ["url":"about:blank"])
        let replacementID = replacement["tileId"] as! String
        _ = try call("browser.wait_for", ["tileId":replacementID,"condition":"idle"])
        _ = try call("browser.evaluate", ["tileId":replacementID,"script":"() => { document.body.innerHTML='<input>'; return true }"])
        let obsolete = try call("browser.type", ["tileId":tile,"text":"LEAK"], allowError:true)
        let replacementValue = try call("browser.evaluate", ["tileId":replacementID,"script":"() => document.querySelector('input').value"])
        guard obsolete["status"] as? String == "error", replacementValue["value"] as? String == "", engine.actionDeliveredCharacters == deliveredAtClose else { throw WorkspaceAPIChecks.Failure(message:"closed identity leaked input into replacement") }
        print("PASS: Tier A faked key close stops prefix input and old identity cannot target replacement")
    }
    if experimental {
        guard !borrowedDuringOrdinaryClick else { throw WorkspaceAPIChecks.Failure(message: "agent type borrowed responder") }
        if realKey {
            guard NSApp.keyWindow === window, window.isKeyWindow else { throw WorkspaceAPIChecks.Failure(message:"Tier B lost native key state in type case") }
            tierBPassedCases.insert("type")
        }
        print("PASS: \(realKey ? "Tier B real key" : "Tier A faked key") 100 agent characters, five concurrent user keys, zero transient borrow")
    } else { print("PASS: browser focus restoration preserves another agent composer, its draft and all five user keys") }
}

/// Explicitly authorized, one-shot Tier B. Never a normal matrix leg.
@MainActor
func runBrowserFocusFreeRealKeyCheck() throws {
    if let path = ProcessInfo.processInfo.environment["ARRAY_REAL_KEY_LOG_PATH"] {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else { throw WorkspaceAPIChecks.Failure(message: "Tier B cannot open log: \(path), errno=\(errno)") }
        guard dup2(fd, STDOUT_FILENO) >= 0, dup2(fd, STDERR_FILENO) >= 0 else {
            close(fd)
            throw WorkspaceAPIChecks.Failure(message: "Tier B cannot redirect log")
        }
        if fd > STDERR_FILENO { close(fd) }
    }
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    guard ProcessInfo.processInfo.environment["ARRAY_ALLOW_REAL_KEY_PROOF"] == "1" else {
        throw WorkspaceAPIChecks.Failure(message: "REFUSED: Tier B activates an offscreen check app briefly. Requires Dylan approval and ARRAY_ALLOW_REAL_KEY_PROOF=1; no activation occurred.")
    }
    setbuf(stdout, nil)
    tierBPassedCases.removeAll()
    // LaunchServices may foreground us before main(). The launcher captures the
    // previous PID before open; without it, never pretend self is a restore target.
    let priorPID = ProcessInfo.processInfo.environment["ARRAY_REAL_KEY_PREVIOUS_PID"].flatMap(Int32.init)
    let previous = priorPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        ?? NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
    guard let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
        throw WorkspaceAPIChecks.Failure(message: "Tier B requires an external previous-frontmost PID; pass ARRAY_REAL_KEY_PREVIOUS_PID captured before open")
    }
    let start = Date()
    tierBSetupLog("entry; restore target=\(previous.localizedName ?? "nil") pid=\(previous.processIdentifier)", since: start)
    let progress = tierBPassedCases
    // POSIX exit is independent of the main queue and of the restoration IPC.
    let previousAlarmHandler = signal(SIGALRM) { _ in Darwin._exit(1) }
    alarm(29)
    defer { alarm(0); _ = signal(SIGALRM, previousAlarmHandler) }
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    watchdog.schedule(deadline: .now() + 28)
    watchdog.setEventHandler {
        for name in ["numeric", "click", "type"] where !progress.contains(name) { fputs("FAIL: Tier B \(name): hard timeout\n", stderr) }
        fputs("FAIL: Tier B hard timeout (28s); returning previous app and exiting\n", stderr)
        if progress.contains("tookForeground") || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            _ = previous.activate(options: [.activateIgnoringOtherApps])
            let end = Date().addingTimeInterval(0.5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            fputs(NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier
                ? "PASS: Tier B watchdog returned previous frontmost app\n"
                : "FAIL: Tier B watchdog could not confirm restoration\n", stderr)
        } else {
            fputs("INFO: Tier B never took foreground; no restoration needed\n", stderr)
        }
        Darwin._exit(1)
    }
    watchdog.resume()
    defer { watchdog.cancel() }
    let policyAccepted = NSApp.setActivationPolicy(.regular)
    tierBSetupLog("regular policy requested accepted=\(policyAccepted); before finishLaunching", since: start)
    NSApp.finishLaunching()
    tierBSetupLog("after finishLaunching", since: start)
    var failure: Error?
    do { try runBrowserFocusRestorationCheck(experimental: true, realKey: true) }
    catch {
        for name in ["numeric", "click", "type"] where !tierBPassedCases.contains(name) { print("FAIL: Tier B \(name): \(error)") }
        failure = error
    }
    tierBSetupLog("before restoration", since: start)
    if !progress.contains("tookForeground") && NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier {
        print("INFO: Tier B never took foreground; no restoration needed")
    } else {
        let requested = previous.activate(options: [.activateIgnoringOtherApps])
        let end = Date().addingTimeInterval(0.5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier, Date() < end {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        tierBSetupLog("restoration requested=\(requested); wait ended", since: start)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier else {
            throw WorkspaceAPIChecks.Failure(message: "Tier B could not confirm restoration of the previous frontmost app")
        }
        print("PASS: Tier B returned previous frontmost app")
    }
    if let failure { throw failure }
}
