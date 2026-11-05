import AppKit
import ContinuumRevivedCore

/// Shared off-screen production-service fixture for the select and native
/// dispatch prevention witnesses. Its scene is mounted by makeFixture.
@MainActor
final class BrowserInputCheckFixture {
    let f: WorkspaceAPIChecks.Fixture
    let window: NSWindow
    var tile = ""
    init() throws {
        f = try WorkspaceAPIChecks.makeFixture()
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        f.delegate.qaAgentSupervisor.workspaceToolsPermission = { .free }
        window = NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = f.canvas
        window.orderFrontOffscreenForChecks()
        tile = try call("browser.open", ["url": "about:blank"])["tileId"] as! String
        _ = try call("browser.wait_for", ["condition": "idle"])
    }
    func close() { window.orderOut(nil); f.tearDown() }
    func raw(_ op: String, _ payload: [String: Any]) throws -> [String: Any] {
        var payload = payload
        if op != "browser.open" { payload["tileId"] = tile }
        var result: [String: Any]?
        f.api.handleMCPRequest(["agentId": f.agentId.rawValue.uuidString, "requestId": UUID().uuidString,
            "op": op, "payload": payload]) { result = $0 }
        let end = Date().addingTimeInterval(20)
        while result == nil && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard let result else { throw WorkspaceAPIChecks.Failure(message: "\(op) did not complete") }
        return result
    }
    func call(_ op: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
        let response = try raw(op, payload)
        guard response["status"] as? String == "ok", let result = response["result"] as? [String: Any] else {
            throw WorkspaceAPIChecks.Failure(message: "\(op): \(response)")
        }
        return result
    }
    func evaluate(_ body: String) throws -> Any? { try call("browser.evaluate", ["script": "() => { " + body + " }"])["value"] }
    func ref(_ name: String) throws -> String {
        let text = try call("browser.snapshot")["text"] as! String
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"" + name + "\"") }),
              let match = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else {
            throw WorkspaceAPIChecks.Failure(message: "missing \(name): \(text)")
        }
        return String(line[match].dropFirst(5).dropLast())
    }
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkspaceAPIChecks.Failure(message: message) }
    }
}

