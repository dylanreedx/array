import AppKit
import ContinuumRevivedCore

@MainActor
func runBrowserNativeSelectPreflightCheck() throws {
    let previous = BrowserAutomation.focusFreeInputEnabled
    let experimental = ProcessInfo.processInfo.environment["ARRAY_FOCUS_FREE_TIER_A"] == "1"
    BrowserAutomation.focusFreeInputEnabled = experimental
    defer { BrowserAutomation.focusFreeInputEnabled = previous }
    let c = try BrowserInputCheckFixture()
    defer { c.close() }
    _ = try c.evaluate("""
        document.body.innerHTML = '<label for="native" role="button" aria-label="Picker label"><span>Label</span></label><select id="native" aria-label="Picker"><option value="a">A</option><option value="b">B</option></select><div role="combobox" aria-label="Custom" tabindex="0">Custom</div><iframe title="Frame"></iframe>';
        window.pickerHandlers = [];
        const select = document.querySelector('select');
        select.addEventListener('click', () => { pickerHandlers.push('immediate'); select.showPicker(); });
        select.addEventListener('click', () => { pickerHandlers.push('scheduled'); setTimeout(() => select.showPicker(), 0); });
        document.querySelector('iframe').srcdoc = '<label for="inside" role="button" aria-label="Frame label">Frame label</label><select id="inside" aria-label="Frame picker"><option value="a">A</option></select><button aria-label="Frame button">Frame button</button>';
        const inaccessible = document.createElement('iframe');
        inaccessible.title = 'Inaccessible'; inaccessible.setAttribute('sandbox', '');
        inaccessible.srcdoc = '<select><option>A</option></select>'; document.body.append(inaccessible);
        return true;
        """)
    if experimental { _ = try c.evaluate("document.querySelector('select').className='monaco-editor'; return true;") }
    let ready = Date().addingTimeInterval(1.5)
    while Date() < ready { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard let runtime = c.f.runtime.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId.uuidString == c.tile }) else {
        throw WorkspaceAPIChecks.Failure(message: "missing runtime")
    }
    let beforeWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    var nativeAttempts = 0
    // This behavioral dispatch-boundary hook prevents the RED replay from
    // opening an actual menu on Dylan's display. The production tool must
    // reject the request BEFORE it reaches this hook.
    runtime.automation._beforeNativeInputForChecks = {
        nativeAttempts += 1
        throw BrowserAutomationError.script("Witness stopped unsafe native input before dispatch")
    }
    defer { runtime.automation._beforeNativeInputForChecks = nil }
    func refused(_ op: String, _ payload: [String: Any]) throws {
        let before = nativeAttempts
        let response = try c.raw(op, payload)
        let error = response["error"] as? [String: Any]
        let action = c.action(response)
        try c.expect(action?["effects"] as? String == "none" && action?["state"] as? String == "rejected" &&
            action?["freshSnapshotRequired"] as? Bool == true && action?["retry"] as? String == "observe_before_new_action" &&
            !(action?["actionId"] as? String ?? "").isEmpty && !(action?["retrySessionId"] as? String ?? "").isEmpty,
            "native select refusal must use the structured no-effects result: \(response)")
        try c.expect(nativeAttempts == before && error?["code"] as? String == "unsupported" &&
            (error?["message"] as? String)?.contains("array_browser_select") == true,
            "native select must fail before dispatch and name select action: attempts=\(nativeAttempts - before), reply=\(response)")
    }
    let ref = try c.ref("Picker")
    try refused("browser.click", ["ref": ref])
    try refused("browser.click", ["ref": try c.ref("Picker label")])
    let labelPoint = try c.evaluate("const r = document.querySelector('label span').getBoundingClientRect(); return { x: r.left + 3, y: r.top + 3 };") as! [String: Any]
    try refused("browser.click", labelPoint)
    let point = try c.evaluate("const r = document.querySelector('select').getBoundingClientRect(); return { x: r.left + 3, y: r.top + 3 };") as! [String: Any]
    try refused("browser.click", point)
    try refused("browser.type", ["ref": ref, "text": "b"])
    _ = try c.evaluate("document.querySelector('select').focus(); return true;")
    for key in ["Space", "ArrowDown", "Alt+ArrowDown", "Enter"] { try refused("browser.press_key", ["keyName": key]) }
    try refused("browser.click", ["ref": try c.ref("Frame picker")])
    _ = try c.call("browser.select", ["ref": try c.ref("Frame picker"), "options": [["value": "a"]]])
    try refused("browser.click", ["ref": try c.ref("Frame label")])
    let framePoint = try c.evaluate("const f = document.querySelector('iframe'); const r = f.getBoundingClientRect(); const s = f.contentDocument.querySelector('select').getBoundingClientRect(); return {x:r.left + f.clientLeft + s.left + 3, y:r.top + f.clientTop + s.top + 3};") as! [String: Any]
    try refused("browser.click", framePoint)
    _ = try c.evaluate("const f = document.querySelector('iframe'); const r = f.getBoundingClientRect(); const b = f.contentDocument.querySelector('button').getBoundingClientRect(); const overlay = document.createElement('select'); overlay.id = 'overlay'; overlay.innerHTML = '<option>Overlay</option>'; Object.assign(overlay.style, {position:'fixed', zIndex:'99999', left:(r.left+f.clientLeft+b.left)+'px', top:(r.top+f.clientTop+b.top)+'px', width:b.width+'px', height:b.height+'px'}); document.body.append(overlay); return true;")
    try refused("browser.click", ["ref": try c.ref("Frame button")])
    _ = try c.evaluate("document.getElementById('overlay').remove(); return true;")
    _ = try c.evaluate("document.querySelector('iframe').style.transform = 'scale(0.8)'; return true;")
    try refused("browser.click", ["ref": try c.ref("Frame label")])
    let transformedPoint = try c.evaluate("const r = document.querySelector('iframe').getBoundingClientRect(); return { x: r.left + 4, y: r.top + 4 };") as! [String: Any]
    try refused("browser.click", transformedPoint)
    _ = try c.evaluate("document.querySelector('iframe').style.transform = 'none'; return true;")
    let inaccessiblePoint = try c.evaluate("const r = document.querySelectorAll('iframe')[1].getBoundingClientRect(); return { x: r.left + 4, y: r.top + 4 };") as! [String: Any]
    try refused("browser.click", inaccessiblePoint)
    try c.expect(try c.evaluate("return pickerHandlers.length") as? Int == 0, "blocked clicks must not schedule immediate or delayed picker handlers")
    let beforeCancel = nativeAttempts
    var cancelled: WorkspaceAPIService.Reply?
    c.f.api.dispatchAsync(agentId: c.f.agentId, requestId: UUID().uuidString, op: "browser.click",
        payload: ["tileId": c.tile, "ref": ref], isCancelled: { true }) { cancelled = $0 }
    let cancelledEnd = Date().addingTimeInterval(5)
    while cancelled == nil && Date() < cancelledEnd { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    if case .error? = cancelled {} else { throw WorkspaceAPIChecks.Failure(message: "cancelled click must fail") }
    try c.expect(nativeAttempts == beforeCancel, "cancelled click must not reach native dispatch")
    let beforeCustom = nativeAttempts
    _ = try c.raw("browser.click", ["ref": try c.ref("Custom")])
    try c.expect(nativeAttempts == beforeCustom + 1, "custom ARIA combobox must remain on its ordinary widget path")
    // An interrupted ordinary click is stopped at the native boundary by the
    // hook. No event or popup may survive it; this is pre-dispatch interruption.
    try c.expect(NSApp.windows.filter { $0.isVisible && !$0.frame.isEmpty && $0.alphaValue > 0 && !beforeWindows.contains($0.windowNumber) }.isEmpty,
        "refused and interrupted clicks must create no popup")
    _ = try c.call("browser.navigate", ["url": "about:blank"])
    let stale = try c.raw("browser.click", ["ref": ref])
    try c.expect(stale["status"] as? String == "error", "navigation must not dispatch into the retired select")
    c.f.browserEngine.shutdown()
    let closed = try c.raw("browser.click", ["ref": ref])
    try c.expect(closed["status"] as? String == "error", "teardown must reject native input")
    print("PASS: native select ref, coordinate, label, type, key and frame paths refuse before native dispatch; no popup survives the pre-dispatch interruption")
}
