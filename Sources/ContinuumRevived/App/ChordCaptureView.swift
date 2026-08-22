import AppKit
import ContinuumRevivedCore

/// A fresh chord-capture field for the keybindings editor (docs/24 S5). Unlike
/// `LaunchProfilePalette.handleKeyEvent` (which REJECTS modifier chords), this
/// view's whole job is to capture a single `KeyChord` — modifiers + keyCode —
/// the moment a real key (not a bare modifier) is pressed. `Esc` cancels.
///
/// While capturing it shows a "press new chord…" affordance and is the window's
/// first responder; any captured chord (and the event's typed character, used
/// by the caller for single-key nav bindings) is reported via `onCapture`, and
/// the view returns to its idle prompt.
@MainActor
final class ChordCaptureView: NSView {
    /// Reports a captured chord. `character` is `charactersIgnoringModifiers`,
    /// lowercased — the caller uses it for single-key nav-mode bindings.
    var onCapture: ((_ keyCode: UInt16, _ modifiers: FocusKeyModifiers, _ character: String?) -> Void)?
    /// Reports a cancel (Esc) so the caller can restore the static row.
    var onCancel: (() -> Void)?

    private let promptLabel = NSTextField(labelWithString: "press new chord…  (esc to cancel)")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).appResolvedCGColor
        layer?.cornerRadius = 4
        promptLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptLabel.textColor = .controlAccentColor
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(promptLabel)
        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            promptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var acceptsFirstResponder: Bool { true }

    /// Begins capture: grab first-responder so key events route here.
    func beginCapture() {
        window?.makeFirstResponder(self)
    }

    func showValidationError(_ message: String) {
        promptLabel.stringValue = message
        promptLabel.textColor = .systemRed
        promptLabel.toolTip = message
        NSSound.beep()
        window?.makeFirstResponder(self)
    }

    // Capturing both `keyDown` and `performKeyEquivalent` ensures we intercept
    // command-modified chords (which the responder chain routes through key
    // equivalents) as well as plain keys.
    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
    }

    /// Returns true if the event was consumed (a chord captured or cancelled).
    private func handle(_ event: NSEvent) -> Bool {
        // Esc cancels.
        if event.keyCode == 53 {
            onCancel?()
            return true
        }
        // Ignore bare modifier-only presses (no real key yet). keyDown for a
        // modifier-only press never fires, but guard the keyCode range anyway.
        if isModifierKeyCode(event.keyCode) {
            return false
        }
        let modifiers = FocusKeyModifiers(modifierFlags: event.modifierFlags)
        let character = event.charactersIgnoringModifiers?.lowercased()
        onCapture?(event.keyCode, modifiers, character)
        return true
    }

    private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        // Command (54/55), Shift (56/60), CapsLock (57), Option (58/61),
        // Control (59/62), Fn (63).
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: return true
        default: return false
        }
    }
}

extension FocusKeyModifiers {
    /// Translates AppKit modifier flags into the pure-model modifier set, masking
    /// to device-independent flags so only Command/Shift/Option/Control survive.
    init(modifierFlags flags: NSEvent.ModifierFlags) {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var value: FocusKeyModifiers = []
        if masked.contains(.command) { value.insert(.command) }
        if masked.contains(.shift) { value.insert(.shift) }
        if masked.contains(.option) { value.insert(.option) }
        if masked.contains(.control) { value.insert(.control) }
        self = value
    }
}