@MainActor
func runBrowserSelectCheck() throws {
    let c = try BrowserInputCheckFixture()
    defer { c.close() }
    _ = try c.evaluate("""
        document.body.innerHTML = '<select aria-label="Native"><option value="a">Alpha</option><optgroup label="Group"><option value="b">Beta</option><option value="b">Duplicate</option><option value="x" disabled>Disabled</option></optgroup></select><select multiple aria-label="Many"><option value="a">A</option><option value="b">B</option></select><select aria-label="Disabled group"><optgroup label="Locked" disabled><option value="d">Locked option</option></optgroup><option value="a">A</option></select><select disabled aria-label="Disabled control"><option value="a">A</option><option value="b">B</option></select><div role="combobox" aria-label="Custom">Custom widget</div><output id="state"></output>';
        window.events = []; window.appState = 'a';
        const select = document.querySelector('select');
        select.addEventListener('input', e => events.push('input:' + e.isTrusted));
        select.addEventListener('change', e => { events.push('change:' + e.isTrusted); window.appState = select.selectedIndex; document.getElementById('state').textContent = 'saved:' + select.selectedIndex; });
        return true;
        """)
    let ref = try c.ref("Native")
    let startup = Date().addingTimeInterval(1.5)
    while Date() < startup { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    print("Select startup windows before any select action: \(NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) + String(describing: $0.frame) })")
    let listed = try c.call("browser.select", ["ref": ref])
    guard let json = listed["value"] as? String,
          let listing = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let options = listing["options"] as? [[String: Any]] else { throw WorkspaceAPIChecks.Failure(message: "missing select listing") }
    try c.expect(listing["multiple"] as? Bool == false && options[0]["label"] as? String == "Alpha" && options[0]["value"] as? String == "a" && options[0]["selected"] as? Bool == true && options.count == 4 && options[1]["group"] as? String == "Group" && options[3]["disabled"] as? Bool == true,
                 "listing must retain groups, duplicates and disabled state")
    let snapshotText = try c.call("browser.snapshot")["text"] as! String
    guard let nativeLine = snapshotText.split(separator: "\n").first(where: { $0.contains("\"Native\"") }),
          let marker = nativeLine.range(of: "htmlSelect="),
          let snapshotSelect = try JSONSerialization.jsonObject(with: Data(nativeLine[marker.upperBound...].utf8)) as? [String: Any],
          let snapshotOptions = snapshotSelect["options"] as? [[String: Any]] else { throw WorkspaceAPIChecks.Failure(message: "snapshot must expose HTML select option metadata") }
    try c.expect(snapshotOptions.count == 4 && snapshotOptions[2]["value"] as? String == "b" && snapshotOptions[2]["group"] as? String == "Group", "snapshot option values and groups must match the actual select")
    let beforeWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    let picked = try c.call("browser.select", ["ref": ref, "options": [["value": "b", "index": 2]]])
    try c.expect((picked["changes"] as? [String])?.contains(where: { $0.contains("saved:2") }) == true,
        "select result must read back the application's rendered saved state")
    let state = try c.evaluate("return { index: document.querySelector('select').selectedIndex, app: window.appState, saved: document.getElementById('state').textContent, events: window.events };") as! [String: Any]
    try c.expect(state["index"] as? Int == 2 && state["app"] as? Int == 2 && state["saved"] as? String == "saved:2" && state["events"] as? [String] == ["input:false", "change:false"], "selection must update DOM and application state, with explicit untrusted event order")
    for request: [String: Any] in [["ref": ref, "options": [["value": "b"]]], ["ref": ref, "options": [["value": "x"]]], ["ref": ref, "options": [["value": "a"], ["value": "missing"]]]] {
        let response = try c.raw("browser.select", request)
        try c.expect(response["status"] as? String == "error", "invalid selection must be rejected")
        try c.expect(try c.evaluate("return document.querySelector('select').selectedIndex") as? Int == 2, "validation must be atomic")
    }
    _ = try c.call("browser.select", ["ref": try c.ref("Many"), "options": [["value": "a"], ["value": "b"]]])
    try c.expect(try c.evaluate("return document.querySelectorAll('select')[1].selectedOptions.length") as? Int == 2, "multiple selection must retain both values")
    _ = try c.call("browser.select", ["ref": try c.ref("Many"), "options": []])
    try c.expect(try c.evaluate("return document.querySelectorAll('select')[1].selectedOptions.length") as? Int == 0, "multiple select supports clearing")
    for (label, value) in [("Disabled group", "d"), ("Disabled control", "b")] {
        let denied = try c.raw("browser.select", ["ref": try c.ref(label), "options": [["value": value]]])
        try c.expect(denied["status"] as? String == "error", "disabled controls and groups must reject selection")
    }
    let custom = try c.raw("browser.select", ["ref": try c.ref("Custom")])
    try c.expect(custom["status"] as? String == "error", "ARIA widgets must retain their widget path")
    let newWindows = NSApp.windows.filter { $0.isVisible && !$0.frame.isEmpty && $0.alphaValue > 0 && !beforeWindows.contains($0.windowNumber) }
    try c.expect(newWindows.isEmpty, "semantic select must not create a native popup window: \(newWindows.map { String(describing: type(of: $0)) + ":" + $0.title + ":" + String(describing: $0.frame) + ":alpha=" + String(describing: $0.alphaValue) + ":level=" + String(describing: $0.level) })")
    // A controlled component may reject the requested selection on its next
    // microtask. The tool must report that reconciliation, not claim success.
    _ = try c.evaluate("document.querySelector('select').addEventListener('change', () => Promise.resolve().then(() => { document.querySelector('select').selectedIndex = 2; })); return true;")
    let reconciled = try c.raw("browser.select", ["ref": ref, "options": [["value": "a"]]])
    try c.expect((reconciled["error"] as? [String: Any])?["code"] as? String == "outcome_unknown", "application reconciliation must be observed")
    _ = try c.evaluate("const s = document.createElement('select'); s.setAttribute('aria-label', 'Value mutation'); s.innerHTML = '<option value=a>A</option><option value=b>B</option>'; s.addEventListener('change', () => Promise.resolve().then(() => { s.options[1].value = 'rewritten'; })); document.body.append(s); return true;")
    let rewritten = try c.raw("browser.select", ["ref": try c.ref("Value mutation"), "options": [["value": "b"]]])
    try c.expect((rewritten["error"] as? [String: Any])?["code"] as? String == "outcome_unknown", "readback must detect a changed value even when the selected index stays the same")
    c.f.delegate.qaAgentSupervisor.workspaceToolsPermission = { .askFirst }
    c.f.api.revoke(agentId: c.f.agentId)
    var prompted = 0
    c.f.api.approvalHandler = { _ in prompted += 1; return .deny }
    let denied = try c.raw("browser.select", ["ref": ref, "options": [["value": "a"]]])
    try c.expect(prompted == 1 && (denied["error"] as? [String: Any])?["code"] as? String == "scope_approval_required", "select must honor production browser-control grants")
    print("PASS: browser select lists and validates options, updates application state, and creates no popup")
}
