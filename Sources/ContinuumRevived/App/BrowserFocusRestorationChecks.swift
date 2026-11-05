import AppKit
import ContinuumRevivedCore
import ObjectiveC

@MainActor
private final class BrowserFocusCheckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    var responderTrace: ((NSResponder?) -> Void)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { responderTrace?(firstResponder) }
        return accepted
    }
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
        if ["browser.type", "browser.press_key"].contains(op), response?["status"] as? String == "error",
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
    window.makeFirstResponder(old)
    var sent = false
    guard let browser = f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId.uuidString == tile }) else {
        throw WorkspaceAPIChecks.Failure(message: "missing browser engine")
    }
    let engine = browser.automation
    var borrowedDuringOrdinaryClick = false
    window.responderTrace = { responder in
        if let view = responder as? NSView, view === browser.webView || view.isDescendant(of: browser.webView) {
            borrowedDuringOrdinaryClick = true
        }
    }
    _ = try call("browser.click", ["tileId": tile, "ref": ref])
    window.responderTrace = nil
    print("Ordinary agent click: responderBorrowObserved=\(borrowedDuringOrdinaryClick), originalResponderAfterAction=\(window.firstResponder === old)")
    window.makeFirstResponder(old)
    var delivered = 0
    engine._afterAgentCharacterForChecks = {
        delivered += 1
        guard delivered == 5 else { return }
        DispatchQueue.main.async {
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
    defer { engine._afterAgentCharacterForChecks = nil }
    _ = try call("browser.type", ["tileId": tile, "ref": ref, "text": String(repeating: "a", count: 100)])
    _ = try call("browser.press_key", ["tileId": tile, "keyName": "Backspace"])
    let prefix = try call("browser.evaluate", ["tileId": tile, "script": "() => document.querySelector('input').value"])
    guard prefix["value"] as? String == "aaaaa", sent, delivered == 5, window.firstResponder === next, next.string == "zzzzz", siblingTile.qaComposerDraftText == "zzzzz", old.string.isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "typing restored obsolete focus or lost user keys: newResponder=\(window.firstResponder === next), delivered=\(delivered), next=\(next.string), old=\(old.string)")
    }
    print("PASS: browser focus restoration preserves another agent composer, its draft and all five user keys")
}
