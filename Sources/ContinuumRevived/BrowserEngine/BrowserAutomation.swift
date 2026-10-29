import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

// Driving a browser tile for an agent (`.plans/80-browser-computer-use`, S2).
// This is the engine only: it knows nothing about agents, grants or leases.
// The workspace API (S3) owns those and calls in here.
//
// Three rules from the S0 probes (`research/wkwebview-feasibility.md`):
// - Input is an `NSEvent` handed straight to the web view's `mouseDown` /
//   `keyDown`. The page sees trusted events, the window need not be key, and
//   `window.sendEvent` is avoided because it misses at 2x canvas zoom. It
//   never passes `NSApp.sendEvent`, so Array's own monitors never mistake an
//   agent's click for the user.
// - Typing starts with a real click on the field. A field focused from script
//   either drops the keys or takes first responder away from the user.
// - The page outline is read in an isolated content world, so the page cannot
//   see the reader or change what it reports.

enum BrowserAutomationError: Error, Equatable, CustomStringConvertible {
    case notLive
    case staleRef(String)
    case notVisible(String)
    case covered(target: String, by: String)
    case notEditable(String)
    case focusRefused(String)
    case userTyping
    case unknownKey(String)
    case timedOut(String, throttled: Bool)
    case script(String)

    /// Every message names the next step, because the reader is a model.
    var description: String {
        switch self {
        case .notLive:
            return "This browser tile isn't on the canvas right now, so it can't take clicks or keys. Reveal it, or reload it."
        case .staleRef(let ref):
            return "\(ref) is no longer on the page. Take a fresh snapshot and use its tags."
        case .notVisible(let what):
            return "\(what) has no size on the page, so it can't be clicked. Take a fresh snapshot."
        case .covered(let target, let cover):
            return "\(target) is covered by \(cover), so a click would land on that instead. Close or click the covering element first, or click by coordinates."
        case .notEditable(let what):
            return "\(what) is not a text field. Type into a textbox, or use press_key."
        case .focusRefused(let what):
            return "Clicking \(what) did not focus it, so nothing was typed. Take a fresh snapshot and check what took focus."
        case .userTyping:
            return "The user is typing or took control of this browser. Wait, then take a fresh snapshot."
        case .unknownKey(let key):
            return "\(key) is not a key this tool knows. Use names like Enter, Tab, Escape, Backspace, ArrowDown, or one character, with Shift+, Control+, Alt+ or Meta+."
        case .timedOut(let what, let throttled):
            return "Timed out \(what)." + (throttled ? " Array is hidden or this tile is parked, so the page is throttled to about one timer tick a second." : "")
        case .script(let message):
            return "The page script failed: \(message)"
        }
    }
}

struct BrowserAutomationOutcome {
    /// One line: what happened.
    var summary: String
    var url: String
    var title: String
    /// Outline lines that appeared (`+ `) or went (`- `) since the last
    /// snapshot or action. Nil when there was no snapshot to compare with or
    /// the page navigated, which both mean "take a snapshot".
    var changes: [String]?
    var dialogs: [String]
    var consoleErrors: [String]
    /// The field's value after typing, passwords masked.
    var value: String?
}

struct BrowserAutomationSnapshot {
    var text: String
    var generation: Int
    var url: String
    var title: String
    /// What the byte cap cut, in the order it was cut. Empty when nothing was.
    var cut: [String]
}

struct BrowserAutomationScreenshot {
    var png: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

@MainActor
final class BrowserAutomation {
    static let world = WKContentWorld.world(name: "array.automation")
    static let snapshotByteCap = 20_000
    static let screenshotMaxPixelWidth = 1_280
    static let evaluateResultCap = 64 * 1_024
    /// A type waits this long after the user's last key in the tile.
    static let userTypingQuiet: TimeInterval = 1.0
    static let maxWait: TimeInterval = 30

