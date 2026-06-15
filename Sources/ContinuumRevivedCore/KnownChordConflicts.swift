import Foundation

/// Chords claimed by macOS itself or by common third-party *global* hotkey
/// daemons (window managers, launchers). Continuum's own shortcuts are
/// app-scoped — they fire only when Continuum is frontmost — so the only chords
/// that can silently preempt them are these system-wide ones (docs/29 §2). The
/// Rectangle entries are why tile move/throw was re-homed off `⌃⌥`-arrows.
///
/// `KeybindConflictChecks` audits every DEFAULT keybind against this list and
/// fails the build if a default lands on a conflict (the nav leader is the one
/// documented exception — see the check). Keep this list curated, not
/// exhaustive: add a chord when a real daemon/system shortcut would shadow a
/// Continuum default.
public enum KnownChordConflicts {
    public enum Source: String, Equatable, Sendable {
        case macOS = "macOS system"
        case rectangle = "Rectangle (global hotkey daemon)"
    }

    public struct Conflict: Equatable, Sendable {
        public let chord: KeyChord
        public let source: Source
        public let note: String

        public init(chord: KeyChord, source: Source, note: String) {
            self.chord = chord
            self.source = source
            self.note = note
        }
    }

    /// macOS system shortcuts that preempt app keys system-wide.
    public static let macOS: [Conflict] = [
        Conflict(chord: KeyChord(keyCode: 49, modifiers: .command), source: .macOS, note: "Spotlight (⌘Space)"),
        Conflict(chord: KeyChord(keyCode: 49, modifiers: .control), source: .macOS, note: "Select previous input source (⌃Space)"),
        Conflict(chord: KeyChord(keyCode: 49, modifiers: [.control, .option]), source: .macOS, note: "Select next input source (⌃⌥Space)"),
        Conflict(chord: KeyChord(keyCode: 48, modifiers: .command), source: .macOS, note: "Switch application (⌘Tab)"),
        Conflict(chord: KeyChord(keyCode: 12, modifiers: .command), source: .macOS, note: "Quit application (⌘Q)"),
        // Mission Control / Spaces — Control + arrows.
        Conflict(chord: KeyChord(keyCode: 126, modifiers: .control), source: .macOS, note: "Mission Control (⌃↑)"),
        Conflict(chord: KeyChord(keyCode: 125, modifiers: .control), source: .macOS, note: "Application windows (⌃↓)"),
        Conflict(chord: KeyChord(keyCode: 123, modifiers: .control), source: .macOS, note: "Move left a space (⌃←)"),
        Conflict(chord: KeyChord(keyCode: 124, modifiers: .control), source: .macOS, note: "Move right a space (⌃→)"),
        // Screenshots.
        Conflict(chord: KeyChord(keyCode: 20, modifiers: [.command, .shift]), source: .macOS, note: "Screenshot to file (⌘⇧3)"),
        Conflict(chord: KeyChord(keyCode: 21, modifiers: [.command, .shift]), source: .macOS, note: "Screenshot selection (⌘⇧4)"),
    ]

    /// Rectangle's default global hotkeys — the daemon that prompted docs/29.
    /// Rectangle owns `⌃⌥` + arrows (halves / maximize / restore) system-wide,
    /// so anything Continuum bound there was silently preempted.
    public static let rectangle: [Conflict] = [
        Conflict(chord: KeyChord(keyCode: 123, modifiers: [.control, .option]), source: .rectangle, note: "Left half (⌃⌥←)"),
        Conflict(chord: KeyChord(keyCode: 124, modifiers: [.control, .option]), source: .rectangle, note: "Right half (⌃⌥→)"),
        Conflict(chord: KeyChord(keyCode: 126, modifiers: [.control, .option]), source: .rectangle, note: "Maximize (⌃⌥↑)"),
        Conflict(chord: KeyChord(keyCode: 125, modifiers: [.control, .option]), source: .rectangle, note: "Restore / bottom half (⌃⌥↓)"),
    ]

    public static let all: [Conflict] = macOS + rectangle

    /// The first known conflict matching `chord`, or `nil` if the chord is clear.
    public static func conflict(for chord: KeyChord) -> Conflict? {
        all.first { $0.chord == chord }
    }
}
