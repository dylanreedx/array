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
    case editorUnsupported(String)
    case nativeSelectUnsupported
    case uninspectableFrame
    case invalidSelection(String)
    case inputNotRetained(retainedCharacters: Int?, intendedCharacters: Int)
    case selectionNotRetained
    case focusChanged
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
        case .editorUnsupported(let message): return message
        case .nativeSelectUnsupported:
            return "Native HTML SELECT activation is unsupported for agent clicks and keys. Use array_browser_select to list and pick options without opening a native menu."
        case .uninspectableFrame:
            return "This frame cannot be inspected before native input, so picker safety cannot be established. Use array_browser_select on an accessible HTML select; this frame requires manual interaction."
        case .invalidSelection(let message):
            return message
        case let .inputNotRetained(retained, intended):
            let detail = retained.map { $0 == 0 ? "The page rejected the intended text (0/\(intended) characters retained)." : "The page retained only \($0)/\(intended) intended characters." }
                ?? "The retained character count could not be established."
            return "Background editing did not retain the full intended text. \(detail) Take a snapshot and inspect application state before retrying."
        case .selectionNotRetained:
            return "The requested selection could not be verified after page events and reconciliation. Application handlers may have changed it; inspect the page before another action."
        case .focusChanged:
            return "Keyboard focus moved outside this browser. Typing stopped before delivering more keys; a prefix may already be on the page. Take a snapshot before deciding what remains."
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
    // Internal experiment only. Remain off until the approved Tier B proof passes.
    static var focusFreeInputEnabled = false
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
    var isEngaged = false {
        didSet {
            if oldValue != isEngaged { updateBackgroundScheduling() }
            if !isEngaged { deliveryWindow = nil }
            else if supportsFocusFreeInput { deliveryWindow = webView.window ?? deliveryWindow }
        }
    }
    private var originalScheduling: [(setter: String, value: Bool)] = []
    private var originalInactivePolicy: WKPreferences.InactiveSchedulingPolicy?
    var backgroundSchedulingCapability: String {
        if !Self.focusFreeInputEnabled { return "Experimental backend disabled; standard scheduling. Hidden requestAnimationFrame may remain frozen." }
        let state = !originalScheduling.isEmpty ? "background DOM timer acceleration enabled" : isEngaged ? "background DOM timer acceleration unavailable; standard scheduling retained" : "ownership inactive; standard scheduling restored"
        return state + "; requestAnimationFrame can remain frozen on a hidden page; rAF-dependent work is not guaranteed."
    }

    private func updateBackgroundScheduling() {
        let prefs = webView.configuration.preferences
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        func set(_ name: String, _ value: Bool) {
            let selector = NSSelectorFromString(name)
            unsafeBitCast(prefs.method(for: selector), to: Setter.self)(prefs, selector, value)
        }
        if !isEngaged || !Self.focusFreeInputEnabled {
            for entry in originalScheduling { set(entry.setter, entry.value) }
            originalScheduling.removeAll()
            if let policy = originalInactivePolicy { prefs.inactiveSchedulingPolicy = policy }
            originalInactivePolicy = nil
            return
        }
        let controls = [
            ("_hiddenPageDOMTimerThrottlingEnabled", "_setHiddenPageDOMTimerThrottlingEnabled:"),
            ("_pageVisibilityBasedProcessSuppressionEnabled", "_setPageVisibilityBasedProcessSuppressionEnabled:")
        ]
        guard controls.allSatisfy({ prefs.responds(to: NSSelectorFromString($0.0)) && prefs.responds(to: NSSelectorFromString($0.1)) }) else { return }
        originalInactivePolicy = prefs.inactiveSchedulingPolicy
        for (getter, setter) in controls {
            let selector = NSSelectorFromString(getter)
            let value = unsafeBitCast(prefs.method(for: selector), to: Getter.self)(prefs, selector)
            originalScheduling.append((setter, value))
        }
        prefs.inactiveSchedulingPolicy = .none
        for entry in originalScheduling { set(entry.setter, false) }
    }
    private(set) var generation = 0
    /// Bumped by every real mouse-down or key-down the user makes in this
    /// tile. S3's takeover rule reads it.
    private(set) var userInputCount = 0
    var onUserInput: (() -> Void)?
    var onAgentClick: ((NSPoint) -> Void)?
    var _screenshotStarted: (() -> Void)?
    var _beforeNativeInputForChecks: (() throws -> Void)?
    var _duringAgentClickForChecks: (() -> Void)?
    var _afterAgentCharacterForChecks: (() -> Void)?
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
    private struct ComparisonBaseline {
        var outline: Set<String>?
        var url: String?
        var consoleMark: Int
    }
    private var comparisonPrincipal: AgentID?
    private var comparisonBaselines: [AgentID: ComparisonBaseline] = [:]
    func selectComparisonPrincipal(_ principal: AgentID) {
        guard principal != comparisonPrincipal else { return }
        if let previous = comparisonPrincipal {
            comparisonBaselines[previous] = ComparisonBaseline(outline: lastOutline, url: outlineURL, consoleMark: snapshotConsoleMark)
        }
        comparisonPrincipal = principal
        let baseline = comparisonBaselines[principal]
        lastOutline = baseline?.outline
        outlineURL = baseline?.url
        snapshotConsoleMark = baseline?.consoleMark ?? 0
    }
    private(set) var actionInputEvents = 0
    private(set) var actionDeliveredCharacters = 0
    private var actionDocumentIdentity: String?
    func beginActionTracking() { actionInputEvents = 0; actionDeliveredCharacters = 0; actionDocumentIdentity = documentIdentity }
    private(set) var documentIdentity = UUID().uuidString
    func invalidateDocumentIdentity() {
        documentIdentity = UUID().uuidString
        comparisonBaselines.removeAll()
        lastOutline = nil
        outlineURL = nil
    }
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
        _beforeNativeInputForChecks = nil
        _afterAgentCharacterForChecks = nil
        _duringAgentClickForChecks = nil
        for fingerprint in agentInputFingerprints where Self.syntheticInputs[fingerprint]?.engine === self {
            Self.syntheticInputs[fingerprint] = nil
        }
        agentInputFingerprints.removeAll()
        isEngaged = false
        deliveryWindow = nil
    }

    /// Include the tile chrome as well as the web view in takeover detection.
    func trackInputSurface(_ surface: NSView) {
        let id = ObjectIdentifier(surface)
        inputSurfaceIds.insert(id)
        Self.registry[id] = WeakEngine(engine: self)
    }

    // MARK: - Reading the page

    func snapshot(deadline: Date) async throws -> BrowserAutomationSnapshot {
        let identity = documentIdentity
        let raw = try await world("outline", [:], deadline: deadline)
        guard identity == documentIdentity else { throw BrowserAutomationError.staleRef("document") }
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
        suppressResponderChanges(true)
        defer { suppressResponderChanges(false) }
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
        let focusWindow = try liveWindow()
        let priorResponder = supportsFocusFreeInput ? nil : focusWindow.firstResponder
        let priorInput = supportsFocusFreeInput ? 0 : Self.focusInputGeneration
        defer { if !supportsFocusFreeInput { restore(priorResponder, in: focusWindow, inputGeneration: priorInput) } }
        actionDocumentIdentity = documentIdentity
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            try await self.settleIfRevealed()
            let target = try await self.world("target", ["ref": ref], deadline: deadline)
            try Self.requireTarget(target, ref: ref, mustLand: true)
            try Self.requireNativeInputTarget(target)
            try self.requireInputControl(inputAtStart, deadline: deadline)
            try self.deliverClick(cssX: Self.double(target["x"]), cssY: Self.double(target["y"]), window: window, count: doubleClick ? 2 : 1)
            return ("Clicked \(target["what"] as? String ?? ref)", nil)
        }
    }

    func click(x: Double, y: Double, doubleClick: Bool = false, deadline: Date) async throws -> BrowserAutomationOutcome {
        let focusWindow = try liveWindow()
        let priorResponder = supportsFocusFreeInput ? nil : focusWindow.firstResponder
        let priorInput = supportsFocusFreeInput ? 0 : Self.focusInputGeneration
        defer { if !supportsFocusFreeInput { restore(priorResponder, in: focusWindow, inputGeneration: priorInput) } }
        actionDocumentIdentity = documentIdentity
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            try await self.settleIfRevealed()
            let hit = try await self.world("at", ["x": x, "y": y], deadline: deadline)
            try Self.requireNativeInputTarget(hit)
            try self.requireInputControl(inputAtStart, deadline: deadline)
            try self.deliverClick(cssX: x, cssY: y, window: window, count: doubleClick ? 2 : 1)
            return ("Clicked at \(Int(x)),\(Int(y)), on \(hit["what"] as? String ?? "nothing")", nil)
        }
    }

    /// Types `text` into the field tagged `ref`, or into whatever has focus
    /// when `ref` is nil. `clear` replaces the field's contents; `submit`
    /// presses Enter afterwards.
    func type(_ text: String, ref: String?, clear: Bool = false, submit: Bool = false, deadline: Date) async throws -> BrowserAutomationOutcome {
        actionDocumentIdentity = documentIdentity
        try await waitForUserQuiet(deadline: deadline)
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            let window = try self.liveWindow()
            // Keep restoration across every yield conditional on no external
            // input anywhere in Array, and on our browser still owning focus.
            let responder = self.supportsFocusFreeInput ? nil : window.firstResponder
            let focusInput = self.supportsFocusFreeInput ? 0 : Self.focusInputGeneration
            defer { if !self.supportsFocusFreeInput { self.restore(responder, in: window, inputGeneration: focusInput) } }
            var what = "the focused element"
            if let ref {
                let target = try await self.world("target", ["ref": ref], deadline: deadline)
                try Self.requireTarget(target, ref: ref, mustLand: true)
                try Self.requireNativeInputTarget(target)
                what = target["what"] as? String ?? ref
                guard target["editable"] as? Bool == true else { throw BrowserAutomationError.notEditable(what) }
                try await self.settleIfRevealed()
                try self.requireInputControl(inputAtStart, deadline: deadline)
                guard self.supportsFocusFreeInput || window.firstResponder === responder else { throw BrowserAutomationError.focusChanged }
                // The type action owns this borrow until its guarded defer.
                // Restoring inside this click blurs the target before its keys.
                try self.deliverClick(cssX: Self.double(target["x"]), cssY: Self.double(target["y"]), window: window, count: 1, restoreFocus: false)
                try await self.pause(0.05, deadline: deadline)
                let focus = try await self.world("focusedIs", ["ref": ref], deadline: deadline)
                guard focus["focused"] as? Bool == true else { throw BrowserAutomationError.focusRefused(what) }
                if clear {
                    try self.requireInputControl(inputAtStart, deadline: deadline)
                    if self.supportsFocusFreeInput {
                        let editor = try await self.world("keyboardTarget", [:], deadline: deadline)["editor"] as? String ?? "native"
                        if editor == "cm" || editor == "pm" || editor == "monaco" { self.deliverKey(Self.characterKey("a"), flags: .command, window: window) }
                        else { try self.editCommand("SelectAll") }
                        try await self.pause(0.02, deadline: deadline)
                    } else { _ = try await self.world("select", ["ref": ref], deadline: deadline) }
                }
            }
            let focusRef: String
            if let ref { focusRef = ref }
            else { focusRef = try await self.world("activeRef", [:], deadline: deadline)["ref"] as? String ?? "" }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            try await self.preflightKeyboard(deadline: deadline)
            try self.requireInputControl(inputAtStart, deadline: deadline)
            if self.supportsFocusFreeInput { _ = try await self.world("beginInputVerification", ["ref": focusRef, "text": text, "clear": clear], deadline: deadline) }
            if clear && text.isEmpty {
                let focus = try await self.world("focusedIs", ["ref": focusRef], deadline: deadline)
                try self.requireInputControl(inputAtStart, deadline: deadline)
                try self.requireTypingResponder(in: window, original: responder, inputGeneration: focusInput)
                guard focus["focused"] as? Bool == true else { throw BrowserAutomationError.focusRefused(what) }
                self.deliverKey(Self.namedKeys["Backspace"]!, flags: [], window: window)
            }
            for character in text {
                try await self.preflightKeyboard(deadline: deadline)
                let focus = try await self.world("focusedIs", ["ref": focusRef], deadline: deadline)
                try self.requireInputControl(inputAtStart, deadline: deadline)
                try self.requireTypingResponder(in: window, original: responder, inputGeneration: focusInput)
                guard focus["focused"] as? Bool == true else { throw BrowserAutomationError.focusRefused(what) }
                if self.supportsFocusFreeInput, character != "\n", character != "\t" {
                    try self.editCommand("InsertText", argument: String(character))
                } else { self.deliverCharacter(character, window: window) }
                self.actionDeliveredCharacters += 1
                self._afterAgentCharacterForChecks?()
                // WebKit consumes trusted input asynchronously. A small yield
                // keeps long bursts from losing keys and lets user input win.
                try await self.pause(0.005, deadline: deadline)
            }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            if submit {
                try await self.preflightKeyboard(deadline: deadline)
                let focus = try await self.world("focusedIs", ["ref": focusRef], deadline: deadline)
                try self.requireInputControl(inputAtStart, deadline: deadline)
                try self.requireTypingResponder(in: window, original: responder, inputGeneration: focusInput)
                guard focus["focused"] as? Bool == true else { throw BrowserAutomationError.focusRefused(what) }
                self.deliverKey(Self.namedKeys["Enter"]!, flags: [], window: window)
            }
            if self.supportsFocusFreeInput {
                try await self.pause(0.1, deadline: deadline)
                let verification = try await self.world("verifyInput", [:], deadline: deadline)
                guard verification["retained"] as? Bool == true else {
                    let retained = verification["retainedCharacters"] as? Int
                    if let retained { self.actionDeliveredCharacters = retained }
                    throw BrowserAutomationError.inputNotRetained(retainedCharacters: retained, intendedCharacters: text.count)
                }
            }
            var value: String?
            if let ref {
                try await self.pause(0.1, deadline: deadline)
                value = try await self.world("focusedIs", ["ref": ref], deadline: deadline)["value"] as? String
            }
            let count = text.count
            if self.supportsFocusFreeInput { return ("Delivered \(count) editing characters into \(what); page text read back" + (submit ? "; Enter dispatched, inspect application outcome" : ""), value) }
            return ("Typed \(count) character\(count == 1 ? "" : "s") into \(what)" + (submit ? " and pressed Enter" : ""), value)
        }
    }

    /// `combo` is a key name or one character, optionally with modifiers:
    /// `Enter`, `Shift+Tab`, `ArrowDown`, `Control+a`.
    func pressKey(_ combo: String, deadline: Date) async throws -> BrowserAutomationOutcome {
        let focusWindow = try liveWindow()
        let priorResponder = supportsFocusFreeInput ? nil : focusWindow.firstResponder
        let priorInput = supportsFocusFreeInput ? 0 : Self.focusInputGeneration
        defer { if !supportsFocusFreeInput { restore(priorResponder, in: focusWindow, inputGeneration: priorInput) } }
        actionDocumentIdentity = documentIdentity
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
            let responder = self.supportsFocusFreeInput ? nil : window.firstResponder
            let focusInput = self.supportsFocusFreeInput ? 0 : Self.focusInputGeneration
            try await self.preflightKeyboard(deadline: deadline)
            try self.requireTypingResponder(in: window, original: responder, inputGeneration: focusInput)
            defer { if !self.supportsFocusFreeInput { self.restore(responder, in: window, inputGeneration: focusInput) } }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            let editor = self.supportsFocusFreeInput ? try await self.world("keyboardTarget", [:], deadline: deadline)["editor"] as? String ?? "native" : "native"
            if self.supportsFocusFreeInput, editor == "monaco", flags == .command, keyName.lowercased() == "z" {
                throw BrowserAutomationError.editorUnsupported("Monaco background Undo is unsupported: the editor gate did not restore its model. Observe the model; no foreground fallback.")
            }
            try self._beforeNativeInputForChecks?()
            let observation = "__arrayKey_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            _ = try await self.callJavaScript("window[token] = false; document.addEventListener('keydown', function observed(e) { if (e.isTrusted) window[token] = true; }, {capture:true, once:true}); return true", arguments: ["token": observation], world: Self.world, deadline: deadline, what: "observing keyboard delivery")
            try self.requireTypingResponder(in: window, original: responder, inputGeneration: focusInput)
            try self.requireInputControl(inputAtStart, deadline: deadline)
            // WebKit observes keydown without applying native editing commands
            // when a host composer owns the responder. Borrow it for dispatch.
            if !self.supportsFocusFreeInput {
                guard window.makeFirstResponder(self.webView) else { throw BrowserAutomationError.focusChanged }
            }
            // A Cmd+A key event selects nothing in a web view (probe p2); the
            // responder action does.
            if flags == .command, keyName.lowercased() == "a" {
                if self.supportsFocusFreeInput {
                    if editor == "cm" || editor == "pm" || editor == "monaco" { self.deliverKey(key, flags: flags, window: window) }
                    else { try self.editCommand("SelectAll") }
                } else { self.webView.selectAll(nil) }
            } else if self.supportsFocusFreeInput, flags == .command, keyName.lowercased() == "z" {
                try self.editCommand("Undo")
            } else {
                self.deliverKey(key, flags: flags, window: window)
            }
            let observed = try await self.callJavaScript("const seen = window[token]; delete window[token]; return seen === true", arguments: ["token": observation], world: Self.world, deadline: deadline, what: "checking keyboard delivery") as? Bool == true
            guard observed || (flags == .command && (keyName.lowercased() == "a" || (self.supportsFocusFreeInput && keyName.lowercased() == "z"))) else {
                throw BrowserAutomationError.script("Keyboard dispatch was not observed in the page; its effect is unknown. Take a snapshot before retrying.")
            }
            return ("Delivered \(combo) to the page; inspect the page to confirm its effect", nil)
        }
    }

    /// Semantic HTML SELECT operation. Validation and selectedness writes happen
    /// in one JavaScript turn. Page listeners receive untrusted input/change.
    func selectOptions(ref: String, options: [BrowserSelectOption]?, deadline: Date) async throws -> BrowserAutomationOutcome {
        actionDocumentIdentity = documentIdentity
        let inputAtStart = userInputCount
        return try await act(deadline: deadline) {
            try self.requireInputControl(inputAtStart, deadline: deadline)
            var args: [String: Any] = ["ref": ref]
            if let options { args["options"] = options.map { option -> [String: Any] in
                var row: [String: Any] = ["value": option.value]
                if let index = option.index { row["index"] = index }
                return row
            } }
            let selected = try await self.world("selectOptions", args, deadline: deadline)
            if selected["stale"] as? Bool == true { throw BrowserAutomationError.staleRef(ref) }
            if let error = selected["error"] as? String { throw BrowserAutomationError.invalidSelection(error) }
            // A successful mutating JavaScript turn crossed the dispatch boundary.
            // Validation errors above made no writes; later reconciliation can
            // fail after this selection has already reached the application.
            if options != nil { self.actionInputEvents += 1 }
            try self.requireInputControl(inputAtStart, deadline: deadline)
            var readback = selected
            if options != nil {
                try await self.pause(0.1, deadline: deadline)
                readback = try await self.world("selectOptions", ["ref": ref], deadline: deadline)
                try self.requireInputControl(inputAtStart, deadline: deadline)
                guard readback["stale"] as? Bool != true,
                      (readback["selectedIndices"] as? [Int]) == (selected["requestedIndices"] as? [Int]),
                      (readback["selectedValues"] as? [String]) == (selected["requestedValues"] as? [String]) else {
                    throw BrowserAutomationError.selectionNotRetained
                }
            }
            let data = try JSONSerialization.data(withJSONObject: readback, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= 60_000 else {
                if options != nil { throw BrowserAutomationError.selectionNotRetained }
                throw BrowserAutomationError.script("Select listing exceeds 60 KB.")
            }
            return (options == nil ? "Listed HTML select options" : "Selected HTML options; inspect application state", String(decoding: data, as: UTF8.self))
        }
    }

    func scroll(ref: String? = nil, dx: Double = 0, dy: Double = 0, deadline: Date) async throws -> BrowserAutomationOutcome {
        actionDocumentIdentity = documentIdentity
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
        suppressResponderChanges(true)
        defer { suppressResponderChanges(false) }
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
        guard runtime?.isTerminated == false else { throw BrowserAutomationError.notLive }
        guard userInputCount == inputAtStart else { throw BrowserAutomationError.userTyping }
        if let expected = actionDocumentIdentity, expected != documentIdentity { throw BrowserAutomationError.staleRef("document") }
        guard Date() < deadline else { throw BrowserAutomationError.timedOut("before sending browser input", throttled: isThrottled) }
    }

    private static func requireNativeInputTarget(_ target: [String: Any], clicking: Bool = true) throws {
        if target["uninspectableFrame"] as? Bool == true { throw BrowserAutomationError.uninspectableFrame }
        if target["nativeSelect"] as? Bool == true { throw BrowserAutomationError.nativeSelectUnsupported }
        if clicking, Self.focusFreeInputEnabled, WKWebView.instancesRespond(to: NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")), target["editor"] as? String == "monaco" {
            throw BrowserAutomationError.editorUnsupported("Monaco background click/caret placement is unsupported; its tested click selected text instead of placing a caret. No foreground fallback.")
        }
    }

    private func preflightKeyboard(deadline: Date) async throws {
        try Self.requireNativeInputTarget(try await world("keyboardTarget", [:], deadline: deadline), clicking: false)
    }

    /// Availability is an OS capability, never permission to activate or take
    /// the key window. Missing SPI retains the Stage 1 guarded delivery path.
    var supportsFocusFreeInput: Bool {
        Self.focusFreeInputEnabled && webView.responds(to: NSSelectorFromString("_setShouldSuppressFirstResponderChanges:"))
    }

    private var suppressionDepth = 0
    private var suppressionInterrupted = false
    private func suppressResponderChanges(_ enabled: Bool) {
        guard supportsFocusFreeInput else { return }
        if enabled {
            if suppressionDepth == 0 { suppressionInterrupted = false }
            suppressionDepth += 1
        } else { suppressionDepth = max(0, suppressionDepth - 1) }
        setResponderSuppression(suppressionDepth > 0 && !suppressionInterrupted)
    }
    private func setResponderSuppression(_ enabled: Bool) {
        guard supportsFocusFreeInput else { return }
        let selector = NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }
    private func editCommand(_ command: String, argument: String = "") throws {
        let selector = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webView.responds(to: selector) else { throw BrowserAutomationError.editorUnsupported("Background edit command unavailable on this WebKit; no foreground fallback.") }
        typealias Edit = @convention(c) (AnyObject, Selector, NSString, NSString, @escaping @convention(block) (Bool) -> Void) -> Void
        actionInputEvents += 1
        unsafeBitCast(webView.method(for: selector), to: Edit.self)(webView, selector, command as NSString, argument as NSString, { _ in })
    }

    private func requireKeyboardResponder(in window: NSWindow) throws {
        guard let current = window.firstResponder as? NSView,
              current === webView || current.isDescendant(of: webView) else { throw BrowserAutomationError.focusChanged }
    }

    private func requireTypingResponder(in window: NSWindow, original: NSResponder?, inputGeneration: UInt64) throws {
        if supportsFocusFreeInput { return }
        // In inactive windows WebKit can consume trusted typing while leaving
        // the original host responder alone. Preserve that supported path only
        // while no external input or responder change has invalidated it.
        if Self.focusInputGeneration == inputGeneration, window.firstResponder === original { return }
        try requireKeyboardResponder(in: window)
    }

    private var deliveryWindow: NSWindow?
    private func liveWindow() throws -> NSWindow {
        guard let runtime, !runtime.isTerminated else { throw BrowserAutomationError.notLive }
        if let window = webView.window {
            if supportsFocusFreeInput { deliveryWindow = window }
            return window
        }
        if supportsFocusFreeInput, isEngaged, let deliveryWindow { return deliveryWindow }
        throw BrowserAutomationError.notLive
    }

    /// A tile that just left a hidden parent needs a moment before input: a
    /// probe click sent straight after registered nothing.
    private func settleIfRevealed() async throws {
        let hidden = webView.isHiddenOrHasHiddenAncestor
        defer { wasHidden = hidden }
        if wasHidden && !hidden { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func deliverClick(cssX: Double, cssY: Double, window: NSWindow, count: Int, restoreFocus: Bool = true) throws {
        try _beforeNativeInputForChecks?()
        suppressResponderChanges(true)
        defer { suppressResponderChanges(false) }
        actionInputEvents += 1
        agentDeliveryDepth += 1
        defer { agentDeliveryDepth -= 1 }
        let zoom = webView.pageZoom
        let local = NSPoint(x: cssX * zoom, y: webView.isFlipped ? cssY * zoom : webView.bounds.height - cssY * zoom)
        let point = webView.convert(local, to: nil)
        let responder = self.supportsFocusFreeInput ? nil : window.firstResponder
        let focusInput = self.supportsFocusFreeInput ? 0 : Self.focusInputGeneration
        for clickCount in 1...count {
            let down = Self.mouseEvent(.leftMouseDown, at: point, window: window, clickCount: clickCount)
            rememberAgentInput(down)
            webView.mouseDown(with: down)
            _duringAgentClickForChecks?()
            webView.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: point, window: window, clickCount: clickCount))
        }
        if restoreFocus && !supportsFocusFreeInput { restore(responder, in: window, inputGeneration: focusInput) }
        onAgentClick?(local)
    }

    private func restore(_ responder: NSResponder?, in window: NSWindow, inputGeneration: UInt64) {
        if supportsFocusFreeInput { return }
        // Nested native tracking can deliver input anywhere in Array. Browser
        // takeover is deliberately local; restoration invalidation is global.
        guard Self.focusInputGeneration == inputGeneration,
              let current = window.firstResponder as? NSView,
              current === webView || current.isDescendant(of: webView) else { return }
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
        suppressResponderChanges(true)
        defer { suppressResponderChanges(false) }
        actionInputEvents += 1
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
    private static var focusInputGeneration: UInt64 = 0
    private static var monitor: Any?

    private static func register(_ engine: BrowserAutomation) {
        registry[ObjectIdentifier(engine.webView)] = WeakEngine(engine: engine)
        guard monitor == nil else { return }
        // One monitor for every engine. It sees only events that pass
        // `NSApp.sendEvent`, which an engine's own direct delivery never does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { BrowserAutomation.noteUserEvent(event) }
            return event
        }
    }

    private static func noteUserEvent(_ event: NSEvent) {
        guard !registry.isEmpty else { return }
        if consumeAgentInput(event) { return }
        focusInputGeneration &+= 1
        let wheelWindow: NSWindow? = event.type == .scrollWheel ? event.cgEvent.flatMap { cg in
            let point = NSPoint(x: cg.location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - cg.location.y)
            let candidates = NSApp.windows.filter { $0.frame.contains(point) }
            return candidates.count == 1 ? candidates.first : nil
        } : nil
        guard let window = event.window ?? wheelWindow else { return }
        var location = event.locationInWindow
        if event.window == nil, let cg = event.cgEvent {
            let screenPoint = NSPoint(x: cg.location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - cg.location.y)
            location = window.convertPoint(fromScreen: screenPoint)
        }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else if let content = window.contentView {
            view = content.hitTest(content.superview?.convert(location, from: nil) ?? location)
        }
        while let current = view {
            if let engine = registry[ObjectIdentifier(current)]?.engine {
                guard engine.agentDeliveryDepth == 0 || engine.supportsFocusFreeInput else { return }
                engine.suppressionInterrupted = true
                engine.setResponderSuppression(false)
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
            BrowserAutomationScript.call, arguments: ["op": op, "a": arguments, "identity": documentIdentity],
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
        let header = "Page: \(title.isEmpty ? "(untitled)" : "\"\(clip(title, 120))\"") at \(url)\nSnapshot \(generation). Refs are opaque and belong to this document. Take a fresh snapshot after navigation or a tab change.\n"
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