    private weak var runtime: WKWebViewBrowserRuntime?
    private let webView: WKWebView
    /// Set by the owner while an agent drives this tile. Dialogs and file
    /// choosers are then answered here instead of opening a sheet nobody
    /// is watching.
    var isEngaged = false
    private(set) var generation = 0
    /// Bumped by every real mouse-down or key-down the user makes in this
    /// tile. S3's takeover rule reads it.
    private(set) var userInputCount = 0
    var onUserInput: (() -> Void)?
    var onAgentClick: ((NSPoint) -> Void)?
    var _screenshotStarted: (() -> Void)?
    private(set) var lastUserKeyAt: Date?
    private var inputSurfaceIds: Set<ObjectIdentifier> = []
    private var agentDeliveryDepth = 0
    private struct AgentInputFingerprint: Hashable {
        let type: NSEvent.EventType
        let timestamp: TimeInterval
        let windowNumber: Int
        let keyCode: UInt16?
    }
    private var agentInputFingerprints: [AgentInputFingerprint] = []
    private var lastOutline: Set<String>?
    private var outlineURL: String?
    private var dialogs: [String] = []
    private var snapshotConsoleMark = 0
    private var wasHidden = false

    init(runtime: WKWebViewBrowserRuntime) {
        self.runtime = runtime
        self.webView = runtime.webView
        snapshotConsoleMark = runtime.consoleEntrySequence
        Self.register(self)
    }

    func detach() {
        Self.registry[ObjectIdentifier(webView)] = nil
        for id in inputSurfaceIds where Self.registry[id]?.engine === self { Self.registry[id] = nil }
        inputSurfaceIds.removeAll()
        onUserInput = nil
        onAgentClick = nil
        _screenshotStarted = nil
        for fingerprint in agentInputFingerprints where Self.syntheticInputs[fingerprint]?.engine === self {
            Self.syntheticInputs[fingerprint] = nil
        }
        agentInputFingerprints.removeAll()
        isEngaged = false
    }

    /// Include the tile chrome as well as the web view in takeover detection.
    func trackInputSurface(_ surface: NSView) {
        let id = ObjectIdentifier(surface)
        inputSurfaceIds.insert(id)
        Self.registry[id] = WeakEngine(engine: self)
    }

    // MARK: - Reading the page

    func snapshot(deadline: Date) async throws -> BrowserAutomationSnapshot {
        let raw = try await world("outline", [:], deadline: deadline)
        let lines = Self.outlineLines(raw)
        generation += 1
        lastOutline = Set(lines.map(\.text))
        outlineURL = raw["url"] as? String
        let url = raw["url"] as? String ?? ""
        let title = raw["title"] as? String ?? ""
        let console = consoleErrors(since: snapshotConsoleMark)
        snapshotConsoleMark = runtime?.consoleEntrySequence ?? 0
        return Self.compose(
            url: url, title: title, generation: generation, lines: lines,
            elementCapHit: raw["cut"] as? Bool ?? false,
            console: console, dialogs: drainDialogs()
        )
    }

    func screenshot(ref: String? = nil, deadline: Date) async throws -> BrowserAutomationScreenshot {
        let configuration = WKSnapshotConfiguration()
        var pointWidth = webView.bounds.width
        if let ref {
            let target = try await world("target", ["ref": ref], deadline: deadline)
            try Self.requireTarget(target, ref: ref, mustLand: false)
            let rect = target["rect"] as? [String: Any] ?? [:]
            let zoom = webView.pageZoom
            let x = Self.double(rect["x"]) * zoom, y = Self.double(rect["y"]) * zoom
            let w = Self.double(rect["w"]) * zoom, h = Self.double(rect["h"]) * zoom
            let viewRect = CGRect(x: x, y: webView.isFlipped ? y : webView.bounds.height - y - h, width: w, height: h)
                .intersection(webView.bounds)
            guard !viewRect.isNull, viewRect.width >= 1, viewRect.height >= 1 else {
                throw BrowserAutomationError.notVisible(target["what"] as? String ?? ref)
            }
            configuration.rect = viewRect
            pointWidth = viewRect.width
        }
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        configuration.snapshotWidth = NSNumber(value: Double(min(pointWidth, CGFloat(Self.screenshotMaxPixelWidth) / scale)))
        _screenshotStarted?()
        let image = try await takeSnapshot(configuration, deadline: deadline)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserAutomationError.script("the snapshot had no bitmap")
        }
        let box = ImageBox(image: cgImage)
        let maxWidth = Self.screenshotMaxPixelWidth
        let encoded = await Task.detached(priority: .userInitiated) { Self.encodePNG(box.image, maxWidth: maxWidth) }.value
        guard let encoded else { throw BrowserAutomationError.script("the snapshot could not be encoded") }
        return encoded
    }

