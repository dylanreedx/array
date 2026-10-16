import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

/// The scrim and card Settings draws inside the main window. It is the window
/// content's top-most subview, so it covers tiles (Metal terminals and WebKit
/// pages included), the canvas toolbar and the sidebar, and it swallows every
/// pointer event that lands on it so nothing reaches the canvas underneath.
///
/// Not `TokenThemed`: the scrim is an appearance-independent black wash, and the
/// card paints nothing itself — its colours come from the SwiftUI content, which
/// resolves system colours against the window's appearance.
final class SettingsOverlayView: NSView {
    static let identifier = "ArraySettingsOverlay"
    static let cardIdentifier = "ArraySettingsCard"
    static let closeIdentifier = "ArraySettingsClose"
    static let preferredCardSize = NSSize(width: 880, height: 620)
    static let minimumCardSize = NSSize(width: 560, height: 400)
    static let margin: CGFloat = 32

    var onDismiss: (() -> Void)?
    let card = NSView()
    private let shadowView = NSView()
    let closeButton: NSButton
    let hosting: NSView

    init(content: NSView) {
        hosting = content
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Settings")
            ?? NSImage(size: NSSize(width: 12, height: 12))
        closeButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 0.38)
        setAccessibilityIdentifier(Self.identifier)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")

        shadowView.wantsLayer = true
        shadowView.shadow = NSShadow()
        shadowView.layer?.shadowColor = CGColor(gray: 0, alpha: 1)
        shadowView.layer?.shadowOpacity = 0.35
        shadowView.layer?.shadowRadius = 30
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -12)
        addSubview(shadowView)

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = CGFloat(LineWidth.hairline)
        card.setAccessibilityIdentifier(Self.cardIdentifier)
        addSubview(card)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        card.addSubview(hosting)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityIdentifier(Self.closeIdentifier)
        closeButton.setAccessibilityLabel("Close Settings")
        closeButton.toolTip = "Close (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        card.addSubview(closeButton)
        applyBorderColour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func closeTapped(_ sender: Any?) { onDismiss?() }

    private func applyBorderColour() {
        var colour = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { colour = NSColor.separatorColor.cgColor }
        card.layer?.borderColor = colour
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColour()
    }

    /// The card shrinks with the window, keeping at least `margin` on every side,
    /// down to `minimumCardSize`; in a window smaller than that the margins give
    /// way first, and the card never exceeds the window.
    static func cardFrame(in bounds: NSRect) -> NSRect {
        func side(_ available: CGFloat, preferred: CGFloat, minimum: CGFloat) -> CGFloat {
            min(preferred, max(available - margin * 2, min(minimum, available)))
        }
        let width = side(bounds.width, preferred: preferredCardSize.width, minimum: minimumCardSize.width)
        let height = side(bounds.height, preferred: preferredCardSize.height, minimum: minimumCardSize.height)
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height).integral
    }

    override func layout() {
        super.layout()
        let frame = Self.cardFrame(in: bounds)
        card.frame = frame
        shadowView.frame = frame
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        hosting.frame = card.bounds
        closeButton.frame = NSRect(x: card.bounds.width - 40, y: card.bounds.height - 40, width: 24, height: 24)
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(point) { onDismiss?() }
    }

    // Nothing behind the scrim may react to the pointer.
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

/// Presents Settings as a modal inside a window, and owns how it closes.
@MainActor
final class SettingsModal {
    let model: SettingsModel
    private(set) var overlay: SettingsOverlayView?
    private weak var previousResponder: NSResponder?
    /// Fired exactly once per presentation, however it closes.
    var onClose: (() -> Void)?

    init(model: SettingsModel) {
        self.model = model
    }

    var isVisible: Bool { overlay?.superview != nil }
    var window: NSWindow? { overlay?.window }

    /// Opens Settings in `window`, or brings an open one forward. Never toggles.
    func show(in window: NSWindow, paneID: String? = nil) {
        if let paneID { model.selectPane(paneID) }
        guard let host = window.contentView else { return }
        if let overlay, overlay.superview === host {
            if host.subviews.last !== overlay {
                overlay.removeFromSuperview()
                host.addSubview(overlay, positioned: .above, relativeTo: nil)
            }
            focusSearch()
            return
        }
        previousResponder = window.firstResponder
        model.hostWindow = window
        let hosting = NSHostingView(rootView: SettingsRootView(model: model))
        let overlay = SettingsOverlayView(content: hosting)
        overlay.onDismiss = { [weak self] in self?.close() }
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        overlay.layoutSubtreeIfNeeded()
        focusSearch()
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    func focusSearch() {
        model.requestSearchFocus()
        if let field = searchField { window?.makeFirstResponder(field) }
    }

    /// Removes the modal and hands focus back. Idempotent: a second call (Esc
    /// after ⌘W, say) does nothing, so `onClose` fires once per presentation.
    func close() {
        guard let overlay else { return }
        let window = overlay.window
        model.flushPendingEdits()
        model.cancelRecording()
        overlay.removeFromSuperview()
        self.overlay = nil
        model.hostWindow = nil
        let previous = previousResponder
        previousResponder = nil
        onClose?()
        // The broker restores the focused surface in `onClose`; if nothing took
        // first responder there, fall back to what had it before Settings opened.
        if let window, window.firstResponder === window || window.firstResponder == nil,
           let view = previous as? NSView, view.window === window {
            window.makeFirstResponder(view)
        }
    }

    var searchField: NSSearchField? {
        guard let overlay else { return nil }
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.accessibilityIdentifier() == SettingsSearchField.identifier { return field }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(overlay)
    }

    private var searchFieldIsFocused: Bool {
        guard let field = searchField, let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field || editor === field.currentEditor()
    }

    /// The modal's share of the app's keyDown monitor. Returns true to consume.
    /// While Settings is open nothing else in that monitor runs, so canvas and
    /// global shortcuts are suppressed; this lets through only ⌘Q and the
    /// standard editing chords, and ordinary typing.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else { return false }
        // The chord recorder owns every key while it listens, Esc included.
        if model.recordingEntryID != nil { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case ",", "f": focusSearch(); return true
            case "w": close(); return true
            case "q", "a", "c", "v", "x", "z": return false
            default: return true
            }
        }
        if flags == [.command, .shift], key == "z" { return false }
        if flags.contains(.command) { return true }
        switch event.keyCode {
        case 53: // Escape: clear an active search first, otherwise close.
            if !model.searchQuery.isEmpty { model.clearSearch(); focusSearch() } else { close() }
            return true
        case 125, 126 where searchFieldIsFocused && !model.searchResults.isEmpty:
            model.moveSelection(by: event.keyCode == 125 ? 1 : -1)
            return true
        case 36, 76 where searchFieldIsFocused && model.selectedResult != nil:
            model.commitSelection()
            return true
        default:
            return false
        }
    }
}
