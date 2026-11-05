import AppKit
import ContinuumRevivedCore
import ObjectiveC

@MainActor
private final class BrowserFocusCheckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor
func runBrowserFocusRestorationCheck() throws {
    guard let method = class_getInstanceMethod(ComposerTextView.self, #selector(NSView.acceptsFirstMouse(for:))) else {
        throw WorkspaceAPIChecks.Failure(message: "missing acceptsFirstMouse")
    }
    let original = method_getImplementation(method)
    let accept: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
    method_setImplementation(method, imp_implementationWithBlock(accept))
    defer { method_setImplementation(method, original) }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    f.delegate.qaAgentSupervisor.workspaceToolsPermission = { .free }
    let window = BrowserFocusCheckWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: f.canvas.frame)
    root.addSubview(f.canvas)
    window.contentView = root
    window.orderFrontOffscreenForChecks()
    defer { window.orderOut(nil) }
    func call(_ op: String, _ payload: [String: Any]) throws -> [String: Any] {
        var response: [String: Any]?
        f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
            "op": op, "payload": payload]) { response = $0 }
        let limit = Date().addingTimeInterval(20)
        while response == nil && Date() < limit { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if op == "browser.type", response?["status"] as? String == "error",
           let error = response?["error"] as? [String: Any], error["code"] as? String == "target_conflict",
           (error["message"] as? String)?.contains("Keyboard focus moved") == true { return [:] }
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
          let range = field.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
        throw WorkspaceAPIChecks.Failure(message: "missing field ref")
    }
    let ref = String(field[range].dropFirst(5).dropLast())
    let old = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let next = ComposerTextView(frame: NSRect(x: 120, y: 0, width: 100, height: 100))
    root.addSubview(old)
    root.addSubview(next)
    window.makeFirstResponder(old)
    var sent = false
    let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
        MainActor.assumeIsolated {
            let point = next.convert(NSPoint(x: 10, y: 10), to: nil)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
            for _ in 0..<5 {
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
                NSApp.sendEvent(key)
            }
            sent = true
        }
    }
    defer { timer.invalidate() }
    _ = try call("browser.type", ["tileId": tile, "ref": ref, "text": String(repeating: "a", count: 100)])
    guard sent, window.firstResponder === next, next.string == "zzzzz", old.string.isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "typing restored obsolete focus or lost user keys: next=\(next.string), old=\(old.string)")
    }
    print("PASS: browser focus restoration preserves another editor and all five user keys")
}