    /// Runs `function` (JavaScript function source, e.g. `() => document.title`)
    /// in the PAGE world and returns its result as JSON text.
    func evaluate(_ function: String, deadline: Date) async throws -> String {
        let body = "const f = (\n\(function)\n);\nconst v = await (typeof f === 'function' ? f() : f);\nreturn JSON.stringify(v === undefined ? null : v);"
        let value = try await callJavaScript(body, arguments: [:], world: .page, deadline: deadline, what: "waiting for the script")
        let json = value as? String ?? "null"
        guard json.utf8.count <= Self.evaluateResultCap else {
            throw BrowserAutomationError.script("the result is \(json.utf8.count) bytes, over the \(Self.evaluateResultCap / 1_024) KB cap. Return less.")
        }
        return json
    }

    // MARK: - Acting

    func click(ref: String, doubleClick: Bool = false, deadline: Date) async throws -> BrowserAutomationOutcome {
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            let target = try await self.world("target", ["ref": ref], deadline: deadline)
            try Self.requireTarget(target, ref: ref, mustLand: true)
            try await self.settleIfRevealed()
            try self.requireInputControl(inputAtStart, deadline: deadline)
            self.deliverClick(cssX: Self.double(target["x"]), cssY: Self.double(target["y"]), window: window, count: doubleClick ? 2 : 1)
            return ("Clicked \(target["what"] as? String ?? ref)", nil)
        }
    }

    func click(x: Double, y: Double, doubleClick: Bool = false, deadline: Date) async throws -> BrowserAutomationOutcome {
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            let hit = try await self.world("at", ["x": x, "y": y], deadline: deadline)
            try await self.settleIfRevealed()
            try self.requireInputControl(inputAtStart, deadline: deadline)
            self.deliverClick(cssX: x, cssY: y, window: window, count: doubleClick ? 2 : 1)
            return ("Clicked at \(Int(x)),\(Int(y)), on \(hit["what"] as? String ?? "nothing")", nil)
        }
    }

    /// Types `text` into the field tagged `ref`, or into whatever has focus
    /// when `ref` is nil. `clear` replaces the field's contents; `submit`
    /// presses Enter afterwards.
    func type(_ text: String, ref: String?, clear: Bool = false, submit: Bool = false, deadline: Date) async throws -> BrowserAutomationOutcome {
        try await waitForUserQuiet(deadline: deadline)
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            let responder = window.firstResponder
            defer { if self.userInputCount == inputAtStart { self.restore(responder, in: window) } }
            var what = "the focused element"
            if let ref {
                let target = try await self.world("target", ["ref": ref], deadline: deadline)
                try Self.requireTarget(target, ref: ref, mustLand: true)
                what = target["what"] as? String ?? ref
                guard target["editable"] as? Bool == true else { throw BrowserAutomationError.notEditable(what) }
                try await self.settleIfRevealed()
                try self.requireInputControl(inputAtStart, deadline: deadline)
                self.deliverClick(cssX: Self.double(target["x"]), cssY: Self.double(target["y"]), window: window, count: 1)
                try await self.pause(0.05, deadline: deadline)
                let focus = try await self.world("focusedIs", ["ref": ref], deadline: deadline)
                guard focus["focused"] as? Bool == true else { throw BrowserAutomationError.focusRefused(what) }
                if clear {
                    try self.requireInputControl(inputAtStart, deadline: deadline)
                    _ = try await self.world("select", ["ref": ref], deadline: deadline)
                }
            }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            if clear && text.isEmpty { self.deliverKey(Self.namedKeys["Backspace"]!, flags: [], window: window) }
            for character in text {
                try self.requireInputControl(inputAtStart, deadline: deadline)
                self.deliverCharacter(character, window: window)
                // WebKit consumes trusted input asynchronously. A small yield
                // keeps long bursts from losing keys and lets user input win.
                try await self.pause(0.005, deadline: deadline)
            }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            if submit { self.deliverKey(Self.namedKeys["Enter"]!, flags: [], window: window) }
            var value: String?
            if let ref {
                try await self.pause(0.1, deadline: deadline)
                value = try await self.world("focusedIs", ["ref": ref], deadline: deadline)["value"] as? String
            }
            let count = text.count
            return ("Typed \(count) character\(count == 1 ? "" : "s") into \(what)" + (submit ? " and pressed Enter" : ""), value)
        }
    }

    /// `combo` is a key name or one character, optionally with modifiers:
    /// `Enter`, `Shift+Tab`, `ArrowDown`, `Control+a`.
    func pressKey(_ combo: String, deadline: Date) async throws -> BrowserAutomationOutcome {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if combo.hasSuffix("++") || combo == "+" { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = parts.last, !keyName.isEmpty else { throw BrowserAutomationError.unknownKey(combo) }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "alt", "option": flags.insert(.option)
            case "meta", "cmd", "command", "controlormeta": flags.insert(.command)
            default: throw BrowserAutomationError.unknownKey(combo)
            }
        }
        let key: Key
        if let named = Self.namedKeys[keyName] {
            key = named
        } else if keyName.count == 1, let character = keyName.first {
            key = Self.characterKey(character)
        } else {
            throw BrowserAutomationError.unknownKey(combo)
        }
        try await waitForUserQuiet(deadline: deadline)
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            let responder = window.firstResponder
            defer { self.restore(responder, in: window) }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            // A Cmd+A key event selects nothing in a web view (probe p2); the
            // responder action does.
            if flags == .command, keyName.lowercased() == "a" {
                self.webView.selectAll(nil)
            } else {
                self.deliverKey(key, flags: flags, window: window)
            }
            return ("Pressed \(combo)", nil)
        }
    }

    func scroll(ref: String? = nil, dx: Double = 0, dy: Double = 0, deadline: Date) async throws -> BrowserAutomationOutcome {
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            try self.requireInputControl(inputAtStart, deadline: deadline)
            var arguments: [String: Any] = ["dx": dx, "dy": dy]
            if let ref { arguments["ref"] = ref }
            let result = try await self.world("scroll", arguments, deadline: deadline)
            if result["stale"] as? Bool == true, let ref { throw BrowserAutomationError.staleRef(ref) }
            let position = "the page is at \(Int(Self.double(result["scrollX"]))),\(Int(Self.double(result["scrollY"])))"
            if let what = result["what"] as? String { return ("Scrolled \(what) into view; \(position)", nil) }
            return ("Scrolled by \(Int(dx)),\(Int(dy)); \(position)", nil)
        }
    }

    enum WaitCondition {
        case textAppears(String), textGone(String), refAppears(String), refGone(String), idle
    }

    /// Polls from here on a wall clock rather than from page timers, which a
    /// hidden Array throttles to about one tick a second (S0 probe c).
    func waitFor(_ condition: WaitCondition, timeout: TimeInterval, deadline: Date) async throws -> BrowserAutomationOutcome {
        let start = Date()
        let end = min(deadline, start.addingTimeInterval(min(timeout, Self.maxWait)))
        var arguments: [String: Any] = [:]
        let label: String
        switch condition {
        case .textAppears(let text): arguments["text"] = text; label = "text \"\(text)\" to appear"
        case .textGone(let text): arguments["text"] = text; label = "text \"\(text)\" to go"
        case .refAppears(let ref): arguments["ref"] = ref; label = "\(ref) to appear"
        case .refGone(let ref): arguments["ref"] = ref; label = "\(ref) to go"
        case .idle: label = "the page to settle"
        }
        return try await act(deadline: deadline) {
            while true {
                let probe = try await self.world("probe", arguments, deadline: end)
                let met: Bool
                switch condition {
                case .textAppears: met = probe["text"] as? Bool == true
                case .textGone: met = probe["text"] as? Bool == false
                case .refAppears: met = probe["ref"] as? Bool == true
                case .refGone: met = probe["ref"] as? Bool == false
                case .idle:
                    met = !self.webView.isLoading && probe["ready"] as? Bool == true && Self.double(probe["quietMs"]) >= 500
                }
                if met {
                    return (String(format: "Waited %.1f s for %@", Date().timeIntervalSince(start), label), nil)
                }
                guard Date().addingTimeInterval(0.1) < end else {
                    throw BrowserAutomationError.timedOut("waiting for \(label)", throttled: self.isThrottled)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    // MARK: - Dialogs while engaged

    /// The runtime's UI delegate hands dialogs here while an agent drives the
    /// tile. Each is dismissed the way Playwright does by default and reported
    /// with the next reply.
    func noteDialog(_ kind: String, message: String, answer: String) {
        dialogs.append("\(kind) \"\(Self.clip(message, 200))\": \(answer)")
    }

    private func drainDialogs() -> [String] {
        defer { dialogs.removeAll() }
        return dialogs
    }

    // MARK: - The action frame

    private func act(
        deadline: Date,
        _ body: () async throws -> (summary: String, value: String?)
    ) async throws -> BrowserAutomationOutcome {
        let consoleMark = runtime?.consoleEntrySequence ?? 0
        let urlBefore = webView.url?.absoluteString
        let result = try await body()
        try? await settle(deadline: deadline)
        let url = webView.url?.absoluteString ?? runtime?.url ?? ""
        var changes: [String]?
        if url == urlBefore, url == outlineURL, lastOutline != nil {
            changes = try? await outlineChanges(deadline: deadline)
        }
        var summary = result.summary
        if url != urlBefore { summary += ". The page is now \(url); take a snapshot" }
        return BrowserAutomationOutcome(
            summary: summary, url: url, title: webView.title ?? "",
            changes: changes, dialogs: drainDialogs(),
            consoleErrors: consoleErrors(since: consoleMark), value: result.value
        )
    }

    /// Lets the page react, then waits out a navigation the action started.
    private func settle(deadline: Date) async throws {
        try await pause(0.12, deadline: deadline)
        let loadEnd = min(deadline, Date().addingTimeInterval(5))
        while webView.isLoading, Date() < loadEnd {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func outlineChanges(deadline: Date) async throws -> [String] {
        let raw = try await world("outline", [:], deadline: deadline)
        let lines = Self.outlineLines(raw).map(\.text)
        let previous = lastOutline ?? []
        let now = Set(lines)
        lastOutline = now
        var seen = Set<String>()
        var changes = lines.filter { !previous.contains($0) && seen.insert($0).inserted }.map { "+ " + $0 }
        changes += previous.subtracting(now).sorted().map { "- " + $0 }
        if changes.count > 40 {
            let more = changes.count - 40
            changes = Array(changes.prefix(40)) + ["… and \(more) more; take a snapshot"]
        }
        return changes
    }

    private func consoleErrors(since mark: Int) -> [String] {
        guard let runtime else { return [] }
        let fresh = min(max(runtime.consoleEntrySequence - mark, 0), runtime.consoleLogEntries.count)
        let errors = runtime.consoleLogEntries.suffix(fresh).filter { $0.level == .error }.map { Self.clip($0.message, 300) }
        guard errors.count > 10 else { return errors }
        return Array(errors.suffix(10)) + ["… \(errors.count - 10) earlier errors not shown"]
    }

    // MARK: - Input delivery

    private func requireInputControl(_ inputAtStart: Int, deadline: Date) throws {
        guard userInputCount == inputAtStart else { throw BrowserAutomationError.userTyping }
        guard Date() < deadline else { throw BrowserAutomationError.timedOut("before sending browser input", throttled: isThrottled) }
    }

    private func liveWindow() throws -> NSWindow {
        guard let runtime, !runtime.isTerminated, let window = webView.window else { throw BrowserAutomationError.notLive }
        return window
    }

    /// A tile that just left a hidden parent needs a moment before input: a
    /// probe click sent straight after registered nothing.
    private func settleIfRevealed() async throws {
        let hidden = webView.isHiddenOrHasHiddenAncestor
        defer { wasHidden = hidden }
        if wasHidden && !hidden { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func deliverClick(cssX: Double, cssY: Double, window: NSWindow, count: Int) {
        agentDeliveryDepth += 1
        defer { agentDeliveryDepth -= 1 }
        let zoom = webView.pageZoom
        let local = NSPoint(x: cssX * zoom, y: webView.isFlipped ? cssY * zoom : webView.bounds.height - cssY * zoom)
        let point = webView.convert(local, to: nil)
        let responder = window.firstResponder
        for clickCount in 1...count {
            let down = Self.mouseEvent(.leftMouseDown, at: point, window: window, clickCount: clickCount)
            rememberAgentInput(down)
            webView.mouseDown(with: down)
            webView.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: point, window: window, clickCount: clickCount))
        }
        restore(responder, in: window)
        onAgentClick?(local)
    }

    private func restore(_ responder: NSResponder?, in window: NSWindow) {
        if window.firstResponder !== responder { window.makeFirstResponder(responder) }
    }

    private func deliverCharacter(_ character: Character, window: NSWindow) {
        switch character {
        case "\n", "\r", "\r\n": deliverKey(Self.namedKeys["Enter"]!, flags: [], window: window)
        case "\t": deliverKey(Self.namedKeys["Tab"]!, flags: [], window: window)
        default: deliverKey(Self.characterKey(character), flags: [], window: window)
        }
    }

    private func deliverKey(_ key: Key, flags: NSEvent.ModifierFlags, window: NSWindow) {
        agentDeliveryDepth += 1
        defer { agentDeliveryDepth -= 1 }
        var flags = flags.union(key.flags)
        if key.shifted { flags.insert(.shift) }
        let characters = flags.contains(.shift) && key.characters.count == 1 ? key.characters.uppercased() : key.characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: key.ignoringModifiers,
                isARepeat: false, keyCode: key.code
            ) else { continue }
            if type == .keyDown { rememberAgentInput(event) }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func rememberAgentInput(_ event: NSEvent) {
        let expired = agentInputFingerprints.filter { event.timestamp - $0.timestamp > 5 }
        for fingerprint in expired where Self.syntheticInputs[fingerprint]?.engine === self { Self.syntheticInputs[fingerprint] = nil }
        agentInputFingerprints.removeAll { event.timestamp - $0.timestamp > 5 }
        let fingerprint = Self.fingerprint(event)
        agentInputFingerprints.append(fingerprint)
        Self.syntheticInputs[fingerprint] = WeakEngine(engine: self)
        while agentInputFingerprints.count > 256 {
            let oldest = agentInputFingerprints.removeFirst()
            if Self.syntheticInputs[oldest]?.engine === self { Self.syntheticInputs[oldest] = nil }
        }
    }

    private static func fingerprint(_ event: NSEvent) -> AgentInputFingerprint {
        AgentInputFingerprint(type: event.type, timestamp: event.timestamp, windowNumber: event.windowNumber,
                              keyCode: event.type == .keyDown ? event.keyCode : nil)
    }

    private static func consumeAgentInput(_ event: NSEvent) -> Bool {
        let fingerprint = fingerprint(event)
        guard let owner = syntheticInputs.removeValue(forKey: fingerprint)?.engine else { return false }
        owner.agentInputFingerprints.removeAll { $0 == fingerprint }
        return true
    }

    struct Key {
        var code: UInt16
        var characters: String
        var ignoringModifiers: String
        var flags: NSEvent.ModifierFlags = []
        var shifted = false
    }

    private static func functionKey(_ code: UInt16, _ scalar: Int, arrow: Bool = false) -> Key {
        let text = String(Character(UnicodeScalar(scalar)!))
        return Key(code: code, characters: text, ignoringModifiers: text, flags: arrow ? [.numericPad, .function] : [.function])
    }

    static let namedKeys: [String: Key] = [
        "Enter": Key(code: 36, characters: "\r", ignoringModifiers: "\r"),
        "Tab": Key(code: 48, characters: "\t", ignoringModifiers: "\t"),
        "Escape": Key(code: 53, characters: "\u{1b}", ignoringModifiers: "\u{1b}"),
        "Backspace": Key(code: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}"),
        "Space": Key(code: 49, characters: " ", ignoringModifiers: " "),
        "Delete": functionKey(117, NSDeleteFunctionKey),
        "ArrowUp": functionKey(126, NSUpArrowFunctionKey, arrow: true),
        "ArrowDown": functionKey(125, NSDownArrowFunctionKey, arrow: true),
        "ArrowLeft": functionKey(123, NSLeftArrowFunctionKey, arrow: true),
        "ArrowRight": functionKey(124, NSRightArrowFunctionKey, arrow: true),
        "Home": functionKey(115, NSHomeFunctionKey),
        "End": functionKey(119, NSEndFunctionKey),
        "PageUp": functionKey(116, NSPageUpFunctionKey),
        "PageDown": functionKey(121, NSPageDownFunctionKey),
    ]

    /// US-layout key codes, so a page reading `event.code` sees the key a
    /// person would have pressed. Characters off this table still type; their
    /// `code` is just not meaningful.
    private static let usKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]

    static func characterKey(_ character: Character) -> Key {
        let text = String(character)
        let lower = Character(text.lowercased())
        let isUpper = character.isUppercase && lower != character
        return Key(code: usKeyCodes[lower] ?? 0, characters: text, ignoringModifiers: String(lower), shifted: isUpper)
    }

    // MARK: - The user's own input in this tile

    private struct WeakEngine { weak var engine: BrowserAutomation? }
    private static var registry: [ObjectIdentifier: WeakEngine] = [:]
    private static var syntheticInputs: [AgentInputFingerprint: WeakEngine] = [:]
    private static var monitor: Any?

    private static func register(_ engine: BrowserAutomation) {
        registry[ObjectIdentifier(engine.webView)] = WeakEngine(engine: engine)
        guard monitor == nil else { return }
        // One monitor for every engine. It sees only events that pass
        // `NSApp.sendEvent`, which an engine's own direct delivery never does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { BrowserAutomation.noteUserEvent(event) }
            return event
        }
    }

    private static func noteUserEvent(_ event: NSEvent) {
        guard !registry.isEmpty else { return }
        if consumeAgentInput(event) { return }
        guard let window = event.window else { return }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else if let content = window.contentView {
            view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        }
        while let current = view {
            if let engine = registry[ObjectIdentifier(current)]?.engine {
                guard engine.agentDeliveryDepth == 0 else { return }
                engine.userInputCount += 1
                if event.type == .keyDown { engine.lastUserKeyAt = Date() }
                engine.onUserInput?()
                return
            }
            view = current.superview
        }
    }

    private func waitForUserQuiet(deadline: Date) async throws {
        while let last = lastUserKeyAt {
            let quietAt = last.addingTimeInterval(Self.userTypingQuiet)
            let wait = quietAt.timeIntervalSinceNow
            if wait <= 0 { return }
            guard quietAt < deadline else { throw BrowserAutomationError.userTyping }
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    // MARK: - WebKit calls with deadlines

    private var isThrottled: Bool {
        guard let window = webView.window else { return true }
        return NSApp.isHidden || !window.occlusionState.contains(.visible) || webView.isHiddenOrHasHiddenAncestor
    }

    private func world(_ op: String, _ arguments: [String: Any], deadline: Date) async throws -> [String: Any] {
        let value = try await callJavaScript(
            BrowserAutomationScript.call, arguments: ["op": op, "a": arguments],
            world: Self.world, deadline: deadline, what: "waiting for the page to answer"
        )
        return value as? [String: Any] ?? [:]
    }

    private func callJavaScript(_ body: String, arguments: [String: Any], world: WKContentWorld, deadline: Date, what: String) async throws -> Any? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw BrowserAutomationError.timedOut(what, throttled: isThrottled) }
        let throttled = isThrottled
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScriptValue, Error>) in
            let gate = Gate()
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                guard gate.claim() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: ScriptValue(value: value))
                case .failure(let error): continuation.resume(throwing: BrowserAutomationError.script(Self.clip(error.localizedDescription, 300)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                MainActor.assumeIsolated {
                    if gate.claim() { continuation.resume(throwing: BrowserAutomationError.timedOut(what, throttled: throttled)) }
                }
            }
        }
        return answer.value
    }

    private func takeSnapshot(_ configuration: WKSnapshotConfiguration, deadline: Date) async throws -> NSImage {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw BrowserAutomationError.timedOut("taking the screenshot", throttled: isThrottled) }
        let throttled = isThrottled
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            let gate = Gate()
            webView.takeSnapshot(with: configuration) { image, error in
                guard gate.claim() else { return }
                if let image { continuation.resume(returning: image) } else {
                    continuation.resume(throwing: BrowserAutomationError.script(error?.localizedDescription ?? "no image"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                MainActor.assumeIsolated {
                    if gate.claim() { continuation.resume(throwing: BrowserAutomationError.timedOut("taking the screenshot", throttled: throttled)) }
                }
            }
        }
    }

    private func pause(_ seconds: TimeInterval, deadline: Date) async throws {
        let wait = min(seconds, deadline.timeIntervalSinceNow)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    // MARK: - Pure helpers

    struct OutlineLine {
        var depth: Int
        var isText: Bool
        var text: String
    }

    static func outlineLines(_ raw: [String: Any]) -> [OutlineLine] {
        (raw["lines"] as? [[String: Any]] ?? []).compactMap { item in
            guard let text = item["s"] as? String else { return nil }
            return OutlineLine(depth: Int(double(item["d"])), isText: item["k"] as? String == "t", text: text)
        }
    }

    /// The snapshot reply, capped at `snapshotByteCap`. Console errors go
    /// first, then page text, then the tail of the outline, and the reply
    /// says what went.
    static func compose(
        url: String, title: String, generation: Int, lines: [OutlineLine],
        elementCapHit: Bool, console: [String], dialogs: [String]
    ) -> BrowserAutomationSnapshot {
        let header = "Page: \(title.isEmpty ? "(untitled)" : "\"\(clip(title, 120))\"") at \(url)\nSnapshot \(generation). A tag like [ref=e5] stays valid while its element stays on the page.\n"
        var outline = lines
        var console = console
        var cut: [String] = []
        if elementCapHit { cut.append("the page has more elements than one snapshot reads; the outline stops early") }
        func render() -> String {
            var text = header + "\n"
            for line in outline { text += String(repeating: "  ", count: line.depth) + "- " + line.text + "\n" }
            if outline.isEmpty { text += "(the page shows nothing)\n" }
            if !console.isEmpty { text += "\nConsole errors since the last snapshot (written by the page):\n" + console.map { "- " + $0 + "\n" }.joined() }
            if !dialogs.isEmpty { text += "\nDialogs, dismissed:\n" + dialogs.map { "- " + $0 + "\n" }.joined() }
            if !cut.isEmpty { text += "\nCut to fit \(snapshotByteCap / 1_000) KB: " + cut.joined(separator: "; ") + ".\n" }
            return text
        }
        let budget = snapshotByteCap - 300
        if render().utf8.count > budget, !console.isEmpty {
            cut.append("\(console.count) console errors (read them with array_browser_console)")
            console = []
        }
        if render().utf8.count > budget, outline.contains(where: \.isText) {
            let count = outline.filter(\.isText).count
            outline.removeAll(where: \.isText)
            cut.append("\(count) lines of page text")
        }
        if render().utf8.count > budget {
            var size = render().utf8.count
            var dropped = 0
            while size > budget, !outline.isEmpty {
                let line = outline.removeLast()
                size -= line.text.utf8.count + 2 * line.depth + 3
                dropped += 1
            }
            cut.append("the last \(dropped) outline lines, after \(outline.last.map { clip($0.text, 60) } ?? "the start"); scroll down and snapshot again")
        }
        return BrowserAutomationSnapshot(text: render(), generation: generation, url: url, title: title, cut: cut)
    }

    private static func requireTarget(_ target: [String: Any], ref: String, mustLand: Bool) throws {
        if target["stale"] as? Bool == true { throw BrowserAutomationError.staleRef(ref) }
        let what = target["what"] as? String ?? ref
        if target["invisible"] as? Bool == true { throw BrowserAutomationError.notVisible(what) }
        if mustLand, target["lands"] as? Bool != true {
            throw BrowserAutomationError.covered(target: what, by: target["cover"] as? String ?? "something")
        }
    }

    nonisolated static func encodePNG(_ image: CGImage, maxWidth: Int) -> BrowserAutomationScreenshot? {
        var source = image
        if image.width > maxWidth {
            let height = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
            guard let context = CGContext(
                data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return BrowserAutomationScreenshot(png: data as Data, pixelWidth: source.width, pixelHeight: source.height)
    }

    static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    static func clip(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }
}

@MainActor
private final class Gate {
    private var open = true
    func claim() -> Bool {
        defer { open = false }
        return open
    }
}

/// What WebKit hands back is property-list values, created for this call and
/// read only on main.
private struct ScriptValue: @unchecked Sendable {
    let value: Any
}

private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

extension BrowserAutomationScreenshot: Sendable {}
