import AppKit

/// The small, deterministic boundary between a hardware key event and the native
/// text system. Anything not explicitly owned by the composer stays with
/// `NSTextView`, including IME commit, Option/Command editing, and Escape when no
/// completion surface is open.
enum ComposerKeyAction: Equatable {
    case send
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
        suggestionsVisible: Bool
    ) -> ComposerKeyAction {
        if event.keyCode == escapeKeyCode, suggestionsVisible {
            return .dismissSuggestions
        }

        guard returnKeyCodes.contains(event.keyCode) else {
            return .nativeTextSystem
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift+Return is deliberately native insertion. Option, Command, and
        // Control combinations also stay native so standard macOS editing commands
        // are never repurposed as send.
        guard modifiers.intersection([.shift, .option, .command, .control]).isEmpty else {
            return .nativeTextSystem
        }
        // Marked text is owned by the input manager. Forward Return unchanged so it
        // can select/commit the actual candidate; clearing the mark ourselves would
        // bypass candidate-window semantics for real IMEs.
        if hasMarkedText { return .nativeTextSystem }
        return hasTrimmedContent ? .send : .nativeTextSystem
    }
}
