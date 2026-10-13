import AppKit

/// The small, deterministic boundary between a hardware key event and the native
/// text system. Anything not explicitly owned by the composer stays with
/// `NSTextView`, including IME commit, Option/Command editing, and Escape when no
/// completion surface is open.
enum ComposerKeyAction: Equatable {
    case send
    /// T5 (D1) — ⌥↩: queue for after the turn.
    case queueSend
    /// T5 (D1) — ⌘↩: interrupt the turn and send now.
    case forceSend
    case dismissSuggestions
    case nativeTextSystem
}

struct ComposerKeyPolicy {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let escapeKeyCode: UInt16 = 53

    static func action(
        for event: NSEvent,
        hasMarkedText: Bool,
        hasTrimmedContent: Bool,
        suggestionsVisible: Bool,
        hasAttachments: Bool = false
    ) -> ComposerKeyAction {
        if event.keyCode == escapeKeyCode, suggestionsVisible {
            return .dismissSuggestions
        }

        guard returnKeyCodes.contains(event.keyCode) else {
            return .nativeTextSystem
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .option, .command, .control])
        // Marked text is owned by the input manager. Forward Return unchanged so it
        // can select/commit the actual candidate; clearing the mark ourselves would
        // bypass candidate-window semantics for real IMEs.
        if hasMarkedText { return .nativeTextSystem }
        guard hasTrimmedContent || hasAttachments else { return .nativeTextSystem }
        // Shift+Return is deliberately native insertion, and so is every other
        // combination: only plain, ⌥ and ⌘ Return are the composer's (D1).
        switch modifiers {
        case []: return .send
        case [.option]: return .queueSend
        case [.command]: return .forceSend
        default: return .nativeTextSystem
        }
    }
}
