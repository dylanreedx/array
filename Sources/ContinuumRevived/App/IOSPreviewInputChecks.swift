import AppKit

/// Uses the production-mounted surface and its transport recorder. The window
/// stays hidden, and no global input, clipboard, simulator or app activation is used.
@MainActor
enum IOSPreviewInputChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw IOSPreviewChecks.Failure(description: message) }
    }
    static func run(view: IOSPreviewTileNSView, session: IOSPreviewChecks.Session) throws {
        guard let window = view.window else { throw IOSPreviewChecks.Failure(description: "input witness requires the production-mounted window") }
        let screen = view.screen
        let start = session.messages.count
        func key(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0)!
        }
        func keyEvents(since index: Int) -> [(String, Int)] {
            session.messages.dropFirst(index).compactMap { tag, payload in
                guard tag == 6, let type = payload["type"] as? String, let usage = payload["usage"] as? Int else { return nil }
                return (type, usage)
            }
        }
        screen.releaseInput()
        // Shift was held before the click: no flagsChanged arrives at this view.
        screen.keyDown(with: key(.keyDown, flags: .shift))
        let synchronized = keyEvents(since: start)
        try expect(synchronized.count == 2 && synchronized[0].0 == "down" && synchronized[0].1 == 225 &&
                   synchronized[1].0 == "down" && synchronized[1].1 == 4,
                   "typing with Shift held before focus must press Shift before the ordinary key")
        screen.releaseInput()
        let rect = screen.screenRect
        let point = screen.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        screen.mouseDown(with: down)
        screen.keyDown(with: key(.keyDown, flags: .shift))
        try expect(window.firstResponder === screen, "the screen must own native focus before testing window deactivation")
        let held = session.messages.count
        // AppKit can keep the same first responder across this real lifecycle
        // notification; the notification observer, rather than a responder swap,
        // must end the held touch and release both kinds of keys.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let released = Array(session.messages.dropFirst(held))
        let releasedKeys = keyEvents(since: held)
        try expect(window.firstResponder === screen, "window deactivation must be tested without resignFirstResponder")
        try expect(released.count == 3 && released.contains { $0.0 == 3 && $0.1["type"] as? String == "end" } &&
                   releasedKeys.contains { $0.0 == "up" && $0.1 == 4 } &&
                   releasedKeys.contains { $0.0 == "up" && $0.1 == 225 },
                   "losing window key status must release the held touch, ordinary key and modifier")
        let alreadyReleased = session.messages.count
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try expect(session.messages.count == alreadyReleased, "repeated focus-loss notifications must not emit unmatched input releases")
        screen.keyDown(with: key(.keyDown, flags: .command))
        let appHeld = session.messages.count
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        let appReleased = keyEvents(since: appHeld)
        try expect(appReleased.count == 2 && appReleased.contains { $0.0 == "up" && $0.1 == 4 } &&
                   appReleased.contains { $0.0 == "up" && $0.1 == 227 },
                   "application deactivation must release ordinary and modifier keys even while its window remains mounted")
        let clean = session.messages.count
        screen.keyUp(with: key(.keyUp))
        try expect(session.messages.count == clean, "key-up arriving after focus-loss cleanup must not emit a second release")
        print("IOSPreviewInputChecks passed: pre-held modifiers, window/app deactivation releases, touch cleanup and duplicate-release suppression")
    }
}
