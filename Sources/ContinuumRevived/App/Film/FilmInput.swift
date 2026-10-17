// Film harness: real input. Every mouse and key event a scene's `gesture`, `click
// {deliver}`, `key`, `hold` and `type` perform is a real NSEvent posted to the app's
// own event queue (`NSApp.postEvent`), so it takes the user's path end to end:
//
//  - dequeued by the run loop, so the app's local monitors see it (⌘K and ⌘1-⌘4, the
//    ⌥ leader, the tile focus monitor, the board's drag monitor, a popover's
//    click-away monitor: all of them are monitors, none is a view override);
//  - dispatched by `NSApplication.sendEvent`: a key event to the key window's first
//    responder, a mouse event to its window, where AppKit hit-tests the view;
//  - a view that runs its own tracking loop (an NSButton, a title-bar control) pulls
//    the rest of the gesture from the same queue while the director keeps stepping
//    on the main actor, because the main queue is serviced in tracking mode too.
//
// The director posts, then `settle()`s: it waits (bounded) until its own monitor has
// seen each posted event dequeued, or a sentinel posted behind them, so what a frame
// captures is what those events did.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ObjectiveC

@MainActor
final class FilmInput {
    /// `NSEvent.applicationDefined` subtype of the sentinel posted behind a batch.
    nonisolated static let sentinelSubtype: Int16 = 0x464C // "FL"
    private var monitor: Any?
    /// Timestamps of posted events not yet seen dequeued (each post gets a unique one).
    private var pending: Set<Double> = []
    /// Each `settle` posts a sentinel carrying its batch number behind the batch.
    private var batch = 0
    private var sentinelSeen = 0
    private var lastTimestamp: Double = 0
    let log: (String) -> Void
    private var warnedTimeout = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func install() {
        guard monitor == nil else { return }
        Self.acceptFirstMouseEverywhere()
        Self.routeMouseLocation()
        Self.routeKeyWindow()
        Self.routeConstraint()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
            let sentinel = event.type == .applicationDefined && event.subtype.rawValue == FilmInput.sentinelSubtype
            let stamp = event.timestamp, batch = sentinel ? event.data1 : 0
            let debug = ProcessInfo.processInfo.environment["FILM_INPUT_DEBUG"] != nil && !sentinel
            let line = debug ? "input: dequeued \(event.type.rawValue) win \(event.windowNumber) at \(event.locationInWindow) clicks \(event.type.rawValue <= 7 ? event.clickCount : 0) flags \(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)" : ""
            MainActor.assumeIsolated {
                if debug { self?.log(line + " key \(NSApp.keyWindow?.windowNumber ?? -1) active \(NSApp.isActive)") }
                self?.observe(stamp: stamp, sentinelBatch: sentinel ? batch : nil)
            }
            return sentinel ? nil : event
        }
    }

    /// The app is never active in a film (activating it would take the user's
    /// keyboard and menu bar), so it has no key window, and AppKit treats every press
    /// on a non-key window as an activation click: swallowed unless the view accepts
    /// the first mouse. A user's click lands in an active app, so in a film run every
    /// view accepts it — NSView's base answer, which views that override keep theirs.
    private static var acceptsFirstMouse = false
    static func acceptFirstMouseEverywhere() {
        guard !acceptsFirstMouse, FilmScene.isRequested,
              let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        acceptsFirstMouse = true
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    /// Film runs only: where the pointer is, in a window's own coordinates, for the
    /// windows the director owns (nil: ask AppKit). `NSWindow.mouseLocationOutsideOfEventStream`
    /// answers with it, so a view that re-derives hover from "where the mouse is" (the
    /// sidebar after every re-render) sees the film pointer, never the user's real one.
    static var pointerLocation: ((NSWindow) -> NSPoint?)?
    private static var routesMouseLocation = false
    static func routeMouseLocation() {
        guard !routesMouseLocation, FilmScene.isRequested else { return }
        let selector = #selector(getter: NSWindow.mouseLocationOutsideOfEventStream)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        routesMouseLocation = true
        typealias Getter = @convention(c) (NSWindow, Selector) -> NSPoint
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let routed: @convention(block) (NSWindow) -> NSPoint = { window in
            guard Thread.isMainThread else { return original(window, selector) }
            return MainActor.assumeIsolated { FilmInput.pointerLocation?(window) } ?? original(window, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(routed))
    }

    /// Film runs only: whether a window the director owns is key (nil: ask AppKit). The
    /// film depicts an ACTIVE app, but the process is never activated (that would take
    /// the user's keyboard), so AppKit never makes its window key. Everything that reads
    /// key-ness (tracking areas `.activeInKeyWindow`, the sidebar's hover, a table's
    /// click, selection colours) asks `isKeyWindow`, which answers with this.
    static var keyWindowOverride: ((NSWindow) -> Bool?)?
    private static var routesKeyWindow = false
    static func routeKeyWindow() {
        guard !routesKeyWindow, FilmScene.isRequested else { return }
        let selector = #selector(getter: NSWindow.isKeyWindow)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        routesKeyWindow = true
        typealias Getter = @convention(c) (NSWindow, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let routed: @convention(block) (NSWindow) -> Bool = { window in
            guard Thread.isMainThread else { return original(window, selector) }
            return MainActor.assumeIsolated { FilmInput.keyWindowOverride?(window) } ?? original(window, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(routed))
    }

    /// Film runs only: a panel the director parks beside the film window (Settings) is
    /// never constrained back onto a display. AppKit keeps part of every titled window on
    /// a screen; the film's panel must sit over the film window, wherever that is parked.
    static var keepsPanelsUnconstrained = false
    private static var routesConstraint = false
    static func routeConstraint() {
        guard !routesConstraint, FilmScene.isRequested else { return }
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        routesConstraint = true
        typealias Constrain = @convention(c) (NSWindow, Selector, NSRect, NSScreen?) -> NSRect
        let original = unsafeBitCast(method_getImplementation(method), to: Constrain.self)
        let routed: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { window, rect, screen in
            if window is NSPanel, Thread.isMainThread, MainActor.assumeIsolated({ FilmInput.keepsPanelsUnconstrained }) { return rect }
            return original(window, selector, rect, screen)
        }
        method_setImplementation(method, imp_implementationWithBlock(routed))
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A timestamp on the system-uptime clock (what AppKit stamps real events with),
    /// strictly increasing so each posted event is recognisable when dequeued.
    func nextTimestamp() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        lastTimestamp = max(now, lastTimestamp + 1e-6)
        return lastTimestamp
    }

    private func observe(stamp: Double, sentinelBatch: Int?) {
        if let sentinelBatch { sentinelSeen = max(sentinelSeen, sentinelBatch) } else { pending.remove(stamp) }
    }

    func post(_ event: NSEvent) {
        pending.insert(event.timestamp)
        NSApp.postEvent(event, atStart: false)
    }

    /// Waits until everything posted has been dequeued (and so dispatched), bounded:
    /// the monitor has seen each event, or the sentinel posted behind them (an event a
    /// monitor before ours consumed, like ⌘K, is still behind it in the queue).
    func settle(timeout: TimeInterval = 1.0) async {
        guard !pending.isEmpty else { return }
        batch += 1
        let mine = batch
        if let sentinel = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: nextTimestamp(), windowNumber: 0, context: nil,
                                             subtype: Self.sentinelSubtype, data1: mine, data2: 0) {
            NSApp.postEvent(sentinel, atStart: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !(pending.isEmpty || sentinelSeen >= mine), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !(pending.isEmpty || sentinelSeen >= mine), !warnedTimeout {
            warnedTimeout = true
            log("WARN input: \(pending.count) posted event(s) not dequeued after \(timeout)s (a modal loop?)")
        }
        pending.removeAll()
        // Dispatch follows dequeue in the same run-loop pass; one more turn for it.
        for _ in 0..<3 { await Task.yield() }
    }

    // MARK: Mouse

    /// The app's window under a SCREEN point, front to back: the main window's
    /// visible child windows (popovers, panels) above it, then the main window.
    static func window(atScreen point: CGPoint, main: NSWindow) -> NSWindow? {
        let children = (main.childWindows ?? []).reversed().filter { $0.isVisible && !$0.ignoresMouseEvents }
        if let hit = children.first(where: { $0.frame.contains(point) }) { return hit }
        return main.frame.contains(point) ? main : nil
    }

    func mouseEvent(_ type: NSEvent.EventType, screenPoint: CGPoint, window: NSWindow, clickCount: Int,
                    modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        let location = window.convertPoint(fromScreen: screenPoint)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                  timestamp: nextTimestamp(), windowNumber: window.windowNumber, context: nil,
                                  eventNumber: Int(lastTimestamp * 1000) & 0x3FFFFFFF, clickCount: clickCount,
                                  pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1)
    }

    // MARK: Tracking areas

    /// Tracking areas the film pointer is inside (by area), for enter/exit transitions.
    private var insideAreas: [ObjectIdentifier: NSTrackingArea] = [:]

    /// What the window server does for a real pointer and cannot do for a posted event:
    /// every tracking area in `window` gets its `mouseEntered` / `mouseMoved` /
    /// `mouseExited` as the film pointer crosses and moves inside it (rect-based, as
    /// AppKit's tracking is; `.inVisibleRect` areas use the view's visible rect). The
    /// film window counts as key and its app as active (`keyWindowOverride`), so every
    /// activity option applies except `.activeWhenFirstResponder` off the first responder.
    func dispatchTracking(_ moved: NSEvent, in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        let point = moved.locationInWindow
        var current: [ObjectIdentifier: (NSTrackingArea, NSView)] = [:]
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            for area in view.trackingAreas {
                if area.options.contains(.activeWhenFirstResponder), window.firstResponder !== view { continue }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                if rect.contains(view.convert(point, from: nil)) { current[ObjectIdentifier(area)] = (area, view) }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        func enterExit(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.enterExitEvent(with: type, location: point, modifierFlags: moved.modifierFlags, timestamp: moved.timestamp,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        for (id, area) in insideAreas where current[id] == nil {
            insideAreas.removeValue(forKey: id)
            if area.options.contains(.mouseEnteredAndExited), let event = enterExit(.mouseExited) {
                (area.owner as? NSResponder)?.mouseExited(with: event)
            }
        }
        for (id, (area, _)) in current.sorted(by: { $0.key.hashValue < $1.key.hashValue }) {
            if insideAreas[id] == nil {
                insideAreas[id] = area
                if area.options.contains(.mouseEnteredAndExited), let event = enterExit(.mouseEntered) {
                    (area.owner as? NSResponder)?.mouseEntered(with: event)
                }
            }
            if area.options.contains(.mouseMoved) { (area.owner as? NSResponder)?.mouseMoved(with: moved) }
        }
    }

    // MARK: Scroll

    /// A pixel scroll-wheel event at a screen point, as a wheel delivers it: positive `dy`
    /// moves the content down (towards the top), negative reveals what is further down.
    func scrollEvent(dx: Int32, dy: Int32, screenPoint: CGPoint, window: NSWindow,
                     modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screenPoint.x, y: primary - screenPoint.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        cg.timestamp = CGEventTimestamp(nextTimestamp() * 1_000_000_000)
        return NSEvent(cgEvent: cg)
    }

    // MARK: Keys

    struct Key: Sendable {
        var code: UInt16
        var characters: String
        var ignoringModifiers: String
        var shift = false
        /// What the key-cap overlay draws (without modifiers).
        var cap: String
    }

    nonisolated static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "shift": .shift, "option": .option, "alt": .option,
        "control": .control, "ctrl": .control,
    ]
    nonisolated static let modifierKeyCodes: [NSEvent.ModifierFlags.RawValue: UInt16] = [
        NSEvent.ModifierFlags.command.rawValue: 55, NSEvent.ModifierFlags.shift.rawValue: 56,
        NSEvent.ModifierFlags.option.rawValue: 58, NSEvent.ModifierFlags.control.rawValue: 59,
    ]

    nonisolated static func modifiers(_ names: [String]?) -> NSEvent.ModifierFlags? {
        var flags: NSEvent.ModifierFlags = []
        for name in names ?? [] {
            guard let flag = modifierNames[name.lowercased()] else { return nil }
            flags.insert(flag)
        }
        return flags
    }

    /// ⌃⌥⇧⌘, Apple's order.
    nonisolated static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    nonisolated private static let named: [String: (UInt16, Int, String)] = [
        // name: (virtual key code, character scalar, cap)
        "return": (36, 0x0D, "Return"), "enter": (76, 0x03, "Enter"), "tab": (48, 0x09, "Tab"),
        "space": (49, 0x20, "Space"), "delete": (51, 0x7F, "Delete"), "backspace": (51, 0x7F, "Delete"),
        "escape": (53, 0x1B, "Esc"), "esc": (53, 0x1B, "Esc"),
        "up": (126, 0xF700, "↑"), "down": (125, 0xF701, "↓"), "left": (123, 0xF702, "←"), "right": (124, 0xF703, "→"),
        "home": (115, 0xF729, "Home"), "end": (119, 0xF72B, "End"), "pageup": (116, 0xF72C, "Page Up"),
        "pagedown": (121, 0xF72D, "Page Down"), "forwarddelete": (117, 0xF728, "⌦"),
    ]

    /// US-ANSI virtual key codes for the printable characters.
    nonisolated private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]
    nonisolated private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]

    /// A named key ("Return", "Escape", "up"...) or one character ("k", "3", "K").
    nonisolated static func key(named name: String) -> Key? {
        if let (code, scalar, cap) = named[name.lowercased()] {
            let text = String(Character(Unicode.Scalar(UInt32(scalar))!))
            return Key(code: code, characters: text, ignoringModifiers: text, cap: cap)
        }
        guard name.count == 1, let character = name.first else { return nil }
        return key(for: character)
    }

    /// The key that types `character` (shift for capitals and shifted symbols).
    nonisolated static func key(for character: Character) -> Key? {
        if character == "\n" || character == "\r" { return key(named: "return") }
        if character == "\t" { return key(named: "tab") }
        let lower = Character(character.lowercased())
        if let code = codes[lower] {
            let shift = character.isUppercase
            return Key(code: code, characters: String(character), ignoringModifiers: String(lower), shift: shift,
                       cap: character == " " ? "Space" : String(character).uppercased())
        }
        if let base = shifted[character], let code = codes[base] {
            return Key(code: code, characters: String(character), ignoringModifiers: String(base), shift: true,
                       cap: String(character))
        }
        // Anything else (é, emoji): no physical key; delivered with code 0 and its text.
        return Key(code: 0, characters: String(character), ignoringModifiers: String(character), cap: String(character))
    }

    func keyEvent(_ type: NSEvent.EventType, key: Key, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        var flags = modifiers
        if key.shift { flags.insert(.shift) }
        // ⌘/⌃ chords carry the unshifted character as AppKit's own events do.
        let characters = flags.contains(.command) || flags.contains(.control) ? key.ignoringModifiers : key.characters
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: nextTimestamp(),
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: key.ignoringModifiers, isARepeat: false, keyCode: key.code)
    }

    /// A modifier transition: `flags` is the state AFTER it, `code` the modifier key.
    func flagsEvent(code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: nextTimestamp(),
                         windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)
    }
}
#endif
