import AppKit
import ObjectiveC

/// Keyboard order for collaboration surfaces. Each surface links its own
/// controls in reading order; a move skips whatever is hidden or disabled at
/// that moment, so one loop serves every state.
///
/// Both directions walk the stored order. AppKit's own `previousKeyView` is a
/// single back-pointer that an enclosing scroll view rewrites when its document
/// view is set, which sent Shift-Tab from a draft editor to the wrong control.
@MainActor
enum CollaborationKeyLoop {
    private final class Loop {
        let views: [Weak]
        init(_ views: [NSView]) { self.views = views.map(Weak.init) }
    }
    private final class Weak { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    private static var loopKey: UInt8 = 0

    /// Closes `views` into one loop, in order.
    static func link(_ views: [NSView]) {
        guard let first = views.first else { return }
        let loop = Loop(views)
        for (view, next) in zip(views, views.dropFirst() + [first]) {
            view.nextKeyView = next
            objc_setAssociatedObject(view, &loopKey, loop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Moves focus from `view` to the next (or previous) stop in its loop that
    /// can take focus now. A view outside any loop falls back to AppKit.
    static func move(from view: NSView?, forward: Bool, in window: NSWindow?) {
        guard let window else { return }
        guard let view, let loop = objc_getAssociatedObject(view, &loopKey) as? Loop,
              let index = loop.views.firstIndex(where: { $0.view === view }) else {
            if forward { window.selectNextKeyView(nil) } else { window.selectPreviousKeyView(nil) }
            return
        }
        let count = loop.views.count
        for offset in 1..<max(count, 1) {
            let candidate = loop.views[(index + (forward ? offset : count - offset)) % count].view
            if let candidate, !candidate.isHiddenOrHasHiddenAncestor, candidate.canBecomeKeyView {
                window.makeFirstResponder(candidate); return
            }
        }
    }

    /// Call before a refresh that may disable or hide controls; the returned
    /// token, restored after it, moves keyboard focus on from a control that can
    /// no longer hold it (Post after sending, Endorse after endorsing) instead
    /// of letting it fall to the window, where Tab reaches nothing.
    static func holdFocus(in window: NSWindow?) -> NSView? {
        guard let view = current(in: window), objc_getAssociatedObject(view, &loopKey) != nil else { return nil }
        return view
    }
    static func restoreFocus(_ held: NSView?, in window: NSWindow?) {
        guard let held, let window, held.isHiddenOrHasHiddenAncestor || !held.canBecomeKeyView || current(in: window) !== held else { return }
        // Focus moved somewhere real on purpose: leave it there.
        if let now = current(in: window), now !== held { return }
        move(from: held, forward: true, in: window)
    }

    /// The control a person is on: a text field rather than its field editor.
    static func current(in window: NSWindow?) -> NSView? {
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return window?.firstResponder as? NSView
    }

    /// Array's menu and action buttons pass Tab up the responder chain rather
    /// than moving focus themselves. Each collaboration root view catches it
    /// here and moves through its loop; Option- and Command-Tab are left alone.
    static func handleTab(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.keyCode == 48, event.modifierFlags.intersection([.command, .option]).isEmpty, let window else { return false }
        move(from: current(in: window), forward: !event.modifierFlags.contains(.shift), in: window)
        return true
    }

    /// Multi-line text views keep Tab for themselves by default, which traps a
    /// keyboard user. Tab and Shift-Tab move focus instead; Option-Tab still
    /// inserts a literal tab through `insertTabIgnoringFieldEditor:`.
    static func moveFocus(from textView: NSTextView, command: Selector) -> Bool {
        if command == #selector(NSResponder.insertTab(_:)) { move(from: textView, forward: true, in: textView.window); return true }
        if command == #selector(NSResponder.insertBacktab(_:)) { move(from: textView, forward: false, in: textView.window); return true }
        return false
    }
}
